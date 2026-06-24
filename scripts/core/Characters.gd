class_name Characters
extends RefCounted
## Roster SSOT for the selectable "Soomgo master" (고수) characters.
##
## These are ORIGINAL characters whose theme is sourced from real Soomgo service
## categories (cleaning, moving, interior, lessons, pet care) — deliberately unrelated
## to any pre-existing arcade IP (see docs/characters.md for the dissimilarity check).
##
## Design constraints honoured here:
##  - User-facing text (name / motif / personality / unique-skill name & effect) is NEVER
##    hardcoded: each field is a localization KEY resolved through tr()
##    (localization/ui_strings.csv). New locales are added as CSV columns with no change to
##    this file.
##  - No colour is invented per character. This repo has no design-token/brand palette,
##    so colour is promised by MEANING only (team distinction, handled by the renderer).
##    The "representative colour / silhouette" direction lives as prose in docs/, not as
##    a committed token here.
##  - Every starting stat is clamped to the gameplay caps in Spec.gd, so a profile can
##    never start outside the legal range / balloon / speed bounds.

## Stable id, the localization KEYS for exposed text, and the starting stat profile.
## `id` is an internal key (never shown to players) used to persist a roster choice.
const ROSTER: Array[Dictionary] = [
	{
		"id": "cleaning",
		"name_key": "CHAR_CLEANING_NAME",
		"motif_key": "CHAR_CLEANING_MOTIF",
		"desc_key": "CHAR_CLEANING_DESC",
		"skill_name_key": "CHAR_CLEANING_SKILL_NAME",
		"skill_desc_key": "CHAR_CLEANING_SKILL_DESC",
		"start_range": 1,
		"start_balloons": 1,
		"start_speed": 6.0,
	},
	{
		"id": "moving",
		"name_key": "CHAR_MOVING_NAME",
		"motif_key": "CHAR_MOVING_MOTIF",
		"desc_key": "CHAR_MOVING_DESC",
		"skill_name_key": "CHAR_MOVING_SKILL_NAME",
		"skill_desc_key": "CHAR_MOVING_SKILL_DESC",
		"start_range": 1,
		"start_balloons": 3,
		"start_speed": 4.0,
	},
	{
		"id": "interior",
		"name_key": "CHAR_INTERIOR_NAME",
		"motif_key": "CHAR_INTERIOR_MOTIF",
		"desc_key": "CHAR_INTERIOR_DESC",
		"skill_name_key": "CHAR_INTERIOR_SKILL_NAME",
		"skill_desc_key": "CHAR_INTERIOR_SKILL_DESC",
		"start_range": 3,
		"start_balloons": 1,
		"start_speed": 4.0,
	},
	{
		"id": "lesson",
		"name_key": "CHAR_LESSON_NAME",
		"motif_key": "CHAR_LESSON_MOTIF",
		"desc_key": "CHAR_LESSON_DESC",
		"skill_name_key": "CHAR_LESSON_SKILL_NAME",
		"skill_desc_key": "CHAR_LESSON_SKILL_DESC",
		"start_range": 2,
		"start_balloons": 2,
		"start_speed": 5.0,
	},
	{
		"id": "pet",
		"name_key": "CHAR_PET_NAME",
		"motif_key": "CHAR_PET_MOTIF",
		"desc_key": "CHAR_PET_DESC",
		"skill_name_key": "CHAR_PET_SKILL_NAME",
		"skill_desc_key": "CHAR_PET_SKILL_DESC",
		"start_range": 1,
		"start_balloons": 2,
		"start_speed": 5.0,
	},
]

static func all() -> Array[Dictionary]:
	return ROSTER

static func count() -> int:
	return ROSTER.size()

static func ids() -> Array:
	var out: Array = []
	for c in ROSTER:
		out.append(c["id"])
	return out

static func get_def(id: String) -> Dictionary:
	for c in ROSTER:
		if c["id"] == id:
			return c
	return {}

static func has(id: String) -> bool:
	return not get_def(id).is_empty()

## Default character for the Nth lobby slot. Cycles through the roster so a freshly
## added slot always references a valid, externalised character.
static func default_id_for_index(index: int) -> String:
	if ROSTER.is_empty():
		return ""
	return ROSTER[index % ROSTER.size()]["id"]

## Apply a character's starting stat profile to a freshly created player. Unknown/empty
## ids leave the engine defaults untouched. Every value is clamped to the Spec caps.
static func apply_start_stats(player: PlayerState, id: String) -> void:
	var def := get_def(id)
	if def.is_empty():
		return
	player.range = Spec.clamp_range(int(def["start_range"]))
	player.max_balloons = Spec.clamp_balloons(int(def["start_balloons"]))
	# `start_speed` is whole cells/second; the engine stores speed in Q16.16 fixed-point.
	player.speed = Spec.clamp_speed(Fixed.from_int(int(def["start_speed"])))
