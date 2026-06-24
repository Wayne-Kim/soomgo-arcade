class_name NetMatch
extends RefCounted
## Deterministic networked lockstep driver for a started match (opportunity-brief wiring).
##
## Ties NetSession's relayed inputs to the deterministic core Simulation so every device
## controls its own assigned player while the rest are bots, and all peers stay byte-identical:
##
##  - Local human input is queued `input_delay` ticks ahead (InputBuffer) so remote inputs for
##    the same tick have time to arrive; the caller broadcasts it over the wire.
##  - Remote human inputs are applied by absolute tick from NetSession.input_received.
##  - A tick only advances once EVERY live human's input for it is present — lockstep waits for
##    the slowest peer rather than diverging (edge case: latency near the budget).
##  - A dropped peer simply stops sending: after a bounded stall its input is predicted
##    (repeat-last, identical on every peer) so the match never hangs or desyncs.
##  - Empty roster slots are bots, computed locally each advanced tick from the (identical)
##    sim state, so no input is broadcast for them and no slot can desync.

const DEFAULT_INPUT_DELAY: int = NetBudget.INPUT_DELAY_TICKS
## Bounded stall (~0.5 s at 60 Hz) before a missing peer's input is predicted so play recovers.
const DEFAULT_MAX_STALL: int = 30

var sim: Simulation
var local_player_id: int
var human_ids: Array = []                 # player ids driven by a human (local or remote)
var bot_ids: Array = []                   # player ids driven by local deterministic AI
var input_delay: int
var max_stall_frames: int

var buffers: Dictionary = {}              # human player_id -> InputBuffer
var bots: Dictionary = {}                 # bot player_id -> AiController
var dropped: Dictionary = {}              # player_id -> true (left mid-match; input predicted)
var current_frame: int = 0
var consecutive_stalls: int = 0
var advanced_frames: int = 0
var predicted_inputs: int = 0
var hashes: Dictionary = {}               # frame -> state hash after that frame ran

## Emitted while a tick is blocked waiting on one or more peers' inputs (UI feedback).
signal waiting_on(player_ids: Array)

func _init(p_sim: Simulation, p_local_player_id: int, p_human_ids: Array, p_bot_ids: Array,
		seed_value: int, p_input_delay: int = DEFAULT_INPUT_DELAY, p_max_stall: int = DEFAULT_MAX_STALL) -> void:
	sim = p_sim
	local_player_id = p_local_player_id
	human_ids = p_human_ids.duplicate()
	bot_ids = p_bot_ids.duplicate()
	input_delay = maxi(0, p_input_delay)
	max_stall_frames = maxi(0, p_max_stall)
	for pid in human_ids:
		var buf := InputBuffer.new(input_delay)
		# Seed the initial delay window neutral on every peer so the match can start in lockstep
		# without anyone having sent inputs for frames 0..input_delay-1.
		for f in input_delay:
			buf.submit(f, InputCmd.NONE)
		buffers[pid] = buf
	for pid in bot_ids:
		bots[pid] = AiController.new(pid, seed_value)

## Queue the local human's input for this tick; it executes `input_delay` ticks ahead. Returns
## the absolute frame the input runs on (to broadcast over the wire), or -1 if not a human.
func sample_local(dir: Vector2i, place: bool, skill: bool = false) -> int:
	if not buffers.has(local_player_id):
		return -1
	var frame := current_frame + input_delay
	buffers[local_player_id].submit(frame, InputCmd.encode(dir, place, skill))
	return frame

## Apply a remote human input received for an explicit absolute frame.
func apply_remote(frame: int, player_id: int, dir: Vector2i, place: bool, skill: bool = false) -> void:
	if buffers.has(player_id):
		buffers[player_id].submit(frame, InputCmd.encode(dir, place, skill))

## Latch a player that left the match: from here on its missing inputs are predicted
## (repeat-last) immediately, with no stall. Deterministic across peers because prediction is
## timing-independent — the same repeat-last value fills the same frames everywhere, whether a
## peer latches early (via this call) or late (via the stall budget). Prevents the post-drop
## "every tick re-stalls" crawl while keeping all peers byte-identical.
func mark_dropped(player_id: int) -> void:
	if buffers.has(player_id):
		dropped[player_id] = true

## Human ids whose input for `frame` has not arrived yet (dropped players never block).
func _missing(frame: int) -> Array:
	var out: Array = []
	for pid in human_ids:
		if dropped.has(pid):
			continue
		if not buffers[pid].has(frame):
			out.append(pid)
	return out

## Advance up to `max_frames` whole ticks, stopping early on a stall. Returns frames advanced.
func advance(max_frames: int = 256) -> int:
	var n := 0
	while n < max_frames and _try_advance():
		n += 1
	return n

func _try_advance() -> bool:
	if sim.finished:
		return false
	var f := current_frame
	# Dropped players never arrive again: fill their frame with a repeat-last prediction so they
	# neither block the tick nor desync (identical value on every peer).
	for pid in dropped:
		if not buffers[pid].has(f):
			buffers[pid].submit(f, buffers[pid].predict(f))
	var missing := _missing(f)
	if not missing.is_empty():
		consecutive_stalls += 1
		if consecutive_stalls <= max_stall_frames:
			waiting_on.emit(missing)
			return false   # wait for the slowest peer within the stall budget
		# Recovery: stall budget exhausted (e.g. a dropped peer) -> predict the missing inputs.
		# repeat-last is deterministic and identical on every peer, so no desync.
		for pid in missing:
			buffers[pid].submit(f, buffers[pid].predict(f))
			predicted_inputs += 1
	# Apply human inputs from the buffers.
	for pid in human_ids:
		var cmd: int = buffers[pid].get_cmd(f)
		buffers[pid].last_cmd = cmd
		sim.set_input(pid, InputCmd.dir(cmd), InputCmd.place(cmd), InputCmd.skill(cmd))
	# Apply bot inputs, computed from the current (identical-across-peers) sim state.
	for pid in bot_ids:
		var mv: Dictionary = bots[pid].decide(sim)
		if mv["act"]:
			sim.set_input(pid, mv["dir"], mv["place"], mv["skill"])
	sim.step()
	hashes[f] = sim.state_hash()
	current_frame += 1
	consecutive_stalls = 0
	advanced_frames += 1
	return true

func hash_at(frame: int) -> int:
	return hashes.get(frame, 0)
