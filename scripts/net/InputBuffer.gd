class_name InputBuffer
extends RefCounted
## One player's input timeline, indexed by the absolute frame in which the input executes
## (acceptance criterion 2: 입력 지연 버퍼). Local inputs are scheduled `input_delay` frames
## ahead so packets have time to arrive over a normal wireless link before their frame runs.
## On packet loss the last confirmed command is reused as a prediction so the session can
## recover within a bounded stall instead of freezing forever.

var input_delay: int
var _by_frame: Dictionary = {}        # frame -> encoded command
var last_cmd: int = InputCmd.NONE     # most recent confirmed command (used for prediction)
var newest_frame: int = -1

func _init(delay: int) -> void:
	input_delay = delay

func submit(frame: int, cmd: int) -> void:
	_by_frame[frame] = cmd
	if frame > newest_frame:
		newest_frame = frame

func has(frame: int) -> bool:
	return _by_frame.has(frame)

func get_cmd(frame: int) -> int:
	return _by_frame.get(frame, InputCmd.NONE)

## Predicted command for a missing frame: repeat the last confirmed input.
func predict(_frame: int) -> int:
	return last_cmd
