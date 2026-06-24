# Soomgo Arcade

A grid-based, water-balloon arena built with **Godot 4.6**. Play **one player per device**
against bots locally, or against other devices online. Place water balloons, trigger chain
explosions, trap opponents in bubbles, rescue teammates, grab power-ups, and be the last
team standing.

## Run

Open the project in Godot 4.6+ and press Play, or:

```sh
/Applications/Godot.app/Contents/MacOS/Godot --path .
```

**Controls.** One local human plays per device (a single keyboard scheme); every other
lobby slot is a **bot** or an **online** peer. Each player also has a character **unique
skill** on a dedicated key (see [`docs/skills.md`](docs/skills.md)):

| Move | Drop balloon | Skill |
| --- | --- | --- |
| `←` `↑` `↓` `→` | `Space` | `Left Shift` |

`Esc` returns to the lobby. The in-game HUD shows which slot the local player drives (tinted
with that player's board colour).

## Gameplay rules (single source of truth: `scripts/core/Spec.gd`)

| Rule | Value |
| --- | --- |
| Balloon fuse | 3.0 s |
| Explosion lifetime | 0.5 s |
| Start / max range | 1 / 8 cells |
| Start / max balloons | 1 / 8 |
| Bubble (trap) timer | 5.0 s |
| Rescue invulnerability | 1.0 s |
| Move speed start / max | 4 / 8 cells per second |
| Power-up drop chance | 45% |

- A balloon explodes in a `+` shape up to the owner's **range**, stopping at hard walls
  and destroying the first soft block it hits. Balloons caught in a blast **chain-detonate**.
- A player caught by an explosion is **trapped in a bubble**. A **teammate** touching the
  bubble **rescues** them; an **enemy** touching it **pops/eliminates** them; if the timer
  expires, the trapped player **drowns** (eliminated).
- Soft blocks may reveal a power-up: **+balloon**, **+range**, or **+speed** (all capped).
- The round ends when **one team (or fewer) has living players**.
- A match is a **best-of-N series** (default `Spec.SERIES_BEST_OF_DEFAULT`). Each round
  winner increments that team's tally; the next round **auto-starts with the committed
  roster and a fresh seed** (eliminated players return), so the HUD shows the real
  *Round X of Y* and a colour-by-team running score. The first team to a majority clinches
  — no dead rounds — and the final screen offers **Rematch** (same roster, reset score) or
  **Back to lobby**. A drawn round (no survivors) awards no point but still counts toward
  the series. Series rules live in `scripts/core/MatchSeries.gd`.

## Architecture

The game logic is a **deterministic, scene-tree-free simulation** (`scripts/core/`),
separate from rendering/UI so it can be unit-tested headlessly:

- `Spec` — all tunable rules. `Arena` — grid + blocks + power-ups. `PlayerState`,
  `Balloon`, `Bubble` — entity state. `Simulation` — fixed-step `step()` driving
  movement, fuses, chain explosions, trapping, rescue and round resolution (emits signals).
  `MatchSeries` — scene-tree-free best-of-N series state (round tally, clinch/draw, rematch).
- `scripts/ui/` — `Lobby.gd`, `Game.gd` (renderer + HUD), `Connect.gd` (connection/
  pairing screen), `Strings.gd` (i18n), `A11y.gd`.
- `scripts/core/Characters.gd` — roster SSOT for the selectable **Soomgo master
  ("고수")** characters (job motif, localised name/personality, starting stat profile).
  The chosen character is shown in the lobby picker **and the in-game HUD** (`Game.gd`).
  Identity spec + dissimilarity check: [`docs/characters.md`](docs/characters.md); overall
  brand direction + originality checklist: [`docs/BRAND.md`](docs/BRAND.md).
- `scripts/net/` — hybrid nearby multiplayer: realtime data over **Godot ENet**
  (deterministic lockstep) with **Bluetooth/hotspot used only for discovery, pairing and
  fallback**. See [docs/NETWORKING.md](docs/NETWORKING.md).

## Nearby multiplayer (hybrid networking)

Realtime input is carried over **Godot ENet** (desktop LAN/Wi‑Fi, mobile Wi‑Fi Direct) as
**deterministic lockstep** — it reuses the deterministic core simulation, so peers share a
seed and relay per-tick inputs. **Bluetooth is never the data channel**; it (and a Wi‑Fi
hotspot) is the discovery/pairing/fallback path to get devices onto one network.

- **Same wireless network → auto-connect.** A LAN UDP beacon advertises the host's ENet
  endpoint; the Connect screen discovers it and connects with no manual IP entry.
- **Otherwise → fallback guidance.** The Connect screen recommends a Wi‑Fi hotspot or
  Bluetooth pairing, then re-scans and auto-connects.
- **Start a match.** Once peers have joined, the host presses **Start match**: all peers jump
  into the same deterministic game off a shared seed, each driving its own assigned player while
  empty slots run bots. A dropped peer is predicted so the round resolves without a hang/desync.
- **Latency budget:** target input round-trip **≤ 100 ms** for an 8-player session
  (`scripts/net/NetBudget.gd`), measured by `tests/net_loopback.gd`.

Open the Connect screen from the Lobby's **Connect players** button. Full design,
budget breakdown and transport roles are documented in
[docs/NETWORKING.md](docs/NETWORKING.md).

## Deterministic lockstep netcode (`scripts/net/`)

The simulation is **bit-deterministic** so a grid water-balloon battle never desyncs across
clients. The netcode layer is headless (no UI surface) and rollback-ready:

- **Fixed-point + integer time** — all continuous state is integer: timers count whole
  **ticks**, sub-cell movement and speed use **Q16.16** fixed-point (`Fixed`). The
  simulation has **zero floats**, so identical inputs produce byte-identical state on every
  platform. `step()` always advances exactly one fixed tick (frame timing never leaks in).
- **Seeded PRNG** — `DetRng` is an integer-only splitmix64; arena generation and bots draw
  from it, and its state serializes with the snapshot for reproducible draws.
- **Lockstep + input delay** — `LockstepSession` advances a frame only when every player's
  input is present. Local inputs are queued `input_delay` frames ahead (`InputBuffer`,
  `InputCmd`) to absorb wireless latency. A lost packet stalls at most `max_stall_frames`,
  then **recovers** by predicting the last input — never a permanent freeze.
- **Per-frame state hash** — `LockstepSession` records a 64-bit FNV-1a hash (`StateHash`) of
  each frame's snapshot. `DesyncDetector` compares peers' hashes and pinpoints the **exact
  frame** where states first diverged (diagnostic logging).
- **One-shot serialize/restore** — `Simulation.write_snapshot()` / `read_snapshot()` save and
  restore the whole game state (tick, RNG, arena, entities) in a single `PackedByteArray`,
  the foundation for future **rollback**.

## UI / accessibility

This is a greenfield repo with **no design SSOT** (no design tokens, theme docs, or
locale catalog). Per that constraint, the UI applies **universal UX + accessibility**
only and does **not** invent a brand palette or a fixed locale set:

- **All user-facing strings are externalised** for i18n via `localization/ui_strings.csv`
  → `tr("KEY")`. English (`en`) and Korean (`ko`) columns ship today; further locales are
  added as extra CSV columns with no code changes. Korean is auto-selected when the device
  locale is Korean (`Strings.set_language` / `toggle_language` for an explicit choice), with
  English as the fallback (`internationalization/locale/fallback`).
- **UI states covered:** empty (no players), loading (entering a match), error (invalid
  roster), disabled (Start until valid / Add when full), and a **visible focus ring** on
  every interactive control (`assets/theme.tres`).
- **Accessibility:** every interactive control has an accessible label/description
  (`A11y.gd`), focusable controls, and a theme tuned for **high text/background contrast**.

## Tests

Headless, deterministic acceptance + smoke tests:

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path . --script res://tests/run_tests.gd      # core rules + AI round
"$GODOT" --headless --path . --script res://tests/run_net_tests.gd  # deterministic lockstep netcode
"$GODOT" --headless --path . --script res://tests/net_loopback.gd   # real ENet RTT + lockstep parity
"$GODOT" --headless --path . --script res://tests/smoke_ui.gd       # lobby/game/connect scene smoke
```

`run_tests.gd` covers arena generation, balloon timer/range, chain reactions, power-ups
and caps, trap→rescue, trap→drown, an 8-player win resolution, and a fully **autonomous
8-bot round** (place→explode→trap→eliminate).

`run_net_tests.gd` covers the four deterministic-netcode criteria: (1) identical input
sequences yield bit-identical state across two clients (and no float drift), (2) the
input-delay buffer absorbs latency while packet loss recovers within a bounded stall,
(3) per-frame hash exchange identifies the exact desync frame, and (4) snapshot
save/restore reproduces subsequent play bit-for-bit (rollback-ready).

`net_loopback.gd` measures a real ENet round-trip against the latency budget and checks
the transport-level lockstep parity; `smoke_ui.gd` also drives every Connect-screen state
(scanning / empty / loading / error / fallback).

> On a fresh checkout, build the global class cache once before running a script directly:
> `"$GODOT" --headless --path . --editor --quit` (the `.godot` cache is git-ignored).
