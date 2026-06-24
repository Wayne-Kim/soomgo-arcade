extends SceneTree
## ============================================================================
## DESIGN-VALIDATION SPIKE — AI-sprite recolour recipe, end-to-end on ONE
## character (Tote, the bulky mover/bomber with the most distinct silhouette).
##
## THIS IS A ONE-TIME SPIKE. It is deliberately ISOLATED from the shipping game:
## nothing here is wired into scripts/, scenes/, assets/ or project.godot, and it
## produces NO launch assets. The deliverable is a GO / NO-GO recommendation
## (spikes/sprite_recolor/REPORT.md); the PNGs under out/ are throwaway evidence.
##
## Run:
##   GODOT=/Applications/Godot.app/Contents/MacOS/Godot
##   "$GODOT" --headless --path . --editor --quit                                  # build class cache once
##   "$GODOT" --headless --path . --script res://spikes/sprite_recolor/run_spike.gd
## Exits 0 if every acceptance criterion passes, 1 otherwise.
##
## WHAT IS BEING VALIDATED — the *recipe / runtime pipeline*, not a vendor tool.
## The recipe ships a character as a GREYSCALE base (form/shading, no hue) + a
## MASK (which pixels are team-tintable). The runtime recolours by tinting only
## the masked region with the FUNCTIONAL team colour (Game.gd's TEAM_COLORS) and
## keeps every other pixel a constant neutral, so "colour == team meaning" is
## never baked in. This harness:
##   1. Builds Tote from a DETERMINISTIC vector rig (the recipe's output contract)
##      for the four render states the game actually shows.
##   2. Recolours to >=2 team hues and checks: no baked colour, no mask-edge bleed.
##   3. Tests the 44px silhouette with squint + desaturate on floor/wall/block.
##   4. Confirms it does not conflict with the redundant TeamMarker SHAPE cue.
##   5. Judges frame-to-frame drift across the four render states.
## Every board constant (44px cell, 8 team hues, the marker shapes) is pulled
## LIVE from the repo so the spike can never silently drift from the game.
## ============================================================================

# --- Live repo bindings (single source of truth) ---------------------------
const GameScript := preload("res://scripts/ui/Game.gd")
# Board tile fills mirror Game.gd:_draw() (literals there, ~lines 354-359):
#   FLOOR #16243f, HARD_WALL #33415a, SOFT_BLOCK #7a5230. Mirrored here because
# they are inline literals in _draw(), not constants we can import.
const TILE_FLOOR := Color("#16243f")
const TILE_WALL := Color("#33415a")
const TILE_BLOCK := Color("#7a5230")

const OUT_DIR := "res://spikes/sprite_recolor/out"
const STATES := ["idle", "walk", "trapped", "rescued"]

# Acceptance thresholds (documented in REPORT.md).
const CHROMA_EPS := 0.01          # max source chroma allowed -> "no baked colour"
const SQUINT_MIN := 0.20          # min Weber contrast of squinted silhouette vs tile
const DESAT_MIN := 0.25           # min Weber contrast of desaturated silhouette vs tile
const SHAPE_DIFF_MIN := 0.15      # min XOR fraction between two teams' marker shapes
const DRIFT_HUE_MAX := 0.02       # max hue spread (turns) inside mask across states
const DRIFT_AREA_MAX := 0.05      # max silhouette-area drift between same-size poses

var CELL: int                     # = Game.CELL (44), asserted below
var _failures := 0
var _checks := 0
var _metrics := {}

# ----------------------------------------------------------------------------
func _initialize() -> void:
	print("== Soomgo Arcade — AI-sprite recolour validation spike (Tote) ==")
	CELL = GameScript.CELL
	_check(CELL == 44, "board cell pulled live from Game.CELL == 44 (got %d)" % CELL)
	_check(GameScript.TEAM_COLORS.size() >= 2, "Game.TEAM_COLORS has >=2 functional team hues")
	_check(TeamMarker.SHAPE_COUNT >= 2, "TeamMarker provides >=2 redundant shapes")

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	# 1) Build the deterministic Tote source (grey + mask) for all render states.
	var src := {}
	for st in STATES:
		src[st] = _build_tote(st)

	# 2) Recolour to two distinct team hues (team 0 + team 1) for every state.
	var team0: Color = GameScript.TEAM_COLORS[0]
	var team1: Color = GameScript.TEAM_COLORS[1]
	var rec0 := {}
	var rec1 := {}
	for st in STATES:
		rec0[st] = _recolour(src[st].gray, src[st].mask, team0)
		rec1[st] = _recolour(src[st].gray, src[st].mask, team1)

	# --- Acceptance criteria ---------------------------------------------------
	_criterion_no_baked_colour(src)
	_criterion_no_edge_bleed(src, rec0, rec1, team0, team1)
	_criterion_squint_and_desat(src, rec0, rec1)
	_criterion_team_marker_noncolour(src)
	_criterion_frame_drift(src, rec0)

	# --- Evidence artefacts (throwaway, gitignored) ----------------------------
	_write_evidence(src, rec0, rec1, team0, team1)
	_write_metrics()

	print("")
	print("Checks: %d  Failures: %d" % [_checks, _failures])
	print("Recommendation basis written to spikes/sprite_recolor/out/metrics.json")
	quit(1 if _failures > 0 else 0)

