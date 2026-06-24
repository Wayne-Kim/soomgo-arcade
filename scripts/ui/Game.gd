extends Node2D
## Game scene: renders the deterministic Simulation for the current round of a best-of-N
## series. Each LOCAL human slot's input is routed into the sim and the remaining slots are
## filled with AiController; the HUD shows the live round number + running score, per-player
## control hints and a results overlay. Between rounds the committed roster is reused with a
## fresh seed (no return to the lobby); when a team clinches the series a final screen offers
## Rematch or Back to lobby. Routing is read-only (sample input -> Simulation.set_input), so
## the fixed-step simulation stays deterministic regardless of how many humans play. Strings
## are externalised via tr().
##
## NETWORKED mode (entered from the Connect flow via NetContext): a single deterministic round
## driven by lockstep over ENet. This device drives NetSession.local_player_id from the
## keyboard, broadcasts its per-tick input and applies peers' inputs through NetMatch, while
## empty slots run bots locally off the shared seed. A dropped peer is predicted so the round
## resolves with no hang or desync.

const CELL: int = 44
const TOP_MARGIN: int = 88
const AUTO_ADVANCE_SECONDS: float = 2.5   # mid-series pause before the next round auto-starts
const LOADING_SECONDS: float = 0.4        # brief "loading between rounds" beat
const COUNTDOWN_SECONDS: float = 3.0      # short, party-friendly "get ready" beat before each round

## Phases gate input/stepping and which overlay affordances are shown. COUNTDOWN precedes
## PLAYING at the start of every (local) round: the sim is built but neither steps nor reads
## input until the countdown finishes or is skipped.
enum Phase { COUNTDOWN, PLAYING, ROUND_OVER, SERIES_OVER, LOADING }

var _series: MatchSeries
var _phase: int = Phase.PLAYING

var sim: Simulation
var _ai: Array[AiController] = []
var _humans: Dictionary = {}        # player_id -> InputScheme id driving that slot
var _accum: float = 0.0
var _origin: Vector2 = Vector2.ZERO
# Wall-clock animation phase for character sprites (render-only; never feeds the
# deterministic simulation). Drives idle/walk frame selection from the sheet.
var _anim_time: float = 0.0

# Render-only skill-cast bursts: each entry is { "pos": Vector2, "color": Color,
# "name": String, "age": float }. Spawned from the `skill_used` signal and advanced by
# wall-clock time in _process, so the on-screen flash never touches lockstep determinism.
var _skill_fx: Array = []
const SKILL_FX_DURATION: float = 0.7

# Render-only power-up pickup bursts: each entry is { "pos": Vector2, "kind": int, "age": float }.
# Spawned from the `powerup_collected` signal and advanced by wall-clock time, so the floating
# "what did I grab" cue (icon + label) never touches lockstep determinism.
var _pickup_fx: Array = []
const PICKUP_FX_DURATION: float = 0.85

# Networking (set when entering from the Connect flow via NetContext).
var _networked: bool = false
var _session: NetSession = null
var _net: NetMatch = null
var _local_id: int = 0
## Monotonic round tag for the active networked round. Inputs are stamped with it and a
## NetMatch only consumes inputs tagged for its own round, so a peer that has auto-advanced
## ahead cannot corrupt a slower peer's still-running round. It climbs every round (and every
## rematch round) and is host-authoritative — adopted verbatim from the host's ADVANCE.
var _net_round: int = 0
## net_round tag -> Array of {tick,pid,dir,place}: inputs that arrived for a future round
## before this peer built it (peer timing skew across the inter-round pause). Drained when the
## matching round starts.
var _pending_net_inputs: Dictionary = {}
## Latched place/skill press edges for networked input sampling. is_action_just_pressed() is
## true for only ONE render frame, but a fixed tick may be due zero times (a short frame) or
## several (catch-up) in that frame, and a stalled tick re-runs the same target frame next
## render frame. Reading the edge directly inside the tick loop therefore dropped balloon/skill
## commands during any network hitch (the reported "can't place balloons online" bug). These
## latch the edge on the render clock; the tick sampler consumes them exactly once per frame.
var _place_latched: bool = false
var _skill_latched: bool = false
## Highest absolute frame we have already sampled + broadcast our local input for. Guards against
## re-sampling — and re-broadcasting a neutral input over — a frame queued just before a stall.
## Reset to -1 each round because the per-round NetMatch restarts its frame clock at 0.
var _last_sampled_frame: int = -1
## Player ids that left the match; they become deterministic bots in every subsequent round
## (host-authoritative — broadcast in ADVANCE so every peer rebuilds the same assignment).
var _dropped_ids: Array = []
## An ADVANCE that arrived before this peer's own round_over (defensive against extreme skew);
## applied once the local round resolves. {net_round:int, reset:bool}.
var _pending_advance: Dictionary = {}
## Set once the host's relay is gone: the current round finishes locally, then the series ends
## gracefully (Back to lobby only — no host to coordinate a rematch). Reconnection is out of scope.
var _host_lost: bool = false

# HUD nodes.
var _round_label: Label
var _score_box: HBoxContainer
var _time_label: Label
var _left_label: Label
var _notice_label: Label
var _controls_box: HBoxContainer

# Bottom HUD: per-player live readouts (balloons / range / speed / status / character). In a
# LOCAL match one readout is shown per local human — the slots driven by a human scheme, so
# every friend on the same screen sees their own power-ups and whether they are trapped or
# out. A NETWORKED match collapses to the single local player (driven by _local_id), so
# today's single readout is unchanged there. The set is rebuilt only when it changes (e.g. a
# human is demoted to a bot mid-round and drops out); the values inside refresh every frame.
var _bottom_panel: PanelContainer
var _readouts_box: HFlowContainer
var _readouts: Array = []        # Array of {id, root, character, stats, status} node refs
var _readout_ids: Array = []     # player ids currently built, to detect when a rebuild is due

# Results overlay nodes.
var _result_overlay: Control
var _result_label: Label
var _overlay_score_box: HBoxContainer
var _loading_label: Label
var _next_btn: Button
var _rematch_btn: Button
var _back_btn: Button

# "Get ready" countdown overlay shown at the start of every local round. While it is up the
# round is fully gated (no stepping, no input) until it finishes or a confirm/back press
# skips it. Reuses the same neutral scrim treatment as the result/pause overlays.
var _countdown_overlay: Control
var _countdown_label: Label
var _countdown_remaining: float = 0.0
# Last whole second shown on the countdown, so a tick SFX fires once per 3·2·1 step
# (and never every frame). -1 means "nothing shown yet" for this round.
var _countdown_last_shown: int = -1

# Pause / leave-confirmation overlay (gates an accidental back/escape during an active match
# so the running series score is never discarded without a deliberate choice). While it is
# open in a LOCAL match it also freezes the simulation (the PLAYING branch in `_process` is
# gated on this flag); a networked match keeps running underneath so its lockstep clock can
# never diverge across peers.
var _pause_overlay: Control
var _resume_btn: Button
var _leave_btn: Button
var _pause_open: bool = false

# Distinct, high-contrast entity colours used only to tell players/teams apart on the
# board and in the score (functional game rendering, not a UI brand palette). Colour is
# never the sole cue: TeamMarker layers a redundant per-team SHAPE on the board markers
# and the HUD/score so colour-blind players can still tell teammates from opponents.
const TEAM_COLORS := [
	Color("#e5484d"), Color("#30a46c"), Color("#3b82f6"), Color("#f5a623"),
	Color("#a855f7"), Color("#06b6b6"), Color("#ec4899"), Color("#eab308"),
]

# Time-up warning colour for the round-countdown HUD. Functional warning hue only — never one
# of the TEAM_COLORS, since team/player identity is always a flat circle or score chip.
const TIME_UP_COLOR := Color("#ff5964")

func _ready() -> void:
	_networked = NetContext.is_networked and NetContext.session != null
	if _networked:
		# Networked best-of-N series off the shared roster + seed + host-chosen length, so the
		# HUD score/round counter and the per-round seeds (base + round index) match on every
		# peer. The series is rebuilt here (not carried via MatchConfig.series, which is the
		# local hand-off) to stay independent of any prior local match.
		_series = MatchSeries.new(MatchConfig.player_defs, maxi(1, MatchConfig.best_of),
			MatchConfig.match_seed, MatchConfig.arena_w, MatchConfig.arena_h, MatchConfig.map_id)
	else:
		_series = MatchConfig.series
		if _series == null or _series.roster.is_empty():
			# Allow running the Game scene directly (e.g. for testing) with a default roster:
			# one local human on the first scheme, the rest bots.
			var defs: Array = []
			for i in 4:
				defs.append({
					"name": "P%d" % (i + 1),
					"team": i,
					"character": Characters.default_id_for_index(i),
					"controller": InputScheme.ids()[0] if i == 0 else InputScheme.BOT,
				})
			_series = MatchSeries.new(defs, Spec.SERIES_BEST_OF_DEFAULT, 12345,
				MatchConfig.arena_w, MatchConfig.arena_h, MatchConfig.map_id)
			MatchConfig.series = _series

	_origin = Vector2(40, TOP_MARGIN)
	_build_hud()
	if _networked:
		_setup_networked_session()
		_start_round_networked()
	else:
		_start_round()

