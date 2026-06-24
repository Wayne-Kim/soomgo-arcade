class_name NetContext
extends RefCounted
## Hand-off carrier for a live networked match across the Connect -> Game scene change.
##
## The Connect screen owns a NetSession; when the host starts (or a client receives START)
## the session must survive `change_scene_to_file` without being torn down. Storing it in
## these static fields keeps the RefCounted session alive across the scene swap (the same
## pattern MatchConfig uses to carry the roster). Game.gd reads it to drive networked play
## and calls `clear()` when the match ends.

static var session: NetSession = null
static var is_networked: bool = false
static var local_player_id: int = -1

static func arm(p_session: NetSession, p_local_player_id: int) -> void:
	session = p_session
	is_networked = true
	local_player_id = p_local_player_id

static func clear() -> void:
	if session != null:
		session.close()
	session = null
	is_networked = false
	local_player_id = -1
