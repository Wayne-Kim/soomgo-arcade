class_name NetSession
extends RefCounted
## Realtime transport binding over Godot ENet (acceptance criteria 1 & 2).
##
## Wraps ENetMultiplayerPeer at the packet level (manual poll + put_packet/get_packet)
## and speaks NetProtocol. This is the realtime data channel — Bluetooth is never used
## here. The netcode model is deterministic lockstep: the host assigns player ids + the
## match seed, then all peers relay per-tick inputs and run an identical Simulation.step().
##
## RefCounted (no scene tree needed) so it can be driven from a _process loop or exercised
## headlessly in tests by polling two sessions in one process.

signal peer_joined(peer_id: int, player_count: int)
signal peer_left(peer_id: int)
signal welcomed(player_id: int, seed_value: int, player_count: int)
signal input_received(tick: int, player_id: int, dir: Vector2i, place: bool, round_index: int, skill: bool)
signal rtt_updated(rtt_ms: float)
signal connected_ok()
signal connection_failed()
signal disconnected()
## Emitted when a player leaves a started match (host: on the client's ENet disconnect;
## clients: when the host's DROP relay arrives). Carries the assigned player id so the match
## driver can latch it to predicted input.
signal player_dropped(player_id: int)
## Emitted when the match actually begins (host: when it calls start_match; client: when the
## host's START arrives). Carries the shared seed + authoritative roster + this peer's id +
## the host-chosen series length (best-of-N).
signal match_started(seed_value: int, roster: Array, local_player_id: int, best_of: int)
## Host -> all clients: advance the series to the next round (or a rematch). Carries the shared
## monotonic round tag, a rematch reset flag, and the authoritative dropped-player set so every
## peer rebuilds the identical round. Emitted on clients when the host's ADVANCE arrives.
signal advance_received(net_round: int, reset: bool, dropped: Array)
## Host-only: a client asked for a rematch on the series-over screen.
signal rematch_requested()
## The pre-match room composition changed (a player joined/left, was kicked, picked a character,
## or toggled ready). Carries no payload — listeners read `lobby_players` / `room_name`. Fires on
## the host whenever it rebuilds the snapshot and on a client whenever a ROOM_STATE arrives.
signal room_updated()
## This client was removed from the room by the host. The UI leaves the room and shows why.
signal kicked()

const _SERVER_ID: int = 1

var peer: ENetMultiplayerPeer
var is_server: bool = false
var local_player_id: int = -1
var seed_value: int = 0
var last_rtt_ms: float = -1.0
## True once the match has started; the host stops admitting late joiners after this.
var started: bool = false
## Host-chosen series length (best-of-N). Set by the host UI before start_match; broadcast in
## START so every peer plays the same number of rounds.
var match_best_of: int = Spec.SERIES_BEST_OF_DEFAULT
## Host-chosen arena layout (Maps id). Set by the host UI; carried in ROOM_STATE (so clients see
## it in the room) and in START (so every peer builds the same arena).
var match_map_id: String = Maps.DEFAULT_ID

## Human-readable room name the host typed when creating the room. Advertised in the LAN beacon
## (so it shows in the discovery list) and carried in ROOM_STATE (so it titles the room view).
var room_name: String = ""
## Latest room snapshot: ordered [{id, name, character, ready, host}]. On the host this is rebuilt
## from the tracking dictionaries on every change; on a client it is the last ROOM_STATE received.
## The room UI renders directly from this.
var lobby_players: Array = []

var _display_name: String = "Host"
var _seed: int = 0
var _next_player_id: int = 1            # server: 0 is the host, clients get 1..N-1
var _peer_to_player: Dictionary = {}    # enet peer id -> assigned player id
var _player_names: Dictionary = {}      # assigned player id -> display name
var _player_characters: Dictionary = {} # assigned player id -> chosen character id (host-tracked)
var _player_ready: Dictionary = {}      # assigned player id -> ready flag (host-tracked)
var _ping_id: int = 0

# --- Lifecycle -------------------------------------------------------------
func host(port: int = NetBudget.DEFAULT_PORT, host_name: String = "Host", seed_value_in: int = 0, room_name_in: String = "") -> int:
	_reset()
	is_server = true
	_display_name = host_name
	_seed = seed_value_in if seed_value_in != 0 else int(Time.get_unix_time_from_system())
	seed_value = _seed
	local_player_id = 0
	_player_names[0] = host_name
	# Seed the host's own room slot: a default character and "ready" (the host commits by pressing
	# Start, so it is always counted ready). A blank room name falls back to the host's name.
	room_name = room_name_in.strip_edges() if room_name_in.strip_edges() != "" else host_name
	_player_characters[0] = Characters.default_id_for_index(0)
	_player_ready[0] = true
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_server(port, NetBudget.MAX_PLAYERS - 1)
	if err != OK:
		_reset()
		return err
	_connect_peer_signals()
	lobby_players = _lobby_snapshot()
	return OK

