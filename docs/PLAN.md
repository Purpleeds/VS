# PitchLane plan

Each step ends with the standard finish (see `CLAUDE.md`): `swift test`, release IPA build, git commit,
report the build number, on-phone test checklist.

## 0. Project setup (done)

SPM package (`PitchLaneCore`, `PitchLane`, tests), xtool config, Info.plist, AppLog + Logs screen,
settings JSON persistence, placeholder home (Play / Library / Tuner / Settings), build/version display.

## 1. Pitch engine (done)

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

## 2. Song format + importers (done)

- Core `Song` / `SongNote` (start s, duration s, MIDI pitch, syllable, golden, freestyle, slide + glide length),
  line breaks, tempo segments (click grid), optional backing audio file, offset ms. Forgiving JSON decoding.
- `UltraStarImporter`: #TITLE #ARTIST #MP3/#AUDIO #BPM (comma decimals) #GAP (ms) #RELATIVE; `:` `*` `F` `R` `G`
  `-` `E`, duets (player 1); beat = 60 / (BPM x 4) s; pitch 0 = C4; `~` = continuation slide; UTF-8 / UTF-16 BOM /
  Windows-1252 (Latin-1); CRLF. Errors carry the line number.
- `MIDIFile` (SMF type 0/1): running status, sysex/meta, tempo map, SMPTE division, track list with note counts,
  channels, range, lyrics, drums flag, suggested melody; chord collapse (same start -> highest) + skyline overlaps.
  Errors carry the byte offset.
- `BuiltInSongs`: scales, arpeggios, intervals, long-note holds, sirens and three original melodies
  ("Morning Lane", "Paper Boats", "Lantern Steps"), each Easy / Normal / Hard.
- `SongLibraryStore`: one folder per imported song (song.json + original + backing.<ext>).
- App: Library (search, swipe delete, detail sheet with range/length/notes), Files import incl. backing audio,
  MIDI melody-track picker.

## 3. Note lane + scoring (done)

Goal: the game screen (landscape), Trombone Champ style, scored fairly at 120 fps.

### Design

**One master clock.** `GameClock` (Core) maps host time (`CACurrentMediaTime`) to song time:
start -> song time runs from -3 s (countdown, notes already scrolling in); pause freezes it; resume holds it for a
3-2-1 countdown, then continues. Every frame reads `songTime(at: now)`; nothing counts frames.

**Pitch frames onto the song clock.** Pitch frames carry stream time (samples since capture start).
`StreamClockMapper` keeps `offset = min(arrival host time - stream time)` (the least-delayed delivery), creeping up
slowly so it adapts, and resets when the stream restarts. Frame song time = clock(stream time + offset) minus a
fixed 20 ms for the stabiliser's median lag (step 4 adds measured latency calibration).

**Scoring (`ScoreKeeper`, Core, unit-tested).** For every frame inside a scored note (after a short attack grace of
min(60 ms, 20% of the note)): error = sung - target in cents, target following slides. Octave-agnostic (default ON)
folds the error into +/-600 c. On pitch when |error| <= tolerance (Easy 100, Normal 50, Hard 25 c). Unvoiced frames
count as off pitch. At the note's end: fraction on pitch -> Perfect >= 90%, Great >= 75%, Good >= 50%, Meh >= 25%,
else Miss. Points = rating base (100/80/50/20/0) x length factor (duration / 0.5 s, clamped 0.5...4) x 2 for golden x
multiplier. Perfect/Great/Good extend the combo, Meh/Miss reset it; multiplier = 1 + combo / 10, max 4.
Accuracy = weighted mean of note fractions; grade S >= 95%, A >= 85%, B >= 70%, C >= 55%, D >= 40%, else F.
`PersonalBests` (JSON) keeps the best score per song + difficulty.

**Lane geometry (`LaneViewport`, Core).** Vertical range = song range +/- 3 semitones, at least 12. Songs wider than
~2 octaves (26 semitones with margin) get a 26-semitone window that pans: its target centre is the middle of the notes
within [-1 s, +4 s] of the playhead, smoothed exponentially (time constant 0.6 s) so it glides, never jumps.
`NoteIndex` finds visible notes by binary search.

