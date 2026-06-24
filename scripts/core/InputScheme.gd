class_name InputScheme
extends RefCounted
## SSOT for the single LOCAL (same-device) control scheme: one player drives the game on
## this device, the rest of the slots are bots or online peers. A scheme maps to a set of
## InputMap actions registered in project.godot (`<prefix>_up/down/left/right/place/skill`).
##
## Design constraints honoured here:
##  - User-facing text is NEVER hardcoded: each scheme exposes localization KEYs
##    (`label_key`, `skill_key`) resolved through tr() by the UI (localization/ui_strings.csv).
##    New locales are added as CSV columns with no change to this file.
##  - No colour is invented per scheme. Player/scheme distinction is shown with the
##    renderer's existing functional team/entity colours (colour-by-meaning), not a brand
##    palette.
##  - Routing is read-only: schemes only sample input and feed Simulation.set_input, so the
##    deterministic fixed-step simulation is unchanged.

## Sentinel controller value for a slot driven by the bot AI instead of the local human.
const BOT := "bot"

## The local control scheme: a stable internal `id` (persisted on a slot, never shown), the
## localization KEYs for its discoverable label + skill button, and the InputMap action
## `prefix`. Only one local human plays per device, so there is a single keyboard scheme.
const SCHEMES: Array[Dictionary] = [
	{"id": "kb_arrows", "label_key": "SCHEME_KB_ARROWS", "skill_key": "SCHEME_KB_ARROWS_SKILL", "prefix": "p1"},
]

static func all() -> Array[Dictionary]:
	return SCHEMES

static func count() -> int:
	return SCHEMES.size()

static func ids() -> Array:
	var out: Array = []
	for s in SCHEMES:
		out.append(s["id"])
	return out

static func get_def(id: String) -> Dictionary:
	for s in SCHEMES:
		if s["id"] == id:
			return s
	return {}

static func has(id: String) -> bool:
	return not get_def(id).is_empty()

## The localization KEY for a scheme's label (resolved via tr() at the UI layer).
static func label_key(id: String) -> String:
	var def := get_def(id)
	return def.get("label_key", "") if not def.is_empty() else ""

## The localization KEY for the button that casts the unique skill on this scheme
## (resolved via tr() at the UI layer), so the lobby can show "Skill: Ctrl/E/Button B".
static func skill_key(id: String) -> String:
	var def := get_def(id)
	return def.get("skill_key", "") if not def.is_empty() else ""

## True when a slot's controller value designates a real local human (a known scheme), as
## opposed to the bot AI or an empty/unknown value.
static func is_human(controller: String) -> bool:
	return controller != BOT and has(controller)

## True when a scheme can currently drive a player. The single keyboard scheme is always
## available (kept for parity with the routing code, which checks before sampling input).
static func is_available(id: String) -> bool:
	return has(id)

## Sample a scheme's current intent for one tick: a single cardinal direction (input is
## tile-stepped, so diagonals collapse to one axis) plus a just-pressed "place" edge.
static func read(id: String) -> Dictionary:
	var def := get_def(id)
	if def.is_empty():
		return {"dir": Vector2i.ZERO, "place": false, "skill": false}
	var pre: String = def["prefix"]
	var dir := Vector2i.ZERO
	if Input.is_action_pressed(pre + "_up"):
		dir = Vector2i.UP
	elif Input.is_action_pressed(pre + "_down"):
		dir = Vector2i.DOWN
	elif Input.is_action_pressed(pre + "_left"):
		dir = Vector2i.LEFT
	elif Input.is_action_pressed(pre + "_right"):
		dir = Vector2i.RIGHT
	var place := Input.is_action_just_pressed(pre + "_place")
	var skill := Input.is_action_just_pressed(pre + "_skill")
	return {"dir": dir, "place": place, "skill": skill}

## Map a roster's player slots to the human schemes driving them: {player_id: scheme_id}.
## Player ids match the slot order Simulation assigns (id == index). Slots whose controller
## is a bot/empty/unknown are omitted, so callers fill exactly the rest with AiController.
static func human_map(player_defs: Array) -> Dictionary:
	var out: Dictionary = {}
	for i in player_defs.size():
		var ctrl: String = player_defs[i].get("controller", "")
		if is_human(ctrl):
			out[i] = ctrl
	return out
