extends Node
## Auto-update facade (Sparkle on macOS). A single, platform-safe entry point so the rest of the
## game never has to know whether a self-update mechanism is present:
##
##  - On a macOS build that ships the optional `SparkleUpdater` GDExtension (see
##    addons/sparkle_update/), this starts Sparkle's automatic background update checks on launch
##    and exposes a manual `check_for_updates()` for a menu button.
##  - Everywhere else — the editor, headless tests, other operating systems, or a build made
##    before the native binary is compiled — every method is a safe no-op and `is_supported()`
##    returns false, so the game (and the test suites) run completely unchanged.
##
## Sparkle itself never crosses into the deterministic simulation; this is purely an app-shell
## concern. Wired as an autoload (see project.godot) so the launch check happens once per run.

## Emitted when a manual update check is kicked off (so UI can show a transient "checking…").
signal update_check_started()

var _updater: Object = null

func _ready() -> void:
	if not is_supported():
		return
	_updater = ClassDB.instantiate("SparkleUpdater")
	if _updater == null:
		return
	# Sparkle's standard updater checks for updates automatically on its own schedule; nudge a
	# background check on launch so a freshly opened app notices a new release promptly.
	if _updater.has_method("start_automatic_checks"):
		_updater.call("start_automatic_checks")

## True only when this build can actually self-update: a macOS build whose native Sparkle
## extension is loaded. UI should gate any "Check for updates" affordance on this.
func is_supported() -> bool:
	return OS.get_name() == "macOS" and ClassDB.class_exists("SparkleUpdater")

## Present Sparkle's user-facing "Check for Updates" flow now. No-op when unsupported, so callers
## never need their own platform guard beyond hiding the button via is_supported().
func check_for_updates() -> void:
	if _updater == null:
		return
	if _updater.has_method("check_for_updates"):
		update_check_started.emit()
		_updater.call("check_for_updates")