# --- Round lifecycle --------------------------------------------------------
## Build (or rebuild) the simulation for the round the series currently points at, reusing
## the committed roster with that round's fresh seed. Eliminated players from prior rounds
## return here because the roster — not last round's survivors — seeds every round.
func _start_round() -> void:
	sim = Simulation.new(_series.roster, _series.arena_w, _series.arena_h, _series.seed_for_round(), _series.map_id)
	_skill_fx.clear()
	_pickup_fx.clear()
	_ai.clear()
	# Route the single local human slot from its control scheme; fill every other slot with
	# a bot. Recomputed per round from the roster. Always keep at least one human so the
	# device stays playable even if the roster marked every slot a bot.
	_humans = InputScheme.human_map(_series.roster)
	if _humans.is_empty() and not sim.players.is_empty():
		_humans[sim.players[0].id] = InputScheme.ids()[0]
	for p in sim.players:
		if not _humans.has(p.id):
			_ai.append(AiController.new(p.id, _series.seed_for_round()))
	sim.round_over.connect(_on_round_over)
	_connect_audio()
	_refresh_control_hints()
	_enter_countdown()
	_refresh_hud()

## Wire up the live networked session once (signals that outlive any single round). The
## per-round simulation/NetMatch are rebuilt in _start_round_networked; these stay connected
## for the whole series.
func _setup_networked_session() -> void:
	_session = NetContext.session
	_local_id = NetContext.local_player_id
	_session.input_received.connect(_on_net_input)
	_session.player_dropped.connect(_on_player_dropped)
	_session.peer_left.connect(_on_peer_left)
	_session.disconnected.connect(_on_host_lost)
	_session.advance_received.connect(_on_advance_received)
	_session.rematch_requested.connect(_on_rematch_requested)

## Networked round: build the simulation for the round the series currently points at using
## the shared per-round seed (base + round index, identical on every peer), drive
## NetContext.local_player_id from the keyboard via NetMatch, and let remote peers + bots fill
## the rest. `net_round` is the shared monotonic tag stamped on this round's inputs.
## `dropped_for_round` is the host-authoritative, per-round-FROZEN set of players who had left
## as of this round's ADVANCE — they play as deterministic bots. It is deliberately the frozen
## snapshot (not the live `_dropped_ids`), so a peer that drops during the inter-round window
## can't make the host build a slot as a bot while clients (built from the same snapshot) build
## it as a human — which would desync. Such a late drop becomes a bot one round later, when the
## next ADVANCE carries it; until then every peer treats it as a human with no input (the same
## deterministic stall-then-predict on all peers).
func _start_round_networked(net_round: int = 0, dropped_for_round: Array = []) -> void:
	_net_round = net_round
	sim = Simulation.new(_series.roster, _series.arena_w, _series.arena_h, _series.seed_for_round(), _series.map_id)
	_skill_fx.clear()
	_pickup_fx.clear()
	_ai.clear()
	_humans.clear()
	var human_ids: Array = []
	var bot_ids: Array = []
	for i in _series.roster.size():
		# A roster bot, or a peer that had left as of this round's ADVANCE, plays as a bot.
		if _series.roster[i].get("bot", false) or i in dropped_for_round:
			bot_ids.append(i)
		else:
			human_ids.append(i)
	_net = NetMatch.new(sim, _local_id, human_ids, bot_ids, _series.seed_for_round())
	sim.round_over.connect(_on_round_over)
	_connect_audio()
	_drain_pending_inputs()
	# The new NetMatch restarts its frame clock at 0, so reset the local sampling guard and drop
	# any press latched during the inter-round overlay (it must not leak into the next round).
	_last_sampled_frame = -1
	_place_latched = false
	_skill_latched = false
	_accum = 0.0
	_phase = Phase.PLAYING
	if _result_overlay != null:
		_result_overlay.visible = false
	_refresh_control_hints()
	_refresh_hud()

## Apply inputs that arrived for this round before it was built (a peer auto-advanced ahead of
## us), and discard any now-stale inputs tagged for an earlier round.
func _drain_pending_inputs() -> void:
	if _pending_net_inputs.has(_net_round):
		for m in _pending_net_inputs[_net_round]:
			_net.apply_remote(m["tick"], m["pid"], m["dir"], m["place"], m["skill"])
	for tag in _pending_net_inputs.keys():
		if tag <= _net_round:
			_pending_net_inputs.erase(tag)

func _process(delta: float) -> void:
	if sim == null:
		return
	_anim_time += delta   # render-only sprite animation clock (not the sim clock)
	_advance_skill_fx(delta)
	_advance_pickup_fx(delta)
	if _networked:
		# Networked lockstep keeps running even while the leave confirmation is open: the
		# deterministic clock must never diverge across peers (so `_pause_open` is ignored here).
		_process_networked(delta)
	elif _phase == Phase.COUNTDOWN:
		_tick_countdown(delta)
	elif _phase == Phase.PLAYING and not sim.finished and not _pause_open:
		# LOCAL match: while the leave confirmation is open the whole board freezes — no input
		# routing, no bot updates, no stepping and no time accumulation (`_accum` is held), so
		# the round resolves from the exact paused state no matter how long the pause lasts.
		# Nothing else depends on this clock on a single device, so freezing is safe.
		_route_inputs()
		for bot in _ai:
			bot.update(sim, delta)
		# Fixed-step the simulation for deterministic behaviour.
		_accum += delta
		while _accum >= Spec.TICK_DELTA:
			sim.step(Spec.TICK_DELTA)
			_accum -= Spec.TICK_DELTA
	_refresh_hud()
	queue_redraw()

## Deterministic lockstep frame: drain the wire, sample + broadcast our own input once per
## fixed tick, then advance only the ticks every live peer has supplied input for. Bots are
## run inside NetMatch so they stay identical on every device.
func _process_networked(delta: float) -> void:
	_session.poll()
	if _phase != Phase.PLAYING or sim.finished:
		return
	# Latch the place/skill press edges on the render clock. They are true for only one render
	# frame, so they must be captured every frame — not only when a tick happens to be due —
	# and held until a tick consumes them, or a press is silently lost.
	if _local_is_player():
		if Input.is_action_just_pressed("p1_place"):
			_place_latched = true
		if Input.is_action_just_pressed("p1_skill"):
			_skill_latched = true
	_accum += delta
	var budget := 8   # cap catch-up so a hitch can't run away from the render loop
	while _accum >= Spec.TICK_DELTA and budget > 0:
		# Sample + broadcast our input for each target frame exactly once. Re-sampling a frame we
		# already queued (which happens every render frame a tick stalls waiting on a peer) would
		# overwrite its latched place/skill with a neutral input and broadcast that to peers —
		# silently eating the command on every device.
		var target: int = _net.current_frame + _net.input_delay
		if target > _last_sampled_frame:
			_last_sampled_frame = target
			var dir := _sample_dir()
			var place := _place_latched
			var skill := _skill_latched
			var frame := _net.sample_local(dir, place, skill)
			if frame >= 0:
				_session.broadcast_input(frame, _local_id, dir, place, _net_round, skill)
				_place_latched = false
				_skill_latched = false
		if _net.advance(1) == 0:
			break   # waiting on a slower peer's input — hold this tick rather than diverge
		_accum -= Spec.TICK_DELTA
		budget -= 1

func _local_is_player() -> bool:
	return _net != null and _local_id in _net.human_ids

## True when player `pid` is driven by the human on THIS device (networked: the local id;
## local match: a routed human slot). Used to show the skill gauge only for the player the
## viewer actually controls, so "can I cast now?" reads at a glance.
func _is_local_human(pid: int) -> bool:
	if _networked:
		return pid == _local_id and _local_is_player()
	return _humans.has(pid)

func _sample_dir() -> Vector2i:
	if not _local_is_player():
		return Vector2i.ZERO
	if Input.is_action_pressed("p1_up"):
		return Vector2i.UP
	elif Input.is_action_pressed("p1_down"):
		return Vector2i.DOWN
	elif Input.is_action_pressed("p1_left"):
		return Vector2i.LEFT
	elif Input.is_action_pressed("p1_right"):
		return Vector2i.RIGHT
	return Vector2i.ZERO