# ============================================================================
# DETERMINISTIC TOTE RIG  — the recipe's grey+mask output contract.
# gray:  RGBA8, rgb == neutral luminance (NO hue), a == coverage.
# mask:  RGBA8, r == team-tintability in [0,1] (1 = recoloured, 0 = constant).
# Four render states match Game.gd's player rendering: idle / walk (movement) /
# trapped (in-bubble) / rescued (post-rescue invulnerable flash).
# ============================================================================
var _pscale := 1.0
var _pcx := 21.0
var _pcy := 21.0
var _pdx := 0
var _pdy := 0

func _build_tote(state: String, with_outline: bool = true) -> Dictionary:
	var g := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	var m := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	g.fill(Color(0, 0, 0, 0))
	m.fill(Color(0, 0, 0, 0))

	# Pose transform (identity for idle/rescued; bob for walk; shrink for trapped).
	_pscale = 1.0; _pcx = 21.0; _pcy = 21.0; _pdx = 0; _pdy = 0
	var lfoot := Vector2i(0, 0)
	var rfoot := Vector2i(0, 0)
	match state:
		"walk":
			_pdy = -1                 # whole figure bobs up 1px
			lfoot = Vector2i(2, -2)   # left foot strides forward/up
			rfoot = Vector2i(-1, 0)   # right foot trails
		"trapped":
			_pscale = 0.8; _pdy = 2   # hunched/compressed inside the bubble
		_:
			pass                      # idle, rescued share one pose

	# Helmet (team-tintable). Vertical shade top->bottom gives form.
	_fill_rect(g, m, 15, 6, 28, 14, 0.90, 0.74, 1.0)
	# Visor band (neutral, constant identity across teams).
	_fill_rect(g, m, 15, 12, 28, 13, 0.16, 0.16, 0.0)
	# Crate / body — the dominant silhouette mass (team-tintable).
	_fill_rect(g, m, 8, 15, 35, 35, 0.86, 0.50, 1.0)
	# Packing straps (neutral) — break up the mass + a constant cross-team cue.
	_fill_rect(g, m, 8, 20, 35, 21, 0.20, 0.20, 0.0)
	_fill_rect(g, m, 8, 29, 35, 30, 0.20, 0.20, 0.0)
	# Left arm stub gripping the load (neutral) — asymmetry sharpens the silhouette.
	_fill_rect(g, m, 5, 22, 8, 26, 0.30, 0.30, 0.0)
	# Hand-truck — the signature "mover" prop (neutral, constant across teams).
	_fill_rect(g, m, 35, 11, 38, 40, 0.30, 0.30, 0.0)   # upright frame
	_fill_rect(g, m, 29, 38, 38, 40, 0.30, 0.30, 0.0)   # base lip
	_fill_disc(g, m, 35, 38, 3, 0.12, 0.0)              # wheel
	# Feet (neutral) — carry the walk stride.
	_fill_rect(g, m, 12 + lfoot.x, 36 + lfoot.y, 19 + lfoot.x, 40 + lfoot.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 24 + rfoot.x, 36 + rfoot.y, 31 + rfoot.x, 40 + rfoot.y, 0.18, 0.18, 0.0)

	# 1px dark keyline so the silhouette separates from ANY tile (matches the
	# TeamMarker.OUTLINE convention). Neutral -> never recoloured. The negative
	# control below builds Tote WITHOUT it to prove the keyline is load-bearing.
	if with_outline:
		_add_outline(g, m)
	return {"gray": g, "mask": m}

func _tx(x: float) -> int:
	return int(round(_pcx + (x - _pcx) * _pscale)) + _pdx

func _ty(y: float) -> int:
	return int(round(_pcy + (y - _pcy) * _pscale)) + _pdy

func _set_px(g: Image, m: Image, px: int, py: int, lum: float, tint: float) -> void:
	if px < 0 or py < 0 or px >= CELL or py >= CELL:
		return
	g.set_pixel(px, py, Color(lum, lum, lum, 1.0))
	m.set_pixel(px, py, Color(tint, tint, tint, 1.0))

func _fill_rect(g: Image, m: Image, x0: int, y0: int, x1: int, y1: int,
		lum_top: float, lum_bot: float, tint: float) -> void:
	for y in range(y0, y1 + 1):
		var f := 0.0 if y1 == y0 else float(y - y0) / float(y1 - y0)
		var lum := lerpf(lum_top, lum_bot, f)
		for x in range(x0, x1 + 1):
			_set_px(g, m, _tx(x), _ty(y), lum, tint)

