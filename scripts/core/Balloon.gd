class_name Balloon
extends RefCounted
## A placed water balloon. Detonates when its fuse expires or when caught in another
## explosion (chain reaction).

var cell: Vector2i
var owner_id: int
var range: int
var fuse: int                  # ticks remaining before detonation
var detonating: bool = false   # flagged for explosion on the current tick

func _init(p_cell: Vector2i, p_owner: int, p_range: int) -> void:
	cell = p_cell
	owner_id = p_owner
	range = p_range
	fuse = Spec.BALLOON_FUSE_TICKS
