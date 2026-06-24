class_name NetBudget
extends RefCounted
## Realtime networking budget SSOT (acceptance criterion 2).
##
## TRANSPORT: realtime input is carried over Godot ENet (desktop LAN/Wi-Fi, mobile
## Wi-Fi Direct), NOT over Bluetooth. Bluetooth is discovery/pairing/fallback only.
##
## NETCODE MODEL: deterministic lockstep. The simulation in scripts/core/ is already
## deterministic (fixed TICK_DELTA + seeded RNG), so networked play = share the seed +
## relay each tick's inputs. Every peer runs an identical step(). A small fixed input
## delay masks one-way network latency without rollback.
##
## LATENCY BUDGET (8-player session, "fast arcade" target).
## Budget for a full input round-trip (local input sampled -> reaches host -> authoritative
## input echoed back to peers) on a same-network LAN/Wi-Fi link:
##
##   input sampling        : ~1 tick   (~16.7 ms)
##   one-way wire (Wi-Fi)  : ~10-25 ms
##   host relay + return   : ~10-25 ms
##   ----------------------------------------
##   TARGET round-trip     : <= 100 ms  (INPUT_DELAY_TICKS gives headroom below this)
##
## At 100 ms the input-delay scheme keeps motion responsive for a grid arcade while
## absorbing jitter across 8 peers. Above the WARN threshold the UI should surface a
## connection-quality hint; above TARGET the link is over budget for fast play.

const PROTOCOL_VERSION: int = 3

## Maximum simultaneous networked players (mirrors Spec.MAX_PLAYERS; kept here so the
## net layer has no hard dependency on gameplay caps beyond this single number).
const MAX_PLAYERS: int = 8

## Round-trip latency budget, in milliseconds.
const TARGET_RTT_MS: float = 100.0   # at/under this == acceptable for fast arcade play
const WARN_RTT_MS: float = 60.0      # above this == surface a quality hint, still playable

## Fixed input delay (in simulation ticks) applied before a local input is executed, so
## remote inputs for the same tick have time to arrive. 3 ticks at 60 Hz ~= 50 ms.
const INPUT_DELAY_TICKS: int = 3

## Default ENet host port and the LAN discovery beacon port.
const DEFAULT_PORT: int = 27015
const BEACON_PORT: int = 27016

enum Quality { GOOD, WARN, OVER }

static func input_delay_ms() -> float:
	return float(INPUT_DELAY_TICKS) * Spec.TICK_DELTA * 1000.0

static func within_budget(rtt_ms: float) -> bool:
	return rtt_ms <= TARGET_RTT_MS

static func classify(rtt_ms: float) -> int:
	if rtt_ms > TARGET_RTT_MS:
		return Quality.OVER
	if rtt_ms > WARN_RTT_MS:
		return Quality.WARN
	return Quality.GOOD
