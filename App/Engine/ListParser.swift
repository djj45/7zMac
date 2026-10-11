import Foundation

/// `7zz l -slt` 输出中的一个条目
struct ArchiveEntry {
    var path: String
    var isDirectory: Bool
    var size: UInt64
    var packedSize: UInt64?
    var modified: Date?
    var encrypted: Bool
}

enum ListParser {

    /// 解析 `7zz l -slt` 的输出。
    /// 格式：头部信息块（含 Type = …），一行 “----------”，之后是空行分隔的 “Key = Value” 块。
    static func parse(_ text: String) -> SevenZip.ListResult {
        var entries: [ArchiveEntry] = []
        var type: String?
        var inEntries = false
        var block: [String: String] = [:]

        func flush() {
            defer { block.removeAll(keepingCapacity: true) }
            guard let path = block["Path"], !path.isEmpty else { return }
            let attrs = block["Attributes"] ?? ""
            let isDir = block["Folder"] == "+" || attrs.hasPrefix("D")
            entries.append(ArchiveEntry(
                path: path,
                isDirectory: isDir,
                size: UInt64(block["Size"] ?? "") ?? 0,
                packedSize: UInt64(block["Packed Size"] ?? ""),
                modified: parseDate(block["Modified"]),
                encrypted: block["Encrypted"] == "+"))
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            if !inEntries {
                if line == "----------" {
                    inEntries = true
                } else if type == nil, line.hasPrefix("Type = ") {
                    type = String(line.dropFirst("Type = ".count))
                }
                continue
            }
            if line.isEmpty {
                flush()
                continue
            }
            if let r = line.range(of: " = ") {
                block[String(line[..<r.lowerBound])] = String(line[r.upperBound...])
            } else if line.hasSuffix(" =") {
                block[String(line.dropLast(2))] = ""
            }
        }
        flush()
        return SevenZip.ListResult(entries: entries, type: type)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    /// “2026-10-01 12:00:00.1234567” → Date（忽略小数秒）
    static func parseDate(_ s: String?) -> Date? {
        guard let s, s.count >= 19 else { return nil }
        return dateFormatter.date(from: String(s.prefix(19)))
    }
}

// MARK: - 树

/// 压缩包内容树的节点（浏览窗口使用）
final class ArchiveNode: NSObject {
    let name: String
    let path: String
    var isDirectory: Bool
    var size: UInt64 = 0
    var packedSize: UInt64?
    var modified: Date?
    var encrypted = false
    weak var parent: ArchiveNode?
    private(set) var children: [ArchiveNode] = []
    private var index: [String: ArchiveNode] = [:]

    init(name: String, path: String, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    /// 文件总数（不含文件夹）
    private(set) var fileCount = 0

    static func buildTree(_ entries: [ArchiveEntry]) -> ArchiveNode {
        let root = ArchiveNode(name: "", path: "", isDirectory: true)
        for e in entries {
            let parts = e.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            guard !parts.isEmpty else { continue }
            var node = root
            for (i, part) in parts.enumerated() {
                let isLast = i == parts.count - 1
                if let child = node.index[part] {
                    node = child
                } else {
                    let childPath = parts[0...i].joined(separator: "/")
                    let child = ArchiveNode(name: part, path: childPath, isDirectory: !isLast || e.isDirectory)
                    child.parent = node
                    node.children.append(child)
                    node.index[part] = child
                    node = child
                }
                if isLast {
                    node.isDirectory = e.isDirectory || !node.children.isEmpty
                    if !e.isDirectory {
                        node.size = e.size
                        node.packedSize = e.packedSize
                    }
                    node.modified = e.modified ?? node.modified
                    node.encrypted = e.encrypted
                }
            }
        }
        root.finish()
        return root
    }

    /// 排序（文件夹在前，按名称自然排序），并汇总文件夹大小
    private func finish() {
        guard isDirectory else { fileCount = 1; return }
        children.forEach { $0.finish() }
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        size = children.reduce(0) { $0 + $1.size }
        let packedValues = children.compactMap { $0.packedSize }
        packedSize = packedValues.isEmpty ? nil : packedValues.reduce(0, +)
        fileCount = children.reduce(0) { $0 + $1.fileCount }
        encrypted = children.contains { $0.encrypted }
    }

    /// 深度优先遍历所有后代
    func forEachDescendant(_ body: (ArchiveNode) -> Void) {
        for c in children {
            body(c)
            c.forEachDescendant(body)
        }
    }
}
