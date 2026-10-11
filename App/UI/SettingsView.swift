import AppKit
import FinderSync
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 窗口

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = "7zMac 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 设置界面

struct SettingsView: View {
    var body: some View {
        TabView {
            CompressSettingsView()
                .tabItem { Label("压缩", systemImage: "archivebox") }
            ExtractSettingsView()
                .tabItem { Label("解压", systemImage: "shippingbox") }
            GeneralSettingsView()
                .tabItem { Label("通用", systemImage: "gearshape") }
        }
        .padding(12)
        .frame(width: 560, height: 470)
    }
}

private struct CompressSettingsView: View {
    @AppStorage(PrefKey.format) private var format = ArchiveFormat.sevenZ.rawValue
    @AppStorage(PrefKey.level) private var level = CompressionLevel.normal.rawValue
    @AppStorage(PrefKey.solid) private var solid = true
    @AppStorage(PrefKey.threads) private var threads = 0
    @AppStorage(PrefKey.encryption) private var encryption = EncryptionMode.off.rawValue
    @AppStorage(PrefKey.encryptNames) private var encryptNames = true
    @AppStorage(PrefKey.volumeMB) private var volumeMB = 0
    @AppStorage(PrefKey.excludeJunk) private var excludeJunk = true

    @State private var fixedPassword = ""
    @State private var passwordNote = ""

    private var currentFormat: ArchiveFormat { ArchiveFormat(rawValue: format) ?? .sevenZ }

    private var threadChoices: [Int] {
        let n = ProcessInfo.processInfo.activeProcessorCount
        return [1, 2, 4, 8, 12, 16, 24, 32].filter { $0 <= n }
    }

