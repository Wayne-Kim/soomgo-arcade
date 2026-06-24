extends Node
## i18n facade. All user-facing strings are referenced by KEY and resolved through
## Godot's translation system (localization/ui_strings.*.translation). Locales are added
## purely as extra CSV columns (en, ko, …) with NO code change to register them — this
## node only *selects* which locale is active and guarantees English as the fallback.

## Locales backed by a column in localization/ui_strings.csv. English is the fallback for
## any key whose translation cell is missing/empty, so a blank Korean entry renders the
## English source rather than a raw KEY.
const SUPPORTED := ["en", "ko"]
const DEFAULT_LOCALE := "en"

func _ready() -> void:
	# Restore a previously chosen language across sessions: if the player explicitly picked
	# one before (persisted in user://settings.cfg), reapply it; otherwise auto-select the
	# device language. Empty/missing cells and unsupported locales still degrade to the
	# English fallback (internationalization/locale/fallback in project.godot) rather than a
	# raw KEY. The device-locale path does NOT persist, so it never masquerades as an
	# explicit choice on the next launch.
	var saved := LobbyStore.load_language()
	if saved != "":
		_apply_locale(saved)
	else:
		_apply_locale(OS.get_locale_language())

func t(key: String) -> String:
	return tr(key)

func tf(key: String, args: Array) -> String:
	return tr(key).format(args)

## Apply a locale to the TranslationServer. Anything we don't ship falls back to English,
## so callers can pass a raw locale safely. This does not persist — see set_language().
func _apply_locale(lang: String) -> void:
	TranslationServer.set_locale(lang if lang in SUPPORTED else DEFAULT_LOCALE)

## Pick the active UI language as an EXPLICIT user choice: apply it and remember it so the
## next launch restores it instead of the device default.
func set_language(lang: String) -> void:
	_apply_locale(lang)
	LobbyStore.save_language(current_language())

func current_language() -> String:
	return TranslationServer.get_locale().substr(0, 2)

## Simple in-app language choice: flip between Korean and the English fallback.
func toggle_language() -> void:
	set_language("en" if current_language() == "ko" else "ko")
