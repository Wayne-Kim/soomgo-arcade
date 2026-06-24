extends Control
## Connect / pairing + ROOM screen (acceptance criterion 1 & 3).
##
## Two phases share this screen:
##   1. Discovery — host a named room or scan the local network and join one (drives the
##      deterministic ConnectionFlow; renders scanning / empty / loading / error / fallback).
##   2. Room — once hosting or welcomed, everyone sits in a shared room: pick a character, ready
##      up, the host kicks unwanted players and starts only when everyone is ready. Room state is
##      host-authoritative (NetSession.lobby_players, synced over ROOM_STATE), so the player list,
##      characters and ready flags are identical on every device.
##
## All strings come from tr(). Networking transport is ENet (LanBeacon + NetSession);
## Bluetooth/hotspot are surfaced as pairing/fallback guidance only — never as a data path.

const SCAN_TIMEOUT_SEC: float = 6.0
const BEACON_POLL_SEC: float = 0.5

## Selectable match lengths (best-of-N rounds), mirroring the local Lobby's picker so the
## host chooses the online series length the same way. Committed to NetSession.match_best_of
## and broadcast in START.
const LENGTH_OPTIONS: Array = [1, 3, 5]

var _flow: ConnectionFlow
var _beacon: LanBeacon
var _session: NetSession

# --- Discovery view nodes ---
var _status_label: Label
var _lobby_view: VBoxContainer
var _room_name_edit: LineEdit
var _host_btn: Button
var _scan_btn: Button
var _results_box: VBoxContainer
var _empty_label: Label
var _error_label: Label
var _fallback_panel: Control
var _fallback_label: Label
var _fallback_ready_btn: Button
var _loading_overlay: Control
var _loading_label: Label
var _back_btn: Button

# --- Room view nodes ---
var _room_view: VBoxContainer
var _room_title_label: Label
var _room_players_box: VBoxContainer
var _char_picker: OptionButton
var _ready_btn: Button
var _start_btn: Button
var _start_hint_label: Label
var _quality_label: Label
var _length_section: Control
var _length_buttons: Array = []   # one toggle Button per LENGTH_OPTIONS entry
var _map_section: Control          # host-only map picker
var _map_buttons: Array = []      # one toggle Button per Maps entry
var _room_map_label: Label        # shows the chosen map (so clients see the host's pick)

var _scan_elapsed: float = 0.0
var _poll_elapsed: float = 0.0
var _beacon_elapsed: float = 0.0
var _connected_count: int = 1     # host counts itself; updated as peers join/leave
var _starting: bool = false       # true between pressing Start and the scene change
## True once this device is sitting in a room (hosting, or welcomed as a client).
var _in_room: bool = false
## Set when the host kicks us, so the follow-up server disconnect is not reported as an error.
var _kicked: bool = false
## Host-chosen series length; defaults until the host picks another.
var _best_of: int = Spec.SERIES_BEST_OF_DEFAULT
## Host-chosen arena layout (Maps id); defaults until the host picks another.
var _map_id: String = Maps.default_id()

func _ready() -> void:
	_flow = ConnectionFlow.new()
	_build_ui()
	_render()
	_host_btn.grab_focus()

# --- UI construction -------------------------------------------------------
func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := Panel.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 32)
	add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 14)
	margin.add_child(root)

	var title := Label.new()
	title.text = tr("CONNECT_TITLE")
	title.add_theme_font_size_override("font_size", 34)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = tr("CONNECT_SUBTITLE")
	subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle.modulate = Color(0.78, 0.85, 0.95)
	root.add_child(subtitle)

	# Shared status line (scanning hint, or in-room "waiting for players").
	_status_label = Label.new()
	root.add_child(_status_label)

	_lobby_view = _build_lobby_view()
	root.add_child(_lobby_view)

	_room_view = _build_room_view()
	root.add_child(_room_view)

	_back_btn = Button.new()
	_back_btn.text = tr("CONNECT_BACK")
	A11y.label(_back_btn, tr("CONNECT_BACK"))
	A11y.make_focusable(_back_btn)
	_back_btn.pressed.connect(_on_back)
	root.add_child(_back_btn)

	_loading_overlay = _build_loading_overlay()
	add_child(_loading_overlay)

