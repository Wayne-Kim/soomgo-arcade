extends Control
## Lobby screen. Builds its UI in code so every interactive control gets an accessible
## label, a focus ring and the full set of UI states required by the brief:
##   - empty   : no players added yet
##   - editing : 1+ slots, validation feedback
##   - error   : invalid roster (e.g. fewer than the minimum players)
##   - loading : transitioning into a match
##   - disabled: Start disabled until the roster is valid; Add disabled when full

enum UiState { EMPTY, EDITING, ERROR, LOADING }

## Functional, high-contrast stat marker colours. These mirror the in-game HUD power-up
## hues (Game.gd `_draw_powerup`) so a stat reads the same here as it does on the board —
## colour-by-meaning (balloons / range / speed), not a brand palette.
const STAT_COLOR_BALLOONS := Color("#2e9bd6")
const STAT_COLOR_RANGE := Color("#e5484d")
const STAT_COLOR_SPEED := Color("#30a46c")

## Selectable match lengths (best-of-N rounds). Each value is committed verbatim to
## MatchConfig.best_of; MatchSeries clamps to >= 1 and the HUD round counter reflects N.
const LENGTH_OPTIONS: Array = [1, 3, 5]

var _players: Array = []          # [{name:String, team:int, character:String, controller:String}]
var _state: int = UiState.EMPTY
## Chosen series length; defaults to the current value until the player picks another.
var _best_of: int = Spec.SERIES_BEST_OF_DEFAULT
## Chosen arena layout (Maps id); defaults until the player picks another.
var _map_id: String = Maps.default_id()

var _count_label: Label
var _empty_label: Label
var _error_label: Label
var _slots_box: VBoxContainer
var _add_btn: Button
var _connect_btn: Button
var _start_btn: Button
var _length_buttons: Array = []   # one toggle Button per LENGTH_OPTIONS entry
var _map_buttons: Array = []      # one toggle Button per Maps entry
var _map_desc_label: Label        # one-line description of the selected map
var _loading_overlay: Control

func _ready() -> void:
	_restore_persisted_state()
	_build_ui()
	# Materialise slot rows for any restored roster (rows are built on demand, so a restored
	# _players array needs an explicit rebuild to render its widgets).
	_rebuild_slots()
	_refresh()
	_add_btn.grab_focus()