func join(address: String, port: int = NetBudget.DEFAULT_PORT, display_name: String = "Player") -> int:
	_reset()
	is_server = false
	_display_name = display_name
	peer = ENetMultiplayerPeer.new()
	var err := peer.create_client(address, port)
	if err != OK:
		_reset()
		return err
	_connect_peer_signals()
	return OK

func close() -> void:
	if peer != null:
		peer.close()
	_reset()

func is_active() -> bool:
	return peer != null

# --- Pumping ---------------------------------------------------------------
## Call every frame. Drains ENet events + inbound packets.
func poll() -> void:
	if peer == null:
		return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var from := peer.get_packet_peer()
		var data := peer.get_packet()
		if data.size() > 0:
			_dispatch(from, data)

# --- Sending ---------------------------------------------------------------
func broadcast_input(tick: int, player_id: int, dir: Vector2i, place: bool, round_index: int = 0, skill: bool = false) -> void:
	_send(MultiplayerPeer.TARGET_PEER_BROADCAST, NetProtocol.encode_input(tick, player_id, dir, place, round_index, skill))

## Host -> all clients: deterministically advance the series to `net_round` (rematch when
## `reset`), naming the authoritative dropped set so every peer rebuilds the same round.
func broadcast_advance(net_round: int, reset: bool, dropped_ids: Array) -> void:
	if not is_server:
		return
	_send(MultiplayerPeer.TARGET_PEER_BROADCAST, NetProtocol.encode_advance(net_round, reset, dropped_ids))

## Client -> host: ask the host to start a rematch from the series-over screen.
func request_rematch() -> void:
	if is_server:
		return
	_send(_SERVER_ID, NetProtocol.encode_rematch_request())

## Measure round-trip latency. Client pings the server; server pings every client.
func send_ping() -> void:
	_ping_id += 1
	var pkt := NetProtocol.encode_ping(_ping_id, Time.get_ticks_usec())
	_send(MultiplayerPeer.TARGET_PEER_BROADCAST, pkt)

# --- Match start -----------------------------------------------------------
## Connected human player ids (host + every joined client), sorted ascending.
func connected_player_ids() -> Array:
	var ids: Array = [local_player_id] if local_player_id >= 0 else []
	for pid in _peer_to_player.values():
		ids.append(pid)
	ids.sort()
	return ids

## Number of connected human participants (host included).
func human_count() -> int:
	return connected_player_ids().size()

## Host: lock the roster, broadcast START to every client and signal the local match start.
## Builds an id-indexed roster: connected humans drive their assigned id, every other slot
## (gaps from pre-start churn, or padding up to the minimum) is a deterministic bot. Returns
## the roster, or [] if called on a client or with no peers connected.
func start_match() -> Array:
	if not is_server:
		return []
	var humans := connected_player_ids()
	if humans.size() < 2:
		return []   # a networked match needs at least one joined peer besides the host
	var top: int = humans[humans.size() - 1]
	var total: int = clampi(maxi(top + 1, Spec.MIN_PLAYERS), Spec.MIN_PLAYERS, Spec.MAX_PLAYERS)
	var roster := build_roster(total, humans)
	started = true
	_send(MultiplayerPeer.TARGET_PEER_BROADCAST, NetProtocol.encode_start(_seed, roster, match_best_of, match_map_id))
	poll()  # flush the START packet to clients before the caller changes scene
	match_started.emit(_seed, roster, local_player_id, match_best_of)
	return roster

## Build an id-indexed roster of `total` slots: ids in `human_ids` are human, the rest bots.
## A human slot uses the character that player picked in the room (falling back to the cycling
## default if none was chosen); bot slots keep the cycling default.
func build_roster(total: int, human_ids: Array) -> Array:
	var roster: Array = []
	for id in total:
		var is_bot := not human_ids.has(id)
		var character: String = Characters.default_id_for_index(id)
		if not is_bot:
			character = String(_player_characters.get(id, character))
		roster.append({
			"team": id,                                  # free-for-all: round resolves on last alive
			"bot": is_bot,
			"character": character,
			"name": _name_for(id, is_bot),
		})
	return roster

func _name_for(id: int, is_bot: bool) -> String:
	if is_bot:
		return "Bot %d" % (id + 1)
	return String(_player_names.get(id, "Player %d" % (id + 1)))

