class_name AiController
extends RefCounted
## Tactical bot. A deterministic, time-aware combatant:
##
##  - DANGER IS TIMED. Every cell is scored by *how many ticks until it becomes lethal*
##    (`_danger_ticks`), with chain reactions propagated, instead of a flat danger/safe flag.
##    This lets the bot ignore a balloon that won't go off for seconds, yet still verify it
##    can physically clear a blast before it detonates given its own move speed.
##  - FLEEING IS ROUTED IN TIME. `_flee_step` never walks through a cell that will explode
##    while the bot is crossing it, and aims for a cell no blast ever reaches; cornered, it
##    buys the most time it can.
##  - ATTACKING IS AGGRESSIVE BUT SAFE. It hunts the nearest opponent, only drops a balloon
##    when that balloon threatens someone (or, when no one is near, opens the map) AND a
##    timed escape route genuinely exists.
##  - SKILLS ARE USED. Each Soomgo master's unique skill fires when it actually lands
##    (whistle a neighbour, dash out of a blast, paint an enemy's lane, shove a balloon into
##    someone, pull a trapped ally), instead of never being cast at all.
##
## Determinism: `decide()` only READS the sim and uses the per-bot `DetRng`, so it is called
## once per tick with identical state on every peer and advances identically — which is what
## lets networked peers run bots locally without broadcasting their inputs.

const DIRS := [Vector2i.RIGHT, Vector2i.DOWN, Vector2i.LEFT, Vector2i.UP]
const _SAFE: int = 1 << 30               # sentinel "no blast ever reaches this cell" tick
const _OBJ_GUARD: int = Spec.EXPLOSION_TICKS   # objectives avoid cells exploding within ~0.5 s

var id: int
var _decide_cooldown: int = 0            # ticks until the next deliberate movement/attack decision
var _rng := DetRng.new()

func _init(p_id: int, seed_value: int) -> void:
	id = p_id
	_rng.state = seed_value * 7919 + p_id

func update(sim: Simulation, _delta: float) -> void:
	var mv := decide(sim)
	if mv["act"]:
		sim.set_input(id, mv["dir"], mv["place"], mv["skill"])

## Compute this bot's input for the current sim state without mutating the sim. Returns
## {dir:Vector2i, place:bool, skill:bool, act:bool}; `act` is false when the bot cannot act
## this tick (trapped/eliminated).
func decide(sim: Simulation) -> Dictionary:
	var p := sim.get_player(id)
	if p == null or not p.can_act():
		return {"dir": Vector2i.ZERO, "place": false, "skill": false, "act": false}
	_decide_cooldown -= 1

	var danger := _danger_ticks(sim)
	var has_skill: bool = Simulation.SKILLS.has(p.character_key)

	# 1. Survival wins: if our cell is inside any blast projection, get out now — and burn a
	#    mobility skill to clear it faster if one is ready.
	if danger.has(p.cell):
		var flee := _flee_step(sim, p, danger)
		var use_skill := false
		if p.skill_cooldown == 0 and has_skill:
			var esc := _skill_decision(sim, p, flee, true)
			if esc["use"]:
				use_skill = true
				flee = esc["dir"]
		return {"dir": flee, "place": false, "skill": use_skill, "act": true}

	# 2. Reactive skill: a ready skill that lands right now. Cheap to check every tick and a
	#    no-op once the skill is on cooldown, so it does not need the decision throttle.
	if p.skill_cooldown == 0 and has_skill:
		var sk := _skill_decision(sim, p, Vector2i.ZERO, false)
		if sk["use"]:
			return {"dir": sk["dir"], "place": false, "skill": true, "act": true}

	# Throttle deliberate decisions but keep existing momentum toward the last goal.
	if _decide_cooldown > 0:
		return {"dir": p.input_dir, "place": false, "skill": false, "act": true}
	_decide_cooldown = _rng.range_int(6, 14)   # ~0.1..0.23 s at 60 ticks/s

	# 3. Attack / clear: drop a balloon only with a real target AND a timed escape.
	if _should_bomb(sim, p) and _can_place_safely(sim, p):
		return {"dir": _escape_after_place(sim, p), "place": true, "skill": false, "act": true}

	# 4. Otherwise advance toward the most useful reachable objective.
	return {"dir": _objective_step(sim, p, danger), "place": false, "skill": false, "act": true}

