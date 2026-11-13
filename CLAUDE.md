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

## CI (GitHub Actions, `.github/workflows/ci.yml`)

Runs on every push and PR:
- **Core tests (Linux):** `swift test` in debug and release inside `swift:6.2-noble`, warnings are errors.
- **iOS compile check (macOS runner):** SwiftPM build for `arm64-apple-ios26.0` (what xtool does) plus an unsigned
  generic-device `xcodebuild`; any Swift warning fails the job. This runner is the only place Xcode tools are used;
  it is a compile check, not part of the user's workflow.
- **Build IPA (`.github/workflows/ipa.yml`, manual: Actions > Build IPA > Run workflow):** Linux `swift test`, then on
  macOS a SwiftPM release build for iOS, links the app target into `PitchLane.app`, adds the bundle keys xtool would add
  (bundle ID is a workflow input, default `dev.pitchlane.PitchLane`; never in code), zips an unsigned
  `PitchLane.ipa` and uploads it as the run's artifact. iloader signs it on import. It bumps `CFBundleVersion` and
  commits "Build N (CI)" back to the branch, so pull before building locally.
- The IPA can also be built locally in WSL with `scripts/build-ipa.sh` (xtool, copies to the Desktop).
- In a cloud session without a Swift toolchain, push and read the CI logs instead of guessing whether code compiles.

## Audio and pitch (step 1)

- `AudioInput` (app, `@MainActor`) is the single app-wide mic owner. Screens call `acquire("name")` /
  `release("name")`; the engine runs while any screen holds it and the app is in the foreground.
  Session: `.playAndRecord`, mode `.measurement` (no AGC), preferred 48 kHz / 5 ms I/O.
- Tap block (audio thread): copy channel 0 into `AudioCaptureRing` (lock-free SPSC) and poke a dispatch source.
  Nothing else: no allocation, locks, logging, Swift arrays or main-actor hops there.
- `PitchAnalyzer` drains the ring on its own serial queue into Core's `PitchPipeline`
  (resample to 16 kHz, YIN, stabiliser, 100 frames/s) and delivers batches to the main actor in order.
- Interruptions, route changes, engine configuration changes and media-services resets restart the engine
  and are logged. Mic permission denied shows an explanation + Settings link.
- Pitch defaults (Core): C2-C6, YIN threshold 0.15, gate -50 dBFS, confidence >= 0.85, 5-frame median,
  octave guard (>= 9 semitones needs 3 agreeing frames). When unsure, frames are unvoiced.
- Note names always carry their own accidental (F♯4, B♭3); sharps/flats is a setting.

## Songs and library (step 2)

- `Song` (Core) is the one song model: notes in seconds from the song/backing-audio start, MIDI pitch, syllable,
  golden, freestyle (unscored), `slidesFromPrevious` + `slideDuration` (nil = whole-note glide, e.g. sirens;
  UltraStar `~` = short glide), line breaks, tempo segments (click grid), backing audio file, `offsetMs`.
  Decoding is forgiving (new fields need defaults). `song.json` per imported song.
- Importers live in Core and must never trap on bad input: throw `SongImportError` with a line (text) or byte
  offset (binary). Every importer gets malformed-file tests (including random bytes).
- Imported songs: `Application Support/PitchLane/Songs/<uuid>/` with `song.json`, `original.<ext>`, `backing.<ext>`.
  Built-ins are generated in code (`BuiltInSongs`), never stored, and must stay original (no copyrighted songs or
  lyrics).

## Game (step 3)

- One master clock: `GameClock` (Core) maps `CACurrentMediaTime()` to song time (runs from -3 s during the
  countdown; pause freezes; resume holds for a 3-2-1). Render from `clock.songTime(at: now)` every frame;
  never count frames. Pitch frames map to song time via `StreamClockMapper` minus `GameSession.pitchLatency`.
- Scoring rules live only in Core `ScoreKeeper` (tolerance per difficulty, octave-agnostic default ON, ratings,
  golden x2, combo/multiplier, accuracy, grade) and are unit-tested; the app never re-implements them.
- The lane is `TimelineView(.animation)` + one `Canvas` (`LaneRenderer`). Inside the renderer: no `@Published`
  writes (dispatch them), no allocation-heavy work, use `NoteIndex` for visible notes. HUD values are published
  only when a note ends. Game fps goes to the debug overlay via `AudioDiagnostics.setGameFrameStats`.