## The discovery view: name + host a room, scan for rooms, and the results / fallback guidance.
func _build_lobby_view() -> VBoxContainer:
	var view := VBoxContainer.new()
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_theme_constant_override("separation", 12)

	# Room name (used when hosting). A blank name falls back to the device name.
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 10)
	var name_caption := Label.new()
	name_caption.text = "%s:" % tr("CONNECT_ROOM_NAME")
	name_row.add_child(name_caption)
	_room_name_edit = LineEdit.new()
	_room_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_name_edit.placeholder_text = tr("CONNECT_ROOM_NAME_HINT")
	A11y.label(_room_name_edit, tr("CONNECT_ROOM_NAME"), tr("A11Y_ROOM_NAME"))
	A11y.make_focusable(_room_name_edit)
	name_row.add_child(_room_name_edit)
	view.add_child(name_row)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	view.add_child(actions)

	_host_btn = Button.new()
	_host_btn.text = tr("CONNECT_HOST")
	A11y.label(_host_btn, tr("CONNECT_HOST"), tr("A11Y_CONNECT_HOST"))
	A11y.make_focusable(_host_btn)
	_host_btn.pressed.connect(_on_host)
	actions.add_child(_host_btn)

	_scan_btn = Button.new()
	_scan_btn.text = tr("CONNECT_SCAN")
	A11y.label(_scan_btn, tr("CONNECT_SCAN"), tr("A11Y_CONNECT_SCAN"))
	A11y.make_focusable(_scan_btn)
	_scan_btn.pressed.connect(_on_scan)
	actions.add_child(_scan_btn)

	var content := PanelContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_child(content)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 8)
	scroll.add_child(inner)

	_empty_label = Label.new()
	_empty_label.text = tr("CONNECT_EMPTY")
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.modulate = Color(0.74, 0.81, 0.92)
	inner.add_child(_empty_label)

	_results_box = VBoxContainer.new()
	_results_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_results_box.add_theme_constant_override("separation", 8)
	inner.add_child(_results_box)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(0.898, 0.282, 0.302))
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_label.visible = false
	view.add_child(_error_label)

	_fallback_panel = _build_fallback_panel()
	view.add_child(_fallback_panel)
	return view

## The room view: title, the live player list, this device's character picker, a ready toggle
## (clients) or the match-length picker + Start (host), and a connection-quality readout.
func _build_room_view() -> VBoxContainer:
	var view := VBoxContainer.new()
	view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_theme_constant_override("separation", 12)
	view.visible = false

	_room_title_label = Label.new()
	_room_title_label.add_theme_font_size_override("font_size", 26)
	view.add_child(_room_title_label)

	var players_caption := Label.new()
	players_caption.text = tr("ROOM_PLAYERS")
	players_caption.modulate = Color(0.78, 0.85, 0.95)
	view.add_child(players_caption)

	var players_panel := PanelContainer.new()
	players_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	view.add_child(players_panel)
	var players_scroll := ScrollContainer.new()
	players_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	players_panel.add_child(players_scroll)
	_room_players_box = VBoxContainer.new()
	_room_players_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_room_players_box.add_theme_constant_override("separation", 6)
	players_scroll.add_child(_room_players_box)

	# This device's character pick.
	var char_row := HBoxContainer.new()
	char_row.add_theme_constant_override("separation", 10)
	var char_caption := Label.new()
	char_caption.text = "%s:" % tr("SLOT_CHARACTER")
	char_row.add_child(char_caption)
	_char_picker = OptionButton.new()
	for ci in Characters.count():
		var cdef: Dictionary = Characters.all()[ci]
		_char_picker.add_item("%s · %s" % [tr(cdef["name_key"]), tr(cdef["motif_key"])], ci)
	A11y.label(_char_picker, tr("SLOT_CHARACTER"), tr("A11Y_ROOM_CHARACTER"))
	A11y.make_focusable(_char_picker)
	_char_picker.item_selected.connect(_on_char_selected)
	char_row.add_child(_char_picker)
	view.add_child(char_row)

	# Client-only ready toggle.
	_ready_btn = Button.new()
	_ready_btn.toggle_mode = true
	_ready_btn.text = tr("ROOM_READY")
	A11y.label(_ready_btn, tr("ROOM_READY"), tr("A11Y_ROOM_READY"))
	A11y.make_focusable(_ready_btn)
	_ready_btn.toggled.connect(_on_ready_toggled)
	view.add_child(_ready_btn)

	# Host-only match-length picker + Start.
	_length_section = _build_match_length_section()
	view.add_child(_length_section)

	# Host-only map picker, plus a label everyone sees showing the chosen map.
	_map_section = _build_room_map_section()
	view.add_child(_map_section)
	_room_map_label = Label.new()
	_room_map_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_room_map_label.modulate = Color(0.82, 0.88, 0.97)
	view.add_child(_room_map_label)

	_start_btn = Button.new()
	_start_btn.text = tr("CONNECT_START")
	A11y.label(_start_btn, tr("CONNECT_START"), tr("A11Y_CONNECT_START"))
	A11y.make_focusable(_start_btn)
	_start_btn.pressed.connect(_on_start_match)
	view.add_child(_start_btn)

	_start_hint_label = Label.new()
	_start_hint_label.text = tr("ROOM_START_HINT")
	_start_hint_label.modulate = Color(0.82, 0.78, 0.6)
	_start_hint_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	view.add_child(_start_hint_label)

	_quality_label = Label.new()
	A11y.label(_quality_label, tr("A11Y_CONNECT_QUALITY"))
	view.add_child(_quality_label)
	return view