func _fill_disc(g: Image, m: Image, cx: int, cy: int, r: int, lum: float, tint: float) -> void:
	for y in range(cy - r, cy + r + 1):
		for x in range(cx - r, cx + r + 1):
			var dx := x - cx
			var dy := y - cy
			if dx * dx + dy * dy <= r * r:
				_set_px(g, m, _tx(x), _ty(y), lum, tint)

## Add a 1px outline on every transparent pixel that touches coverage.
func _add_outline(g: Image, m: Image) -> void:
	var ring: Array[Vector2i] = []
	for y in CELL:
		for x in CELL:
			if g.get_pixel(x, y).a > 0.0:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < CELL and n.y < CELL and g.get_pixel(n.x, n.y).a > 0.0:
					ring.append(Vector2i(x, y))
					break
	for p in ring:
		g.set_pixel(p.x, p.y, Color(0.05, 0.05, 0.05, 1.0))
		m.set_pixel(p.x, p.y, Color(0, 0, 0, 1.0))

# ============================================================================
# THE RECOLOUR PIPELINE — the candidate runtime op (a GPU shader would mirror
# this). Inside the mask: tint the neutral value by the team hue (multiply
# preserves hue+saturation exactly, only value/shading varies). Outside the
# mask: keep the constant neutral value. Transparent stays exactly (0,0,0,0).
# ============================================================================
func _recolour(gray: Image, mask: Image, team: Color) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y in CELL:
		for x in CELL:
			var gp := gray.get_pixel(x, y)
			if gp.a <= 0.0:
				continue                                  # no bleed: stays transparent
			var lum := gp.r                               # r == g == b
			var t := mask.get_pixel(x, y).r               # tintability
			var neutral := Color(lum, lum, lum)
			var tinted := Color(team.r * lum, team.g * lum, team.b * lum)
			var rgb := neutral.lerp(tinted, t)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, gp.a))
	return out

# ============================================================================
# CRITERION 1 — grey+mask recolours to >=2 team hues with NO BAKED COLOUR.
# ============================================================================
func _criterion_no_baked_colour(src: Dictionary) -> void:
	print("[criterion] greyscale source carries no baked colour")
	var worst := 0.0
	for st in STATES:
		var g: Image = src[st].gray
		for y in CELL:
			for x in CELL:
				var c := g.get_pixel(x, y)
				if c.a <= 0.0:
					continue
				var chroma: float = max(c.r, c.g, c.b) - min(c.r, c.g, c.b)
				worst = max(worst, chroma)
	_metrics["max_source_chroma"] = worst
	_check(worst <= CHROMA_EPS,
		"source is true greyscale across all states (max chroma %.4f <= %.4f)" % [worst, CHROMA_EPS])

# ============================================================================
# CRITERION 1 (cont.) — recolour to two team hues, NO MASK-EDGE BLEED, and the
# tint actually lands as the correct, distinct team hue. A negative control
# proves the bleed detector has teeth.
# ============================================================================
func _criterion_no_edge_bleed(src: Dictionary, rec0: Dictionary, rec1: Dictionary,
		team0: Color, team1: Color) -> void:
	print("[criterion] recolour to 2 team hues, no mask-edge bleed")
	var total_fringe := 0
	for st in STATES:
		total_fringe += _count_bleed(src[st].gray, rec0[st])
		total_fringe += _count_bleed(src[st].gray, rec1[st])
	_metrics["bleed_fringe_pixels"] = total_fringe
	_check(total_fringe == 0, "no tinted pixel escapes the silhouette (fringe pixels == %d)" % total_fringe)

	# The two recolours must be the two distinct team hues (not a baked-in colour).
	var h0 := _mean_mask_hue(src["idle"].gray, src["idle"].mask, rec0["idle"])
	var h1 := _mean_mask_hue(src["idle"].gray, src["idle"].mask, rec1["idle"])
	_metrics["team0_hue"] = h0
	_metrics["team1_hue"] = h1
	_metrics["team0_target_hue"] = team0.h
	_metrics["team1_target_hue"] = team1.h
	_check(_hue_close(h0, team0.h, 0.03), "team 0 mask resolves to team-0 hue (%.3f ~ %.3f)" % [h0, team0.h])
	_check(_hue_close(h1, team1.h, 0.03), "team 1 mask resolves to team-1 hue (%.3f ~ %.3f)" % [h1, team1.h])
	_check(not _hue_close(h0, h1, 0.10), "the two recolours are visibly different team hues (%.3f vs %.3f)" % [h0, h1])

	# Negative control: a mask dilated 2px past the silhouette MUST be flagged.
	var bad := _dilate_mask(src["idle"].mask, 2)
	var bad_rec := _recolour_unbounded(src["idle"].gray, bad, team0)
	var caught := _count_bleed(src["idle"].gray, bad_rec)
	_check(caught > 0, "negative control: detector flags a deliberately bled mask (%d fringe px)" % caught)

