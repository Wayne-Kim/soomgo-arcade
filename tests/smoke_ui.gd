extends SceneTree
## Headless smoke test: instantiate the Lobby and Game scenes, run a few frames each,
## and confirm no runtime errors and that key UI states are reachable.

var _phase := 0
var _frames := 0
var _lobby: Control
var _game: Node2D
var _connect: Control
var _fail := false
var _settings_had := false
var _settings_backup := ""

func _initialize() -> void:
	print("== UI smoke test ==")
	# Isolate the test from any real persisted lobby/language state so the empty-lobby
	# assertions are deterministic; the original file is restored in _finish_settings().
	_settings_had = FileAccess.file_exists(LobbyStore.PATH)
	_settings_backup = FileAccess.get_file_as_string(LobbyStore.PATH) if _settings_had else ""
	_clear_persisted_lobby()
	_lobby = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(_lobby)

func _process(_dt: float) -> bool:
	_frames += 1
	if _phase == 0 and _frames > 3:
		_check_lobby()
		_lobby.queue_free()
		_check_lobby_restore()
		_phase = 1
		_frames = 0
		# Provide a valid roster for the Game scene (each with a selected character).
		# One local human (the single keyboard scheme) + the rest bots, to exercise routing + hints.
		MatchConfig.player_defs = [
			{"name": "Ann", "team": 0, "character": Characters.default_id_for_index(0), "controller": InputScheme.ids()[0]},
			{"name": "Bo", "team": 1, "character": Characters.default_id_for_index(1), "controller": InputScheme.BOT},
			{"name": "Cy", "team": 2, "character": Characters.default_id_for_index(2), "controller": InputScheme.BOT},
			{"name": "Di", "team": 3, "character": Characters.default_id_for_index(3), "controller": InputScheme.BOT},
			{"name": "Ed", "team": 4, "character": Characters.default_id_for_index(4), "controller": InputScheme.BOT},
			{"name": "Fi", "team": 5, "character": Characters.default_id_for_index(5), "controller": InputScheme.BOT},
			{"name": "Gu", "team": 6, "character": Characters.default_id_for_index(6), "controller": InputScheme.BOT},
			{"name": "Ha", "team": 7, "character": Characters.default_id_for_index(7), "controller": InputScheme.BOT}]
		MatchConfig.match_seed = 42
		MatchConfig.best_of = Spec.SERIES_BEST_OF_DEFAULT
		MatchConfig.start_series()
		_game = load("res://scenes/Game.tscn").instantiate()
		root.add_child(_game)
	elif _phase == 1 and _frames > 30:
		_check_game()
		_game.queue_free()
		_phase = 2
		_frames = 0
		_connect = load("res://scenes/Connect.tscn").instantiate()
		root.add_child(_connect)
	elif _phase == 2 and _frames > 3:
		_check_connect()
		_connect.queue_free()
		_phase = 3
		_frames = 0
		_start_networked_game()
	elif _phase == 3 and _frames > 20:
		_check_networked_game()
		_finish_settings()
		print("UI smoke: %s" % ("FAIL" if _fail else "PASS"))
		quit(1 if _fail else 0)
		return true
	return false

## Stand up the Game scene in networked mode (no real peers) to exercise the networked branch:
## a single local human (player 0) + bots, driven through NetMatch.
func _start_networked_game() -> void:
	var session := NetSession.new()
	session.host(27098, "SmokeHost")
	MatchConfig.player_defs = [
		{"name": "Me", "team": 0, "character": Characters.default_id_for_index(0), "bot": false},
		{"name": "Bot 2", "team": 1, "character": Characters.default_id_for_index(1), "bot": true},
		{"name": "Bot 3", "team": 2, "character": Characters.default_id_for_index(2), "bot": true},
		{"name": "Bot 4", "team": 3, "character": Characters.default_id_for_index(3), "bot": true}]
	MatchConfig.match_seed = 77
	NetContext.arm(session, 0)
	_game = load("res://scenes/Game.tscn").instantiate()
	root.add_child(_game)

