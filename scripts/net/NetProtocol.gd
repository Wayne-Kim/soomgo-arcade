class_name NetProtocol
extends RefCounted
## Compact binary wire codec for the realtime ENet channel + the LAN discovery beacon.
##
## Keeping the wire format here (separate from transport) makes it deterministic and
## unit-testable without opening a socket. Every message starts with a 1-byte type tag.
##
## Message types:
##   HELLO   client -> host : protocol version + display name (join request)
##   WELCOME host -> client : assigned player_id, match seed, current player count
##   INPUT   peer  <-> host : tick, player_id, dir (-1..1 each), place flag (lockstep)
##   PING    peer  -> peer  : ping id + send timestamp (round-trip measurement)
##   PONG    peer  -> peer  : echoed ping id + original send timestamp
##   START   host  -> peers : shared seed + authoritative roster + series length (best-of-N)
##   ADVANCE host  -> peers : start the next round/rematch (round tag, reset, dropped set)
##   REMATCH_REQUEST client -> host : ask the host to start a rematch
##   BEACON  host  -> LAN   : UDP advertisement (magic, version, port, name, players)
##   ROOM_STATE    host -> peers : pre-match lobby snapshot (room name, length, every player's
##                                 name / character / ready / host flag) — the host owns it
##   SET_CHARACTER client -> host : I picked this character in the room
##   SET_READY     client -> host : I am (not) ready to start
##   KICK          host -> client : you were removed from the room by the host

const MAGIC: int = 0x534F4F4D   # "SOOM" — guards against unrelated UDP traffic

enum Msg { HELLO = 1, WELCOME = 2, INPUT = 3, PING = 4, PONG = 5, BEACON = 6, START = 7, DROP = 8,
	ADVANCE = 9, REMATCH_REQUEST = 10, ROOM_STATE = 11, SET_CHARACTER = 12, SET_READY = 13, KICK = 14 }

# --- HELLO -----------------------------------------------------------------
static func encode_hello(display_name: String) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.HELLO)
	b.put_u8(NetBudget.PROTOCOL_VERSION)
	b.put_utf8_string(display_name)
	return b.data_array

static func decode_hello(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()  # type
	return {"version": b.get_u8(), "name": b.get_utf8_string()}

# --- WELCOME ---------------------------------------------------------------
static func encode_welcome(player_id: int, seed_value: int, player_count: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.WELCOME)
	b.put_u8(player_id)
	b.put_64(seed_value)
	b.put_u8(player_count)
	return b.data_array

static func decode_welcome(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"player_id": b.get_u8(), "seed": b.get_64(), "player_count": b.get_u8()}

# --- START -----------------------------------------------------------------
## Host -> all clients: the authoritative roster + shared seed that kicks every peer into
## the same deterministic match. `roster` is an ordered array indexed by player id; each
## entry is {team:int, bot:bool, character:String, name:String}. Sending the full roster
## (not just a count) guarantees every peer builds a byte-identical Simulation. `best_of`
## is the host-chosen series length so every peer plays the same number of rounds.
static func encode_start(seed_value: int, roster: Array, best_of: int = Spec.SERIES_BEST_OF_DEFAULT, map_id: String = Maps.DEFAULT_ID) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.START)
	b.put_64(seed_value)
	b.put_u8(maxi(1, best_of))
	b.put_utf8_string(map_id)
	b.put_u8(roster.size())
	for slot in roster:
		b.put_u8(int(slot.get("team", 0)))
		b.put_u8(1 if slot.get("bot", false) else 0)
		b.put_utf8_string(String(slot.get("character", "")))
		b.put_utf8_string(String(slot.get("name", "")))
	return b.data_array

static func decode_start(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	var seed_value := b.get_64()
	var best_of := b.get_u8()
	var map_id := b.get_utf8_string()
	var count := b.get_u8()
	var roster: Array = []
	for _i in count:
		var team := b.get_u8()
		var bot := b.get_u8() != 0
		var character := b.get_utf8_string()
		var name_v := b.get_utf8_string()
		roster.append({"team": team, "bot": bot, "character": character, "name": name_v})
	return {"seed": seed_value, "best_of": best_of, "map_id": map_id, "roster": roster}

# --- ADVANCE ---------------------------------------------------------------
## Host -> all clients: deterministically start the next round of the series. Carries the
## shared monotonic `net_round` tag (which round's inputs to consume), a `reset` flag for a
## rematch (reset the running score before this round), and the authoritative set of dropped
## player ids so every peer rebuilds the same human/bot assignment (a left peer becomes a bot
## for the round). Host-authoritative so all peers transition together with no runtime
## agreement and no desync.
static func encode_advance(net_round: int, reset: bool, dropped_ids: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.ADVANCE)
	b.put_u32(net_round)
	b.put_u8(1 if reset else 0)
	b.put_u8(dropped_ids.size())
	for pid in dropped_ids:
		b.put_u8(int(pid))
	return b.data_array

static func decode_advance(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	var net_round := b.get_u32()
	var reset := b.get_u8() != 0
	var count := b.get_u8()
	var dropped: Array = []
	for _i in count:
		dropped.append(b.get_u8())
	return {"net_round": net_round, "reset": reset, "dropped": dropped}

# --- REMATCH_REQUEST -------------------------------------------------------
## Client -> host: ask the host to start a rematch (host owns the deterministic transition,
## then broadcasts ADVANCE to every peer). No payload beyond the type tag.
static func encode_rematch_request() -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.REMATCH_REQUEST)
	return b.data_array

# --- ROOM_STATE ------------------------------------------------------------
## Host -> every client: the authoritative pre-match room snapshot. The host owns it and
## re-broadcasts on every change (join / leave / kick / character pick / ready toggle) so the
## room UI is identical on all peers. `players` is an ordered array of
## {id:int, name:String, character:String, ready:bool, host:bool}.
static func encode_room_state(room_name: String, best_of: int, map_id: String, players: Array) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.ROOM_STATE)
	b.put_utf8_string(room_name)
	b.put_u8(maxi(1, best_of))
	b.put_utf8_string(map_id)
	b.put_u8(players.size())
	for p in players:
		b.put_u8(int(p.get("id", 0)))
		b.put_utf8_string(String(p.get("name", "")))
		b.put_utf8_string(String(p.get("character", "")))
		b.put_u8(1 if p.get("ready", false) else 0)
		b.put_u8(1 if p.get("host", false) else 0)
	return b.data_array

