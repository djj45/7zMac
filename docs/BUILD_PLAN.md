# 7zMac 构建方案：基于 7-Zip 源码的 macOS 原生压缩/解压工具

> 版本基线：7-Zip **26.04**（2026-10-05 发布，源码 `7z2604-src.tar.xz`）
> 目标系统：macOS 13 Ventura 及以上，Apple Silicon + Intel（Universal）
> 应用名 `7zMac`、Bundle ID 前缀 `local.djj45` 均为占位，可随意替换。

---

## 0. 需求清单（验收标准）

| # | 需求 | 实现方式 |
|---|------|---------|
| R1 | 用 7-Zip 源码构建 | 从官方源码编译 `7zz`（Alone2 bundle，全格式），打包进 App |
| R2 | 原生 mac GUI，界面简洁 | Swift + AppKit/SwiftUI，基于 `NSDocument` 的只读压缩包浏览窗口 |
| R3 | 关联压缩包后缀，双击打开浏览界面 | `Info.plist` 声明 `CFBundleDocumentTypes` + `UTImportedTypeDeclarations`，设置页提供“设为默认” |
| R4 | 右键**一级菜单**只有「压缩」「解压」 | **Finder Sync 扩展**（不能用 Quick Action / Services，它们会进二级子菜单） |
| R5 | 点「压缩」直接生成压缩包 | 按设置页的默认参数在同目录生成，无对话框 |
| R6 | 点「解压」解压到当前文件夹，智能处理嵌套 | 先解到同卷隐藏临时目录，看顶层项数：=1 直接移出；>1 建“压缩包同名文件夹” |
| R7 | 参数在界面另外设置 | 独立的「设置」窗口（压缩 / 解压 / 通用 三个标签页） |

---

## 1. 总体架构

```
┌──────────────────────── 7zMac.app（非沙盒，主程序）────────────────────────┐
│                                                                           │
│  Contents/MacOS/7zMac        Swift 主程序                                  │
│    ├─ ArchiveDocument        双击压缩包 → 浏览窗口（列表/解压/拖出）         │
│    ├─ JobRunner              执行压缩/解压任务、进度面板、错误提示            │
│    ├─ SmartExtract           智能文件夹逻辑                                 │
│    ├─ SevenZip               调用 7zz 的进程封装 + 输出解析                  │
│    └─ Settings               设置窗口（UserDefaults）                       │
│  Contents/MacOS/7zz          从 7-Zip 26.04 源码编译的 Universal 可执行文件   │
│                                                                           │
│  Contents/PlugIns/7zMacFinder.appex（沙盒，Finder Sync 扩展）               │
│    └─ 只负责：显示「压缩」「解压」两个一级菜单项 → 把选中路径交给主程序          │
└───────────────────────────────────────────────────────────────────────────┘
         扩展 ──(打开 URL：sevenzipmac://job?d=<base64url(JSON)>)──▶ 主程序
```

### 1.1 为什么调用 `7zz` 命令行，而不是把 7-Zip 编成库链接？

| 方案 | 优点 | 缺点 |
|------|------|------|
| **A. 内嵌 `7zz` 可执行文件，Swift 用 `Process` 调用（推荐）** | 官方 makefile 原生支持 mac；与 7-Zip 升级解耦（换个二进制即可）；崩溃隔离；取消任务=结束进程，干净 | 需要解析文本输出 |
| B. 编译 `7z.so`/静态库，用 Objective-C++ 桥接 `IInArchive` COM 接口 | 无文本解析，回调拿进度更精细 | 7-Zip 的 COM 风格接口在 mac 上桥接工作量大（≈3–5 倍），升级源码要跟着改 |

本方案采用 **A**。`7zz -slt` 的列表输出是稳定的 `Key = Value` 格式，解析很简单；`-bsp1` 可以拿到百分比进度。

### 1.2 为什么右键菜单必须用 Finder Sync 扩展？

- **Quick Actions（快速操作）/ Services（服务）** 在 Finder 右键菜单中会被收进「快速操作 ▸」或「服务 ▸」二级子菜单，不满足 R4。
- **Finder Sync Extension** 的 `menu(for: .contextualMenuForItems)` 返回的菜单项直接出现在右键菜单**第一级**。
- 代价：
  1. 扩展必须沙盒化 → 扩展本身不做压缩/解压，只把路径转交主程序（主程序不沙盒，可以读写任意目录）。
  2. 需要用户在「系统设置 › 通用 › 登录项与扩展 › 访达扩展（Finder）」里勾选一次（设置页提供跳转按钮）。
  3. 需要监视目录：把 `directoryURLs` 设为 `/` 并追加所有已挂载卷，覆盖全盘。

---

## 2. 环境准备

