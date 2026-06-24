extends CharacterSkill
## Rolly (interior) Unique Skill: Roller Coating.
## Coats up to 3 cells in front of the caster with team-colored paint.
## Friendly players move faster, and enemies move slower on the paint.

func execute(sim: Simulation, caster: PlayerState) -> bool:
	var dir := caster.facing
	if dir == Vector2i.ZERO:
		dir = Vector2i.DOWN
		
	var coated := false
	for i in range(1, 4):
		var target := caster.cell + dir * i
		if sim.arena.get_tile(target) == Spec.Tile.FLOOR:
			sim.active_paints[target] = {
				"team": caster.team,
				"ticks_left": 300 # 5 seconds (assuming 60 ticks/second)
			}
			coated = true
			
	return coated

func get_cooldown_ticks() -> int:
	return 480 # 8 seconds (assuming 60 ticks/second)