## Restore the last committed roster and match length from user://settings.cfg so a host
## who reopens the game finds the lobby already configured. Everything is validated and
## degraded against current data by LobbyStore, so an unknown character, an out-of-range
## slot count, a conflicting scheme or a corrupt/missing file never blocks the lobby — the
## first run (no file) leaves `_players` empty, exactly like today.
func _restore_persisted_state() -> void:
	var saved := LobbyStore.load_roster()
	var players: Array = saved.get("players", [])
	if not players.is_empty():
		_players = players
	# Map the restored length onto an offered option; anything else degrades to the default
	# so a button is always the pressed segment.
	var bo := int(saved.get("best_of", Spec.SERIES_BEST_OF_DEFAULT))
	_best_of = bo if bo in LENGTH_OPTIONS else Spec.SERIES_BEST_OF_DEFAULT
	# Restore the chosen map, degrading any unknown id to the default layout.
	_map_id = Maps.sanitize(String(saved.get("map_id", Maps.default_id())))

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
	title.text = tr("LOBBY_TITLE")
	title.add_theme_font_size_override("font_size", 34)
	root.add_child(title)

	var subtitle := Label.new()
	subtitle.text = tr("LOBBY_SUBTITLE")
	subtitle.modulate = Color(0.78, 0.85, 0.95)
	root.add_child(subtitle)

	_count_label = Label.new()
	root.add_child(_count_label)

	root.add_child(_build_match_length_section())
	root.add_child(_build_map_section())

	# Persistent SFX volume/mute control (stored by the `Audio` autoload across sessions),
	# reachable before any match starts.
	root.add_child(SoundControl.build())

	var content := PanelContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(content)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)

	var inner := VBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.add_theme_constant_override("separation", 8)
	scroll.add_child(inner)

	_empty_label = Label.new()
	_empty_label.text = tr("LOBBY_EMPTY")
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.modulate = Color(0.74, 0.81, 0.92)
	inner.add_child(_empty_label)

	_slots_box = VBoxContainer.new()
	_slots_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_slots_box.add_theme_constant_override("separation", 8)
	inner.add_child(_slots_box)

	_error_label = Label.new()
	_error_label.add_theme_color_override("font_color", Color(0.898, 0.282, 0.302))
	_error_label.visible = false
	root.add_child(_error_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 12)
	root.add_child(buttons)

	_add_btn = Button.new()
	_add_btn.text = tr("BTN_ADD_PLAYER")
	A11y.label(_add_btn, tr("BTN_ADD_PLAYER"), tr("A11Y_ADD_PLAYER"))
	A11y.make_focusable(_add_btn)
	_add_btn.pressed.connect(_on_add_player)
	buttons.add_child(_add_btn)

	_connect_btn = Button.new()
	_connect_btn.text = tr("BTN_CONNECT")
	A11y.label(_connect_btn, tr("BTN_CONNECT"), tr("A11Y_CONNECT_SCAN"))
	A11y.make_focusable(_connect_btn)
	_connect_btn.pressed.connect(_on_open_connect)
	buttons.add_child(_connect_btn)

	# "Check for updates" — only on a build that can actually self-update (a signed macOS build
	# with the Sparkle extension). Hidden everywhere else, so the editor/tests are unaffected.
	if UpdateManager.is_supported():
		var update_btn := Button.new()
		update_btn.text = tr("BTN_CHECK_UPDATES")
		A11y.label(update_btn, tr("BTN_CHECK_UPDATES"), tr("A11Y_CHECK_UPDATES"))
		A11y.make_focusable(update_btn)
		update_btn.pressed.connect(func(): UpdateManager.check_for_updates())
		buttons.add_child(update_btn)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	_start_btn = Button.new()
	_start_btn.text = tr("BTN_START")
	A11y.label(_start_btn, tr("BTN_START"), tr("A11Y_START_MATCH"))
	A11y.make_focusable(_start_btn)
	_start_btn.pressed.connect(_on_start)
	buttons.add_child(_start_btn)

	_loading_overlay = _build_loading_overlay()
	add_child(_loading_overlay)

# --- Match length (best-of-N series) ---------------------------------------
## A segmented length picker: one toggle button per LENGTH_OPTIONS value, grouped so
## exactly one stays pressed (the "selected" state). The chosen value is committed to
## MatchConfig.best_of on Start. The whole group is disabled while loading or whenever the
## roster is invalid, mirroring the Start button's gating. Changing the selection never
## touches the roster.
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
		btn.set_meta("best_of", n)
		btn.button_pressed = (n == _best_of)
		A11y.label(btn, tr("LOBBY_ROUNDS_VALUE").format([n]),
			tr("A11Y_MATCH_LENGTH_OPTION").format([n]))
		A11y.make_focusable(btn)
		btn.pressed.connect(_on_match_length_selected.bind(n))
		segment.add_child(btn)
		_length_buttons.append(btn)
	return box

## Record the chosen series length. Toggle buttons in a group keep one pressed, so this
## only stores the value — the roster is left untouched (no rebuild, no reset).
func _on_match_length_selected(value: int) -> void:
	_best_of = maxi(1, value)

## Arena (map) picker: one toggle button per Maps entry, grouped so exactly one stays pressed.
## The chosen id is committed to MatchConfig.map_id on Start and persisted. A description line
## below updates as the selection changes so a host knows what each layout plays like.
func _build_map_section() -> Control:
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
		btn.set_meta("map_id", mid)
		btn.button_pressed = (mid == _map_id)
		A11y.label(btn, tr(m["name_key"]), tr(m["desc_key"]))
		A11y.make_focusable(btn)
		btn.pressed.connect(_on_map_selected.bind(mid))
		segment.add_child(btn)
		_map_buttons.append(btn)

	_map_desc_label = Label.new()
	_map_desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_map_desc_label.modulate = Color(0.82, 0.88, 0.97)
	box.add_child(_map_desc_label)
	_update_map_desc()
	return box