- Canvas closures that touch main-actor state wrap their body in `MainActor.assumeIsolated`.
- Personal bests: `Application Support/PitchLane/personal-bests.json` (`ScoreStore`).

## Playback and latency (step 4)

- One `AVAudioEngine` (owned by `AudioInput`) for mic + playback: input tap, click player, guide
  `AVAudioSourceNode` (`GuideVoice` + Core `GuideToneRenderer`), backing `AVAudioPlayerNode` ->
  `AVAudioUnitTimePitch` (rate 1; practice speed later) -> main mixer. Session `.playAndRecord` / `.measurement`
  with `.defaultToSpeaker` + `.allowBluetoothA2DP`; voice processing (echo cancel / AGC) must stay off (logged).
- **Master clock = audio output timeline.** The guide voice's render callback publishes (sample time, host time)
  every cycle; `SongTimebase` runs the `GameClock` in output-render seconds. The lane shows what is heard:
  `songTime(render(now) - outputLatency)`. Guide, backing and clicks are placed on the same timeline; never
  start audio "now" or count frames.
- Mic frames carry exact capture times (tap `AVAudioTime` -> `PitchAnalyzer.CaptureAnchor`). Frame song time =
  `songTime(render(capture - inputLatency) - outputLatency) - correction - pitchLatency`.
- Latency = `AVAudioSession` input/output latency + per-route correction (calibration + nudge) stored in
  `Application Support/PitchLane/latency.json` (`LatencyStore`, keyed by `AudioRouteKind`: speaker / wired /
  Bluetooth / other). Calibration (Settings > Latency) measures clap/beep onsets with Core `LatencyCalibrator`.
- Render-thread rules: `GuideVoice` reads only atomics (`Synchronization.Atomic`, `WordPair`) and a renderer handed
  over by an atomic slot flip; `GuideToneRenderer.render` never allocates/locks/logs.
- Speaker route: warn that guide/backing leak into the mic. Bluetooth: warn about delay, suggest calibrating.

## Practice, range and stats (step 5)

- Home menu now: Play, Library, Tuner, **Practice** (range test, hold drill), **Stats**, Settings, plus the vocal-range
  card. A song's sheet holds Key (transpose + preview) and Practice (speed / loop / no-fail).
- Practice speed lives in `GameClock.rate` and `PracticeOptions`; never rescale song data. Loops use
  `GameClock.seek` (earlier host times keep the old mapping, so the display that lags the audio doesn't skip) and
  `SongTimebase.seek(toSongTime:whenRenderingSongTime:)`; frames sung before the seek belong to the previous pass.
- Practice runs (speed < 100%, loop, no-fail) and failed runs never set personal bests; they are recorded in
  `history.json` (`GameHistory`, via `ScoreStore.record`).
- The energy bar (`HealthMeter`) is Core and tested; fail can be disabled in Settings.
- Detection settings (instrument mode, noise gate) flow from `AppSettings.pipelineConfiguration()` through
  `AudioInput.setDetection`; graphs use `AudioInput.displayBounds`.
- Reset data goes through confirmation dialogs in Settings only.

## Robustness and privacy (step 6)

- `AudioInput.acquire(_:needsMic:)`: `needsMic: false` is playback only (`.playback` session, no input tap, no
  permission prompt); used by the key preview and the hold-drill reference tone. A mic client restarts the engine.
- Anything with a song clock registers `AudioInput.addEngineStopListener` and pauses/cancels there: a restarted engine
  has a new output timeline and has dropped scheduled audio. `GuideVoice.invalidateAnchor()` runs on every stop.
  Resume only succeeds while audio is `.running` (`GameSession.resume()` returns Bool).
- The mic is released on the results screen and outside an active calibration run; views release after `acquire`
  if their task was cancelled; `HomeView` calls `releaseAll` when the stack is empty.
- Song data stays inside `SongLimits` (importers throw, `song.json` decoding rejects); `clickTimes` is capped.
- App JSON stores load with `JSONFileStore.loadOrQuarantine()` (a corrupt file is moved to `*.corrupt-<time>.json`,
  newest two kept) and decode leniently (`lenient(_:forKey:)`, `Lossy<T>`); new fields need defaults.
- Song folders are named by app-generated ids only (`SongLibraryStore.isSafeFolderName`); the folder name wins over
  the id in `song.json`.
- os_log mirror is `.private`; the log file leaves the phone only via Copy All (local-only, expires) or Share.
  Erase everything also clears the logs; Logs has Clear.

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