## A bleed pixel = a transparent source pixel that came out non-transparent, OR
## any output pixel carrying team chroma where the source had no coverage.
func _count_bleed(gray: Image, rec: Image) -> int:
	var n := 0
	for y in CELL:
		for x in CELL:
			var cov := gray.get_pixel(x, y).a
			var rp := rec.get_pixel(x, y)
			if cov <= 0.0:
				# Must be exactly transparent — no premultiplied colour fringe.
				if rp.a > 0.0 or rp.r > 0.0 or rp.g > 0.0 or rp.b > 0.0:
					n += 1
	return n

## Like _recolour but does NOT clip to coverage — used only for the negative
## control so a sloppy (dilated) mask can actually paint past the silhouette.
func _recolour_unbounded(gray: Image, mask: Image, team: Color) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y in CELL:
		for x in CELL:
			var t := mask.get_pixel(x, y).r
			var cov := gray.get_pixel(x, y).a
			if t <= 0.0 and cov <= 0.0:
				continue
			var lum: float = gray.get_pixel(x, y).r if cov > 0.0 else 0.7
			var rgb := Color(lum, lum, lum).lerp(Color(team.r * lum, team.g * lum, team.b * lum), t)
			out.set_pixel(x, y, Color(rgb.r, rgb.g, rgb.b, max(cov, t)))
	return out

func _dilate_mask(mask: Image, radius: int) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 1))
	for y in CELL:
		for x in CELL:
			var on := false
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and ny >= 0 and nx < CELL and ny < CELL and mask.get_pixel(nx, ny).r > 0.0:
						on = true
			out.set_pixel(x, y, Color(1, 1, 1, 1) if on else Color(0, 0, 0, 1))
	return out

# ============================================================================
# CRITERION 2 — 44px silhouette passes SQUINT + DESATURATE on floor/wall/block.
# ============================================================================
func _criterion_squint_and_desat(src: Dictionary, rec0: Dictionary, rec1: Dictionary) -> void:
	print("[criterion] 44px silhouette reads (squint + desaturate) on floor/wall/block")
	var tiles := {"floor": TILE_FLOOR, "wall": TILE_WALL, "block": TILE_BLOCK}
	var cov: Image = src["idle"].gray

	# SQUINT — players only ever occupy FLOOR cells (Arena.is_walkable == Tile.FLOOR),
	# so the squint background that matters is the floor. Downscale 44->11 (4x squint)
	# and require the whole blob to separate from the floor. Wall/block squint is
	# recorded for BOTH teams as informational only (no player ever stands on them).
	var sc_floor := _squint_contrast(rec0["idle"], cov, TILE_FLOOR)
	_check(sc_floor >= SQUINT_MIN, "squint(11px) blob reads on the floor tile players stand on (Weber %.2f >= %.2f)" % [sc_floor, SQUINT_MIN])
	_metrics["squint_floor_team0"] = sc_floor
	_metrics["squint_floor_team1"] = _squint_contrast(rec1["idle"], cov, TILE_FLOOR)
	_metrics["squint_wall_team0_informational"] = _squint_contrast(rec0["idle"], cov, TILE_WALL)
	_metrics["squint_block_team0_informational"] = _squint_contrast(rec0["idle"], cov, TILE_BLOCK)

	# DESATURATE — "reads on floor/wall/block" is a figure/ground EDGE question:
	# with colour removed, the silhouette's dark keyline must separate it from the
	# tile it sits on or beside. Hard requirement on all three tiles, for the
	# low-luma team (red, team 0) which is the worst case.
	var edge := {}
	for tname in tiles:
		var e := _edge_separation(rec0["idle"], cov, tiles[tname])
		edge[tname] = e
		_check(e >= DESAT_MIN, "desaturated silhouette edge separates from %s tile (Weber %.2f >= %.2f)" % [tname, e, DESAT_MIN])
	_metrics["desat_edge_separation"] = edge

	# Form still reads in greyscale: the desaturated figure keeps internal contrast.
	var form_range := _internal_luma_range(rec0["idle"], cov)
	_metrics["desat_internal_luma_range_team0"] = form_range
	_check(form_range >= 0.30, "desaturated form keeps internal contrast (luma range %.2f >= 0.30)" % form_range)

	# FINDING (recorded, not a pass/fail): a low-luma team hue drops the recoloured
	# BODY's mean luminance close to the mid-luma wall, so the fill alone cannot be
	# relied on for separation — the keyline is what guarantees readability.
	_metrics["body_mean_luma_team0_red"] = _figure_mean_luma(rec0["idle"], cov)
	_metrics["wall_luma"] = _luma(TILE_WALL)

	# NEGATIVE CONTROL — rebuild Tote WITHOUT the keyline. Against the slate wall the
	# low-luma red fill leaves a chunk of the silhouette edge near-invisible
	# (contrast < threshold); the keyline drives that fraction to ~zero. Proves the
	# keyline is load-bearing, not decorative.
	var bare := _build_tote("idle", false)
	var bare_rec := _recolour(bare.gray, bare.mask, GameScript.TEAM_COLORS[0])
	var bare_gap := _low_contrast_boundary_fraction(bare_rec, bare.gray, TILE_WALL, DESAT_MIN)
	var keyed_gap := _low_contrast_boundary_fraction(rec0["idle"], cov, TILE_WALL, DESAT_MIN)
	_metrics["no_keyline_wall_invisible_edge_fraction"] = bare_gap
	_metrics["keyline_wall_invisible_edge_fraction"] = keyed_gap
	_check(bare_gap >= 0.10 and keyed_gap <= 0.02,
		"negative control: keyline closes invisible silhouette edges on the wall (no-keyline %.0f%% -> keyline %.0f%%)" % [bare_gap * 100.0, keyed_gap * 100.0])

