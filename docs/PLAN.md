# PitchLane plan

Each step ends with the standard finish (see `CLAUDE.md`): `swift test`, release IPA build, git commit,
report the build number, on-phone test checklist.

## 0. Project setup (done)

SPM package (`PitchLaneCore`, `PitchLane`, tests), xtool config, Info.plist, AppLog + Logs screen,
settings JSON persistence, placeholder home (Play / Library / Tuner / Settings), build/version display.

## 1. Pitch engine

Goal: a trustworthy real-time pitch reading from the microphone: accurate, fast, stable.

### Design

```
mic -> AVAudioEngine input tap (audio thread, ~1024 frames)
    -> AudioCaptureRing (lock-free SPSC, drop + count on overflow)       [app]
    -> analysis serial queue (woken by a DispatchSource, never the audio thread)
    -> PitchPipeline                                                     [Core]
         StreamingResampler  44.1/48 kHz -> 16 kHz (6th-order Butterworth LPF @ 5.5 kHz + linear interp)
         sliding 492-sample window (30.75 ms), hop 160 samples (10 ms => 100 frames/s)
         PitchDetector (YIN)  -> Hz, confidence = 1 - CMNDF(tau), RMS
         PitchStabilizer      -> gate, confidence, octave guard, 5-frame median
         PitchFrame           -> Hz, MIDI (Double), nearest note name, cents, confidence, RMS/dBFS
    -> main actor (batched per drain) -> Tuner UI, debug overlay
    -> PitchSessionStats -> AppLog summaries (no audio)
```

**Why YIN over MPM:** both are time-domain and suit monophonic voice. YIN's absolute-threshold rule
("first dip below 0.15") is what keeps it off sub-octaves for harmonic-rich signals, its CMNDF value gives a
calibrated confidence for free, and it is simple to make fast with plain pointer loops. MPM's advantage
(fewer octave-up errors on very bright timbres) is covered by the stabilizer's octave guard.

**Detector details (prototyped in Python before porting, numbers from that prototype):**
- Range: configurable, default C2-C6 (65.4-1046.5 Hz). At 16 kHz: lags 15...246, window W = 246.
- Difference function with 4 parallel accumulators over `UnsafeBufferPointer` (O(W x maxLag) ~ 60k MACs/frame).
- Threshold search starts at lag 2, below the range: a periodic dip shorter than the minimum lag means the
  pitch is above range (e.g. whistling at 2 kHz) and is reported as such, not folded to a sub-octave.
- Parabolic interpolation on the raw difference function (worst sine error 0.5 c vs 3.9 c on CMNDF).
- Prototype results: sines C2-C6 at 44.1/48 kHz within 0.5 c; saw/square within 4 c, no octave errors;
  white noise confidence <= 0.30; 300 Hz-lowpassed "fan" noise <= 0.78 (so the voiced threshold is 0.85).

**Stabilizer (in this order):**
1. RMS noise gate, default -50 dBFS.
2. Above-range dip -> unvoiced (`outOfRange`).
3. Confidence < 0.85 -> unvoiced (`lowConfidence`).
4. Octave guard: a jump of >= 9 semitones from the current median is held back (`pendingJump`, unvoiced)
   until 3 consecutive frames agree within 1.5 semitones; then the history is replaced and it is accepted.
5. 5-frame median of accepted MIDI values (adds ~20 ms lag; removes single-frame spikes).
6. 3 unvoiced frames in a row clear the history, so a new note after a gap starts fresh.
When unsure the frame is unvoiced, so the cursor hides instead of jumping.

**Latency budget:** window centre is ~15 ms old when analysed, the median adds ~20 ms, plus I/O buffering.
Measured and compensated in step 4.

### Deliverables
- Core: `NoteNaming` (accidental always on the note: F♯4 / B♭3, sharps-or-flats setting), `PitchMath`,
  `Biquad`, `StreamingResampler`, `PitchDetector`, `PitchStabilizer`, `PitchPipeline`, `PitchHistory` +
  `PitchGraphScale` (5 s graph), `PitchSessionStats` (log summaries), settings `accidentals`.
- Tests at 44.1 and 48 kHz: sine sweep C2-C6 (+/-5 c), saw/square (no octave errors), 5 Hz vibrato,
  silence + white noise + fan-like noise (unvoiced), whistle above range (unvoiced), octave glide up and down,
  stabilizer unit tests, resampler response + chunking invariance, speed test.
- App: `AudioInput` (session `.playAndRecord` / `.measurement`, tap, permission, interruptions, route and
  engine-configuration changes, media-services reset), `PitchAnalyzer` (ring buffer + serial queue),
  Tuner screen (note, Hz, cents needle, confidence bar, level meter, 5 s scrolling graph), debug overlay
  (analysis time/frame, frames/s, dropped buffers), sharps/flats in Settings.
- Phone checklist: sing a slow scale, hold a note with vibrato, whistle, stay silent near a fan or TV,
  then paste the Logs.

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
