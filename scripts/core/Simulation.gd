class_name Simulation
extends RefCounted
## Deterministic, scene-tree-free game simulation. Fixed-step `step()` drives
## movement, balloon fuses, chain explosions, trapping, rescue and round resolution.
## Rendering/UI layers read state + listen to signals; headless tests drive it directly.

signal balloon_placed(player_id: int, cell: Vector2i)
signal explosion_happened(cells: Array)
signal block_destroyed(cell: Vector2i)
signal player_trapped(player_id: int, cell: Vector2i)
signal player_rescued(player_id: int, by_id: int)
signal player_eliminated(player_id: int, cause: String)
signal powerup_collected(player_id: int, kind: int)
signal round_over(winner_team: int)
signal skill_used(player_id: int, character_key: String)

var arena: Arena
var players: Array[PlayerState] = []
var balloons: Array[Balloon] = []
var bubbles: Array[Bubble] = []
var explosions: Dictionary = {}        # Vector2i -> remaining lethal ticks (int)
var rng := DetRng.new()
var finished: bool = false
var winner_team: int = -1
var map_id: String = Maps.DEFAULT_ID    # which arena layout was generated (render/reference only)
var tick: int = 0                       # whole fixed ticks elapsed (deterministic clock)
var active_paints: Dictionary = {}      # Vector2i -> { "team": int, "ticks_left": int }

const SKILLS: Dictionary = {
	"cleaning": preload("res://scripts/core/skills/SlipperyDash.gd"),
	"moving": preload("res://scripts/core/skills/CargoPush.gd"),
	"interior": preload("res://scripts/core/skills/RollerCoating.gd"),
	"lesson": preload("res://scripts/core/skills/WhistleBlow.gd"),
	"pet": preload("res://scripts/core/skills/LeashRetrieve.gd")
}

# Cache of each character's full skill cooldown (ticks), so the UI can render a recharge
# gauge without instantiating a skill every frame. Read-only; never affects the sim.
static var _skill_cooldown_cache: Dictionary = {}

## The full cooldown in ticks for a character's unique skill (0 when it has none). Used by
## the HUD to show how close the skill is to ready; does not touch simulation state.
static func skill_cooldown_max(character_key: String) -> int:
	if _skill_cooldown_cache.has(character_key):
		return _skill_cooldown_cache[character_key]
	var ticks := 0
	if SKILLS.has(character_key):
		ticks = SKILLS[character_key].new().get_cooldown_ticks()
	_skill_cooldown_cache[character_key] = ticks
	return ticks

# Roller Coating paint movement multipliers, expressed as integer ratios so the
# fixed-point speed stays fully deterministic (no float maths in the sim).
const PAINT_FRIENDLY_SPEED_NUM: int = 3
const PAINT_FRIENDLY_SPEED_DEN: int = 2
const PAINT_ENEMY_SPEED_NUM: int = 1
const PAINT_ENEMY_SPEED_DEN: int = 2

func _init(player_defs: Array, w: int = 15, h: int = 13, seed_value: int = 0, p_map_id: String = Maps.DEFAULT_ID) -> void:
	rng.state = seed_value
	map_id = Maps.sanitize(p_map_id)
	var n: int = clampi(player_defs.size(), 0, Spec.MAX_PLAYERS)
	var spawns := Arena.default_spawns(w, h)
	for i in n:
		var def: Dictionary = player_defs[i]
		var team: int = def.get("team", i)
		var pname: String = def.get("name", "P%d" % (i + 1))
		var ps := PlayerState.new(i, team, spawns[i], pname)
		# Apply the chosen Soomgo master's starting stat profile (range/balloons/speed).
		ps.character_key = def.get("character", "")
		Characters.apply_start_stats(ps, ps.character_key)
		players.append(ps)
	arena = Arena.generate(map_id, w, h, spawns.slice(0, n), rng)

func get_player(id: int) -> PlayerState:
	for p in players:
		if p.id == id:
			return p
	return null

func set_input(id: int, dir: Vector2i, place: bool, skill: bool = false) -> void:
	var p := get_player(id)
	if p == null:
		return
	p.input_dir = dir
	if place:
		p.input_place = true
	if skill:
		p.input_skill = true