## Composite over tile, downscale 44->11 (4x squint), measure silhouette-vs-tile
## Weber contrast.
func _squint_contrast(rec: Image, gray: Image, tile: Color) -> float:
	var comp := _over_tile(rec, tile)
	var small := comp.duplicate()
	small.resize(11, 11, Image.INTERPOLATE_BILINEAR)
	var covsmall := _coverage_image(gray)
	covsmall.resize(11, 11, Image.INTERPOLATE_BILINEAR)
	var sum := 0.0
	var cnt := 0
	for y in 11:
		for x in 11:
			if covsmall.get_pixel(x, y).r > 0.4:
				sum += _luma(small.get_pixel(x, y))
				cnt += 1
	if cnt == 0:
		return 0.0
	var fg := sum / float(cnt)
	var bg := _luma(tile)
	return absf(fg - bg) / maxf(bg, 0.001)

## Figure/ground EDGE contrast after full desaturation: mean Weber contrast
## between the silhouette's boundary pixels (the dark keyline) and the tile they
## abut. This is the perceptually correct "does the silhouette read on the tile"
## test — independent of the (hue-dependent) interior fill.
func _edge_separation(rec: Image, gray: Image, tile: Color) -> float:
	var bg := _luma(tile)
	var sum := 0.0
	var cnt := 0
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a <= 0.0:
				continue
			var boundary := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x < 0 or n.y < 0 or n.x >= CELL or n.y >= CELL or gray.get_pixel(n.x, n.y).a <= 0.0:
					boundary = true
					break
			if boundary:
				sum += absf(_luma(rec.get_pixel(x, y)) - bg) / maxf(bg, 0.001)
				cnt += 1
	if cnt == 0:
		return 0.0
	return sum / float(cnt)

## Fraction of silhouette boundary pixels whose Weber contrast against the tile
## falls below `thresh` — i.e. edges that visually vanish into the tile.
func _low_contrast_boundary_fraction(rec: Image, gray: Image, tile: Color, thresh: float) -> float:
	var bg := _luma(tile)
	var low := 0
	var total := 0
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a <= 0.0:
				continue
			var boundary := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x < 0 or n.y < 0 or n.x >= CELL or n.y >= CELL or gray.get_pixel(n.x, n.y).a <= 0.0:
					boundary = true
					break
			if boundary:
				total += 1
				if absf(_luma(rec.get_pixel(x, y)) - bg) / maxf(bg, 0.001) < thresh:
					low += 1
	return float(low) / float(total) if total > 0 else 0.0

## Internal luminance range of the desaturated figure (form/structure cue).
func _internal_luma_range(rec: Image, gray: Image) -> float:
	var lo := 1.0
	var hi := 0.0
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a <= 0.0:
				continue
			var l := _luma(rec.get_pixel(x, y))
			lo = min(lo, l)
			hi = max(hi, l)
	return hi - lo

## Mean luminance of the whole figure (used only as a recorded finding).
func _figure_mean_luma(rec: Image, gray: Image) -> float:
	var sum := 0.0
	var cnt := 0
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a > 0.0:
				sum += _luma(rec.get_pixel(x, y))
				cnt += 1
	return sum / float(cnt) if cnt > 0 else 0.0

