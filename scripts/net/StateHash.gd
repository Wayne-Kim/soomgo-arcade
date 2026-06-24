class_name StateHash
extends RefCounted
## 64-bit FNV-1a hash over a snapshot byte stream (acceptance criterion 3: 상태 해시).
## Clients exchange one hash per tick; the first tick whose hashes disagree is the desync
## frame. Integer-only and order-stable, so identical state always hashes identically.

const OFFSET: int = -3750763034362895579   # 0xCBF29CE484222325
const PRIME: int = 1099511628211           # 0x100000001B3

static func of_bytes(data: PackedByteArray) -> int:
	var h: int = OFFSET
	for b in data:
		h = (h ^ b) * PRIME            # 64-bit two's-complement wrap is deterministic
	return h

## Short hex form for logs (treats the 64-bit pattern as unsigned).
static func to_hex(h: int) -> String:
	return "%08x%08x" % [(h >> 32) & 0xFFFFFFFF, h & 0xFFFFFFFF]
