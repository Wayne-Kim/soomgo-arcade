class_name MatchSeries
extends RefCounted
## A match = best-of-N rounds played by a single committed roster. Tracks the current
## round number, a per-team running win tally, and decides when the series is over and
## who won — all deterministically, with no UI/scene-tree dependencies so it is unit
## testable in isolation. The Game scene rebuilds a Simulation per round from this state
## (same roster, fresh per-round seed), so eliminated players return next round.

var roster: Array = []                 # committed player defs, reused for every round
var arena_w: int = 15
var arena_h: int = 13
var map_id: String = Maps.DEFAULT_ID   # arena layout, identical for every round of the series
var base_seed: int = 0                  # per-round seed = base_seed + round_index
var best_of: int = Spec.SERIES_BEST_OF_DEFAULT

var round_index: int = 0                # 0-based index of the round currently in play
var team_wins: Dictionary = {}          # team_id -> rounds won (all roster teams present)
var finished: bool = false
## Series outcome: -2 = undecided, -1 = drawn series, >= 0 = winning team id.
var series_winner_team: int = -2

func _init(roster_defs: Array = [], best_of_rounds: int = Spec.SERIES_BEST_OF_DEFAULT,
		seed_value: int = 0, w: int = 15, h: int = 13, p_map_id: String = Maps.DEFAULT_ID) -> void:
	roster = roster_defs.duplicate(true)
	best_of = maxi(1, best_of_rounds)
	base_seed = seed_value
	arena_w = w
	arena_h = h
	map_id = Maps.sanitize(p_map_id)
	reset()

## Rounds a single team must win to clinch the series (a majority of best_of).
func rounds_needed() -> int:
	return best_of / 2 + 1

## 1-based number of the round currently in play (HUD: "Round X of Y").
func current_round_number() -> int:
	return round_index + 1

## Deterministic, distinct seed for each round so every round plays a fresh arena while
## the series stays reproducible from base_seed.
func seed_for_round() -> int:
	return base_seed + round_index

## Record the result of the round that just ended and advance the series.
## winner_team < 0 means a drawn round (no survivors): no point is awarded, but the round
## still counts toward best_of so the series always terminates deterministically.
func record_round(winner_team: int) -> void:
	if finished:
		return
	if winner_team >= 0:
		team_wins[winner_team] = int(team_wins.get(winner_team, 0)) + 1
	round_index += 1
	_evaluate()

func _evaluate() -> void:
	# Early clinch: a team reached the needed wins -> end immediately, no dead rounds.
	var need := rounds_needed()
	for team_id in _sorted_teams():
		if int(team_wins[team_id]) >= need:
			finished = true
			series_winner_team = team_id
			return
	# All scheduled rounds played without a clinch (possible with draws / many teams):
	# decide by the highest tally, or declare a drawn series if the lead is tied.
	if round_index >= best_of:
		finished = true
		series_winner_team = _leader_or_draw()

func _leader_or_draw() -> int:
	var best := -1
	var best_team := -1
	var tied := false
	for team_id in _sorted_teams():
		var w := int(team_wins[team_id])
		if w > best:
			best = w
			best_team = team_id
			tied = false
		elif w == best:
			tied = true
	if best <= 0 or tied:
		return -1
	return best_team

## Total rounds either side has won so far (drawn rounds contribute to neither).
func total_decided_rounds() -> int:
	var sum := 0
	for team_id in team_wins:
		sum += int(team_wins[team_id])
	return sum

## Restart the same roster for a fresh series with a reset score (Rematch).
func reset() -> void:
	round_index = 0
	finished = false
	series_winner_team = -2
	team_wins.clear()
	for def in roster:
		var team_id: int = int(def.get("team", 0))
		if not team_wins.has(team_id):
			team_wins[team_id] = 0

## Teams in ascending id order for deterministic iteration/rendering.
func _sorted_teams() -> Array:
	var teams: Array = team_wins.keys()
	teams.sort()
	return teams

func teams() -> Array:
	return _sorted_teams()

func wins_for(team_id: int) -> int:
	return int(team_wins.get(team_id, 0))
