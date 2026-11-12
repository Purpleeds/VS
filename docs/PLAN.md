# PitchLane plan

Each step ends with the standard finish (see `CLAUDE.md`): `swift test`, release IPA build, git commit,
report the build number, on-phone test checklist.

## 0. Project setup (done)

SPM package (`PitchLaneCore`, `PitchLane`, tests), xtool config, Info.plist, AppLog + Logs screen,
settings JSON persistence, placeholder home (Play / Library / Tuner / Settings), build/version display.

## 1. Pitch engine

Goal: a trustworthy real-time pitch reading from the microphone.

- Core: monophonic pitch detector (YIN or MPM) over `[Float]` frames: frequency, confidence/clarity,
  voiced/unvoiced gate (RMS + clarity), octave-error guard, smoothing/median filter, Hz -> MIDI -> cents,
  note names. Synthetic-signal tests (sine, harmonics, noise, silence, vocal range ~80-1000 Hz).
- App: `AVAudioEngine` input tap, `AVAudioSession` (`.playAndRecord`, measurement-friendly mode), mic permission
  flow, interruption/route-change handling (all logged, no raw audio logged).
- Tuner screen: big note name, cents needle, live frequency, debug overlay line with detection rate.
- Phone checklist: permission prompt wording, sustained note reads stable, octave jumps rare, silence shows no
  pitch, works with and without headphones, survives a phone call / backgrounding.

## 2. Song format + importers

Goal: songs as Codable JSON in Application Support, plus ways to get them in.

- Core: `Song` model (title, artist, tempo map, notes with start/duration/MIDI pitch, optional lyrics,
  backing-track reference, schema version), validation, JSON round-trip, transposition helper.
- Importers (Core, pure parsers, fixture tests): MIDI (.mid), UltraStar (.txt), MusicXML; clear error reporting.
- App: Library screen lists songs, import via the Files picker, delete, bundled demo song.
- Phone checklist: import each format, malformed file shows a readable error, library survives relaunch.

## 3. Note lane + scoring

Goal: the actual game screen (landscape).

- Core: scoring engine (per-frame cents error vs. target note, tolerance window, hold/streak/combo, octave
  forgiveness option, final grade), deterministic and fully tested; song-time <-> beat mapping.
- App: 120 Hz Canvas/TimelineView lane, notes scrolling right-to-left, pitch cursor driven by the engine,
  score/combo HUD, pause/resume, results screen.
- Phone checklist: cursor tracks voice smoothly at 120 Hz, notes line up with the playhead, scoring feels
  fair, pause/resume and backgrounding behave.

## 4. Guide tone + backing track + latency

Goal: audio playback that lines up with what the player sees and sings.

- Guide tone synthesiser (sine/soft vowel-ish) for the current note, toggle + volume.
- Backing-track playback (`AVAudioPlayerNode`/`AVAudioEngine`) synced to song time.
- Latency: measure/estimate input + output latency from the session, manual calibration offset (tap/clap or
  slider), applied to scoring and visuals; headphone guidance (avoid speaker bleed into the mic).
- Phone checklist: guide tone matches notes, backing stays in sync over a full song, calibration changes the
  alignment, bluetooth route is handled and logged.

## 5. Range test + practice + settings

Goal: make it playable for any voice and easy to practise.

- Range test: find lowest/highest comfortable notes, store in settings, auto-transpose songs into range.
- Practice mode: loop a section, slow down, hide/show guide, per-note feedback.
- Settings: difficulty/tolerance, calibration, guide tone, haptics, debug overlay, log access; persisted JSON.
- Phone checklist: range result sensible, transposed song is singable, loop/slowdown work, settings persist.

## 6. Final review

- Full code review (correctness, audio-thread safety, concurrency warnings), dead code, naming.
- Performance pass at 120 Hz (frame time, memory, battery), log volume check.
- Accessibility (Dynamic Type on menus, contrast), empty/error states, permission-denied flows.
- Re-verify Info.plist keys, no hardcoded bundle ID, no raw audio in logs, release build with zero warnings.
- Full on-phone regression checklist; tag the release.