## Record the chosen map and refresh its description. Toggle buttons keep one pressed, so this
## only stores the value — the roster is untouched.
func _on_map_selected(map_id: String) -> void:
	_map_id = Maps.sanitize(map_id)
	_update_map_desc()

func _update_map_desc() -> void:
	if _map_desc_label == null:
		return
	var def := Maps.get_def(_map_id)
	_map_desc_label.text = tr(def["desc_key"]) if not def.is_empty() else ""

func _build_loading_overlay() -> Control:
	var overlay := ColorRect.new()
	overlay.color = Color(0.04, 0.07, 0.13, 0.85)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.visible = false
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.add_child(center)
	var label := Label.new()
	label.text = tr("LOBBY_LOADING")
	label.add_theme_font_size_override("font_size", 28)
	center.add_child(label)
	return overlay

# --- Slot rows -------------------------------------------------------------
func _rebuild_slots() -> void:
	for child in _slots_box.get_children():
		child.queue_free()
	for i in _players.size():
		_slots_box.add_child(_make_slot_row(i))

func _make_slot_row(index: int) -> Control:
	var slot := VBoxContainer.new()
	slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slot.add_theme_constant_override("separation", 4)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	slot.add_child(row)

	var idx_label := Label.new()
	idx_label.custom_minimum_size = Vector2(90, 0)
	idx_label.text = tr("A11Y_PLAYER_SLOT").format([index + 1])
	row.add_child(idx_label)

	var name_edit := LineEdit.new()
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.placeholder_text = tr("SLOT_PLAYER_NAME")
	name_edit.text = _players[index]["name"]
	A11y.label(name_edit, tr("SLOT_PLAYER_NAME"), tr("A11Y_PLAYER_SLOT").format([index + 1]))
	name_edit.text_changed.connect(func(t): _players[index]["name"] = t)
	row.add_child(name_edit)

	var team := OptionButton.new()
	for team_i in Spec.MAX_PLAYERS:
		team.add_item("%s %d" % [tr("SLOT_TEAM"), team_i + 1], team_i)
	team.select(_players[index]["team"])
	A11y.label(team, tr("SLOT_TEAM"), tr("A11Y_TEAM_SELECT").format([index + 1]))
	A11y.make_focusable(team)
	team.item_selected.connect(func(sel): _players[index]["team"] = sel)
	row.add_child(team)

	var character := OptionButton.new()
	var char_ids := Characters.ids()
	for ci in Characters.count():
		var cdef: Dictionary = Characters.all()[ci]
		character.add_item("%s · %s" % [tr(cdef["name_key"]), tr(cdef["motif_key"])], ci)
	var sel_char: int = maxi(0, char_ids.find(_players[index].get("character", "")))
	character.select(sel_char)
	A11y.label(character, tr("SLOT_CHARACTER"), tr("A11Y_CHARACTER_SELECT").format([index + 1]))
	A11y.make_focusable(character)
	row.add_child(character)

	var control := OptionButton.new()
	_populate_control_options(control, index)
	A11y.label(control, tr("SLOT_CONTROL"), tr("A11Y_CONTROL_SELECT").format([index + 1]))
	A11y.make_focusable(control)
	control.item_selected.connect(_on_control_selected.bind(index, control))
	row.add_child(control)

	var remove := Button.new()
	remove.text = tr("SLOT_REMOVE")
	A11y.label(remove, tr("SLOT_REMOVE"), tr("A11Y_REMOVE_PLAYER"))
	A11y.make_focusable(remove)
	remove.pressed.connect(_on_remove_player.bind(index))
	row.add_child(remove)

	# Selection preview: the chosen character's description + starting strengths, read
	# straight from the Characters SSOT. It updates immediately when the selection
	# changes so a player can compare playstyles before the match begins.
	var preview := _make_character_preview(index)
	slot.add_child(preview)
	character.item_selected.connect(func(sel):
		_players[index]["character"] = char_ids[sel]
		_update_character_preview(preview, char_ids[sel]))
	_update_character_preview(preview, _players[index].get("character", ""))
	return slot