static func decode_room_state(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	var room_name := b.get_utf8_string()
	var best_of := b.get_u8()
	var map_id := b.get_utf8_string()
	var count := b.get_u8()
	var players: Array = []
	for _i in count:
		var pid := b.get_u8()
		var name_v := b.get_utf8_string()
		var character := b.get_utf8_string()
		var ready := b.get_u8() != 0
		var host := b.get_u8() != 0
		players.append({"id": pid, "name": name_v, "character": character, "ready": ready, "host": host})
	return {"room_name": room_name, "best_of": best_of, "map_id": map_id, "players": players}

# --- SET_CHARACTER / SET_READY ---------------------------------------------
## Client -> host: I chose this character / I am (not) ready. The host resolves which player
## sent it from the ENet peer mapping, updates the room and re-broadcasts ROOM_STATE.
static func encode_set_character(character: String) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.SET_CHARACTER)
	b.put_utf8_string(character)
	return b.data_array

static func decode_set_character(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"character": b.get_utf8_string()}

static func encode_set_ready(ready: bool) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.SET_READY)
	b.put_u8(1 if ready else 0)
	return b.data_array

static func decode_set_ready(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"ready": b.get_u8() != 0}

# --- KICK ------------------------------------------------------------------
## Host -> a specific client: the host removed you from the room. Carries the kicked player id
## so the client can confirm it is the target before leaving (and show the right message).
static func encode_kick(player_id: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.KICK)
	b.put_u8(player_id)
	return b.data_array

static func decode_kick(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"player_id": b.get_u8()}

# --- DROP ------------------------------------------------------------------
## Host -> remaining clients: a player left the match. Carries only the player id; every peer
## latches that player to predicted input from its own last-received frame (identical on all
## peers because that frame and the repeat-last prediction are the same everywhere), so the
## match keeps advancing without stalling and without diverging.
static func encode_drop(player_id: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.DROP)
	b.put_u8(player_id)
	return b.data_array

static func decode_drop(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"player_id": b.get_u8()}

# --- INPUT -----------------------------------------------------------------
## `round_index` namespaces an input to one round of the series so a peer that has already
## auto-advanced cannot have its next round's inputs misapplied to a slower peer's still-running
## round (each NetMatch consumes only inputs tagged for its own round).
static func encode_input(tick: int, player_id: int, dir: Vector2i, place: bool, round_index: int = 0, skill: bool = false) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.INPUT)
	b.put_u32(tick)
	b.put_u8(player_id)
	b.put_8(clampi(dir.x, -1, 1))
	b.put_8(clampi(dir.y, -1, 1))
	b.put_u8((1 if place else 0) | (2 if skill else 0))
	b.put_u32(round_index)
	return b.data_array

static func decode_input(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	var tick := b.get_u32()
	var pid := b.get_u8()
	var dx := b.get_8()
	var dy := b.get_8()
	var flags := b.get_u8()
	var round_index := b.get_u32()
	return {"tick": tick, "player_id": pid, "dir": Vector2i(dx, dy), "place": (flags & 1) != 0, "skill": (flags & 2) != 0, "round": round_index}

# --- PING / PONG -----------------------------------------------------------
static func encode_ping(ping_id: int, send_usec: int) -> PackedByteArray:
	return _ping_like(Msg.PING, ping_id, send_usec)

static func encode_pong(ping_id: int, send_usec: int) -> PackedByteArray:
	return _ping_like(Msg.PONG, ping_id, send_usec)

static func decode_ping(data: PackedByteArray) -> Dictionary:
	var b := _reader(data)
	b.get_u8()
	return {"ping_id": b.get_u32(), "send_usec": b.get_64()}

# --- BEACON (LAN discovery over UDP) ---------------------------------------
static func encode_beacon(port: int, host_name: String, player_count: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(Msg.BEACON)
	b.put_u32(MAGIC)
	b.put_u8(NetBudget.PROTOCOL_VERSION)
	b.put_u16(port)
	b.put_u8(player_count)
	b.put_utf8_string(host_name)
	return b.data_array

static func decode_beacon(data: PackedByteArray) -> Dictionary:
	## Returns {} for anything that is not a valid, version-matched beacon.
	if data.size() < 8 or data[0] != Msg.BEACON:
		return {}
	var b := _reader(data)
	b.get_u8()
	if b.get_u32() != MAGIC:
		return {}
	var version := b.get_u8()
	if version != NetBudget.PROTOCOL_VERSION:
		return {}
	return {
		"version": version,
		"port": b.get_u16(),
		"player_count": b.get_u8(),
		"name": b.get_utf8_string(),
	}

# --- helpers ---------------------------------------------------------------
static func message_type(data: PackedByteArray) -> int:
	return data[0] if data.size() > 0 else 0

static func _ping_like(tag: int, ping_id: int, send_usec: int) -> PackedByteArray:
	var b := StreamPeerBuffer.new()
	b.put_u8(tag)
	b.put_u32(ping_id)
	b.put_64(send_usec)
	return b.data_array

static func _reader(data: PackedByteArray) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.data_array = data
	b.seek(0)
	return b
