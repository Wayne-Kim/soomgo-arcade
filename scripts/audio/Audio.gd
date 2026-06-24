extends Node
## Render-side audio layer (autoload singleton `Audio`).
##
## Plays short sound effects for the game's key moments. This layer is DELIBERATELY
## render-side only: it is driven off the deterministic Simulation's signals from the
## render/UI nodes (Game.gd), and is NEVER called from inside the fixed-step
## `Simulation.step()`. The simulation neither reads nor produces any audio state, so
## lockstep determinism is completely unaffected and every peer plays its own audio
## locally off its own render — nothing audio-related ever goes over the wire.
##
## Headless / CI safe: AudioServer always exists (it falls back to a dummy driver with
## no output device), so building the player pool and calling `play()` never crashes a
## headless run. Volume/mute persist across sessions in user://settings.cfg.

## All bundled clips are 100% original, procedurally synthesised (see
## assets/audio/generate_sfx.py + docs/audio.md) — safe for commercial use.
const SOUNDS := {
	"balloon_place": "res://assets/audio/balloon_place.wav",
	"explosion": "res://assets/audio/explosion.wav",
	"trapped": "res://assets/audio/trapped.wav",
	"rescue": "res://assets/audio/rescue.wav",
	"skill": "res://assets/audio/skill.wav",
	"eliminated": "res://assets/audio/eliminated.wav",
	"countdown_tick": "res://assets/audio/countdown_tick.wav",
	"countdown_go": "res://assets/audio/countdown_go.wav",
	"round_win": "res://assets/audio/round_win.wav",
	"series_win": "res://assets/audio/series_win.wav",
}

## Polyphony cap: a big chain detonation can emit many `explosion`/`eliminated` signals
## in one frame. A fixed-size voice pool bounds simultaneous playback so the mix can't
## clip or overwhelm — extra requests in the same instant are dropped, not stacked.
const VOICES := 12

const SETTINGS_PATH := "user://settings.cfg"
const SETTINGS_SECTION := "audio"
const BUS_NAME := "SFX"

var _streams: Dictionary = {}                 # name -> AudioStream
var _players: Array[AudioStreamPlayer] = []   # round-robin voice pool
var _next: int = 0
var _bus_idx: int = -1
var _volume: float = 0.8                       # linear 0..1 (pre-mute)
var _muted: bool = false

func _ready() -> void:
	_ensure_bus()
	_load_streams()
	_build_voice_pool()
	_load_settings()
	_apply_bus_volume()

## Route SFX onto their own audio bus so the volume/mute control never touches the
## Master bus (leaving room for a future music track on its own bus). Created at runtime
## so no .tres bus layout has to ship.
func _ensure_bus() -> void:
	_bus_idx = AudioServer.get_bus_index(BUS_NAME)
	if _bus_idx == -1:
		AudioServer.add_bus()
		_bus_idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(_bus_idx, BUS_NAME)
		AudioServer.set_bus_send(_bus_idx, "Master")

func _load_streams() -> void:
	for name in SOUNDS:
		var stream := load(SOUNDS[name]) as AudioStream
		if stream != null:
			_streams[name] = stream

func _build_voice_pool() -> void:
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_NAME
		add_child(p)
		_players.append(p)

## Play a named effect through the next free voice (round-robin). Unknown names and a
## muted state are no-ops. Safe to call every frame and from any render-side signal
## handler; never call this from inside the deterministic simulation.
func play(name: String) -> void:
	if _muted or not _streams.has(name) or _players.is_empty():
		return
	# Prefer a voice that is not currently playing so simultaneous distinct sounds are
	# all heard; fall back to round-robin (oldest voice) when every voice is busy, which
	# is exactly the polyphony cap kicking in on a large chain.
	var player: AudioStreamPlayer = null
	for i in _players.size():
		var idx := (_next + i) % _players.size()
		if not _players[idx].playing:
			player = _players[idx]
			_next = (idx + 1) % _players.size()
			break
	if player == null:
		player = _players[_next]
		_next = (_next + 1) % _players.size()
	player.stream = _streams[name]
	player.play()

# --- Volume / mute settings (persisted) ------------------------------------
func volume() -> float:
	return _volume

func is_muted() -> bool:
	return _muted

## Set the SFX volume (linear 0..1). Persisted immediately so the choice survives across
## sessions. Setting a non-zero volume does NOT clear an explicit mute.
func set_volume(linear: float) -> void:
	_volume = clampf(linear, 0.0, 1.0)
	_apply_bus_volume()
	_save_settings()

func set_muted(muted: bool) -> void:
	_muted = muted
	_apply_bus_volume()
	_save_settings()

func toggle_muted() -> void:
	set_muted(not _muted)

func _apply_bus_volume() -> void:
	if _bus_idx < 0:
		return
	AudioServer.set_bus_mute(_bus_idx, _muted or _volume <= 0.0)
	AudioServer.set_bus_volume_db(_bus_idx, linear_to_db(maxf(_volume, 0.0001)))

func _load_settings() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) != OK:
		return
	_volume = clampf(float(cfg.get_value(SETTINGS_SECTION, "volume", _volume)), 0.0, 1.0)
	_muted = bool(cfg.get_value(SETTINGS_SECTION, "muted", _muted))

func _save_settings() -> void:
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)   # preserve any other sections already on disk
	cfg.set_value(SETTINGS_SECTION, "volume", _volume)
	cfg.set_value(SETTINGS_SECTION, "muted", _muted)
	cfg.save(SETTINGS_PATH)
