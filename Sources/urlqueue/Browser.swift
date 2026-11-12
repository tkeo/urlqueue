import AppKit
import Foundation

// MARK: - 設定

struct Config: Codable {
    var version: Int = 1
    /// 一覧から開くときに使うブラウザの bundle ID。nil ならシステムのデフォルト。
    /// 自分自身をデフォルトブラウザにする場合は、ここを必ず埋める必要がある。
    var openWithBundleID: String?
    /// キューに入れるドメイン。空／未設定なら全部キューに入れる（従来どおり）。
    /// 省略されている古い config.json も読めるよう Optional にしてある。
    var queueDomains: [String]?

    var domains: [String] { queueDomains ?? [] }
}

// MARK: - 振り分け

/// 受け取った URL をキューに入れるか、そのままブラウザで開くかを決める。
enum QueueRouter {
    /// キュー対象か。ドメイン指定が空のときは全部キューに入れる。
    static func shouldQueue(_ url: URL, domains: [String]) -> Bool {
        guard !domains.isEmpty else { return true }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return true }
        return domains.contains { matches(host: host, pattern: $0) }
    }

    /// example.com は example.com 自身とそのサブドメインにマッチする。
    static func matches(host: String, pattern: String) -> Bool {
        let p = normalize(pattern)
        guard !p.isEmpty else { return false }
        return host == p || host.hasSuffix("." + p)
    }

    /// 入力のゆらぎを吸収して裸のホスト名にする。
    /// "https://Example.com/a", "*.example.com", ".example.com", "example.com:8080"
    /// はいずれも "example.com" になる。
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return "" }

        if let url = URL(string: s), let host = url.host, !host.isEmpty {
            return trimDots(host)
        }
        // スキームが無い場合。パスやポートが付いていても落とす
        if let slash = s.firstIndex(of: "/") { s = String(s[s.startIndex..<slash]) }
        if let colon = s.firstIndex(of: ":") { s = String(s[s.startIndex..<colon]) }
        return trimDots(s)
    }

    private static func trimDots(_ host: String) -> String {
        var s = host
        if s.hasPrefix("*.") { s = String(s.dropFirst(2)) }
        while s.hasPrefix(".") { s = String(s.dropFirst()) }
        while s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }
}

enum ConfigStore {
    static var file: URL { QueuePaths.dir.appendingPathComponent("config.json") }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: file) else { return Config() }
        return (try? JSONDecoder().decode(Config.self, from: data)) ?? Config()
    }

    static func save(_ config: Config) {
        QueuePaths.ensureDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(config) else { return }
        let tmp = QueuePaths.dir.appendingPathComponent("config.json.tmp.\(getpid())")
        guard (try? data.write(to: tmp, options: .atomic)) != nil else { return }
        if rename(tmp.path, file.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
        }
        QueueIO.notifyChanged()
    }
}

// MARK: - ブラウザの解決

enum BrowserResolver {
    static let selfBundleID = "com.github.takeo.urlqueue"

    /// http(s) を開けるアプリを探すための当たり障りのない URL
    private static let probeURL = URL(string: "https://example.com")!

    static func isSelf(_ appURL: URL) -> Bool {
        Bundle(url: appURL)?.bundleIdentifier == selfBundleID
    }

    static func name(of appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
    }

    /// https を開けるアプリ一覧（自分自身は除く）
    static func candidates() -> [URL] {
        NSWorkspace.shared.urlsForApplications(toOpen: probeURL)
            .filter { !isSelf($0) }
            .sorted { name(of: $0).localizedCaseInsensitiveCompare(name(of: $1)) == .orderedAscending }
    }

    /// 名前・bundle ID・パスのいずれかで候補を引く
    static func find(_ query: String) -> URL? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }

        // パス指定
        if q.hasSuffix(".app") || q.hasPrefix("/") {
            let url = URL(fileURLWithPath: (q as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // bundle ID 指定
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: q) { return url }
        // 表示名の部分一致
        let all = candidates()
        return all.first { name(of: $0).localizedCaseInsensitiveCompare(q) == .orderedSame }
            ?? all.first { name(of: $0).localizedCaseInsensitiveContains(q) }
    }

    /// 実際に URL を開くアプリ。nil なら「開けるブラウザが無い」。
    static func opener() -> URL? {
        if let id = ConfigStore.load().openWithBundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
           !isSelf(url) {
            return url
        }
        // 未設定ならシステムのデフォルト。ただし自分自身なら使えない（無限ループになる）
        if let fallback = NSWorkspace.shared.urlForApplication(toOpen: probeURL), !isSelf(fallback) {
            return fallback
        }
        return nil
    }

    enum OpenResult {
        case opened(appName: String)
        /// 自分がデフォルトブラウザで、かつ開く先が未設定。開くとループするので拒否する。
        case noBrowserConfigured
    }

    @discardableResult
    static func open(_ url: URL) -> OpenResult {
        guard let app = opener() else { return .noBrowserConfigured }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        return .opened(appName: name(of: app))
    }
}

// MARK: - デフォルトブラウザの切り替え

enum DefaultBrowser {
    /// http / https の両方を登録しないとデフォルトブラウザとして扱われない
    static let schemes = ["http", "https"]

    static func currentHandler() -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
    }

    static var isSelf: Bool {
        guard let current = currentHandler() else { return false }
        return BrowserResolver.isSelf(current)
    }

    /// http/https のハンドラを appURL に差し替える。macOS がユーザーに確認ダイアログを出す。
    /// ユーザーがダイアログを操作するまで待つので、タイムアウトは長めに取る。
    static func set(to appURL: URL, timeout: TimeInterval = 600) -> Error? {
        guard #available(macOS 14.0, *) else {
            return NSError(domain: "urlqueue", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "macOS 14 以降が必要です。システム設定 > デスクトップとDock > デフォルトのWebブラウザ から変更してください"
            ])
        }

        var lastError: Error?
        for scheme in schemes {
            let semaphore = DispatchSemaphore(value: 0)
            NSWorkspace.shared.setDefaultApplication(at: appURL, toOpenURLsWithScheme: scheme) { error in
                if let error { lastError = error }
                semaphore.signal()
            }
            // 確認ダイアログを操作してもらう必要があるので、RunLoop を回しながら待つ
            let deadline = Date().addingTimeInterval(timeout)
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
                if Date() > deadline {
                    return NSError(domain: "urlqueue", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "タイムアウトしました（\(scheme)）"
                    ])
                }
            }
            if lastError != nil { break }
        }
        return lastError
    }
}

extension URL {
    /// 自身が .app バンドルならそれを返す
    var asAppBundle: URL? { pathExtension == "app" ? self : nil }
}