# --- Timing helpers --------------------------------------------------------
## Whole ticks to slide across one cell at the player's current speed (Q16.16 cells/second).
## ceil(ONE * TICK_RATE / speed); used to reason about "can I get out in time?".
func _ticks_per_cell(p: PlayerState) -> int:
	var s: int = maxi(1, p.speed)
	return maxi(1, (Fixed.ONE * Spec.TICK_RATE + s - 1) / s)

func _soon(danger: Dictionary, c: Vector2i, ticks: int) -> bool:
	return danger.get(c, _SAFE) <= ticks

# --- Danger model ----------------------------------------------------------
## Every cell a balloon at `cell` with `reach` would fill, stopping at hard walls and at (and
## including) the first soft block in each direction — i.e. the real explosion footprint.
func _blast_cells(sim: Simulation, cell: Vector2i, reach: int) -> Dictionary:
	var out: Dictionary = {cell: true}
	for d in DIRS:
		for i in range(1, reach + 1):
			var c: Vector2i = cell + d * i
			var t := sim.arena.get_tile(c)
			if t == Spec.Tile.HARD_WALL:
				break
			out[c] = true
			if t == Spec.Tile.SOFT_BLOCK:
				break
	return out

## Map of cell -> ticks until it first becomes lethal (0 == lethal right now). Balloon fuses
## are relaxed through chain reactions (a balloon caught in an earlier blast detonates with
## it), and live explosion cells are lethal immediately. Cells absent from the map are never
## touched by any current blast.
func _danger_ticks(sim: Simulation) -> Dictionary:
	var bs := sim.balloons
	var n := bs.size()
	var fuses: Array[int] = []
	var cells: Array = []
	fuses.resize(n)
	cells.resize(n)
	for i in n:
		fuses[i] = 0 if bs[i].detonating else bs[i].fuse
		cells[i] = _blast_cells(sim, bs[i].cell, bs[i].range)
	# Chain relaxation: if balloon i's blast covers balloon j, j cannot detonate later than i.
	var changed := true
	while changed:
		changed = false
		for i in n:
			for j in n:
				if i != j and fuses[i] < fuses[j] and cells[i].has(bs[j].cell):
					fuses[j] = fuses[i]
					changed = true
	var danger: Dictionary = {}
	for i in n:
		for c in cells[i]:
			if fuses[i] < danger.get(c, _SAFE):
				danger[c] = fuses[i]
	for cell in sim.explosions:
		danger[cell] = 0
	return danger

# --- Movement primitives ---------------------------------------------------
func _passable(sim: Simulation, c: Vector2i) -> bool:
	return sim.arena.is_walkable(c) and sim._balloon_at(c) == null

## Plain BFS: first-step direction toward the nearest cell satisfying `is_goal`, never
## entering a cell where `blocked` is true. `max_steps` caps the search radius (-1 == no cap),
## used to ask "is there a goal close by?". ZERO if none reachable within the cap.
func _bfs_step(sim: Simulation, start: Vector2i, is_goal: Callable, blocked: Callable, max_steps: int = -1) -> Vector2i:
	var came: Dictionary = {start: start}
	var depth: Dictionary = {start: 0}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		if cur != start and is_goal.call(cur):
			var node := cur
			while came[node] != start:
				node = came[node]
			return node - start
		if max_steps >= 0 and depth[cur] >= max_steps:
			continue
		for d in DIRS:
			var nc: Vector2i = cur + d
			if came.has(nc) or not sim.arena.in_bounds(nc):
				continue
			if blocked.call(nc):
				continue
			came[nc] = cur
			depth[nc] = depth[cur] + 1
			queue.append(nc)
	return Vector2i.ZERO