func _on_net_input(tick: int, player_id: int, dir: Vector2i, place: bool, round_index: int, skill: bool) -> void:
	if player_id == _local_id:
		return
	if round_index == _net_round:
		_net.apply_remote(tick, player_id, dir, place, skill)
	elif round_index > _net_round:
		# A peer auto-advanced ahead of us: stash this future round's input until we build it,
		# so the input is never lost (which would otherwise stall — and then desync — our slower
		# peer when it reaches that round).
		if not _pending_net_inputs.has(round_index):
			_pending_net_inputs[round_index] = []
		_pending_net_inputs[round_index].append({"tick": tick, "pid": player_id, "dir": dir, "place": place, "skill": skill})
	# round_index < _net_round: a straggler from a finished round — safely ignored.

func _on_player_dropped(player_id: int) -> void:
	# Latch the gone player to predicted input (deterministic on every peer) so the current
	# round keeps resolving, and remember it so it plays as a bot in every subsequent round.
	if _net != null:
		_net.mark_dropped(player_id)
	if not player_id in _dropped_ids:
		_dropped_ids.append(player_id)
	_show_notice(tr("NET_NOTICE_PEER_LEFT"))

func _on_peer_left(_peer_id: int) -> void:
	_show_notice(tr("NET_NOTICE_PEER_LEFT"))

func _on_host_lost() -> void:
	# The relay hub is gone: latch every remote human to prediction so this device's round still
	# resolves, then end the series gracefully once it does (no host to coordinate a rematch;
	# reconnection is out of scope).
	_host_lost = true
	if _net != null:
		for pid in _net.human_ids:
			if pid != _local_id:
				_net.mark_dropped(pid)
	_show_notice(tr("NET_NOTICE_HOST_LEFT"))

func _show_notice(text: String) -> void:
	if _notice_label != null:
		_notice_label.text = text
		_notice_label.visible = true
		# The notice adds a line to the bottom panel; regrow it so nothing clips.
		_relayout_bottom_panel.call_deferred()

## Sample the local human's control scheme and feed it into the simulation. The availability
## check is kept for parity with `_demote_to_bot` (unavailable schemes hand the slot to a
## bot rather than freezing); the single keyboard scheme is always available.
func _route_inputs() -> void:
	for pid in _humans.keys():
		if not InputScheme.is_available(_humans[pid]):
			_demote_to_bot(pid)
	for pid in _humans.keys():
		var s := InputScheme.read(_humans[pid])
		sim.set_input(pid, s["dir"], s["place"], s["skill"])

func _demote_to_bot(pid: int) -> void:
	_humans.erase(pid)
	_ai.append(AiController.new(pid, _series.seed_for_round()))
	_refresh_control_hints()

# --- Audio (render-side only) ----------------------------------------------
## Wire the deterministic simulation's signals to the render-side `Audio` layer so the
## key moments are heard. This is the ONLY bridge between the sim and audio, and it lives
## on the render node: nothing here runs inside `Simulation.step()`, the sim never reads
## audio state, and in networked play each peer reaches this independently off its own
## render — so lockstep determinism is untouched and no audio crosses the wire. Audio
## always layers on top of the existing visual cues (board flashes, overlays), never the
## sole cue for any state.
func _connect_audio() -> void:
	sim.balloon_placed.connect(func(_pid, _cell): Audio.play("balloon_place"))
	sim.explosion_happened.connect(func(_cells): Audio.play("explosion"))
	sim.player_trapped.connect(func(_pid, _cell): Audio.play("trapped"))
	sim.player_rescued.connect(func(_pid, _by): Audio.play("rescue"))
	sim.player_eliminated.connect(func(_pid, _cause): Audio.play("eliminated"))
	# Skill cast: a render-only burst at the caster plus a distinct cue, so a player can
	# tell their unique skill actually fired (it always layers on top of the world change).
	sim.skill_used.connect(_on_skill_used)
	# Power-up pickup: a render-only floating icon + label at the collector, so a player can
	# tell WHICH power-up they grabbed (not just a colour). Never mutates the simulation.
	sim.powerup_collected.connect(_on_powerup_collected)

## Spawn a render-only burst at the caster and play the skill cue when any player's unique
## skill fires. Never mutates the simulation, so lockstep determinism is untouched.
func _on_skill_used(player_id: int, character_key: String) -> void:
	Audio.play("skill")
	var p := sim.get_player(player_id)
	if p == null:
		return
	var pos := _origin + p.render_pos() * CELL + Vector2(CELL / 2.0, CELL / 2.0)
	var col: Color = TEAM_COLORS[player_id % TEAM_COLORS.size()]
	var def := Characters.get_def(character_key)
	var label := tr(def["skill_name_key"]) if not def.is_empty() else ""
	_skill_fx.append({"pos": pos, "color": col, "name": label, "age": 0.0})

## Advance and retire render-only skill bursts by wall-clock time (never the sim clock).
func _advance_skill_fx(delta: float) -> void:
	if _skill_fx.is_empty():
		return
	var kept: Array = []
	for fx in _skill_fx:
		fx["age"] = float(fx["age"]) + delta
		if float(fx["age"]) < SKILL_FX_DURATION:
			kept.append(fx)
	_skill_fx = kept

## Spawn a floating pickup cue (icon + label) at the collector when any player grabs a power-up,
## so it is clear WHICH power-up was collected — not just a colour. Render-only; never touches sim.
func _on_powerup_collected(player_id: int, kind: int) -> void:
	var p := sim.get_player(player_id)
	if p == null:
		return
	var pos := _origin + p.render_pos() * CELL + Vector2(CELL / 2.0, CELL / 2.0)
	_pickup_fx.append({"pos": pos, "kind": kind, "age": 0.0})

## Advance and retire render-only pickup bursts by wall-clock time (never the sim clock).
func _advance_pickup_fx(delta: float) -> void:
	if _pickup_fx.is_empty():
		return
	var kept: Array = []
	for fx in _pickup_fx:
		fx["age"] = float(fx["age"]) + delta
		if float(fx["age"]) < PICKUP_FX_DURATION:
			kept.append(fx)
	_pickup_fx = kept

# --- Ready countdown -------------------------------------------------------
## Open the short "get ready" beat for the round the simulation was just built for. The sim
## is left fully gated (no stepping, no input routing) until the countdown elapses or a
## confirm/back press skips it. Determinism is untouched: the round seed and the sim already
## exist; the countdown only delays when stepping begins.
func _enter_countdown() -> void:
	_phase = Phase.COUNTDOWN
	_countdown_remaining = COUNTDOWN_SECONDS
	_countdown_last_shown = -1
	if _result_overlay != null:
		_result_overlay.visible = false
	if _countdown_overlay != null:
		_countdown_overlay.visible = true
	_update_countdown_label()

## Advance the countdown on the render clock. Held (not advanced) while the leave
## confirmation is open so the countdown and that overlay never fight, and so losing window
## focus mid-countdown can never let play start early — play only begins once the phase
## flips to PLAYING below.
func _tick_countdown(delta: float) -> void:
	if _pause_open:
		return
	_countdown_remaining -= delta
	if _countdown_remaining <= 0.0:
		_finish_countdown()
	else:
		_update_countdown_label()

func _update_countdown_label() -> void:
	var n := maxi(1, int(ceil(_countdown_remaining)))
	if _countdown_label != null:
		_countdown_label.text = str(n)
	# Audio layered on top of the existing visual count (never the sole cue): one tick per
	# whole-second step as the number changes.
	if n != _countdown_last_shown:
		_countdown_last_shown = n
		Audio.play("countdown_tick")

## Leave the countdown and hand control to the live round. Shared by the natural timeout and
## the confirm/back skip path, so play starts exactly the same way in both.
func _finish_countdown() -> void:
	if _phase != Phase.COUNTDOWN:
		return
	_phase = Phase.PLAYING
	if _countdown_overlay != null:
		_countdown_overlay.visible = false
	Audio.play("countdown_go")
	_refresh_hud()

func _unhandled_input(event: InputEvent) -> void:
	# During the ready countdown a confirm/back press skips straight into play. The leave
	# confirmation takes precedence: if it is open, fall through so back resumes it instead.
	if _phase == Phase.COUNTDOWN and not _pause_open:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_back"):
			_finish_countdown()
			get_viewport().set_input_as_handled()
		return
	if not event.is_action_pressed("ui_back"):
		return
	# While the confirmation is open, back/escape resumes (dismisses it) rather than leaving.
	if _pause_open:
		_resume_match()
		get_viewport().set_input_as_handled()
		return
	# On the post-series result screen, Back to lobby is already an explicit, deliberate
	# choice, so escape leaves immediately. During an in-progress match (active round,
	# round-over, or the brief loading beat) it instead opens the leave confirmation so an
	# accidental press can't discard the running series score.
	if _phase == Phase.SERIES_OVER:
		_back_to_lobby()
	elif _should_confirm_leave():
		_open_pause_overlay()
	get_viewport().set_input_as_handled()

