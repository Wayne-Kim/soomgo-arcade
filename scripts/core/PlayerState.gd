class_name PlayerState
extends RefCounted
## Per-player runtime state. Movement is tile-stepped: a player slides from `cell`
## to `move_target` over time, which keeps everything grid-aligned and deterministic.

var id: int
var team: int
var display_name: String = ""
var character_key: String = ""          # Characters.gd id; drives the starting stat profile

var cell: Vector2i
var move_target: Vector2i
var moving: bool = false
var move_progress: int = 0               # Q16.16, 0..Fixed.ONE from `cell` toward `move_target`
var facing: Vector2i = Vector2i.DOWN

# Stats (mutated by power-ups).
var range: int = Spec.START_RANGE
var max_balloons: int = Spec.START_MAX_BALLOONS
var speed: int = Spec.START_SPEED_FP     # Q16.16 cells/second
var active_balloons: int = 0

# Lifecycle.
var alive: bool = true
var trapped: bool = false
var trap_timer: int = 0                  # ticks remaining
var invuln_timer: int = 0                # ticks remaining
var skill_cooldown: int = 0              # ticks remaining for skill usage
var stun_timer: int = 0                  # ticks remaining for stun status

# Desired input for the current tick (set by controller / AI / test).
var input_dir: Vector2i = Vector2i.ZERO
var input_place: bool = false
var input_skill: bool = false

func _init(p_id: int, p_team: int, spawn: Vector2i, p_name: String = "") -> void:
	id = p_id
	team = p_team
	cell = spawn
	move_target = spawn
	display_name = p_name

func render_pos() -> Vector2:
	## Interpolated cell-space position for rendering (fixed-point progress -> float only here).
	return Vector2(cell).lerp(Vector2(move_target), Fixed.to_float(move_progress))

func can_act() -> bool:
	return alive and not trapped and stun_timer <= 0