## Host-only match-length picker (best-of-N): a segmented group of toggle buttons, exactly one
## pressed. The chosen value is committed to NetSession.match_best_of and broadcast to peers.
func _build_match_length_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var heading := Label.new()
	heading.text = tr("LOBBY_MATCH_LENGTH")
	box.add_child(heading)

	var group := ButtonGroup.new()
	var segment := HBoxContainer.new()
	segment.add_theme_constant_override("separation", 8)
	A11y.label(segment, tr("LOBBY_MATCH_LENGTH"), tr("A11Y_MATCH_LENGTH"))
	box.add_child(segment)

	_length_buttons.clear()
	for n in LENGTH_OPTIONS:
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = group
		btn.text = tr("LOBBY_ROUNDS_VALUE").format([n])
		btn.button_pressed = (n == _best_of)
		A11y.label(btn, tr("LOBBY_ROUNDS_VALUE").format([n]),
			tr("A11Y_MATCH_LENGTH_OPTION").format([n]))
		A11y.make_focusable(btn)
		btn.pressed.connect(_on_match_length_selected.bind(n))
		segment.add_child(btn)
		_length_buttons.append(btn)
	return box

## Record the chosen series length and (if hosting) sync it to every peer via ROOM_STATE.
func _on_match_length_selected(value: int) -> void:
	_best_of = maxi(1, value)
	if _session != null and _session.is_server:
		_session.match_best_of = _best_of
		_session.broadcast_room_state()

## Host-only arena (map) picker for the room: one toggle button per Maps entry, exactly one
## pressed. The chosen id is committed to NetSession.match_map_id, broadcast to every peer in
## ROOM_STATE (so clients see it) and sent in START so every peer builds the same arena.
func _build_room_map_section() -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)

	var heading := Label.new()
	heading.text = tr("LOBBY_MAP")
	box.add_child(heading)

	var group := ButtonGroup.new()
	var segment := HBoxContainer.new()
	segment.add_theme_constant_override("separation", 8)
	A11y.label(segment, tr("LOBBY_MAP"), tr("A11Y_MAP_SELECT"))
	box.add_child(segment)

	_map_buttons.clear()
	for m in Maps.all():
		var mid: String = m["id"]
		var btn := Button.new()
		btn.toggle_mode = true
		btn.button_group = group
		btn.text = tr(m["name_key"])
		btn.button_pressed = (mid == _map_id)
		A11y.label(btn, tr(m["name_key"]), tr(m["desc_key"]))
		A11y.make_focusable(btn)
		btn.pressed.connect(_on_room_map_selected.bind(mid))
		segment.add_child(btn)
		_map_buttons.append(btn)
	return box

## Record the chosen map and (hosting) sync it to every peer via ROOM_STATE.
func _on_room_map_selected(map_id: String) -> void:
	_map_id = Maps.sanitize(map_id)
	if _session != null and _session.is_server:
		_session.match_map_id = _map_id
		_session.broadcast_room_state()

