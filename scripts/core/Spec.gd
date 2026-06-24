class_name Spec
extends RefCounted
## Gameplay rules SSOT (acceptance criterion 2).
## All balloon timers, explosion ranges and power-up rules are defined here so they
## are reproducible and testable in isolation from rendering.

## --- Tiles ---
enum Tile { FLOOR, HARD_WALL, SOFT_BLOCK }

## --- Power-ups ---
enum PowerUp { NONE, BALLOON, RANGE, SPEED }

## --- Simulation ---
## The deterministic simulation advances in whole fixed ticks. TICK_DELTA exists only as
## a display/convenience constant; no simulated value is derived from it (criterion 1).
const TICK_RATE: int = 60
const TICK_DELTA: float = 1.0 / float(TICK_RATE)

## All durations are expressed in integer ticks so countdowns are exact and reproducible.
## --- Balloon / explosion ---
const BALLOON_FUSE_TICKS: int = 180      # 3.0 s before a balloon explodes
const EXPLOSION_TICKS: int = 30          # 0.5 s an explosion cell stays lethal
const START_RANGE: int = 1               # explosion reach in cells (each direction)
const MAX_RANGE: int = 8
const START_MAX_BALLOONS: int = 1        # simultaneous balloons a player may hold
const MAX_BALLOONS: int = 8

## --- Bubble (trap) ---
const BUBBLE_TICKS: int = 300            # 5.0 s before a trapped player is eliminated
const RESCUE_INVULN_TICKS: int = 60      # 1.0 s invulnerability after being rescued

## --- Round time limit (bounded, reproducible round length) ---
## A round must reach a definite end within a deterministic number of whole ticks so two
## cautious players can never stall the party. Expressed purely in integer ticks (no floats)
## so the countdown is exact and unit-testable headlessly. If the hard cap is reached with more
## than one team still alive, the round resolves to a draw (no series point).
const ROUND_LIMIT_TICKS: int = 5400          # 90.0 s hard cap — the round always resolves by here

## --- Movement (Q16.16 fixed-point cells/second; Fixed.ONE == 1 cell/s) ---
const START_SPEED_FP: int = 4 << 16      # 4.0 cells per second
const SPEED_STEP_FP: int = 1 << 16       # +1.0 cells per second per power-up
const MAX_SPEED_FP: int = 8 << 16        # 8.0 cells per second

## --- Power-up drop (integer odds; no floats) ---
const POWERUP_DROP_NUM: int = 45         # 45/100 chance a soft block drops a power-up
const POWERUP_DROP_DEN: int = 100

## --- Players ---
const MIN_PLAYERS: int = 4
const MAX_PLAYERS: int = 8

## --- Series (best-of-N rounds) ---
## A match is a series of rounds; the first team to win a majority clinches. The default
## is a short, party-friendly series; `MatchSeries` derives the wins-needed from this.
const SERIES_BEST_OF_DEFAULT: int = 3

static func clamp_range(v: int) -> int:
	return clampi(v, START_RANGE, MAX_RANGE)

static func clamp_balloons(v: int) -> int:
	return clampi(v, START_MAX_BALLOONS, MAX_BALLOONS)

static func clamp_speed(v: int) -> int:
	## Operates on Q16.16 fixed-point cells/second.
	return clampi(v, START_SPEED_FP, MAX_SPEED_FP)
