import AppKit
import Foundation

enum CLI {
    static let usage = """
    urlqueue — 後で開く URL をためておく macOS アプリ

    使い方:
      urlqueue <URL>...              URL をキューに追加する（ウィンドウは前に出ない）
      urlqueue add <URL>...          同上
      urlqueue add -                 標準入力から 1 行 1 URL で追加

    add のオプション:
      --front   追加後にウィンドウを前面に出す
      --no-open アプリが未起動でも起動しない（キューに書くだけ）
      urlqueue list                  キューを一覧表示
      urlqueue open [番号]           指定番号を開いて削除（省略時は先頭）
      urlqueue open --all            すべて開いて削除
      urlqueue remove <番号>...      開かずに削除
      urlqueue clear                 すべて削除
      urlqueue gui                   GUI を起動（.app から呼ばれる）
      urlqueue path                  キューファイルのパスを表示

    キューに入れるドメイン（デフォルトブラウザとして受けたリンクの振り分け）:
      urlqueue domains                 現在の指定を表示
      urlqueue domains add <ドメイン>...   追加（サブドメインも対象になる）
      urlqueue domains remove <ドメイン>... 削除
      urlqueue domains clear           指定を解除（全部キューに入れる）
      urlqueue domains test <URL>      その URL がどう振り分けられるか確認

    開く先のブラウザ:
      urlqueue browser               現在の開く先を表示
      urlqueue browser --list        候補を一覧表示
      urlqueue browser <名前>        開く先を設定（例: urlqueue browser Chrome）
      urlqueue browser --system      システムのデフォルトに戻す

    デフォルトブラウザの乗っ取り:
      urlqueue default-browser              現在の http/https ハンドラを表示
      urlqueue default-browser set          このアプリをデフォルトブラウザにする
      urlqueue default-browser unset <名前> 指定ブラウザをデフォルトに戻す
      urlqueue --help

    番号は `urlqueue list` の表示順（1 始まり）です。
    キューは \(QueuePaths.queueFile.path) に保存されます。
    URLQUEUE_DIR 環境変数で保存先を変更できます。
    """

    /// 終了コードを返す。
    static func run(_ args: [String]) -> Int32 {
        guard let first = args.first else { return 0 }

        switch first {
        case "--help", "-h", "help":
            print(usage)
            return 0

        case "path":
            print(QueuePaths.queueFile.path)
            return 0

        case "list", "ls":
            return list()

        case "add":
            return addCommand(Array(args.dropFirst()))

        case "open":
            return open(Array(args.dropFirst()))

        case "remove", "rm", "delete":
            return remove(Array(args.dropFirst()))

        case "domains", "domain":
            return domains(Array(args.dropFirst()))

        case "browser":
            return browser(Array(args.dropFirst()))

        case "default-browser":
            return defaultBrowser(Array(args.dropFirst()))

        case "clear":
            QueueIO.mutate { $0.items.removeAll() }
            print("キューを空にしました")
            return 0

        default:
            // `urlqueue <URL>...` のショートハンド
            if first.hasPrefix("-") {
                FileHandle.standardError.write(Data("不明なオプション: \(first)\n\n\(usage)\n".utf8))
                return 2
            }
            return addCommand(args)
        }
    }

    // MARK: - サブコマンド

    private static func addCommand(_ raw: [String]) -> Int32 {
        let flags: Set<String> = ["--no-open", "--front", "--show"]
        var rest = raw
        let noLaunch = rest.contains("--no-open")
        let front = rest.contains("--front") || rest.contains("--show")
        rest.removeAll { flags.contains($0) }
        if rest == ["-"] {
            rest = readURLsFromStdin()
        }
        return add(rest, launch: !noLaunch, activate: front)
    }