## Whether a back/escape press during the current phase should ask for confirmation instead
## of leaving outright. The post-series result screen is excluded: its Back-to-lobby button
## is already an explicit, deliberate choice, so escape there leaves immediately.
func _should_confirm_leave() -> bool:
	return _phase != Phase.SERIES_OVER

# --- Rendering -------------------------------------------------------------
func _draw() -> void:
	if sim == null:
		return
	var a := sim.arena
	for y in a.height:
		for x in a.width:
			var c := Vector2i(x, y)
			var r := Rect2(_origin + Vector2(x * CELL, y * CELL), Vector2(CELL - 2, CELL - 2))
			match a.get_tile(c):
				Spec.Tile.HARD_WALL:
					draw_rect(r, Color("#33415a"))
				Spec.Tile.SOFT_BLOCK:
					draw_rect(r, Color("#7a5230"))
				_:
					draw_rect(r, Color("#16243f"))
					var pu := a.get_powerup(c)
					if pu != Spec.PowerUp.NONE:
						_draw_powerup(r, pu)

	# Roller Coating paint: team-tinted floor overlay that speeds allies / slows foes. Drawn
	# above the floor but below players, fading as its remaining ticks run out.
	for cell in sim.active_paints:
		var paint: Dictionary = sim.active_paints[cell]
		_draw_paint(cell, int(paint["team"]), int(paint["ticks_left"]))

	for cell in sim.explosions:
		var er := Rect2(_origin + Vector2(cell.x * CELL, cell.y * CELL), Vector2(CELL - 2, CELL - 2))
		draw_rect(er, Color(1.0, 0.6, 0.2, 0.8))

	for b in sim.balloons:
		var center := _origin + Vector2(b.cell.x * CELL + CELL / 2.0, b.cell.y * CELL + CELL / 2.0)
		draw_circle(center, CELL * 0.32, Color("#2e9bd6"))
		draw_arc(center, CELL * 0.32, 0, TAU, 24, Color("#bfe6f7"), 2.0)

	for p in sim.players:
		if not p.alive:
			continue
		var pos := _origin + p.render_pos() * CELL + Vector2(CELL / 2.0, CELL / 2.0)
		var col: Color = TEAM_COLORS[p.id % TEAM_COLORS.size()]
		# Just-rescued invulnerability: fade the whole player (sprite + cues) to 0.55
		# alpha. The art stays legible at this alpha (docs/character-art.md §8).
		var alpha := 0.55 if p.invuln_timer > 0.0 else 1.0
		var sprites := CharacterSprites.load_for(p.character_key)
		if sprites != null:
			_draw_character(p, pos, col, alpha, sprites)
		else:
			# No produced art for this character → clean fallback to today's shape
			# marker as the body (pilot ships incrementally, no crash/blank cell).
			col.a = alpha
			_draw_marker_body(p, pos, col)
		if p.trapped:
			# Engine-drawn bubble ring around the (curled) player; identical for the
			# sprite and fallback paths so trapped reads the same everywhere.
			draw_arc(pos, CELL * 0.46, 0, TAU, 28, Color(0.62, 0.88, 1.0, alpha), 3.0)
		# Skill recharge gauge for the player THIS device controls, so "can I cast now?"
		# reads at a glance (a filling ring while on cooldown, a pulsing full ring when ready).
		if _is_local_human(p.id):
			_draw_skill_gauge(p, pos)

	# Skill-cast bursts sit on top of everything so a fired skill always reads clearly.
	for fx in _skill_fx:
		_draw_skill_fx(fx)
	# Power-up pickup cues float above that, naming what was just grabbed.
	for fx in _pickup_fx:
		_draw_pickup_fx(fx)

## Render-only skill recharge ring drawn around the local player's character. A dark base
## ring plus a clockwise arc that fills from empty→full as the cooldown elapses; once ready,
## a brighter pulsing full ring. Shape (partial vs full) carries the meaning, not colour
## alone, so it stays readable for colour-blind players.
func _draw_skill_gauge(p: PlayerState, pos: Vector2) -> void:
	var max_ticks := Simulation.skill_cooldown_max(p.character_key)
	if max_ticks <= 0:
		return
	var col: Color = TEAM_COLORS[p.id % TEAM_COLORS.size()]
	var radius := CELL * 0.54
	# Dark base ring so the gauge reads on any tile.
	draw_arc(pos, radius, 0, TAU, 40, Color(0, 0, 0, 0.45), 4.0)
	if p.skill_cooldown > 0:
		var recharged: float = clampf(1.0 - float(p.skill_cooldown) / float(max_ticks), 0.0, 1.0)
		var start := -PI / 2.0   # 12 o'clock
		draw_arc(pos, radius, start, start + recharged * TAU, 40, Color(col.r, col.g, col.b, 0.95), 4.0)
	else:
		# Ready: a bright, gently pulsing full ring (white core + team-coloured rim).
		var pulse: float = 0.65 + 0.35 * sin(_anim_time * 6.0)
		draw_arc(pos, radius, 0, TAU, 40, Color(1, 1, 1, pulse), 3.5)
		draw_arc(pos, radius, 0, TAU, 40, Color(col.r, col.g, col.b, pulse), 2.0)

## Render-only paint overlay for one coated cell. Team-tinted fill + outline, fading out
## over its final second so players see the effect expire (mirrors the 5s sim duration).
func _draw_paint(cell: Vector2i, team: int, ticks_left: int) -> void:
	var col: Color = TEAM_COLORS[team % TEAM_COLORS.size()]
	# Fade across the last 60 ticks (~1s) so the overlay visibly wears off.
	var fade: float = clampf(float(ticks_left) / 60.0, 0.0, 1.0)
	var r := Rect2(_origin + Vector2(cell.x * CELL, cell.y * CELL), Vector2(CELL - 2, CELL - 2))
	draw_rect(r, Color(col.r, col.g, col.b, 0.28 * fade))
	draw_rect(r, Color(col.r, col.g, col.b, 0.7 * fade), false, 2.0)

## Render-only expanding ring + skill name at a cast site. `age` runs 0→SKILL_FX_DURATION.
func _draw_skill_fx(fx: Dictionary) -> void:
	var t: float = clampf(float(fx["age"]) / SKILL_FX_DURATION, 0.0, 1.0)
	var pos: Vector2 = fx["pos"]
	var base: Color = fx["color"]
	var alpha := 1.0 - t
	# Expanding shockwave ring.
	var radius := CELL * (0.3 + 1.1 * t)
	draw_arc(pos, radius, 0, TAU, 32, Color(base.r, base.g, base.b, alpha), 3.0)
	# A second, brighter inner ring for a bit of pop.
	draw_arc(pos, radius * 0.6, 0, TAU, 24, Color(1, 1, 1, alpha * 0.7), 2.0)
	# Skill name floating upward above the caster.
	var label: String = fx["name"]
	if label != "":
		var f := ThemeDB.fallback_font
		var rise := pos + Vector2(0, -CELL * 0.6 - 24.0 * t)
		var size := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16)
		var origin := rise - Vector2(size.x / 2.0, 0)
		draw_string(f, origin + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			Color(0, 0, 0, alpha * 0.8))
		draw_string(f, origin, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16,
			Color(base.r, base.g, base.b, alpha))

## Legacy body: the redundant team SHAPE drawn large at the cell centre, with the
## player number on top. Used when a character has no produced sprite sheet yet.
func _draw_marker_body(p: PlayerState, pos: Vector2, col: Color) -> void:
	# Redundant non-colour cue: the marker's SHAPE encodes the team, so colour-blind
	# players can tell teammates from opponents without relying on hue.
	TeamMarker.draw_shape(self, pos, CELL * 0.38, col, p.team)
	_draw_player_number(p, pos, col.a)

