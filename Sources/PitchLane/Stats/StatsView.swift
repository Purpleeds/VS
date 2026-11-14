#if canImport(SwiftUI)
import SwiftUI
import PitchLaneCore

/// Accuracy over time: dots per run, a faint line through them and a smoothed dashed trend.
struct TrendChart: View {
    let points: [TrendPoint]

    var body: some View {
        Canvas { context, size in
            MainActor.assumeIsolated {
                draw(&context, size: size)
            }
        }
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityLabel("Accuracy trend over \(points.count) runs")
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize) {
        let left: CGFloat = 34
        let right: CGFloat = 10
        let top: CGFloat = 10
        let bottom: CGFloat = 20
        let plotWidth = size.width - left - right
        let plotHeight = size.height - top - bottom
        func y(_ accuracy: Double) -> CGFloat { top + plotHeight * CGFloat(1 - min(1, max(0, accuracy))) }
        func x(_ index: Int) -> CGFloat {
            points.count <= 1 ? left + plotWidth / 2 : left + plotWidth * CGFloat(index) / CGFloat(points.count - 1)
        }
        for value in [0.0, 0.5, 1.0] {
            var line = Path()
            line.move(to: CGPoint(x: left, y: y(value)))
            line.addLine(to: CGPoint(x: size.width - right, y: y(value)))
            context.stroke(line, with: .color(Theme.grid.opacity(value == 0 ? 0.35 : 0.15)), lineWidth: 1)
            context.draw(
                Text("\(Int(value * 100))%").font(.system(size: 10)).foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: 4, y: y(value)),
                anchor: .leading
            )
        }
        guard !points.isEmpty else {
            context.draw(
                Text("No runs yet").font(.footnote).foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: size.width / 2, y: size.height / 2)
            )
            return
        }
        var raw = Path()
        for (index, point) in points.enumerated() {
            let p = CGPoint(x: x(index), y: y(point.accuracy))
            if index == 0 { raw.move(to: p) } else { raw.addLine(to: p) }
        }
        context.stroke(raw, with: .color(Theme.accent.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        let smooth = GameHistory.movingAverage(points.map(\.accuracy), window: 5)
        var trend = Path()
        for (index, value) in smooth.enumerated() {
            let p = CGPoint(x: x(index), y: y(value))
            if index == 0 { trend.move(to: p) } else { trend.addLine(to: p) }
        }
        if points.count > 2 {
            context.stroke(trend, with: .color(Theme.gold), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [6, 4]))
        }
        for (index, point) in points.enumerated() {
            let center = CGPoint(x: x(index), y: y(point.accuracy))
            context.fill(Path(ellipseIn: CGRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)), with: .color(Theme.accent))
        }
        let formatter = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if let first = points.first, let last = points.last {
            context.draw(
                Text(first.date.formatted(formatter)).font(.system(size: 10)).foregroundStyle(Theme.textSecondary),
                at: CGPoint(x: left, y: size.height - 2),
                anchor: .bottomLeading
            )
            if points.count > 1 {
                context.draw(
                    Text(last.date.formatted(formatter)).font(.system(size: 10)).foregroundStyle(Theme.textSecondary),
                    at: CGPoint(x: size.width - right, y: size.height - 2),
                    anchor: .bottomTrailing
                )
            }
        }
    }
}

@MainActor
private func trendSummary(_ points: [TrendPoint]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
        if let last = points.last {
            Text("Latest \(Int((last.accuracy * 100).rounded()))%")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
        }
        if let delta = GameHistory.improvement(in: points) {
            let percent = Int((delta * 100).rounded())
            Label(
                percent == 0 ? "Holding steady vs your previous runs" : "\(percent > 0 ? "+" : "")\(percent) points vs your previous runs",
                systemImage: percent >= 0 ? "arrow.up.right" : "arrow.down.right"
            )
            .font(.caption)
            .foregroundStyle(percent >= 0 ? Theme.good : Theme.warn)
        } else {
            Text("Play a few more runs to see a trend.")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}

/// Every badge: earned ones glow, the rest are locked with what it takes to earn them.
struct BadgeGrid: View {
    let earned: Set<Badge>

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(Badge.allCases) { badge in
                let has = earned.contains(badge)
                VStack(spacing: 5) {
                    BadgeCoin(badge: badge, earned: has, size: 46)
                    Text(badge.title)
                        .font(.system(.caption, design: .rounded).weight(.bold))
                        .foregroundStyle(has ? Theme.textPrimary : Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(badge.detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity)
                .opacity(has ? 1 : 0.7)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct StatsView: View {
    @EnvironmentObject private var scores: ScoreStore
    @EnvironmentObject private var settings: SettingsModel

    var body: some View {
        let trend = scores.history.trend()
        List {
            Section {
                PlayerCard(progress: PlayerProgress(history: scores.history))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }
            Section {
                BadgeGrid(earned: Set(Achievements.earned(scores.history.records).keys))
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            } header: {
                let count = Achievements.earned(scores.history.records).count
                Text("Badges · \(count) of \(Badge.allCases.count)")
            }
            Section("Accuracy trend") {
                VStack(alignment: .leading, spacing: 10) {
                    TrendChart(points: trend).frame(height: 170)
                    trendSummary(trend)
                    Text("Full-speed completed runs. Dashed line = moving average.")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section("Songs") {
                let summaries = scores.history.songSummaries
                if summaries.isEmpty {
                    Text("Your runs will show up here after you sing a song.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(summaries) { summary in
                    NavigationLink(value: Route.songStats(summary.songID)) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.title).font(.headline).foregroundStyle(Theme.textPrimary)
                                Text("\(summary.plays) run\(summary.plays == 1 ? "" : "s") · last \(summary.lastPlayed.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            if let grade = bestGrade(summary.songID) {
                                GradeBadge(grade: grade, size: 30)
                            }
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(summary.bestScore)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                                Text("best · \(Int((summary.bestAccuracy * 100).rounded()))%").font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.5))
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func bestGrade(_ songID: String) -> Grade? {
        let order: [Grade] = [.s, .a, .b, .c, .d, .f]
        return Difficulty.allCases.compactMap { scores.best(songID: songID, difficulty: $0)?.grade }
            .min { (order.firstIndex(of: $0) ?? 9) < (order.firstIndex(of: $1) ?? 9) }
    }
}

struct SongStatsView: View {
    let songID: String

    @EnvironmentObject private var scores: ScoreStore

    var body: some View {
        let records = scores.history.records(forSong: songID)
        let trend = scores.history.trend(songID: songID)
        List {
            Section("Accuracy trend") {
                VStack(alignment: .leading, spacing: 10) {
                    TrendChart(points: trend).frame(height: 170)
                    trendSummary(trend)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            }
            Section("History") {
                ForEach(records.reversed()) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.subheadline)
                                .foregroundStyle(Theme.textPrimary)
                            Text(tags(record))
                                .font(.caption)
                                .foregroundStyle(record.failed ? Theme.warn : Theme.textSecondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(record.score)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textPrimary)
                            Text("\(record.grade.rawValue) · \(Int((record.accuracy * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(GameBackdrop(intensity: 0.5))
        .navigationTitle(records.first?.songTitle ?? "Song")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func tags(_ record: GameRecord) -> String {
        var parts = [record.difficulty.displayName]
        if record.failed { parts.append("failed") }
        if record.practice { parts.append("practice \(Int((record.speed * 100).rounded()))%") }
        if record.transpose != 0 { parts.append(SongTransposer.shiftText(record.transpose)) }
        return parts.joined(separator: " · ")
    }
}
#endif