    private static func add(_ raw: [String], launch: Bool, activate: Bool) -> Int32 {
        guard !raw.isEmpty else {
            FileHandle.standardError.write(Data("URL を指定してください\n".utf8))
            return 2
        }

        var accepted: [String] = []
        var rejected: [String] = []
        for s in raw {
            if let n = URLNormalizer.normalize(s) { accepted.append(n) } else { rejected.append(s) }
        }

        for bad in rejected {
            FileHandle.standardError.write(Data("URL として解釈できませんでした: \(bad)\n".utf8))
        }
        guard !accepted.isEmpty else { return 1 }

        QueueIO.mutate { f in
            for url in accepted { f.items.append(QueueItem(url: url)) }
        }
        for url in accepted { print("追加: \(url)") }

        if launch { launchApp(activate: activate) }
        return rejected.isEmpty ? 0 : 1
    }

    private static func list() -> Int32 {
        let items = QueueIO.read().items
        if items.isEmpty {
            print("キューは空です")
            return 0
        }
        let width = String(items.count).count
        for (i, item) in items.enumerated() {
            let n = String(i + 1).leftPadded(to: width)
            print("\(n). \(item.url)")
        }
        return 0
    }

    private static func open(_ args: [String]) -> Int32 {
        let items = QueueIO.read().items
        guard !items.isEmpty else {
            print("キューは空です")
            return 0
        }

        let targets: [QueueItem]
        if args.contains("--all") || args.contains("-a") {
            targets = items
        } else if let arg = args.first {
            guard let n = Int(arg), n >= 1, n <= items.count else {
                FileHandle.standardError.write(
                    Data("番号は 1〜\(items.count) で指定してください: \(arg)\n".utf8))
                return 2
            }
            targets = [items[n - 1]]
        } else {
            targets = [items[0]]
        }

        guard BrowserResolver.opener() != nil else {
            FileHandle.standardError.write(
                Data("開く先のブラウザが解決できません。`urlqueue browser <名前>` で設定してください\n".utf8))
            return 1
        }

        var openedIDs = Set<UUID>()
        for item in targets {
            guard let url = URL(string: item.url) else {
                openedIDs.insert(item.id)
                continue
            }
            if case .opened(let appName) = BrowserResolver.open(url) {
                print("開く: \(item.url)  → \(appName)")
                openedIDs.insert(item.id)
            }
        }
        QueueIO.mutate { $0.items.removeAll { openedIDs.contains($0.id) } }
        return 0
    }

    private static func remove(_ args: [String]) -> Int32 {
        let items = QueueIO.read().items
        guard !args.isEmpty else {
            FileHandle.standardError.write(Data("削除する番号を指定してください\n".utf8))
            return 2
        }

        // 先に全引数を検証してから削除する（一部だけ消える事故を防ぐ）
        var targets: [QueueItem] = []
        for arg in args {
            guard let n = Int(arg), n >= 1, n <= items.count else {
                FileHandle.standardError.write(
                    Data("番号は 1〜\(items.count) で指定してください: \(arg)\n".utf8))
                return 2
            }
            targets.append(items[n - 1])
        }

        let ids = Set(targets.map(\.id))
        QueueIO.mutate { $0.items.removeAll { ids.contains($0.id) } }
        for item in targets { print("削除: \(item.url)") }
        return 0
    }

    // MARK: - キュー対象ドメイン

