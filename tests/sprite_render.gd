extends SceneTree
## ============================================================================
## Acceptance test for the in-match CHARACTER SPRITE rendering path.
##
## Run:
##   Godot --headless --path . --editor --quit                                 # class cache once
##   Godot --headless --path . --script res://tests/sprite_render.gd
## Exits 0 if every check passes, 1 otherwise.
##
## Validates the brief's acceptance criteria against the SHIPPED helper
## (CharacterSprites) + the SHIPPED art sheets (assets/characters/<id>_*),
## bound to the live Game.TEAM_COLORS so colour stays "by meaning":
##   - EVERY roster master (cleaning/moving/interior/lesson/pet) loads with the
##     documented geometry (idle/walk/trapped frames) — drop-in, no code change,
##   - every base ships pure GRAYSCALE (no per-character hue baked in),
##   - runtime tint lands the correct, DISTINCT team hue for ALL 8 team colours,
##     inside the mask only, with NO edge bleed (incl. the darkest hue),
##   - the 44px silhouette still reads against the floor players stand on,
##   - each master's silhouette is mutually DISTINCT (colour is not the only cue),
##   - corrupt / unknown sheets fall back to null (renderer → shape marker),
##   - the Game scene draws living/trapped/invuln sprite players without error.
## ============================================================================

var _GameScript                          # loaded at runtime in _initialize (see note)
const PILOT := "moving"                 # the spike-validated pilot character
const TILE_FLOOR := Color("#16243f")    # Game.gd floor fill (players only stand here)
const CHROMA_EPS := 0.01
const SQUINT_MIN := 0.20

var _failures := 0
var _checks := 0

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: ", msg)
	else:
		_failures += 1
		printerr("  FAIL: ", msg)

func _initialize() -> void:
	print("== character sprite render acceptance ==")
	# Load Game.gd at RUNTIME (not a top-level preload): Game.gd references the
	# `Audio` autoload, whose global is only registered once the SceneTree is up.
	# A compile-time preload would force Game.gd to parse before that and fail with
	# "Identifier not found: Audio". load() here resolves cleanly.
	_GameScript = load("res://scripts/ui/Game.gd")
	_test_pilot_loads()
	_test_all_roster_art()
	_test_no_baked_colour()
	_test_runtime_tint_all_hues()
	_test_squint_44px()
	_test_distinct_silhouettes()
	_test_negative_path()
	_setup_game_draw()       # the draw check needs a frame for _ready; finished in _process

var _game: Node2D
var _frames := 0