func _check_networked_game() -> void:
	_ck(_game._networked and _game._net != null, "Game entered networked mode via NetContext")
	_ck(_game._local_id == 0 and _game._local_is_player(), "this device drives its assigned player id")
	_ck(_game.sim.elapsed_seconds() > 0.0, "networked simulation advanced via NetMatch lockstep")
	# No regression: a networked match keeps the single local-player readout (driven by
	# _local_id), not one per slot.
	_ck(_game._readouts.size() == 1 and int(_game._readouts[0]["id"]) == _game._local_id,
		"networked match keeps the single local-player readout")
	# Networked matches are unchanged: opening the leave confirmation must NOT freeze the
	# lockstep clock — it keeps running under the overlay so peers cannot diverge (`_pause_open`
	# gates only the local PLAYING branch, never `_process_networked`).
	if not _game.sim.finished:
		_game._open_pause_overlay()
		var net_tick_before: int = _game.sim.tick
		_game._process(Spec.TICK_DELTA * 4)
		_ck(_game._pause_open and _game.sim.tick > net_tick_before,
			"networked: the simulation keeps running while the pause overlay is open")
		_game._resume_match()
	# Peer-dropped notice state: latch + visible, non-blocking message.
	_game._on_player_dropped(0)
	_ck(_game._net.dropped.has(0), "dropped player latched to predicted input")
	_ck(_game._notice_label.visible and _game._notice_label.text == tr("NET_NOTICE_PEER_LEFT"),
		"peer-dropped notice is shown")
	# Networked best-of-N series: a resolved round records the running score and the host
	# rebuilds the next round off a fresh per-round seed (deterministic auto-advance); the
	# series ends with Rematch + Back — no longer Back-only. Driven through the real series
	# methods (bypassing only the wall-clock auto-advance/loading timers).
	_game._dropped_ids.clear()              # undo the drop injected above so player 0 stays human
	var seed_r1: int = _game._series.seed_for_round()
	var round1: int = _game._series.current_round_number()
	_game._on_round_over_networked(0)       # team 0 takes the round
	_ck(_game._phase == _game.Phase.ROUND_OVER and _game._series.wins_for(0) == 1,
		"networked round-over records the running score")
	_ck(_game._next_btn.visible, "networked round-over offers the next-round affordance on the host")
	_game._start_round_networked(_game._net_round + 1)
	_ck(_game._series.current_round_number() == round1 + 1 and _game._series.seed_for_round() != seed_r1,
		"networked next round reuses the roster with a fresh per-round seed")
	# Drive to a clinch and confirm the online results screen is no longer Back-only.
	var loops := 0
	while not _game._series.finished and loops < 20:
		_game._on_round_over_networked(0)
		loops += 1
		if not _game._series.finished:
			_game._start_round_networked(_game._net_round + 1)
	_ck(_game._phase == _game.Phase.SERIES_OVER and _game._rematch_btn.visible and _game._back_btn.visible
		and not _game._rematch_btn.disabled, "online series-over offers Rematch and Back to lobby")
	_game._on_rematch_pressed()             # host rematch
	_ck(_game._series.wins_for(0) == 0, "online Rematch resets the running score")
	NetContext.clear()
	_game.queue_free()

