#if canImport(SwiftUI)
import AVFoundation
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

    private var engine = AVAudioEngine()
    private let analyzer = PitchAnalyzer()
    private var clients: Set<String> = []
    private var inBackground = false
    private var accidentals: Accidentals = .sharps
    private var tapSampleRate: Double = 0
    private var observers: [NSObjectProtocol] = []
    private var isStarting = false

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
        engine.prepare()
        try engine.start()

        history.removeAll()
        latest = nil
        lastVoiced = nil
        let ioMs = AVAudioSession.sharedInstance().ioBufferDuration * 1_000
        diagnostics.setRunning(true, sampleRate: format.sampleRate, ioBufferMs: ioMs)
        AppLog.info("Engine started: tap \(Int(format.sampleRate)) Hz, \(format.channelCount) ch, buffer 1024", category: "audio")
    }

    private func tearDownEngine() {
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