## Timed BFS: like `_bfs_step`, but it also refuses to step into a cell that will be lethal by
## the time the bot would occupy it (arrival ticks = depth * `tpc`, plus a one-cell `guard`).
## This is what makes fleeing actually survive: the path is checked against blast timing.
func _bfs_step_timed(sim: Simulation, start: Vector2i, is_goal: Callable, danger: Dictionary, tpc: int, guard: int, extra_blocked: Dictionary = {}) -> Vector2i:
	var came: Dictionary = {start: start}
	var depth: Dictionary = {start: 0}
	var queue: Array[Vector2i] = [start]
	while not queue.is_empty():
		var cur: Vector2i = queue.pop_front()
		if cur != start and is_goal.call(cur):
			var node := cur
			while came[node] != start:
				node = came[node]
			return node - start
		var arrive: int = (depth[cur] + 1) * tpc
		for d in DIRS:
			var nc: Vector2i = cur + d
			if came.has(nc) or not sim.arena.in_bounds(nc):
				continue
			if not _passable(sim, nc) or extra_blocked.has(nc):
				continue
			if danger.get(nc, _SAFE) <= arrive + guard:
				continue   # this cell would be (about to be) exploding when we arrive
			came[nc] = cur
			depth[nc] = depth[cur] + 1
			queue.append(nc)
	return Vector2i.ZERO

# --- Fleeing ---------------------------------------------------------------
func _flee_step(sim: Simulation, p: PlayerState, danger: Dictionary) -> Vector2i:
	var tpc := _ticks_per_cell(p)
	# 1. Route to the nearest cell no blast ever reaches, without crossing imminent death.
	var step := _bfs_step_timed(sim, p.cell,
		func(c): return not danger.has(c), danger, tpc, tpc)
	if step != Vector2i.ZERO:
		return step
	# 2. No fully-safe cell reachable: step to whichever option explodes latest (buy time).
	var best := Vector2i.ZERO
	var best_t: int = danger.get(p.cell, _SAFE)   # staying put is a candidate
	for d in DIRS:
		var nc: Vector2i = p.cell + d
		if not _passable(sim, nc):
			continue
		var t: int = danger.get(nc, _SAFE)
		if t > best_t:
			best_t = t
			best = d
	return best

# --- Placing balloons ------------------------------------------------------
## True when dropping a balloon here is worth it. Priority order:
##   1. KILL — an opponent stands in the blast and, with this balloon added, can no longer
##      reach safety in time (it is cornered). Always worth our balloon.
##   2. PRESSURE — an opponent is in the blast and we can spare a balloon (would still hold one
##      after this), so a dodgeable bomb herds them / sets up crossfire without leaving us
##      defenceless. Skipped when we hold only a single balloon — wasting it on a mobile
##      target is exactly what made old bots stalemate.
##   3. OPEN THE MAP — no opponent is close enough to spend the balloon on.
func _should_bomb(sim: Simulation, p: PlayerState) -> bool:
	var blast := _blast_cells(sim, p.cell, p.range)
	var dropped := _danger_with_own_drop(sim, p)
	var has_target := false
	for other in sim.players:
		if other.id == id or not other.alive or other.invuln_timer > 0:
			continue
		if not blast.has(sim.occupied_cell(other)):
			continue
		has_target = true
		if not _enemy_can_escape(sim, other, dropped, p.cell):
			return true   # cornered kill shot
	if has_target and (p.active_balloons + 1 < p.max_balloons or sim.living_players() <= 3):
		return true       # affordable pressure, or commit it in the endgame to force the fight
	if _nearest_enemy_manhattan(sim, p) > p.range + 2:
		for d in DIRS:
			if sim.arena.get_tile(p.cell + d) == Spec.Tile.SOFT_BLOCK:
				return true
	return false