# --- Character selection preview -------------------------------------------
## Builds the per-slot preview surface. It is focusable, carries an accessible
## label/description (A11y.gd), and inherits the global high-contrast theme + focus ring
## (assets/theme.tres). Contents are filled by _update_character_preview().
func _make_character_preview(index: int) -> Control:
	var preview := PanelContainer.new()
	preview.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	A11y.make_focusable(preview)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	preview.add_child(box)

	var desc := Label.new()
	desc.name = "Desc"
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Long localized descriptions wrap within the slot width instead of stretching the row.
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.modulate = Color(0.82, 0.88, 0.97)
	box.add_child(desc)

	# Unique-skill line: name + cast button + one-line effect, so a player understands
	# what their character does and which key triggers it without leaving the lobby.
	var skill := Label.new()
	skill.name = "Skill"
	skill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	skill.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	skill.modulate = Color(0.98, 0.86, 0.55)
	box.add_child(skill)

	var stats := HBoxContainer.new()
	stats.name = "Stats"
	stats.add_theme_constant_override("separation", 16)
	box.add_child(stats)
	# Functional, high-contrast stat markers (colour-by-meaning, same hues as the HUD).
	_add_stat_marker(stats, "Balloons", STAT_COLOR_BALLOONS)
	_add_stat_marker(stats, "Range", STAT_COLOR_RANGE)
	_add_stat_marker(stats, "Speed", STAT_COLOR_SPEED)

	preview.set_meta("slot_index", index)
	preview.set_meta("desc", desc)
	preview.set_meta("skill", skill)
	preview.set_meta("stats", stats)
	return preview

## Creates one "▮ Label N" stat chip: a small functional colour marker followed by a
## value label whose text is set later from the localized stat name + SSOT value.
func _add_stat_marker(parent: HBoxContainer, tag: String, color: Color) -> void:
	var chip := HBoxContainer.new()
	chip.name = tag
	chip.add_theme_constant_override("separation", 5)
	var marker := ColorRect.new()
	marker.color = color
	marker.custom_minimum_size = Vector2(12, 12)
	marker.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.add_child(marker)
	var value := Label.new()
	value.name = "Value"
	chip.add_child(value)
	chip.set_meta("value", value)
	parent.add_child(chip)
	parent.set_meta(tag, chip)

