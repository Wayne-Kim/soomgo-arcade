extends SceneTree
## Real ENet loopback test (acceptance criteria 1 & 2).
##
## Stands up a NetSession host + client in one process over 127.0.0.1, then:
##   1. confirms the client connects and is welcomed with the host's player id + seed,
##   2. measures a real input round-trip (PING/PONG) and asserts it is within NetBudget,
##   3. relays one input over the wire and shows both peers' deterministic Simulations
##      reach an identical state (lockstep parity) — the basis for 8-player realtime play.
##
## Run: Godot --headless --path . --script res://tests/net_loopback.gd

const PORT: int = 27099

var _host: NetSession
var _client: NetSession
var _frames: int = 0
var _fail: bool = false

var _welcomed: bool = false
var _seed: int = 0
var _client_player_id: int = -1
var _rtt_ms: float = -1.0
var _ping_sent: bool = false
var _relayed_input: Dictionary = {}

# Started-match (lockstep over the wire) phase.
var _phase: int = 0                 # 0 = connect/relay checks, 1 = started-match parity
var _host_match: NetMatch
var _client_match: NetMatch
var _host_rng := DetRng.new(101)
var _client_rng := DetRng.new(202)
var _match_iters: int = 0

func _initialize() -> void:
	print("== ENet loopback test ==")
	_host = NetSession.new()
	var herr := _host.host(PORT, "Host", 4242)
	if herr != OK:
		_ck(false, "host created (err %d)" % herr)
		quit(1)
		return
	_seed = _host.seed_value

	_client = NetSession.new()
	_client.welcomed.connect(func(pid, seed_v, _count):
		_welcomed = true
		_client_player_id = pid
		_seed = seed_v)
	_host.rtt_updated.connect(func(rtt): _rtt_ms = rtt)
	_host.input_received.connect(func(tick, pid, dir, place, _round, _skill):
		_relayed_input = {"tick": tick, "player_id": pid, "dir": dir, "place": place})

	# Build each peer's deterministic match when the host's START lands (host emits locally,
	# client emits when the START packet arrives over the wire).
	_host.match_started.connect(func(seed_v, roster, local_id, _best_of):
		_host_match = _build_match(roster, local_id, seed_v))
	_client.match_started.connect(func(seed_v, roster, local_id, _best_of):
		_client_match = _build_match(roster, local_id, seed_v))
	# Apply remote inputs received off the wire into each peer's match.
	_host.input_received.connect(func(tick, pid, dir, place, _round, _skill):
		if _host_match != null and pid != _host_match.local_player_id:
			_host_match.apply_remote(tick, pid, dir, place))
	_client.input_received.connect(func(tick, pid, dir, place, _round, _skill):
		if _client_match != null and pid != _client_match.local_player_id:
			_client_match.apply_remote(tick, pid, dir, place))

	var cerr := _client.join("127.0.0.1", PORT, "Client")
	if cerr != OK:
		_ck(false, "client created (err %d)" % cerr)
		quit(1)
		return

func _process(_dt: float) -> bool:
	_frames += 1
	_host.poll()
	_client.poll()

	if _phase == 0:
		return _process_connect_phase()
	return _process_match_phase()

func _process_connect_phase() -> bool:
	# Once welcomed, fire a ping from the host to measure round-trip.
	if _welcomed and not _ping_sent and _frames > 5:
		_ping_sent = true
		_host.send_ping()

	# Relay an input from the client after the ping has had time to return.
	if _ping_sent and _relayed_input.is_empty() and _frames > 12:
		_client.broadcast_input(10, _client_player_id, Vector2i.RIGHT, false)

	if _frames > 240 or (_welcomed and _rtt_ms >= 0.0 and not _relayed_input.is_empty()):
		_check_connection()
		# Transition to the started-match parity phase.
		_phase = 1
		_host.start_match()
		return false
	return false

