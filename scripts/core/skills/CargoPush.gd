extends CharacterSkill
## Tote (moving) Unique Skill: Cargo Push.
## Pushes a balloon or a soft block in front of the caster.

func execute(sim: Simulation, caster: PlayerState) -> bool:
	var dir := caster.facing
	if dir == Vector2i.ZERO:
		dir = Vector2i.DOWN
		
	var target := caster.cell + dir
	
	# 1. Try to push a balloon
	var balloon := sim._balloon_at(target)
	if balloon != null:
		var current := target
		while true:
			var next := current + dir
			# Check obstacles
			if not sim.arena.is_walkable(next) or sim._balloon_at(next) != null:
				break
			# Check players
			var player_present := false
			for p in sim.players:
				if p.alive and sim.occupied_cell(p) == next:
					player_present = true
					break
			if player_present:
				break
			current = next
			
		if current != target:
			balloon.cell = current
			return true
		return false
		
	# 2. Try to push a soft block
	if sim.arena.get_tile(target) == Spec.Tile.SOFT_BLOCK:
		var push_target := target + dir
		if sim.arena.is_walkable(push_target) and sim._balloon_at(push_target) == null:
			# Check players
			var player_present := false
			for p in sim.players:
				if p.alive and sim.occupied_cell(p) == push_target:
					player_present = true
					break
			if not player_present:
				# Move the block
				sim.arena.set_tile(target, Spec.Tile.FLOOR)
				sim.arena.set_tile(push_target, Spec.Tile.SOFT_BLOCK)
				
				# Move hidden power-up if any
				var pu := sim.arena.get_powerup(target)
				if pu != Spec.PowerUp.NONE:
					sim.arena.set_powerup(target, Spec.PowerUp.NONE)
					sim.arena.set_powerup(push_target, pu)
				return true
				
	return false

func get_cooldown_ticks() -> int:
	return 240 # 4 seconds (assuming 60 ticks/second)