func occupied_cell(p: PlayerState) -> Vector2i:
	if p.moving and p.move_progress >= Fixed.HALF:
		return p.move_target
	return p.cell

func _balloon_at(cell: Vector2i) -> Balloon:
	for b in balloons:
		if b.cell == cell:
			return b
	return null

func _bubble_for(id: int) -> Bubble:
	for b in bubbles:
		if b.victim_id == id:
			return b
	return null

func _can_enter(cell: Vector2i) -> bool:
	return arena.is_walkable(cell) and _balloon_at(cell) == null

# ---------------------------------------------------------------------------
## Advance exactly one fixed tick. The `delta` argument is accepted for call-site
## compatibility but deliberately ignored: simulated time is the integer tick count, so
## the result never depends on frame timing (acceptance criterion 1).
func step(_delta: float = Spec.TICK_DELTA) -> void:
	if finished:
		return
	tick += 1
	_update_players()
	_update_balloons()
	_update_explosions()
	_update_paints()
	_resolve_explosion_hits()
	_update_bubbles()
	_check_round_over()

func elapsed_seconds() -> float:
	## Display-only wall-clock estimate; never fed back into the simulation.
	return float(tick) * Spec.TICK_DELTA

## Whole ticks left before the hard round limit (HUD countdown source; never < 0).
func remaining_ticks() -> int:
	return maxi(0, Spec.ROUND_LIMIT_TICKS - tick)

## Display-only seconds left before the hard round limit.
func remaining_seconds() -> float:
	return float(remaining_ticks()) * Spec.TICK_DELTA

func _update_players() -> void:
	for p in players:
		if p.invuln_timer > 0:
			p.invuln_timer -= 1
		if p.skill_cooldown > 0:
			p.skill_cooldown -= 1
		if p.stun_timer > 0:
			p.stun_timer -= 1
		if not p.can_act():
			p.input_skill = false
			continue
		if p.input_dir != Vector2i.ZERO:
			p.facing = p.input_dir
		# Use a unique skill before moving so a dash/knockback resolves this tick.
		if p.input_skill:
			p.input_skill = false
			_try_use_skill(p)
		# Advance an in-progress step (fixed-point cells/second -> cells/tick).
		if p.moving:
			p.move_progress += _effective_speed(p) / Spec.TICK_RATE
			if p.move_progress >= Fixed.ONE:
				p.cell = p.move_target
				p.moving = false
				p.move_progress = 0
				_pickup(p)
		# Start a new step if idle and input requests one.
		if not p.moving and p.input_dir != Vector2i.ZERO:
			var target: Vector2i = p.cell + p.input_dir
			if _can_enter(target):
				p.move_target = target
				p.moving = true
				p.move_progress = 0
		# Place a balloon.
		if p.input_place:
			p.input_place = false
			_try_place_balloon(p)

## Fixed-point movement speed for this tick, adjusted by any Roller Coating paint the
## player currently stands on: a team's own paint speeds it up, an enemy's slows it down.
func _effective_speed(p: PlayerState) -> int:
	var paint: Variant = active_paints.get(p.cell)
	if paint == null:
		return p.speed
	if paint["team"] == p.team:
		return p.speed * PAINT_FRIENDLY_SPEED_NUM / PAINT_FRIENDLY_SPEED_DEN
	return p.speed * PAINT_ENEMY_SPEED_NUM / PAINT_ENEMY_SPEED_DEN

## Cast the caster's character-unique skill if it is off cooldown. A successful cast
## (the skill actually affected the world) starts the cooldown and emits `skill_used`.
func _try_use_skill(p: PlayerState) -> void:
	if p.skill_cooldown > 0:
		return
	if not SKILLS.has(p.character_key):
		return
	var skill: CharacterSkill = SKILLS[p.character_key].new()
	if skill.execute(self, p):
		p.skill_cooldown = skill.get_cooldown_ticks()
		skill_used.emit(p.id, p.character_key)

