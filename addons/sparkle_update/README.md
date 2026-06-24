# sparkle_update — Sparkle auto-update GDExtension (macOS)

Wraps [Sparkle](https://sparkle-project.org/)'s `SPUStandardUpdaterController` so a Godot 4 macOS
build can check for and install updates. GDScript uses it only through the `UpdateManager`
autoload (`scripts/updates/UpdateManager.gd`), which is a safe no-op when this extension (or a
non-macOS platform) is absent — so the editor, headless tests and other OSes are unaffected.

## Build (on macOS, with Xcode command-line tools)

```sh
cd addons/sparkle_update

# 1. godot-cpp matching the engine version (4.x). As a submodule or a plain clone:
git clone --branch 4.4 https://github.com/godotengine/godot-cpp

# 2. Sparkle.framework. Download a Sparkle 2.x release and put Sparkle.framework here, OR point
#    sparkle_dir at wherever it lives (a directory CONTAINING Sparkle.framework):
#    https://github.com/sparkle-project/Sparkle/releases
#    e.g. ./Sparkle/Sparkle.framework

# 3. Build both targets:
scons platform=macos target=template_debug   sparkle_dir="$PWD/Sparkle"
scons platform=macos target=template_release sparkle_dir="$PWD/Sparkle"

# 4. Activate the extension so Godot loads it:
mv sparkle_update.gdextension.disabled sparkle_update.gdextension
```

`bin/libsparkle_update.macos.template_{debug,release}.dylib` are produced.
`godot-cpp/`, `Sparkle/` and `bin/` are git-ignored (build inputs/outputs, not source).

## How it ties together

- `SparkleUpdater` (this extension) — registers a `SparkleUpdater` class with
  `start_automatic_checks()` and `check_for_updates()`.
- `UpdateManager` autoload — calls `start_automatic_checks()` on launch and exposes
  `check_for_updates()` to the UI; `is_supported()` gates any "Check for updates" button.
- Packaging (`tools/macos_release.sh`) — embeds `Sparkle.framework`, signs in the correct order,
  notarizes, staples, and generates the EdDSA-signed appcast.

See `docs/UPDATES.md` for the full release runbook (keys, Info.plist, appcast, CI).