## Sprite body: the chosen character drawn at the cell, team-tinted at runtime, with
## the redundant team shape relocated to a small corner footplate badge (so it no
## longer occludes the character — spike composition finding) and the player number
## kept for individual identification.
func _draw_character(p: PlayerState, pos: Vector2, col: Color, alpha: float, sprites: CharacterSprites) -> void:
	var state := _sprite_state_for(p, sprites)
	# Frame from the wall-clock animation (static if the row has a single frame).
	var n := sprites.frame_count(state)
	var fps := 8.0 if state == "walk" else 2.5
	var frame := int(_anim_time * fps) if n > 1 else 0
	var src := sprites.cell_rect(state, frame)
	# Tint identity is the per-PLAYER colour index (TEAM_COLORS[p.id % size]); cache the
	# baked sheet by that index, not p.team — teammates share a team but get distinct
	# colours, so keying by team would hand back the wrong tint.
	var color_idx := p.id % TEAM_COLORS.size()
	var tex := sprites.sheet_texture(color_idx, TEAM_COLORS[color_idx])
	# Draw the source cell scaled to fill the board cell (bottom-anchored), leaving the
	# 2px gutter the tiles already respect (Game.gd tiles draw at CELL-2).
	var dest_size := Vector2(CELL, CELL)
	var dest := Rect2(pos - Vector2(CELL / 2.0, CELL / 2.0), dest_size)
	draw_texture_rect_region(tex, dest, src, Color(1, 1, 1, alpha))
	# Redundant team SHAPE as a corner footplate badge (never removed) — keeps team
	# identity available without colour, no longer covering the character body.
	var badge_r := CELL * 0.16
	var badge_pos := pos + Vector2(CELL * 0.30, CELL * 0.34)
	var badge_col := col
	badge_col.a = alpha
	TeamMarker.draw_shape(self, badge_pos, badge_r, badge_col, p.team, 1.5)
	_draw_player_number(p, pos, alpha)

## Player number, centred near the top of the cell so it reads over the sprite body.
func _draw_player_number(p: PlayerState, pos: Vector2, alpha: float) -> void:
	var f := ThemeDB.fallback_font
	draw_string(f, pos + Vector2(-5, 6), str(p.id + 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 18,
		Color(0, 0, 0, alpha))

## Which sheet row a living player renders from: trapped (in-bubble) → walk (moving)
## → idle, each gated on the row actually existing in the character's sheet so a
## partial sheet degrades to idle rather than indexing a missing row.
func _sprite_state_for(p: PlayerState, sprites: CharacterSprites) -> String:
	if p.trapped and sprites.has_state("trapped"):
		return "trapped"
	if p.moving and sprites.has_state("walk"):
		return "walk"
	return "idle"

## A power-up on the floor: a coloured chip PLUS a distinct white icon per kind, so the type is
## told by SHAPE (balloon = circle, range = 4-way arrows, speed = double chevron) and never by
## colour alone — readable for colour-blind players, matching the game's redundant-cue rule.
func _draw_powerup(r: Rect2, pu: int) -> void:
	var center := r.position + r.size / 2.0
	var col := _powerup_color(pu)
	var half := CELL * 0.2
	var chip := Rect2(center - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
	draw_rect(chip, Color(col.r, col.g, col.b, 0.35))
	draw_rect(chip, col, false, 2.0)
	_draw_powerup_icon(center, CELL * 0.15, pu, Color(1, 1, 1, 0.95))

## Functional power-up colour, shared by the floor chip and the floating pickup cue.
func _powerup_color(pu: int) -> Color:
	match pu:
		Spec.PowerUp.BALLOON: return Color("#2e9bd6")
		Spec.PowerUp.RANGE: return Color("#e5484d")
		Spec.PowerUp.SPEED: return Color("#30a46c")
	return Color("#f5d142")

## The localized one-word name of a power-up kind (reuses the HUD stat labels).
func _powerup_label(pu: int) -> String:
	match pu:
		Spec.PowerUp.BALLOON: return tr("HUD_BALLOONS")
		Spec.PowerUp.RANGE: return tr("HUD_RANGE")
		Spec.PowerUp.SPEED: return tr("HUD_SPEED")
	return ""

## Draw a power-up's distinct SHAPE centred at `c`, sized ~`s`, in `col`: balloon -> circle with
## a knot; range -> a four-way arrow cross; speed -> a double chevron. Shape is the primary cue.
func _draw_powerup_icon(c: Vector2, s: float, pu: int, col: Color) -> void:
	match pu:
		Spec.PowerUp.BALLOON:
			draw_circle(c, s, col)
			draw_line(c + Vector2(0, s), c + Vector2(0, s + s * 0.5), col, 2.0)
		Spec.PowerUp.RANGE:
			for dir: Vector2 in [Vector2.RIGHT, Vector2.LEFT, Vector2.UP, Vector2.DOWN]:
				var tip := c + dir * s * 1.3
				var perp := Vector2(-dir.y, dir.x)
				draw_line(c, tip, col, 2.0)
				draw_line(tip, tip - dir * (s * 0.5) + perp * (s * 0.4), col, 2.0)
				draw_line(tip, tip - dir * (s * 0.5) - perp * (s * 0.4), col, 2.0)
		Spec.PowerUp.SPEED:
			for i in 2:
				var x0 := c.x - s * 0.6 + i * s * 0.7
				draw_line(Vector2(x0, c.y - s), Vector2(x0 + s * 0.7, c.y), col, 2.0)
				draw_line(Vector2(x0 + s * 0.7, c.y), Vector2(x0, c.y + s), col, 2.0)
		_:
			draw_circle(c, s, col)

## Render-only floating pickup cue: the grabbed power-up's icon + "+Name" rising and fading above
## the collector, so a player can tell WHICH item they got at a glance.
func _draw_pickup_fx(fx: Dictionary) -> void:
	var t: float = clampf(float(fx["age"]) / PICKUP_FX_DURATION, 0.0, 1.0)
	var alpha := 1.0 - t
	var kind := int(fx["kind"])
	var base := _powerup_color(kind)
	var pos: Vector2 = fx["pos"] + Vector2(0, -CELL * 0.55 - 30.0 * t)
	_draw_powerup_icon(pos + Vector2(-CELL * 0.34, 0), CELL * 0.13, kind, Color(base.r, base.g, base.b, alpha))
	var label := "+%s" % _powerup_label(kind)
	var f := ThemeDB.fallback_font
	var origin := pos + Vector2(-CELL * 0.18, 6.0)
	draw_string(f, origin + Vector2(1, 1), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(0, 0, 0, alpha * 0.8))
	draw_string(f, origin, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, Color(base.r, base.g, base.b, alpha))

# --- HUD --------------------------------------------------------------------
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)

	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	layer.add_child(top)
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 28)
	top.add_child(top_row)
	_round_label = _hud_label(top_row)
	_score_box = _make_score_box(top_row)
	_time_label = _hud_label(top_row)
	A11y.label(_time_label, tr("HUD_TIME_LEFT"), tr("A11Y_TIME_LEFT"))
	_left_label = _hud_label(top_row)

	_build_readout_panel(layer)
	_build_controls_panel(layer)

	_result_overlay = _build_result_overlay(layer)
	_countdown_overlay = _build_countdown_overlay(layer)
	# Built last so it layers above the results/countdown overlays and the board; hidden until
	# a back/escape press during an in-progress match asks to confirm leaving.
	_pause_overlay = _build_pause_overlay(layer)

## Discoverability: a top-of-screen strip that names which control scheme drives each
## player slot (e.g. "P2 · WASD + Shift"), or "Bot" for AI slots. Each chip is tinted with
## the renderer's functional per-player colour (colour-by-meaning, same as the board
## markers) so a friend can match their controls to their on-board character.
func _build_controls_panel(layer: CanvasLayer) -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	panel.offset_top = 48
	layer.add_child(panel)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 18)
	panel.add_child(row)
	var caption := Label.new()
	caption.text = "%s:" % tr("HUD_CONTROLS")
	row.add_child(caption)
	_controls_box = HBoxContainer.new()
	_controls_box.add_theme_constant_override("separation", 14)
	row.add_child(_controls_box)
	A11y.label(panel, tr("HUD_CONTROLS"), tr("A11Y_CONTROLS_HINT"))
	_refresh_control_hints()

func _refresh_control_hints() -> void:
	if _controls_box == null or sim == null:
		return
	for child in _controls_box.get_children():
		child.queue_free()
	for p in sim.players:
		var item := HBoxContainer.new()
		item.add_theme_constant_override("separation", 5)
		# Same team shape + per-player colour as the on-board marker, so a player can
		# match their controls to their character by shape as well as by colour.
		var player_col: Color = TEAM_COLORS[p.id % TEAM_COLORS.size()]
		item.add_child(TeamGlyph.new(p.team, player_col, 8.0))
		var chip := Label.new()
		var scheme_text := tr("CTRL_BOT")
		if _networked and _net != null:
			# Networked: distinguish this device's player, other online peers, and bots.
			if p.id == _local_id:
				scheme_text = tr("CTRL_YOU")
			elif p.id in _net.human_ids:
				scheme_text = tr("CTRL_ONLINE")
		elif _humans.has(p.id):
			scheme_text = tr(InputScheme.label_key(_humans[p.id]))
		chip.text = "P%d · %s" % [p.id + 1, scheme_text]
		# Functional per-player colour, identical to the on-board marker (colour-by-meaning).
		chip.add_theme_color_override("font_color", player_col)
		A11y.label(chip, chip.text)
		item.add_child(chip)
		_controls_box.add_child(item)

