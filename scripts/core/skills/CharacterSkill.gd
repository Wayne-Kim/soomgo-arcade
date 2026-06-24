class_name CharacterSkill
extends RefCounted
## Base class/interface for character unique skills.
## Implementation of SOLID principles (SRP, OCP, LSP, DIP).

## Execute the skill on the given simulation state.
## Returns true if the skill was successfully cast, triggering cooldown.
func execute(_sim: Simulation, _caster: PlayerState) -> bool:
	return false

## Get cooldown duration in ticks.
func get_cooldown_ticks() -> int:
	return 0
