import Foundation

enum FileOps {

    private static var fm: FileManager { .default }

    /// 路径上是否已有东西（包括失效的符号链接）
    static func exists(_ url: URL) -> Bool {
        (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// 复合后缀，用于重名时把序号插在正确位置：资料.tar.gz → 资料 2.tar.gz
    private static let compoundSuffixes = [".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".7z.001", ".zip.001"]

    static func splitName(_ name: String, isDirectory: Bool) -> (stem: String, ext: String) {
        if isDirectory { return (name, "") }
        let lower = name.lowercased()
        for suffix in compoundSuffixes where lower.hasSuffix(suffix) && lower.count > suffix.count {
            let cut = name.index(name.endIndex, offsetBy: -suffix.count)
            return (String(name[..<cut]), String(name[name.index(after: cut)...]))
        }
        let ext = (name as NSString).pathExtension
        if ext.isEmpty || name.hasPrefix(".") && name.dropFirst().contains(".") == false {
            return (name, "")
        }
        return ((name as NSString).deletingPathExtension, ext)
    }

    /// Finder 风格的不重名路径：资料 → 资料 2 → 资料 3；a.txt → a 2.txt
    static func uniqueURL(in dir: URL, name: String, isDirectory: Bool) -> URL {
        let first = dir.appendingPathComponent(name, isDirectory: isDirectory)
        if !exists(first) { return first }
        let (stem, ext) = splitName(name, isDirectory: isDirectory)
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            let url = dir.appendingPathComponent(candidate, isDirectory: isDirectory)
            if !exists(url) { return url }
            n += 1
        }
    }

    /// 把 src 移动到 dir/name；按设置处理重名
    /// protecting：绝不能被替换掉的路径（压缩包本身）
    static func place(_ src: URL, into dir: URL, name: String, conflict: ConflictMode,
                      protecting: URL? = nil) throws -> URL {
        let srcIsDir = isDirectory(src)
        var dest = dir.appendingPathComponent(name, isDirectory: srcIsDir)
        if exists(dest) {
            var mode = conflict
            if let protecting, protecting.standardizedFileURL.path == dest.standardizedFileURL.path {
                mode = .rename
            }
            switch mode {
            case .rename:
                dest = uniqueURL(in: dir, name: name, isDirectory: srcIsDir)
            case .overwrite:
                try fm.trashItem(at: dest, resultingItemURL: nil)
            }
        }
        try fm.moveItem(at: src, to: dest)
        return dest
    }

    /// 删除 mac 压缩时带进来的垃圾：顶层 __MACOSX/ 与所有 .DS_Store
    static func removeMacJunk(in dir: URL) {
        try? fm.removeItem(at: dir.appendingPathComponent("__MACOSX"))
        var junk: [URL] = []
        if let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let u as URL in e where u.lastPathComponent == ".DS_Store" {
                junk.append(u)
            }
        }
        junk.forEach { try? fm.removeItem(at: $0) }
    }

    /// 把压缩包的隔离属性（com.apple.quarantine）复制到解出的文件上，与「归档实用工具」一致
    static func propagateQuarantine(from archive: URL, to dest: URL) {
        let name = "com.apple.quarantine"
        let len = getxattr(archive.path, name, nil, 0, 0, 0)
        guard len > 0 else { return }
        var buf = [UInt8](repeating: 0, count: len)
        guard getxattr(archive.path, name, &buf, len, 0, 0) == len else { return }

        func apply(_ path: String) {
            _ = setxattr(path, name, buf, len, 0, XATTR_NOFOLLOW)
        }
        apply(dest.path)
        if isDirectory(dest), let e = fm.enumerator(atPath: dest.path) {
            for case let rel as String in e {
                apply((dest.path as NSString).appendingPathComponent(rel))
            }
        }
    }

    /// 应用缓存目录（预览、拖出时的临时解压）
    static var cacheDirectory: URL {
        let base = fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("local.djj45.7zmac", isDirectory: true)
    }

    static func makeTempDirectory() throws -> URL {
        let dir = cacheDirectory.appendingPathComponent("tmp/\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 清理超过 age 秒的临时解压目录（刚打开的预览文件可能还在被其他 App 使用，不立即删除）
    static func clearCache(olderThan age: TimeInterval) {
        let tmp = cacheDirectory.appendingPathComponent("tmp", isDirectory: true)
        let items = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let cutoff = Date().addingTimeInterval(-age)
        for item in items {
            let date = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if (date ?? .distantPast) < cutoff {
                try? fm.removeItem(at: item)
            }
        }
    }
}