## Age every active Roller Coating paint patch and drop the ones that have worn off.
func _update_paints() -> void:
	if active_paints.is_empty():
		return
	var expired: Array = []
	for c in active_paints:
		active_paints[c]["ticks_left"] -= 1
		if active_paints[c]["ticks_left"] <= 0:
			expired.append(c)
	for c in expired:
		active_paints.erase(c)

func _pickup(p: PlayerState) -> void:
	var pu := arena.get_powerup(p.cell)
	if pu == Spec.PowerUp.NONE:
		return
	arena.set_powerup(p.cell, Spec.PowerUp.NONE)
	match pu:
		Spec.PowerUp.BALLOON:
			p.max_balloons = Spec.clamp_balloons(p.max_balloons + 1)
		Spec.PowerUp.RANGE:
			p.range = Spec.clamp_range(p.range + 1)
		Spec.PowerUp.SPEED:
			p.speed = Spec.clamp_speed(p.speed + Spec.SPEED_STEP_FP)
	powerup_collected.emit(p.id, pu)

func _try_place_balloon(p: PlayerState) -> void:
	if p.active_balloons >= p.max_balloons:
		return
	if _balloon_at(p.cell) != null:
		return
	balloons.append(Balloon.new(p.cell, p.id, p.range))
	p.active_balloons += 1
	balloon_placed.emit(p.id, p.cell)

func _update_balloons() -> void:
	for b in balloons:
		b.fuse -= 1
		if b.fuse <= 0:
			b.detonating = true
	# Resolve detonations + chain reactions.
	var any := false
	for b in balloons:
		if b.detonating:
			any = true
			break
	if any:
		_detonate_chain()

func _detonate_chain() -> void:
	var exploded_cells: Dictionary = {}
	var processed: Array[Balloon] = []
	var changed := true
	while changed:
		changed = false
		for b in balloons:
			if b.detonating and not processed.has(b):
				processed.append(b)
				changed = true
				_blast(b, exploded_cells)
	# Apply explosion cells (lethal for EXPLOSION_TICKS), free owners' balloon slots.
	for cell in exploded_cells:
		explosions[cell] = Spec.EXPLOSION_TICKS
	for b in processed:
		var owner := get_player(b.owner_id)
		if owner != null:
			owner.active_balloons = maxi(0, owner.active_balloons - 1)
		balloons.erase(b)
	if not exploded_cells.is_empty():
		explosion_happened.emit(exploded_cells.keys())

func _blast(b: Balloon, out_cells: Dictionary) -> void:
	out_cells[b.cell] = true
	for dir in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]:
		for step_i in range(1, b.range + 1):
			var c: Vector2i = b.cell + dir * step_i
			var t := arena.get_tile(c)
			if t == Spec.Tile.HARD_WALL:
				break
			if t == Spec.Tile.SOFT_BLOCK:
				arena.destroy_block(c)
				block_destroyed.emit(c)
				out_cells[c] = true        # explosion fills the block's cell, then stops
				break
			out_cells[c] = true
			# Chain: a balloon in the path detonates too.
			var hit := _balloon_at(c)
			if hit != null and not hit.detonating:
				hit.detonating = true

func _update_explosions() -> void:
	var expired: Array = []
	for cell in explosions:
		explosions[cell] -= 1
		if explosions[cell] <= 0:
			expired.append(cell)
	for cell in expired:
		explosions.erase(cell)

func _resolve_explosion_hits() -> void:
	for p in players:
		if not p.can_act() or p.invuln_timer > 0:
			continue
		var cell := occupied_cell(p)
		if explosions.has(cell):
			_trap(p)

func _trap(p: PlayerState) -> void:
	p.trapped = true
	p.moving = false
	p.move_progress = 0
	p.trap_timer = Spec.BUBBLE_TICKS
	bubbles.append(Bubble.new(p.cell, p.id, p.team))
	player_trapped.emit(p.id, p.cell)