```bash
# 代理（下载源码、Homebrew 都走这个）
export http_proxy="http://127.0.0.1:20122"
export https_proxy="http://127.0.0.1:20122"

# 1) 完整 Xcode（不是只有 Command Line Tools；App Extension 和签名需要完整 Xcode）
xcode-select -p                       # 应指向 /Applications/Xcode.app/Contents/Developer
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer   # 如不是则切换

# 2) XcodeGen：用 project.yml 文本描述工程，避免手工点 Xcode 配 target
brew install xcodegen

# 3) Xcode › Settings › Accounts 登录 Apple ID（免费的 Personal Team 即可）
#    Finder Sync 扩展用 ad-hoc 签名（"-"）经常不被 pluginkit 加载，
#    用 Apple Development 证书签名最省事。记下 Team ID（10 位字符）。
```

---

## 3. 目录结构

```
~/code/7z/
├── BUILD_PLAN.md                  ← 本文档
├── project.yml                    ← XcodeGen 工程描述
├── scripts/
│   ├── fetch-7zip.sh              ← 下载并校验 7-Zip 源码
│   ├── build-7zz.sh               ← 编译 arm64 + x86_64，lipo 成 Universal
│   └── build-app.sh               ← 一键：7zz → xcodegen → xcodebuild → 安装到 /Applications
├── vendor/
│   ├── 7zip/                      ← 解包后的 7-Zip 源码（不改动，只打补丁）
│   ├── patches/
│   │   └── 0001-zip-codepage-iconv.patch   ← 中文 ZIP 文件名乱码修复（见 §5）
│   └── bin/7zz                    ← 编译产物（Universal）
├── Shared/                        ← 主程序与扩展共用
│   ├── ArchiveTypes.swift         ← 后缀表、分卷识别、去扩展名
│   └── JobRequest.swift           ← 扩展→主程序 的请求结构与 URL 编解码
├── App/
│   ├── Info.plist                 ← 文档类型关联、URL Scheme
│   ├── 7zMac.entitlements         ← 非沙盒 + Hardened Runtime
│   ├── AppDelegate.swift          ← URL 事件、激活策略
│   ├── Engine/
│   │   ├── SevenZip.swift         ← Process 封装（list/extract/add/test）
│   │   ├── ListParser.swift       ← 解析 `7zz l -slt`
│   │   ├── ProgressParser.swift   ← 解析 `-bsp1`
│   │   ├── SmartExtract.swift     ← 智能文件夹算法
│   │   ├── Compressor.swift       ← 压缩命名 + 参数拼装
│   │   └── JobRunner.swift        ← 任务队列、取消、错误
│   ├── UI/
│   │   ├── ArchiveDocument.swift  ← NSDocument 子类（只读）
│   │   ├── BrowserView.swift      ← 浏览窗口
│   │   ├── ProgressPanel.swift    ← 浮动进度小面板
│   │   ├── PasswordPrompt.swift
│   │   └── SettingsView.swift     ← 设置窗口
│   └── Resources/Assets.xcassets
└── FinderExt/
    ├── Info.plist
    ├── FinderExt.entitlements     ← 沙盒
    └── FinderSync.swift
```

---

## 4. 第一步：从源码编译 7zz

### 4.1 下载源码 `scripts/fetch-7zip.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
export http_proxy="${http_proxy:-http://127.0.0.1:20122}"
export https_proxy="${https_proxy:-http://127.0.0.1:20122}"

VER=26.04; TAG=2604
cd "$(dirname "$0")/../vendor"
curl -fL -o "7z${TAG}-src.tar.xz" \
  "https://github.com/ip7z/7zip/releases/download/${VER}/7z${TAG}-src.tar.xz"
