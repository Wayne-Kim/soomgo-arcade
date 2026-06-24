extends SceneTree
## ============================================================================
## Deterministic sprite generator — materialises all five Soomgo master
## (cleaning, moving, interior, lesson, pet) characters as the shipping art sheets.
##
## Run:
##   Godot --headless --path . --editor --quit                                   # class cache once
##   Godot --headless --path . --script res://tools/gen_character_sprites.gd
##
## Writes, under assets/characters/:
##   <id>_base.png   grayscale form (NO hue, ever) — straight alpha
##   <id>_mask.png   team-tintable coverage (premultiplied) — runtime tint region
##   <id>.json       sheet manifest (geometry the renderer reads)
## ============================================================================

const OUT_DIR := "res://assets/characters"
const SRC := 80                       # source frame px (docs/character-art.md §B.1)
const COLS := 4
const ROWS := ["idle", "walk", "trapped"]
const FRAMES := {"idle": 2, "walk": 4, "trapped": 2}
const SCALE := float(SRC) / 44.0      # the validated rig is authored in 44-space

# Per-frame pose deltas (44-space): body offset + per-foot stride offset, and a
# figure scale used for the curled trapped state. Deterministic, no AI drift.
const POSES := {
	"idle_0":    {"dx": 0, "dy": 0,  "scale": 1.0, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
	"idle_1":    {"dx": 0, "dy": -1, "scale": 1.0, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
	"walk_0":    {"dx": 0, "dy": 0,  "scale": 1.0, "lfoot": Vector2i(2, -2), "rfoot": Vector2i(-1, 0)},
	"walk_1":    {"dx": 0, "dy": -1, "scale": 1.0, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
	"walk_2":    {"dx": 0, "dy": 0,  "scale": 1.0, "lfoot": Vector2i(-1, 0), "rfoot": Vector2i(2, -2)},
	"walk_3":    {"dx": 0, "dy": -1, "scale": 1.0, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
	"trapped_0": {"dx": 0, "dy": 2,  "scale": 0.8, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
	"trapped_1": {"dx": 1, "dy": 3,  "scale": 0.8, "lfoot": Vector2i(0, 0),  "rfoot": Vector2i(0, 0)},
}

# Pose transform state (44-space), reset per frame.
var _pscale := 1.0
var _pcx := 21.0
var _pcy := 21.0
var _pdx := 0
var _pdy := 0

func _initialize() -> void:
	print("== character sprite generator (all 5 masters) ==")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT_DIR))

	var ids: Array[String] = ["cleaning", "moving", "interior", "lesson", "pet"]
	for id: String in ids:
		var base: Image = Image.create_empty(COLS * SRC, ROWS.size() * SRC, false, Image.FORMAT_RGBA8)
		var mask: Image = Image.create_empty(COLS * SRC, ROWS.size() * SRC, false, Image.FORMAT_RGBA8)
		base.fill(Color(0, 0, 0, 0))
		mask.fill(Color(0, 0, 0, 0))

		for row: int in ROWS.size():
			var state: String = ROWS[row]
			for col: int in int(FRAMES[state]):
				var frame: Dictionary = _build_frame(id, "%s_%d" % [state, col])
				base.blit_rect(frame.base, Rect2i(0, 0, SRC, SRC), Vector2i(col * SRC, row * SRC))
				mask.blit_rect(frame.mask, Rect2i(0, 0, SRC, SRC), Vector2i(col * SRC, row * SRC))

		var base_path: String = OUT_DIR + "/" + id + "_base.png"
		var mask_path: String = OUT_DIR + "/" + id + "_mask.png"
		var err1: Error = base.save_png(base_path)
		var err2: Error = mask.save_png(mask_path)
		if err1 != OK or err2 != OK:
			printerr("save failed for ", id, ": base=", err1, " mask=", err2)
			quit(1)
			return

		var manifest: Dictionary = {
			"cell": SRC,
			"board_cell": 44,
			"cols": COLS,
			"rows": ROWS,
			"frames": FRAMES,
			"anchor_bottom_center": true,
			"derived_states": {"invuln": "runtime 0.55 alpha over active idle/walk frame"},
			"layers": {"base": id + "_base.png", "mask": id + "_mask.png"},
		}
		var f: FileAccess = FileAccess.open(OUT_DIR + "/" + id + ".json", FileAccess.WRITE)
		f.store_string(JSON.stringify(manifest, "\t"))
		f.close()

		print("wrote ", base_path, " ", mask_path, " ", id, ".json")
		print("  sheet ", base.get_width(), "x", base.get_height(),
			"  frames idle:%d walk:%d trapped:%d" % [FRAMES["idle"], FRAMES["walk"], FRAMES["trapped"]])
	quit(0)

# ---------------------------------------------------------------------------
# Rig builder — dispatches based on character ID.
# base is grayscale (rgb == luminance, a == coverage);
# mask is the team-tintable region (premultiplied coverage, rgb == a == tint factor).
# ---------------------------------------------------------------------------
func _build_frame(id: String, key: String) -> Dictionary:
	var g: Image = Image.create_empty(SRC, SRC, false, Image.FORMAT_RGBA8)
	var m: Image = Image.create_empty(SRC, SRC, false, Image.FORMAT_RGBA8)
	g.fill(Color(0, 0, 0, 0))
	m.fill(Color(0, 0, 0, 0))

	var pose: Dictionary = POSES[key]
	_pscale = pose["scale"]
	_pcx = 21.0
	_pcy = 21.0
	_pdx = pose["dx"]
	_pdy = pose["dy"]
	var lf: Vector2i = pose["lfoot"]
	var rf: Vector2i = pose["rfoot"]

	match id:
		"cleaning":
			_draw_sudsy(g, m, lf, rf)
		"moving":
			_draw_tote(g, m, lf, rf)
		"interior":
			_draw_rolly(g, m, lf, rf)
		"lesson":
			_draw_menty(g, m, lf, rf)
		"pet":
			_draw_paws(g, m, lf, rf)

	# 1px dark keyline (proven load-bearing, spike condition #2) — neutral, never tinted.
	_add_outline(g, m)
	return {"base": g, "mask": m}

# --- Character Drawings ---

## Sudsy / Cleaning — slim, lithe build; spray bottle & cloth; short apron (tinted)
func _draw_sudsy(g: Image, m: Image, lf: Vector2i, rf: Vector2i) -> void:
	# Head & Face
	_fill_rect(g, m, 18, 6, 26, 14, 0.88, 0.88, 0.0) # Face
	_fill_rect(g, m, 18, 5, 26, 7, 0.20, 0.20, 0.0) # Hair/Cap
	# Torso (Slim)
	_fill_rect(g, m, 17, 15, 27, 34, 0.80, 0.80, 0.0) # Shirt
	# Apron (team-tintable)
	_fill_rect(g, m, 17, 21, 27, 30, 0.90, 0.75, 1.0) # Apron body
	_fill_rect(g, m, 16, 20, 28, 20, 0.90, 0.90, 0.0) # Apron top strap / tie
	# Left Arm & Spray bottle prop
	_fill_rect(g, m, 13, 21, 16, 23, 0.80, 0.80, 0.0) # Left arm
	_fill_rect(g, m, 11, 23, 13, 28, 0.90, 0.90, 0.0) # Spray bottle body
	_fill_rect(g, m, 11, 21, 12, 22, 0.30, 0.30, 0.0) # Spray nozzle
	# Right Arm & Cleaning cloth prop
	_fill_rect(g, m, 28, 21, 30, 23, 0.80, 0.80, 0.0) # Right arm
	_fill_rect(g, m, 28, 24, 31, 28, 0.95, 0.95, 0.0) # Cleaning cloth hanging
	# Feet (poised, thin)
	_fill_rect(g, m, 18 + lf.x, 35 + lf.y, 20 + lf.x, 39 + lf.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 24 + rf.x, 35 + rf.y, 26 + rf.x, 39 + rf.y, 0.18, 0.18, 0.0)

## Tote / Moving — bulky, broad; stack of cardboard boxes; hand-truck; work gloves
func _draw_tote(g: Image, m: Image, lf: Vector2i, rf: Vector2i) -> void:
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
	_fill_rect(g, m, 12 + lf.x, 36 + lf.y, 19 + lf.x, 40 + lf.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 24 + rf.x, 36 + rf.y, 31 + rf.x, 40 + rf.y, 0.18, 0.18, 0.0)

## Rolly / Interior — tall, broad; paint-roller on a pole; overalls & painter's cap (tinted)
func _draw_rolly(g: Image, m: Image, lf: Vector2i, rf: Vector2i) -> void:
	# Painter's Cap (team-tintable)
	_fill_rect(g, m, 14, 2, 29, 7, 0.95, 0.85, 1.0) # Cap top
	_fill_rect(g, m, 13, 6, 30, 7, 0.85, 0.85, 0.0) # Cap brim
	# Head & Face
	_fill_rect(g, m, 15, 8, 28, 14, 0.88, 0.88, 0.0) # Face
	# Torso (Tall, broad)
	_fill_rect(g, m, 12, 15, 31, 18, 0.90, 0.90, 0.0) # Shirt top
	# Bib overalls (team-tintable)
	_fill_rect(g, m, 12, 19, 31, 35, 0.80, 0.50, 1.0) # Overalls
	_fill_rect(g, m, 14, 15, 16, 18, 0.80, 0.80, 1.0) # Left strap
	_fill_rect(g, m, 27, 15, 29, 18, 0.80, 0.80, 1.0) # Right strap
	# Arm left
	_fill_rect(g, m, 8, 17, 11, 23, 0.80, 0.80, 0.0)
	# Paint-roller pole (over right shoulder)
	_fill_line(g, m, 7, 36, 25, 2, 0.35, 0.0) # Pole
	_fill_rect(g, m, 22, 0, 28, 4, 0.95, 0.95, 0.0) # Roller brush
	# Feet
	_fill_rect(g, m, 12 + lf.x, 36 + lf.y, 19 + lf.x, 40 + lf.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 24 + rf.x, 36 + rf.y, 31 + rf.x, 40 + rf.y, 0.18, 0.18, 0.0)

## Menty / Lesson — upright, neat build; coach polo (tinted); whistle & pointer
func _draw_menty(g: Image, m: Image, lf: Vector2i, rf: Vector2i) -> void:
	# Head & Face
	_fill_rect(g, m, 16, 6, 27, 14, 0.88, 0.88, 0.0) # Face
	_fill_rect(g, m, 16, 4, 27, 6, 0.20, 0.20, 0.0) # Hair
	# Torso (average proportions)
	_fill_rect(g, m, 14, 15, 29, 34, 0.85, 0.60, 1.0) # Coach polo (team-tintable)
	# Collar (neutral)
	_fill_rect(g, m, 18, 15, 25, 16, 0.30, 0.30, 0.0)
	# Lanyard and whistle
	_fill_line(g, m, 21, 16, 21, 22, 0.15, 0.0) # Lanyard
	_fill_rect(g, m, 20, 22, 22, 24, 0.95, 0.95, 0.0) # Whistle
	# Left Arm & Pointer Stick
	_fill_rect(g, m, 10, 18, 13, 23, 0.88, 0.88, 0.0) # Left arm
	_fill_line(g, m, 11, 22, 5, 28, 0.90, 0.0) # Pointer stick
	# Right Arm
	_fill_rect(g, m, 30, 18, 33, 23, 0.88, 0.88, 0.0) # Right arm
	# Feet
	_fill_rect(g, m, 13 + lf.x, 35 + lf.y, 20 + lf.x, 39 + lf.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 23 + rf.x, 35 + rf.y, 30 + rf.x, 39 + rf.y, 0.18, 0.18, 0.0)

## Paws / Pet — small, rounded, compact; hoodie/cap (tinted) with ears; paw print; leash
func _draw_paws(g: Image, m: Image, lf: Vector2i, rf: Vector2i) -> void:
	# Rounded cap ears
	_fill_disc(g, m, 15, 9, 3, 0.20, 0.0) # Left ear
	_fill_disc(g, m, 29, 9, 3, 0.20, 0.0) # Right ear
	# Head & Face (tinted hoodie cap)
	_fill_rect(g, m, 16, 10, 28, 19, 0.85, 0.65, 1.0) # Hoodie cap
	_fill_rect(g, m, 18, 13, 26, 18, 0.88, 0.88, 0.0) # Face
	# Torso (crouched, compact, tinted hoodie)
	_fill_rect(g, m, 15, 20, 29, 33, 0.80, 0.60, 1.0)
	# Paw-print patch (neutral)
	_fill_rect(g, m, 20, 24, 24, 28, 0.95, 0.95, 0.0) # Patch background
	_fill_rect(g, m, 22, 22, 22, 23, 0.15, 0.15, 0.0) # Paw pad center
	_fill_rect(g, m, 20, 25, 20, 25, 0.15, 0.15, 0.0) # Toe
	_fill_rect(g, m, 24, 25, 24, 25, 0.15, 0.15, 0.0) # Toe
	# Left Arm & Leash
	_fill_rect(g, m, 11, 22, 14, 25, 0.88, 0.88, 0.0) # Left arm
	_fill_rect(g, m, 7, 24, 11, 28, 0.70, 0.70, 0.0) # Leash coil body
	_fill_rect(g, m, 8, 25, 10, 27, 0.0, 0.0, 0.0) # Hollow leash center
	# Right Arm
	_fill_rect(g, m, 30, 22, 33, 25, 0.88, 0.88, 0.0) # Right arm
	# Feet (crouched, slightly lower)
	_fill_rect(g, m, 14 + lf.x, 34 + lf.y, 20 + lf.x, 38 + lf.y, 0.18, 0.18, 0.0)
	_fill_rect(g, m, 24 + rf.x, 34 + rf.y, 30 + rf.x, 38 + rf.y, 0.18, 0.18, 0.0)

# --- Drawing Utilities ---

# 44-space -> SRC-space transform with per-frame pose.
func _tx(x: float) -> int:
	return int(round((_pcx + (x - _pcx) * _pscale + _pdx) * SCALE))

func _ty(y: float) -> int:
	return int(round((_pcy + (y - _pcy) * _pscale + _pdy) * SCALE))

func _set_px(g: Image, m: Image, px: int, py: int, lum: float, tint: float) -> void:
	# Fill the SRC/44 block for one rig pixel so the scaled-up figure has no gaps.
	var step := int(ceil(SCALE))
	for oy: int in step:
		for ox: int in step:
			var x: int = px + ox
			var y: int = py + oy
			if x < 0 or y < 0 or x >= SRC or y >= SRC:
				continue
			g.set_pixel(x, y, Color(lum, lum, lum, 1.0))
			m.set_pixel(x, y, Color(tint, tint, tint, tint))

func _fill_rect(g: Image, m: Image, x0: int, y0: int, x1: int, y1: int,
		lum_top: float, lum_bot: float, tint: float) -> void:
	for y: int in range(y0, y1 + 1):
		var f: float = 0.0 if y1 == y0 else float(y - y0) / float(y1 - y0)
		var lum: float = lerpf(lum_top, lum_bot, f)
		for x: int in range(x0, x1 + 1):
			_set_px(g, m, _tx(x), _ty(y), lum, tint)

func _fill_disc(g: Image, m: Image, cx: int, cy: int, r: int, lum: float, tint: float) -> void:
	for y: int in range(cy - r, cy + r + 1):
		for x: int in range(cx - r, cx + r + 1):
			var dx: int = x - cx
			var dy: int = y - cy
			if dx * dx + dy * dy <= r * r:
				_set_px(g, m, _tx(x), _ty(y), lum, tint)

func _fill_line(g: Image, m: Image, x0: int, y0: int, x1: int, y1: int, lum: float, tint: float) -> void:
	var dx: int = abs(x1 - x0)
	var dy: int = abs(y1 - y0)
	var sx: int = 1 if x0 < x1 else -1
	var sy: int = 1 if y0 < y1 else -1
	var err: int = dx - dy
	var x: int = x0
	var y: int = y0
	while true:
		_set_px(g, m, _tx(x), _ty(y), lum, tint)
		if x == x1 and y == y1:
			break
		var e2: int = 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy

## 1px dark outline on every transparent pixel that touches coverage.
func _add_outline(g: Image, m: Image) -> void:
	var ring: Array[Vector2i] = []
	for y: int in SRC:
		for x: int in SRC:
			if g.get_pixel(x, y).a > 0.0:
				continue
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = Vector2i(x, y) + d
				if n.x >= 0 and n.y >= 0 and n.x < SRC and n.y < SRC and g.get_pixel(n.x, n.y).a > 0.0:
					ring.append(Vector2i(x, y))
					break
	for p: Vector2i in ring:
		g.set_pixel(p.x, p.y, Color(0.05, 0.05, 0.05, 1.0))
		m.set_pixel(p.x, p.y, Color(0, 0, 0, 0))