func _build_fallback_panel() -> Control:
	var panel := PanelContainer.new()
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)

	var heading := Label.new()
	heading.text = tr("CONNECT_FALLBACK_TITLE")
	heading.add_theme_font_size_override("font_size", 22)
	box.add_child(heading)

	_fallback_label = Label.new()
	_fallback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_fallback_label)

	_fallback_ready_btn = Button.new()
	_fallback_ready_btn.text = tr("CONNECT_FALLBACK_READY")
	A11y.label(_fallback_ready_btn, tr("CONNECT_FALLBACK_READY"), tr("A11Y_CONNECT_FALLBACK_READY"))
	A11y.make_focusable(_fallback_ready_btn)
	_fallback_ready_btn.pressed.connect(_on_fallback_ready)
	box.add_child(_fallback_ready_btn)

	panel.visible = false
	return panel

func _build_loading_overlay() -> Control:
	var overlay := ColorRect.new()
	overlay.color = Color(0.04, 0.07, 0.13, 0.85)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	_loading_label = Label.new()
	_loading_label.text = tr("CONNECT_CONNECTING")
	_loading_label.add_theme_font_size_override("font_size", 28)
	center.add_child(_loading_label)
	return overlay

# --- Actions ---------------------------------------------------------------
func _on_host() -> void:
	var room := _room_name_edit.text.strip_edges() if _room_name_edit != null else ""
	_session = NetSession.new()
	var err := _session.host(NetBudget.DEFAULT_PORT, _device_name(), 0, room)
	if err != OK:
		_flow.state = ConnectionFlow.State.ERROR
		_flow.error_key = "NET_ERR_HOST_FAILED"
		_session = null
		_render()
		return
	_session.peer_joined.connect(_on_peer_joined)
	_session.peer_left.connect(_on_peer_left)
	_session.match_started.connect(_on_match_started)
	_session.room_updated.connect(_on_room_updated)
	_beacon = LanBeacon.new()
	# Advertise the ROOM NAME (not the device name) so the discovery list shows it.
	_beacon.start_advertising(NetBudget.DEFAULT_PORT, _session.room_name, 1)
	_connected_count = 1
	_flow.state = ConnectionFlow.State.CONNECTED  # host is "connected" to itself; waits for joins
	_enter_room()

func _on_scan() -> void:
	_scan_elapsed = 0.0
	_poll_elapsed = 0.0
	_beacon = LanBeacon.new()
	_beacon.start_listening()
	_session = NetSession.new()
	_flow.begin_scan()
	_render()

func _on_join(host: Dictionary) -> void:
	_flow.target = host
	_flow.state = ConnectionFlow.State.CONNECTING
	if _session == null:
		_session = NetSession.new()
	_session.connected_ok.connect(func(): _flow.on_enet_connected(); _render(), CONNECT_ONE_SHOT)
	_session.connection_failed.connect(func(): _flow.on_enet_failed(); _render(), CONNECT_ONE_SHOT)
	_session.match_started.connect(_on_match_started)
	_session.welcomed.connect(_on_welcomed)
	_session.room_updated.connect(_on_room_updated)
	_session.kicked.connect(_on_kicked)
	_session.disconnected.connect(_on_host_gone)
	var err := _session.join(host.get("address", "127.0.0.1"), host.get("port", NetBudget.DEFAULT_PORT), _device_name())
	if err != OK:
		_flow.on_enet_failed()
	_render()

func _on_fallback_ready() -> void:
	_flow.on_fallback_network_ready()
	_on_scan()

# --- Room ------------------------------------------------------------------
## Enter the room view (hosting, or welcomed as a client) and wire up which controls are shown:
## the host gets the match-length picker + Start; a client gets the Ready toggle.
func _enter_room() -> void:
	_in_room = true
	var is_host := _session != null and _session.is_server
	_start_btn.visible = is_host
	_length_section.visible = is_host
	_start_hint_label.visible = is_host
	_ready_btn.visible = not is_host
	# Host picks the map; clients see the host's choice on the label below.
	_map_section.visible = is_host
	_room_map_label.visible = not is_host
	# Seed the character picker from this device's current room slot.
	var mine := _my_slot()
	if not mine.is_empty():
		var idx := Characters.ids().find(String(mine.get("character", "")))
		if idx >= 0:
			_char_picker.select(idx)
	_render()