func _update_bubbles() -> void:
	var to_remove: Array[Bubble] = []
	for bub in bubbles:
		bub.timer -= 1
		var victim := get_player(bub.victim_id)
		# Find a rescuer/popper standing on the bubble.
		var teammate_present := false
		var enemy_present := false
		for other in players:
			if other.id == bub.victim_id or not other.can_act():
				continue
			if occupied_cell(other) == bub.cell:
				if other.team == bub.team:
					teammate_present = true
				else:
					enemy_present = true
		if teammate_present:
			_rescue(victim)
			to_remove.append(bub)
		elif enemy_present:
			_eliminate(victim, "popped")
			to_remove.append(bub)
		elif bub.timer <= 0:
			_eliminate(victim, "drowned")
			to_remove.append(bub)
	for bub in to_remove:
		bubbles.erase(bub)

func _rescue(p: PlayerState) -> void:
	if p == null:
		return
	p.trapped = false
	p.trap_timer = 0
	p.invuln_timer = Spec.RESCUE_INVULN_TICKS
	player_rescued.emit(p.id, p.id)

func _eliminate(p: PlayerState, cause: String) -> void:
	if p == null:
		return
	p.trapped = false
	p.alive = false
	player_eliminated.emit(p.id, cause)

func _check_round_over() -> void:
	var live_teams: Dictionary = {}
	for p in players:
		if p.alive:
			live_teams[p.team] = true
	if live_teams.size() <= 1:
		finished = true
		winner_team = live_teams.keys()[0] if live_teams.size() == 1 else -1
		round_over.emit(winner_team)
		return
	# Hard cap: if the deterministic time limit is reached with more than one team still
	# alive, the round resolves to a draw (no series point) — the same outcome as the
	# no-survivors path — so the party is never stuck and round_over is emitted exactly once.
	if tick >= Spec.ROUND_LIMIT_TICKS:
		finished = true
		winner_team = -1
		round_over.emit(winner_team)

func living_players() -> int:
	var n := 0
	for p in players:
		if p.alive:
			n += 1
	return n

# ---------------------------------------------------------------------------
## Whole-state serialization (acceptance criterion 4: one-shot save/restore, rollback-ready).
## Every field that influences future ticks — tick clock, RNG state, arena, all entities and
## their fixed-point/integer fields — is written in a fixed order so the byte stream is a
## complete, deterministic snapshot. No floats are ever serialized.
const SNAPSHOT_VERSION: int = 4

func write_snapshot() -> PackedByteArray:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_32(SNAPSHOT_VERSION)
	buf.put_32(tick)
	buf.put_8(1 if finished else 0)
	buf.put_32(winner_team)
	buf.put_64(rng.state)
	arena.write_into(buf)
	buf.put_32(players.size())
	for p in players:
		_write_player(buf, p)
	buf.put_32(balloons.size())
	for b in balloons:
		buf.put_32(b.cell.x); buf.put_32(b.cell.y)
		buf.put_32(b.owner_id); buf.put_32(b.range)
		buf.put_32(b.fuse); buf.put_8(1 if b.detonating else 0)
	buf.put_32(bubbles.size())
	for bub in bubbles:
		buf.put_32(bub.cell.x); buf.put_32(bub.cell.y)
		buf.put_32(bub.victim_id); buf.put_32(bub.team); buf.put_32(bub.timer)
	var ex_keys: Array = explosions.keys()
	ex_keys.sort_custom(func(a, c): return (a.y * arena.width + a.x) < (c.y * arena.width + c.x))
	buf.put_32(ex_keys.size())
	for c in ex_keys:
		buf.put_32(c.x); buf.put_32(c.y); buf.put_32(explosions[c])
	# Active paints serialization
	var pt_keys: Array = active_paints.keys()
	pt_keys.sort_custom(func(a, c): return (a.y * arena.width + a.x) < (c.y * arena.width + c.x))
	buf.put_32(pt_keys.size())
	for c in pt_keys:
		buf.put_32(c.x); buf.put_32(c.y)
		buf.put_32(active_paints[c]["team"])
		buf.put_32(active_paints[c]["ticks_left"])
	return buf.data_array

