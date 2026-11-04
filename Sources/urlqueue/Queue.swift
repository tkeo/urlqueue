import Foundation

// MARK: - Model

struct QueueItem: Codable, Identifiable, Equatable {
    var id: UUID
    var url: String
    var title: String?
    var addedAt: Date

    init(id: UUID = UUID(), url: String, title: String? = nil, addedAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.addedAt = addedAt
    }

    /// 表示用の見出し。title があればそれ、なければホスト名。
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let host = URL(string: url)?.host, !host.isEmpty { return host }
        return url
    }
}

struct QueueFile: Codable {
    var version: Int = 1
    var items: [QueueItem] = []
}

// MARK: - Paths

enum QueuePaths {
    /// URLQUEUE_DIR で差し替え可能（テスト用）。既定は ~/.urlqueue
    static var dir: URL {
        let env = ProcessInfo.processInfo.environment["URLQUEUE_DIR"] ?? ""
        if !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".urlqueue", isDirectory: true)
    }

    static var queueFile: URL { dir.appendingPathComponent("queue.json") }
    static var lockFile: URL { dir.appendingPathComponent("lock") }

    @discardableResult
    static func ensureDir() -> Bool {
        (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
    }
}

// MARK: - URL 正規化

enum URLNormalizer {
    /// ユーザー入力を開ける URL 文字列に正規化する。無効なら nil。
    static func normalize(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // 既にスキーム付き
        if let u = URL(string: s), let scheme = u.scheme, !scheme.isEmpty {
            // file:// や http(s):// 等はそのまま通す
            return u.absoluteString
        }

        // スキームなし。ドメインらしければ https:// を補う
        let candidate = "https://" + s
        guard let u = URL(string: candidate), let host = u.host, host.contains(".") else {
            return nil
        }
        return u.absoluteString
    }
}

// MARK: - 排他制御付きファイル I/O

enum QueueIO {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let changedNotification = Notification.Name("com.github.takeo.urlqueue.changed")

    /// flock(2) による排他ロック下で body を実行する。
    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        QueuePaths.ensureDir()
        let fd = open(QueuePaths.lockFile.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            // ロックが取れなくても処理自体は進める（単独利用なら実害なし）
            return try body()
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        flock(fd, LOCK_EX)
        return try body()
    }

    private static func readUnlocked() -> QueueFile {
        guard let data = try? Data(contentsOf: QueuePaths.queueFile) else { return QueueFile() }
        return (try? decoder.decode(QueueFile.self, from: data)) ?? QueueFile()
    }

    private static func writeUnlocked(_ file: QueueFile) throws {
        QueuePaths.ensureDir()
        let data = try encoder.encode(file)
        // 同一ディレクトリに書いて rename(2) で原子的に差し替える
        let tmp = QueuePaths.dir.appendingPathComponent("queue.json.tmp.\(getpid())")
        try data.write(to: tmp, options: .atomic)
        if rename(tmp.path, QueuePaths.queueFile.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: "queue.json の書き込みに失敗しました"])
        }
    }

    static func read() -> QueueFile {
        withLock { readUnlocked() }
    }

    /// ロック下で読み→変更→書き戻し。変更後の内容を返す。
    @discardableResult
    static func mutate(_ body: (inout QueueFile) -> Void) -> QueueFile {
        let result: QueueFile = withLock {
            var file = readUnlocked()
            body(&file)
            try? writeUnlocked(file)
            return file
        }
        notifyChanged()
        return result
    }

    /// 他プロセス（GUI）へ即時反映を促す。ファイル監視もあるので失敗しても最終的に追いつく。
    static func notifyChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