# ============================================================================
# CRITERION 3 — does NOT conflict with the redundant TeamMarker SHAPE; team
# identity survives WITHOUT colour. Uses the repo's real TeamMarker geometry.
# ============================================================================
func _criterion_team_marker_noncolour(src: Dictionary) -> void:
	print("[criterion] TeamMarker shape stays readable over the sprite (team id without colour)")
	var body: Image = src["idle"].gray   # desaturated sprite body (no colour at all)
	var center := Vector2(CELL / 2.0, CELL / 2.0)
	var radius := CELL * 0.38            # same factor Game.gd uses for the board marker

	# (a) Marker must stay visible over the sprite once colour is removed: its dark
	#     OUTLINE must contrast with the greyscale body underneath.
	var shape0 := _marker_coverage(0, center, radius)
	var contrast := _marker_outline_contrast(body, shape0, center, radius)
	_metrics["marker_outline_contrast"] = contrast
	_check(contrast >= DESAT_MIN, "TeamMarker outline still pops over the desaturated sprite (Weber %.2f >= %.2f)" % [contrast, DESAT_MIN])

	# (b) Team identity by SHAPE alone (no hue): two teams' marker silhouettes
	#     must be geometrically distinct.
	var shape1 := _marker_coverage(1, center, radius)
	var diff := _coverage_xor_fraction(shape0, shape1)
	_metrics["marker_shape_xor_fraction"] = diff
	_check(diff >= SHAPE_DIFF_MIN, "team 0 vs team 1 marker shapes are distinguishable without colour (XOR %.2f >= %.2f)" % [diff, SHAPE_DIFF_MIN])

	# (c) The sprite leaves room for the marker (the marker is not swallowed): the
	#     marker footprint is a sane fraction of the cell, matching the board.
	var mfrac := float(_coverage_count(shape0)) / float(CELL * CELL)
	_metrics["marker_footprint_fraction"] = mfrac
	_check(mfrac > 0.10 and mfrac < 0.85, "marker footprint is legible over the sprite (%.0f%% of cell)" % (mfrac * 100.0))

## Rasterise TeamMarker shape `team` coverage using the repo's real geometry.
func _marker_coverage(team: int, center: Vector2, radius: float) -> Image:
	var img := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var idx := (team % TeamMarker.SHAPE_COUNT + TeamMarker.SHAPE_COUNT) % TeamMarker.SHAPE_COUNT
	if idx == 0:
		for y in CELL:
			for x in CELL:
				if Vector2(x, y).distance_to(center) <= radius:
					img.set_pixel(x, y, Color(1, 1, 1, 1))
		return img
	var pts := TeamMarker.shape_points(idx, center, radius)
	for y in CELL:
		for x in CELL:
			if _point_in_poly(Vector2(x + 0.5, y + 0.5), pts):
				img.set_pixel(x, y, Color(1, 1, 1, 1))
	return img

## Weber contrast between the marker's 1px outline ring and the sprite body
## (or floor) directly beneath it, after full desaturation.
func _marker_outline_contrast(body: Image, shape: Image, center: Vector2, radius: float) -> float:
	var outline_sum := 0.0
	var outline_cnt := 0
	var under_sum := 0.0
	var under_cnt := 0
	for y in CELL:
		for x in CELL:
			var inside := shape.get_pixel(x, y).a > 0.0
			if not inside:
				continue
			# A perimeter pixel has a non-shape 4-neighbour.
			var perim := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x < 0 or n.y < 0 or n.x >= CELL or n.y >= CELL or shape.get_pixel(n.x, n.y).a <= 0.0:
					perim = true
					break
			# TeamMarker.OUTLINE luma (the marker draws a dark keyline on its rim).
			var outline_luma := _luma(TeamMarker.OUTLINE)
			if perim:
				outline_sum += outline_luma
				outline_cnt += 1
			else:
				# Body luma under the marker fill (sprite if covered, else floor).
				var bp := body.get_pixel(x, y)
				under_sum += _luma(bp) if bp.a > 0.0 else _luma(TILE_FLOOR)
				under_cnt += 1
	if outline_cnt == 0 or under_cnt == 0:
		return 0.0
	var fg := outline_sum / float(outline_cnt)
	var bg := under_sum / float(under_cnt)
	return absf(fg - bg) / maxf(bg, 0.001)

