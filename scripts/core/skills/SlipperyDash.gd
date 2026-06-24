extends CharacterSkill
## Sudsy (cleaning) Unique Skill: Slippery Dash.
## Dashes forward up to 2 cells, skipping through empty space.

func execute(sim: Simulation, caster: PlayerState) -> bool:
	var dir := caster.facing
	if dir == Vector2i.ZERO:
		dir = Vector2i.DOWN

	# Launch from the cell the caster currently occupies, cancelling any in-progress tile step,
	# so the dash fires mid-stride instead of only from a full standstill.
	var steps := 0
	var current_cell := sim.occupied_cell(caster)
	for i in range(2):
		var next := current_cell + dir
		if sim._can_enter(next):
			current_cell = next
			steps += 1
		else:
			break
			
	if steps > 0:
		caster.cell = current_cell
		caster.move_target = current_cell
		caster.moving = false
		caster.move_progress = 0
		return true
		
	return false

func get_cooldown_ticks() -> int:
	return 360 # 6 seconds (assuming 60 ticks/second)