**Rendering (app).** `TimelineView(.animation)` + one `Canvas`: semitone lines (labelled C lines), playhead at 20%
of the width, ~4.5 s of notes to the right. Notes are round-capped strokes from `x(start)` to `x(end)`; slides are
curves from the previous pitch; golden notes gold with a glow; freestyle dashed; past notes tinted by rating;
lyrics under notes; optional note names (accidental on each note). Sung pitch: glowing dot on the playhead plus a
fading 0.4 s trail, hidden when unvoiced, folded to the octave of the nearby notes when octave-agnostic. Rating
pop-ups float above finished notes. HUD (score, combo, multiplier) is SwiftUI and only changes when a note ends.
Game fps measured by `FrameRateMeter` and shown in the debug overlay.

**Flow.** Library -> detail sheet -> Sing (difficulty, octave-agnostic, click track, note names) -> landscape game:
countdown, pause (button or app backgrounding / audio interruption), resume with countdown, restart, quit ->
results: score, grade, accuracy, longest combo, rating counts, replay graph of the sung pitch over the notes,
personal best.

**Click track.** Toggle; clicks scheduled ~0.5 s ahead on an `AVAudioPlayerNode` at exact host times from the song's
tempo grid (2.5 kHz blip, above the pitch range so the mic doesn't score it). Headphones recommended.

### Phone checklist
Play a built-in on each difficulty; notes scroll smoothly at 120 fps (debug overlay); dot tracks your voice and hides
when silent; slides/golden/lyrics look right; a wide MIDI import pans smoothly; pause/resume/restart/quit; results +
personal best persist; click track in time.

## 4. Guide tone + backing track + latency (done)

### Design
- **Shared engine.** Mic tap, click player, guide `AVAudioSourceNode`, backing player -> `AVAudioUnitTimePitch`
  -> main mixer, all in `AudioInput`'s single `AVAudioEngine`. `.measurement` mode keeps AGC/echo processing off;
  the engine logs `isVoiceProcessingEnabled` at every start.
- **Master clock.** The guide source node renders on every output cycle and publishes (sample time, host time)
  atomically. `SongTimebase` runs the game clock in output-render seconds; the lane draws the song time being
  *heard* (render time - output latency). The guide renders from the same anchor on the render thread; the
  backing (via time-pitch, latency compensated) and clicks are scheduled at the host time of their render time,
  so audio and visuals share one clock and cannot drift.
- **Mic timing.** The input tap's `AVAudioTime` gives the capture host time of each buffer; frames map to
  `songTime(render(capture - input latency) - output latency) - per-route correction - 20 ms median lag`.
- **Guide tone.** Core `GuideToneRenderer`: fundamental + soft 2nd/3rd harmonics, raised-cosine 30 ms attack /
  60 ms release, legato across gaps < 40 ms, glides on slides, 3 ms gain smoothing (no clicks on pause/volume).
  Off by default on Hard; toggle + volume in the song sheet, Settings and the pause menu.
- **Backing track.** Attached audio plays with `Song.offsetMs` (notes later = positive) through time-pitch at rate 1.
- **Latency.** Starts from `AVAudioSession` input/output latency. Settings > Latency: 4 count-in + 8 beeps;
  clap or sing "ta" on each (or stay silent on the speaker: the mic hears the beeps). Core `LatencyCalibrator`
  finds each onset (rising crossing of local floor + 12 dB), median offset + spread; save per route
  (speaker / wired / Bluetooth / other) and nudge in 5 ms steps.
- **Warnings.** Speaker: headphones work best (leak into the mic can score as your voice). Bluetooth: delay,
  calibrate.

### Phone checklist
Speaker, wired headphones, Bluetooth earbuds: calibrate each, play a song with guide tone (and one with backing
audio), check notes, guide and backing stay together over a whole song, pause/resume re-syncs, route warnings.

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