func _ck(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS: ", msg)
	else:
		_fail = true
		printerr("  FAIL: ", msg)

func _check_lobby() -> void:
	# Empty state on first frame: start button disabled, empty label visible.
	var start := _find(_lobby, func(n): return n is Button and n.text == tr("BTN_START"))
	_ck(start != null and start.disabled, "Start disabled in empty lobby")
	# Add 4 players via the lobby API and confirm Start enables.
	for i in 4:
		_lobby._on_add_player()
	_ck(not start.disabled, "Start enabled after adding 4 players")
	# Each added slot carries a valid, externalised character choice by default.
	var with_char := true
	for p in _lobby._players:
		if not Characters.has(p.get("character", "")):
			with_char = false
	_ck(with_char, "every lobby slot defaults to a valid character")
	# A character OptionButton is present and focusable in each slot row.
	var char_select := _find(_lobby, func(n): return n is OptionButton and n.item_count == Characters.count())
	_ck(char_select != null and char_select.focus_mode == Control.FOCUS_ALL, "character selector present and focusable")
	# Selecting a character surfaces its SSOT description + starting strengths in a
	# focusable, labelled preview that reflects the same values the simulation applies.
	_check_character_preview(char_select)
	# A Controls selector (Bot + every local scheme) is present and focusable per slot.
	var ctrl_select := _find(_lobby, func(n): return n is OptionButton and n.item_count == InputScheme.count() + 1)
	_ck(ctrl_select != null and ctrl_select.focus_mode == Control.FOCUS_ALL, "control-scheme selector present and focusable")
	# Default routing: slot 0 is a local human, the rest are bots (humans opt-in).
	_ck(InputScheme.is_human(_lobby._players[0].get("controller", "")), "slot 0 defaults to a local human")
	_ck(_lobby._players[1].get("controller", "") == InputScheme.BOT, "later slots default to bots")
	# Conflict prevention: slot 0's scheme is shown disabled in another slot's selector.
	# (Populate a fresh selector for slot 1 — within one frame the live rows are mid
	# rebuild via deferred queue_free, so we exercise the production populate path directly.)
	var taken: String = _lobby._players[0]["controller"]
	var probe := OptionButton.new()
	_lobby._populate_control_options(probe, 1)
	var disabled_taken := false
	for i in probe.item_count:
		if probe.get_item_metadata(i) == taken:
			disabled_taken = probe.is_item_disabled(i)
	probe.free()
	_ck(disabled_taken, "a scheme already taken is disabled in other slots")
	# Adding up to 8 then one more keeps it capped.
	for i in 10:
		_lobby._on_add_player()
	_ck(_lobby._players.size() == Spec.MAX_PLAYERS, "Roster capped at MAX_PLAYERS")
	_check_match_length(start)

## Match-length picker: present, focusable, defaults to the current value, gated like Start,
## and selecting an option commits that best-of to MatchConfig on Start without resetting
## the roster.
func _check_match_length(start: Button) -> void:
	var buttons: Array = _lobby._length_buttons
	_ck(buttons.size() == _lobby.LENGTH_OPTIONS.size() and buttons.size() >= 3,
		"match-length picker offers at least 1/3/5 options")
	var values: Array = []
	var default_pressed := false
	var all_focusable := true
	for btn in buttons:
		values.append(int(btn.get_meta("best_of")))
		if btn.focus_mode != Control.FOCUS_ALL or btn.tooltip_text.is_empty():
			all_focusable = false
		if int(btn.get_meta("best_of")) == Spec.SERIES_BEST_OF_DEFAULT and btn.button_pressed:
			default_pressed = true
	_ck(values.has(1) and values.has(3) and values.has(5), "picker includes 1, 3 and 5 rounds")
	_ck(all_focusable, "every length option is focusable and labelled")
	_ck(default_pressed and _lobby._best_of == Spec.SERIES_BEST_OF_DEFAULT,
		"current value (SERIES_BEST_OF_DEFAULT) is selected by default")
	# Enabled alongside Start (valid roster, not loading); disabled while loading.
	_ck(not start.disabled and not buttons[0].disabled, "length picker enabled with a valid roster")
	# Picking a different length commits it to MatchConfig.best_of without touching the roster.
	var roster_before: int = _lobby._players.size()
	var bo1: Button = null
	for btn in buttons:
		if int(btn.get_meta("best_of")) == 1:
			bo1 = btn
	bo1.button_pressed = true
	_lobby._on_match_length_selected(1)
	_ck(_lobby._best_of == 1 and _lobby._players.size() == roster_before,
		"selecting a length updates best_of and keeps the roster")
	MatchConfig.best_of = _lobby._best_of
	_ck(MatchConfig.best_of == 1, "chosen best_of is committed to MatchConfig before Start")
	# Map picker mirrors the length picker: one focusable option per Maps entry, one selected.
	_ck(_lobby._map_buttons.size() == Maps.count() and _lobby._map_buttons.size() >= 2,
		"map picker offers every map")
	var map_pressed := false
	for btn in _lobby._map_buttons:
		if btn.button_pressed:
			map_pressed = true
	_ck(map_pressed, "a map is selected by default")
	_lobby._on_map_selected("open")
	MatchConfig.map_id = _lobby._map_id
	_ck(_lobby._map_id == "open" and MatchConfig.map_id == "open", "selecting a map commits it to MatchConfig")

func _check_game() -> void:
	_ck(_game.sim != null, "Game simulation created")
	_ck(_game.sim.players.size() == 8, "8 players in live game scene")
	# The chosen character is carried onto player state and shown in the in-game HUD.
	_ck(Characters.has(_game.sim.get_player(0).character_key), "player 0 character carried into simulation")
	# Local match: the bottom HUD shows one per-player readout for the single local human,
	# labelled by player number and keyed to that player's balloons / range / speed /
	# status / character.
	_ck(_game._readouts.size() == 1, "bottom HUD shows one readout for the local human")
	var r0: Dictionary = _game._readouts[0]
	var p0: PlayerState = _game.sim.get_player(int(r0["id"]))
	_ck(int(r0["id"]) == 0, "first readout is player 1's slot")
	_ck(not r0["root"].tooltip_text.is_empty(), "each readout carries an accessibility label/description")
	_ck(r0["stats"].text == "%s %d   %s %d   %s %0.1f" % [
		tr("HUD_BALLOONS"), p0.max_balloons, tr("HUD_RANGE"), p0.range,
		tr("HUD_SPEED"), Fixed.to_float(p0.speed)], "readout shows that player's balloons, range and speed")
	_ck(r0["status"].text == tr("HUD_STATUS_PLAYING"), "readout shows the live status")
	# The readout surfaces the skill cooldown state so the player knows when they can cast.
	# A freshly built round starts with the skill ready (no cooldown).
	_ck(r0["skill"].visible and r0["skill"].text == tr("HUD_SKILL_READY"),
		"readout shows the skill as ready at round start")
	# Once on cooldown, the readout counts down in seconds instead.
	p0.skill_cooldown = Spec.TICK_RATE * 3
	_game._update_readout(r0, p0)
	_ck(r0["skill"].text == tr("HUD_SKILL_COOLDOWN").format(["3.0"]),
		"readout counts down the skill cooldown in seconds")
	p0.skill_cooldown = 0
	var def0: Dictionary = Characters.get_def(p0.character_key)
	_ck(r0["character"].text == "%s: %s · %s" % [tr("HUD_CHARACTER"),
		tr(def0["name_key"]), tr(def0["motif_key"])], "readout shows the chosen character")
	# A single local human is routed; every other slot is a bot.
	_ck(_game._humans.size() == 1, "one local human routed into the round")
	_ck(_game._ai.size() == 7, "remaining slots filled with bots")
	# The HUD shows a control hint chip per player slot (discoverability).
	_ck(_game._controls_box != null and _game._controls_box.get_child_count() == _game.sim.players.size(), "HUD shows a control hint per player")
	# The HUD shows the real round number / best-of and a per-team running score (no
	# hardcoded "Round 1").
	_ck(_game._series != null and _game._series.best_of == Spec.SERIES_BEST_OF_DEFAULT, "Game scene runs a best-of-N series")
	_ck(_game._round_label.text == tr("HUD_ROUND_OF").format([1, _game._series.best_of]), "HUD shows real 'Round X of Y'")
	_ck(_game._score_box != null and _game._score_box.get_child_count() > 0, "HUD shows a running per-team score")
	# Power-up pickup cue: collecting a power-up spawns a render-only floating icon+label burst,
	# and each kind resolves to a distinct localized label (told by more than colour alone).
	_game._on_powerup_collected(0, Spec.PowerUp.RANGE)
	_ck(_game._pickup_fx.size() == 1, "collecting a power-up spawns a floating pickup cue")
	_ck(_game._powerup_label(Spec.PowerUp.RANGE) == tr("HUD_RANGE")
		and _game._powerup_label(Spec.PowerUp.SPEED) == tr("HUD_SPEED")
		and _game._powerup_label(Spec.PowerUp.BALLOON) == tr("HUD_BALLOONS"),
		"each power-up kind has a distinct localized pickup label")
	# Edge case: the local human demoted to a bot mid-round drops out of the per-player
	# readout cleanly on the next refresh.
	_game._demote_to_bot(0)
	_game._refresh_hud()
	_ck(_game._readouts.size() == 0,
		"a human demoted to a bot drops out of the per-player readout")
	# Every round opens with a short "get ready" countdown that fully gates the round: the
	# simulation does not step and no input is routed until it finishes or is skipped. Rebuild
	# the round so the gate is observed deterministically regardless of headless frame timing.
	_game._start_round()
	_ck(_game._phase == _game.Phase.COUNTDOWN, "each round opens in the ready-countdown phase")
	_ck(_game._countdown_overlay.visible, "ready countdown overlay is shown at round start")
	_ck(not _game._countdown_overlay.tooltip_text.is_empty(), "countdown overlay carries an accessibility label/description")
	_ck(_game.sim.elapsed_seconds() == 0.0, "simulation has not stepped during the countdown")
	# Frames pass during the countdown but still must not advance the sim or end the gate early.
	_game._process(Spec.TICK_DELTA * 4)
	_ck(_game._phase == _game.Phase.COUNTDOWN and _game.sim.elapsed_seconds() == 0.0,
		"frames during the countdown neither step the sim nor end the gate early")
	# A confirm/back press skips the countdown straight into play.
	_game._finish_countdown()
	_ck(_game._phase == _game.Phase.PLAYING and not _game._countdown_overlay.visible,
		"confirm/back skips the countdown into immediate play")
	# After the countdown, the round plays exactly as before — the sim steps on frames.
	_game._process(Spec.TICK_DELTA * 4)
	_ck(_game.sim.elapsed_seconds() > 0.0, "after the countdown the round steps the simulation as usual")
	# Skill-cast feedback: firing the simulation's skill_used signal spawns a render-only
	# burst (so a player can SEE their skill fired), which then expires over wall-clock time
	# without ever touching the deterministic sim.
	var fx_before: int = _game._skill_fx.size()
	_game.sim.skill_used.emit(0, _game.sim.get_player(0).character_key)
	_ck(_game._skill_fx.size() == fx_before + 1, "skill_used spawns a render-only cast burst")
	_ck(_game._skill_fx[-1]["name"] == tr(Characters.get_def(_game.sim.get_player(0).character_key)["skill_name_key"]),
		"the cast burst carries the SSOT skill name")
	_game._process(_game.SKILL_FX_DURATION + 0.1)
	_ck(_game._skill_fx.size() == fx_before, "the cast burst expires on wall-clock time")
	# Leave-confirmation overlay: hidden during play; a back/escape press opens it instead of
	# leaving, the simulation + series score survive, Resume returns to play, and the post-
	# series result screen is exempt (Back there is already an explicit choice).
	_ck(_game._pause_overlay != null and not _game._pause_overlay.visible, "leave confirmation hidden during play")
	_ck(_game._should_confirm_leave(), "back/escape during an active round asks for confirmation")
	var score_before: int = _game._series.wins_for(0)
	_game._open_pause_overlay()
	_ck(_game._pause_overlay.visible and _game._pause_open, "back/escape during a round opens the confirmation")
	_ck(_game._series.wins_for(0) == score_before, "opening the confirmation keeps the series score")
	# Local (non-networked) match: while the confirmation is open the board freezes — extra
	# frames must not step the sim, route input or advance the round timer, so the round
	# resolves from the exact paused state no matter how long the pause lasts.
	var paused_tick: int = _game.sim.tick
	var paused_elapsed: float = _game.sim.elapsed_seconds()
	_game._process(Spec.TICK_DELTA * 8)
	_game._process(Spec.TICK_DELTA * 8)
	_ck(_game.sim.tick == paused_tick and _game.sim.elapsed_seconds() == paused_elapsed,
		"local match: the simulation is frozen while the pause overlay is open")
	_ck(_game._resume_btn.focus_mode == Control.FOCUS_ALL and not _game._resume_btn.tooltip_text.is_empty(),
		"Resume control is focusable and labelled")
	_ck(_game._leave_btn.focus_mode == Control.FOCUS_ALL and not _game._leave_btn.tooltip_text.is_empty(),
		"Leave control is focusable and labelled")
	_ck(_game._resume_btn.focus_next == _game._leave_btn.get_path()
		and _game._leave_btn.focus_next == _game._resume_btn.get_path(),
		"focus is trapped between the two confirmation buttons")
	_game._resume_match()
	_ck(not _game._pause_overlay.visible and not _game._pause_open, "Resume dismisses the confirmation")
	_ck(_game._series.wins_for(0) == score_before and _game.sim != null, "Resume keeps the simulation and series intact")
	# Resuming continues the round from exactly where it was paused — the sim steps again.
	_game._process(Spec.TICK_DELTA * 4)
	_ck(_game.sim.tick > paused_tick, "local match: Resume continues the round and the simulation steps again")
	# Mid-series round-over reuses the roster with a fresh seed and offers a next-round
	# affordance; the final results screen offers Rematch + Back.
	var seed_r1: int = _game._series.seed_for_round()
	_game._on_round_over(0)
	_ck(_game._result_overlay.visible and _game._next_btn.visible, "mid-series round-over shows results with a next-round affordance")
	_ck(_game._next_btn.visible and not _game._next_btn.disabled, "next-round button enabled mid-series")
	_ck(_game._series.seed_for_round() != seed_r1, "next round uses a fresh seed (same roster)")
	_game._begin_next_round()
	# Drive the series to a clinch -> final results with Rematch + Back to lobby.
	while not _game._series.finished:
		_game._on_round_over(0)
	_ck(_game._rematch_btn.visible and _game._back_btn.visible, "final results show Rematch and Back to lobby")
	_ck(not _game._next_btn.visible, "final results hide the next-round button")
	_ck(not _game._should_confirm_leave(), "post-series result screen leaves without a confirmation")
	_game._on_rematch_pressed()
	_ck(_game._series.wins_for(0) == 0 and _game._series.current_round_number() == 1, "Rematch resets the score and roster")

func _check_connect() -> void:
	# Drive each required UI state through the deterministic flow and assert the
	# matching view elements render. Strings are all externalised (tr()).
	var c := _connect
	# Scanning + empty: no games found yet.
	c._flow.begin_scan()
	c._render()
	_ck(c._empty_label.visible, "Connect: empty state visible while scanning with no games")
	_ck(c._host_btn.disabled and c._scan_btn.disabled, "Connect: primary actions disabled while busy")
	_ck(c._host_btn.focus_mode == Control.FOCUS_ALL, "Connect: host button is focusable")
	_ck(not c._host_btn.tooltip_text.is_empty(), "Connect: host button has an accessibility label")
	# Discovered a game -> a join item is listed.
	c._flow.on_hosts_discovered([{"address": "127.0.0.1", "port": 27015, "name": "Den", "player_count": 2}])
	c._render()
	_ck(c._results_box.get_child_count() == 1 and c._results_box.visible, "Connect: discovered game listed as a join item")
	# Connecting -> loading overlay.
	c._flow.state = ConnectionFlow.State.CONNECTING
	c._render()
	_ck(c._loading_overlay.visible, "Connect: loading overlay visible while connecting")
	# Error -> error label + fallback guidance.
	c._flow.state = ConnectionFlow.State.ERROR
	c._flow.fallback = ConnectionFlow.Fallback.BLUETOOTH
	c._flow.error_key = "NET_ERR_CONNECT_FAILED"
	c._render()
	_ck(c._error_label.visible and not c._error_label.text.is_empty(), "Connect: error state shows a message")
	_ck(c._fallback_panel.visible, "Connect: Bluetooth/hotspot fallback guidance shown on error")
	# Fallback (no host) -> guidance without error.
	c._flow.state = ConnectionFlow.State.FALLBACK
	c._render()
	_ck(c._fallback_panel.visible and not c._error_label.visible, "Connect: fallback guidance shown when no game found")

	_check_connect_host(c)

## Host room controls + states: enters the room on host, shows the player list, gates Start on
## everyone being ready, offers a kick button per peer, and disables while starting.
func _check_connect_host(c: Control) -> void:
	c._room_name_edit.text = "Pico Den"
	c._on_host()
	_ck(c._session != null and c._session.is_server, "Connect: hosting session is a server")
	_ck(c._in_room, "Connect: hosting enters the room view")
	_ck(c._session.room_name == "Pico Den", "Connect: host's room takes the typed name")
	_ck(c._room_players_box.get_child_count() == 1, "Connect: room shows the host as the only player")
	_ck(c._char_picker.item_count == Characters.count(), "Connect: room offers every character to pick")
	_ck(c._start_btn.visible and c._start_btn.disabled, "Connect: Start visible but disabled with no peers joined")
	_ck(c._start_btn.focus_mode == Control.FOCUS_ALL and not c._start_btn.tooltip_text.is_empty(),
		"Connect: Start control is focusable and labelled")
	_ck(c._status_label.text == tr("CONNECT_NEED_PEERS"), "Connect: host is told to wait for players")
	# Host-only match-length picker mirrors the local Lobby selector and defaults to best-of-N.
	_ck(c._length_section.visible and c._length_buttons.size() == c.LENGTH_OPTIONS.size(),
		"Connect: host sees the match-length selector")
	_ck(c._map_section.visible and c._map_buttons.size() == Maps.count(),
		"Connect: host sees the map selector in the room")
	c._on_room_map_selected("cross")
	_ck(c._map_id == "cross" and c._session.match_map_id == "cross",
		"Connect: host picking a map syncs it to the session")
	_ck(c._best_of == Spec.SERIES_BEST_OF_DEFAULT, "Connect: match length defaults to the series default")
	c._on_match_length_selected(5)
	_ck(c._best_of == 5, "Connect: choosing a length updates the host's best-of-N")
	# A peer joins the room (registered in the session without a live socket).
	c._session._peer_to_player[7] = 1
	c._session._player_names[1] = "Bea"
	c._session._player_characters[1] = Characters.default_id_for_index(1)
	c._session._player_ready[1] = false
	c._on_peer_joined(7, 2)
	c._session.broadcast_room_state()
	_ck(c._room_players_box.get_child_count() == 2, "Connect: joined peer appears in the room list")
	_ck(c._start_btn.disabled, "Connect: Start stays disabled until every peer is ready")
	_ck(c._status_label.text == tr("ROOM_WAIT_READY"), "Connect: host waits on the peer's ready")
	_ck(_room_has_kick_button(c), "Connect: host sees a Kick button for the joined peer")
	# Peer readies up -> Start enables.
	c._session._player_ready[1] = true
	c._session.broadcast_room_state()
	_ck(not c._start_btn.disabled, "Connect: Start enables once every peer is ready")
	_ck(c._status_label.text == tr("CONNECT_PLAYERS_JOINED").format([2]), "Connect: host shows connected player count")
	# Starting -> loading overlay + primary actions disabled.
	c._starting = true
	c._render()
	_ck(c._loading_overlay.visible and c._loading_label.text == tr("CONNECT_STARTING"), "Connect: starting overlay shown")
	_ck(c._host_btn.disabled and c._scan_btn.disabled and c._start_btn.disabled, "Connect: primary actions disabled while starting")
	c._teardown()

## True when any room row carries a button labelled with the Kick action.
func _room_has_kick_button(c: Control) -> bool:
	for row in c._room_players_box.get_children():
		for child in row.get_children():
			if child is Button and child.text == tr("ROOM_KICK"):
				return true
	return false

func _check_character_preview(char_select: OptionButton) -> void:
	if char_select == null:
		_ck(false, "character preview: selector missing")
		return
	# The preview lives in the same slot (VBox) as the selector's controls row.
	var slot := char_select.get_parent().get_parent()
	var preview: Control = _find(slot, func(n): return n is Control and n.has_meta("slot_index"))
	_ck(preview != null, "character selection preview present in slot")
	if preview == null:
		return
	_ck(preview.focus_mode == Control.FOCUS_ALL, "character preview is focusable")
	_ck(not preview.tooltip_text.is_empty(), "character preview carries an accessible label/description")
	var desc: Label = preview.get_meta("desc")
	var stats: HBoxContainer = preview.get_meta("stats")
	# Initial selection mirrors the slot's default character (SSOT description shown).
	var first_id: String = Characters.ids()[char_select.selected]
	var first_def := Characters.get_def(first_id)
	_ck(desc.text == tr(first_def["desc_key"]), "preview shows the selected character's SSOT description")
	# Changing the selection updates the preview immediately to the new SSOT values.
	var moving_idx: int = Characters.ids().find("moving")
	char_select.select(moving_idx)
	char_select.item_selected.emit(moving_idx)
	var mdef := Characters.get_def("moving")
	_ck(desc.text == tr(mdef["desc_key"]), "preview updates description when the selection changes")
	var balloons_value: Label = stats.get_meta("Balloons").get_meta("value")
	_ck(balloons_value.text == "%s %d" % [tr("HUD_BALLOONS"), int(mdef["start_balloons"])],
		"preview shows the SSOT starting balloons the simulation applies")
	var range_value: Label = stats.get_meta("Range").get_meta("value")
	_ck(range_value.text == "%s %d" % [tr("HUD_RANGE"), int(mdef["start_range"])],
		"preview shows the SSOT starting range")
	var speed_value: Label = stats.get_meta("Speed").get_meta("value")
	_ck(speed_value.text == "%s %0.1f" % [tr("HUD_SPEED"), float(mdef["start_speed"])],
		"preview shows the SSOT starting speed")
	# The preview also surfaces the character's unique skill (name + effect) so a player
	# understands what their character does and how to trigger it from the lobby.
	var skill: Label = preview.get_meta("skill")
	_ck(skill.visible, "preview shows the unique-skill line for a chosen character")
	_ck(skill.text.contains(tr(mdef["skill_name_key"])) and skill.text.contains(tr(mdef["skill_desc_key"])),
		"preview shows the SSOT skill name and effect")
	# Unknown/empty id -> neutral empty state with stats hidden, no crash.
	_lobby._update_character_preview(preview, "")
	_ck(desc.text == tr("SLOT_CHARACTER_EMPTY") and not stats.visible and not skill.visible,
		"unknown/empty character shows a neutral empty state")

## Persist a known roster + match length, then open a FRESH lobby and confirm it restores
## them (slot count, per-slot character + controller, best-of-N) with Start enabled and the
## saved length segment pressed — the lobby reopens already configured.
func _check_lobby_restore() -> void:
	var human: String = InputScheme.ids()[0]
	var roster: Array = [
		{"name": "Ann", "team": 0, "character": Characters.ids()[1], "controller": human},
		{"name": "Bo", "team": 1, "character": Characters.ids()[0], "controller": InputScheme.BOT},
		{"name": "Cy", "team": 2, "character": Characters.ids()[2], "controller": InputScheme.BOT},
		{"name": "Di", "team": 3, "character": Characters.ids()[3], "controller": InputScheme.BOT}]
	LobbyStore.save_roster(roster, 5)
	var restored: Control = load("res://scenes/Lobby.tscn").instantiate()
	root.add_child(restored)   # _ready() restores from settings on enter-tree
	_ck(restored._players.size() == 4, "restored lobby reopens the saved roster (slot count)")
	_ck(restored._best_of == 5, "restored lobby reopens the saved match length")
	_ck(restored._players[0]["character"] == Characters.ids()[1], "restored slot keeps its character id")
	_ck(restored._players[0]["controller"] == human, "restored slot keeps its controller")
	var rstart := _find(restored, func(n): return n is Button and n.text == tr("BTN_START"))
	_ck(rstart != null and not rstart.disabled, "restored valid roster enables Start")
	var pressed_ok := false
	for btn in restored._length_buttons:
		if int(btn.get_meta("best_of")) == 5 and btn.button_pressed:
			pressed_ok = true
	_ck(pressed_ok, "restored match-length option is the pressed segment")
	# Slot rows must still render with their accessible character preview (states intact).
	var preview := _find(restored, func(n): return n is Control and n.has_meta("slot_index"))
	_ck(preview != null and preview.focus_mode == Control.FOCUS_ALL,
		"restored slots keep their focusable, labelled character preview")
	restored.queue_free()

## Drop any persisted lobby/language sections while keeping [audio] intact, so the first
## lobby instance opens empty (deterministic baseline).
func _clear_persisted_lobby() -> void:
	var cfg := ConfigFile.new()
	cfg.load(LobbyStore.PATH)
	if cfg.has_section(LobbyStore.SECTION_LOBBY):
		cfg.erase_section(LobbyStore.SECTION_LOBBY)
	if cfg.has_section(LobbyStore.SECTION_UI):
		cfg.erase_section(LobbyStore.SECTION_UI)
	cfg.save(LobbyStore.PATH)

## Restore the user's real settings file (or remove our scratch file on a clean machine).
func _finish_settings() -> void:
	if _settings_had:
		var f := FileAccess.open(LobbyStore.PATH, FileAccess.WRITE)
		f.store_string(_settings_backup)
		f.close()
	elif FileAccess.file_exists(LobbyStore.PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(LobbyStore.PATH))

func _find(node: Node, pred: Callable) -> Node:
	if pred.call(node):
		return node
	for c in node.get_children():
		var r := _find(c, pred)
		if r != null:
			return r
	return null
