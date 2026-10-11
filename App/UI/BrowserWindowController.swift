import AppKit
import UniformTypeIdentifiers

/// 压缩包浏览窗口：工具栏（解压 / 解压到… / 搜索）+ 树形列表 + 底部状态栏
final class BrowserWindowController: NSWindowController, NSWindowDelegate {

    private enum Column {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let packed = NSUserInterfaceItemIdentifier("packed")
        static let modified = NSUserInterfaceItemIdentifier("modified")
    }

    private enum ToolbarID {
        static let extract = NSToolbarItem.Identifier("extract")
        static let extractTo = NSToolbarItem.Identifier("extractTo")
        static let search = NSToolbarItem.Identifier("search")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    private let outlineView = NSOutlineView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let lockIcon = NSImageView()
    private let overlay = NSStackView()
    private let spinner = NSProgressIndicator()
    private let overlayLabel = NSTextField(wrappingLabelWithString: "")

    private var root: ArchiveNode?
    private var filtered: [ArchiveNode]?
    private var archiveType: String?
    private let dragDelegate = DragOutDelegate()

    private var archiveDocument: ArchiveDocument? { document as? ArchiveDocument }
    private var archiveURL: URL? { archiveDocument?.fileURL }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var iconCache: [String: NSImage] = [:]

