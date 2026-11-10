import AppKit
import Combine
import Foundation

/// GUI 側の状態。queue.json を唯一の真実とし、外部からの変更を監視して反映する。
@MainActor
final class QueueStore: ObservableObject {
    static let shared = QueueStore()

    @Published private(set) var items: [QueueItem] = []

    /// 一覧から開くときに使うブラウザ（nil なら未解決 = 開けない）
    @Published private(set) var openerURL: URL?
    /// 自分自身が http/https のデフォルトハンドラになっているか
    @Published private(set) var isDefaultBrowser: Bool = false
    /// 開く先が無くて開けなかったときに出す警告
    @Published var openFailureMessage: String?

    var openerName: String? { openerURL.map(BrowserResolver.name(of:)) }

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
        refreshBrowserState()
    }

    /// config.json / LaunchServices 由来の状態を読み直す
    func refreshBrowserState() {
        openerURL = BrowserResolver.opener()
        isDefaultBrowser = DefaultBrowser.isSelf
    }

    /// 開く先の候補（起動のたびに変わるものではないのでキャッシュする）
    lazy var browserCandidates: [URL] = BrowserResolver.candidates()

    /// 自分自身を http/https のデフォルトハンドラにする。macOS が確認ダイアログを出す。
    func makeDefaultBrowser() {
        guard let bundle = CLI.enclosingAppBundleURL() ?? Bundle.main.bundleURL.asAppBundle else {
            openFailureMessage = "インストール済みの UrlQueue.app から実行してください"
            return
        }
        // 乗っ取る前に、今のデフォルトブラウザを「開く先」として覚えておく。
        // これをしないと自分自身にリダイレクトし続けて URL を開けなくなる。
        if ConfigStore.load().openWithBundleID == nil,
           let current = DefaultBrowser.currentHandler(),
           !BrowserResolver.isSelf(current) {
            setOpener(current)
        }
        if let error = DefaultBrowser.set(to: bundle) {
            openFailureMessage = error.localizedDescription
        } else {
            openFailureMessage = nil
        }
        refreshBrowserState()
    }

    func setOpener(_ appURL: URL?) {
        var config = ConfigStore.load()
        config.openWithBundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        ConfigStore.save(config)
        refreshBrowserState()
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

    /// 設定されたブラウザで開き、一覧から削除する。
    /// 開く先が解決できないときは削除せず警告を出す（URL を失わないため）。
    func openAndRemove(_ item: QueueItem) {
        guard let url = URL(string: item.url) else {
            remove(item)
            return
        }
        switch BrowserResolver.open(url) {
        case .opened:
            openFailureMessage = nil
            remove(item)
        case .noBrowserConfigured:
            openFailureMessage = noBrowserMessage
        }
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
        guard BrowserResolver.opener() != nil else {
            openFailureMessage = noBrowserMessage
            return
        }
        var openedIDs = Set<UUID>()
        for item in snapshot {
            guard let url = URL(string: item.url) else {
                openedIDs.insert(item.id)
                continue
            }
            if case .opened = BrowserResolver.open(url) { openedIDs.insert(item.id) }
        }
        openFailureMessage = nil
        remove(ids: openedIDs)
    }

    private var noBrowserMessage: String {
        "開く先のブラウザが設定されていません。このアプリ自身がデフォルトブラウザなので、"
        + "開く先を明示的に選んでください。"
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
