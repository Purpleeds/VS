# PitchLane

iOS singing game in the style of Trombone Champ. Notes scroll right-to-left on a pitch lane, a cursor
shows the pitch the player is singing in real time, and points are scored for matching it.
Roadmap: `docs/PLAN.md`.

## Environment (non-negotiable)

- Developer machine: **Windows PC, WSL Ubuntu, Linux Swift toolchain + xtool**. **No Mac, no Xcode.**
  Never suggest Xcode, `xcodebuild`, `.xcodeproj`, simulators, or anything that needs macOS.
- **Swift Package Manager only.** No CocoaPods, no Carthage.
- **No `Assets.xcassets`.** Colours are defined in code (`Theme.swift`). SF Symbols are fine.
- **No SwiftData**, and no other macros that xtool's OpenAppleMacros do not implement. Prefer plain
  `ObservableObject` / `@Published` over `@Observable`. When unsure whether a macro is supported, don't use it.
- **Persistence = Codable JSON files in Application Support** (`Application Support/PitchLane/...`), via
  `JSONFileStore` in Core. No SwiftData / Core Data / UserDefaults for real data.
- **Target iOS 26, iPhone only** (`UIDeviceFamily` = [1]).
- **Orientation:** the game screen is landscape (`.lockOrientation(.landscape)`); every other screen supports
  portrait and landscape. Info.plist allows portrait + both landscapes; `OrientationLock` narrows per screen.
- The phone is **not connected to WSL**. Debugging happens through AppLog (below), not a debugger or Console.app.
- The user installs with **iloader (Import IPA) using a free Apple ID**. **Never hardcode the bundle ID**;
  use `Bundle.main.bundleIdentifier`. `xtool.yml` deliberately has no `bundleID`.

## Targets

| Target | Kind | Rules |
|---|---|---|
| `PitchLaneCore` | library, **pure Swift, imports Foundation only** | DSP, song model, parsers, scoring, log file store, JSON persistence, `BuildInfo`, settings model. **Everything here gets unit tests.** No UIKit/SwiftUI/AVFoundation/os. |
| `PitchLane` | library product xtool packages as the app (SwiftUI, AVFoundation, os) | Thin: UI, audio I/O, glue. Logic that can be pure goes in Core. |
| `PitchLaneCoreTests` | tests | Must pass with `swift test` in WSL. |

- **Every file in `Sources/PitchLane` is wrapped in `#if canImport(SwiftUI)` ... `#endif`.** This keeps
  `swift test` (which builds all targets) working on Linux, where SwiftUI doesn't exist. xtool cross-compiles
  against the iOS SDK where it does. Keep this on every new app file.
- Core is Swift 6 language mode (strict concurrency). Types shared across threads must be `Sendable`.
- Audio-thread code must not allocate, lock, or log. Do DSP in Core on plain `[Float]`/buffers so it is testable.

## Commands

```bash
swift test                                  # Core unit tests (runs in WSL)
scripts/build-ipa.sh                        # test + bump build + release IPA + copy to Desktop
scripts/bump-build.sh                       # only bump CFBundleVersion, prints new number
xtool dev build --ipa -c release            # what build-ipa.sh runs
```

- **Release builds only** (`-c release`). No debug IPAs.
- IPA destination: `/mnt/c/Users/Purpl/Desktop/PitchLane.ipa` (overwrite). Override with `PITCHLANE_IPA_DEST`.
- **Fix ALL errors and ALL warnings.** `build-ipa.sh` fails the build if the log contains any `warning:` or `error:`.
- Info.plist (`Info.plist`, referenced by `xtool.yml`) must keep:
  `NSMicrophoneUsageDescription` = "PitchLane listens to your voice to show your pitch. Audio never leaves your phone."
  and `CADisableMinimumFrameDurationOnPhone` = true (120 Hz).

## Versioning

- `CFBundleShortVersionString` = marketing version; `CFBundleVersion` = integer build number.
- **Bump `CFBundleVersion` on every IPA build** (`scripts/bump-build.sh` does it; `build-ipa.sh` calls it).
  Commit the bumped Info.plist with the step.
- Version + build are shown in **Settings** and in the **debug overlay** (toggle in Settings), and the build
  number is in the corner of the home screen. Read them via `BuildInfo.current`, never hardcode.

## Logging (AppLog)

- `AppLog.info/warning/error/debug(_:category:)` writes timestamped lines to
  `Application Support/PitchLane/Logs/pitchlane.log` (cap ~1 MB; oldest half dropped when exceeded) and mirrors to os_log.
- At launch the current file rotates to `pitchlane.previous.log` (the previous session is kept) and AppLog logs
  whether the previous session ended cleanly. "Clean" = the app reached the background; the state file
  (`session.state`) flips to `running` again on return to foreground. Unclean = crash or killed in foreground.
- Settings > Logs shows previous + current session, with **Copy All** and **Share**.
- **Never log raw audio** (samples, buffers, waveforms). Log derived, low-rate facts only.
- Log lifecycle, navigation, permission results, audio route/config changes, errors, and anything useful to
  diagnose a problem without the device attached.
- Pure logic lives in Core's `LogFileStore` (tested); the os_log mirror lives in the app's `AppLog`.

## Definition of done: every step ends with

1. `swift test` passes.
2. IPA build (`scripts/build-ipa.sh`): zero errors, zero warnings, IPA copied to the Desktop.
3. `git commit` (include the bumped Info.plist).
4. Tell the user the **build number**.
5. Give a **short on-phone test checklist** for what the step changed.

If a toolchain is unavailable in the current environment (e.g. a cloud session without Swift/xtool), say so
plainly instead of claiming steps 1-2 passed.

## Style

- Don't add features outside the current step in `docs/PLAN.md`.
- Keep the home/menu screens as the navigation hub: Play, Library, Tuner, Settings (Logs lives under Settings).
- Colours only via `Theme`. SF Symbols for icons.