    private static func domains(_ args: [String]) -> Int32 {
        var config = ConfigStore.load()
        var list = config.domains

        func save() {
            config.queueDomains = list.isEmpty ? nil : list.sorted()
            ConfigStore.save(config)
        }

        switch args.first {
        case nil, "list", "ls":
            return showDomains(list)

        case "add":
            let raw = Array(args.dropFirst())
            guard !raw.isEmpty else {
                FileHandle.standardError.write(Data("ドメインを指定してください\n".utf8))
                return 2
            }
            var added: [String] = []
            for item in raw {
                let d = QueueRouter.normalize(item)
                guard !d.isEmpty, d.contains(".") else {
                    FileHandle.standardError.write(
                        Data("ドメインとして解釈できませんでした: \(item)\n".utf8))
                    continue
                }
                guard !list.contains(d) else { continue }
                list.append(d)
                added.append(d)
            }
            guard !added.isEmpty else {
                print("追加するものがありませんでした")
                return showDomains(list)
            }
            save()
            for d in added { print("追加: \(d)") }
            return showDomains(list)

        case "remove", "rm", "delete":
            let raw = Array(args.dropFirst())
            guard !raw.isEmpty else {
                FileHandle.standardError.write(Data("ドメインを指定してください\n".utf8))
                return 2
            }
            var removed: [String] = []
            for item in raw {
                let d = QueueRouter.normalize(item)
                guard list.contains(d) else {
                    FileHandle.standardError.write(Data("指定されていません: \(item)\n".utf8))
                    continue
                }
                list.removeAll { $0 == d }
                removed.append(d)
            }
            guard !removed.isEmpty else { return 1 }
            save()
            for d in removed { print("削除: \(d)") }
            return showDomains(list)

        case "clear":
            list = []
            save()
            print("ドメイン指定を解除しました")
            return showDomains(list)

        case "test":
            guard let target = args.dropFirst().first,
                  let normalized = URLNormalizer.normalize(target),
                  let url = URL(string: normalized) else {
                FileHandle.standardError.write(Data("URL を指定してください\n".utf8))
                return 2
            }
            if QueueRouter.shouldQueue(url, domains: list) {
                let why = list.isEmpty ? "ドメイン指定が無いため" : "指定ドメインに一致"
                print("\(url.absoluteString) → キューに入れる（\(why)）")
            } else {
                let opener = BrowserResolver.opener().map(BrowserResolver.name(of:)) ?? "開く先が未設定"
                print("\(url.absoluteString) → すぐ開く（\(opener)）")
            }
            return 0

        default:
            FileHandle.standardError.write(Data("不明なサブコマンド: \(args[0])\n".utf8))
            return 2
        }
    }

    private static func showDomains(_ list: [String]) -> Int32 {
        if list.isEmpty {
            print("ドメイン指定なし: すべての URL をキューに入れます")
        } else {
            print("キューに入れるドメイン（これ以外はすぐブラウザで開きます）:")
            for d in list.sorted() { print("  \(d)") }
        }
        return 0
    }

    // MARK: - ブラウザ設定

    private static func browser(_ args: [String]) -> Int32 {
        if args.contains("--list") || args.contains("-l") {
            let candidates = BrowserResolver.candidates()
            if candidates.isEmpty {
                print("候補が見つかりませんでした")
                return 1
            }
            for app in candidates {
                let id = Bundle(url: app)?.bundleIdentifier ?? "-"
                print("\(BrowserResolver.name(of: app))  (\(id))")
            }
            return 0
        }

        if args.contains("--system") {
            var config = ConfigStore.load()
            config.openWithBundleID = nil
            ConfigStore.save(config)
            print("開く先をシステムのデフォルトに戻しました")
            return showOpener()
        }

        guard let query = args.first else { return showOpener() }

        guard let app = BrowserResolver.find(query) else {
            FileHandle.standardError.write(
                Data("ブラウザが見つかりませんでした: \(query)\n--list で候補を確認できます\n".utf8))
            return 1
        }
        guard !BrowserResolver.isSelf(app) else {
            FileHandle.standardError.write(
                Data("自分自身は開く先にできません（無限ループになります）\n".utf8))
            return 2
        }
        guard let id = Bundle(url: app)?.bundleIdentifier else {
            FileHandle.standardError.write(Data("bundle ID を取得できませんでした: \(app.path)\n".utf8))
            return 1
        }

        var config = ConfigStore.load()
        config.openWithBundleID = id
        ConfigStore.save(config)
        print("開く先を \(BrowserResolver.name(of: app)) にしました")
        return 0
    }

    private static func showOpener() -> Int32 {
        let configured = ConfigStore.load().openWithBundleID
        guard let app = BrowserResolver.opener() else {
            FileHandle.standardError.write(
                Data("開く先が解決できません。`urlqueue browser <名前>` で設定してください\n".utf8))
            return 1
        }
        let source = configured == nil ? "システムのデフォルト" : "設定値"
        print("開く先: \(BrowserResolver.name(of: app))  [\(source)]")
        print("        \(app.path)")
        return 0
    }

    // MARK: - デフォルトブラウザ