    var body: some View {
        Form {
            Section {
                Picker("格式", selection: $format) {
                    ForEach(ArchiveFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("压缩等级", selection: $level) {
                    ForEach(CompressionLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if currentFormat == .sevenZ {
                    Toggle("固实压缩（压缩率更高，但单独取出某个文件会慢一些）", isOn: $solid)
                }
                Picker("线程数", selection: $threads) {
                    Text("自动").tag(0)
                    ForEach(threadChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("分卷", selection: $volumeMB) {
                    Text("不分卷").tag(0)
                    Text("100 MB").tag(100)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("4 GB（FAT32 U 盘）").tag(4000)
                }
                Toggle("排除 .DS_Store、__MACOSX、._* 等 mac 隐藏文件", isOn: $excludeJunk)
            }

            Section("加密") {
                if currentFormat.supportsEncryption {
                    Picker("密码", selection: $encryption) {
                        ForEach(EncryptionMode.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    if encryption == EncryptionMode.fixed.rawValue {
                        HStack {
                            SecureField("固定密码（保存在钥匙串）", text: $fixedPassword)
                            Button("保存") {
                                passwordNote = Keychain.savePassword(fixedPassword) ? "已保存" : "保存失败"
                                fixedPassword = ""
                            }
                        }
                        if !passwordNote.isEmpty {
                            Text(passwordNote).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    if currentFormat == .sevenZ, encryption != EncryptionMode.off.rawValue {
                        Toggle("同时加密文件名（不输密码看不到包里有什么）", isOn: $encryptNames)
                    }
                    if currentFormat == .zip, encryption != EncryptionMode.off.rawValue {
                        Text("ZIP 使用 AES-256 加密；Windows 自带的解压不支持，需要 7-Zip 等工具打开。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } else {
                    Text("tar.gz / tar.xz 不支持加密。").foregroundColor(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExtractSettingsView: View {
    @AppStorage(PrefKey.folderMode) private var folderMode = FolderMode.smart.rawValue
    @AppStorage(PrefKey.conflict) private var conflict = ConflictMode.rename.rawValue
    @AppStorage(PrefKey.zipCodePage) private var zipCodePage = ZipCodePage.autoGBK.rawValue
    @AppStorage(PrefKey.unwrapTar) private var unwrapTar = true
    @AppStorage(PrefKey.removeJunk) private var removeJunk = true
    @AppStorage(PrefKey.revealInFinder) private var revealInFinder = false
    @AppStorage(PrefKey.trashArchive) private var trashArchive = false
    @AppStorage(PrefKey.quarantine) private var quarantine = true

    var body: some View {
        Form {
            Section {
                Picker("新建文件夹", selection: $folderMode) {
                    ForEach(FolderMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("同名时", selection: $conflict) {
                    ForEach(ConflictMode.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("ZIP 文件名编码", selection: $zipCodePage) {
                    ForEach(ZipCodePage.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section {
                Toggle("自动解开 .tar.gz / .tar.xz 等双层压缩包", isOn: $unwrapTar)
                Toggle("删除 __MACOSX 和 .DS_Store", isOn: $removeJunk)
                Toggle("解压后在 Finder 中显示", isOn: $revealInFinder)
                Toggle("解压后把压缩包移到废纸篓", isOn: $trashArchive)
                Toggle("解出的文件继承压缩包的“来自互联网”标记（更安全）", isOn: $quarantine)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PrefKey.showProgress) private var showProgress = true
    @State private var extensionEnabled = FIFinderSyncController.isExtensionEnabled
    @State private var defaultAppNote = ""
    @State private var version = ""

    /// 设为默认时处理的后缀
    private static let defaultExtensions = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz2",
                                            "xz", "txz", "zst", "lzma", "cab", "wim", "001"]

    var body: some View {
        Form {
            Section("右键菜单") {
                HStack {
                    Image(systemName: extensionEnabled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(extensionEnabled ? .green : .orange)
                    Text(extensionEnabled ? "Finder 扩展已启用" : "Finder 扩展未启用，右键菜单不会出现")
                    Spacer()
                    Button("打开扩展设置") {
                        FIFinderSyncController.showExtensionManagementInterface()
                    }
                    Button {
                        extensionEnabled = FIFinderSyncController.isExtensionEnabled
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新状态")
                }
                Text("在「系统设置 › 通用 › 登录项与扩展 › 访达扩展」中勾选 7zMac。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("后台运行") {
                Toggle("压缩 / 解压超过一瞬间时，在右上角显示进度窗口", isOn: $showProgress)
                Text("右键压缩、解压始终在后台进行，不会打开主窗口，也不会出现在 Dock 中。")
                    .font(.caption).foregroundColor(.secondary)
            }

            Section("默认打开方式") {
                HStack {
                    Text("双击压缩包时用 7zMac 打开")
                    Spacer()
                    Button("设为默认解压工具") { setAsDefault() }
                }
                if !defaultAppNote.isEmpty {
                    Text(defaultAppNote).font(.caption).foregroundColor(.secondary)
                }
            }

            Section("关于") {
                LabeledContent("7-Zip 内核", value: version.isEmpty ? "…" : version)
                LabeledContent("缓存", value: FileOps.cacheDirectory.path)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            extensionEnabled = FIFinderSyncController.isExtensionEnabled
            if version.isEmpty {
                Task.detached {
                    let v = SevenZip.versionString()
                    await MainActor.run { version = v }
                }
            }
        }
    }

    private func setAsDefault() {
        let app = Bundle.main.bundleURL
        var seen = Set<String>()
        let types = Self.defaultExtensions.compactMap { UTType(filenameExtension: $0) }
            .filter { seen.insert($0.identifier).inserted }
        let failures = Box(0)
        let group = DispatchGroup()
        let lock = NSLock()
        for type in types {
            group.enter()
            NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type) { error in
                if error != nil {
                    lock.lock(); failures.value += 1; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let failures = failures.value
            defaultAppNote = failures == 0
                ? "已设置 \(types.count) 种格式。"
                : "\(types.count - failures) 种成功，\(failures) 种失败（可在 Finder“显示简介 › 打开方式 › 全部更改”中手动设置）。"
        }
    }
}