## This device's row in the authoritative room snapshot, or {} before the first ROOM_STATE.
func _my_slot() -> Dictionary:
	if _session == null:
		return {}
	for p in _session.lobby_players:
		if int(p.get("id", -1)) == _session.local_player_id:
			return p
	return {}

func _on_welcomed(_player_id: int, _seed_value: int, _player_count: int) -> void:
	_enter_room()

func _on_room_updated() -> void:
	if _in_room:
		_render()

func _on_char_selected(index: int) -> void:
	if _session == null:
		return
	var ids := Characters.ids()
	if index >= 0 and index < ids.size():
		_session.set_my_character(ids[index])

func _on_ready_toggled(pressed: bool) -> void:
	if _session != null and not _session.is_server:
		_session.set_my_ready(pressed)

func _on_kick_pressed(player_id: int) -> void:
	if _session != null and _session.is_server:
		_session.kick_player(player_id)

## A client was removed by the host: leave the room and explain why (the follow-up server
## disconnect is then expected, not an error).
func _on_kicked() -> void:
	_kicked = true
	_teardown()
	_in_room = false
	_flow.state = ConnectionFlow.State.ERROR
	_flow.error_key = "NET_NOTICE_KICKED"
	_flow.fallback = ConnectionFlow.Fallback.NONE
	_render()

## The host's session went away while we were in the room (not a kick): leave gracefully.
func _on_host_gone() -> void:
	if _kicked or not _in_room:
		return
	_teardown()
	_in_room = false
	_flow.state = ConnectionFlow.State.ERROR
	_flow.error_key = "NET_NOTICE_HOST_LEFT"
	_flow.fallback = ConnectionFlow.Fallback.NONE
	_render()

## Rebuild the player list and refresh the room's interactive state from the authoritative
## snapshot (NetSession.lobby_players): character picks, ready flags, host-only Start gating.
func _refresh_room() -> void:
	if not _in_room or _session == null:
		return
	_room_title_label.text = "%s · %s" % [tr("ROOM_HEADING"), _session.room_name]
	_rebuild_room_players()
	# Keep the picker in sync with the authoritative pick for this device.
	var mine := _my_slot()
	if not mine.is_empty():
		var idx := Characters.ids().find(String(mine.get("character", "")))
		if idx >= 0 and _char_picker.selected != idx:
			_char_picker.select(idx)
	# Show the chosen map to everyone (clients especially, who have no picker).
	var map_def := Maps.get_def(_session.match_map_id)
	if not map_def.is_empty():
		_room_map_label.text = "%s: %s — %s" % [tr("LOBBY_MAP"), tr(map_def["name_key"]), tr(map_def["desc_key"])]
	if _session.is_server:
		var ready_to_start := _session.all_ready()
		_start_btn.disabled = _starting or not ready_to_start
		_start_hint_label.visible = not ready_to_start
	_quality_label.visible = _session.last_rtt_ms >= 0.0
	if _quality_label.visible:
		_quality_label.text = _quality_text(_session.last_rtt_ms)

## One row per player: name (+ "(You)"), chosen character, a Host/Ready/Not-ready status, and —
## for the host, beside every other player — a Kick button.
func _rebuild_room_players() -> void:
	# Detach immediately (not just queue_free, which is deferred) so the row count reflects the
	# current snapshot the same frame — no transient duplicate rows while a peer churns.
	for child in _room_players_box.get_children():
		_room_players_box.remove_child(child)
		child.queue_free()
	var am_host := _session.is_server
	for p in _session.lobby_players:
		var pid := int(p.get("id", 0))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 12)
		A11y.label(row, tr("A11Y_ROOM_PLAYER").format([pid + 1]))

		var name_label := Label.new()
		var nm := String(p.get("name", "P%d" % (pid + 1)))
		if pid == _session.local_player_id:
			nm += " " + tr("ROOM_YOU")
		name_label.text = nm
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var char_label := Label.new()
		var cdef := Characters.get_def(String(p.get("character", "")))
		char_label.text = tr(cdef["name_key"]) if not cdef.is_empty() else tr("SLOT_CHARACTER_EMPTY")
		char_label.modulate = Color(0.82, 0.88, 0.97)
		row.add_child(char_label)

		var status := Label.new()
		if bool(p.get("host", false)):
			status.text = tr("ROOM_STATUS_HOST")
			status.modulate = Color(0.98, 0.86, 0.55)
		elif bool(p.get("ready", false)):
			status.text = tr("ROOM_STATUS_READY")
			status.modulate = Color(0.46, 0.93, 0.55)
		else:
			status.text = tr("ROOM_STATUS_WAITING")
			status.modulate = Color(0.85, 0.55, 0.55)
		row.add_child(status)

		if am_host and pid != 0:
			var kick := Button.new()
			kick.text = tr("ROOM_KICK")
			A11y.label(kick, tr("ROOM_KICK"), tr("A11Y_ROOM_KICK").format([nm]))
			A11y.make_focusable(kick)
			kick.pressed.connect(_on_kick_pressed.bind(pid))
			row.add_child(kick)
		_room_players_box.add_child(row)