# ============================================================================
# CRITERION 4 — frame-to-frame DRIFT across the four render states.
# The deterministic rig is engineered to eliminate the four drift modes the
# research flags (proportion / palette / line-weight / silhouette wobble):
#   * palette identity: idle and rescued share a pose -> must be pixel-identical.
#   * hue identity: every state recoloured to one team -> one constant hue.
#   * proportion identity: same-size poses' silhouette areas barely move.
# ============================================================================
func _criterion_frame_drift(src: Dictionary, rec0: Dictionary) -> void:
	print("[criterion] frame-to-frame drift across the four render states")

	# Palette/identity: rescued reuses the idle pose -> zero unwanted drift.
	var pixel_delta := _max_pixel_delta(src["idle"].gray, src["rescued"].gray)
	_metrics["idle_vs_rescued_max_pixel_delta"] = pixel_delta
	_check(pixel_delta == 0.0, "idle vs rescued is pixel-identical (max delta %.4f) — zero identity drift" % pixel_delta)

	# Hue identity: recolour every state to team 0; hue inside the mask is constant.
	var hues: Array[float] = []
	for st in STATES:
		hues.append(_mean_mask_hue(src[st].gray, src[st].mask, rec0[st]))
	var hue_spread: float = hues.max() - hues.min()
	_metrics["hue_spread_across_states"] = hue_spread
	_check(hue_spread <= DRIFT_HUE_MAX, "team hue is constant across all 4 states (spread %.4f <= %.4f)" % [hue_spread, DRIFT_HUE_MAX])

	# Proportion: same-size poses (idle/walk/rescued) barely change area; trapped
	# is an INTENTIONAL compression, reported separately (not counted as drift).
	var area := {}
	for st in STATES:
		area[st] = _coverage_count_img(src[st].gray)
	var base: float = float(area["idle"])
	var walk_drift: float = absf(float(area["walk"]) - base) / base
	var rescued_drift: float = absf(float(area["rescued"]) - base) / base
	_metrics["silhouette_area_px"] = area
	_metrics["walk_area_drift"] = walk_drift
	_metrics["rescued_area_drift"] = rescued_drift
	_metrics["trapped_area_ratio_intentional"] = float(area["trapped"]) / base
	_check(walk_drift <= DRIFT_AREA_MAX, "walk silhouette area within %.0f%% of idle (drift %.1f%%)" % [DRIFT_AREA_MAX * 100.0, walk_drift * 100.0])
	_check(rescued_drift <= DRIFT_AREA_MAX, "rescued silhouette area within %.0f%% of idle (drift %.1f%%)" % [DRIFT_AREA_MAX * 100.0, rescued_drift * 100.0])

# ============================================================================
# Small image / geometry / colour helpers.
# ============================================================================
func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

func _over_tile(rec: Image, tile: Color) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	out.fill(tile)
	for y in CELL:
		for x in CELL:
			var p := rec.get_pixel(x, y)
			if p.a > 0.0:
				out.set_pixel(x, y, Color(p.r, p.g, p.b, 1.0).lerp(tile, 1.0 - p.a))
	return out

func _coverage_image(gray: Image) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	for y in CELL:
		for x in CELL:
			var a := gray.get_pixel(x, y).a
			out.set_pixel(x, y, Color(a, a, a, 1.0))
	return out

func _coverage_count_img(gray: Image) -> int:
	var n := 0
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a > 0.0:
				n += 1
	return n

func _coverage_count(img: Image) -> int:
	var n := 0
	for y in CELL:
		for x in CELL:
			if img.get_pixel(x, y).a > 0.0:
				n += 1
	return n

func _coverage_xor_fraction(a: Image, b: Image) -> float:
	var diff := 0
	var union := 0
	for y in CELL:
		for x in CELL:
			var ina := a.get_pixel(x, y).a > 0.0
			var inb := b.get_pixel(x, y).a > 0.0
			if ina or inb:
				union += 1
			if ina != inb:
				diff += 1
	if union == 0:
		return 0.0
	return float(diff) / float(union)

func _max_pixel_delta(a: Image, b: Image) -> float:
	var worst := 0.0
	for y in CELL:
		for x in CELL:
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			worst = max(worst, absf(ca.r - cb.r))
			worst = max(worst, absf(ca.g - cb.g))
			worst = max(worst, absf(ca.b - cb.b))
			worst = max(worst, absf(ca.a - cb.a))
	return worst

## Mean hue of the recoloured pixels that the mask marked as tintable.
func _mean_mask_hue(gray: Image, mask: Image, rec: Image) -> float:
	var sx := 0.0
	var sy := 0.0
	var cnt := 0
	for y in CELL:
		for x in CELL:
			if mask.get_pixel(x, y).r > 0.5 and gray.get_pixel(x, y).a > 0.0:
				var h: float = rec.get_pixel(x, y).h * TAU
				sx += cos(h)
				sy += sin(h)
				cnt += 1
	if cnt == 0:
		return 0.0
	var ang := atan2(sy, sx)
	if ang < 0.0:
		ang += TAU
	return ang / TAU

func _hue_close(a: float, b: float, tol: float) -> bool:
	var d: float = absf(a - b)
	d = min(d, 1.0 - d)   # hue is circular
	return d <= tol