## Drive both peers' NetMatch in lockstep over the real wire: each samples + broadcasts its
## own per-tick input, applies the other's relayed input, and advances. With the shared seed
## and identical relayed inputs every advanced tick must hash identically on both peers.
func _process_match_phase() -> bool:
	if _host_match == null or _client_match == null:
		if _frames > 600:
			_ck(false, "both peers built a NetMatch from the host's START")
			_finish()
			return true
		return false

	_match_iters += 1
	# Host drives player 0; client drives its assigned id. Each scripts only its OWN input.
	var hdir := _scripted_dir(_host_rng)
	var hframe := _host_match.sample_local(hdir, false)
	if hframe >= 0:
		_host.broadcast_input(hframe, _host_match.local_player_id, hdir, false)
	var cdir := _scripted_dir(_client_rng)
	var cframe := _client_match.sample_local(cdir, false)
	if cframe >= 0:
		_client.broadcast_input(cframe, _client_match.local_player_id, cdir, false)
	_host_match.advance(1)
	_client_match.advance(1)

	if _match_iters >= 220:
		_finish_match()
		return true
	return false

func _scripted_dir(rng: DetRng) -> Vector2i:
	match rng.below(5):
		1: return Vector2i.UP
		2: return Vector2i.DOWN
		3: return Vector2i.LEFT
		4: return Vector2i.RIGHT
	return Vector2i.ZERO

func _build_match(roster: Array, local_id: int, seed_v: int) -> NetMatch:
	var human_ids: Array = []
	var bot_ids: Array = []
	for i in roster.size():
		if roster[i].get("bot", false):
			bot_ids.append(i)
		else:
			human_ids.append(i)
	var sim := Simulation.new(roster, 15, 13, seed_v)
	return NetMatch.new(sim, local_id, human_ids, bot_ids, seed_v)

func _check_connection() -> void:
	_ck(_welcomed, "client connected and was welcomed by the host")
	_ck(_client_player_id >= 1, "host assigned the client a player id (%d)" % _client_player_id)
	_ck(_seed == 4242, "match seed propagated to the client over the wire")

	_ck(_rtt_ms >= 0.0, "measured a real round-trip (%.2f ms)" % _rtt_ms)
	_ck(NetBudget.within_budget(_rtt_ms), "loopback RTT %.2f ms is within the %.0f ms budget" % [_rtt_ms, NetBudget.TARGET_RTT_MS])

	_ck(not _relayed_input.is_empty(), "host received the client's relayed input")
	if not _relayed_input.is_empty():
		_ck(_relayed_input["dir"] == Vector2i.RIGHT and _relayed_input["player_id"] == _client_player_id,
			"relayed input matches what the client sent")
		# Lockstep parity: two seeded sims given the same relayed input reach the same state.
		var a := _build_sim()
		var b := _build_sim()
		a.set_input(0, _relayed_input["dir"], _relayed_input["place"])
		b.set_input(0, _relayed_input["dir"], _relayed_input["place"])
		for i in 8:
			a.step(Spec.TICK_DELTA)
			b.step(Spec.TICK_DELTA)
		_ck(a.get_player(0).cell == b.get_player(0).cell and a.tick == b.tick,
			"deterministic lockstep parity across peers")

## Parity of a fully started match: every tick both peers advanced must hash identically.
func _finish_match() -> void:
	_ck(_host_match != null and _client_match != null, "both peers entered the started match")
	_ck(_host_match.advanced_frames > 50 and _client_match.advanced_frames > 50,
		"both peers advanced a started match over the wire (host %d / client %d frames)" %
			[_host_match.advanced_frames, _client_match.advanced_frames])
	# Compare every frame both peers have simulated.
	var common := 0
	var mismatch := -1
	var top: int = mini(_host_match.current_frame, _client_match.current_frame)
	for f in top:
		if _host_match.hashes.has(f) and _client_match.hashes.has(f):
			common += 1
			if _host_match.hash_at(f) != _client_match.hash_at(f) and mismatch < 0:
				mismatch = f
	_ck(common > 50, "peers share %d simulated frames to compare" % common)
	_ck(mismatch < 0, "started-match lockstep parity: identical state hash on every shared frame"
		if mismatch < 0 else "started-match diverged at frame %d" % mismatch)
	_finish()

func _finish() -> void:
	_host.close()
	_client.close()
	print("ENet loopback: %s" % ("FAIL" if _fail else "PASS"))
	quit(1 if _fail else 0)

func _build_sim() -> Simulation:
	var defs := []
	for i in 4:
		defs.append({"team": i, "name": "P%d" % (i + 1)})
	return Simulation.new(defs, 15, 13, _seed)

func _ck(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		_fail = true
		printerr("  FAIL: ", msg)
