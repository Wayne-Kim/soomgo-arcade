class_name CharacterSprites
extends RefCounted
## Runtime loader + team-recolour for a character's board sprite sheet.
##
## Wires the art recipe (docs/character-art.md) into the renderer: a character
## ships a GRAYSCALE base sheet (`<id>_base.png`, no hue ever) plus a team-tint
## MASK (`<id>_mask.png`, the tintable region). Team colour is applied HERE, at
## runtime, from the functional team palette (Game.TEAM_COLORS) — colour stays
## "by meaning" (team distinction) and is NEVER baked into the shipped pixels
## (docs/BRAND.md, docs/characters.md §3).
##
## A character with no produced art returns `null` from `load_for()`, so the
## renderer falls back cleanly to the legacy TeamMarker shape (pilot-first ship).
##
## Layout (manifest `<id>.json`): rows = state (idle/walk/trapped), cols = frame.
## invuln is NOT a row — it is the renderer's 0.55-alpha treatment of the active
## idle/walk frame. The trapped row carries the character only; the engine draws
## the bubble ring around it.

const DIR := "res://assets/characters"

var id: String
var cell: int = 80                 # source frame px
var rows: Array = []               # ["idle", "walk", "trapped"]
var frames: Dictionary = {}        # state -> frame count
var _base: Image
var _mask: Image
var _sheets: Dictionary = {}       # team index -> ImageTexture (lazily team-tinted)

static var _cache: Dictionary = {} # id -> CharacterSprites or null (negative cache)

## Return the sprite set for `id`, or null if the character has no produced art
## (or the sheet fails to load). Result is cached, including the negative case.
static func load_for(id: String) -> CharacterSprites:
	if _cache.has(id):
		return _cache[id]
	var inst := CharacterSprites.new()
	var ok := inst._load(id)
	var result: CharacterSprites = inst if ok else null
	_cache[id] = result
	return result

func _load(p_id: String) -> bool:
	id = p_id
	var manifest_path := "%s/%s.json" % [DIR, p_id]
	if not FileAccess.file_exists(manifest_path):
		return false
	var raw := FileAccess.get_file_as_string(manifest_path)
	var data: Variant = JSON.parse_string(raw)
	if typeof(data) != TYPE_DICTIONARY:
		return false
	cell = int(data.get("cell", 80))
	rows = data.get("rows", [])
	frames = data.get("frames", {})
	var layers: Dictionary = data.get("layers", {})
	var base_name: String = layers.get("base", "%s_base.png" % p_id)
	var mask_name: String = layers.get("mask", "%s_mask.png" % p_id)
	_base = _load_png("%s/%s" % [DIR, base_name])
	_mask = _load_png("%s/%s" % [DIR, mask_name])
	if _base == null or _mask == null:
		return false
	if rows.is_empty() or _base.get_width() < cell or _base.get_height() < cell:
		return false
	return true

## Load a PNG straight from the project tree (no import dependency), so the
## sheets work headlessly and regardless of the editor import cache.
static func _load_png(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

func has_state(state: String) -> bool:
	return rows.has(state) and int(frames.get(state, 0)) > 0

func frame_count(state: String) -> int:
	return int(frames.get(state, 0))

## Source-sheet pixel rect for (state, frame). Returns a zero rect for an unknown
## state so callers can guard. `frame` wraps within the state's frame count.
func cell_rect(state: String, frame: int) -> Rect2:
	var row := rows.find(state)
	var n := frame_count(state)
	if row < 0 or n <= 0:
		return Rect2()
	var col := ((frame % n) + n) % n
	return Rect2(col * cell, row * cell, cell, cell)

## Team-tinted full sheet for colour index `key` (lazily baked + cached). The tint is
## applied ONLY inside the mask region with the functional `team_color`; everything
## else stays the neutral grayscale value. `key` is the per-player colour index
## (TEAM_COLORS[p.id % size]) the caller tints with — NOT the team number — so
## teammates that share a team but differ in colour each cache their own sheet.
## Mirrors the spike-validated recolour (spikes/sprite_recolor/run_spike.gd:_recolour):
## multiply preserves hue while the base luminance keeps the cel shading.
func sheet_texture(key: int, team_color: Color) -> ImageTexture:
	if _sheets.has(key):
		return _sheets[key]
	var w := _base.get_width()
	var h := _base.get_height()
	var out := Image.create_empty(w, h, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y in h:
		for x in w:
			var bp := _base.get_pixel(x, y)
			if bp.a <= 0.0:
				continue                       # transparent stays transparent (no bleed)
			var lum := bp.r                    # base is grayscale: r == g == b
			var t := _mask.get_pixel(x, y).r   # tintability in [0,1]
			var neutral := Color(lum, lum, lum)
			var tinted := Color(team_color.r * lum, team_color.g * lum, team_color.b * lum)
			var rgb := neutral.lerp(tinted, t)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, bp.a))
	var tex := ImageTexture.create_from_image(out)
	_sheets[key] = tex
	return tex
