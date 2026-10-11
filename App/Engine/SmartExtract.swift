import Foundation

/// 智能解压：
/// 1. 先解到目标目录下的隐藏临时目录（同一个卷，最后 rename 是瞬间完成的）
/// 2. 解完看顶层有几项：
///    - 1 项（一个文件或一个文件夹）→ 直接移到目标目录
///    - 多项 → 把临时目录改名为“压缩包同名文件夹”
/// 3. 失败或取消时删除临时目录，不留半成品
enum SmartExtract {

    struct Options {
        var folderMode: FolderMode = Prefs.folderMode
        var conflict: ConflictMode = Prefs.conflict
        var unwrapTar: Bool = Prefs.unwrapTar
        var removeJunk: Bool = Prefs.removeJunk
        var quarantine: Bool = Prefs.quarantine
    }

    /// - Returns: 解压结果（文件或文件夹）的位置
    static func run(_ archive: URL, into parent: URL, password: String?,
                    options: Options = Options(),
                    progress: ((Int) -> Void)? = nil,
                    cancel: CancelToken? = nil) async throws -> URL {
        let fm = FileManager.default
        let staging = parent.appendingPathComponent(".7zmac-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        } catch {
            throw SevenZipError.message("无法在“\(parent.path)”中写入文件（\(error.localizedDescription)）。")
        }
        var stagingConsumed = false
        defer {
            if !stagingConsumed { try? fm.removeItem(at: staging) }
        }

        try await SevenZip.extract(archive, to: staging, password: password,
                                   unwrapTar: options.unwrapTar,
                                   progress: progress, cancel: cancel)
        if cancel?.isCancelled == true { throw SevenZipError.cancelled }

        if options.removeJunk { FileOps.removeMacJunk(in: staging) }

        let top = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [])
        if top.isEmpty { throw SevenZipError.emptyArchive }

        let folderName = ArchiveTypes.baseName(of: archive)
        let result: URL
        let wrapInFolder: Bool
        switch options.folderMode {
        case .smart:  wrapInFolder = top.count > 1
        case .always: wrapInFolder = true
        case .never:  wrapInFolder = false
        }

        if wrapInFolder {
            result = try FileOps.place(staging, into: parent, name: folderName,
                                       conflict: options.conflict, protecting: archive)
            stagingConsumed = true
        } else if top.count == 1 {
            result = try FileOps.place(top[0], into: parent, name: top[0].lastPathComponent,
                                       conflict: options.conflict, protecting: archive)
        } else {
            // “从不建文件夹”且有多项：逐项放出，返回第一项
            var first: URL?
            for item in top {
                let placed = try FileOps.place(item, into: parent, name: item.lastPathComponent,
                                               conflict: options.conflict, protecting: archive)
                if first == nil { first = placed }
            }
            result = first ?? parent
        }

        if options.quarantine { FileOps.propagateQuarantine(from: archive, to: result) }
        return result
    }

    /// 压缩包内一个条目的引用（只含路径和名字，可跨线程传递）
    struct EntryRef: Sendable {
        let path: String
        let name: String
    }

    /// 只解压选中的条目到 dest（浏览窗口“解压到…”/双击预览/拖出使用）。
    /// 条目按自身名字放进 dest，不带压缩包内的上级路径。
    static func extractEntries(_ archive: URL, entries: [EntryRef], to dest: URL,
                               password: String?, conflict: ConflictMode = .rename,
                               quarantine: Bool = true,
                               progress: ((Int) -> Void)? = nil,
                               cancel: CancelToken? = nil) async throws -> [URL] {
        let fm = FileManager.default
        let staging = dest.appendingPathComponent(".7zmac-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw SevenZipError.message("无法在“\(dest.path)”中写入文件（\(error.localizedDescription)）。")
        }
        defer { try? fm.removeItem(at: staging) }

        // 去掉被其他选中文件夹包含的条目
        let roots = entries.filter { e in
            !entries.contains { other in other.path != e.path && e.path.hasPrefix(other.path + "/") }
        }

        try await SevenZip.extract(archive, to: staging, entries: roots.map(\.path),
                                   password: password, progress: progress, cancel: cancel)
        if cancel?.isCancelled == true { throw SevenZipError.cancelled }

        var results: [URL] = []
        for entry in roots {
            let src = staging.appendingPathComponent(entry.path)
            guard FileOps.exists(src) else { continue }
            results.append(try FileOps.place(src, into: dest, name: entry.name, conflict: conflict))
        }
        if quarantine {
            results.forEach { FileOps.propagateQuarantine(from: archive, to: $0) }
        }
        return results
    }
}
