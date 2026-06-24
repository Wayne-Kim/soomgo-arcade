class_name DetRng
extends RefCounted
## Deterministic seeded PRNG (acceptance criterion 1: 시드 PRNG).
## splitmix64 over GDScript's 64-bit two's-complement int — integer-only, so the exact
## same sequence is produced on every platform. State is a single int, trivially
## serialized/restored so RNG draws stay reproducible across snapshots (rollback-ready).

const GOLDEN: int = -7046029254386353131   # 0x9E3779B97F4A7C15
const M1: int = -4658895280553007687       # 0xBF58476D1CE4E5B9
const M2: int = -7723592293110705685       # 0x94D049BB133111EB

var state: int = 0

func _init(seed_value: int = 0) -> void:
	state = seed_value

func clone() -> DetRng:
	var r := DetRng.new(0)
	r.state = state
	return r

## Next raw 64-bit value (may be negative; callers treat it as an opaque bit pattern).
func next_u64() -> int:
	state = state + GOLDEN
	var z: int = state
	z = (z ^ (_lsr(z, 30))) * M1
	z = (z ^ (_lsr(z, 27))) * M2
	return z ^ _lsr(z, 31)

## Uniform integer in [0, n) for n > 0. Modulo of the logically-unsigned draw — bias is
## negligible for the small ranges used here and, crucially, identical on every platform.
func below(n: int) -> int:
	if n <= 1:
		return 0
	var v: int = _lsr(next_u64(), 1)   # drop sign bit -> non-negative 63-bit value
	return v % n

## Uniform integer in [lo, hi] inclusive.
func range_int(lo: int, hi: int) -> int:
	if hi <= lo:
		return lo
	return lo + below(hi - lo + 1)

## True with probability num/den (integer-only; no floats).
func chance(num: int, den: int) -> bool:
	return below(den) < num

## Deterministic in-place Fisher-Yates shuffle (replaces Array.shuffle(), which uses the
## engine's global, non-reproducible RNG).
func shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = below(i + 1)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp

## Logical (unsigned) right shift, since GDScript's >> is arithmetic on negative ints.
static func _lsr(v: int, bits: int) -> int:
	if bits <= 0:
		return v
	# Mask off the sign bits that arithmetic shift would replicate.
	return (v >> bits) & ((1 << (64 - bits)) - 1)
