#if canImport(SwiftUI)
import AVFoundation
import QuartzCore
import SwiftUI
import PitchLaneCore

enum AudioInputError: LocalizedError {
    case noInputAvailable

    var errorDescription: String? {
        switch self {
        case .noInputAvailable: return "No microphone input is available."
        }
    }
}

/// App-wide microphone input. Screens that need pitch call `acquire`/`release`; the engine runs while at
/// least one screen holds it and the app is in the foreground.
///
/// Session: `.playAndRecord` + `.measurement` (no AGC / voice processing), preferred 48 kHz, 5 ms I/O.
/// Survives permission denial, interruptions (calls, Siri), route changes (headphones in/out), engine
/// configuration changes and media-services resets: every one of those is logged.
@MainActor
final class AudioInput: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case permissionDenied
        case starting
        case running
        case interrupted
        case failed(String)
    }

    /// Detector range shown by graphs (C2...C6).
    static let displayBounds: ClosedRange<Double> = 36...84

    @Published private(set) var state: State = .idle
    @Published private(set) var latest: PitchFrame?
    @Published private(set) var lastVoiced: PitchFrame?
    @Published private(set) var history = PitchHistory(duration: 5)
    @Published private(set) var graphRange: ClosedRange<Double> = 54...66

    let diagnostics = AudioDiagnostics()
    /// Per-route latency calibration (also injected as an environment object).
    let latencyStore = LatencyStore()
    /// Output route kind (speaker / wired / Bluetooth / other); latency is calibrated per kind.
    @Published private(set) var routeKind: AudioRouteKind = .other

    private var engine = AVAudioEngine()
    private let analyzer = PitchAnalyzer()
    private var clients: Set<String> = []
    private var inBackground = false
    private var accidentals: Accidentals = .sharps
    private var tapSampleRate: Double = 0
    private var observers: [NSObjectProtocol] = []
    private var isStarting = false
    /// Screens that want every pitch frame (the game), keyed by name. Called on the main actor with the
    /// batch and its arrival host time.
    private var frameListeners: [String: (PitchAnalyzer.Batch, Double) -> Void] = [:]
    private var clickPlayer: AVAudioPlayerNode?
    private var clickBuffer: AVAudioPCMBuffer?
    private var guideVoice: GuideVoice?
    private var guideNode: AVAudioSourceNode?
    private var currentGuide: GuideToneRenderer?
    private var guideVolume: Float = 0
    private var sessionLatency: (input: Double, output: Double) = (0, 0)
    let backing = BackingTrack()

    init() {
        analyzer.setDelivery { [weak self] batch in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.receive(batch)
                }
            }
        }
        observeSystemNotifications()
    }

    // MARK: Clients

    func acquire(_ client: String) async {
        clients.insert(client)
        AppLog.info("Audio requested by \(client)", category: "audio")
        await startIfNeeded(reason: "\(client) opened")
    }

    func release(_ client: String) {
        guard clients.remove(client) != nil else { return }
        AppLog.info("Audio released by \(client)", category: "audio")
        if clients.isEmpty {
            stop(reason: "no screen needs audio")
        }
    }

    func retry() async {
        AppLog.info("Audio retry requested", category: "audio")
        if case .failed = state { state = .idle }
        await startIfNeeded(reason: "retry")
    }

    func addFrameListener(_ name: String, _ handler: @escaping (PitchAnalyzer.Batch, Double) -> Void) {
        frameListeners[name] = handler
    }

    func removeFrameListener(_ name: String) {
        frameListeners[name] = nil
    }

    // MARK: Output clock, guide tone, backing track

    /// Latency for the current route: session input/output latency plus the calibrated correction.
    var latency: LatencyEstimate {
        LatencyEstimate(
            route: routeKind,
            input: sessionLatency.input,
            output: sessionLatency.output,
            correction: latencyStore.profiles[routeKind].correctionMs / 1_000
        )
    }

    /// Latest reading of the output sample clock (the master clock), or nil if the engine isn't rendering.
    func outputAnchor() -> OutputClockAnchor? {
        guard engine.isRunning else { return nil }
        return guideVoice?.outputAnchor()
    }

    func renderSeconds(atHost host: Double) -> Double? {
        outputAnchor()?.renderSeconds(atHost: host)
    }

    func hostSeconds(forRender render: Double) -> Double? {
        outputAnchor()?.hostSeconds(forRender: render)
    }

    /// Gives the guide synth to the audio thread (nil = silent). Survives engine rebuilds.
    func installGuide(_ renderer: GuideToneRenderer?) {
        currentGuide = renderer
        guideVoice?.install(renderer)
    }

    func setGuideTimeline(anchorRender: Double, anchorSong: Double) {
        guideVoice?.setTimeline(anchorRender: anchorRender, anchorSong: anchorSong)
    }

    func stopGuideTimeline() {
        guideVoice?.stopTimeline()
    }

    func setGuideVolume(_ volume: Float) {
        guideVolume = volume
        guideVoice?.setVolume(volume)
    }

    var backingLatency: Double { backing.latency }

    private func attachPlayback() {
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        if guideNode == nil || guideVoice?.sampleRate != rate {
            if let old = guideNode { engine.detach(old) }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
            let voice = GuideVoice(sampleRate: rate)
            let node = AVAudioSourceNode(format: format, renderBlock: voice.makeRenderBlock())
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            voice.install(currentGuide)
            voice.setVolume(guideVolume)
            guideVoice = voice
            guideNode = node
            AppLog.info("Guide voice attached at \(Int(rate)) Hz (output clock source)", category: "audio")
        }
        backing.attach(to: engine, outputRate: rate)
    }

    private func updateRoute() {
        let session = AVAudioSession.sharedInstance()
        let kind = AudioRouteKind.classify(outputPortTypes: session.currentRoute.outputs.map { $0.portType.rawValue })
        sessionLatency = (session.inputLatency, session.outputLatency)
        if kind != routeKind {
            routeKind = kind
        }
        let correction = latencyStore.profiles[kind]
        AppLog.info(
            "Route \(kind.rawValue): input latency \(Self.ms(session.inputLatency)) ms, output latency \(Self.ms(session.outputLatency)) ms, "
                + "calibration \(correction.calibrationMs.map { String(format: "%.0f", $0) } ?? "none") ms, nudge \(String(format: "%.0f", correction.nudgeMs)) ms",
            category: "latency"
        )
    }

    // MARK: Click track

    /// Plays a click at an exact host time (seconds on the `CACurrentMediaTime` clock).
    func scheduleClick(atHostTime seconds: Double) {
        guard let clickPlayer, let clickBuffer, engine.isRunning else { return }
        let time = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: seconds))
        clickPlayer.scheduleBuffer(clickBuffer, at: time, options: [], completionHandler: nil)
    }

    /// Drops every scheduled click (pause, quit).
    func cancelClicks() {
        guard let clickPlayer, engine.isRunning else { return }
        clickPlayer.stop()
        clickPlayer.play()
    }

    private func attachClickPlayer() {
        let player = clickPlayer ?? AVAudioPlayerNode()
        if clickPlayer == nil {
            engine.attach(player)
            clickPlayer = player
        }
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let rate = outputRate > 0 ? outputRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
        engine.connect(player, to: engine.mainMixerNode, format: format)
        clickBuffer = Self.makeClick(format: format)
    }

    /// 25 ms decaying 2.5 kHz blip: above the C2-C6 pitch range, so the mic doesn't score it as a note.
    private static func makeClick(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(format.sampleRate * 0.025)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frames
        let rate = format.sampleRate
        for i in 0..<Int(frames) {
            let t = Double(i) / rate
            channel[i] = Float(0.5 * sin(2 * Double.pi * 2_500 * t) * exp(-t * 180))
        }
        return buffer
    }

    func setAccidentals(_ accidentals: Accidentals) {
        self.accidentals = accidentals
        analyzer.setAccidentals(accidentals)
    }

    func enterBackground() {
        inBackground = true
        if isActive { stop(reason: "app in background") }
    }

    func enterForeground() async {
        guard inBackground else { return }
        inBackground = false
        await startIfNeeded(reason: "app returned to foreground")
    }

    private var isActive: Bool {
        switch state {
        case .running, .starting, .interrupted: return true
        default: return false
        }
    }

    // MARK: Start / stop

    private func startIfNeeded(reason: String) async {
        guard !clients.isEmpty, !inBackground, !isStarting else { return }
        switch state {
        case .running, .starting, .requestingPermission, .failed: return
        case .idle, .permissionDenied, .interrupted: break
        }
        isStarting = true
        defer { isStarting = false }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            break
        case .denied:
            if state != .permissionDenied {
                AppLog.warning("Microphone permission is denied; showing Settings link", category: "audio")
            }
            state = .permissionDenied
            return
        case .undetermined:
            state = .requestingPermission
            AppLog.info("Requesting microphone permission", category: "audio")
            let granted = await AVAudioApplication.requestRecordPermission()
            AppLog.info("Microphone permission \(granted ? "granted" : "denied") by user", category: "audio")
            guard granted else {
                state = .permissionDenied
                return
            }
            guard !clients.isEmpty, !inBackground else {
                state = .idle
                return
            }
        @unknown default:
            state = .failed("Unknown microphone permission state.")
            return
        }

        state = .starting
        do {
            try configureSession()
            try startEngine()
            state = .running
            AppLog.info("Audio running (\(reason))", category: "audio")
        } catch {
            AppLog.error("Audio start failed (\(reason)): \(error.localizedDescription)", category: "audio")
            tearDownEngine()
            state = .failed(error.localizedDescription)
        }
    }

    private func stop(reason: String) {
        if isActive || tapSampleRate > 0 {
            tearDownEngine()
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                AppLog.warning("Session deactivate failed: \(error.localizedDescription)", category: "audio")
            }
            AppLog.info("Audio stopped (\(reason))", category: "audio")
        }
        if state != .permissionDenied { state = .idle }
    }

    private func restart(reason: String) async {
        AppLog.info("Restarting audio (\(reason))", category: "audio")
        tearDownEngine()
        state = .idle
        await startIfNeeded(reason: reason)
    }

    private func configureSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        do {
            try session.setPreferredSampleRate(48_000)
        } catch {
            AppLog.warning("Preferred sample rate rejected: \(error.localizedDescription)", category: "audio")
        }
        do {
            try session.setPreferredIOBufferDuration(0.005)
        } catch {
            AppLog.warning("Preferred IO buffer rejected: \(error.localizedDescription)", category: "audio")
        }
        try session.setActive(true)
        updateRoute()
        AppLog.info(
            "Session active: \(Int(session.sampleRate)) Hz, IO buffer \(Self.ms(session.ioBufferDuration)) ms, "
                + "input latency \(Self.ms(session.inputLatency)) ms, output latency \(Self.ms(session.outputLatency)) ms, "
                + "route \(Self.describe(session.currentRoute))",
            category: "audio"
        )
    }

    private func startEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputError.noInputAvailable
        }
        analyzer.prepare(sampleRate: format.sampleRate, accidentals: accidentals)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: analyzer.makeTapBlock())
        tapSampleRate = format.sampleRate
        attachClickPlayer()
        attachPlayback()
        engine.prepare()
        try engine.start()
        clickPlayer?.play()
        AppLog.info(
            "Processing check: session mode \(AVAudioSession.sharedInstance().mode.rawValue), "
                + "voice processing (echo cancel/AGC) \(input.isVoiceProcessingEnabled ? "ON (unexpected)" : "off")",
            category: "audio"
        )

        history.removeAll()
        latest = nil
        lastVoiced = nil
        let ioMs = AVAudioSession.sharedInstance().ioBufferDuration * 1_000
        diagnostics.setRunning(true, sampleRate: format.sampleRate, ioBufferMs: ioMs)
        AppLog.info("Engine started: tap \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, buffer 1024", category: "audio")
    }

    private func tearDownEngine() {
        backing.stop()
        if tapSampleRate > 0 {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            tapSampleRate = 0
        }
        analyzer.stop()
        latest = nil
        diagnostics.setRunning(false)
    }

    // MARK: Frames

    private func receive(_ batch: PitchAnalyzer.Batch) {
        if let stats = batch.stats {
            diagnostics.update(stats)
        }
        guard state == .running, let last = batch.frames.last else { return }
        // Only the tuner needs the published stream. Publishing ~47x/s while the game runs would re-render
        // every observing view on top of the game's own 120 Hz timeline.
        if clients.contains("tuner") {
            var updated = history
            for frame in batch.frames {
                updated.append(frame)
            }
            history = updated
            latest = last
            if let voiced = batch.frames.last(where: { $0.isVoiced }) {
                lastVoiced = voiced
            }
            let range = PitchGraphScale.range(for: updated, current: graphRange, bounds: Self.displayBounds)
            if range != graphRange {
                graphRange = range
            }
        }
        if !frameListeners.isEmpty {
            let arrival = CACurrentMediaTime()
            for listener in frameListeners.values {
                listener(batch, arrival)
            }
        }
    }

    // MARK: System notifications

    private func observeSystemNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let reason = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(typeRaw: type, optionsRaw: options, reasonRaw: reason)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(reasonRaw: reason)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMediaServicesReset()
            }
        })

        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] note in
            let source = (note.object as AnyObject?).map { ObjectIdentifier($0) }
            MainActor.assumeIsolated {
                self?.handleEngineConfigurationChange(source: source)
            }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?, reasonRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            AppLog.warning("Interruption began (reason \(reasonRaw.map { String($0) } ?? "n/a"), state \(state))", category: "audio")
            if state == .running || state == .starting {
                state = .interrupted
                latest = nil
                diagnostics.setRunning(false)
            }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            AppLog.info("Interruption ended (shouldResume \(options.contains(.shouldResume)))", category: "audio")
            if state == .interrupted {
                Task { await restart(reason: "interruption ended") }
            }
        @unknown default:
            AppLog.warning("Unknown interruption type \(typeRaw)", category: "audio")
        }
    }

    private func handleRouteChange(reasonRaw: UInt?) {
        let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw ?? 0) ?? .unknown
        let route = Self.describe(AVAudioSession.sharedInstance().currentRoute)
        AppLog.info("Route change: \(Self.name(reason)) -> \(route)", category: "audio")
        updateRoute()
        guard state == .running else { return }
        let rate = engine.inputNode.outputFormat(forBus: 0).sampleRate
        if !engine.isRunning || rate != tapSampleRate {
            Task { await restart(reason: "route change, input now \(Int(rate)) Hz, engine running \(engine.isRunning)") }
        }
    }

    private func handleEngineConfigurationChange(source: ObjectIdentifier?) {
        guard source == nil || source == ObjectIdentifier(engine) else { return }
        AppLog.info("Engine configuration changed (running \(engine.isRunning), state \(state))", category: "audio")
        if state == .running {
            Task { await restart(reason: "engine configuration change") }
        }
    }

    private func handleMediaServicesReset() {
        AppLog.warning("Media services were reset; rebuilding audio engine", category: "audio")
        let wasActive = isActive
        tapSampleRate = 0
        analyzer.stop()
        engine = AVAudioEngine()
        clickPlayer = nil
        clickBuffer = nil
        guideNode = nil
        guideVoice = nil
        state = .idle
        diagnostics.setRunning(false)
        if wasActive {
            Task { await startIfNeeded(reason: "media services reset") }
        }
    }

    // MARK: Formatting

    private static func ms(_ seconds: TimeInterval) -> String {
        String(format: "%.1f", seconds * 1_000)
    }

    private static func describe(_ route: AVAudioSessionRouteDescription) -> String {
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: "+")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: "+")
        return "in [\(inputs)] out [\(outputs)]"
    }

    private static func name(_ reason: AVAudioSession.RouteChangeReason) -> String {
        switch reason {
        case .unknown: return "unknown"
        case .newDeviceAvailable: return "newDeviceAvailable"
        case .oldDeviceUnavailable: return "oldDeviceUnavailable"
        case .categoryChange: return "categoryChange"
        case .override: return "override"
        case .wakeFromSleep: return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRouteForCategory"
        case .routeConfigurationChange: return "routeConfigurationChange"
        @unknown default: return "reason \(reason.rawValue)"
        }
    }
}
#endif
