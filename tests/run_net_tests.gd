extends SceneTree
## Headless acceptance tests for the deterministic lockstep netcode layer. Run:
##   Godot --headless --path . --script res://tests/run_net_tests.gd
## Exits 0 on success, 1 on any failed assertion. Covers all four brief criteria:
##   1) bit-identical state for identical input sequences (fixed-point + seeded PRNG)
##   2) input-delay buffer absorbs latency; packet loss recovers within a bounded stall
##   3) per-frame state-hash exchange identifies the desync frame
##   4) one-shot state serialize/restore reproduces play bit-for-bit (rollback-ready)

var _failures: int = 0
var _checks: int = 0

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: ", msg)
	else:
		_failures += 1
		printerr("  FAIL: ", msg)

func _initialize() -> void:
	print("== Soomgo Arcade netcode acceptance tests ==")
	_test_determinism()
	_test_fixed_point_no_drift()
	_test_input_delay_absorbs_latency()
	_test_packet_loss_bounded_recovery()
	_test_desync_frame_identified()
	_test_snapshot_restore_rollback()
	_test_netmatch_started_determinism()
	_test_netmatch_drop_recovery()
	_test_net_series_determinism()
	_test_room_state()
	print("")
	print("Checks: %d  Failures: %d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

# --- Room (pre-match lobby): host authority, characters, ready gating, kick -----
## Register a joined peer in the host's room exactly as _on_hello does, but without a live
## socket (the WELCOME unicast needs a real ENet peer; the loopback test covers that path).
func _join_room(host: NetSession, enet_id: int, pid: int, pname: String) -> void:
	host._peer_to_player[enet_id] = pid
	host._player_names[pid] = pname
	host._player_characters[pid] = Characters.default_id_for_index(pid)
	host._player_ready[pid] = false
	host._next_player_id = maxi(host._next_player_id, pid + 1)
	host.broadcast_room_state()

func _test_room_state() -> void:
	print("[room] host-authoritative room: characters, ready gating, kick, character roster")
	# Wire codec round-trips (pure, no sockets).
	var drs := NetProtocol.decode_room_state(NetProtocol.encode_room_state("Den", 3, "cross", [
		{"id": 0, "name": "Host", "character": "cleaning", "ready": true, "host": true},
		{"id": 1, "name": "Bea", "character": "pet", "ready": false, "host": false},
	]))
	_check(drs["room_name"] == "Den" and drs["best_of"] == 3 and drs["map_id"] == "cross",
		"ROOM_STATE round-trips room name + length + map")
	_check(drs["players"].size() == 2 and drs["players"][1]["character"] == "pet"
		and drs["players"][1]["ready"] == false and drs["players"][0]["host"] == true,
		"ROOM_STATE round-trips each player's name/character/ready/host")
	_check(NetProtocol.decode_set_character(NetProtocol.encode_set_character("interior"))["character"] == "interior",
		"SET_CHARACTER round-trips the chosen character")
	_check(NetProtocol.decode_set_ready(NetProtocol.encode_set_ready(true))["ready"] == true,
		"SET_READY round-trips the ready flag")
	_check(NetProtocol.decode_kick(NetProtocol.encode_kick(2))["player_id"] == 2,
		"KICK round-trips the target player id")

	# Host-side room logic (real server bound to a private port; peers registered without sockets).
	var host := NetSession.new()
	_check(host.host(28123, "HostDev", 555, "Pico Den") == OK, "host opens a named room")
	_check(host.room_name == "Pico Den", "room name stored on the host")
	_check(host.lobby_players.size() == 1 and host.lobby_players[0]["host"], "host seeds its own room slot")
	_check(not host.all_ready(), "a lone host cannot start")
	_join_room(host, 101, 1, "Bea")
	_join_room(host, 102, 2, "Cyd")
	_check(host.lobby_players.size() == 3, "joined peers appear in the room snapshot")
	_check(not host.all_ready(), "start is gated while a joined peer is not ready")
	# Peers pick a character + ready up via dispatched client->host messages.
	host._dispatch(101, NetProtocol.encode_set_character("moving"))
	host._dispatch(101, NetProtocol.encode_set_ready(true))
	host._dispatch(102, NetProtocol.encode_set_ready(true))
	_check(host.all_ready(), "start enables once every non-host player is ready")
	var roster := host.build_roster(3, host.connected_player_ids())
	_check(roster[1]["character"] == "moving" and not roster[1]["bot"], "roster uses each player's chosen character")
	_check(roster[0]["character"] == host._player_characters[0], "host slot keeps the host's character")
	# Kick: a peer un-readying re-gates start; removing it shrinks the snapshot.
	host._dispatch(102, NetProtocol.encode_set_ready(false))
	_check(not host.all_ready(), "a peer toggling not-ready re-gates start")
	host._player_ready.erase(2); host._player_characters.erase(2)
	host._player_names.erase(2); host._peer_to_player.erase(102)
	host.broadcast_room_state()
	_check(host.lobby_players.size() == 2, "a kicked player leaves the room snapshot")
	host.close()

	# Client side: a KICK addressed to me fires `kicked`; a KICK for someone else is ignored.
	var client := NetSession.new()
	client.is_server = false
	client.local_player_id = 1
	var kicked_fired := [false]
	client.kicked.connect(func(): kicked_fired[0] = true)
	client._dispatch(1, NetProtocol.encode_kick(0))
	_check(not kicked_fired[0], "a KICK for another id is ignored by this client")
	client._dispatch(1, NetProtocol.encode_kick(1))
	_check(kicked_fired[0], "a client kicked by its own id fires the kicked signal")

func _defs(n: int, teamed: bool = false) -> Array:
	var out: Array = []
	for i in n:
		out.append({"team": (i % 2 if teamed else i), "name": "P%d" % (i + 1)})
	return out

func _ids(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append(i)
	return out

## Deterministic pseudo-input generator (the "recorded input sequence").
func _gen_cmd(rng: DetRng) -> int:
	var dirs := [Vector2i.ZERO, Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	var d: Vector2i = dirs[rng.below(dirs.size())]
	var place := rng.chance(1, 5)   # place ~20% of frames
	return InputCmd.encode(d, place)

# --- Criterion 1: determinism ----------------------------------------------
func _test_determinism() -> void:
	print("[determinism] identical input sequence -> bit-identical state on two clients")
	var seed_value := 1234
	var n := 8
	var a := LockstepSession.new(Simulation.new(_defs(n), 15, 13, seed_value), _ids(n), 2, 30)
	var b := LockstepSession.new(Simulation.new(_defs(n), 15, 13, seed_value), _ids(n), 2, 30)
	# Same recorded inputs fed to both "clients".
	var gen := DetRng.new(999)
	var frames := 600
	var hashes_match := true
	for _i in frames:
		for pid in _ids(n):
			var cmd := _gen_cmd(gen)
			a.remote_input(pid, a.current_frame, cmd)
			b.remote_input(pid, b.current_frame, cmd)
		var fa := a.current_frame
		var adv_a := a.try_advance()
		var adv_b := b.try_advance()
		if adv_a and adv_b and a.hash_at(fa) != b.hash_at(fa):
			hashes_match = false
	_check(a.current_frame == b.current_frame and a.current_frame > 0, "both clients advanced equally")
	_check(hashes_match, "per-frame state hashes identical across all frames")
	_check(a.sim.write_snapshot() == b.sim.write_snapshot(), "final serialized state is byte-identical")
	_check(a.sim.state_hash() == b.sim.state_hash(), "final state hash matches")
	# Tick clock advanced identically (and the round actually progressed).
	_check(a.sim.tick == b.sim.tick and a.sim.tick > 0, "deterministic tick count on both clients")

func _test_fixed_point_no_drift() -> void:
	print("[fixed-point] integer/Q16.16 timeline matches regardless of step batching")
	# A single sim advanced one-frame-at-a-time must equal one advanced in larger batches:
	# proves time is the integer tick count, not a float accumulation.
	var n := 4
	var s1 := Simulation.new(_defs(n), 15, 13, 7)
	var s2 := Simulation.new(_defs(n), 15, 13, 7)
	var gen := DetRng.new(55)
	var cmds: Array = []
	for f in 300:
		var per: Array = []
		for pid in _ids(n):
			per.append(_gen_cmd(gen))
		cmds.append(per)
	for f in cmds.size():
		for pid in _ids(n):
			var c: int = cmds[f][pid]
			s1.set_input(pid, InputCmd.dir(c), InputCmd.place(c))
		s1.step()
	# s2: identical inputs, identical per-frame stepping (control), must equal s1.
	for f in cmds.size():
		for pid in _ids(n):
			var c: int = cmds[f][pid]
			s2.set_input(pid, InputCmd.dir(c), InputCmd.place(c))
		s2.step()
	_check(s1.write_snapshot() == s2.write_snapshot(), "repeated runs are byte-identical (no float drift)")

# --- Criterion 2: input delay buffer + packet loss recovery -----------------
func _test_input_delay_absorbs_latency() -> void:
	print("[input-delay] inputs queued ahead by input_delay run without stalling")
	var n := 4
	var delay := 3
	var s := LockstepSession.new(Simulation.new(_defs(n), 15, 13, 3), _ids(n), delay, 10)
	var gen := DetRng.new(77)
	var frames := 120
	for _i in frames:
		# "Network" delivers each input `delay` frames before it is needed.
		for pid in _ids(n):
			s.local_input(pid, InputCmd.dir(_gen_cmd(gen)), false)
		s.try_advance()
	_check(s.advanced_frames == frames, "all frames advanced (latency fully absorbed)")
	_check(s.stall_frames == 0, "no stalls while inputs arrive on time")

func _test_packet_loss_bounded_recovery() -> void:
	print("[packet-loss] missing input stalls within bound, then recovers via prediction")
	var n := 4
	var max_stall := 5
	var s := LockstepSession.new(Simulation.new(_defs(n), 15, 13, 4), _ids(n), 0, max_stall)
	var hole := 8           # frame at which player 2's packet is "lost"
	# Provide every player's input for frames 0..hole, except player 2 at `hole`.
	for f in hole + 1:
		for pid in _ids(n):
			if f == hole and pid == 2:
				continue
			s.remote_input(pid, f, InputCmd.NONE)
	# Frames before the hole advance cleanly.
	for _i in hole:
		_check(s.try_advance(), "frame advanced before packet loss")
	# At the hole: stall up to the budget (each returns false), then recover.
	var stalls := 0
	while not s.try_advance():
		stalls += 1
		if stalls > max_stall + 2:
			break
	_check(stalls == max_stall, "stalled exactly max_stall frames before recovery")
	_check(s.stall_events == 1, "one stall event recorded")
	_check(s.predicted_inputs == 1, "exactly the missing input was predicted")
	_check(s.current_frame == hole + 1, "frame advanced after bounded recovery")

# --- Criterion 3: desync frame identification -------------------------------
func _test_desync_frame_identified() -> void:
	print("[desync] diverging input on one client is pinpointed to the exact frame")
	var n := 4
	var delay := 2
	var target := 20   # frame at which client B diverges
	var a := LockstepSession.new(Simulation.new(_defs(n), 15, 13, 5), _ids(n), delay, 60)
	var b := LockstepSession.new(Simulation.new(_defs(n), 15, 13, 5), _ids(n), delay, 60)
	var gen := DetRng.new(321)
	var frames := 60
	for _i in frames:
		for pid in _ids(n):
			var cmd := _gen_cmd(gen)
			var a_dir := InputCmd.dir(cmd)
			var a_place := InputCmd.place(cmd)
			var b_dir := a_dir
			var b_place := a_place
			# Client B diverges for player 0 on exactly the input bound for `target`:
			# different facing guarantees a state difference even if movement is blocked.
			if pid == 0 and a.current_frame + delay == target:
				a_dir = Vector2i.UP
				a_place = false
				b_dir = Vector2i.DOWN
				b_place = false
			a.local_input(pid, a_dir, a_place)
			b.local_input(pid, b_dir, b_place)
		a.try_advance()
		b.try_advance()
	var pre_target_match := true
	for f in target:
		if a.hash_at(f) != b.hash_at(f):
			pre_target_match = false
	_check(pre_target_match, "states identical on every frame before the divergence")
	var det := DesyncDetector.new()
	var found := det.compare(a.hashes, b.hashes, "clientB")
	_check(found == target, "desync detector reports the exact divergence frame (%d)" % target)
	_check(not det.in_sync(), "detector flags the session as out of sync")
	# A genuinely identical peer is reported in sync.
	var det2 := DesyncDetector.new()
	_check(det2.compare(a.hashes, a.hashes) == -1 and det2.in_sync(), "identical peer reported in sync")

# --- Criterion 4: snapshot save/restore (rollback-ready) --------------------
func _test_snapshot_restore_rollback() -> void:
	print("[snapshot] one-shot save/restore reproduces subsequent play bit-for-bit")
	var n := 4
	var sim := Simulation.new(_defs(n), 15, 13, 9)
	var gen := DetRng.new(2024)
	# Record a full input timeline up front.
	var total := 400
	var save_at := 150
	var cmds: Array = []
	for f in total:
		var per: Array = []
		for pid in _ids(n):
			per.append(_gen_cmd(gen))
		cmds.append(per)
	# Run to the save point and snapshot.
	for f in save_at:
		_apply_frame(sim, cmds[f])
	var snap := sim.write_snapshot()
	# Immediate round-trip: restore then re-serialize must be identical.
	var probe := Simulation.new(_defs(n), 15, 13, 9)
	probe.read_snapshot(snap)
	_check(probe.write_snapshot() == snap, "restore -> re-serialize is byte-identical")
	# Continue the original to the end.
	for f in range(save_at, total):
		_apply_frame(sim, cmds[f])
	var original_final := sim.write_snapshot()
	# Restore a fresh sim from the snapshot and replay the SAME remaining inputs.
	var restored := Simulation.new(_defs(n), 15, 13, 9)
	restored.read_snapshot(snap)
	for f in range(save_at, total):
		_apply_frame(restored, cmds[f])
	_check(restored.write_snapshot() == original_final, "restored sim + same inputs == original (rollback-ready)")
	_check(restored.state_hash() == sim.state_hash(), "restored final state hash matches original")

func _apply_frame(sim: Simulation, per: Array) -> void:
	for pid in per.size():
		var c: int = per[pid]
		sim.set_input(pid, InputCmd.dir(c), InputCmd.place(c))
	sim.step()

# --- Started-match wiring (NetMatch): networked play off the shared seed -----
## A roster like NetSession.build_roster produces: id-indexed, free-for-all teams, the first
## `humans` ids human and the rest bots, every slot a real character.
func _roster(total: int, humans: int) -> Array:
	var out: Array = []
	for i in total:
		out.append({
			"team": i,
			"bot": i >= humans,
			"character": Characters.default_id_for_index(i),
			"name": "P%d" % (i + 1),
		})
	return out

func _new_match(roster: Array, local_id: int, seed_v: int, delay: int, max_stall: int) -> NetMatch:
	var human_ids: Array = []
	var bot_ids: Array = []
	for i in roster.size():
		if roster[i]["bot"]:
			bot_ids.append(i)
		else:
			human_ids.append(i)
	return NetMatch.new(Simulation.new(roster, 15, 13, seed_v), local_id, human_ids, bot_ids, seed_v, delay, max_stall)

## Advance a match to (at least) `upto`, repeatedly calling advance so stall-budget recovery
## can accumulate across calls. Returns true if it reached the target without deadlocking.
func _drain(m: NetMatch, upto: int) -> bool:
	var guard := 0
	while m.current_frame < upto and guard < upto * 40:
		m.advance(64)
		guard += 1
	return m.current_frame >= upto

func _test_netmatch_started_determinism() -> void:
	print("[started-match] two peers off the same seed + relayed inputs stay byte-identical")
	var seed_v := 2468
	var roster := _roster(4, 2)   # players 0,1 human; 2,3 bots
	# Two independent peers (different local ids), each fed every human's input + local bots.
	var a := _new_match(roster, 0, seed_v, 0, 30)
	var b := _new_match(roster, 1, seed_v, 0, 30)
	var gen := DetRng.new(13)
	var frames := 400
	var hashes_match := true
	for f in frames:
		for pid in [0, 1]:
			var cmd := _gen_cmd(gen)
			a.apply_remote(f, pid, InputCmd.dir(cmd), InputCmd.place(cmd))
			b.apply_remote(f, pid, InputCmd.dir(cmd), InputCmd.place(cmd))
		a.advance(1)
		b.advance(1)
		if a.hash_at(f) != b.hash_at(f):
			hashes_match = false
	_check(a.current_frame == b.current_frame and a.current_frame == frames, "both peers advanced every tick")
	_check(hashes_match, "per-frame hashes identical across the whole started match")
	_check(a.sim.write_snapshot() == b.sim.write_snapshot(), "final state byte-identical (humans + bots)")
	_check(a.sim.tick > 0, "the match actually ran (tick %d)" % a.sim.tick)

func _test_netmatch_drop_recovery() -> void:
	print("[peer-drop] a dropped peer is predicted identically however/whenever peers detect it")
	var seed_v := 99
	var roster := _roster(4, 2)
	var drop_at := 40
	var target := 120
	# Three peers: A latches the drop early, B latches late, C never latches (pure stall budget).
	var a := _new_match(roster, 0, seed_v, 0, 5)
	var b := _new_match(roster, 0, seed_v, 0, 5)
	var c := _new_match(roster, 0, seed_v, 0, 5)
	var gen := DetRng.new(7)
	# Supply player 0 for every frame; player 1 only until it "drops" at drop_at.
	for f in target:
		var c0 := _gen_cmd(gen)
		for m in [a, b, c]:
			m.apply_remote(f, 0, InputCmd.dir(c0), InputCmd.place(c0))
		if f < drop_at:
			var c1 := _gen_cmd(gen)
			for m in [a, b, c]:
				m.apply_remote(f, 1, InputCmd.dir(c1), InputCmd.place(c1))
	a.mark_dropped(1)                 # latched immediately
	var reached_a := _drain(a, target)
	# B: advance to just past the drop on the stall budget, latch late, then finish.
	_drain(b, drop_at + 8)
	b.mark_dropped(1)
	var reached_b := _drain(b, target)
	# C: never latches — relies entirely on the bounded stall + repeat-last prediction.
	var reached_c := _drain(c, target)
	_check(reached_a and reached_b and reached_c, "no peer hangs after the drop (all reach the target frame)")
	_check(a.sim.write_snapshot() == b.sim.write_snapshot(), "early vs late latch reach identical state")
	_check(a.sim.write_snapshot() == c.sim.write_snapshot(), "latched vs stall-budget recovery reach identical state")
	_check(c.predicted_inputs > 0, "stall-budget peer predicted the dropped player's input")
	_check(a.sim.tick == target and c.sim.tick == target, "the round kept resolving past the drop")

# --- Networked best-of-N series: rounds + rematch stay byte-deterministic ----
## Two peers play a full best-of-N series the way Game.gd drives it networked: each round is a
## fresh NetMatch off the shared per-round seed (base + round index), the running score is
## recorded from each round's deterministic winner, and a rematch resets the score and replays.
## Asserts per-frame state-hash parity across every round of two back-to-back series, plus that
## the series mechanics (score, clinch, rematch reset) agree on both peers.
func _test_net_series_determinism() -> void:
	print("[series] best-of-N rounds + a rematch stay byte-identical across peers")
	var base_seed := 9090
	var best_of := 3
	var roster := _roster(4, 2)              # players 0,1 human; 2,3 bots
	# Each peer keeps its own deterministic series; only round results (identical) drive it.
	var series_a := MatchSeries.new(roster, best_of, base_seed, 15, 13)
	var series_b := MatchSeries.new(roster, best_of, base_seed, 15, 13)
	var gen_a := DetRng.new(111)
	var gen_b := DetRng.new(222)
	var parity := true
	var rounds := 0
	var series_done := 0
	var net_round := 0
	var net_a := _series_round_match(series_a, roster, 0)
	var net_b := _series_round_match(series_b, roster, 1)
	var guard := 0
	while series_done < 2 and guard < 200000:
		guard += 1
		# Lockstep: each peer samples its own human, relays it to the other tagged with the
		# shared round, applies bots locally, and advances one tick.
		if not net_a.sim.finished:
			var da := _series_dir(gen_a)
			var pa := gen_a.chance(1, 5)
			var fa := net_a.sample_local(da, pa)
			if fa >= 0:
				net_b.apply_remote(fa, 0, da, pa)
			net_a.advance(1)
		if not net_b.sim.finished:
			var db := _series_dir(gen_b)
			var pb := gen_b.chance(1, 5)
			var fb := net_b.sample_local(db, pb)
			if fb >= 0:
				net_a.apply_remote(fb, 1, db, pb)
			net_b.advance(1)
		if not (net_a.sim.finished and net_b.sim.finished):
			continue
		# Round resolved on both peers. Compare every shared frame's hash, then advance the
		# series identically on both and rebuild the next round (or rematch / stop).
		if not _series_hashes_equal(net_a, net_b):
			parity = false
		if net_a.sim.winner_team != net_b.sim.winner_team:
			parity = false
		rounds += 1
		series_a.record_round(net_a.sim.winner_team)
		series_b.record_round(net_b.sim.winner_team)
		if series_a.finished != series_b.finished or series_a.wins_for(0) != series_b.wins_for(0):
			parity = false
		net_round += 1
		if series_a.finished:
			series_done += 1
			if series_done == 1:
				# Rematch: same roster, score reset, fresh series replays deterministically.
				series_a.reset()
				series_b.reset()
			else:
				break
		net_a = _series_round_match(series_a, roster, 0)
		net_b = _series_round_match(series_b, roster, 1)
	_check(parity, "per-frame hashes + round winners identical across every round and the rematch")
	_check(rounds >= 2, "the series actually played multiple rounds (%d)" % rounds)
	_check(series_done == 2, "played a full series and a full rematch to completion")
	_check(series_a.round_index == series_b.round_index and series_a.team_wins == series_b.team_wins,
		"both peers agree on the final series score after the rematch")
	_test_net_dropped_bot_agreement()

## A peer that left becomes a deterministic bot in subsequent rounds. This only stays in lockstep
## while every peer agrees on the dropped set for a round (the reason ADVANCE carries a FROZEN
## snapshot): two peers that both build the slot as a bot are byte-identical, whereas a peer that
## built it as a still-live human (predicted input) would diverge. This guards that invariant.
func _test_net_dropped_bot_agreement() -> void:
	print("[series] a left peer rebuilt as a bot stays byte-identical when peers agree on the set")
	var seed_v := 31337
	var roster := _roster(4, 2)              # players 0,1 human; 2,3 bots
	# Both peers treat player 1 as dropped -> a bot (agreed frozen set). Only player 0 remains a
	# human; feed it the same input sequence to both peers. The botted player 1 + bots 2,3 are
	# computed locally from the shared seed, so both peers must stay byte-identical.
	var agree_a := _round_with_bots(roster, 0, seed_v, [1])
	var agree_b := _round_with_bots(roster, 0, seed_v, [1])
	var gen := DetRng.new(5)
	var parity := true
	for f in 200:
		var d := _series_dir(gen)
		agree_a.apply_remote(f, 0, d, false)
		agree_b.apply_remote(f, 0, d, false)
		agree_a.advance(1)
		agree_b.advance(1)
		if agree_a.hash_at(f) != agree_b.hash_at(f):
			parity = false
	_check(parity, "agreed dropped-as-bot set keeps both peers byte-identical")
	_check(agree_a.sim.write_snapshot() == agree_b.sim.write_snapshot(), "final state identical with the left peer botted")
	# Counter-check: a disagreeing build (player 1 left a live human with no input -> stalls then
	# predicts NONE) reaches a different state than the botted build — exactly what the frozen
	# per-round set prevents across peers.
	var disagree := _round_with_bots(roster, 0, seed_v, [])   # player 1 still a human here
	var gen2 := DetRng.new(5)
	for f in 200:
		var d := _series_dir(gen2)
		disagree.apply_remote(f, 0, d, false)
		disagree.advance(64)   # player 1 never sends -> bounded stall then predicted NONE
	_check(disagree.sim.write_snapshot() != agree_a.sim.write_snapshot(),
		"a disagreeing build (human vs bot) reaches a different state — why the set must be agreed")

func _round_with_bots(roster: Array, local_id: int, seed_v: int, extra_bots: Array) -> NetMatch:
	var human_ids: Array = []
	var bot_ids: Array = []
	for i in roster.size():
		if roster[i]["bot"] or i in extra_bots:
			bot_ids.append(i)
		else:
			human_ids.append(i)
	return NetMatch.new(Simulation.new(roster, 15, 13, seed_v), local_id, human_ids, bot_ids, seed_v)

func _series_round_match(series: MatchSeries, roster: Array, local_id: int) -> NetMatch:
	# Mirror Game._start_round_networked: build the round off the shared per-round seed.
	var human_ids: Array = []
	var bot_ids: Array = []
	for i in roster.size():
		if roster[i]["bot"]:
			bot_ids.append(i)
		else:
			human_ids.append(i)
	var sim := Simulation.new(roster, series.arena_w, series.arena_h, series.seed_for_round())
	return NetMatch.new(sim, local_id, human_ids, bot_ids, series.seed_for_round())

func _series_dir(rng: DetRng) -> Vector2i:
	match rng.below(5):
		1: return Vector2i.UP
		2: return Vector2i.DOWN
		3: return Vector2i.LEFT
		4: return Vector2i.RIGHT
	return Vector2i.ZERO

func _series_hashes_equal(a: NetMatch, b: NetMatch) -> bool:
	var top: int = mini(a.current_frame, b.current_frame)
	for f in top:
		if a.hashes.has(f) and b.hashes.has(f) and a.hash_at(f) != b.hash_at(f):
			return false
	return true
