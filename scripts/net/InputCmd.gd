class_name InputCmd
extends RefCounted
## Compact, deterministic encoding of one player's per-tick input (direction + place + skill).
## A single int travels the wire and is replayed identically on every client.

const NONE: int = 0
const _PLACE_BIT: int = 1 << 3
const _SKILL_BIT: int = 1 << 4

static func encode(dir: Vector2i, place: bool, skill: bool = false) -> int:
	var d := 0
	if dir == Vector2i.UP:
		d = 1
	elif dir == Vector2i.DOWN:
		d = 2
	elif dir == Vector2i.LEFT:
		d = 3
	elif dir == Vector2i.RIGHT:
		d = 4
	return d | (_PLACE_BIT if place else 0) | (_SKILL_BIT if skill else 0)

static func dir(cmd: int) -> Vector2i:
	match cmd & 0x7:
		1: return Vector2i.UP
		2: return Vector2i.DOWN
		3: return Vector2i.LEFT
		4: return Vector2i.RIGHT
	return Vector2i.ZERO

static func place(cmd: int) -> bool:
	return (cmd & _PLACE_BIT) != 0

static func skill(cmd: int) -> bool:
	return (cmd & _SKILL_BIT) != 0
