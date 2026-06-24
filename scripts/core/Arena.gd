class_name Arena
extends RefCounted
## Grid model: hard walls (indestructible), soft blocks (destructible) and floor.
## Holds power-ups revealed when a soft block is destroyed. No rendering here.

var width: int
var height: int
var _tiles: PackedInt32Array          # row-major, Spec.Tile values
var _powerups: Dictionary = {}        # Vector2i -> Spec.PowerUp (hidden under soft blocks / on floor)

func _init(w: int = 15, h: int = 13) -> void:
	width = w
	height = h
	_tiles = PackedInt32Array()
	_tiles.resize(w * h)
	for i in _tiles.size():
		_tiles[i] = Spec.Tile.FLOOR

func _idx(c: Vector2i) -> int:
	return c.y * width + c.x

func in_bounds(c: Vector2i) -> bool:
	return c.x >= 0 and c.y >= 0 and c.x < width and c.y < height

func get_tile(c: Vector2i) -> int:
	if not in_bounds(c):
		return Spec.Tile.HARD_WALL
	return _tiles[_idx(c)]

func set_tile(c: Vector2i, t: int) -> void:
	if in_bounds(c):
		_tiles[_idx(c)] = t

func is_walkable(c: Vector2i) -> bool:
	return get_tile(c) == Spec.Tile.FLOOR

func is_blocking(c: Vector2i) -> bool:
	## Stops explosion propagation and movement.
	var t := get_tile(c)
	return t == Spec.Tile.HARD_WALL or t == Spec.Tile.SOFT_BLOCK

func get_powerup(c: Vector2i) -> int:
	return _powerups.get(c, Spec.PowerUp.NONE)

func set_powerup(c: Vector2i, p: int) -> void:
	if p == Spec.PowerUp.NONE:
		_powerups.erase(c)
	else:
		_powerups[c] = p

func destroy_block(c: Vector2i) -> void:
	if get_tile(c) == Spec.Tile.SOFT_BLOCK:
		set_tile(c, Spec.Tile.FLOOR)

## Default symmetric arena (the "classic" map): border + pillar grid (hard) with soft blocks
## filling the rest, leaving the spawn corners and their immediate neighbours clear. Kept as a
## thin alias of generate("classic", ...) so existing callers and saved behaviour are unchanged.
static func generate_default(w: int, h: int, spawns: Array, rng: DetRng) -> Arena:
	return _gen_classic(w, h, spawns, rng)

## Build the arena for a chosen map id. Every layout is deterministic from (id, w, h, rng), so
## peers that share the seed + map produce byte-identical arenas. An unknown id falls back to
## the classic layout. The classic path is preserved verbatim (no behaviour change).
static func generate(map_id: String, w: int, h: int, spawns: Array, rng: DetRng) -> Arena:
	var id := Maps.sanitize(map_id)
	if id == "classic":
		return _gen_classic(w, h, spawns, rng)
	var a := Arena.new(w, h)
	# Hard border.
	for y in h:
		for x in w:
			if x == 0 or y == 0 or x == w - 1 or y == h - 1:
				a.set_tile(Vector2i(x, y), Spec.Tile.HARD_WALL)
	# Map-specific hard-wall pattern + its soft-block density.
	var soft_pct := 45
	match id:
		"open":
			soft_pct = 30
		"cross":
			_walls_cross(a)
			soft_pct = 50
		"pinwheel":
			_walls_pinwheel(a)
			soft_pct = 45
	_fill_soft_and_powerups(a, spawns, soft_pct, rng)
	return a

## The original classic generator — border + even/even pillars + soft blocks everywhere else,
## spawns cleared, power-ups seeded. Unchanged so its output stays byte-identical.
static func _gen_classic(w: int, h: int, spawns: Array, rng: DetRng) -> Arena:
	var a := Arena.new(w, h)
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if x == 0 or y == 0 or x == w - 1 or y == h - 1:
				a.set_tile(c, Spec.Tile.HARD_WALL)
			elif x % 2 == 0 and y % 2 == 0:
				a.set_tile(c, Spec.Tile.HARD_WALL)
			else:
				a.set_tile(c, Spec.Tile.SOFT_BLOCK)
	# Keep spawn cells and orthogonal neighbours clear so players never start boxed in.
	for s in spawns:
		for off in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
			var c: Vector2i = s + off
			if a.get_tile(c) == Spec.Tile.SOFT_BLOCK:
				a.set_tile(c, Spec.Tile.FLOOR)
	# Seed power-ups under remaining soft blocks.
	for y in h:
		for x in w:
			var c := Vector2i(x, y)
			if a.get_tile(c) == Spec.Tile.SOFT_BLOCK and rng.chance(Spec.POWERUP_DROP_NUM, Spec.POWERUP_DROP_DEN):
				a.set_powerup(c, 1 + rng.below(3))  # BALLOON/RANGE/SPEED
	return a