func _point_in_poly(p: Vector2, poly: PackedVector2Array) -> bool:
	var inside := false
	var n := poly.size()
	var j := n - 1
	for i in n:
		var a := poly[i]
		var b := poly[j]
		if (a.y > p.y) != (b.y > p.y):
			var xint := (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x
			if p.x < xint:
				inside = not inside
		j = i
	return inside

# ============================================================================
# Evidence artefacts (throwaway; out/ is gitignored). A proof sheet plus the raw
# grey/mask/recolour PNGs so a reviewer can eyeball the recipe.
# ============================================================================
func _scale_nn(img: Image, factor: int) -> Image:
	var out := img.duplicate()
	out.resize(CELL * factor, CELL * factor, Image.INTERPOLATE_NEAREST)
	return out

func _save(img: Image, name: String) -> void:
	img.save_png("%s/%s.png" % [OUT_DIR, name])

func _write_evidence(src: Dictionary, rec0: Dictionary, rec1: Dictionary, team0: Color, team1: Color) -> void:
	var F := 4   # 4x nearest-neighbour upscale for legibility
	# Raw idle grey + mask + both recolours.
	_save(_scale_nn(src["idle"].gray, F), "tote_idle_gray")
	_save(_scale_nn(_mask_view(src["idle"].mask, src["idle"].gray), F), "tote_idle_mask")
	_save(_scale_nn(rec0["idle"], F), "tote_idle_team0")
	_save(_scale_nn(rec1["idle"], F), "tote_idle_team1")

	# Proof sheet: rows = states; cols = grey, mask, team0/floor+marker,
	# team1/block+marker, squint(team0/floor). 4x upscaled.
	var cols := 5
	var rows := STATES.size()
	var cw := CELL * F
	var gap := 8
	var sheet := Image.create_empty(cols * cw + (cols + 1) * gap, rows * cw + (rows + 1) * gap, false, Image.FORMAT_RGBA8)
	sheet.fill(Color(0.10, 0.10, 0.13, 1.0))
	for r in rows:
		var st: String = STATES[r]
		var tiles := [
			_scale_nn(src[st].gray, F),
			_scale_nn(_mask_view(src[st].mask, src[st].gray), F),
			_scale_nn(_with_marker(_over_tile(rec0[st], TILE_FLOOR), 0), F),
			_scale_nn(_with_marker(_over_tile(rec1[st], TILE_BLOCK), 1), F),
			_scale_nn(_squint_view(rec0[st], TILE_FLOOR), F),
		]
		for c in cols:
			var dst := Vector2i(gap + c * (cw + gap), gap + r * (cw + gap))
			sheet.blit_rect(tiles[c], Rect2i(0, 0, cw, cw), dst)
	sheet.save_png("%s/proofsheet.png" % OUT_DIR)

## Render the mask as a visible overlay (tintable = cyan, neutral = grey) for review.
func _mask_view(mask: Image, gray: Image) -> Image:
	var out := Image.create_empty(CELL, CELL, false, Image.FORMAT_RGBA8)
	out.fill(Color(0, 0, 0, 0))
	for y in CELL:
		for x in CELL:
			if gray.get_pixel(x, y).a <= 0.0:
				continue
			var t := mask.get_pixel(x, y).r
			out.set_pixel(x, y, Color(0.1, 0.8, 0.9, 1.0) if t > 0.5 else Color(0.4, 0.4, 0.4, 1.0))
	return out

## Composite over tile, then draw the real TeamMarker shape on top (fill = team
## colour, dark OUTLINE), exactly as Game.gd layers the redundant cue.
func _with_marker(comp: Image, team: int) -> Image:
	var out := comp.duplicate()
	var center := Vector2(CELL / 2.0, CELL / 2.0)
	var radius := CELL * 0.38
	var shape := _marker_coverage(team, center, radius)
	var fill: Color = GameScript.TEAM_COLORS[team % GameScript.TEAM_COLORS.size()]
	for y in CELL:
		for x in CELL:
			if shape.get_pixel(x, y).a <= 0.0:
				continue
			var perim := false
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x < 0 or n.y < 0 or n.x >= CELL or n.y >= CELL or shape.get_pixel(n.x, n.y).a <= 0.0:
					perim = true
					break
			out.set_pixel(x, y, TeamMarker.OUTLINE if perim else fill)
	return out

func _squint_view(rec: Image, tile: Color) -> Image:
	var comp := _over_tile(rec, tile)
	comp.resize(11, 11, Image.INTERPOLATE_BILINEAR)
	comp.resize(CELL, CELL, Image.INTERPOLATE_NEAREST)
	return comp

func _write_metrics() -> void:
	_metrics["states"] = STATES
	_metrics["team_colors_used"] = [GameScript.TEAM_COLORS[0].to_html(), GameScript.TEAM_COLORS[1].to_html()]
	_metrics["checks"] = _checks
	_metrics["failures"] = _failures
	var f := FileAccess.open("%s/metrics.json" % OUT_DIR, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_metrics, "  "))
		f.close()

# ----------------------------------------------------------------------------
func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: ", msg)
	else:
		_failures += 1
		printerr("  FAIL: ", msg)
