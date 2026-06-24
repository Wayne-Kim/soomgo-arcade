class_name TeamGlyph
extends Control
## A small, decorative team-shape icon for the HUD/score, drawn with the same
## TeamMarker shapes used on the board so the team -> shape mapping is consistent
## and learnable. Purely visual: the adjacent text label carries the accessible
## name, so this control is non-focusable and ignored by the pointer.

var team: int = 0
var fill: Color = Color.WHITE
var glyph_radius: float = 9.0

func _init(p_team: int = 0, p_fill: Color = Color.WHITE, p_radius: float = 9.0) -> void:
	team = p_team
	fill = p_fill
	glyph_radius = p_radius
	custom_minimum_size = Vector2(glyph_radius * 2.0 + 4.0, glyph_radius * 2.0 + 4.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _draw() -> void:
	TeamMarker.draw_shape(self, size / 2.0, glyph_radius, fill, team, 1.5)
