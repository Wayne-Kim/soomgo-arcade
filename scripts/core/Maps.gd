class_name Maps
extends RefCounted
## SSOT for the selectable arena layouts ("maps"). Each entry is purely metadata — a stable
## internal `id` (persisted/sent over the wire) plus localization KEYs for the shown name and
## description. The actual tile layout for an id is produced deterministically by
## Arena.generate(id, ...), so a map is reproducible and identical on every peer from the shared
## (id, width, height, seed).
##
## Design constraints mirror Characters.gd / InputScheme.gd:
##  - User-facing text is NEVER hardcoded: name/desc are localization KEYs resolved via tr().
##  - No colour is invented per map; the renderer draws every map with the same functional palette.
##  - "classic" is the original layout and the default, so existing behaviour is unchanged.

const DEFAULT_ID := "classic"

const ROSTER: Array[Dictionary] = [
	{"id": "classic",  "name_key": "MAP_CLASSIC_NAME",  "desc_key": "MAP_CLASSIC_DESC"},
	{"id": "open",     "name_key": "MAP_OPEN_NAME",     "desc_key": "MAP_OPEN_DESC"},
	{"id": "cross",    "name_key": "MAP_CROSS_NAME",    "desc_key": "MAP_CROSS_DESC"},
	{"id": "pinwheel", "name_key": "MAP_PINWHEEL_NAME", "desc_key": "MAP_PINWHEEL_DESC"},
]

static func all() -> Array[Dictionary]:
	return ROSTER

static func count() -> int:
	return ROSTER.size()

static func ids() -> Array:
	var out: Array = []
	for m in ROSTER:
		out.append(m["id"])
	return out

static func get_def(id: String) -> Dictionary:
	for m in ROSTER:
		if m["id"] == id:
			return m
	return {}

static func has(id: String) -> bool:
	return not get_def(id).is_empty()

## A valid map id: the given one if known, otherwise the default. Used to degrade any stale or
## wire-supplied value to a layout that actually exists (never an empty/unknown map).
static func sanitize(id: String) -> String:
	return id if has(id) else DEFAULT_ID

static func default_id() -> String:
	return DEFAULT_ID
