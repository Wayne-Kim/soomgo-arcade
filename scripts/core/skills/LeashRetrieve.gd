extends CharacterSkill
## Paws (pet) Unique Skill: Leash Retrieve.
## Throws a leash up to 4 cells forward. If it hits a trapped teammate,
## pulls them to the cell in front of the caster and rescues them instantly.

func execute(sim: Simulation, caster: PlayerState) -> bool:
	var dir := caster.facing
	if dir == Vector2i.ZERO:
		dir = Vector2i.DOWN
		
	var pull_target := caster.cell + dir
	# The target cell where the teammate will be pulled must be walkable and clear of balloons
	if not sim.arena.is_walkable(pull_target) or sim._balloon_at(pull_target) != null:
		return false
		
	# Check if a player is already standing on the pull target
	for p in sim.players:
		if p.alive and sim.occupied_cell(p) == pull_target:
			return false
			
	# Search up to 4 cells in front of the caster
	for i in range(1, 5):
		var target := caster.cell + dir * i
		
		# Stopped by walls or soft blocks
		if sim.arena.is_blocking(target):
			break
			
		# Check if a bubble (trapped player) is here
		for bub in sim.bubbles:
			if bub.cell == target:
				var victim := sim.get_player(bub.victim_id)
				# Teammate in a bubble
				if victim != null and victim.alive and victim.trapped and victim.team == caster.team:
					# Pull teammate
					victim.cell = pull_target
					victim.move_target = pull_target
					victim.moving = false
					victim.move_progress = 0
					
					# Rescue teammate
					victim.trapped = false
					victim.trap_timer = 0
					victim.invuln_timer = Spec.RESCUE_INVULN_TICKS
					
					sim.bubbles.erase(bub)
					sim.player_rescued.emit(victim.id, caster.id)
					return true
					
	return false

func get_cooldown_ticks() -> int:
	return 600 # 10 seconds (assuming 60 ticks/second)