## Fills the preview from the Characters SSOT. Unknown/empty ids show a neutral empty
## state (mirrors Characters.get_def) with the stat chips hidden — no crash, no stale data.
func _update_character_preview(preview: Control, char_id: String) -> void:
	var index := int(preview.get_meta("slot_index", 0))
	var desc: Label = preview.get_meta("desc")
	var skill: Label = preview.get_meta("skill")
	var stats: HBoxContainer = preview.get_meta("stats")
	var def := Characters.get_def(char_id)
	if def.is_empty():
		desc.text = tr("SLOT_CHARACTER_EMPTY")
		skill.visible = false
		stats.visible = false
		A11y.label(preview, tr("SLOT_CHARACTER"), tr("SLOT_CHARACTER_EMPTY"))
		return

	desc.text = tr(def["desc_key"])
	stats.visible = true
	var balloons := int(def["start_balloons"])
	var range_v := int(def["start_range"])
	var speed := float(def["start_speed"])
	_set_stat_value(stats, "Balloons", "%s %d" % [tr("HUD_BALLOONS"), balloons])
	_set_stat_value(stats, "Range", "%s %d" % [tr("HUD_RANGE"), range_v])
	_set_stat_value(stats, "Speed", "%s %0.1f" % [tr("HUD_SPEED"), speed])

	# Skill line: "Skill · Name (key): effect". The cast key is shown only when this slot
	# is driven by a local human scheme (bots/online slots have no on-device key to press).
	var skill_text := "%s · %s" % [tr("SLOT_SKILL"), tr(def["skill_name_key"])]
	var skill_button := _skill_button_label(index)
	if skill_button != "":
		skill_text += " (%s)" % skill_button
	skill_text += ": %s" % tr(def["skill_desc_key"])
	skill.text = skill_text
	skill.visible = true

	# Accessible readout: name + the same description, skill and strengths shown visually.
	var summary := "%s — %s — %s %d, %s %d, %s %0.1f" % [
		tr(def["desc_key"]),
		skill_text,
		tr("HUD_BALLOONS"), balloons,
		tr("HUD_RANGE"), range_v,
		tr("HUD_SPEED"), speed]
	A11y.label(preview, tr("A11Y_CHARACTER_PREVIEW").format([index + 1]), summary)

## The localized cast-button label for a slot, or "" when the slot is a bot (no key to
## show). Read from the InputScheme SSOT so the lobby never hardcodes a key name.
func _skill_button_label(index: int) -> String:
	var ctrl: String = _players[index].get("controller", InputScheme.BOT)
	if not InputScheme.is_human(ctrl):
		return ""
	return tr(InputScheme.skill_key(ctrl))

func _set_stat_value(stats: HBoxContainer, tag: String, text: String) -> void:
	var chip: HBoxContainer = stats.get_meta(tag)
	var value: Label = chip.get_meta("value")
	value.text = text

# --- Control scheme (local human vs bot) -----------------------------------
## Fills a slot's Controls selector with "Bot" + every local scheme. A scheme already
## assigned to a DIFFERENT slot is shown disabled (it can't be taken twice), and the row's
## current controller is selected. Each item carries its controller id as metadata.
func _populate_control_options(control: OptionButton, index: int) -> void:
	control.clear()
	var current: String = _players[index].get("controller", InputScheme.BOT)
	control.add_item(tr("CTRL_BOT"), 0)
	control.set_item_metadata(0, InputScheme.BOT)
	var item_i := 1
	for scheme in InputScheme.all():
		var sid: String = scheme["id"]
		control.add_item(tr(scheme["label_key"]), item_i)
		control.set_item_metadata(item_i, sid)
		if _scheme_taken_by_other(sid, index):
			control.set_item_disabled(item_i, true)
		item_i += 1
	# Select the row's current controller by matching metadata.
	for i in control.item_count:
		if control.get_item_metadata(i) == current:
			control.select(i)
			break

func _scheme_taken_by_other(scheme_id: String, index: int) -> bool:
	for i in _players.size():
		if i != index and _players[i].get("controller", InputScheme.BOT) == scheme_id:
			return true
	return false

func _on_control_selected(item: int, index: int, control: OptionButton) -> void:
	_players[index]["controller"] = control.get_item_metadata(item)
	# Rebuild rows so the new disabled/available scheme state is reflected everywhere.
	_rebuild_slots()
	_refresh()

## Pick a sensible default controller for a freshly added slot: the first slot becomes a
## local human on the first scheme so a round is playable immediately; later slots default
## to bots (humans are opt-in, remaining slots stay bots per the brief).
func _default_controller_for_index(index: int) -> String:
	if index == 0 and InputScheme.count() > 0:
		return InputScheme.ids()[0]
	return InputScheme.BOT

# --- Actions ---------------------------------------------------------------
func _on_add_player() -> void:
	if _players.size() >= Spec.MAX_PLAYERS:
		return
	var idx := _players.size()
	_players.append({
		"name": "",
		"team": idx,
		"character": Characters.default_id_for_index(idx),
		"controller": _default_controller_for_index(idx),
	})
	_rebuild_slots()
	_refresh()

