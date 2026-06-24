class_name LanBeacon
extends RefCounted
## LAN discovery beacon. This is the mechanism behind "same wireless network -> auto ENet"
## (acceptance criterion 1): a host periodically broadcasts a small UDP beacon; clients on
## the same wireless network listen and learn the host's ENet endpoint, then auto-connect.
##
## This carries ONLY discovery metadata (host endpoint + player count) over UDP broadcast.
## It is NOT the realtime data channel and is unrelated to Bluetooth — Bluetooth provides
## the *alternative* discovery/pairing path when the two devices are not yet on one network.
##
## The wire format lives in NetProtocol (encode_beacon/decode_beacon) so it stays unit
## testable; this class only owns the socket lifecycle.

var _udp: PacketPeerUDP
var _is_host: bool = false
var _port: int = NetBudget.DEFAULT_PORT
var _host_name: String = ""
var _player_count: int = 0
var _beacon_port: int = NetBudget.BEACON_PORT

## host_name/host_port describe the ENet endpoint clients should connect back to.
func start_advertising(host_port: int, host_name: String, player_count: int, beacon_port: int = NetBudget.BEACON_PORT) -> int:
	stop()
	_is_host = true
	_port = host_port
	_host_name = host_name
	_player_count = player_count
	_beacon_port = beacon_port
	_udp = PacketPeerUDP.new()
	_udp.set_broadcast_enabled(true)
	_udp.set_dest_address("255.255.255.255", beacon_port)
	return OK

func update_player_count(player_count: int) -> void:
	_player_count = player_count

## Call periodically (e.g. once a second) while hosting to emit a beacon.
func broadcast_once() -> void:
	if not _is_host or _udp == null:
		return
	_udp.put_packet(NetProtocol.encode_beacon(_port, _host_name, _player_count))

func start_listening(beacon_port: int = NetBudget.BEACON_PORT) -> int:
	stop()
	_is_host = false
	_beacon_port = beacon_port
	_udp = PacketPeerUDP.new()
	return _udp.bind(beacon_port)

## Drain pending beacons. Returns an array of discovered hosts:
##   [{ "address": String, "port": int, "name": String, "player_count": int }]
func poll() -> Array:
	var found: Array = []
	if _udp == null or _is_host:
		return found
	while _udp.get_available_packet_count() > 0:
		var data := _udp.get_packet()
		var sender_ip := _udp.get_packet_ip()
		var info := NetProtocol.decode_beacon(data)
		if info.is_empty():
			continue
		found.append({
			"address": sender_ip,
			"port": info["port"],
			"name": info["name"],
			"player_count": info["player_count"],
		})
	return found

func stop() -> void:
	if _udp != null:
		_udp.close()
		_udp = null