# --- Match start -----------------------------------------------------------
func _on_peer_joined(_peer_id: int, player_count: int) -> void:
	_connected_count = player_count
	if _beacon != null:
		_beacon.update_player_count(player_count)
	_render()

func _on_peer_left(_peer_id: int) -> void:
	_connected_count = _session.human_count() if _session != null else 1
	if _beacon != null:
		_beacon.update_player_count(_connected_count)
	_render()

## Host pressed Start. Requires at least one joined peer AND every non-host player ready
## (NetSession.all_ready); otherwise the press is a no-op and the hint stays up.
func _on_start_match() -> void:
	if _session == null or not _session.is_server or _starting:
		return
	if not _session.all_ready():
		_render()
		return
	_starting = true
	_render()
	_session.match_best_of = _best_of
	_session.match_map_id = _map_id
	_session.start_match()   # broadcasts START + emits match_started -> _on_match_started

## Fired on the host (when it starts) and on every client (when START arrives). Hands the
## live session off to the Game scene without tearing it down.
func _on_match_started(seed_value: int, roster: Array, local_player_id: int, best_of: int) -> void:
	MatchConfig.player_defs = roster
	MatchConfig.match_seed = seed_value
	MatchConfig.best_of = maxi(1, best_of)
	MatchConfig.map_id = Maps.sanitize(_session.match_map_id)
	NetContext.arm(_session, local_player_id)
	if _beacon != null:
		_beacon.stop()
		_beacon = null
	_session = null   # ownership transferred to NetContext; keep _teardown from closing it
	get_tree().change_scene_to_file("res://scenes/Game.tscn")

func _on_back() -> void:
	_teardown()
	get_tree().change_scene_to_file("res://scenes/Lobby.tscn")

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_back"):
		_on_back()

# --- Frame loop ------------------------------------------------------------
func _process(delta: float) -> void:
	if _session != null:
		_session.poll()
	# Host: periodically advertise the ENet endpoint so clients on the same network can
	# discover and join (the data channel is ENet; this UDP beacon is discovery only).
	if _flow.state == ConnectionFlow.State.CONNECTED and _session != null and _session.is_server and _beacon != null:
		_beacon_elapsed += delta
		if _beacon_elapsed >= BEACON_POLL_SEC:
			_beacon_elapsed = 0.0
			_beacon.broadcast_once()
	if _flow.state == ConnectionFlow.State.SCANNING:
		_poll_elapsed += delta
		if _poll_elapsed >= BEACON_POLL_SEC and _beacon != null:
			_poll_elapsed = 0.0
			var found := _beacon.poll()
			if not found.is_empty():
				_flow.on_hosts_discovered(found)
				if _flow.state == ConnectionFlow.State.CONNECTING:
					_on_join(_flow.target)
				_render()
		_scan_elapsed += delta
		if _scan_elapsed >= SCAN_TIMEOUT_SEC:
			_flow.on_scan_timeout()
			_render()

# --- Rendering -------------------------------------------------------------
func _render() -> void:
	if _in_room:
		_render_room()
	else:
		_render_lobby()