## Would `enemy` survive the given danger map? Models it as a passive fleer with its own move
## speed that cannot walk through `block` (the balloon we are about to drop): true if it can
## still reach a cell no blast touches before being caught. False == this bomb likely kills it.
func _enemy_can_escape(sim: Simulation, enemy: PlayerState, danger: Dictionary, block: Vector2i) -> bool:
	var start := sim.occupied_cell(enemy)
	if not danger.has(start):
		return true   # not even in the threatened area
	var tpc := _ticks_per_cell(enemy)
	return _bfs_step_timed(sim, start,
		func(c): return not danger.has(c), danger, tpc, tpc, {block: true}) != Vector2i.ZERO

## A drop is safe only if, with the new balloon's blast added to the danger map, a cell no
## blast reaches is still reachable in time. The new balloon takes a full fuse, so the binding
## constraint is escaping nearby existing balloons and not boxing ourselves in.
func _can_place_safely(sim: Simulation, p: PlayerState) -> bool:
	if p.active_balloons >= p.max_balloons or sim._balloon_at(p.cell) != null:
		return false
	var danger := _danger_with_own_drop(sim, p)
	var tpc := _ticks_per_cell(p)
	return _bfs_step_timed(sim, p.cell,
		func(c): return not danger.has(c), danger, tpc, tpc) != Vector2i.ZERO

func _escape_after_place(sim: Simulation, p: PlayerState) -> Vector2i:
	return _flee_step(sim, p, _danger_with_own_drop(sim, p))

## Current danger plus the balloon we are about to drop at our feet (full fuse).
func _danger_with_own_drop(sim: Simulation, p: PlayerState) -> Dictionary:
	var danger := _danger_ticks(sim)
	for c in _blast_cells(sim, p.cell, p.range):
		if Spec.BALLOON_FUSE_TICKS < danger.get(c, _SAFE):
			danger[c] = Spec.BALLOON_FUSE_TICKS
	return danger

# --- Objectives ------------------------------------------------------------
func _objective_step(sim: Simulation, p: PlayerState, danger: Dictionary) -> Vector2i:
	var blocked := func(c): return not _passable(sim, c) or _soon(danger, c, _OBJ_GUARD)
	var is_powerup := func(c): return sim.arena.get_powerup(c) != Spec.PowerUp.NONE

	# a) Grab a power-up that is close by — cheap, and the extra range/balloons are what make
	#    end-game kills actually possible (a range-1 bot can never corner anyone).
	var step := _bfs_step(sim, p.cell, is_powerup, blocked, 4)
	if step != Vector2i.ZERO:
		return step

	# b) Hunt: get next to a living opponent so we can bomb them.
	step = _bfs_step(sim, p.cell, func(c): return _adjacent_to_enemy(sim, c), blocked)
	if step != Vector2i.ZERO:
		return step

	# c) Otherwise go fetch a more distant power-up.
	step = _bfs_step(sim, p.cell, is_powerup, blocked)
	if step != Vector2i.ZERO:
		return step

	# d) Open the map / reveal power-ups by reaching a destructible block.
	step = _bfs_step(sim, p.cell, func(c): return _adjacent_to_softblock(sim, c), blocked)
	if step != Vector2i.ZERO:
		return step

	# e) Fallback: any safe neighbour, deterministic but slightly varied.
	var order := DIRS.duplicate()
	if _rng.chance(1, 2):
		order.reverse()
	for d in order:
		var nc: Vector2i = p.cell + d
		if _passable(sim, nc) and not _soon(danger, nc, _OBJ_GUARD):
			return d
	return Vector2i.ZERO

func _nearest_enemy_manhattan(sim: Simulation, p: PlayerState) -> int:
	var best: int = 1 << 30
	for other in sim.players:
		if other.id == id or not other.alive:
			continue
		var oc := sim.occupied_cell(other)
		var dd: int = absi(oc.x - p.cell.x) + absi(oc.y - p.cell.y)
		if dd < best:
			best = dd
	return best

func _adjacent_to_enemy(sim: Simulation, c: Vector2i) -> bool:
	for other in sim.players:
		if other.id == id or not other.alive:
			continue
		var oc := sim.occupied_cell(other)
		if (oc - c).length_squared() == 1 or oc == c:
			return true
	return false

