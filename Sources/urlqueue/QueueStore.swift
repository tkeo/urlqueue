import AppKit
import Combine
import Foundation

/// GUI 側の状態。queue.json を唯一の真実とし、外部からの変更を監視して反映する。
@MainActor
final class QueueStore: ObservableObject {
    static let shared = QueueStore()

    @Published private(set) var items: [QueueItem] = []

    private var dirFD: Int32 = -1
    private var dirSource: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    private init() {}

    // MARK: - ライフサイクル

    func start() {
        reload()
        startWatching()
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(externalChange),
            name: QueueIO.changedNotification,
            object: nil)
    }

    @objc private func externalChange() {
        scheduleReload(after: 0.02)
    }

    func reload() {
        items = QueueIO.read().items
    }

    /// 連続した変更をまとめる。
    private func scheduleReload(after delay: TimeInterval) {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reloadWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - ファイル監視

    /// queue.json は rename(2) で差し替えるため、ファイルではなくディレクトリを監視する。
    private func startWatching() {
        QueuePaths.ensureDir()
        stopWatching()

        let fd = open(QueuePaths.dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        dirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)

        source.setEventHandler { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.scheduleReload(after: 0.05)
                // ディレクトリ自体が消えた/移動した場合は張り直す
                let data = source.data
                if data.contains(.delete) || data.contains(.rename) {
                    self.scheduleRewatch()
                }
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        dirSource = source
    }

    private func scheduleRewatch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated { self?.startWatching() }
        }
    }

    private func stopWatching() {
        dirSource?.cancel()  // cancel handler が fd を閉じる
        dirSource = nil
        dirFD = -1
    }

    // MARK: - 操作

    /// URL を追加する。戻り値は実際に追加された件数。
    @discardableResult
    func add(_ rawURLs: [String]) -> Int {
        let normalized = rawURLs.compactMap(URLNormalizer.normalize)
        guard !normalized.isEmpty else { return 0 }
        let file = QueueIO.mutate { f in
            for url in normalized {
                f.items.append(QueueItem(url: url))
            }
        }
        items = file.items
        return normalized.count
    }

    /// デフォルトブラウザで開き、一覧から削除する。
    func openAndRemove(_ item: QueueItem) {
        if let url = URL(string: item.url) {
            NSWorkspace.shared.open(url)
        }
        remove(item)
    }

    func remove(_ item: QueueItem) {
        remove(ids: [item.id])
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let file = QueueIO.mutate { f in
            f.items.removeAll { ids.contains($0.id) }
        }
        items = file.items
    }

    func openAll() {
        let snapshot = items
        guard !snapshot.isEmpty else { return }
        for item in snapshot {
            if let url = URL(string: item.url) {
                NSWorkspace.shared.open(url)
            }
        }
        remove(ids: Set(snapshot.map(\.id)))
    }

    func clear() {
        let file = QueueIO.mutate { $0.items.removeAll() }
        items = file.items
    }

    func copyToClipboard(_ item: QueueItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.url, forType: .string)
    }
}