## Room view: hide discovery, show the live room, keep the "starting" overlay + busy-disable.
func _render_room() -> void:
	_lobby_view.visible = false
	_room_view.visible = true
	_status_label.text = _status_text(_flow.state)
	_refresh_room()
	_loading_overlay.visible = _starting
	if _starting:
		_loading_label.text = tr("CONNECT_STARTING")
	# Discovery actions are hidden in the room, but keep them disabled so any stray focus is inert.
	_host_btn.disabled = true
	_scan_btn.disabled = true

## Discovery view: the original scanning / empty / connecting / error / fallback rendering.
func _render_lobby() -> void:
	var s := _flow.state
	_lobby_view.visible = true
	_room_view.visible = false
	_status_label.text = _status_text(s)

	_rebuild_results()
	var scanning := s == ConnectionFlow.State.SCANNING
	_empty_label.visible = scanning and _flow.hosts.is_empty()
	_results_box.visible = not _flow.hosts.is_empty()

	var connecting := s == ConnectionFlow.State.CONNECTING
	_loading_overlay.visible = connecting or _starting
	if _starting:
		_loading_label.text = tr("CONNECT_STARTING")
	elif connecting:
		_loading_label.text = tr("CONNECT_CONNECTING")

	_error_label.visible = s == ConnectionFlow.State.ERROR
	if s == ConnectionFlow.State.ERROR:
		_error_label.text = tr(_flow.error_key if _flow.error_key != "" else "NET_ERR_CONNECT_FAILED")

	var show_fallback := s == ConnectionFlow.State.FALLBACK or s == ConnectionFlow.State.ERROR
	_fallback_panel.visible = show_fallback
	if show_fallback:
		_fallback_label.text = _fallback_text()

	var busy := _flow.is_busy() or _starting
	_host_btn.disabled = busy
	_scan_btn.disabled = busy

func _rebuild_results() -> void:
	for child in _results_box.get_children():
		child.queue_free()
	for host in _flow.hosts:
		var hname: String = host.get("name", "?")
		var count: int = host.get("player_count", 0)
		var item := Button.new()
		item.text = tr("CONNECT_FOUND_ONE").format([hname, count])
		A11y.label(item, item.text, tr("A11Y_CONNECT_GAME_ITEM").format([hname, count]))
		A11y.make_focusable(item)
		item.pressed.connect(_on_join.bind(host))
		_results_box.add_child(item)

func _status_text(s: int) -> String:
	if _in_room and _session != null:
		if _session.is_server:
			if _connected_count < 2:
				return tr("CONNECT_NEED_PEERS")
			if not _session.all_ready():
				return tr("ROOM_WAIT_READY")
			return tr("CONNECT_PLAYERS_JOINED").format([_connected_count])
		return tr("CONNECT_WAIT_FOR_HOST")
	match s:
		ConnectionFlow.State.SCANNING:
			return tr("CONNECT_SCANNING")
		ConnectionFlow.State.CONNECTING:
			return tr("CONNECT_CONNECTING")
		ConnectionFlow.State.CONNECTED:
			if _session != null and _session.is_server:
				if _connected_count < 2:
					return tr("CONNECT_NEED_PEERS")
				return tr("CONNECT_PLAYERS_JOINED").format([_connected_count])
			return tr("CONNECT_WAIT_FOR_HOST")
		ConnectionFlow.State.FALLBACK:
			return tr("CONNECT_EMPTY")
		_:
			return ""

func _fallback_text() -> String:
	match _flow.fallback:
		ConnectionFlow.Fallback.BLUETOOTH:
			return tr("CONNECT_FALLBACK_BLUETOOTH")
		_:
			return tr("CONNECT_FALLBACK_HOTSPOT")

func _quality_text(rtt_ms: float) -> String:
	var key := "NET_QUALITY_GOOD"
	match NetBudget.classify(rtt_ms):
		NetBudget.Quality.WARN:
			key = "NET_QUALITY_WARN"
		NetBudget.Quality.OVER:
			key = "NET_QUALITY_OVER"
	return "%s   %s" % [tr(key), tr("NET_RTT").format([int(round(rtt_ms))])]

func _device_name() -> String:
	var n := OS.get_environment("USER")
	return n if n != "" else "Player"

func _teardown() -> void:
	if _beacon != null:
		_beacon.stop()
		_beacon = null
	if _session != null:
		_session.close()
		_session = null

func _exit_tree() -> void:
	_teardown()