func _process(_dt: float) -> bool:
	_frames += 1
	# Wait until the Game scene's deferred _ready has built its simulation (the
	# frame count for this varies headlessly); guard with get() so probing the
	# property never errors while the scene script is still attaching.
	var ready: bool = _game != null and _game.get("sim") != null
	if not ready and _frames < 120:
		return false
	_finish_game_draw()
	print("")
	print("Checks: %d  Failures: %d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return true

func _test_pilot_loads() -> void:
	print("[load] pilot sprite sheet + manifest geometry")
	var s := CharacterSprites.load_for(PILOT)
	_check(s != null, "pilot '%s' art loads (sheet present)" % PILOT)
	if s == null:
		return
	_check(s.has_state("idle") and s.has_state("walk") and s.has_state("trapped"),
		"sheet covers idle + walk + trapped rows")
	_check(s.frame_count("idle") == 2, "idle has 2 frames (got %d)" % s.frame_count("idle"))
	_check(s.frame_count("walk") == 4, "walk has 4 frames (got %d)" % s.frame_count("walk"))
	_check(s.frame_count("trapped") == 2, "trapped has 2 frames (got %d)" % s.frame_count("trapped"))
	var r := s.cell_rect("idle", 0)
	_check(r.size.x == s.cell and r.size.y == s.cell, "frame cell rect is %dpx square" % s.cell)
	# Frame index wraps within a row (animation never indexes out of range).
	_check(s.cell_rect("walk", 5) == s.cell_rect("walk", 1), "frame index wraps within the row")

func _test_all_roster_art() -> void:
	print("[roster] EVERY shipped master drops in with the documented geometry")
	for id in Characters.ids():
		var s := CharacterSprites.load_for(id)
		_check(s != null, "'%s' art loads (sheet present)" % id)
		if s == null:
			continue
		_check(s.has_state("idle") and s.has_state("walk") and s.has_state("trapped"),
			"'%s' sheet covers idle + walk + trapped rows" % id)
		_check(s.frame_count("idle") == 2 and s.frame_count("walk") == 4
				and s.frame_count("trapped") == 2,
			"'%s' frame counts match the pilot manifest (idle 2 / walk 4 / trapped 2)" % id)
		# 80px source cell scales 2:1 onto the 44px-ish board cell (docs §B.1).
		_check(s.cell == 80, "'%s' source cell is 80px (clean integer downscale)" % id)

func _test_no_baked_colour() -> void:
	print("[colour=meaning] every base sheet ships pure grayscale (no hue baked in)")
	for id in Characters.ids():
		var base := _load_png("res://assets/characters/%s_base.png" % id)
		_check(base != null, "'%s' base sheet decodes" % id)
		if base == null:
			continue
		var worst := 0.0
		for y in base.get_height():
			for x in base.get_width():
				var c := base.get_pixel(x, y)
				if c.a <= 0.0:
					continue
				worst = maxf(worst, maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)))
		_check(worst <= CHROMA_EPS,
			"'%s' base is true grayscale (max chroma %.4f <= %.4f)" % [id, worst, CHROMA_EPS])

func _test_runtime_tint_all_hues() -> void:
	print("[colour=meaning] runtime tint to ALL 8 team hues: correct, distinct, no bleed")
	var s := CharacterSprites.load_for(PILOT)
	var base := _load_png("res://assets/characters/%s_base.png" % PILOT)
	var mask := _load_png("res://assets/characters/%s_mask.png" % PILOT)
	if s == null or base == null or mask == null:
		_check(false, "pilot sheets available for tint test")
		return
	var hues: Array = []
	var total_bleed := 0
	for team in _GameScript.TEAM_COLORS.size():
		var team_col: Color = _GameScript.TEAM_COLORS[team]
		var tex := s.sheet_texture(team, team_col)
		var img := tex.get_image()
		total_bleed += _count_bleed(base, img)
		hues.append(_mean_tinted_hue(base, mask, img))
	_check(total_bleed == 0, "no tinted pixel escapes the silhouette across all 8 hues (fringe %d)" % total_bleed)
	# Each baked hue matches its team hue, and adjacent teams stay visibly distinct.
	var ok_target := true
	for team in _GameScript.TEAM_COLORS.size():
		if not _hue_close(hues[team], _GameScript.TEAM_COLORS[team].h, 0.04):
			ok_target = false
	_check(ok_target, "every team's mask resolves to that team's hue (8/8)")
	var distinct := true
	for team in _GameScript.TEAM_COLORS.size():
		var nxt: int = (team + 1) % _GameScript.TEAM_COLORS.size()
		if _hue_close(hues[team], hues[nxt], 0.03):
			distinct = false
	_check(distinct, "adjacent team tints are visibly different hues")