    // MARK: - 初始化

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 500),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 520, height: 300)
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = false
        super.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        window.center()
        _ = window.setFrameAutosaveName("ArchiveBrowserWindow")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 界面

    private func buildContent() {
        guard let content = window?.contentView else { return }

        // 列表
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.rowSizeStyle = .default
        outlineView.style = .inset
        outlineView.autosaveExpandedItems = false
        outlineView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle

        func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat) {
            let col = NSTableColumn(identifier: id)
            col.title = title
            col.width = width
            col.minWidth = min
            if id != Column.name { col.headerCell.alignment = id == Column.modified ? .left : .right }
            outlineView.addTableColumn(col)
        }
        addColumn(Column.name, "名称", width: 360, min: 160)
        addColumn(Column.size, "大小", width: 90, min: 60)
        addColumn(Column.packed, "压缩后", width: 90, min: 60)
        addColumn(Column.modified, "修改日期", width: 150, min: 100)
        outlineView.outlineTableColumn = outlineView.tableColumns[0]

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)

        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // 状态栏
        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        lockIcon.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "已加密")
        lockIcon.contentTintColor = .secondaryLabelColor
        lockIcon.isHidden = true
        lockIcon.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        status.addSubview(separator)
        status.addSubview(statusLabel)
        status.addSubview(lockIcon)

        // 加载中 / 出错时的覆盖层
        spinner.style = .spinning
        spinner.controlSize = .regular
        overlayLabel.alignment = .center
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.preferredMaxLayoutWidth = 360
        overlay.orientation = .vertical
        overlay.spacing = 12
        overlay.alignment = .centerX
        overlay.addArrangedSubview(spinner)
        overlay.addArrangedSubview(overlayLabel)
        overlay.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(status)
        content.addSubview(overlay)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor),

            status.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 28),

            separator.topAnchor.constraint(equalTo: status.topAnchor),
            separator.leadingAnchor.constraint(equalTo: status.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: status.trailingAnchor),

            statusLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: lockIcon.leadingAnchor, constant: -8),
            lockIcon.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -14),
            lockIcon.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            lockIcon.widthAnchor.constraint(equalToConstant: 12),
            lockIcon.heightAnchor.constraint(equalToConstant: 12),

            overlay.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "ArchiveBrowserToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func showOverlay(loading: Bool, message: String) {
        overlay.isHidden = false
        spinner.isHidden = !loading
        if loading { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        overlayLabel.stringValue = message
        scrollView.isHidden = !loading && root == nil
    }

    private func hideOverlay() {
        spinner.stopAnimation(nil)
        overlay.isHidden = true
        scrollView.isHidden = false
    }

    // MARK: - 加载

    /// 由 ArchiveDocument 在关联窗口后调用
    func load() {
        guard let url = archiveURL else { return }
        showOverlay(loading: true, message: "正在读取…")
        statusLabel.stringValue = ""
        Task { @MainActor in
            var password = archiveDocument?.password ?? JobRunner.shared.password(for: url)
            while true {
                do {
                    let result = try await SevenZip.list(url, password: password)
                    archiveDocument?.password = password
                    if let password { JobRunner.shared.rememberPassword(password, for: url) }
                    archiveType = result.type
                    root = ArchiveNode.buildTree(result.entries)
                    outlineView.reloadData()
                    if let root, root.children.count == 1, root.children[0].isDirectory {
                        outlineView.expandItem(root.children[0])
                    }
                    hideOverlay()
                    updateStatus()
                    return
                } catch SevenZipError.wrongPassword {
                    guard let pw = PasswordPrompt.ask(for: url.lastPathComponent, retry: password != nil, button: "打开") else {
                        showOverlay(loading: false, message: "这个压缩包的文件名已加密，需要密码才能查看内容。")
                        return
                    }
                    password = pw
                } catch {
                    showOverlay(loading: false, message: "无法打开：\n\(error.localizedDescription)")
                    return
                }
            }
        }
    }

    private func updateStatus() {
        guard let root else { statusLabel.stringValue = ""; return }
        var parts: [String] = []
        if let filtered {
            parts.append("找到 \(filtered.count) 项")
        }
        parts.append("\(root.fileCount) 个文件")
        parts.append("共 \(Self.byteFormatter.string(fromByteCount: Int64(root.size)))")
        if let packed = root.packedSize, root.size > 0, packed > 0 {
            let ratio = Int((Double(packed) / Double(root.size) * 100).rounded())
            parts.append("压缩后 \(Self.byteFormatter.string(fromByteCount: Int64(packed)))（\(ratio)%）")
        }
        if let type = archiveType { parts.append(type) }
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
        lockIcon.isHidden = !root.encrypted
    }

    // MARK: - 操作

    private var selectedNodes: [ArchiveNode] {
        outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? ArchiveNode }
    }

    /// 在浏览窗口里点的解压：按设置执行；设置为“不做任何事”时至少在 Finder 中选中结果
    private static var afterExtractFromBrowser: AfterExtract {
        Prefs.afterExtract == .nothing ? .reveal : Prefs.afterExtract
    }

    /// 解压整个压缩包到它所在的文件夹（与右键「解压」相同的智能规则）
    @objc func extractAll(_ sender: Any?) {
        guard let url = archiveURL else { return }
        if let pw = archiveDocument?.password { JobRunner.shared.rememberPassword(pw, for: url) }
        JobRunner.shared.enqueueExtract(url, into: url.deletingLastPathComponent(), after: Self.afterExtractFromBrowser)
    }

    /// 选择目录后解压：有选中项则只解压选中项，否则解压全部
    @objc func extractTo(_ sender: Any?) {
        guard let url = archiveURL, let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "解压到这里"
        panel.directoryURL = url.deletingLastPathComponent()
        let nodes = selectedNodes
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let dir = panel.url else { return }
            if let pw = self?.archiveDocument?.password { JobRunner.shared.rememberPassword(pw, for: url) }
            if nodes.isEmpty {
                JobRunner.shared.enqueueExtract(url, into: dir, after: Self.afterExtractFromBrowser)
            } else {
                JobRunner.shared.enqueueExtractEntries(url, entries: nodes.map(\.ref), into: dir) { results in
                    if !results.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(results) }
                }
            }
        }
    }

    @objc func openSettings(_ sender: Any?) {
        SettingsWindowController.shared.present()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? ArchiveNode else { return }
        if node.isDirectory && filtered == nil {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            openEntry(node)
        }
    }

    /// 解压到缓存目录后用默认程序打开；内层压缩包用 7zMac 打开
    private func openEntry(_ node: ArchiveNode) {
        guard let url = archiveURL else { return }
        let dir: URL
        do { dir = try FileOps.makeTempDirectory() } catch {
            Alerts.showError(title: "无法打开", error: error); return
        }
        if let pw = archiveDocument?.password { JobRunner.shared.rememberPassword(pw, for: url) }
        JobRunner.shared.enqueueExtractEntries(url, entries: [node.ref], into: dir,
                                               title: "打开 \(node.name)") { results in
            guard let file = results.first else { return }
            if !node.isDirectory, ArchiveTypes.isExtractable(name: file.lastPathComponent) {
                NSDocumentController.shared.openDocument(withContentsOf: file, display: true) { _, _, _ in }
            } else {
                NSWorkspace.shared.open(file)
            }
        }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let q = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || root == nil {
            filtered = nil
        } else {
            var matches: [ArchiveNode] = []
            root?.forEachDescendant { node in
                if matches.count < 5000, node.name.localizedCaseInsensitiveContains(q) { matches.append(node) }
            }
            filtered = matches
        }
        outlineView.reloadData()
        updateStatus()
    }

    // MARK: - 图标

    private func icon(for node: ArchiveNode) -> NSImage {
        if node.isDirectory {
            if let cached = iconCache["/folder"] { return cached }
            let img = NSWorkspace.shared.icon(for: .folder)
            iconCache["/folder"] = img
            return img
        }
        let ext = (node.name as NSString).pathExtension.lowercased()
        if let cached = iconCache[ext] { return cached }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let img = NSWorkspace.shared.icon(for: type)
        iconCache[ext] = img
        return img
    }
}

