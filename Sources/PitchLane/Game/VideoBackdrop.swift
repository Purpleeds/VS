#if canImport(SwiftUI)
import AVFoundation
import QuartzCore
import SwiftUI
import UIKit
import PitchLaneCore

/// The song's video, muted, behind the lane. Its sound already plays as the backing track on the audio engine,
/// so the picture follows the song clock (`VideoSyncPolicy`): it holds during countdowns and pauses, seeks on big
/// jumps (loops, resume) and nudges its rate by a few percent to stay in step.
struct VideoBackdrop: View {
    let url: URL
    let session: GameSession

    @StateObject private var model = VideoBackdropModel()

    var body: some View {
        PlayerLayerView(player: model.player)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task { await model.run(url: url, session: session) }
            .onDisappear { model.stop() }
    }
}

@MainActor
final class VideoBackdropModel: ObservableObject {
    let player = AVPlayer()
    private let policy = VideoSyncPolicy()
    private var seeking = false
    private var duration: Double?
    private var seeks = 0

    func run(url: URL, session: GameSession) async {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.replaceCurrentItem(with: item)
        duration = try? await asset.load(.duration).seconds
        AppLog.info("Video backdrop loaded (\(url.pathExtension), \(duration.map { String(format: "%.1f s", $0) } ?? "unknown length"))", category: "game")
        while !Task.isCancelled {
            tick(session: session)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if seeks > 0 { AppLog.info("Video backdrop: \(seeks) resync seeks", category: "game") }
    }

    private func tick(session: GameSession) {
        guard !seeking, player.currentItem?.status == .readyToPlay,
              let clock = session.videoClock(atHost: CACurrentMediaTime()) else { return }
        let target = VideoSyncPolicy.videoTime(forSongTime: clock.songTime, offsetMs: session.song.offsetMs)
        let now = player.currentTime().seconds
        let action = policy.action(
            videoTime: now.isFinite ? now : 0,
            targetTime: target,
            advancing: clock.advancing,
            songRate: clock.rate,
            currentRate: Double(player.rate),
            duration: duration
        )
        switch action {
        case .none:
            break
        case .setRate(let rate):
            player.rate = Float(rate)
        case .pause(let time):
            player.pause()
            if abs((now.isFinite ? now : 0) - time) > 0.05 { seek(to: time) }
        case .seek(let time):
            // Land slightly ahead: the seek itself takes a moment.
            seek(to: time + 0.08 * clock.rate)
        }
    }

    private func seek(to time: Double) {
        seeking = true
        seeks += 1
        let target = CMTime(seconds: max(0, time), preferredTimescale: 600)
        Task {
            _ = await player.seek(to: target, toleranceBefore: .zero, toleranceAfter: CMTime(value: 1, timescale: 30))
            seeking = false
        }
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.isUserInteractionEnabled = false
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}

final class PlayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    // swiftlint:disable:next force_cast
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif
