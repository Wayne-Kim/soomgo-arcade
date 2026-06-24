class_name LobbyStore
extends RefCounted
## Persistence for the lobby roster, match length and the explicitly-chosen UI language.
##
## A party game gets reopened in the same spot over and over, so the host should not have
## to rebuild the lobby every launch. This stores the last committed roster (slot count,
## per-slot character + controller, best-of-N) and the active language in
## `user://settings.cfg`, restoring them on the next run.
##
## Design constraints honoured here:
##  - New `[lobby]` / `[ui]` sections are written with the SAME load-then-save pattern as
##    Audio.gd, so the existing `[audio]` section (and anything else on disk) is preserved
##    and never clobbered.
##  - Everything restored is validated against the CURRENT data: unknown/removed character
##    ids fall back to a valid per-slot default, an out-of-range slot count is clamped to
##    `Spec.MAX_PLAYERS`, unknown controllers degrade to a bot, a local scheme claimed by
##    two slots is resolved to a single human (mirroring the lobby's own rule), and an
##    unsupported saved language is ignored so the caller falls back to the device locale.
##  - First run (no settings file) and any corrupt/partial file degrade gracefully to the
##    engine defaults — restoration never errors and never blocks reaching the lobby.

## Same file the audio settings already live in (criterion: one settings file, new section).
const PATH := "user://settings.cfg"
const SECTION_LOBBY := "lobby"
const SECTION_UI := "ui"
const KEY_ROSTER := "roster"
const KEY_BEST_OF := "best_of"
const KEY_MAP := "map_id"
const KEY_LANGUAGE := "language"

## The supported-locale set lives in the Strings facade; preload the script (not the
## autoload singleton) so this static helper can validate a saved language without
## depending on autoload init order.
const StringsScript = preload("res://scripts/ui/Strings.gd")

# --- Roster + match length -------------------------------------------------
## Persist the committed roster and chosen best-of-N. Loads the existing file first so the
## `[audio]` section (and any other) survives the write.
static func save_roster(players: Array, best_of: int, map_id: String = Maps.DEFAULT_ID) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)   # preserve any other sections already on disk (e.g. [audio])
	cfg.set_value(SECTION_LOBBY, KEY_ROSTER, _serialize_roster(players))
	cfg.set_value(SECTION_LOBBY, KEY_BEST_OF, maxi(1, best_of))
	cfg.set_value(SECTION_LOBBY, KEY_MAP, Maps.sanitize(map_id))
	cfg.save(PATH)

## Restore the saved roster, validated and degraded against current data. Returns
## `{players: Array, best_of: int, map_id: String}`; `players` is empty on first run / missing /
## corrupt file (so the lobby opens exactly as it does today) and an unknown map degrades to the
## default layout.
static func load_roster() -> Dictionary:
	var result := {"players": [], "best_of": Spec.SERIES_BEST_OF_DEFAULT, "map_id": Maps.DEFAULT_ID}
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return result
	result["best_of"] = maxi(1, int(cfg.get_value(SECTION_LOBBY, KEY_BEST_OF, Spec.SERIES_BEST_OF_DEFAULT)))
	result["map_id"] = Maps.sanitize(String(cfg.get_value(SECTION_LOBBY, KEY_MAP, Maps.DEFAULT_ID)))
	var raw: Variant = cfg.get_value(SECTION_LOBBY, KEY_ROSTER, [])
	if raw is Array:
		result["players"] = _sanitize_roster(raw)
	return result

## Reduce a live roster to the minimal, serialisable fields we persist.
static func _serialize_roster(players: Array) -> Array:
	var out: Array = []
	for p in players:
		if not (p is Dictionary):
			continue
		out.append({
			"name": String(p.get("name", "")),
			"team": int(p.get("team", 0)),
			"character": String(p.get("character", "")),
			"controller": String(p.get("controller", InputScheme.BOT)),
		})
	return out

## Validate a restored roster against the current SSOTs, degrading anything stale to a
## safe default instead of erroring:
##  - slot count clamped to <= Spec.MAX_PLAYERS,
##  - unknown/removed character id -> Characters.default_id_for_index(slot),
##  - unknown controller -> bot, a local scheme already taken by an earlier slot -> bot,
##  - team clamped into the legal range.
static func _sanitize_roster(raw: Array) -> Array:
	var out: Array = []
	var taken: Dictionary = {}   # scheme_id -> true (a local scheme can't be claimed twice)
	for entry in raw:
		if out.size() >= Spec.MAX_PLAYERS:
			break
		if not (entry is Dictionary):
			continue
		var idx := out.size()
		var character := String(entry.get("character", ""))
		if not Characters.has(character):
			character = Characters.default_id_for_index(idx)
		var controller := String(entry.get("controller", InputScheme.BOT))
		if InputScheme.is_human(controller):
			if taken.has(controller):
				controller = InputScheme.BOT   # conflict: duplicate scheme falls back to a bot
			else:
				taken[controller] = true
		elif controller != InputScheme.BOT:
			controller = InputScheme.BOT       # unknown/empty controller -> bot
		var team := clampi(int(entry.get("team", idx)), 0, Spec.MAX_PLAYERS - 1)
		out.append({
			"name": String(entry.get("name", "")),
			"team": team,
			"character": character,
			"controller": controller,
		})
	return out

# --- Active language -------------------------------------------------------
## Remember an EXPLICIT language choice so the next launch reapplies it. Uses the same
## section-preserving write as the roster save.
static func save_language(lang: String) -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH)
	cfg.set_value(SECTION_UI, KEY_LANGUAGE, lang)
	cfg.save(PATH)

## The explicitly-chosen, currently-supported language, or "" when none was saved or the
## saved value is no longer supported. "" tells the caller to fall back to the device
## locale (today's behaviour preserved).
static func load_language() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return ""
	var lang := String(cfg.get_value(SECTION_UI, KEY_LANGUAGE, ""))
	return lang if lang in StringsScript.SUPPORTED else ""
