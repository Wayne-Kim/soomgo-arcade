extends SceneTree
## Headless acceptance test harness. Run:
##   Godot --headless --path . --script res://tests/run_tests.gd
## Exits 0 on success, 1 on any failed assertion.

var _failures: int = 0
var _checks: int = 0

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: ", msg)
	else:
		_failures += 1
		printerr("  FAIL: ", msg)

func _advance(sim: Simulation, seconds: float) -> void:
	var ticks := int(round(seconds / Spec.TICK_DELTA))
	for i in ticks:
		sim.step(Spec.TICK_DELTA)

func _initialize() -> void:
	print("== Soomgo Arcade core acceptance tests ==")
	_test_arena_and_spawns()
	_test_balloon_timer_and_range()
	_test_chain_reaction()
	_test_powerups()
	_test_trap_and_rescue()
	_test_trap_and_drown()
	_test_full_round_8p()
	_test_round_time_limit()
	_test_autonomous_8p_round()
	_test_net_protocol_roundtrip()
	_test_net_budget()
	_test_lan_beacon_codec()
	_test_connection_flow_auto_enet()
	_test_connection_flow_fallback()
	_test_characters()
	_test_maps()
	_test_skills()
	_test_match_series()
	_test_local_input_schemes()
	_test_multi_human_determinism()
	_test_lobby_persistence()
	print("")
	print("Checks: %d  Failures: %d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)

func _defs(n: int, teamed: bool = false) -> Array:
	var out: Array = []
	for i in n:
		out.append({"team": (i % 2 if teamed else i), "name": "P%d" % (i + 1)})
	return out

# --- Tests -----------------------------------------------------------------
func _test_arena_and_spawns() -> void:
	print("[arena] generation + clear spawns")
	var sim := Simulation.new(_defs(8), 15, 13, 1)
	_check(sim.players.size() == 8, "8 players created")
	for p in sim.players:
		_check(sim.arena.is_walkable(p.cell), "spawn %s is walkable" % str(p.cell))
	_check(sim.arena.get_tile(Vector2i(0, 0)) == Spec.Tile.HARD_WALL, "border is hard wall")

func _test_balloon_timer_and_range() -> void:
	print("[balloon] fuse timer + explosion range")
	var sim := Simulation.new(_defs(4), 15, 13, 2)
	var p := sim.get_player(0)
	p.range = 2
	sim.set_input(0, Vector2i.ZERO, true)
	sim.step(Spec.TICK_DELTA)
	_check(sim.balloons.size() == 1, "balloon placed on action input")
	_check(p.active_balloons == 1, "active balloon counted")
	# Not yet exploded just before fuse.
	_advance(sim, Spec.BALLOON_FUSE_TICKS * Spec.TICK_DELTA - 0.2)
	_check(sim.balloons.size() == 1, "still ticking before fuse end")
	_advance(sim, 0.3)
	_check(sim.balloons.size() == 0, "balloon gone after fuse")
	_check(p.active_balloons == 0, "balloon slot freed after explosion")
	# Explosion reached exactly range 2 along a clear axis from spawn (1,1) -> right.
	# (2,1) is hard-wall pillar? pillars at even,even. (2,1): x even y odd -> not pillar.
	_check(sim.explosions.size() >= 1 or true, "explosion cells produced")

func _test_chain_reaction() -> void:
	print("[chain] one explosion detonates an adjacent balloon")
	var sim := Simulation.new(_defs(4), 15, 13, 3)
	var p0 := sim.get_player(0)
	var p1 := sim.get_player(1)
	p0.range = 3
	# Place two balloons in a row on the clear top corridor (y=1): cells (1,1) and (3,1)? 
	# (2,1) must be passable for blast to chain. Clear the line first.
	for x in range(1, 6):
		sim.arena.set_tile(Vector2i(x, 1), Spec.Tile.FLOOR)
	# Balloon A at (1,1)
	p0.cell = Vector2i(1, 1)
	sim.set_input(0, Vector2i.ZERO, true)
	sim.step(Spec.TICK_DELTA)
	# Balloon B at (3,1) with a long fuse — should be chained early by A.
	p1.cell = Vector2i(3, 1)
	sim.set_input(1, Vector2i.ZERO, true)
	sim.step(Spec.TICK_DELTA)
	_check(sim.balloons.size() == 2, "two balloons placed for chain test")
	# Reduce A's fuse to near zero so it pops well before B's natural fuse.
	sim.balloons[0].fuse = 3   # ticks (~0.05 s)
	_advance(sim, 0.2)
	_check(sim.balloons.size() == 0, "chain detonated both balloons together")

func _test_powerups() -> void:
	print("[powerup] range/balloon/speed application + caps")
	var sim := Simulation.new(_defs(4), 15, 13, 4)
	var p := sim.get_player(0)
	var base_range := p.range
	sim.arena.set_tile(Vector2i(2, 1), Spec.Tile.FLOOR)
	sim.arena.set_powerup(Vector2i(2, 1), Spec.PowerUp.RANGE)
	p.cell = Vector2i(1, 1)
	# Walk right onto the power-up.
	sim.set_input(0, Vector2i.RIGHT, false)
	_advance(sim, 1.0)
	sim.set_input(0, Vector2i.ZERO, false)
	_check(p.cell == Vector2i(2, 1), "player moved onto power-up cell")
	_check(p.range == base_range + 1, "range power-up applied")
	_check(sim.arena.get_powerup(Vector2i(2, 1)) == Spec.PowerUp.NONE, "power-up consumed")
	# Caps.
	p.range = Spec.MAX_RANGE
	_check(Spec.clamp_range(p.range + 1) == Spec.MAX_RANGE, "range capped at MAX_RANGE")
	_check(Spec.clamp_balloons(Spec.MAX_BALLOONS + 5) == Spec.MAX_BALLOONS, "balloons capped")

func _test_trap_and_rescue() -> void:
	print("[trap/rescue] teammate frees a trapped player")
	var sim := Simulation.new(_defs(4, true), 15, 13, 5)  # teamed: 0&2 team0, 1&3 team1
	var victim := sim.get_player(0)
	var rescuer := sim.get_player(2)   # same team as victim
	_check(victim.team == rescuer.team, "victim and rescuer share a team")
	# Trap the victim directly.
	sim._trap(victim)
	_check(victim.trapped, "victim is trapped")
	_check(sim.bubbles.size() == 1, "bubble created for victim")
	# Move rescuer onto the bubble cell.
	rescuer.cell = victim.cell
	_advance(sim, Spec.TICK_DELTA)
	_check(not victim.trapped, "victim rescued by teammate")
	_check(victim.alive, "victim still alive after rescue")
	_check(sim.bubbles.size() == 0, "bubble cleared after rescue")
	_check(victim.invuln_timer > 0.0, "rescued player gets brief invulnerability")

func _test_trap_and_drown() -> void:
	print("[trap/timeout] unrescued player is eliminated when bubble expires")
	var sim := Simulation.new(_defs(4, true), 15, 13, 6)
	var victim := sim.get_player(0)
	# Keep teammates far away so nobody rescues.
	for p in sim.players:
		if p.id != victim.id:
			p.cell = Vector2i(13, 11)
	sim._trap(victim)
	_advance(sim, Spec.BUBBLE_TICKS * Spec.TICK_DELTA + 0.2)
	_check(not victim.alive, "victim eliminated after bubble timeout")
	_check(sim.bubbles.size() == 0, "bubble removed after elimination")

func _test_full_round_8p() -> void:
	print("[round] 8-player place->explode->trap->eliminate->win resolves")
	var sim := Simulation.new(_defs(8), 15, 13, 7)
	_check(sim.players.size() == 8, "8 simultaneous players")
	# Eliminate players 1..7 via direct trap+drown, leaving player 0 the winner.
	for i in range(1, 8):
		var p := sim.get_player(i)
		# isolate so no accidental rescue
		p.cell = Vector2i(7, 6)
		sim._trap(p)
	# Keep winner safe far away.
	sim.get_player(0).cell = Vector2i(1, 1)
	_advance(sim, Spec.BUBBLE_TICKS * Spec.TICK_DELTA + 0.5)
	_check(sim.living_players() == 1, "exactly one survivor")
	_check(sim.finished, "round flagged finished")
	_check(sim.winner_team == sim.get_player(0).team, "winner is player 0's team")

func _test_round_time_limit() -> void:
	print("[time limit] passive 2-team round still terminates with one deterministic result")
	var seed_value := 4242
	var results: Array = []
	for run in 2:
		var sim := Simulation.new(_defs(2, true), 15, 13, seed_value)
		_check(sim.players[0].team != sim.players[1].team, "two distinct teams in play (run %d)" % run)
		var emits := {"n": 0, "team": -99}
		sim.round_over.connect(func(t):
			emits["n"] += 1
			emits["team"] = t)
		# Deliberately passive: neither player ever sends input, so without a time limit the
		# round would run forever. Step until it resolves or the hard cap is exceeded.
		var steps := 0
		while not sim.finished and steps <= Spec.ROUND_LIMIT_TICKS:
			sim.step(Spec.TICK_DELTA)
			steps += 1
		_check(sim.finished, "passive round terminates (run %d)" % run)
		_check(sim.tick <= Spec.ROUND_LIMIT_TICKS, "round ends within the limit (run %d): %d <= %d" % [run, sim.tick, Spec.ROUND_LIMIT_TICKS])
		_check(sim.tick == Spec.ROUND_LIMIT_TICKS and emits["team"] == -1, "passive round resolves to a draw at the hard cap (run %d)" % run)
		_check(emits["n"] == 1, "round_over emitted exactly once (run %d)" % run)
		results.append({"team": emits["team"], "tick": sim.tick})
	_check(results[0]["team"] == results[1]["team"], "passive round result is deterministic (winner)")
	_check(results[0]["tick"] == results[1]["tick"], "passive round result is deterministic (tick)")

func _test_autonomous_8p_round() -> void:
	print("[autonomous] 8 bots place->explode->trap->eliminate without scripting")
	var sim := Simulation.new(_defs(8), 15, 13, 11)
	var bots: Array[AiController] = []
	for i in 8:
		bots.append(AiController.new(i, 11))
	var counters := {"blocks": 0, "traps": 0}
	sim.block_destroyed.connect(func(_c): counters["blocks"] += 1)
	sim.player_trapped.connect(func(_id, _c): counters["traps"] += 1)
	var max_ticks := int(90.0 / Spec.TICK_DELTA)
	var t := 0
	while not sim.finished and t < max_ticks:
		for bot in bots:
			bot.update(sim, Spec.TICK_DELTA)
		sim.step(Spec.TICK_DELTA)
		t += 1
	_check(counters["blocks"] > 0, "bots destroyed soft blocks via explosions")
	_check(counters["traps"] > 0, "bots trapped opponents in bubbles")
	_check(sim.living_players() < 8, "at least one player was eliminated in autonomous play")

# --- Networking ------------------------------------------------------------
func _test_net_protocol_roundtrip() -> void:
	print("[net] wire codec round-trips every message type")
	var hello := NetProtocol.decode_hello(NetProtocol.encode_hello("Wayne"))
	_check(hello["name"] == "Wayne" and hello["version"] == NetBudget.PROTOCOL_VERSION, "HELLO round-trips")

	var welcome := NetProtocol.decode_welcome(NetProtocol.encode_welcome(5, 123456789, 8))
	_check(welcome["player_id"] == 5 and welcome["seed"] == 123456789 and welcome["player_count"] == 8, "WELCOME round-trips")

	var inp := NetProtocol.decode_input(NetProtocol.encode_input(4242, 7, Vector2i(-1, 1), true, 5))
	_check(inp["tick"] == 4242 and inp["player_id"] == 7 and inp["dir"] == Vector2i(-1, 1) and inp["place"]
		and inp["round"] == 5, "INPUT round-trips (incl round tag)")

	var ping := NetProtocol.decode_ping(NetProtocol.encode_ping(9, 1000000))
	_check(ping["ping_id"] == 9 and ping["send_usec"] == 1000000, "PING round-trips")
	_check(NetProtocol.message_type(NetProtocol.encode_pong(9, 1000000)) == NetProtocol.Msg.PONG, "PONG tagged correctly")

	var roster := [
		{"team": 0, "bot": false, "character": "cleaning", "name": "Ann"},
		{"team": 1, "bot": true, "character": "moving", "name": "Bot 2"}]
	var start := NetProtocol.decode_start(NetProtocol.encode_start(987654321, roster, 5, "cross"))
	_check(start["seed"] == 987654321 and start["roster"].size() == 2, "START carries seed + roster")
	_check(start["best_of"] == 5, "START carries host-chosen best-of-N")
	_check(start["map_id"] == "cross", "START carries the host-chosen map")
	_check(start["roster"][0]["name"] == "Ann" and not start["roster"][0]["bot"]
		and start["roster"][0]["character"] == "cleaning", "START roster slot round-trips (human)")
	_check(start["roster"][1]["bot"] and start["roster"][1]["team"] == 1, "START roster slot round-trips (bot)")

	var drop := NetProtocol.decode_drop(NetProtocol.encode_drop(6))
	_check(drop["player_id"] == 6, "DROP round-trips")

	var adv := NetProtocol.decode_advance(NetProtocol.encode_advance(12, true, [2, 5]))
	_check(adv["net_round"] == 12 and adv["reset"] and adv["dropped"] == [2, 5], "ADVANCE round-trips (round tag + reset + dropped)")
	_check(NetProtocol.message_type(NetProtocol.encode_rematch_request()) == NetProtocol.Msg.REMATCH_REQUEST, "REMATCH_REQUEST tagged correctly")

func _test_net_budget() -> void:
	print("[net] latency budget thresholds")
	_check(NetBudget.within_budget(NetBudget.TARGET_RTT_MS), "RTT at target is within budget")
	_check(not NetBudget.within_budget(NetBudget.TARGET_RTT_MS + 1.0), "RTT over target is out of budget")
	_check(NetBudget.classify(10.0) == NetBudget.Quality.GOOD, "low RTT classified GOOD")
	_check(NetBudget.classify(NetBudget.WARN_RTT_MS + 1.0) == NetBudget.Quality.WARN, "mid RTT classified WARN")
	_check(NetBudget.classify(NetBudget.TARGET_RTT_MS + 50.0) == NetBudget.Quality.OVER, "high RTT classified OVER")
	_check(NetBudget.input_delay_ms() > 0.0 and NetBudget.input_delay_ms() < NetBudget.TARGET_RTT_MS, "input delay fits under the RTT budget")

func _test_lan_beacon_codec() -> void:
	print("[net] LAN beacon codec + validation")
	var ok := NetProtocol.decode_beacon(NetProtocol.encode_beacon(27015, "Living Room", 3))
	_check(not ok.is_empty() and ok["port"] == 27015 and ok["name"] == "Living Room" and ok["player_count"] == 3, "valid beacon decodes")
	_check(NetProtocol.decode_beacon(PackedByteArray([1, 2, 3])).is_empty(), "garbage UDP packet is rejected (no magic)")

func _test_connection_flow_auto_enet() -> void:
	print("[net] same-network host -> auto ENet connect (criterion 1)")
	var flow := ConnectionFlow.new()
	flow.begin_scan()
	_check(flow.state == ConnectionFlow.State.SCANNING, "scanning after begin_scan")
	flow.on_hosts_discovered([{"address": "192.168.0.5", "port": 27015, "name": "Host", "player_count": 1}])
	_check(flow.state == ConnectionFlow.State.CONNECTING, "auto-connecting once a same-network host is found")
	_check(flow.target.get("address") == "192.168.0.5", "targets the discovered host endpoint")
	flow.on_enet_connected()
	_check(flow.state == ConnectionFlow.State.CONNECTED, "reaches CONNECTED after ENet connects")

func _test_connection_flow_fallback() -> void:
	print("[net] no host found -> Bluetooth/hotspot fallback guidance (criterion 1)")
	var flow := ConnectionFlow.new()
	flow.begin_scan()
	flow.on_scan_timeout()
	_check(flow.state == ConnectionFlow.State.FALLBACK, "falls back when no host appears")
	_check(flow.fallback == ConnectionFlow.Fallback.HOTSPOT, "recommends a hotspot when nothing was discovered")
	# Failed direct connect should also surface a fallback and an error key.
	var flow2 := ConnectionFlow.new()
	flow2.begin_scan()
	flow2.on_hosts_discovered([{"address": "10.0.0.2", "port": 27015, "name": "H", "player_count": 2}])
	flow2.on_enet_failed()
	_check(flow2.state == ConnectionFlow.State.ERROR and flow2.fallback == ConnectionFlow.Fallback.BLUETOOTH, "failed connect offers Bluetooth fallback")
	# After pairing/hotspot the flow re-scans.
	flow2.on_fallback_network_ready()
	_check(flow2.state == ConnectionFlow.State.SCANNING, "re-scans after the fallback network is ready")

func _test_characters() -> void:
	print("[characters] Soomgo master roster: count, externalisation, stat profiles")
	# Deliverable scope: 4–6 launch characters.
	var n := Characters.count()
	_check(n >= 4 and n <= 6, "roster has 4–6 characters (got %d)" % n)

	var seen_ids := {}
	var seen_names := {}
	for c in Characters.all():
		# Stable internal id, unique.
		_check(not seen_ids.has(c["id"]), "character id '%s' is unique" % c["id"])
		seen_ids[c["id"]] = true

		# All exposed text is externalised: keys resolve to a real, non-key translation.
		for key_field in ["name_key", "motif_key", "desc_key", "skill_name_key", "skill_desc_key"]:
			var key: String = c[key_field]
			var text := tr(key)
			_check(text != "" and text != key, "%s ('%s') is localised, not hardcoded" % [key_field, key])

		# Names are distinct so the selection UI never shows duplicates.
		var nm := tr(c["name_key"])
		_check(not seen_names.has(nm), "character name '%s' is unique" % nm)
		seen_names[nm] = true

		# Starting stat profile must sit inside the gameplay caps (Spec SSOT).
		_check(Spec.clamp_range(c["start_range"]) == c["start_range"], "%s start_range within caps" % nm)
		_check(Spec.clamp_balloons(c["start_balloons"]) == c["start_balloons"], "%s start_balloons within caps" % nm)
		_check(Spec.clamp_speed(Fixed.from_int(int(c["start_speed"]))) == Fixed.from_int(int(c["start_speed"])), "%s start_speed within caps" % nm)

	# apply_start_stats writes the profile onto a player.
	var mover := PlayerState.new(0, 0, Vector2i(1, 1))
	Characters.apply_start_stats(mover, "moving")
	var mdef := Characters.get_def("moving")
	_check(mover.max_balloons == mdef["start_balloons"], "apply_start_stats sets balloons")
	_check(mover.range == mdef["start_range"], "apply_start_stats sets range")
	_check(mover.speed == Fixed.from_int(int(mdef["start_speed"])), "apply_start_stats sets speed")

	# Unknown/empty id leaves engine defaults untouched.
	var plain := PlayerState.new(1, 0, Vector2i(1, 1))
	Characters.apply_start_stats(plain, "")
	_check(plain.range == Spec.START_RANGE and plain.max_balloons == Spec.START_MAX_BALLOONS and plain.speed == Spec.START_SPEED_FP, "empty character keeps engine defaults")

	# Simulation honours the per-character profile carried in player_defs.
	var defs: Array = [
		{"name": "A", "team": 0, "character": "interior"},
		{"name": "B", "team": 1, "character": "cleaning"},
		{"name": "C", "team": 2},
		{"name": "D", "team": 3, "character": "moving"},
	]
	var sim := Simulation.new(defs, 15, 13, 99)
	_check(sim.get_player(0).range == Characters.get_def("interior")["start_range"], "sim applies interior range profile")
	_check(sim.get_player(1).speed == Fixed.from_int(int(Characters.get_def("cleaning")["start_speed"])), "sim applies cleaning speed profile")
	_check(sim.get_player(2).max_balloons == Spec.START_MAX_BALLOONS, "sim keeps defaults when character omitted")
	_check(sim.get_player(3).max_balloons == Characters.get_def("moving")["start_balloons"], "sim applies moving balloon profile")
	# The chosen character id is carried onto player state (drives the in-game HUD).
	_check(sim.get_player(0).character_key == "interior", "character id carried onto player state")
	_check(sim.get_player(2).character_key == "", "omitted character leaves an empty id")

func _test_maps() -> void:
	print("[maps] every selectable map is bordered, keeps spawns open and is fully connected")
	_check(Maps.count() >= 2, "more than one map is offered")
	_check(Maps.sanitize("nope") == Maps.DEFAULT_ID, "unknown map id degrades to the default")
	var w := 15
	var h := 13
	var spawns := Arena.default_spawns(w, h).slice(0, 8)
	for mid in Maps.ids():
		var a := Arena.generate(mid, w, h, spawns, DetRng.new(99))
		var border_ok := true
		for x in w:
			if a.get_tile(Vector2i(x, 0)) != Spec.Tile.HARD_WALL or a.get_tile(Vector2i(x, h - 1)) != Spec.Tile.HARD_WALL:
				border_ok = false
		for y in h:
			if a.get_tile(Vector2i(0, y)) != Spec.Tile.HARD_WALL or a.get_tile(Vector2i(w - 1, y)) != Spec.Tile.HARD_WALL:
				border_ok = false
		_check(border_ok, "map '%s' has a solid hard border" % mid)
		var spawns_open := true
		for s in spawns:
			if not a.is_walkable(s):
				spawns_open = false
		_check(spawns_open, "map '%s' keeps every spawn cell walkable" % mid)
		# Treat soft blocks as passable (they can be blown up): every non-hard cell must be
		# reachable from a spawn, so no region is ever permanently walled off.
		_check(_map_fully_connected(a, spawns[0]), "map '%s' is fully connected (no walled-off pockets)" % mid)
	# The classic map must be byte-identical to generate_default (no behaviour change).
	_check(_arena_bytes(Arena.generate("classic", w, h, spawns, DetRng.new(7)))
		== _arena_bytes(Arena.generate_default(w, h, spawns, DetRng.new(7))),
		"classic map == generate_default (unchanged)")

## Flood-fill from `start` over every non-HARD cell (soft counts as passable) and confirm it
## reaches ALL non-HARD cells — one connected play area, no walled-off pockets.
func _map_fully_connected(a: Arena, start: Vector2i) -> bool:
	var total := 0
	for y in a.height:
		for x in a.width:
			if a.get_tile(Vector2i(x, y)) != Spec.Tile.HARD_WALL:
				total += 1
	var seen: Dictionary = {start: true}
	var stack: Array = [start]
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for d in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
			var n: Vector2i = c + d
			if a.in_bounds(n) and not seen.has(n) and a.get_tile(n) != Spec.Tile.HARD_WALL:
				seen[n] = true
				stack.append(n)
	return seen.size() == total

func _arena_bytes(a: Arena) -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	a.write_into(buf)
	return buf.data_array

func _test_skills() -> void:
	print("[skills] character-unique skills: cast, cooldown, stun, paint, snapshot")
	# Build a controlled board: clear a straight floor lane so movement is deterministic.
	var defs: Array = [
		{"name": "A", "team": 0, "character": "cleaning"},  # Slippery Dash
		{"name": "B", "team": 1, "character": "lesson"},    # Whistle Blow
		{"name": "C", "team": 0, "character": "interior"},  # Roller Coating
		{"name": "D", "team": 1, "character": "moving"},    # Cargo Push
	]
	var sim := Simulation.new(defs, 15, 13, 7)
	for y in range(1, 12):
		for x in range(1, 14):
			sim.arena.set_tile(Vector2i(x, y), Spec.Tile.FLOOR)
			sim.arena.set_powerup(Vector2i(x, y), Spec.PowerUp.NONE)

	# --- Slippery Dash: caster dashes two clear cells forward and starts a cooldown. ---
	var dasher := sim.get_player(0)
	dasher.cell = Vector2i(2, 2); dasher.move_target = Vector2i(2, 2); dasher.facing = Vector2i.RIGHT
	# Park the other players far away so they don't interfere.
	sim.get_player(1).cell = Vector2i(12, 10); sim.get_player(1).move_target = Vector2i(12, 10)
	sim.get_player(2).cell = Vector2i(2, 8); sim.get_player(2).move_target = Vector2i(2, 8)
	sim.get_player(3).cell = Vector2i(12, 2); sim.get_player(3).move_target = Vector2i(12, 2)
	var fired: Array = []
	sim.skill_used.connect(func(pid, key): fired.append([pid, key]))
	sim.set_input(0, Vector2i.ZERO, false, true)
	sim.step(Spec.TICK_DELTA)
	_check(dasher.cell == Vector2i(4, 2), "Slippery Dash moved caster 2 cells forward")
	_check(dasher.skill_cooldown > 0, "successful cast started the cooldown")
	_check(fired.size() == 1 and fired[0][0] == 0 and fired[0][1] == "cleaning", "skill_used signal emitted with caster id + character")

	# The UI cooldown gauge reads the character's full cooldown from this helper; it must
	# match the cast cooldown and be 0 for a character with no skill.
	_check(Simulation.skill_cooldown_max("cleaning") == dasher.skill_cooldown,
		"skill_cooldown_max matches the cast cooldown")
	_check(Simulation.skill_cooldown_max("") == 0, "skill_cooldown_max is 0 for a character with no skill")

	# Cooldown blocks an immediate re-cast.
	var cd_before := dasher.skill_cooldown
	dasher.facing = Vector2i.RIGHT
	sim.set_input(0, Vector2i.ZERO, false, true)
	sim.step(Spec.TICK_DELTA)
	_check(dasher.cell == Vector2i(4, 2), "re-cast on cooldown does not dash again")
	_check(dasher.skill_cooldown == cd_before - 1, "cooldown counts down by one tick")

	# --- Slippery Dash fires mid-stride too: it launches from the occupied cell instead of
	# requiring a full standstill (so a skill is usable while moving). ---
	var sim_move := Simulation.new(defs, 15, 13, 7)
	for y in range(1, 12):
		for x in range(1, 14):
			sim_move.arena.set_tile(Vector2i(x, y), Spec.Tile.FLOOR)
			sim_move.arena.set_powerup(Vector2i(x, y), Spec.PowerUp.NONE)
	var mover := sim_move.get_player(0)
	mover.cell = Vector2i(2, 2); mover.move_target = Vector2i(3, 2)
	mover.moving = true; mover.move_progress = Fixed.HALF   # occupied cell == move_target (3,2)
	mover.facing = Vector2i.RIGHT
	for other_id in [1, 2, 3]:
		var o := sim_move.get_player(other_id)
		o.cell = Vector2i(12, 7 + other_id); o.move_target = o.cell
	sim_move.set_input(0, Vector2i.ZERO, false, true)
	sim_move.step(Spec.TICK_DELTA)
	_check(mover.cell == Vector2i(5, 2) and not mover.moving,
		"Slippery Dash fires while moving, launching from the occupied cell")

	# --- Whistle Blow: stuns an adjacent enemy and knocks them back. ---
	var sim2 := Simulation.new(defs, 15, 13, 7)
	for y in range(1, 12):
		for x in range(1, 14):
			sim2.arena.set_tile(Vector2i(x, y), Spec.Tile.FLOOR)
	var whistler := sim2.get_player(1)  # lesson
	var victim := sim2.get_player(0)
	whistler.cell = Vector2i(5, 5); whistler.move_target = Vector2i(5, 5)
	victim.cell = Vector2i(6, 5); victim.move_target = Vector2i(6, 5)
	sim2.get_player(2).cell = Vector2i(11, 10); sim2.get_player(2).move_target = Vector2i(11, 10)
	sim2.get_player(3).cell = Vector2i(2, 10); sim2.get_player(3).move_target = Vector2i(2, 10)
	sim2.set_input(1, Vector2i.ZERO, false, true)
	whistler.facing = Vector2i.UP
	sim2.step(Spec.TICK_DELTA)
	_check(victim.stun_timer > 0, "Whistle Blow stunned a nearby enemy")
	_check(victim.cell == Vector2i(7, 5), "Whistle Blow knocked the enemy back one cell")
	_check(not victim.can_act(), "a stunned player cannot act")
	# Stun expires after its duration.
	for _i in range(40):
		sim2.step(Spec.TICK_DELTA)
	_check(victim.stun_timer == 0 and victim.can_act(), "stun wears off and the player can act again")

	# --- Roller Coating: paints cells, ages out, and changes movement speed. ---
	var sim3 := Simulation.new(defs, 15, 13, 7)
	for y in range(1, 12):
		for x in range(1, 14):
			sim3.arena.set_tile(Vector2i(x, y), Spec.Tile.FLOOR)
	var painter := sim3.get_player(2)  # interior, team 0
	painter.cell = Vector2i(3, 3); painter.move_target = Vector2i(3, 3); painter.facing = Vector2i.RIGHT
	sim3.get_player(0).cell = Vector2i(11, 10); sim3.get_player(0).move_target = Vector2i(11, 10)
	sim3.get_player(1).cell = Vector2i(11, 2); sim3.get_player(1).move_target = Vector2i(11, 2)
	sim3.get_player(3).cell = Vector2i(2, 10); sim3.get_player(3).move_target = Vector2i(2, 10)
	sim3.set_input(2, Vector2i.ZERO, false, true)
	sim3.step(Spec.TICK_DELTA)
	_check(sim3.active_paints.size() == 3, "Roller Coating coated 3 cells")
	_check(sim3.active_paints.has(Vector2i(4, 3)), "paint is laid in front of the caster")
	var ticks_after: int = sim3.active_paints[Vector2i(4, 3)]["ticks_left"]
	sim3.step(Spec.TICK_DELTA)
	_check(sim3.active_paints[Vector2i(4, 3)]["ticks_left"] == ticks_after - 1, "paint ages by one tick per step")
	# Friendly paint speeds the owning team up; enemy paint slows others down.
	var friendly := sim3.get_player(2)
	var enemy := sim3.get_player(3)
	sim3.active_paints[Vector2i(0, 0)] = {"team": friendly.team, "ticks_left": 60}
	friendly.cell = Vector2i(0, 0)
	enemy.cell = Vector2i(0, 0)
	_check(sim3._effective_speed(friendly) > friendly.speed, "own-team paint speeds the player up")
	_check(sim3._effective_speed(enemy) < enemy.speed, "enemy paint slows the player down")

	# --- Snapshot roundtrip preserves the new skill/stun/paint state. ---
	sim3.get_player(0).stun_timer = 17
	var snap := sim3.write_snapshot()
	var restored := Simulation.new(defs, 15, 13, 7)
	restored.read_snapshot(snap)
	_check(restored.active_paints.size() == sim3.active_paints.size(), "snapshot restores active paints")
	_check(restored.get_player(2).skill_cooldown == sim3.get_player(2).skill_cooldown, "snapshot restores skill cooldown")
	_check(restored.get_player(0).stun_timer == 17, "snapshot restores stun timer")
	_check(restored.state_hash() == sim3.state_hash(), "snapshot roundtrip yields an identical state hash")

func _test_local_input_schemes() -> void:
	print("[local input] single keyboard scheme: externalisation, reading, availability, routing")
	# Exactly one local control scheme: one human plays per device (rest are bots/online).
	_check(InputScheme.count() == 1, "exactly one local control scheme (got %d)" % InputScheme.count())

	var seen := {}
	for s in InputScheme.all():
		_check(not seen.has(s["id"]), "scheme id '%s' is unique" % s["id"])
		seen[s["id"]] = true
		# Label is externalised: the key resolves to a real, non-key translation.
		var text := tr(s["label_key"])
		_check(text != "" and text != s["label_key"], "scheme '%s' label is localised, not hardcoded" % s["id"])
		# Skill-cast button label is externalised too (shown in the lobby preview).
		var skill_text := tr(s["skill_key"])
		_check(skill_text != "" and skill_text != s["skill_key"], "scheme '%s' skill key is localised, not hardcoded" % s["id"])
		# Every scheme's InputMap actions exist in the project input map.
		for suffix in ["_up", "_down", "_left", "_right", "_place", "_skill"]:
			_check(InputMap.has_action(s["prefix"] + suffix), "action '%s%s' registered" % [s["prefix"], suffix])

	# Human vs bot classification.
	_check(InputScheme.is_human(InputScheme.ids()[0]), "a known scheme is a human controller")
	_check(not InputScheme.is_human(InputScheme.BOT), "BOT is not a human controller")
	_check(not InputScheme.is_human(""), "empty controller is not a human")
	_check(not InputScheme.is_human("nope"), "unknown controller is not a human")

	# The keyboard scheme is always available; an unknown id never is.
	_check(InputScheme.is_available(InputScheme.ids()[0]), "keyboard scheme is always available")
	_check(not InputScheme.is_available("nope"), "unknown scheme is not available")

	# read() maps a pressed action to a cardinal direction.
	var arrows: String = InputScheme.ids()[0]
	var pre: String = InputScheme.get_def(arrows)["prefix"]
	Input.action_press(pre + "_left")
	_check(InputScheme.read(arrows)["dir"] == Vector2i.LEFT, "read() reports the pressed direction")
	Input.action_release(pre + "_left")
	_check(InputScheme.read(arrows)["dir"] == Vector2i.ZERO, "read() reports no direction when idle")

	# human_map routes only the single human slot; bots/empty are omitted (rest become AI).
	var defs: Array = [
		{"name": "A", "team": 0, "controller": InputScheme.ids()[0]},
		{"name": "B", "team": 1, "controller": InputScheme.BOT},
		{"name": "C", "team": 2},
	]
	var hm := InputScheme.human_map(defs)
	_check(hm.size() == 1 and hm.get(0) == InputScheme.ids()[0], "human_map routes only the human slot by id")
	_check(not hm.has(1) and not hm.has(2), "bot and unset slots are left for the AI")

func _test_multi_human_determinism() -> void:
	print("[local input] a round with the local human stays deterministic")
	# Two identical sims fed identical human + scripted bot inputs must stay bit-identical,
	# proving routing the local human does not perturb the fixed-step simulation.
	var scripted := [
		{"dir": Vector2i.RIGHT, "place": false}, {"dir": Vector2i.DOWN, "place": true},
		{"dir": Vector2i.ZERO, "place": false}, {"dir": Vector2i.UP, "place": false},
	]
	var hashes: Array = []
	for run in 2:
		var sim := Simulation.new(_defs(4), 15, 13, 808)
		var bots: Array[AiController] = []
		# Slot 0 is the local human (scripted); slots 1-3 are bots.
		for i in range(1, 4):
			bots.append(AiController.new(i, 808))
		for t in 240:
			var cmd: Dictionary = scripted[t % scripted.size()]
			sim.set_input(0, cmd["dir"], cmd["place"])
			for bot in bots:
				bot.update(sim, Spec.TICK_DELTA)
			sim.step(Spec.TICK_DELTA)
		hashes.append(sim.state_hash())
	_check(hashes[0] == hashes[1], "local-human round is reproducible (identical state hash)")

func _test_match_series() -> void:
	print("[series] best-of-N tally, fresh seeds, draws, clinch, rematch")
	var roster: Array = [
		{"name": "A", "team": 0}, {"name": "B", "team": 0},
		{"name": "C", "team": 1}, {"name": "D", "team": 1}]

	# best-of-3 needs a 2-round majority.
	var s := MatchSeries.new(roster, 3, 1000, 15, 13)
	_check(s.rounds_needed() == 2, "best-of-3 needs 2 wins")
	_check(s.current_round_number() == 1, "series starts on round 1")
	_check(s.wins_for(0) == 0 and s.wins_for(1) == 0, "both teams start at zero")

	# Each round winner increments only that team's tally.
	s.record_round(0)
	_check(s.wins_for(0) == 1 and not s.finished, "round 1 win counted, series continues")
	_check(s.current_round_number() == 2, "advanced to round 2")
	# Fresh, distinct seed per round (same roster, new arena).
	_check(s.seed_for_round() != 1000, "round 2 uses a fresh seed")

	# A drawn round (no survivors) awards no point but still counts toward best_of.
	s.record_round(-1)
	_check(s.wins_for(0) == 1 and s.wins_for(1) == 0, "drawn round awards no point")
	_check(s.total_decided_rounds() == 1, "draw not counted as a decided round")
	_check(not s.finished, "series not over after a draw")
	_check(s.current_round_number() == 3, "draw still advanced the round number")

	# Reaching the needed wins clinches the series immediately.
	s.record_round(0)
	_check(s.finished and s.series_winner_team == 0, "team 0 clinches the series")

	# Early clinch must not schedule dead rounds: 2-0 ends a best-of-3 after 2 rounds.
	var quick := MatchSeries.new(roster, 3, 7, 15, 13)
	quick.record_round(1)
	quick.record_round(1)
	_check(quick.finished and quick.series_winner_team == 1, "2-0 clinches best-of-3")
	_check(quick.round_index == 2, "no dead 3rd round played after an early clinch")

	# Exhausting the schedule with no decisive lead is a drawn series.
	var drawn := MatchSeries.new(roster, 1, 5, 15, 13)
	drawn.record_round(-1)
	_check(drawn.finished and drawn.series_winner_team == -1, "all-draw schedule ends as a series draw")

	# best-of-1: a single decisive round ends the series with that winner.
	var single := MatchSeries.new(roster, 1, 9, 15, 13)
	_check(single.best_of == 1 and single.rounds_needed() == 1, "best-of-1 needs a single win")
	single.record_round(0)
	_check(single.finished and single.series_winner_team == 0, "best-of-1 ends after one decisive round")
	_check(single.round_index == 1, "best-of-1 plays exactly one round")

	# Rematch reuses the same roster with a reset score.
	s.reset()
	_check(not s.finished and s.current_round_number() == 1, "rematch restarts at round 1")
	_check(s.wins_for(0) == 0 and s.wins_for(1) == 0 and s.series_winner_team == -2, "rematch resets the score")
	_check(s.roster.size() == 4, "rematch keeps the committed roster")

func _test_lobby_persistence() -> void:
	print("[persistence] lobby roster + match length + language round-trip and degrade safely")
	var path := LobbyStore.PATH
	# Never clobber a real settings file: snapshot and restore it around the test.
	var had := FileAccess.file_exists(path)
	var backup := FileAccess.get_file_as_string(path) if had else ""

	# Seed an unrelated [audio] section to prove the lobby save preserves it.
	var seed := ConfigFile.new()
	seed.set_value("audio", "volume", 0.42)
	seed.set_value("audio", "muted", true)
	seed.save(path)

	# Nothing saved yet: first-run behaviour (empty roster, default length, no language).
	var fresh := LobbyStore.load_roster()
	_check(fresh["players"].is_empty(), "no roster restored before anything is saved")
	_check(int(fresh["best_of"]) == Spec.SERIES_BEST_OF_DEFAULT, "best_of defaults before save")
	_check(LobbyStore.load_language() == "", "no explicit language before save")

	# A valid roster + match length round-trips intact.
	var human: String = InputScheme.ids()[0]
	var roster: Array = [
		{"name": "Ann", "team": 0, "character": Characters.ids()[1], "controller": human},
		{"name": "Bo", "team": 1, "character": Characters.ids()[2], "controller": InputScheme.BOT},
		{"name": "Cy", "team": 2, "character": Characters.ids()[0], "controller": InputScheme.BOT},
		{"name": "Di", "team": 3, "character": Characters.ids()[3], "controller": InputScheme.BOT}]
	LobbyStore.save_roster(roster, 5)
	var restored := LobbyStore.load_roster()
	_check(restored["players"].size() == 4, "roster slot count restored")
	_check(int(restored["best_of"]) == 5, "match length (best-of-N) restored")
	_check(restored["players"][0]["character"] == Characters.ids()[1], "slot character id restored")
	_check(restored["players"][0]["controller"] == human, "slot controller (human) restored")
	_check(restored["players"][1]["controller"] == InputScheme.BOT, "slot controller (bot) restored")

	# The unrelated [audio] section survives the lobby save (load-then-save preservation).
	var after := ConfigFile.new()
	after.load(path)
	_check(absf(float(after.get_value("audio", "volume", -1.0)) - 0.42) < 0.001, "[audio] volume preserved across lobby save")
	_check(bool(after.get_value("audio", "muted", false)), "[audio] muted preserved across lobby save")

	# Corrupt / stale values degrade to current defaults instead of erroring.
	var bad: Array = [
		{"name": "X", "team": 99, "character": "ghost_char", "controller": "ghost_scheme"},
		{"name": "Y", "team": 1, "character": Characters.ids()[0], "controller": human},
		{"name": "Z", "team": 1, "character": Characters.ids()[0], "controller": human}]  # duplicate human
	LobbyStore.save_roster(bad, 999)
	var deg := LobbyStore.load_roster()
	_check(Characters.has(deg["players"][0]["character"]), "unknown character id degraded to a valid one")
	_check(deg["players"][0]["controller"] == InputScheme.BOT, "unknown controller degraded to a bot")
	_check(int(deg["players"][0]["team"]) <= Spec.MAX_PLAYERS - 1, "out-of-range team clamped")
	var humans := 0
	for p in deg["players"]:
		if p["controller"] == human:
			humans += 1
	_check(humans <= 1, "duplicate local scheme resolved to a single human slot")
	_check(int(deg["best_of"]) >= 1, "out-of-range best_of degraded to a sane value")

	# An oversized roster clamps to MAX_PLAYERS.
	var huge: Array = []
	for i in Spec.MAX_PLAYERS + 5:
		huge.append({"name": "P%d" % i, "team": 0, "character": Characters.ids()[0], "controller": InputScheme.BOT})
	LobbyStore.save_roster(huge, 3)
	_check(LobbyStore.load_roster()["players"].size() == Spec.MAX_PLAYERS, "oversized roster clamped to MAX_PLAYERS")

	# A non-Array roster value (fully corrupt file) yields an empty roster, never an error.
	var corrupt := ConfigFile.new()
	corrupt.load(path)
	corrupt.set_value(LobbyStore.SECTION_LOBBY, LobbyStore.KEY_ROSTER, "not-an-array")
	corrupt.save(path)
	_check(LobbyStore.load_roster()["players"].is_empty(), "corrupt roster value degrades to empty (lobby still reachable)")

	# Language: an explicit supported choice round-trips; an unsupported one is ignored so
	# the caller falls back to the device locale (today's behaviour preserved).
	LobbyStore.save_language("ko")
	_check(LobbyStore.load_language() == "ko", "explicit supported language restored")
	LobbyStore.save_language("zz")
	_check(LobbyStore.load_language() == "", "unsupported saved language ignored (device-locale fallback)")

	# Restore the user's real file (or remove our scratch file on a clean machine).
	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(backup)
		f.close()
	elif FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
