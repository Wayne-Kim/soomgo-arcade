class_name LockstepSession
extends RefCounted
## Deterministic lockstep driver tying the pieces together (acceptance criteria 1-4).
##
## - Advances the simulation in whole fixed ticks, one frame at a time, and ONLY when every
##   player's input for that frame is available -> identical input sequence yields identical
##   state on every client (criterion 1).
## - Local inputs are delayed `input_delay` frames to absorb network latency; missing inputs
##   cause a bounded stall, after which prediction (repeat last input) recovers play so a
##   dropped packet never deadlocks the match (criterion 2).
## - Records a state hash per simulated frame for desync diagnostics (criterion 3).
## - The simulation it drives is fully snapshot/restore-capable (criterion 4), leaving room
##   for a future rollback layer to rewind and re-simulate from a confirmed frame.

var sim: Simulation
var player_ids: Array = []
var input_delay: int
var max_stall_frames: int
var buffers: Dictionary = {}          # player_id -> InputBuffer
var current_frame: int = 0            # next frame to simulate (== sim.tick)
var hashes: Dictionary = {}           # frame -> state hash (after that frame ran)

# Diagnostics.
var consecutive_stalls: int = 0
var advanced_frames: int = 0
var stall_frames: int = 0
var stall_events: int = 0
var predicted_inputs: int = 0

func _init(p_sim: Simulation, p_player_ids: Array, p_input_delay: int = 2, p_max_stall: int = 30) -> void:
	sim = p_sim
	player_ids = p_player_ids.duplicate()
	input_delay = maxi(0, p_input_delay)
	max_stall_frames = maxi(0, p_max_stall)
	for pid in player_ids:
		var buf := InputBuffer.new(input_delay)
		# Frames inside the initial delay window have no real input yet: seed them neutral
		# so the match can start without stalling.
		for f in input_delay:
			buf.submit(f, InputCmd.NONE)
		buffers[pid] = buf

## Queue a locally-produced input; it executes `input_delay` frames in the future.
func local_input(player_id: int, dir: Vector2i, place: bool, skill: bool = false) -> int:
	var frame := current_frame + input_delay
	var cmd := InputCmd.encode(dir, place, skill)
	buffers[player_id].submit(frame, cmd)
	return frame

## Apply an input received from a peer for an explicit frame.
func remote_input(player_id: int, frame: int, cmd: int) -> void:
	buffers[player_id].submit(frame, cmd)

func _all_ready(frame: int) -> Array:
	var missing: Array = []
	for pid in player_ids:
		if not buffers[pid].has(frame):
			missing.append(pid)
	return missing

## Attempt to simulate the next frame. Returns true if it advanced, false if it stalled
## waiting for input (within the stall budget). Past the budget, missing inputs are
## predicted and the frame advances anyway (recovery).
func try_advance() -> bool:
	if sim.finished:
		return false
	var f := current_frame
	var missing := _all_ready(f)
	if not missing.is_empty():
		if consecutive_stalls == 0:
			stall_events += 1
		consecutive_stalls += 1
		stall_frames += 1
		if consecutive_stalls <= max_stall_frames:
			return false   # bounded wait for the late packet(s)
		# Recovery: stall budget exhausted -> predict missing inputs and keep going.
		for pid in missing:
			buffers[pid].submit(f, buffers[pid].predict(f))
			predicted_inputs += 1
	for pid in player_ids:
		var cmd: int = buffers[pid].get_cmd(f)
		buffers[pid].last_cmd = cmd
		sim.set_input(pid, InputCmd.dir(cmd), InputCmd.place(cmd), InputCmd.skill(cmd))
	sim.step()
	hashes[f] = sim.state_hash()
	current_frame += 1
	consecutive_stalls = 0
	advanced_frames += 1
	return true

## Drive up to `max_frames` advances, stopping early on a stall. Returns frames advanced.
func run(max_frames: int) -> int:
	var n := 0
	while n < max_frames and try_advance():
		n += 1
	return n

func hash_at(frame: int) -> int:
	return hashes.get(frame, 0)

func has_hash(frame: int) -> bool:
	return hashes.has(frame)
