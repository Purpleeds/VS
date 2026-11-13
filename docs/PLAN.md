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

## 5. Range test + practice + settings (done)

### Design
- **Range test.** `RangeTestFlow` (Core): "sing your lowest comfortable note" -> hold 1 s (`NoteHoldDetector`: run
  within 0.7 semitone, short dropouts bridged) -> stop singing 0.6 s -> highest note -> saved as `VocalRange` in
  settings and shown on the home screen. The high note must be at least 5 semitones above the low one.
- **Auto-transpose.** `SongTransposer`: fit check, best shift in +/-24 semitones (fewest notes outside the range,
  then smallest move, whole octaves preferred on ties), `Song.transposed(by:)`. The song sheet has a Key section:
  range readout, "Fit to my range", octave/semitone steps, audio preview (guide tone on the first notes). The shift is
  remembered per song and applied at play time. Scoring is octave-agnostic by default, so a shift changes the lane
  and the guide tone, not what counts as correct.
- **Practice.** `PracticeOptions`: speed 50-100% (`GameClock.rate`: the guide renders at that rate, the backing goes
  through the time-pitch unit, clicks and lane follow the clock), loop a section (phrase pickers; `GameClock.seek`
  wraps exactly when the audio reaches the loop end; each pass is scored on its own and shown as "Pass N"),
  no-fail. Practice runs are saved to history but never count toward personal bests.
- **Fail / no-fail.** New `HealthMeter` energy bar: Perfect/Great/Good top it up, Meh/Miss drain it; at zero the
  song ends ("out of energy"). Settings > "Songs can be failed" turns it off globally; practice no-fail and loops
  never fail.
- **Hold drill.** `HoldDrill` (Core): one long note (a set note or any note, 5-15 s). The first 0.8 s isn't scored;
  steadiness = 100 at <= 3 cents RMS wobble falling to 0 at 35 cents, times the voiced fraction; also reports max swing,
  drift (cents/s) and the centre vs the target.
- **Instrument mode.** `PitchDetectorConfiguration.instrument` (40 Hz-2 kHz, 50 ms window) selected in Settings;
  detector range and graphs follow.
- **Stats.** `GameHistory` (JSON, newest 1000 runs): per-song history, accuracy trend (full-speed completed runs),
  moving average and improvement vs the previous five runs; drawn with a Canvas chart.
- **Settings.** Difficulty, octave-agnostic, failing, click track, note names + sharps/flats, labels on notes,
  guide/backing volume, noise gate (dBFS), instrument mode, latency, show FPS, debug overlay, and Reset data
  (settings / range / scores / latency / imported songs / everything, each confirmed).

### Phone checklist
Range test (sing low, high), range card on home, a song outside your range (suggestion + preview), practice at 70%
with a loop, no-fail, hold drill, instrument mode with your instrument, stats after a few runs, each reset.

## 6. Final review (done)

- Full code review (correctness, audio-thread safety, concurrency warnings), dead code, naming.
- Performance pass at 120 Hz (frame time, memory, battery), log volume check.
- Accessibility (Dynamic Type on menus, contrast), empty/error states, permission-denied flows.
- Re-verify Info.plist keys, no hardcoded bundle ID, no raw audio in logs, release build with zero warnings.
- Full on-phone regression checklist; tag the release.

### What the review fixed
Five parallel reviews (audio, pitch engine, UI, data, privacy). Fixed: engine restarts pause the game (engine-stop
listeners) and never reuse a stale output anchor; resume waits for audio; stuck interrupted/failed states recover;
practice-speed guide timing; backing format after media reset; coalesced restarts. Pitch: below-range notes unvoiced,
NaN-safe resampler, subharmonic check + confidence hysteresis for breathy voices, pitch latency 25 ms. Data:
`SongLimits` (no traps on huge GAP/BPM/pitch), click-track cap, corrupt JSON quarantined instead of overwritten,
lenient decoding of history/bests/latency/settings, safe song folders, atomic backing replace, MIDI legato lyrics and
chord fixes, temp-file cleanup. UI: permission/failed states with Settings links and scrolling, pause/results Dynamic
Type, alerts from the song sheet, MIDI picker vs alert, preview lifetime, VoiceOver values. Privacy: mic off on results
and idle calibration, playback-only key preview (no mic prompt), logs cleared by Erase everything / Logs > Clear,
os_log mirror private, local-only clipboard, Privacy section in Settings.