func _adjacent_to_softblock(sim: Simulation, c: Vector2i) -> bool:
	for d in DIRS:
		if sim.arena.get_tile(c + d) == Spec.Tile.SOFT_BLOCK:
			return true
	return false

# --- Skills ----------------------------------------------------------------
## Decide whether to fire this character's unique skill, and in which direction (the returned
## dir doubles as the facing the skill resolves along). Only consulted when the skill is off
## cooldown. `in_danger` is true while fleeing, which unlocks the escape-oriented uses.
func _skill_decision(sim: Simulation, p: PlayerState, flee_dir: Vector2i, in_danger: bool) -> Dictionary:
	match p.character_key:
		"lesson":   # Whistle Blow — knock back + stun a neighbour (cross, 2 cells).
			var dw := _enemy_in_cross(sim, p, 2)
			if dw != Vector2i.ZERO:
				return {"use": true, "dir": dw}
		"cleaning": # Slippery Dash — bolt out of a blast.
			if in_danger and flee_dir != Vector2i.ZERO and _passable(sim, p.cell + flee_dir):
				return {"use": true, "dir": flee_dir}
		"interior": # Roller Coating — speed our own escape, else slow an approaching enemy.
			if in_danger and flee_dir != Vector2i.ZERO:
				return {"use": true, "dir": flee_dir}
			var di := _enemy_in_cross(sim, p, 3)
			if di != Vector2i.ZERO:
				return {"use": true, "dir": di}
		"moving":   # Cargo Push — shove a balloon down a lane into an enemy.
			var dm := _push_balloon_dir(sim, p)
			if dm != Vector2i.ZERO:
				return {"use": true, "dir": dm}
		"pet":      # Leash Retrieve — pull a trapped team-mate to safety.
			var dp := _trapped_teammate_dir(sim, p)
			if dp != Vector2i.ZERO:
				return {"use": true, "dir": dp}
	return {"use": false, "dir": Vector2i.ZERO}

## Direction toward the nearest living opponent in a straight, unobstructed line within
## `maxd` cells (the line a cross-shaped skill or a balloon shot would travel). ZERO if none.
func _enemy_in_cross(sim: Simulation, p: PlayerState, maxd: int) -> Vector2i:
	for d in DIRS:
		for i in range(1, maxd + 1):
			var c: Vector2i = p.cell + d * i
			var t := sim.arena.get_tile(c)
			if t == Spec.Tile.HARD_WALL or t == Spec.Tile.SOFT_BLOCK:
				break
			for other in sim.players:
				if other.id != id and other.alive and sim.occupied_cell(other) == c:
					return d
	return Vector2i.ZERO

## Direction in which a balloon sits adjacent AND a living opponent stands further down the
## same lane — so pushing the balloon sends it toward them. ZERO if no such lane.
func _push_balloon_dir(sim: Simulation, p: PlayerState) -> Vector2i:
	for d in DIRS:
		if sim._balloon_at(p.cell + d) == null:
			continue
		for i in range(2, p.range + 4):
			var c: Vector2i = p.cell + d * i
			var t := sim.arena.get_tile(c)
			if t == Spec.Tile.HARD_WALL or t == Spec.Tile.SOFT_BLOCK:
				break
			for other in sim.players:
				if other.id != id and other.alive and sim.occupied_cell(other) == c:
					return d
	return Vector2i.ZERO

## Direction toward a trapped team-mate within 4 cells in a straight line. ZERO if none.
func _trapped_teammate_dir(sim: Simulation, p: PlayerState) -> Vector2i:
	for d in DIRS:
		for i in range(1, 5):
			var c: Vector2i = p.cell + d * i
			if sim.arena.is_blocking(c):
				break
			for bub in sim.bubbles:
				if bub.cell == c:
					var v := sim.get_player(bub.victim_id)
					if v != null and v.trapped and v.id != id and v.team == p.team:
						return d
	return Vector2i.ZERO