# --- Room (pre-match lobby) -------------------------------------------------
## The current room snapshot built from the host's tracking dictionaries. The host slot is always
## marked ready (it commits by pressing Start). Host-only; clients read the received `lobby_players`.
func _lobby_snapshot() -> Array:
	var out: Array = []
	for pid in connected_player_ids():
		out.append({
			"id": pid,
			"name": _name_for(pid, false),
			"character": String(_player_characters.get(pid, Characters.default_id_for_index(pid))),
			"ready": true if pid == 0 else bool(_player_ready.get(pid, false)),
			"host": pid == 0,
		})
	return out

## Host: rebuild the snapshot, push it to every client and refresh the host's own room UI. Safe
## to call with no peers connected (the broadcast is then a no-op).
func broadcast_room_state() -> void:
	if not is_server:
		return
	lobby_players = _lobby_snapshot()
	_send(MultiplayerPeer.TARGET_PEER_BROADCAST, NetProtocol.encode_room_state(room_name, match_best_of, match_map_id, lobby_players))
	room_updated.emit()

## Set THIS device's character in the room. The host updates + rebroadcasts directly; a client
## asks the host, which echoes the authoritative ROOM_STATE back.
func set_my_character(character: String) -> void:
	if is_server:
		_player_characters[local_player_id] = character
		broadcast_room_state()
	else:
		_send(_SERVER_ID, NetProtocol.encode_set_character(character))

## Set THIS device's ready flag. Only meaningful for clients (the host is always counted ready);
## a client tells the host, which echoes ROOM_STATE.
func set_my_ready(ready: bool) -> void:
	if is_server:
		return
	_send(_SERVER_ID, NetProtocol.encode_set_ready(ready))

## Host: true once the room can start — at least two participants and every non-host player ready.
func all_ready() -> bool:
	if not is_server:
		return false
	var ids := connected_player_ids()
	if ids.size() < 2:
		return false
	for pid in ids:
		if pid == 0:
			continue   # the host commits by pressing Start
		if not bool(_player_ready.get(pid, false)):
			return false
	return true

## Host: remove a joined player from the room. Tells that client (so it can show why), drops the
## ENet peer, clears its room state and rebroadcasts so everyone else sees the updated roster.
func kick_player(player_id: int) -> void:
	if not is_server or player_id == 0:
		return
	var enet_id := _enet_for_player(player_id)
	if enet_id == -1:
		return
	_send(enet_id, NetProtocol.encode_kick(player_id))
	poll()   # flush the KICK packet before the disconnect tears the channel down
	peer.disconnect_peer(enet_id)
	_peer_to_player.erase(enet_id)
	_player_names.erase(player_id)
	_player_characters.erase(player_id)
	_player_ready.erase(player_id)
	broadcast_room_state()
	peer_left.emit(enet_id)

func _enet_for_player(player_id: int) -> int:
	for enet_id in _peer_to_player:
		if _peer_to_player[enet_id] == player_id:
			return enet_id
	return -1

# --- Dispatch --------------------------------------------------------------
func _dispatch(from: int, data: PackedByteArray) -> void:
	match NetProtocol.message_type(data):
		NetProtocol.Msg.HELLO:
			_on_hello(from, data)
		NetProtocol.Msg.WELCOME:
			_on_welcome(data)
		NetProtocol.Msg.START:
			_on_start(data)
		NetProtocol.Msg.DROP:
			if not is_server:
				player_dropped.emit(NetProtocol.decode_drop(data)["player_id"])
		NetProtocol.Msg.ADVANCE:
			if not is_server:
				var a := NetProtocol.decode_advance(data)
				advance_received.emit(a["net_round"], a["reset"], a["dropped"])
		NetProtocol.Msg.REMATCH_REQUEST:
			if is_server:
				rematch_requested.emit()
		NetProtocol.Msg.ROOM_STATE:
			if not is_server:
				var rs := NetProtocol.decode_room_state(data)
				room_name = rs["room_name"]
				match_best_of = rs["best_of"]
				match_map_id = Maps.sanitize(rs["map_id"])
				lobby_players = rs["players"]
				room_updated.emit()
		NetProtocol.Msg.SET_CHARACTER:
			if is_server and _peer_to_player.has(from):
				_player_characters[_peer_to_player[from]] = NetProtocol.decode_set_character(data)["character"]
				broadcast_room_state()
		NetProtocol.Msg.SET_READY:
			if is_server and _peer_to_player.has(from):
				_player_ready[_peer_to_player[from]] = NetProtocol.decode_set_ready(data)["ready"]
				broadcast_room_state()
		NetProtocol.Msg.KICK:
			if not is_server and NetProtocol.decode_kick(data)["player_id"] == local_player_id:
				kicked.emit()
		NetProtocol.Msg.INPUT:
			# The host is the relay hub: in client-server ENet a client's broadcast only
			# reaches the host, so re-send it to every other client before applying locally.
			if is_server:
				_relay_excluding(from, data)
			var m := NetProtocol.decode_input(data)
			input_received.emit(m["tick"], m["player_id"], m["dir"], m["place"], m["round"], m["skill"])
		NetProtocol.Msg.PING:
			var p := NetProtocol.decode_ping(data)
			_send(from, NetProtocol.encode_pong(p["ping_id"], p["send_usec"]))
		NetProtocol.Msg.PONG:
			var q := NetProtocol.decode_ping(data)
			last_rtt_ms = float(Time.get_ticks_usec() - q["send_usec"]) / 1000.0
			rtt_updated.emit(last_rtt_ms)

