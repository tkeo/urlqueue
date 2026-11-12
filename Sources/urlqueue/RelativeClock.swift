import Combine
import Foundation

/// 相対時刻表示（「3 分前」）を定期的に更新するための共有時計。
///
/// `Text(date, format: .relative)` は body を評価した時点の文字列を焼き込むだけで、
/// 時間が経っても SwiftUI は再評価してくれない。このクラスが `now` を発行し直すことで
/// 表示中の行をまとめて更新する。
@MainActor
final class RelativeClock: ObservableObject {
    static let shared = RelativeClock()

    /// 相対時刻の基準。これが変わると購読しているビューが再描画される。
    @Published private(set) var now = Date()

    /// 表示中の行の数。0 ならタイマーを止める（常駐アプリなので無駄に起こさない）。
    private var subscribers = 0
    private var timer: Timer?

    private let interval: TimeInterval = 10

    private init() {}

    /// 行が画面に出たときに呼ぶ。最初の 1 件でタイマーが動き出す。
    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        now = Date()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// 行が画面から消えたときに呼ぶ。最後の 1 件でタイマーを止める。
    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.dateTimeStyle = .numeric
        f.unitsStyle = .full
        return f
    }()

    /// 1 分未満は「たった今」。数値表示だと「0 秒前」になってしまうため。
    static func string(for date: Date, relativeTo now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed >= 0 && elapsed < 60 { return "たった今" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