## Restore this simulation in place from a snapshot (rollback). After this call the sim
## continues bit-identically to the original that produced the bytes.
func read_snapshot(data: PackedByteArray) -> void:
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.data_array = data
	var version := buf.get_32()
	assert(version == SNAPSHOT_VERSION, "unsupported snapshot version")
	tick = buf.get_32()
	finished = buf.get_8() != 0
	winner_team = buf.get_32()
	rng = DetRng.new(buf.get_64())
	arena = Arena.read_from(buf)
	players.clear()
	var pn := buf.get_32()
	for _i in pn:
		players.append(_read_player(buf))
	balloons.clear()
	var bn := buf.get_32()
	for _i in bn:
		var b := Balloon.new(Vector2i(buf.get_32(), buf.get_32()), buf.get_32(), buf.get_32())
		b.fuse = buf.get_32()
		b.detonating = buf.get_8() != 0
		balloons.append(b)
	bubbles.clear()
	var bbn := buf.get_32()
	for _i in bbn:
		var bub := Bubble.new(Vector2i(buf.get_32(), buf.get_32()), buf.get_32(), buf.get_32())
		bub.timer = buf.get_32()
		bubbles.append(bub)
	explosions.clear()
	var en := buf.get_32()
	for _i in en:
		var c := Vector2i(buf.get_32(), buf.get_32())
		explosions[c] = buf.get_32()
	active_paints.clear()
	var ptn := buf.get_32()
	for _i in ptn:
		var c := Vector2i(buf.get_32(), buf.get_32())
		active_paints[c] = {
			"team": buf.get_32(),
			"ticks_left": buf.get_32()
		}

## 64-bit FNV-1a state hash for per-frame desync detection (criterion 3).
func state_hash() -> int:
	return StateHash.of_bytes(write_snapshot())

func _write_player(buf: StreamPeerBuffer, p: PlayerState) -> void:
	buf.put_32(p.id); buf.put_32(p.team)
	buf.put_utf8_string(p.display_name)
	buf.put_utf8_string(p.character_key)
	buf.put_32(p.cell.x); buf.put_32(p.cell.y)
	buf.put_32(p.move_target.x); buf.put_32(p.move_target.y)
	buf.put_8(1 if p.moving else 0)
	buf.put_64(p.move_progress)
	buf.put_32(p.facing.x); buf.put_32(p.facing.y)
	buf.put_32(p.range); buf.put_32(p.max_balloons)
	buf.put_64(p.speed); buf.put_32(p.active_balloons)
	buf.put_8(1 if p.alive else 0)
	buf.put_8(1 if p.trapped else 0)
	buf.put_32(p.trap_timer); buf.put_32(p.invuln_timer)
	buf.put_32(p.skill_cooldown); buf.put_32(p.stun_timer)
	buf.put_32(p.input_dir.x); buf.put_32(p.input_dir.y)
	buf.put_8(1 if p.input_place else 0)
	buf.put_8(1 if p.input_skill else 0)

func _read_player(buf: StreamPeerBuffer) -> PlayerState:
	var id_v := buf.get_32()
	var team_v := buf.get_32()
	var name_v := buf.get_utf8_string()
	var char_v := buf.get_utf8_string()
	var p := PlayerState.new(id_v, team_v, Vector2i.ZERO, name_v)
	p.character_key = char_v
	p.cell = Vector2i(buf.get_32(), buf.get_32())
	p.move_target = Vector2i(buf.get_32(), buf.get_32())
	p.moving = buf.get_8() != 0
	p.move_progress = buf.get_64()
	p.facing = Vector2i(buf.get_32(), buf.get_32())
	p.range = buf.get_32()
	p.max_balloons = buf.get_32()
	p.speed = buf.get_64()
	p.active_balloons = buf.get_32()
	p.alive = buf.get_8() != 0
	p.trapped = buf.get_8() != 0
	p.trap_timer = buf.get_32()
	p.invuln_timer = buf.get_32()
	p.skill_cooldown = buf.get_32()
	p.stun_timer = buf.get_32()
	p.input_dir = Vector2i(buf.get_32(), buf.get_32())
	p.input_place = buf.get_8() != 0
	p.input_skill = buf.get_8() != 0
	return p
