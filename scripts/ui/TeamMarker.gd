class_name TeamMarker
extends RefCounted
## Redundant, colour-independent team identity cue. Each team maps to a distinct
## geometric SHAPE that is layered on top of the existing functional team/player
## colour, so colour-blind players can tell teammates from opponents (touching a
## teammate's bubble rescues, an opponent's pops) without relying on hue alone.
##
## Colour stays "by meaning" (player/team distinction) — the shape is an additional
## channel, never a second meaning overloaded onto a colour. The same shapes are
## reused on the board markers and in the HUD/score so the mapping is learnable.
## Covers the full Spec.MAX_PLAYERS (8) team maximum.

const SHAPE_COUNT := 8

# High-contrast dark outline so a marker stays separable from the floor/wall/block
# fills and from an adjacent team's marker, regardless of its fill hue.
const OUTLINE := Color(0.04, 0.06, 0.11, 0.95)

## Draw team `team`'s shape, filled with `fill`, centred at `center` with `radius`.
## Works for any CanvasItem (the arena Node2D and the small HUD glyph controls).
static func draw_shape(ci: CanvasItem, center: Vector2, radius: float, fill: Color,
		team: int, outline_width: float = 2.0) -> void:
	var idx := (team % SHAPE_COUNT + SHAPE_COUNT) % SHAPE_COUNT
	if idx == 0:
		ci.draw_circle(center, radius, fill)
		ci.draw_arc(center, radius, 0.0, TAU, 32, OUTLINE, outline_width)
		return
	var pts := shape_points(idx, center, radius)
	ci.draw_colored_polygon(pts, fill)
	var closed := pts.duplicate()
	closed.push_back(pts[0])
	ci.draw_polyline(closed, OUTLINE, outline_width)

## Perimeter points for shape `idx` (1..SHAPE_COUNT-1; idx 0 is the circle fast path).
static func shape_points(idx: int, center: Vector2, radius: float) -> PackedVector2Array:
	match idx:
		1: return _regular(center, radius, 4, 45.0)    # square
		2: return _regular(center, radius, 3, -90.0)   # triangle (point up)
		3: return _regular(center, radius, 3, 90.0)    # triangle (point down)
		4: return _regular(center, radius, 4, 0.0)     # diamond
		5: return _regular(center, radius, 6, -90.0)   # hexagon
		6: return _star(center, radius, 5, 0.45, -90.0) # 5-point star
		7: return _plus(center, radius)                # plus / cross
		_: return _regular(center, radius, 4, 45.0)

static func _regular(center: Vector2, radius: float, sides: int, start_deg: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in sides:
		var a := deg_to_rad(start_deg + 360.0 * float(i) / float(sides))
		pts.push_back(center + Vector2(cos(a), sin(a)) * radius)
	return pts

static func _star(center: Vector2, radius: float, points: int, inner_ratio: float, start_deg: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	for i in points * 2:
		var r := radius if i % 2 == 0 else radius * inner_ratio
		var a := deg_to_rad(start_deg + 180.0 * float(i) / float(points))
		pts.push_back(center + Vector2(cos(a), sin(a)) * r)
	return pts

static func _plus(center: Vector2, radius: float) -> PackedVector2Array:
	var t := radius * 0.42  # half arm width
	var l := radius         # arm reach
	var pts := PackedVector2Array([
		Vector2(-t, -l), Vector2(t, -l), Vector2(t, -t), Vector2(l, -t),
		Vector2(l, t), Vector2(t, t), Vector2(t, l), Vector2(-t, l),
		Vector2(-t, t), Vector2(-l, t), Vector2(-l, -t), Vector2(-t, -t),
	])
	for i in pts.size():
		pts[i] += center
	return pts
