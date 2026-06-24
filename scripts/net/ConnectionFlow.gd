class_name ConnectionFlow
extends RefCounted
## Connection/fallback decision state machine (acceptance criterion 1).
##
## Goal: "if on the same wireless network, auto-connect via ENet; if not possible, fall
## back to Bluetooth/hotspot guidance." This class is the deterministic brain the Connect
## UI binds to — it owns NO sockets and NO timers, so it can be unit tested with scripted
## events. The UI feeds it discovery results and transport callbacks; it returns the state
## and the recommended next action.
##
## Roles of each transport (documented here as the single source of truth):
##   ENet (LAN/Wi-Fi/Wi-Fi Direct) : the realtime data channel.
##   LAN UDP beacon                : same-network host discovery -> drives auto-connect.
##   Bluetooth / hotspot           : discovery / pairing / invite / *fallback* to get the
##                                   devices onto one wireless network. NEVER the data path.

enum State {
	IDLE,            # nothing started yet
	SCANNING,        # listening for same-network hosts (and offering BT/invite)
	CONNECTING,      # a same-network host was found -> auto-connecting via ENet
	CONNECTED,       # ENet session established
	FALLBACK,        # no same-network host found/reachable -> show BT/hotspot guidance
	ERROR,           # a connection attempt failed
}

## Recommended fallback channel surfaced to the user in the FALLBACK state.
enum Fallback { NONE, BLUETOOTH, HOTSPOT }

var state: int = State.IDLE
var fallback: int = Fallback.NONE
var error_key: String = ""
## The host endpoint chosen for auto-connect, when in CONNECTING/CONNECTED.
var target: Dictionary = {}
## Discovered same-network hosts: [{address, port, name, player_count}].
var hosts: Array = []

## Begin scanning for same-network hosts. Caller should also start the LAN beacon listener
## and (on supported platforms) Bluetooth discovery for the invite/fallback path.
func begin_scan() -> void:
	state = State.SCANNING
	fallback = Fallback.NONE
	error_key = ""
	target = {}
	hosts.clear()

## Feed in the current set of discovered same-network hosts (from LanBeacon.poll()).
## If at least one reachable host exists while scanning, auto-connect to the first one.
func on_hosts_discovered(discovered: Array) -> void:
	hosts = discovered.duplicate()
	if state == State.SCANNING and not hosts.is_empty():
		target = hosts[0]
		state = State.CONNECTING

## No same-network host appeared within the scan window -> recommend a fallback path.
## Wi-Fi hotspot is recommended first (higher bandwidth, more devices than a piconet);
## Bluetooth pairing is the easy-proximity alternative.
func on_scan_timeout() -> void:
	if state == State.SCANNING:
		state = State.FALLBACK
		fallback = Fallback.HOTSPOT if hosts.is_empty() else Fallback.NONE

## ENet transport reported a successful connection.
func on_enet_connected() -> void:
	state = State.CONNECTED

## ENet transport failed (timeout/refused). Offer Bluetooth as the proximity fallback.
func on_enet_failed(reason_key: String = "NET_ERR_CONNECT_FAILED") -> void:
	state = State.ERROR
	error_key = reason_key
	fallback = Fallback.BLUETOOTH

## User picked a fallback option (paired over Bluetooth / enabled a hotspot). Once the
## shared network is up we re-scan, which will discover the host and auto-connect.
func on_fallback_network_ready() -> void:
	begin_scan()

func retry() -> void:
	begin_scan()

func reset() -> void:
	state = State.IDLE
	fallback = Fallback.NONE
	error_key = ""
	target = {}
	hosts.clear()

func is_busy() -> bool:
	return state == State.SCANNING or state == State.CONNECTING