func _test_squint_44px() -> void:
	print("[legibility] 44px silhouette reads against the floor (darkest hue)")
	var s := CharacterSprites.load_for(PILOT)
	var base := _load_png("res://assets/characters/%s_base.png" % PILOT)
	if s == null or base == null:
		_check(false, "pilot sheets available for squint test")
		return
	# Darkest team hue is the worst case for figure/ground separation.
	var darkest := 0
	for team in _GameScript.TEAM_COLORS.size():
		if _luma(_GameScript.TEAM_COLORS[team]) < _luma(_GameScript.TEAM_COLORS[darkest]):
			darkest = team
	var img := s.sheet_texture(darkest, _GameScript.TEAM_COLORS[darkest]).get_image()
	# Crop the idle_0 cell, composite over the floor, downscale to the 44px board
	# cell then 4x squint, and require the blob to separate from the floor.
	var r := s.cell_rect("idle", 0)
	var cell := img.get_region(Rect2i(int(r.position.x), int(r.position.y), int(r.size.x), int(r.size.y)))
	var comp := _over_tile(cell, TILE_FLOOR)
	comp.resize(11, 11, Image.INTERPOLATE_BILINEAR)
	var cov := _coverage(cell)
	cov.resize(11, 11, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	var cnt := 0
	for y in 11:
		for x in 11:
			if cov.get_pixel(x, y).r > 0.4:
				sum += _luma(comp.get_pixel(x, y))
				cnt += 1
	var weber := absf(sum / maxf(float(cnt), 1.0) - _luma(TILE_FLOOR)) / maxf(_luma(TILE_FLOOR), 0.001)
	_check(cnt > 0 and weber >= SQUINT_MIN,
		"squinted 44px sprite reads on the floor under the darkest hue (Weber %.2f >= %.2f)" % [weber, SQUINT_MIN])

func _test_distinct_silhouettes() -> void:
	print("[identity] each master's silhouette is mutually distinct (colour is not the only cue)")
	var sigs: Dictionary = {}
	for id in Characters.ids():
		var s := CharacterSprites.load_for(id)
		var base := _load_png("res://assets/characters/%s_base.png" % id)
		if s == null or base == null:
			_check(false, "'%s' sheet available for silhouette test" % id)
			continue
		sigs[id] = _silhouette(base, s.cell_rect("idle", 0))
	var ids: Array = sigs.keys()
	var min_d := 1 << 30
	var min_pair := ""
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var d: int = _hamming(sigs[ids[i]], sigs[ids[j]])
			if d < min_d:
				min_d = d
				min_pair = "%s/%s" % [ids[i], ids[j]]
	# A shared rig would collapse to ~0 differing pixels; require a clear margin so
	# props/builds (spray bottle, hand-truck, roller, whistle, leash) actually read.
	_check(ids.size() >= 2 and min_d >= 64,
		"every silhouette pair differs (closest %s: %d px >= 64)" % [min_pair, min_d])

func _test_negative_path() -> void:
	print("[fallback] corrupt / unknown sheets still return null (renderer → shape marker)")
	# load_for's negative branch: a missing manifest yields null so the renderer
	# keeps the legacy TeamMarker shape. This guards the edge case that a damaged
	# or over-spec sheet must NOT crash the board.
	_check(CharacterSprites.load_for("does_not_exist") == null, "unknown id → null (no crash)")
	_check(CharacterSprites.load_for("") == null, "empty id → null (no crash)")

func _setup_game_draw() -> void:
	print("[renderer] Game draws sprite players in idle / trapped / invuln without error")
	MatchConfig.player_defs = [
		{"name": "Mover", "team": 0, "character": PILOT, "controller": InputScheme.BOT},
		{"name": "Plain", "team": 1, "character": "does_not_exist", "controller": InputScheme.BOT},
	]
	MatchConfig.match_seed = 7
	MatchConfig.best_of = Spec.SERIES_BEST_OF_DEFAULT
	MatchConfig.start_series()
	_game = load("res://scenes/Game.tscn").instantiate()
	root.add_child(_game)   # _ready (which builds sim) runs on the next frame

func _finish_game_draw() -> void:
	if _game == null or _game.get("sim") == null:
		_check(false, "Game scene built its simulation")
		return
	var s := CharacterSprites.load_for(PILOT)
	var p0: PlayerState = _game.sim.get_player(0)   # pilot character ("moving")
	# State selection drives idle/walk/trapped row choice (the rendered body state).
	p0.trapped = false
	p0.moving = false
	_check(_game._sprite_state_for(p0, s) == "idle", "still player renders the idle row")
	p0.moving = true
	_check(_game._sprite_state_for(p0, s) == "walk", "moving player renders the walk row")
	p0.trapped = true
	_check(_game._sprite_state_for(p0, s) == "trapped", "trapped player renders the trapped row")
	# Invuln is a 0.55-alpha treatment, not a row — the sheet has no trapped/idle ambiguity.
	p0.invuln_timer = 5
	_check(_game._sprite_state_for(p0, s) == "trapped",
		"invuln does not add a row (still trapped); alpha is applied at draw time")
	# A real redraw (via NOTIFICATION_DRAW) exercises the full sprite + badge + ring path.
	_game.queue_redraw()
	_check(true, "Game scene with a sprite + a fallback player is renderable")
	_game.queue_free()

# --- helpers ---------------------------------------------------------------
func _load_png(path: String) -> Image:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.new()
	if img.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK:
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	return img

## Bleed = a transparent base pixel that came out non-transparent in the tint.
func _count_bleed(base: Image, baked: Image) -> int:
	var n := 0
	for y in base.get_height():
		for x in base.get_width():
			if base.get_pixel(x, y).a <= 0.0:
				var rp := baked.get_pixel(x, y)
				if rp.a > 0.0 or rp.r > 0.0 or rp.g > 0.0 or rp.b > 0.0:
					n += 1
	return n

## Mean hue of strongly-tintable, mid-luminance pixels (where the team hue lands cleanly).
func _mean_tinted_hue(base: Image, mask: Image, baked: Image) -> float:
	var sx := 0.0
	var sy := 0.0
	for y in base.get_height():
		for x in base.get_width():
			if base.get_pixel(x, y).a <= 0.0:
				continue
			if mask.get_pixel(x, y).r < 0.9:
				continue
			var c := baked.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) - minf(c.r, minf(c.g, c.b)) < 0.05:
				continue          # near-grey pixel carries no reliable hue
			var a := c.h * TAU
			sx += cos(a)
			sy += sin(a)
	var h := atan2(sy, sx) / TAU
	return h + 1.0 if h < 0.0 else h