## Finish a non-classic map after its hard-wall pattern is placed: fill the open interior with
## soft blocks at `soft_pct` density (skipping the protected spawn cells), force the spawn cells +
## their orthogonal neighbours clear LAST (this also punches any wall the pattern placed on a
## spawn, so a player can never start boxed in), then seed power-ups under the soft blocks.
static func _fill_soft_and_powerups(a: Arena, spawns: Array, soft_pct: int, rng: DetRng) -> void:
	var w := a.width
	var h := a.height
	var protected := _spawn_protected(spawns)
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var c := Vector2i(x, y)
			if protected.has(c):
				continue
			if a.get_tile(c) == Spec.Tile.FLOOR and rng.chance(soft_pct, 100):
				a.set_tile(c, Spec.Tile.SOFT_BLOCK)
	for c in protected:
		if c.x > 0 and c.y > 0 and c.x < w - 1 and c.y < h - 1:
			a.set_tile(c, Spec.Tile.FLOOR)
	for y in range(1, h - 1):
		for x in range(1, w - 1):
			var c := Vector2i(x, y)
			if a.get_tile(c) == Spec.Tile.SOFT_BLOCK and rng.chance(Spec.POWERUP_DROP_NUM, Spec.POWERUP_DROP_DEN):
				a.set_powerup(c, 1 + rng.below(3))

## Spawn cells + their orthogonal neighbours, kept clear so players are never boxed in.
static func _spawn_protected(spawns: Array) -> Dictionary:
	var p: Dictionary = {}
	for s in spawns:
		for off in [Vector2i.ZERO, Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
			p[s + off] = true
	return p

## "Crossroads": a central hard-wall plus whose arms stop short of the border, so the four
## quadrants stay connected around the arm ends (and the edge-midpoint spawns stay open).
static func _walls_cross(a: Arena) -> void:
	var midx := a.width / 2
	var midy := a.height / 2
	var x0 := a.width / 4
	var x1 := a.width - 1 - a.width / 4
	var y0 := a.height / 4
	var y1 := a.height - 1 - a.height / 4
	for x in range(x0, x1 + 1):
		a.set_tile(Vector2i(x, midy), Spec.Tile.HARD_WALL)
	for y in range(y0, y1 + 1):
		a.set_tile(Vector2i(midx, y), Spec.Tile.HARD_WALL)

## "Pinwheel": four short hard-wall bars placed with 2-fold point symmetry (matching the spawn
## layout's symmetry). They are small and isolated, so the otherwise-open interior stays fully
## connected while giving cover and rotational character.
static func _walls_pinwheel(a: Arena) -> void:
	var qx := a.width / 4
	var qy := a.height / 4
	var tqx := a.width - 1 - qx
	# One horizontal bar (upper-left) and one vertical bar (upper-right); each is mirrored
	# through the centre to its point-symmetric partner.
	var bars: Array = [
		[Vector2i(qx - 1, qy), Vector2i(qx, qy), Vector2i(qx + 1, qy)],
		[Vector2i(tqx, qy - 1), Vector2i(tqx, qy), Vector2i(tqx, qy + 1)],
	]
	for bar in bars:
		for c in bar:
			a.set_tile(c, Spec.Tile.HARD_WALL)
			a.set_tile(Vector2i(a.width - 1 - c.x, a.height - 1 - c.y), Spec.Tile.HARD_WALL)

## Evenly distributed corner/edge spawn cells for up to 8 players.
static func default_spawns(w: int, h: int) -> Array:
	var midx := w / 2
	var midy := h / 2
	return [
		Vector2i(1, 1),
		Vector2i(w - 2, h - 2),
		Vector2i(w - 2, 1),
		Vector2i(1, h - 2),
		Vector2i(midx, 1),
		Vector2i(midx, h - 2),
		Vector2i(1, midy),
		Vector2i(w - 2, midy),
	]

## --- Deterministic serialization (rollback/desync diagnostics) ---------------
## Bytes are written in a fixed order with power-up keys sorted by row-major index, so
## two arenas with identical contents always produce byte-identical output (stable hash).
func write_into(buf: StreamPeerBuffer) -> void:
	buf.put_32(width)
	buf.put_32(height)
	for t in _tiles:
		buf.put_8(t)
	var keys: Array = _powerups.keys()
	keys.sort_custom(func(a, b): return _idx(a) < _idx(b))
	buf.put_32(keys.size())
	for c in keys:
		buf.put_32(c.x)
		buf.put_32(c.y)
		buf.put_8(_powerups[c])

static func read_from(buf: StreamPeerBuffer) -> Arena:
	var w := buf.get_32()
	var h := buf.get_32()
	var a := Arena.new(w, h)
	for i in w * h:
		a._tiles[i] = buf.get_8()
	var n := buf.get_32()
	for _i in n:
		var x := buf.get_32()
		var y := buf.get_32()
		var p := buf.get_8()
		a._powerups[Vector2i(x, y)] = p
	return a
