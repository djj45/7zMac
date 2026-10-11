import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 启动时是否收到了要打开的文件 / 右键任务（收到了就不弹设置窗口）
    private var receivedOpenRequest = false
    private var lastOpenRequest = Date.distantPast
    private var idleTask: Task<Void, Never>?

    /// 没有窗口、没有任务时，多久后自动退出
    private let idleQuitDelay: TimeInterval = 60

    // MARK: - 生命周期

    func applicationWillFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        // 默认作为“后台应用”（无 Dock 图标），被右键菜单唤起时不打扰；有窗口时再切换为普通应用
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build()

        JobRunner.shared.onActivity = { [weak self] in self?.cancelIdleQuit() }
        JobRunner.shared.onIdle = { [weak self] in self?.scheduleIdleQuitIfNeeded() }

        let nc = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification,
                     NSWindow.willCloseNotification] {
            nc.addObserver(self, selector: #selector(windowsChanged(_:)), name: name, object: nil)
        }

        FileOps.clearCache(olderThan: 24 * 3600)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 只有“直接打开 App”（启动台 / Dock / 双击 App）才显示设置窗口；
        // 被右键菜单（URL）或双击压缩包唤起时 isDefaultLaunch 为 false，保持后台运行。
        let isDefaultLaunch = (notification.userInfo?["NSApplicationLaunchIsDefaultLaunchKey"] as? Bool) ?? true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let self else { return }
            if isDefaultLaunch && !self.receivedOpenRequest && !self.hasUserWindow && !JobRunner.shared.isBusy {
                SettingsWindowController.shared.present()
            }
            self.scheduleIdleQuitIfNeeded()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedOpenRequest = true
        lastOpenRequest = Date()
        for url in urls {
            if let request = JobRequest(url: url) {
                JobRunner.shared.handle(request)
            } else if url.isFileURL {
                NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error {
                        Alerts.showError(title: "无法打开“\(url.lastPathComponent)”", error: error)
                    }
                }
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 右键任务唤起时系统也可能发“重新打开”事件：刚收到任务或正在干活时不弹设置
        let recentlyRequested = Date().timeIntervalSince(lastOpenRequest) < 3
        if !flag && !recentlyRequested && !JobRunner.shared.isBusy {
            SettingsWindowController.shared.present()
        }
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard JobRunner.shared.isBusy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "还有任务在进行"
        alert.informativeText = "退出会取消正在进行的压缩/解压。"
        alert.addButton(withTitle: "继续任务")
        alert.addButton(withTitle: "取消任务并退出")
        if alert.runModal() == .alertSecondButtonReturn {
            JobRunner.shared.cancelAll()
            return .terminateNow
        }
        return .terminateCancel
    }

    // MARK: - 菜单动作

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    // MARK: - Dock 图标 / 空闲退出

    private var hasUserWindow: Bool {
        NSApp.windows.contains { w in
            w.isVisible && !(w is NSPanel)
                && (w.windowController is BrowserWindowController || w.windowController is SettingsWindowController)
        }
    }

    @objc private func windowsChanged(_ note: Notification) {
        // willClose 时窗口仍可见，稍后再判断
        Task { @MainActor [weak self] in
            self?.updateActivationPolicy()
        }
    }

    private func updateActivationPolicy() {
        let wantRegular = hasUserWindow
        let desired: NSApplication.ActivationPolicy = wantRegular ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            NSApp.setActivationPolicy(desired)
            if wantRegular { NSApp.activate(ignoringOtherApps: true) }
        }
        if wantRegular { cancelIdleQuit() } else { scheduleIdleQuitIfNeeded() }
    }

    private func cancelIdleQuit() {
        idleTask?.cancel()
        idleTask = nil
    }

    private func scheduleIdleQuitIfNeeded() {
        cancelIdleQuit()
        guard !JobRunner.shared.isBusy, !hasUserWindow else { return }
        let delay = UInt64(idleQuitDelay * 1_000_000_000)
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self else { return }
            guard !JobRunner.shared.isBusy, !self.hasUserWindow else { return }
            NSApp.terminate(nil)
        }
    }
}