# --- Per-player readouts ----------------------------------------------------
## Bottom strip: a compact live readout per shown player. In a local match this is one
## readout per local human; in a networked match it is just this device's player. Uses an
## HFlowContainer so up to four readouts wrap to a second row at 1280×800 rather than clip,
## and the panel grows to fit. A non-blocking notice line (e.g. a peer dropped) sits above.
func _build_readout_panel(layer: CanvasLayer) -> void:
	_bottom_panel = PanelContainer.new()
	_bottom_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_bottom_panel.offset_top = -64
	layer.add_child(_bottom_panel)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 6)
	_bottom_panel.add_child(col)
	# Non-blocking notice line (e.g. a peer dropped) — colour-by-meaning reuse of the
	# functional warning hue already used elsewhere; hidden until something happens.
	_notice_label = Label.new()
	_notice_label.add_theme_color_override("font_color", Color("#f5a623"))
	_notice_label.visible = false
	A11y.label(_notice_label, tr("A11Y_NET_NOTICE"))
	col.add_child(_notice_label)
	_readouts_box = HFlowContainer.new()
	_readouts_box.add_theme_constant_override("h_separation", 28)
	_readouts_box.add_theme_constant_override("v_separation", 8)
	col.add_child(_readouts_box)

## The player ids that should currently have a readout: just this device's player when
## networked (no regression), else every local human (the slots InputScheme.human_map kept,
## recomputed each round). A human demoted to a bot mid-round is already gone from _humans,
## so it drops out of this list — and the readout — on the next refresh.
func _readout_ids_desired() -> Array:
	if _networked:
		return [_local_id]
	var ids: Array = _humans.keys()
	ids.sort()
	return ids

func _refresh_readouts() -> void:
	if _readouts_box == null or sim == null:
		return
	var ids := _readout_ids_desired()
	if ids != _readout_ids:
		_rebuild_readouts(ids)
	for r in _readouts:
		var p: PlayerState = sim.get_player(r["id"])
		if p != null:
			_update_readout(r, p)

func _rebuild_readouts(ids: Array) -> void:
	for child in _readouts_box.get_children():
		child.queue_free()
	_readouts.clear()
	for pid in ids:
		var p: PlayerState = sim.get_player(pid)
		var team: int = p.team if p != null else 0
		var r := _make_readout(pid, team)
		_readouts.append(r)
		_readouts_box.add_child(r["root"])
	_readout_ids = ids.duplicate()
	# Grow the bottom panel to fit the (multi-line, possibly wrapped) readouts once laid out.
	_relayout_bottom_panel.call_deferred()

## Build one compact readout card. The header reuses the renderer's functional per-player
## colour AND the redundant per-team SHAPE (TeamGlyph) — exactly as the board markers and the
## controls strip do — so a player finds their own row by colour and by shape, never by hue
## alone (docs/BRAND.md §4). The slightly smaller type keeps four cards on one row at 1280px.
func _make_readout(pid: int, team: int) -> Dictionary:
	var player_col: Color = TEAM_COLORS[pid % TEAM_COLORS.size()]
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 2)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	header.add_child(TeamGlyph.new(team, player_col, 8.0))
	var num := Label.new()
	num.text = "P%d" % (pid + 1)
	num.add_theme_color_override("font_color", player_col)
	num.add_theme_font_size_override("font_size", 16)
	header.add_child(num)
	card.add_child(header)

	var character := _readout_line(card)
	var stats := _readout_line(card)
	var skill := _readout_line(card)
	var status := _readout_line(card)
	return {"id": pid, "root": card, "character": character, "stats": stats, "skill": skill, "status": status}

func _readout_line(parent: Node) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 15)
	parent.add_child(l)
	return l

## Refresh one card's live values from its player state — balloons / range / speed, status,
## and chosen character — using existing localization keys via tr(). The card carries an
## accessibility label (player number) + description (live status) and inherits the
## high-contrast theme; an empty/unknown character shows a neutral empty state, mirroring
## Characters.get_def returning {}.
func _update_readout(r: Dictionary, p: PlayerState) -> void:
	var def := Characters.get_def(p.character_key)
	var character: Label = r["character"]
	if def.is_empty():
		character.text = tr("SLOT_CHARACTER_EMPTY")
	else:
		character.text = "%s: %s · %s" % [
			tr("HUD_CHARACTER"), tr(def["name_key"]), tr(def["motif_key"])]
	r["stats"].text = "%s %d   %s %d   %s %0.1f" % [
		tr("HUD_BALLOONS"), p.max_balloons,
		tr("HUD_RANGE"), p.range,
		tr("HUD_SPEED"), Fixed.to_float(p.speed)]
	_update_readout_skill(r["skill"], p)
	var st := _status_text(p)
	r["status"].text = st
	A11y.label(r["root"], tr("A11Y_PLAYER_SLOT").format([p.id + 1]), st)

## Show the live skill state on a readout: "Skill ready" (green) when off cooldown, else
## "Skill in Ns" (grey) counting down. Hidden for characters without a unique skill. Mirrors
## the on-board recharge ring so the player has the same answer in both places.
func _update_readout_skill(label: Label, p: PlayerState) -> void:
	var max_ticks := Simulation.skill_cooldown_max(p.character_key)
	if max_ticks <= 0:
		label.visible = false
		return
	label.visible = true
	if p.skill_cooldown <= 0:
		label.text = tr("HUD_SKILL_READY")
		label.add_theme_color_override("font_color", Color(0.46, 0.93, 0.55))
	else:
		var secs: float = ceil(float(p.skill_cooldown) / float(Spec.TICK_RATE) * 10.0) / 10.0
		label.text = tr("HUD_SKILL_COOLDOWN").format([("%0.1f" % secs)])
		label.add_theme_color_override("font_color", Color(0.72, 0.78, 0.86))

## Live status, covering in play / trapped (needs rescue) / eliminated. Holds across the
## loading/countdown beats too: the sim exists (players alive, not stepping), so it reads
## "in play" until the round resolves.
func _status_text(p: PlayerState) -> String:
	if not p.alive:
		return tr("HUD_STATUS_OUT")
	elif p.trapped:
		return tr("HUD_STATUS_TRAPPED")
	return tr("HUD_STATUS_PLAYING")

## Size the bottom panel to its content so the multi-line cards (and a wrapped second row, if
## four don't fit one row) are never clipped, while staying ~64px tall in the common case.
func _relayout_bottom_panel() -> void:
	if _bottom_panel == null:
		return
	_bottom_panel.offset_top = -maxf(_bottom_panel.get_combined_minimum_size().y, 64.0)

func _hud_label(parent: Node) -> Label:
	var l := Label.new()
	parent.add_child(l)
	return l

## A horizontal strip of per-team score labels, each tinted with that team's functional
## colour so the running score reads as "colour by meaning". Carries an accessible label.
func _make_score_box(parent: Node) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	parent.add_child(box)
	A11y.label(box, tr("HUD_SCORE"), tr("A11Y_SCORE"))
	return box

func _rebuild_score(box: HBoxContainer) -> void:
	if box == null:
		return
	for child in box.get_children():
		child.queue_free()
	var lead := Label.new()
	lead.text = "%s:" % tr("HUD_SCORE")
	box.add_child(lead)
	var parts := PackedStringArray()
	for team_id in _series.teams():
		var wins: int = _series.wins_for(team_id)
		var team_col: Color = TEAM_COLORS[team_id % TEAM_COLORS.size()]
		# Same redundant team shape as the board, so the colour -> team mapping is learnable.
		box.add_child(TeamGlyph.new(team_id, team_col, 9.0))
		var l := Label.new()
		l.text = tr("SCORE_TEAM").format([team_id + 1, wins])
		l.modulate = team_col
		box.add_child(l)
		parts.append(l.text)
	A11y.label(box, "%s: %s" % [tr("HUD_SCORE"), ", ".join(parts)], tr("A11Y_SCORE"))