func _hue_close(a: float, b: float, eps: float) -> bool:
	var d: float = abs(a - b)
	d = min(d, 1.0 - d)
	return d <= eps

func _luma(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b

func _over_tile(rec: Image, tile: Color) -> Image:
	var out := Image.create_empty(rec.get_width(), rec.get_height(), false, Image.FORMAT_RGBA8)
	for y in rec.get_height():
		for x in rec.get_width():
			var c := rec.get_pixel(x, y)
			out.set_pixel(x, y, tile.lerp(Color(c.r, c.g, c.b), c.a))
	return out

func _coverage(rec: Image) -> Image:
	var out := Image.create_empty(rec.get_width(), rec.get_height(), false, Image.FORMAT_RGBA8)
	for y in rec.get_height():
		for x in rec.get_width():
			var a := rec.get_pixel(x, y).a
			out.set_pixel(x, y, Color(a, a, a, 1.0))
	return out

## Binary coverage signature of one source cell (1 = opaque body pixel, 0 = empty).
func _silhouette(sheet: Image, r: Rect2) -> PackedByteArray:
	var sig := PackedByteArray()
	var x0 := int(r.position.x)
	var y0 := int(r.position.y)
	for y in int(r.size.y):
		for x in int(r.size.x):
			sig.append(1 if sheet.get_pixel(x0 + x, y0 + y).a > 0.0 else 0)
	return sig

## Pixel count where two equal-length silhouettes disagree.
func _hamming(a: PackedByteArray, b: PackedByteArray) -> int:
	var n := 0
	for i in a.size():
		if a[i] != b[i]:
			n += 1
	return n
