extends CharacterSkill
## Menty (lesson) Unique Skill: Whistle Blow.
## Blows a whistle, knocking back all players within 2 cells in cross direction.
## Affected players are stunned for 0.5s (30 ticks).

func execute(sim: Simulation, caster: PlayerState) -> bool:
	var directions: Array[Vector2i] = [Vector2i.UP, Vector2i.DOWN, Vector2i.LEFT, Vector2i.RIGHT]
	var affected := false
	# Each player is hit at most once per whistle: knocking a player back at dist 1 must
	# not let the dist 2 sweep catch the same player again in its new cell.
	var hit_ids: Dictionary = {}
	
	for dir in directions:
		for dist in range(1, 3):
			var check_cell: Vector2i = caster.cell + dir * dist
			# Find any player at this cell
			for p in sim.players:
				if p.id == caster.id or not p.alive or hit_ids.has(p.id):
					continue
				if sim.occupied_cell(p) != check_cell:
					continue
				hit_ids[p.id] = true
				# Apply knockback
				var push_target: Vector2i = p.cell + dir
				# Check if they can be pushed into the next cell
				var can_push := sim._can_enter(push_target)
				if can_push:
					# Check if another player is in the target cell
					for other in sim.players:
						if other.alive and sim.occupied_cell(other) == push_target:
							can_push = false
							break
							
				if can_push:
					p.cell = push_target
					p.move_target = push_target
					
				p.moving = false
				p.move_progress = 0
				p.stun_timer = 30 # 0.5s stun
				affected = true
				
	return affected

func get_cooldown_ticks() -> int:
	return 420 # 7 seconds (assuming 60 ticks/second)
