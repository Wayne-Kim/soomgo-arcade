class_name DesyncDetector
extends RefCounted
## Compares per-frame state hashes from peers and reports the FIRST frame whose hashes
## disagree (acceptance criterion 3: 데스싱크 발생 프레임 식별 + 진단 로깅). In a real match
## each client broadcasts hash_at(frame); this flags the exact frame where states diverged
## so the offending tick can be inspected.

var first_desync_frame: int = -1
var checked: int = 0

## Feed one frame's local + peer hash. Returns true while still in sync; logs and latches
## the first divergence.
func observe(frame: int, local_hash: int, peer_hash: int, peer_label: String = "peer") -> bool:
	checked += 1
	if local_hash != peer_hash:
		if first_desync_frame == -1 or frame < first_desync_frame:
			first_desync_frame = frame
			push_warning("[desync] frame %d: local=%s %s=%s" % [
				frame, StateHash.to_hex(local_hash), peer_label, StateHash.to_hex(peer_hash)])
		return false
	return true

## Bulk-compare two frame->hash maps. Returns the first divergent frame, or -1 if identical.
func compare(local: Dictionary, peer: Dictionary, peer_label: String = "peer") -> int:
	var frames: Array = local.keys()
	frames.sort()
	for f in frames:
		if peer.has(f):
			observe(f, local[f], peer[f], peer_label)
	return first_desync_frame

func in_sync() -> bool:
	return first_desync_frame == -1
