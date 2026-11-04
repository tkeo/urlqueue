import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = QueueStore.shared

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow!
    private var cancellables = Set<AnyCancellable>()

    /// 起動直後に一覧ウィンドウを出すか（CLI からの追加で前面化する場合は true）
    var showWindowOnLaunch: Bool = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        store.start()
        buildMainMenu()
        buildStatusItem()
        buildWindow()
        observeItemCount()

        if showWindowOnLaunch {
            showWindow()
        }
    }

    // メニューバーに常駐するので、ウィンドウを閉じても終了しない
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 既に起動中のアプリに対して `open -a` された時（= CLI から URL 追加された時）に呼ばれる
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow()
        return true
    }

    // MARK: - ウィンドウ

    private func buildWindow() {
        let hosting = NSHostingView(rootView: QueueView().environmentObject(store))
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        win.title = "URL Queue"
        win.contentView = hosting
        win.isReleasedWhenClosed = false
        win.center()
        win.setFrameAutosaveName("UrlQueueMainWindow")
        window = win
    }

    @objc func showWindow() {
        popover?.performClose(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - メニューバー

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "list.bullet.rectangle",
                                   accessibilityDescription: "URL Queue")
            button.imagePosition = .imageLeading
            button.action = #selector(togglePopover)
            button.target = self
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentSize = NSSize(width: 380, height: 300)
        pop.contentViewController = NSHostingController(
            rootView: MenuBarContent(onOpenWindow: { [weak self] in self?.showWindow() })
                .environmentObject(store))
        popover = pop
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 件数をメニューバーのタイトルに出す
    private func observeItemCount() {
        store.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] items in
                self?.statusItem?.button?.title = items.isEmpty ? "" : " \(items.count)"
            }
            .store(in: &cancellables)
    }

    // MARK: - メインメニュー（Cmd+Q / Cmd+W などを有効にする）

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "URL Queue について", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "一覧を表示", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "URL Queue を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編集")
        editMenu.addItem(withTitle: "コピー", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "すべてを選択", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "ウインドウ")
        windowMenu.addItem(withTitle: "閉じる", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "しまう", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

/// ポップオーバーの中身。一覧 + ウィンドウを開くフッタ。
private struct MenuBarContent: View {
    @EnvironmentObject var store: QueueStore
    let onOpenWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            QueueView(compact: true)
            Divider()
            HStack {
                Button("ウインドウで開く", action: onOpenWindow)
                Spacer()
                Button("終了") { NSApp.terminate(nil) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}