func _build_result_overlay(layer: CanvasLayer) -> Control:
	var overlay := ColorRect.new()
	overlay.color = Color(0.04, 0.07, 0.13, 0.9)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	layer.add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)

	_result_label = Label.new()
	_result_label.add_theme_font_size_override("font_size", 36)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_result_label)

	_overlay_score_box = HBoxContainer.new()
	_overlay_score_box.add_theme_constant_override("separation", 16)
	_overlay_score_box.alignment = BoxContainer.ALIGNMENT_CENTER
	A11y.label(_overlay_score_box, tr("HUD_SCORE"), tr("A11Y_SCORE"))
	box.add_child(_overlay_score_box)

	_loading_label = Label.new()
	_loading_label.text = tr("ROUND_LOADING")
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.visible = false
	box.add_child(_loading_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)

	_next_btn = Button.new()
	_next_btn.text = tr("BTN_NEXT_ROUND")
	A11y.label(_next_btn, tr("BTN_NEXT_ROUND"), tr("A11Y_NEXT_ROUND"))
	A11y.make_focusable(_next_btn)
	_next_btn.pressed.connect(_on_next_round_pressed)
	buttons.add_child(_next_btn)

	_rematch_btn = Button.new()
	_rematch_btn.text = tr("BTN_REMATCH")
	A11y.label(_rematch_btn, tr("BTN_REMATCH"), tr("A11Y_REMATCH"))
	A11y.make_focusable(_rematch_btn)
	_rematch_btn.pressed.connect(_on_rematch_pressed)
	buttons.add_child(_rematch_btn)

	_back_btn = Button.new()
	_back_btn.text = tr("BTN_BACK")
	A11y.label(_back_btn, tr("BTN_BACK"), tr("A11Y_BACK_LOBBY"))
	A11y.make_focusable(_back_btn)
	_back_btn.pressed.connect(_back_to_lobby)
	buttons.add_child(_back_btn)

	return overlay

## Ready-countdown overlay: a short "get ready" beat shown at the start of every local round
## so everyone can get their hands on the controls before the sim steps. Reuses the same
## neutral dim scrim as the result/pause overlays (colour-by-meaning — no brand palette) and
## inherits the high-contrast theme + large type. Carries an accessibility label/description
## announcing the round is about to start; the big number counts down 3 · 2 · 1.
func _build_countdown_overlay(layer: CanvasLayer) -> Control:
	var overlay := ColorRect.new()
	overlay.color = Color(0.04, 0.07, 0.13, 0.9)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	A11y.label(overlay, tr("COUNTDOWN_READY"), tr("A11Y_COUNTDOWN"))
	layer.add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)

	var caption := Label.new()
	caption.text = tr("COUNTDOWN_READY")
	caption.add_theme_font_size_override("font_size", 32)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(caption)

	_countdown_label = Label.new()
	_countdown_label.add_theme_font_size_override("font_size", 72)
	_countdown_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_countdown_label)

	return overlay

## Leave-confirmation overlay: a focus-trapped pause menu (Resume / Leave) shown when the
## player presses back/escape during an in-progress match, so an accidental press cannot
## discard the running series score. Reuses the same dim scrim convention as the results
## overlay (colour-by-meaning, no new colours). In a LOCAL match opening this also freezes
## the board (see `_open_pause_overlay`); a NETWORKED match keeps running underneath so its
## deterministic lockstep clock cannot diverge across peers.
func _build_pause_overlay(layer: CanvasLayer) -> Control:
	var overlay := ColorRect.new()
	overlay.color = Color(0.04, 0.07, 0.13, 0.9)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	A11y.label(overlay, tr("PAUSE_TITLE"), tr("A11Y_PAUSE_OVERLAY"))
	layer.add_child(overlay)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 20)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	center.add_child(box)

	var title := Label.new()
	title.text = tr("PAUSE_TITLE")
	title.add_theme_font_size_override("font_size", 36)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	var body := Label.new()
	body.text = tr("PAUSE_BODY")
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(body)

	# Settings reachable mid-match: the SFX volume/mute control (persisted by `Audio`).
	box.add_child(SoundControl.build())

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)

	_resume_btn = Button.new()
	_resume_btn.text = tr("BTN_RESUME")
	A11y.label(_resume_btn, tr("BTN_RESUME"), tr("A11Y_RESUME"))
	A11y.make_focusable(_resume_btn)
	_resume_btn.pressed.connect(_resume_match)
	buttons.add_child(_resume_btn)

	_leave_btn = Button.new()
	_leave_btn.text = tr("BTN_LEAVE")
	A11y.label(_leave_btn, tr("BTN_LEAVE"), tr("A11Y_LEAVE"))
	A11y.make_focusable(_leave_btn)
	_leave_btn.pressed.connect(_back_to_lobby)
	buttons.add_child(_leave_btn)

	# Focus trap: keyboard/gamepad navigation cycles only between the two overlay buttons
	# while it is open, so focus can never wander to the obscured HUD behind the scrim.
	for pair in [[_resume_btn, _leave_btn], [_leave_btn, _resume_btn]]:
		var btn: Button = pair[0]
		var other: Button = pair[1]
		var other_path: NodePath = other.get_path()
		btn.focus_next = other_path
		btn.focus_previous = other_path
		btn.focus_neighbor_left = other_path
		btn.focus_neighbor_right = other_path
		btn.focus_neighbor_top = other_path
		btn.focus_neighbor_bottom = other_path

	return overlay

## Open the leave confirmation. In a LOCAL match this also pauses the board: `_pause_open`
## gates the PLAYING branch in `_process`, so the simulation stops stepping, no input is
## routed and the round/sudden-death timer is held until Resume — a single-device match has
## nothing else depending on the clock. A NETWORKED match deliberately keeps running
## underneath (its deterministic lockstep clock must never diverge across peers), so this
## flag has no effect on `_process_networked`.
func _open_pause_overlay() -> void:
	if _pause_open:
		return
	_pause_open = true
	_pause_overlay.visible = true
	_resume_btn.grab_focus()

## Dismiss the confirmation and return to play with the simulation and series state intact.
## Restores focus to whatever the match is showing now (the round/series overlay may have
## appeared while paused), and re-arms a pending round-over auto-advance so the overlay's
## precedence doesn't strand the round.
func _resume_match() -> void:
	if not _pause_open:
		return
	_pause_open = false
	_pause_overlay.visible = false
	match _phase:
		Phase.ROUND_OVER:
			# Local play re-arms its auto-advance (held while the confirmation was open). A
			# networked match advances on the host's clock regardless of this local overlay, so
			# nothing to re-arm; only restore focus to the affordance actually shown.
			if not _networked:
				_arm_auto_advance()
				_next_btn.grab_focus()
			elif _next_btn.visible and not _next_btn.disabled:
				_next_btn.grab_focus()
		Phase.SERIES_OVER:
			# Focus the strongest affordance present (Rematch when offered, else Back).
			if _rematch_btn.visible and not _rematch_btn.disabled:
				_rematch_btn.grab_focus()
			elif _back_btn.visible:
				_back_btn.grab_focus()

func _refresh_hud() -> void:
	if sim == null:
		return
	_round_label.text = tr("HUD_ROUND_OF").format([_series.current_round_number(), _series.best_of])
	_rebuild_score(_score_box)
	_update_time_label()
	_left_label.text = "%s %d" % [tr("HUD_PLAYERS_LEFT"), sim.living_players()]
	_refresh_readouts()

## Round countdown: shows time *remaining* (not elapsed) with three states — empty (no live
## sim), active (counting down) and expired (limit reached, drawn). The control always carries
## an accessible label/description (A11y) describing the current state.
func _update_time_label() -> void:
	if _time_label == null:
		return
	if sim == null:
		_time_label.text = ""
		_time_label.remove_theme_color_override("font_color")
		A11y.label(_time_label, tr("HUD_TIME"))
		return
	if sim.tick >= Spec.ROUND_LIMIT_TICKS:
		_time_label.text = tr("HUD_TIME_UP")
		_time_label.add_theme_color_override("font_color", TIME_UP_COLOR)
		A11y.label(_time_label, tr("HUD_TIME_UP"), tr("A11Y_TIME_UP"))
	else:
		_time_label.text = "%s %0.1f" % [tr("HUD_TIME_LEFT"), sim.remaining_seconds()]
		_time_label.remove_theme_color_override("font_color")
		A11y.label(_time_label, tr("HUD_TIME_LEFT"), tr("A11Y_TIME_LEFT"))

# --- Series flow ------------------------------------------------------------
func _on_round_over(winner_team: int) -> void:
	if _networked:
		_on_round_over_networked(winner_team)
		return
	# Record this round into the series (drawn rounds award no point but still count),
	# then either advance toward the next round or end the series.
	var round_winner := winner_team
	_series.record_round(winner_team)
	_rebuild_score(_overlay_score_box)
	if _series.finished:
		_enter_series_over()
	else:
		_enter_round_over(round_winner)

## Networked round end: record the result into the series (deterministic — the winning team is
## identical on every peer), show the running score, then either end the series or wait for the
## host-driven auto-advance into the next round. The series score/round counter are computed the
## same on every peer, so no agreement is needed beyond the host's transition trigger.
func _on_round_over_networked(winner_team: int) -> void:
	_series.record_round(winner_team)
	_rebuild_score(_overlay_score_box)
	# The relay hub being gone ends the series gracefully once the in-flight round resolves.
	if _series.finished or _host_lost:
		_enter_series_over_networked()
		return
	_enter_round_over_networked(winner_team)
	# An ADVANCE may have arrived before our own round_over under extreme skew; apply it now.
	if not _pending_advance.is_empty():
		var a := _pending_advance
		_pending_advance = {}
		_apply_advance(int(a["net_round"]), bool(a["reset"]), a["dropped"])
	elif _session.is_server:
		_arm_net_auto_advance()

