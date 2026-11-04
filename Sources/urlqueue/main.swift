import AppKit

/// GUI を起動する。main.swift のトップレベルは main スレッドで走るので
/// assumeIsolated で @MainActor に入る。
func launchGUI() -> Never {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        delegate.showWindowOnLaunch = true
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // delegate は app が強参照しないので保持しておく
        retainedDelegate = delegate
        app.run()
    }
    exit(0)
}

var retainedDelegate: AnyObject?

// 引数なし（Finder / open -a からの起動）→ GUI
// 引数あり（シェルからの起動）→ CLI
let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty || args == ["gui"] {
    launchGUI()
} else {
    exit(CLI.run(args))
}
