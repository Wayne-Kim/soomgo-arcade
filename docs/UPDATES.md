# Auto-updates (Sparkle, macOS)

The macOS build self-updates with [Sparkle](https://sparkle-project.org/). This is **direct
distribution only** — Sparkle cannot be used for a Mac App Store build (the store handles updates).

## How it's wired

| Piece | Location | Role |
|---|---|---|
| `UpdateManager` autoload | `scripts/updates/UpdateManager.gd` | Platform-safe facade: starts a background check on launch, exposes `check_for_updates()`, `is_supported()`. No-op on non-macOS / editor / headless / before the native binary exists. |
| `SparkleUpdater` GDExtension | `addons/sparkle_update/` | Obj-C++ wrapper over Sparkle's `SPUStandardUpdaterController`. |
| "Check for updates" button | Lobby | Shown only when `UpdateManager.is_supported()` (real signed macOS build). |
| Release pipeline | `tools/macos_release.sh` | export → embed → sign → notarize → staple → EdDSA-sign → appcast. |
| Info.plist keys / entitlements / appcast sample | `tools/sparkle/` | Config templates. |

Because everything funnels through `UpdateManager` with runtime capability checks, the game, the
editor and the headless test suites run unchanged whether or not the native extension is present.

## One-time setup

1. **Build the GDExtension** — see `addons/sparkle_update/README.md` (needs godot-cpp +
   `Sparkle.framework` on macOS), then rename `sparkle_update.gdextension.disabled` →
   `sparkle_update.gdextension`.
2. **Generate EdDSA keys** with Sparkle's tools and keep the private key secret:
   ```sh
   ./bin/generate_keys            # prints the PUBLIC key, stores the private key in the keychain
   ./bin/generate_keys -x sparkle_private.key   # export the private key for CI
   ```
3. **Add Info.plist keys** to the Godot macOS export preset (Application → Additional Plist
   Content): paste the entries from `tools/sparkle/Info.plist.additions.plist`, filling in your
   `SUFeedURL` (HTTPS) and the `SUPublicEDKey` from step 2.
4. **Signing identity**: a "Developer ID Application" certificate in your keychain and a
   `notarytool` credentials profile (`xcrun notarytool store-credentials`).

## Cutting a release

Bump the export preset's **Version** (CFBundleShortVersionString) and **Build**
(CFBundleVersion — Sparkle compares this to decide "is newer"), then:

```sh
export GODOT=/Applications/Godot.app/Contents/MacOS/Godot
export EXPORT_PRESET="macOS"
export SIGN_IDENTITY="Developer ID Application: You (TEAMID)"
export SPARKLE_BIN="/path/to/Sparkle/bin"          # has sign_update, generate_appcast + Sparkle.framework
export NOTARY_PROFILE="ac-notary"
export SPARKLE_PRIVATE_KEY="/path/to/sparkle_private.key"
export UPDATES_DIR="/path/to/your/feed-root"        # holds the .zip archives + appcast.xml

./tools/macos_release.sh
```

Then publish the contents of `$UPDATES_DIR` (the new `.zip` and the regenerated `appcast.xml`) to
the host behind your `SUFeedURL`, over HTTPS.

## Gotchas (verified against Sparkle docs)

- **Build number must increment** every release or users see "You're up to date".
- **Sign helper tools individually, never `codesign --deep`**; order is XPC services → Autoupdate
  → framework → app. `tools/macos_release.sh` does this.
- **Notarize + staple** the app; serve the appcast over **HTTPS**.
- The `SUPublicEDKey` must actually end up in the built app's Info.plist (verify with
  `codesign -d --entitlements - "App.app"` / `plutil -p App.app/Contents/Info.plist`).
- Keep the EdDSA **private** key safe; only the **public** key goes in Info.plist.

Sources: <https://sparkle-project.org/documentation/>,
<https://sparkle-project.org/documentation/eddsa-migration/>.
