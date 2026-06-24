class_name Fixed
extends RefCounted
## Q16.16 fixed-point integer math (acceptance criterion 1: 고정소수점).
## All simulated continuous quantities use these integer-only helpers so arithmetic is
## bit-identical on every platform. GDScript int is 64-bit two's-complement everywhere,
## so there is no float in any value that feeds the deterministic simulation or its hash.

const SHIFT: int = 16
const ONE: int = 1 << SHIFT          # 65536 == 1.0
const HALF: int = ONE >> 1

static func from_int(n: int) -> int:
	return n << SHIFT

static func to_int(f: int) -> int:
	## Floor toward negative infinity (arithmetic shift), matching across platforms.
	return f >> SHIFT

static func round_to_int(f: int) -> int:
	return (f + HALF) >> SHIFT

static func mul(a: int, b: int) -> int:
	return (a * b) >> SHIFT

static func div(a: int, b: int) -> int:
	return (a << SHIFT) / b

## Build a fixed value from a rational num/den (e.g. 4 cells / 60 ticks) without floats.
static func ratio(num: int, den: int) -> int:
	return (num << SHIFT) / den

## Float conversion is ONLY for the rendering/HUD boundary — never feed the result back
## into simulation state or hashing.
static func to_float(f: int) -> float:
	return float(f) / float(ONE)
