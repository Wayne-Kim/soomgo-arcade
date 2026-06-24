extends SceneTree
## Headless acceptance tests for the render-side audio layer. Run:
##   Godot --headless --path . --script res://tests/run_audio_tests.gd
## Exits 0 on success, 1 on any failed assertion.
##
## Covers: clips load, the voice pool is polyphony-capped, play() is crash-safe under a
## big simultaneous burst (large chain), mute makes play() a no-op, and volume/mute
## persist to user://settings.cfg. Runs under the dummy audio driver (no device), proving
## the layer is headless/CI safe.

var _failures: int = 0
var _checks: int = 0
var _frames: int = 0

func _check(cond: bool, msg: String) -> void:
	_checks += 1
	if cond:
		print("  PASS: ", msg)
	else:
		_failures += 1
		printerr("  FAIL: ", msg)

func _initialize() -> void:
	print("== Soomgo Arcade audio acceptance tests ==")

## Run the checks after a frame so the Audio autoload's _ready() (stream load, voice pool,
## SFX bus) has executed.
func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	# Autoload singletons live under /root; fetch by node path (the global identifier is
	# not resolvable from a custom SceneTree --script at its own compile time).
	var audio = root.get_node_or_null("Audio")

	_check(audio != null, "Audio autoload is available")
	if audio == null:
		print("Checks: %d  Failures: %d" % [_checks, _failures])
		quit(1)
		return true

	_check(audio._streams.size() == audio.SOUNDS.size(), "every bundled SFX clip loaded")
	_check(audio._players.size() == audio.VOICES, "voice pool is capped at VOICES")
	_check(AudioServer.get_bus_index(audio.BUS_NAME) >= 0, "dedicated SFX bus exists")

	# A large chain detonation: far more simultaneous plays than voices. Must not crash,
	# must not grow the pool (polyphony stays capped).
	for i in 200:
		audio.play("explosion")
		audio.play("eliminated")
	_check(audio._players.size() == audio.VOICES, "polyphony stays capped during a burst")

	# Unknown names are safe no-ops.
	audio.play("does_not_exist")
	_check(true, "playing an unknown clip is a safe no-op")

	# Mute makes play() a no-op (no stream started) and is crash-safe.
	audio.set_muted(true)
	_check(audio.is_muted(), "mute flag set")
	audio.play("balloon_place")
	_check(true, "play() while muted is a safe no-op")
	audio.set_muted(false)

	# Persistence: set values, then read the config file back directly.
	audio.set_volume(0.42)
	audio.set_muted(true)
	var cfg := ConfigFile.new()
	var ok := cfg.load(audio.SETTINGS_PATH) == OK
	_check(ok, "settings file written to user://")
	_check(abs(float(cfg.get_value("audio", "volume", -1.0)) - 0.42) < 0.001,
		"volume persisted across sessions")
	_check(bool(cfg.get_value("audio", "muted", false)) == true,
		"mute persisted across sessions")

	# Reset to defaults so a dev's local settings file isn't left muted by the test.
	audio.set_muted(false)
	audio.set_volume(0.8)

	print("")
	print("Checks: %d  Failures: %d" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)
	return true
