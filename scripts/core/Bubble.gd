class_name Bubble
extends RefCounted
## A trapped player held in a water bubble. Rescued if a teammate touches it,
## eliminated if an enemy touches it or the timer expires.

var cell: Vector2i
var victim_id: int
var team: int
var timer: int                 # ticks remaining before the trapped player drowns

func _init(p_cell: Vector2i, p_victim: int, p_team: int) -> void:
	cell = p_cell
	victim_id = p_victim
	team = p_team
	timer = Spec.BUBBLE_TICKS
