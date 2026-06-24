class_name MatchConfig
extends RefCounted
## Carries the chosen roster from the Lobby to the Game scene, plus the best-of-N series
## state so a match spans several rounds without returning to the lobby.

static var player_defs: Array = []
static var arena_w: int = 15
static var arena_h: int = 13
static var match_seed: int = 0
static var best_of: int = Spec.SERIES_BEST_OF_DEFAULT
static var map_id: String = Maps.DEFAULT_ID
## The live series shared across rounds. Built by the Lobby on Start; the Game scene reads
## the current round/seed from it and records each round's result back into it.
static var series: MatchSeries = null

static func is_valid() -> bool:
	var n: int = player_defs.size()
	return n >= Spec.MIN_PLAYERS and n <= Spec.MAX_PLAYERS

## Build a fresh series from the currently committed roster/seed and store it for the
## Game scene to consume.
static func start_series() -> MatchSeries:
	series = MatchSeries.new(player_defs, best_of, match_seed, arena_w, arena_h, map_id)
	return series