func _on_remove_player(index: int) -> void:
	if index >= 0 and index < _players.size():
		_players.remove_at(index)
		_rebuild_slots()
		_refresh()

func _on_open_connect() -> void:
	get_tree().change_scene_to_file("res://scenes/Connect.tscn")

func _on_start() -> void:
	if not _roster_valid():
		_set_state(UiState.ERROR)
		return
	_set_state(UiState.LOADING)
	var committed := _commit_roster()
	MatchConfig.player_defs = committed
	MatchConfig.match_seed = Time.get_ticks_msec()
	MatchConfig.best_of = _best_of
	MatchConfig.map_id = _map_id
	# Remember this roster + match length + map for the next launch (criterion: the lobby reopens
	# with the last setup already applied). Persisted after the conflict-resolved commit so
	# what is restored matches what was actually played.
	LobbyStore.save_roster(committed, _best_of, _map_id)
	MatchConfig.start_series()
	var timer := get_tree().create_timer(0.5)
	timer.timeout.connect(func():
		var err := get_tree().change_scene_to_file("res://scenes/Game.tscn")
		if err != OK:
			_set_state(UiState.ERROR, tr("LOBBY_ERROR_GENERIC")))

func _commit_roster() -> Array:
	var out: Array = []
	var taken: Dictionary = {}    # scheme_id -> true (defensive: never assign one twice)
	for i in _players.size():
		var nm: String = _players[i]["name"].strip_edges()
		if nm.is_empty():
			nm = "P%d" % (i + 1)
		var ctrl: String = _players[i].get("controller", InputScheme.BOT)
		if InputScheme.is_human(ctrl) and taken.has(ctrl):
			ctrl = InputScheme.BOT   # conflict fallback: extra duplicate becomes a bot
		if InputScheme.is_human(ctrl):
			taken[ctrl] = true
		out.append({
			"name": nm,
			"team": _players[i]["team"],
			"character": _players[i].get("character", ""),
			"controller": ctrl,
		})
	return out

# --- State -----------------------------------------------------------------
func _roster_valid() -> bool:
	var n := _players.size()
	return n >= Spec.MIN_PLAYERS and n <= Spec.MAX_PLAYERS

func _set_state(state: int, error_text: String = "") -> void:
	_state = state
	if state == UiState.ERROR and error_text.is_empty():
		error_text = tr("LOBBY_ERROR_MIN_PLAYERS")
	if not error_text.is_empty():
		_error_label.text = error_text
	_refresh()

func _refresh() -> void:
	var n := _players.size()
	if _state != UiState.LOADING and _state != UiState.ERROR:
		_state = UiState.EMPTY if n == 0 else UiState.EDITING

	_count_label.text = tr("PLAYER_COUNT").format([n, Spec.MAX_PLAYERS])
	_empty_label.visible = (n == 0)
	_slots_box.visible = (n > 0)
	_loading_overlay.visible = (_state == UiState.LOADING)

	# Error visibility: explicit error state, or a hint when below the minimum.
	if _state == UiState.ERROR:
		_error_label.visible = true
	elif n > 0 and n < Spec.MIN_PLAYERS:
		_error_label.text = tr("LOBBY_ERROR_MIN_PLAYERS")
		_error_label.visible = true
	else:
		_error_label.visible = false

	# Disabled states.
	_add_btn.disabled = (n >= Spec.MAX_PLAYERS) or (_state == UiState.LOADING)
	_start_btn.disabled = (not _roster_valid()) or (_state == UiState.LOADING)
	# The match-length and map pickers are gated exactly like Start: disabled while loading and
	# whenever the roster is invalid.
	var length_disabled := (not _roster_valid()) or (_state == UiState.LOADING)
	for btn in _length_buttons:
		btn.disabled = length_disabled
	for btn in _map_buttons:
		btn.disabled = length_disabled