func _on_hello(from: int, data: PackedByteArray) -> void:
	if not is_server:
		return
	if started:
		# Match already running: reject the late joiner cleanly (no id, no welcome).
		return
	var hello := NetProtocol.decode_hello(data)
	var assigned: int = _next_player_id
	_next_player_id += 1
	_peer_to_player[from] = assigned
	_player_names[assigned] = String(hello.get("name", "Player %d" % (assigned + 1)))
	# New joiner starts on a default character and not-ready. WELCOME first (so the client learns
	# its id), then ROOM_STATE so it — and everyone already in the room — sees the new roster.
	_player_characters[assigned] = Characters.default_id_for_index(assigned)
	_player_ready[assigned] = false
	_send(from, NetProtocol.encode_welcome(assigned, _seed, _next_player_id))
	peer_joined.emit(from, _next_player_id)
	broadcast_room_state()

func _on_welcome(data: PackedByteArray) -> void:
	var m := NetProtocol.decode_welcome(data)
	local_player_id = m["player_id"]
	seed_value = m["seed"]
	welcomed.emit(m["player_id"], m["seed"], m["player_count"])

func _on_start(data: PackedByteArray) -> void:
	if is_server:
		return
	var m := NetProtocol.decode_start(data)
	started = true
	seed_value = m["seed"]
	match_best_of = m["best_of"]
	match_map_id = Maps.sanitize(m["map_id"])
	match_started.emit(m["seed"], m["roster"], local_player_id, m["best_of"])

# --- ENet signal handlers --------------------------------------------------
func _on_peer_connected(id: int) -> void:
	if is_server:
		# Wait for the client's HELLO to assign a player id.
		return
	# Client side: connection to the server established -> introduce ourselves.
	_send(_SERVER_ID, NetProtocol.encode_hello(_display_name))
	connected_ok.emit()

func _on_peer_disconnected(id: int) -> void:
	if is_server and _peer_to_player.has(id):
		var player_id: int = _peer_to_player[id]
		_player_names.erase(player_id)
		_player_characters.erase(player_id)
		_player_ready.erase(player_id)
		_peer_to_player.erase(id)
		if started:
			# Tell the remaining clients (the data hub is the host) and the local match driver
			# so every peer latches the same player to predicted input — round resolves, no hang.
			_send(MultiplayerPeer.TARGET_PEER_BROADCAST, NetProtocol.encode_drop(player_id))
			player_dropped.emit(player_id)
		else:
			# Still in the room: refresh everyone's roster so the departed player drops out.
			broadcast_room_state()
	peer_left.emit(id)

func _on_connection_failed() -> void:
	connection_failed.emit()

func _on_server_disconnected() -> void:
	disconnected.emit()

# --- helpers ---------------------------------------------------------------
func _send(target: int, data: PackedByteArray) -> void:
	if peer == null:
		return
	peer.set_target_peer(target)
	peer.put_packet(data)

## Host-only: forward a received packet to every connected client except its sender.
func _relay_excluding(from: int, data: PackedByteArray) -> void:
	for enet_id in _peer_to_player.keys():
		if enet_id != from:
			_send(enet_id, data)

func _connect_peer_signals() -> void:
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)

func _reset() -> void:
	peer = null
	is_server = false
	local_player_id = -1
	seed_value = 0
	last_rtt_ms = -1.0
	started = false
	room_name = ""
	match_map_id = Maps.DEFAULT_ID
	lobby_players.clear()
	_next_player_id = 1
	_peer_to_player.clear()
	_player_names.clear()
	_player_characters.clear()
	_player_ready.clear()
	_ping_id = 0