### Not done (needs a device to verify)
- Backing scheduling upstream of the time-pitch unit at practice speed (may start late at 50%; check the log line
  "Backing scheduled" against what you hear).
- Loop wrap: ~100 ms of guide/backing silence and an unscored tail on each pass.
- Lane text rendering per frame (watch the FPS badge on lyric-dense songs); 120 Hz from `TimelineView(.animation)`.

## 7. Videos + flashier game screen (done)

### Videos (Photos and Files)
- Library **+** menu: "Song or Video from Files…" (now accepts .mov/.mp4/.m4v) and "Video from Photos…"
  (`PhotosPicker`, no photo-library permission needed). Song sheet: "Attach Audio or Video from Files…" and
  "Attach Video from Photos…".
- **Backing audio:** a video attached to a song (or picked with a .txt/MIDI of the same name) is stored as
  `video.<ext>` and its soundtrack is exported to AAC as `backing.m4a` (`VideoTools.extractAudio`).
- **Video behind the lane:** `Song.videoFile`; `VideoBackdrop` plays it muted under a dark veil and keeps it on the
  song clock with Core `VideoSyncPolicy` (hold during countdown/pause, seek on > 250 ms drift, ±6 % rate nudge
  above 35 ms). Setting: "Song videos behind the lane" (`AppSettings.showVideo`, default on).
- **Notes from vocals:** a video picked on its own becomes a new song (`SongSource.video`): its audio is decoded
  (`AVAssetReader`, 48 kHz mono float) through `PitchPipeline` into Core `MelodyTranscriber` (median-tracked
  notes, gap bridging, 4-frame confirmed pitch changes, 0.1 s minimum, same-pitch merge, line breaks at 1.2 s
  silences). Progress card with Cancel. Rough on full mixes; best with one voice.

### Flashier game screen
- Gradient lane (or the dimmed video), scrolling beat lines, a hit-zone column that brightens with the multiplier.
- Glowing notes with a glossy highlight; the active note pulses, its lyric turns gold.
- Core `ParticleField` (fixed pool, allocation-free, positions from birth): a comet tail of sparks while on pitch,
  bursts on Great/Perfect, golden showers on golden notes, confetti on the results screen.
- Comet-tail cursor with a pulsing ring when on pitch; pop-ups with points; "25 COMBO!" and "×3" flashes
  (`ComboMilestone`); popping countdown; HUD combo with flame and bouncing multiplier badge.
- Results: grade spins in with a glow, the score counts up, confetti for S/A or a new best.

### Phone checklist
Import a video from Photos (progress card, new song "From video", plays with its video); attach a video to an
UltraStar song (video behind the lane, its sound as backing, in sync after pause/resume and with a practice loop);
turn videos off in Settings; a game at 120 fps with sparks, bursts, combo flash; results confetti.

## 8. Voice search + lyrics by song name (done)

- **Voice search** (Library toolbar mic, and the mic in Find Lyrics): Apple speech recognition with
  `requiresOnDeviceRecognition` only (refuses rather than sending audio to a server when the language has no
  on-device model). Mic samples come from `PitchAnalyzer`'s drain queue via `AudioInput.setSampleSink` (the audio-thread
  tap is unchanged). Stops after ~1.4 s of silence. Core `VoiceQuery` strips "play/sing/please…" and fuzzy-matches the
  library (accents, one-letter mishearings); a clear match opens the song, otherwise the words fill the search field.
- **Find Lyrics Online** (song sheet, imported songs): search LRCLIB (`lrclib.net/api/search?q=`, free/open, synced LRC);
  Genius has no lyrics API. Core `LRCParser` (time tags, offset, enhanced word times), `LyricsSearch` (URL, lenient
  decode, synced-first ranking by duration), `LyricAligner` (line words onto the notes that start in the line; word times
  win; automatic offset −12…12 s for videos with a different intro; plain lyrics spread over phrases). Credit stored in
  `Song.lyricsCredit`. Only the typed/spoken song name is sent; this is the app's only network request.

### Phone checklist
Library mic: say "play Major Scale" (opens it), say a nonsense name (fills search); deny speech permission (message);
song made from a video: Find Lyrics Online, pick a timed result (words on the notes, line breaks, shift message);
a words-only result; airplane mode (clear error).