    private static func defaultBrowser(_ args: [String]) -> Int32 {
        switch args.first {
        case nil, "status":
            guard let current = DefaultBrowser.currentHandler() else {
                print("http/https のハンドラが見つかりません")
                return 1
            }
            let mark = BrowserResolver.isSelf(current) ? "（このアプリ）" : ""
            print("デフォルトブラウザ: \(BrowserResolver.name(of: current))\(mark)")
            print("                    \(current.path)")
            return 0

        case "set":
            guard let bundle = enclosingAppBundleURL() else {
                FileHandle.standardError.write(
                    Data("インストール済みの UrlQueue.app 経由で実行してください\n".utf8))
                return 2
            }
            // 乗っ取る前に、今のデフォルトブラウザを開く先として覚えておく
            if ConfigStore.load().openWithBundleID == nil,
               let current = DefaultBrowser.currentHandler(),
               !BrowserResolver.isSelf(current),
               let id = Bundle(url: current)?.bundleIdentifier {
                var config = ConfigStore.load()
                config.openWithBundleID = id
                ConfigStore.save(config)
                print("開く先を \(BrowserResolver.name(of: current)) に設定しました")
            }
            print("macOS の確認ダイアログで「\"\(BrowserResolver.name(of: bundle))\" に変更」を選んでください…")
            fflush(stdout)
            if let error = DefaultBrowser.set(to: bundle) {
                FileHandle.standardError.write(Data("失敗: \(error.localizedDescription)\n".utf8))
                return 1
            }
            return defaultBrowser([])

        case "unset":
            guard let query = args.dropFirst().first else {
                FileHandle.standardError.write(
                    Data("戻す先のブラウザを指定してください（例: urlqueue default-browser unset Chrome）\n".utf8))
                return 2
            }
            guard let app = BrowserResolver.find(query), !BrowserResolver.isSelf(app) else {
                FileHandle.standardError.write(Data("ブラウザが見つかりませんでした: \(query)\n".utf8))
                return 1
            }
            print("macOS の確認ダイアログで「\"\(BrowserResolver.name(of: app))\" に変更」を選んでください…")
            fflush(stdout)
            if let error = DefaultBrowser.set(to: app) {
                FileHandle.standardError.write(Data("失敗: \(error.localizedDescription)\n".utf8))
                return 1
            }
            return defaultBrowser([])

        default:
            FileHandle.standardError.write(
                Data("不明なサブコマンド: \(args[0])\n".utf8))
            return 2
        }
    }

    // MARK: - ヘルパ

    private static func readURLsFromStdin() -> [String] {
        var lines: [String] = []
        while let line = readLine(strippingNewline: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { lines.append(t) }
        }
        return lines
    }

    /// 自分自身が入っている .app を起動する。
    ///
    /// 起動済みの場合、追加した URL は queue.json のファイル監視で即座に一覧へ反映される。
    /// そのため前面化を明示的に頼まれていない限り、何もしない（作業の邪魔をしない）。
    private static func launchApp(activate: Bool) {
        guard let bundle = enclosingAppBundleURL() else { return }

        let isRunning = !NSRunningApplication
            .runningApplications(withBundleIdentifier: BrowserResolver.selfBundleID).isEmpty
        if isRunning && !activate { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        if !activate {
            // 新規起動でもウィンドウを出さないよう GUI 側へ伝える
            config.arguments = ["gui", "--background"]
        }

        let semaphore = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: bundle, configuration: config) { _, error in
            if let error {
                FileHandle.standardError.write(
                    Data("アプリの起動に失敗しました: \(error.localizedDescription)\n".utf8))
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    /// 実行ファイルが <Something>.app/Contents/MacOS/urlqueue にあるかを辿る。
    static func enclosingAppBundleURL() -> URL? {
        let exe = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
            .resolvingSymlinksInPath()
        // urlqueue -> MacOS -> Contents -> Foo.app
        let candidate = exe
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        guard candidate.pathExtension == "app",
              FileManager.default.fileExists(atPath: candidate.path)
        else { return nil }
        return candidate
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