rm -rf 7zip && mkdir 7zip
tar -xf "7z${TAG}-src.tar.xz" -C 7zip
# 打补丁（§5）
for p in patches/*.patch; do patch -d 7zip -p1 < "$p"; done
```

### 4.2 编译 `scripts/build-7zz.sh`

7-Zip 源码自带 mac 专用 makefile：`CPP/7zip/cmpl_mac_arm64.mak`、`cmpl_mac_x64.mak`，输出目录分别是 `b/m_arm64/`、`b/m_x64/`。`Alone2` 是全功能控制台版（即 `7zz`，含 RAR 解压等全部格式）。

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/vendor/7zip/CPP/7zip/Bundles/Alone2"
JOBS="$(sysctl -n hw.ncpu)"
export MACOSX_DEPLOYMENT_TARGET=13.0

cd "$SRC"
# MY_LIBS=-liconv：补丁里用到 iconv（§5）
make -j"$JOBS" -f ../../cmpl_mac_arm64.mak MY_LIBS=-liconv
make -j"$JOBS" -f ../../cmpl_mac_x64.mak   MY_LIBS=-liconv

mkdir -p "$ROOT/vendor/bin"
lipo -create b/m_arm64/7zz b/m_x64/7zz -output "$ROOT/vendor/bin/7zz"
lipo -info "$ROOT/vendor/bin/7zz"          # 应显示 x86_64 arm64
"$ROOT/vendor/bin/7zz" i | head -40       # 查看支持的格式
```

验收：`vendor/bin/7zz` 能在本机运行，`7zz i` 列出 7z/zip/rar/tar/gzip/bzip2/xz/iso/... 等格式。

> 注：x86_64 的 makefile 设置了 `USE_ASM=` （不用汇编），arm64 用 `USE_ASM=1`，都不需要额外装 asmc/uasm。

---

## 5. 7-Zip 源码补丁：中文 ZIP 文件名乱码（必须做）

**问题**：Windows 上（中文系统）打的 ZIP，文件名通常是 GBK 编码且不带 UTF-8 标志。我核对了 26.04 源码：在非 Windows 平台，`CPP/Common/StringConvert.cpp` 里 `g_ForceToUTF8 = true`，`MultiByteToUnicodeString2()` 会**忽略传入的代码页、一律按 UTF-8 解码**；所以即使传 `-mcp=936`，mac 上的 `7zz` 解出来的中文名依然是乱码。

**修复**：在 `CPP/7zip/Archive/Zip/ZipItem.cpp` 的 `CItem::GetUnicodeString()` 末尾、`MultiByteToUnicodeString2(...)` 之前插入一段（只在非 Windows 生效）：

```cpp
#ifndef _WIN32
  // 7zMac patch: 没有 UTF-8 标志的条目
  // 1) 字节本身是合法 UTF-8（mac/Linux 打包常见）→ 按 UTF-8
  // 2) 否则若指定了 -mcp=<n> → 用 iconv 从该代码页转换（936→GB18030, 950→BIG5, 932→SHIFT_JIS）
  if (!isUtf8 && useSpecifiedCodePage && codePage != CP_UTF8)
  {
    if (Check_UTF8_Buf(s.Ptr(), s.Len(), false)) { ConvertUTF8ToUnicode(s, res); return; }
    if (My_Iconv_To_Unicode(res, s, codePage)) return;
  }
#endif
```

`My_Iconv_To_Unicode` 约 30 行：`iconv_open("UTF-32LE", name)` → 转换 → 逐个 `wchar_t` 追加进 `UString`（mac 上 `wchar_t` 是 32 位）。失败返回 `false`，走原逻辑。链接时加 `-liconv`（已在 §4.2 的 make 命令里）。

**使用**：主程序在列表/解压 ZIP 时，按设置页「ZIP 文件名编码」传 `-mcp=936`（默认“自动(GBK)”）。带 UTF-8 标志的条目不受影响（源码中 `IsUtf8()` 优先）。压缩 ZIP 时一律加 `-mcu=on` 写 UTF-8 标志，Windows 上打开也不会乱码。

验收：用 Windows 资源管理器“发送到压缩文件夹”生成的中文名 ZIP，`7zz l -mcp=936 x.zip` 显示正确中文。

---

## 6. 核心引擎（Swift）

### 6.1 `SevenZip.swift`：进程封装

所有调用统一加：`-sccUTF-8`（控制台 UTF-8）、`-bso0 -bse2`（只要错误输出）、`-bsp1`（进度到 stdout），文件参数前加 `--`（防止文件名以 `-` 开头被当成开关）。

| 用途 | 命令 |
|------|------|
| 列表 | `7zz l -slt -sccUTF-8 [-mcp=936] [-p<pwd>] -- <archive>` |
| 解压 | `7zz x -y -bsp1 -bso0 -bse2 -sccUTF-8 -o<staging> [-mcp=936] [-p<pwd>] -- <archive>` |
| 解压单个条目（预览/拖出） | `7zz x -y ... -o<tmp> -- <archive> <entryPath>` |
| 压缩 7z | `7zz a -t7z -mx=<lvl> -mmt=on -ms=<on/off> -snl -bsp1 -bso0 -bse2 -sccUTF-8 [排除项] [-p<pwd> -mhe=on] [-v<size>] -- <tmp.7z> <相对路径...>` |
| 压缩 zip | `7zz a -tzip -mx=<lvl> -mcu=on [-mem=AES256 -p<pwd>] ... -- <tmp.zip> <相对路径...>` |
| 压缩 tar.gz / tar.xz | `7zz a -ttar -so -- <相对路径...>` **管道到** `7zz a -tgzip -si -- <tmp.tar.gz>`（两个 `Process` 用 `Pipe` 串起来） |

```swift
struct SevenZip {
    static let exe = Bundle.main.url(forAuxiliaryExecutable: "7zz")!

    /// 运行 7zz；onProgress 收到 0...100；返回 (exitCode, stderr)
    static func run(_ args: [String], cwd: URL? = nil,
                    onProgress: ((Int) -> Void)? = nil,
                    cancel: CancelToken) async throws -> (Int32, String) {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice     // 防止 7zz 等待交互输入密码而卡住
        // 逐块读 stdout，用正则 /(\d+)%/ 取最后一个百分比（输出里夹着 \b 退格符）
        ...
        cancel.onCancel { p.interrupt() }           // SIGINT，7zz 会清理后退出（退出码 255）
        ...
    }
}
```

退出码：`0` 成功；`1` 警告（如个别文件被锁）；`2` 致命错误；`7` 参数错误；`8` 内存不足；`255` 用户取消。

**密码处理**：首次不带 `-p` 运行，stdin 为空设备；若 stderr 含 `Wrong password` / `Can not open encrypted archive` → 弹出密码框 → 带 `-p<pwd>` 重试；本次会话内对同一压缩包缓存密码。

### 6.2 `ListParser.swift`：解析 `-slt`

`7zz l -slt` 在 `----------` 分隔行之后，每个条目是一段空行分隔的 `Key = Value`：

```
Path = 文件夹/a.txt
Folder = -
Size = 1234
Packed Size = 567
Modified = 2026-10-01 12:00:00.0000000
Attributes = A -rw-r--r--
Encrypted = -
```

解析成 `[Entry(path, isDir, size, packed, mtime, encrypted)]`，再按 `/` 拆分建树（缺失的中间目录自动补节点）。10 万条目级别的压缩包也只需流式读一遍。

### 6.3 `SmartExtract.swift`：智能文件夹（R6 核心）

**原则：不靠“先列表再猜”，而是先解到同卷临时目录，看实际结果再决定**——列表与实际解出结果不一致（比如含 `__MACOSX`、`.tar.gz` 双层）的情况都能正确处理，而且同卷 `rename` 是瞬间完成的，不占双倍空间。

```
输入：archive = /x/y/资料.zip
1. staging = /x/y/.7zmac-<UUID>/          （隐藏目录，与目标同一卷）
2. 7zz x → staging
3. 双层包处理：若压缩包是 .tar.gz/.tgz/.tar.bz2/.tar.xz/.tar.zst，
   且 staging 里只有一个 .tar 文件 → 再解一次该 .tar，删掉中间 .tar
4. 清理垃圾（设置可关）：删除 staging 内的 __MACOSX/、顶层 .DS_Store
5. 统计 staging 顶层条目数 n：
   n == 0 → 提示“压缩包为空”，删除 staging
   n == 1 → 把这唯一的文件或文件夹移到 /x/y/<它自己的名字>（重名自动改名）
   n >= 2 → 把 staging 重命名为 /x/y/资料/（重名自动改名）
6. 失败/取消 → 删除 staging，不留半成品
7.（可选）解压完成后在 Finder 中选中结果；（可选）把压缩包移到废纸篓
```

```swift
func smartExtract(_ archive: URL, s: ExtractSettings, cancel: CancelToken) async throws -> URL {
    let fm = FileManager.default
    let parent = archive.deletingLastPathComponent()
    let staging = parent.appendingPathComponent(".7zmac-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    var moved = false
    defer { if !moved { try? fm.removeItem(at: staging) } }

    try await SevenZip.extract(archive, to: staging, settings: s, cancel: cancel)
    try unwrapInnerTarIfNeeded(archive, in: staging, cancel: cancel)
    if s.removeMacJunk { removeJunk(in: staging) }

    let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [])
    switch top.count {
    case 0:
        throw ExtractError.emptyArchive
    case 1:
        let dest = uniqueURL(parent.appendingPathComponent(top[0].lastPathComponent))
        try fm.moveItem(at: top[0], to: dest)
        return dest            // defer 会删掉已空的 staging
    default:
        let dest = uniqueURL(parent.appendingPathComponent(ArchiveTypes.baseName(of: archive)))
        try fm.moveItem(at: staging, to: dest); moved = true
        return dest
    }
}
```

**辅助规则**

- `ArchiveTypes.baseName`：剥掉复合后缀 —— `资料.tar.gz`→`资料`、`a.tgz`→`a`、`b.7z.001`→`b`、`c.part1.rar`→`c`、`d.zip.001`→`d`。
- `uniqueURL`：Finder 风格重名 —— `资料` → `资料 2` → `资料 3`；文件保留扩展名：`a.txt` → `a 2.txt`。（设置里可改为“覆盖”。）
- 父目录不可写（只读卷、无权限）→ 报错并提供“解压到…”选择目录。
- 多选多个压缩包：逐个独立执行上述流程，排队运行。
- 分卷：只对首卷（`.001`、`.part1.rar`、`.z01` 对应的 `.zip`）执行；同时选中多个分卷时按首卷去重。
- 安全：保持 7zz 默认的路径安全检查（拒绝绝对路径和 `../` 逃逸），**不要**加 `-snld`。
- 隔离属性（可选，默认开）：若压缩包带 `com.apple.quarantine`，把该属性复制到解出的项目上，与「归档实用工具」行为一致。

### 6.4 `Compressor.swift`：一键压缩（R5）

- **命名**：
  - 单选文件夹 `照片` → `照片.7z`
  - 单选文件 `报告.pdf` → `报告.7z`（去掉原扩展名，与 Windows 7-Zip 一致）
  - 多选 → 用所在文件夹名，如 `/x/项目/` 下多选 → `项目.7z`
  - 重名自动 `照片 2.7z`
- **路径**：`Process.currentDirectoryURL = 父目录`，参数传相对名，避免把绝对路径打进包。
- **原子性**：先写 `.照片.7z.7zmac-tmp`（隐藏），成功后 `rename` 成正式名；失败/取消删除临时文件。
- **默认排除**（设置可关）：`-xr!.DS_Store -xr!__MACOSX -xr!._*`
- **符号链接**：`-snl` 存为链接而不是跟随（避免把整个链接目标打进包）。

### 6.5 `JobRunner.swift` + 进度面板

- 串行队列（同时一个任务，避免多个任务抢磁盘）；可设置并发数。
- 任务开始 0.8 秒后仍未完成才弹出进度面板 —— 小文件“点了就完成”，不闪窗口。
- 进度面板：`NSPanel`（浮动、不抢焦点），一行一个任务：`正在解压 资料.zip  ▓▓▓▓░░ 62%  ✕`。
- 完成：面板自动消失；（可选）Finder 中选中结果。失败：`NSAlert` 显示 7zz 的 stderr 摘要。

---

## 7. Finder Sync 扩展（R4）

### 7.1 `FinderSync.swift`

```swift
import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        updateWatchedURLs()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self, selector: #selector(updateWatchedURLs), name: NSWorkspace.didMountNotification, object: nil)
        nc.addObserver(self, selector: #selector(updateWatchedURLs), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    @objc private func updateWatchedURLs() {
        var urls: Set<URL> = [URL(fileURLWithPath: "/")]
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                         options: [.skipHiddenVolumes]) ?? []
        urls.formUnion(vols)
        FIFinderSyncController.default().directoryURLs = urls
    }

    // 只在“对选中项右键”时出菜单；空白处右键、工具栏不出
    override func menu(for kind: FIMenuKind) -> NSMenu? {
        guard kind == .contextualMenuForItems,
              let items = FIFinderSyncController.default().selectedItemURLs(),
              !items.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        let c = NSMenuItem(title: "压缩", action: #selector(compress(_:)), keyEquivalent: "")
        c.image = NSImage(systemSymbolName: "archivebox", accessibilityDescription: nil)
        menu.addItem(c)

        if items.contains(where: { ArchiveTypes.isExtractable($0) }) {
            let x = NSMenuItem(title: "解压", action: #selector(extract(_:)), keyEquivalent: "")
            x.image = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)
            menu.addItem(x)
        }
        return menu
    }

    @objc func compress(_ sender: NSMenuItem) { send(.compress) }
    @objc func extract(_ sender: NSMenuItem)  { send(.extract) }

    private func send(_ op: JobRequest.Op) {
        guard let items = FIFinderSyncController.default().selectedItemURLs(), !items.isEmpty else { return }
        let req = JobRequest(op: op, paths: items.map(\.path))
        NSWorkspace.shared.open(req.url)    // sevenzipmac://job?d=<base64url(JSON)>
    }
}
```

菜单逻辑：

| 选中内容 | 显示 |
|---------|------|
| 任意文件/文件夹（不含压缩包） | 压缩 |
| 含至少一个压缩包 | 压缩、解压（「解压」只处理其中的压缩包） |
| 空白处右键 | 不显示 |

`ArchiveTypes.isExtractable` 只看后缀（不读文件，保证右键菜单弹出不卡）。

### 7.2 扩展 → 主程序 的通信

- 主程序 `Info.plist` 注册 URL Scheme `sevenzipmac`（URL scheme 必须以字母开头）。
- 扩展把 `{op, paths}` 编成 JSON → base64url → `sevenzipmac://job?d=...`，用 `NSWorkspace.open` 打开（沙盒扩展允许）。
- 主程序在 `application(_:open:)` 中解码、校验路径存在，然后交给 `JobRunner`。
- 若将来遇到“一次选中数千个文件 URL 过长”的情况，再升级为 App Group 共享目录写任务文件、URL 只带任务 ID。

### 7.3 主程序被扩展唤起时不打扰

- `applicationWillFinishLaunching` 中先 `NSApp.setActivationPolicy(.accessory)`（不出 Dock 图标、不抢前台）。
- 只有打开浏览窗口或设置窗口时才切到 `.regular`；所有窗口关闭后切回 `.accessory`。
- 任务全部完成且无窗口时，空闲 60 秒后自动退出（`NSApp.terminate`），不常驻。

---

## 8. 文件关联与浏览窗口（R2、R3）

### 8.1 `App/Info.plist` 关键片段

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>Archive</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>NSDocumentClass</key><string>$(PRODUCT_MODULE_NAME).ArchiveDocument</string>
    <key>LSItemContentTypes</key>
    <array>
      <string>public.zip-archive</string>
      <string>org.7-zip.7-zip-archive</string>
      <string>com.rarlab.rar-archive</string>
      <string>public.tar-archive</string>
      <string>org.gnu.gnu-zip-archive</string>
      <string>org.gnu.gnu-zip-tar-archive</string>
      <string>public.bzip2-archive</string>
      <string>org.tukaani.xz-archive</string>
      <string>local.djj45.7zmac.tar-xz</string>
      <string>local.djj45.7zmac.zst</string>
      <string>local.djj45.7zmac.lzma</string>
      <string>local.djj45.7zmac.cab</string>
      <string>local.djj45.7zmac.wim</string>
      <string>local.djj45.7zmac.split</string>
    </array>
  </dict>
</array>

<key>UTImportedTypeDeclarations</key>
<array>
  <!-- 系统可能已声明的类型也在这里“导入”声明一次，保证后缀能识别；系统定义优先 -->
  <dict>
    <key>UTTypeIdentifier</key><string>org.7-zip.7-zip-archive</string>
    <key>UTTypeDescription</key><string>7-Zip 压缩包</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>7z</string></array></dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key><string>com.rarlab.rar-archive</string>
    <key>UTTypeDescription</key><string>RAR 压缩包</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>rar</string></array></dict>
  </dict>
  <!-- 其余：xz / txz / tar.xz / zst / lzma / cab / wim / 001 等同理 -->
</array>

<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLName</key><string>local.djj45.7zmac.job</string>
    <key>CFBundleURLSchemes</key><array><string>sevenzipmac</string></array>
  </dict>
</array>
```

> ISO/DMG 不默认关联（双击 ISO/DMG 在 mac 上通常是想挂载），设置页里可以手动勾选。

### 8.2 设为默认打开方式

- `Info.plist` 声明后，压缩包的「打开方式」里就会出现 7zMac，但**不会自动成为默认**。
- 设置页「通用」提供 **“设为默认解压工具”** 按钮：对每个勾选的 UTType 调用 `NSWorkspace.shared.setDefaultApplication(at:toOpen:)`（macOS 12+），系统可能弹出确认框。
- 兜底：Finder 中选一个 .zip → 显示简介 → 打开方式 → 选 7zMac → 全部更改。

### 8.3 浏览窗口（双击压缩包时出现）

`ArchiveDocument : NSDocument`，`read(from:ofType:)` 里跑一次列表；只读，不支持编辑压缩包内容（保持简单）。

```
┌─ 资料.zip ──────────────────────────────────────────────────┐
│ [⤓ 解压]  [⤓ 解压到…]                         🔍 搜索       │
├─────────────────────────────────────────────────────────────┤
│ 资料 › 图片                                                  │
├─────────────────────────────────────────────────────────────┤
│ 名称                    大小        压缩后      修改日期       │
│ ▸ 📁 原图                 —          —        2026-10-01     │
│   📄 封面.png           2.1 MB     1.9 MB    2026-10-01     │
│   📄 说明.txt           3 KB       1 KB      2026-09-30     │
├─────────────────────────────────────────────────────────────┤
│ 128 个文件，共 512 MB，压缩率 61%                🔒 已加密     │
└─────────────────────────────────────────────────────────────┘
```

- 列表：`NSOutlineView`（树形，可展开）或 Finder 式逐层进入，二选一，建议树形。
- **解压**：对整个压缩包执行与右键相同的智能解压（目标为压缩包所在目录）。
- **解压到…**：选目录；有选中项时只解压选中项。
- **双击文件**：解到 `~/Library/Caches/local.djj45.7zmac/preview/<uuid>/` 并用默认程序打开；双击内层压缩包 → 新窗口浏览。
- **空格键**：Quick Look 预览（同样先解到缓存目录）。
- **拖出到 Finder**：`NSFilePromiseProvider`，放下时才解压该条目。
- 缓存目录在启动和退出时清空。

---

## 9. 设置窗口（R7）

SwiftUI `Settings` 场景，三个标签页，全部存 `UserDefaults`（只有主程序读；扩展不需要读设置）。

**压缩**

| 项 | 选项 | 默认 | 对应参数 |
|----|------|------|---------|
| 格式 | 7z / zip / tar.gz / tar.xz | 7z | `-t7z` / `-tzip` / 管道 |
| 压缩等级 | 仅存储 / 最快 / 快速 / 标准 / 最大 / 极限 | 标准 | `-mx=0/1/3/5/7/9` |
| 固实压缩（7z） | 开/关 | 开 | `-ms=on/off` |
| 线程数 | 自动 / 1…N | 自动 | `-mmt=on` / `-mmt=N` |
| 加密 | 关 / 每次询问密码 / 使用固定密码（存钥匙串） | 关 | `-p…`，7z 加 `-mhe=on`，zip 加 `-mem=AES256` |
| 分卷 | 不分卷 / 自定义 MB | 不分卷 | `-v<N>m` |
| 排除 mac 隐藏文件 | 开/关 | 开 | `-xr!.DS_Store -xr!__MACOSX -xr!._*` |

**解压**

| 项 | 选项 | 默认 |
|----|------|------|
| 智能文件夹 | 开（单个顶层项直接放出，否则建同名文件夹）/ 总是建文件夹 / 从不建文件夹 | 开 |
| 重名处理 | 自动改名 / 覆盖 | 自动改名 |
| ZIP 文件名编码 | 自动（UTF-8 优先，其次 GBK）/ GBK / Big5 / Shift-JIS / UTF-8 | 自动 |
| 自动解开 .tar.gz 等双层包 | 开/关 | 开 |
| 删除 `__MACOSX`、`.DS_Store` | 开/关 | 开 |
| 解压后在 Finder 中显示 | 开/关 | 关 |
| 解压后将压缩包移到废纸篓 | 开/关 | 关 |
| 继承隔离属性 | 开/关 | 开 |

**通用**

- 关联格式（复选框列表）+「设为默认解压工具」按钮
- Finder 扩展状态（`FIFinderSyncController.isExtensionEnabled`）+「打开扩展设置」按钮（`FIFinderSyncController.showExtensionManagementInterface()`）
- 7-Zip 内核版本显示（`7zz` 首行输出）

直接从启动台/Dock 打开 7zMac 时，显示的就是设置窗口。

---

## 10. 工程配置

### 10.1 `project.yml`（XcodeGen）

```yaml
name: 7zMac
options:
  bundleIdPrefix: local.djj45
  deploymentTarget: { macOS: "13.0" }
settings:
  base:
    DEVELOPMENT_TEAM: XXXXXXXXXX          # 你的 Team ID
    CODE_SIGN_STYLE: Automatic
    SWIFT_VERSION: "5.10"
    ENABLE_HARDENED_RUNTIME: YES
targets:
  7zMac:
    type: application
    platform: macOS
    sources:
      - App
      - Shared
      # 把 7zz 拷进 Contents/MacOS 并随 App 一起签名
      - path: vendor/bin/7zz
        buildPhase:
          copyFiles:
            destination: executables
        attributes: [CodeSignOnCopy]
    info: { path: App/Info.plist }
    entitlements: { path: App/7zMac.entitlements }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.djj45.7zmac
    dependencies:
      - target: 7zMacFinder
        embed: true
        codeSign: true
  7zMacFinder:
    type: app-extension
    platform: macOS
    sources: [FinderExt, Shared]
    info:
      path: FinderExt/Info.plist
      properties:
        NSExtension:
          NSExtensionPointIdentifier: com.apple.FinderSync
          NSExtensionPrincipalClass: $(PRODUCT_MODULE_NAME).FinderSync
    entitlements: { path: FinderExt/FinderExt.entitlements }
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: local.djj45.7zmac.finder
```

> 生成工程后在 Xcode › 7zMac target › Build Phases 确认有一个 “Copy Files → Executables” 阶段包含 `7zz`，且勾选了 Code Sign On Copy。

### 10.2 Entitlements

`App/7zMac.entitlements` —— **不开沙盒**（要在任意目录读写）：
```xml
<dict>
  <key>com.apple.security.app-sandbox</key><false/>
</dict>
```

`FinderExt/FinderExt.entitlements` —— 扩展**必须**沙盒：
```xml
<dict>
  <key>com.apple.security.app-sandbox</key><true/>
</dict>
```

### 10.3 一键构建 `scripts/build-app.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail
export http_proxy="${http_proxy:-http://127.0.0.1:20122}"
export https_proxy="${https_proxy:-http://127.0.0.1:20122}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"

[ -x vendor/bin/7zz ] || { scripts/fetch-7zip.sh; scripts/build-7zz.sh; }
xcodegen generate
xcodebuild -project 7zMac.xcodeproj -scheme 7zMac -configuration Release \
           -derivedDataPath build -destination 'generic/platform=macOS' build

APP=build/Build/Products/Release/7zMac.app
codesign --verify --deep --strict "$APP"
rm -rf /Applications/7zMac.app && cp -R "$APP" /Applications/

# 注册 & 启用 Finder 扩展
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/7zMac.app
open /Applications/7zMac.app            # 首次启动一次，扩展才会被系统发现
pluginkit -e use -i local.djj45.7zmac.finder
killall Finder
```

---

## 11. 开发里程碑

| 阶段 | 内容 | 验收 |
|------|------|------|
| **M0** 内核 | §4 编译 Universal `7zz`；§5 编码补丁 | `7zz i` 正常；GBK 中文 ZIP 列表无乱码 |
| **M1** 引擎 | `SevenZip`/`ListParser`/`SmartExtract`/`Compressor` + 单元测试（XCTest，测试夹具见 §12） | 测试全部通过 |
| **M2** 浏览窗口 | 文档类型关联、`ArchiveDocument`、树形列表、解压/解压到、双击预览、拖出 | 双击 .zip/.7z/.rar 打开窗口并能浏览 |
| **M3** 右键菜单 | Finder Sync 扩展、URL 通信、`JobRunner`、进度面板、取消 | 右键一级菜单出现「压缩」「解压」，功能正确 |
| **M4** 设置 | 三个标签页、所有参数生效、设为默认、扩展状态 | 修改设置后右键操作按新参数执行 |
| **M5** 打磨 | 密码流程、错误提示文案、图标、空闲自动退出、缓存清理 | §12 测试矩阵全部通过 |

---

## 12. 测试矩阵

**智能解压**

| 压缩包内容 | 期望结果 |
|-----------|---------|
| 一个文件夹 `资料/…`（与包同名） | `./资料/` |
| 一个文件夹 `abc/…`（与包名不同） | `./abc/`（单顶层项直接放出） |
| 一个文件 `a.pdf` | `./a.pdf` |
| 多个文件/文件夹 | `./<包名>/…` |
| `__MACOSX/` + 一个文件夹（mac 打的 zip） | `./<那个文件夹>/`，无 `__MACOSX` |
| `x.tar.gz`（内含一个文件夹） | `./<那个文件夹>/`，无中间 `x.tar` |
| 目标已存在同名 | `资料 2` |
| 空压缩包 | 提示“压缩包为空”，不留临时目录 |
| 中途取消 | 无任何残留（含隐藏 `.7zmac-*` 目录） |
| 加密（7z 文件名加密 / zip AES） | 弹密码框；错误密码提示重试 |
| 分卷 `.7z.001`…、`.part1.rar`… | 只从首卷解压一次 |
| Windows 打的 GBK 中文 ZIP | 中文文件名正确 |
| 只读目录 / 外接 U 盘 / NAS 共享 | 只读给出明确错误；外接盘和 NAS 上菜单可见且可用 |
| 恶意 `../` 路径的 ZIP | 不写出目标目录之外 |

**压缩**：单文件、单文件夹、多选、含符号链接、含 `.DS_Store`、中文/emoji 文件名、5GB 以上大文件、各格式在 Windows 7-Zip 中打开验证。

**右键菜单**：桌面、下载、外接卷、iCloud 云盘目录、搜索结果中多选；空白处右键不出现菜单。

---

## 13. 已知坑与对策

| 坑 | 对策 |
|----|------|
| 右键菜单不出现 | ① 主程序至少启动过一次；② 系统设置里启用扩展；③ `pluginkit -mAvvv -p com.apple.FinderSync` 确认已注册；④ `killall Finder`；⑤ 确认不是 ad-hoc 签名 |
| macOS 15.0/15.1 的系统设置里找不到 Finder 扩展开关 | 升级到 15.2+（苹果已恢复入口），或用 `pluginkit -e use -i local.djj45.7zmac.finder` |
| 首次在 桌面/文稿/下载 解压时弹出“想访问…文件夹” | 这是 macOS 隐私保护（TCC），点允许一次即可；也可在「隐私与安全性 › 完全磁盘访问」里勾选 7zMac |
| 7zz 不读写 mac 的扩展属性/资源分叉 | 压缩包本身就是跨平台格式，属正常；需要保留 mac 元数据时用系统自带 `ditto` 另行处理（不在本工具范围内） |
| 文件名 NFD/NFC（mac 文件系统存 NFD） | 压缩时 7zz 按原样写入；在 Windows 下中文显示正常；如遇韩文/带音标字符异常，压缩前把相对路径参数转成 NFC |
| RAR | `7zz` 只能解压 RAR，不能生成 RAR；压缩格式不提供 RAR |
| 7-Zip 升级 | 改 `fetch-7zip.sh` 里的版本号 → 重新打补丁（补丁只改一处，冲突概率低）→ 重新编译 |
| 许可 | 7-Zip 为 LGPL + BSD + unRAR 限制条款；个人使用无问题，若对外分发需附带 `vendor/7zip/DOC/License.txt` |