// MARK: - 数据源 / 代理

extension BrowserWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let filtered { return item == nil ? filtered.count : 0 }
        let node = (item as? ArchiveNode) ?? root
        return node?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let filtered { return filtered[index] }
        let node = (item as? ArchiveNode) ?? root!
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard filtered == nil, let node = item as? ArchiveNode else { return false }
        return node.isDirectory && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? ArchiveNode, let column = tableColumn else { return nil }
        switch column.identifier {
        case Column.name:
            let cell = makeCell(Column.name, withIcon: true, alignment: .left)
            cell.textField?.stringValue = filtered == nil ? node.name : node.path
            cell.imageView?.image = icon(for: node)
            cell.toolTip = node.path
            return cell
        case Column.size:
            let cell = makeCell(Column.size, withIcon: false, alignment: .right)
            cell.textField?.stringValue = Self.byteFormatter.string(fromByteCount: Int64(node.size))
            return cell
        case Column.packed:
            let cell = makeCell(Column.packed, withIcon: false, alignment: .right)
            if let p = node.packedSize, !(node.isDirectory && p == 0) {
                cell.textField?.stringValue = Self.byteFormatter.string(fromByteCount: Int64(p))
            } else {
                cell.textField?.stringValue = "—"
            }
            return cell
        case Column.modified:
            let cell = makeCell(Column.modified, withIcon: false, alignment: .left)
            cell.textField?.stringValue = node.modified.map { Self.dateFormatter.string(from: $0) } ?? ""
            return cell
        default:
            return nil
        }
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier, withIcon: Bool,
                          alignment: NSTextAlignment) -> NSTableCellView {
        if let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView {
            return cell
        }
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = .byTruncatingMiddle
        text.alignment = alignment
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        if alignment == .right || id == Column.modified {
            text.textColor = .secondaryLabelColor
        }

        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // 拖出到 Finder：放下时才解压
    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let node = item as? ArchiveNode, let url = archiveURL else { return nil }
        let type: UTType = node.isDirectory ? .folder : (UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: dragDelegate)
        provider.userInfo = DragOutDelegate.Payload(
            archive: url, entry: node.ref,
            password: archiveDocument?.password ?? JobRunner.shared.password(for: url))
        return provider
    }
}

// MARK: - 工具栏

extension BrowserWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarID.extract, ToolbarID.extractTo, .flexibleSpace, ToolbarID.search, ToolbarID.settings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.extract:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "解压"
            item.toolTip = "解压到压缩包所在的文件夹"
            item.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "解压")
            item.isBordered = true
            item.target = self
            item.action = #selector(extractAll(_:))
            return item
        case ToolbarID.extractTo:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "解压到…"
            item.toolTip = "选择位置解压（有选中项时只解压选中项）"
            item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "解压到")
            item.isBordered = true
            item.target = self
            item.action = #selector(extractTo(_:))
            return item
        case ToolbarID.settings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = "设置"
            item.toolTip = "压缩 / 解压参数设置（⌘,）"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "设置")
            item.isBordered = true
            item.target = self
            item.action = #selector(openSettings(_:))
            return item
        case ToolbarID.search:
            let item = NSSearchToolbarItem(itemIdentifier: itemIdentifier)
            item.searchField.placeholderString = "搜索"
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.searchField.sendsSearchStringImmediately = false
            return item
        default:
            return nil
        }
    }
}

// MARK: - 拖出

extension ArchiveNode {
    var ref: SmartExtract.EntryRef { SmartExtract.EntryRef(path: path, name: name) }
}

/// NSFilePromiseProvider 的代理（在后台队列被调用，不碰界面状态）
final class DragOutDelegate: NSObject, NSFilePromiseProviderDelegate {

    struct Payload {
        let archive: URL
        let entry: SmartExtract.EntryRef
        let password: String?
    }

    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? Payload)?.entry.name ?? "未命名"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let payload = filePromiseProvider.userInfo as? Payload else {
            completionHandler(nil)
            return
        }
        let dest = url.deletingLastPathComponent()
        let sema = DispatchSemaphore(value: 0)
        let errorBox = Box<Error?>(nil)
        Task.detached {
            do {
                _ = try await SmartExtract.extractEntries(payload.archive, entries: [payload.entry], to: dest,
                                                          password: payload.password, conflict: .rename)
            } catch {
                errorBox.value = error
            }
            sema.signal()
        }
        sema.wait()
        completionHandler(errorBox.value)
    }
}
