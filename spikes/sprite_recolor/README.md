# `spikes/sprite_recolor/` — design-validation spike (one-time, non-shipping)

A throwaway spike that validates the **AI-sprite recolour recipe** (greyscale base + team-tint
mask → runtime recolour) end-to-end on **one** character, **Tote**, before committing the
whole roster. It produces a **go/no-go recommendation**, not launch assets.

- **The recommendation:** [`REPORT.md`](REPORT.md) ← read this.
- **The harness:** [`run_spike.gd`](run_spike.gd) — headless Godot script; 22 automated
  acceptance checks bound to the **live** game constants (`Game.CELL`, `Game.TEAM_COLORS`, the
  real `TeamMarker` geometry). Exits 0 iff all pass.
- **Evidence:** `out/` (git-ignored; regenerated) — `proofsheet.png` + `metrics.json`.

This directory is **isolated**: it is wired into no scene, autoload, or `project.godot`, adds
no user-facing strings, and touches no file under `scripts/`, `scenes/`, `assets/`, or
`localization/`. Deleting `spikes/` removes the spike with zero impact on the game.

```sh
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
"$GODOT" --headless --path . --editor --quit                                    # build class cache once
"$GODOT" --headless --path . --script res://spikes/sprite_recolor/run_spike.gd  # -> out/, 22/22 PASS
```
