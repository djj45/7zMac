import Cocoa
import FinderSync

/// Finder 右键一级菜单：只有「压缩」「解压」两项。
/// 扩展本身是沙盒进程，不做实际工作，只把选中路径交给主程序。
@objc(FinderSync)
final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        updateWatchedDirectories()

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(volumesChanged(_:)),
                       name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func volumesChanged(_ note: Notification) {
        updateWatchedDirectories()
    }

    /// 监视整个磁盘 + 所有已挂载的卷（U 盘、移动硬盘、NAS）
    private func updateWatchedDirectories() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        urls.formUnion(volumes)
        FIFinderSyncController.default().directoryURLs = urls
    }

    // MARK: - 菜单

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        // 只在“对选中的文件/文件夹右键”时出现；空白处右键、工具栏菜单都不出现
        guard menuKind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty
        else { return nil }

        let menu = NSMenu(title: "")

        let compress = NSMenuItem(title: "压缩", action: #selector(compressAction(_:)), keyEquivalent: "")
        compress.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        menu.addItem(compress)

        if items.contains(where: { ArchiveTypes.isExtractable($0) }) {
            let extract = NSMenuItem(title: "解压", action: #selector(extractAction(_:)), keyEquivalent: "")
            extract.image = NSImage(systemSymbolName: "shippingbox.and.arrow.backward", accessibilityDescription: nil)
                ?? NSImage(systemSymbolName: "arrow.up.bin", accessibilityDescription: nil)
            menu.addItem(extract)
        }
        return menu
    }

    @IBAction func compressAction(_ sender: AnyObject?) {
        send(.compress)
    }

    @IBAction func extractAction(_ sender: AnyObject?) {
        send(.extract)
    }

    private func send(_ op: JobRequest.Op) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }
        var paths = items.map { $0.path }
        if op == .extract {
            paths = items.filter { ArchiveTypes.isExtractable($0) }.map { $0.path }
        }
        guard !paths.isEmpty, let url = JobRequest(op: op, paths: paths).url else { return }
        // 不激活主程序：Finder 保持在前台，压缩/解压在后台进行
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.addsToRecentItems = false
        NSWorkspace.shared.open(url, configuration: config, completionHandler: nil)
    }
}