## Mid-series networked round-over: show the outcome + running score. The host can skip the
## pause with Next; on every peer the transition is automatic (disabled-during-transition),
## driven by the host's ADVANCE off the shared next-round seed.
func _enter_round_over_networked(winner_team: int) -> void:
	_phase = Phase.ROUND_OVER
	_result_label.text = _round_result_text(winner_team)
	var host := _session.is_server
	_set_overlay_buttons(host, false, false)   # only the host gets a manual "next round"
	_loading_label.visible = false
	_result_overlay.visible = true
	if host and not _pause_open:
		_next_btn.grab_focus()

## Host-only: after a short pause, broadcast ADVANCE and step every peer into the next round.
## Not gated on the leave confirmation: a networked match keeps its lockstep clock running under
## the (local) pause overlay, so the series must advance regardless.
func _arm_net_auto_advance() -> void:
	var t := get_tree().create_timer(AUTO_ADVANCE_SECONDS)
	t.timeout.connect(func():
		if _networked and _phase == Phase.ROUND_OVER and _session.is_server:
			_host_advance(false))

## Networked series end: show the winner + final score with Rematch + Back to lobby (the screen
## is no longer Back-only). When the host's relay is gone, only Back is offered — no host to
## coordinate a rematch.
func _enter_series_over_networked() -> void:
	_phase = Phase.SERIES_OVER
	_result_label.text = _series_result_text()
	var can_rematch := not _host_lost
	_set_overlay_buttons(false, can_rematch, true)
	_loading_label.visible = false
	_result_overlay.visible = true
	# A networked match is a single round, so its result is the series result.
	Audio.play("series_win")
	if not _pause_open:
		if can_rematch:
			_rematch_btn.grab_focus()
		else:
			_back_btn.grab_focus()

## Host: trigger the next round (or a rematch when `reset`). Broadcasts the shared monotonic
## round tag + the authoritative dropped set so every peer rebuilds the identical round, then
## applies it locally off that same frozen snapshot.
func _host_advance(reset: bool) -> void:
	if not _networked or not _session.is_server:
		return
	var next_tag := _net_round + 1
	var frozen := _dropped_ids.duplicate()
	_session.broadcast_advance(next_tag, reset, frozen)
	_apply_advance(next_tag, reset, frozen)

## Client: the host told us to advance. Step into the next round off the host's FROZEN dropped
## set (so a peer that left becomes a bot on every peer at the same round); a peer that drops
## locally after this point is carried by a later ADVANCE, not this round's build.
func _on_advance_received(net_round: int, reset: bool, dropped: Array) -> void:
	# Defensive: if our own round hasn't resolved yet (extreme skew), hold the advance until it
	# does so we don't tear down a round mid-flight.
	if _phase == Phase.PLAYING:
		_pending_advance = {"net_round": net_round, "reset": reset, "dropped": dropped.duplicate()}
		return
	_apply_advance(net_round, reset, dropped.duplicate())

## Host: a client asked for a rematch from the series-over screen. Honour it once.
func _on_rematch_requested() -> void:
	if _networked and _session.is_server and _phase == Phase.SERIES_OVER and not _host_lost:
		_host_advance(true)

## Shared by host + clients: reset the score for a rematch, then run the loading beat into the
## next networked round under the given shared round tag + frozen dropped set.
func _apply_advance(net_round: int, reset: bool, dropped_for_round: Array) -> void:
	if reset:
		_series.reset()
	_begin_next_round_networked(net_round, dropped_for_round)

## Networked loading beat: disable actions, show the loading message, then build the next round
## (same roster, shared next-round seed) under the host-supplied round tag + frozen dropped set.
func _begin_next_round_networked(net_round: int, dropped_for_round: Array) -> void:
	if _phase == Phase.LOADING:
		return
	_phase = Phase.LOADING
	_loading_label.visible = true
	_set_overlay_buttons(false, false, false)
	var t := get_tree().create_timer(LOADING_SECONDS)
	t.timeout.connect(func():
		if _phase == Phase.LOADING:
			_start_round_networked(net_round, dropped_for_round))

## Mid-series: a round ended but the match continues. Show the round outcome + running
## score with a "next round" affordance, and auto-advance after a short pause.
func _enter_round_over(winner_team: int) -> void:
	_phase = Phase.ROUND_OVER
	_result_label.text = _round_result_text(winner_team)
	_set_overlay_buttons(true, false, false)
	_loading_label.visible = false
	_result_overlay.visible = true
	Audio.play("round_win")
	if not _pause_open:
		_next_btn.grab_focus()
	_arm_auto_advance()

## Arm the mid-series auto-advance. The leave confirmation takes precedence: if it is open
## when the timer fires the round is held (re-armed on Resume) rather than advancing behind
## the overlay.
func _arm_auto_advance() -> void:
	var t := get_tree().create_timer(AUTO_ADVANCE_SECONDS)
	t.timeout.connect(func():
		if _phase == Phase.ROUND_OVER and not _pause_open:
			_begin_next_round())

## Final results: a team clinched (or the schedule is exhausted). Show the series winner
## with Rematch + Back to lobby.
func _enter_series_over() -> void:
	_phase = Phase.SERIES_OVER
	_result_label.text = _series_result_text()
	_set_overlay_buttons(false, true, true)
	_loading_label.visible = false
	_result_overlay.visible = true
	Audio.play("series_win")
	if not _pause_open:
		_rematch_btn.grab_focus()

func _on_next_round_pressed() -> void:
	if _phase != Phase.ROUND_OVER:
		return
	if _networked:
		# Host-only manual skip of the auto-advance pause.
		if _session.is_server:
			_host_advance(false)
	else:
		_begin_next_round()

## Loading beat between rounds: disable actions, show a loading message, then rebuild the
## simulation for the next round (same roster, fresh seed).
func _begin_next_round() -> void:
	if _phase == Phase.LOADING:
		return
	_phase = Phase.LOADING
	_loading_label.visible = true
	_set_overlay_buttons(false, false, false)
	var t := get_tree().create_timer(LOADING_SECONDS)
	t.timeout.connect(func():
		if _phase == Phase.LOADING:
			_start_round())

func _on_rematch_pressed() -> void:
	if _networked:
		# Rematch is host-authoritative so every peer resets and restarts deterministically.
		if _session.is_server:
			_host_advance(true)
		else:
			# Ask the host to start the rematch; disable our button so it can't double-fire.
			_session.request_rematch()
			_rematch_btn.disabled = true
		return
	_series.reset()
	_begin_next_round()

func _back_to_lobby() -> void:
	# Discard the in-progress series so a fresh Start rebuilds it cleanly.
	MatchConfig.series = null
	if _networked:
		NetContext.clear()
		_networked = false
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

func _exit_tree() -> void:
	# Safety net: tear the networked session down if we leave without the explicit back path.
	if _networked:
		NetContext.clear()
		_networked = false

## Toggle which overlay actions are available; everything is disabled during transitions.
func _set_overlay_buttons(next: bool, rematch: bool, back: bool) -> void:
	_next_btn.visible = next
	_next_btn.disabled = not next
	_rematch_btn.visible = rematch
	_rematch_btn.disabled = not rematch
	_back_btn.visible = back
	_back_btn.disabled = not back

func _round_result_text(winner_team: int) -> String:
	if winner_team < 0:
		return tr("RESULT_DRAW")
	# Name the surviving player if exactly one remains on the winning team, else the team.
	var survivor: PlayerState = null
	var same_team := 0
	for p in sim.players:
		if p.alive and p.team == winner_team:
			survivor = p
			same_team += 1
	if same_team == 1 and survivor != null:
		return tr("RESULT_WINNER").format([survivor.display_name])
	return tr("RESULT_TEAM_WINNER").format([winner_team + 1])

func _series_result_text() -> String:
	var team_id := _series.series_winner_team
	if team_id < 0:
		return tr("RESULT_SERIES_DRAW")
	# Name the player if the winning team is a single roster member, else the team.
	var members: Array = []
	for def in _series.roster:
		if int(def.get("team", 0)) == team_id:
			members.append(def)
	if members.size() == 1:
		var nm: String = String(members[0].get("name", "")).strip_edges()
		if nm.is_empty():
			nm = tr("SLOT_PLAYER_NAME")
		return tr("RESULT_SERIES_WINNER").format([nm])
	return tr("RESULT_SERIES_TEAM_WINNER").format([team_id + 1])
