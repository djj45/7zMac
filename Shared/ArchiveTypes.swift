import Foundation

/// 压缩包后缀识别（主程序与 Finder 扩展共用；只看文件名，不读文件内容）
enum ArchiveTypes {

    /// 可以「解压」的单一后缀（小写）
    static let extractableExtensions: Set<String> = [
        "7z", "zip", "rar", "tar",
        "gz", "gzip", "tgz", "taz",
        "bz2", "bzip2", "tbz", "tbz2",
        "xz", "txz",
        "zst", "tzst",
        "lzma", "tlz",
        "z", "cab", "wim", "swm", "esd",
        "arj", "lzh", "lha", "cpio", "rpm", "deb", "iso",
    ]

    /// 只压缩了单个数据流的格式（它们包着 tar 时需要“二次解包”）
    static let streamExtensions: Set<String> = ["gz", "gzip", "bz2", "bzip2", "xz", "zst", "lzma", "z"]

    /// tar 的简写后缀
    static let tarShortExtensions: Set<String> = ["tgz", "taz", "tbz", "tbz2", "txz", "tzst", "tlz"]

    // MARK: - 判断

    /// 右键是否显示「解压」：是压缩包，且如果是分卷则必须是首卷
    static func isExtractable(_ url: URL) -> Bool {
        if url.hasDirectoryPath { return false }
        return isExtractable(name: url.lastPathComponent)
    }

    static func isExtractable(name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        guard !ext.isEmpty else { return false }

        // 分卷：xxx.7z.001 / xxx.zip.001 / xxx.001 —— 只认首卷 .001
        if ext.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return ext == "001"
        }
        // RAR 新式分卷：xxx.part1.rar / part01 / part001 —— 只认第 1 卷
        if ext == "rar" {
            if let n = rarPartNumber(lower) { return n == 1 }
            return true
        }
        return extractableExtensions.contains(ext)
    }

    /// 是否是 tar.gz 这类“压缩流 + tar”的双层包
    static func isCompoundTar(name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if tarShortExtensions.contains(ext) { return true }
        if streamExtensions.contains(ext) {
            let inner = ((lower as NSString).deletingPathExtension as NSString).pathExtension
            return inner == "tar"
        }
        return false
    }

    /// 是否是 ZIP（只对 ZIP 传 -mcp 代码页参数，其他格式传了会报错）
    static func isZip(name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext == "zip" { return true }
        if ext == "001" {
            return ((lower as NSString).deletingPathExtension as NSString).pathExtension == "zip"
        }
        return false
    }

    /// 是否是多卷压缩包的首卷
    static func isMultiVolume(name: String) -> Bool {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        if ext == "001" { return true }
        if ext == "rar", rarPartNumber(lower) != nil { return true }
        return false
    }

    // MARK: - 名称

    /// 去掉压缩包后缀得到“基础名”：
    /// 资料.tar.gz → 资料，a.tgz → a，b.7z.001 → b，c.part1.rar → c
    static func baseName(of url: URL) -> String {
        baseName(ofFileName: url.lastPathComponent)
    }

    static func baseName(ofFileName fileName: String) -> String {
        var name = fileName
        func ext(_ s: String) -> String { (s as NSString).pathExtension.lowercased() }
        func drop(_ s: String) -> String { (s as NSString).deletingPathExtension }

        // 1. 分卷号
        let e0 = ext(name)
        if !e0.isEmpty, e0.allSatisfy({ $0.isASCII && $0.isNumber }) {
            name = drop(name)
        }
        // 2. 主后缀
        let e1 = ext(name)
        if e1 == "rar" {
            name = drop(name)
            if ext(name).hasPrefix("part"), ext(name).dropFirst(4).allSatisfy({ $0.isNumber }) {
                name = drop(name)
            }
        } else if streamExtensions.contains(e1) {
            name = drop(name)
            if ext(name) == "tar" { name = drop(name) }
        } else if extractableExtensions.contains(e1) {
            name = drop(name)
        }
        if name.isEmpty || name == "." { return "未命名" }
        return name
    }

    /// xxx.part3.rar → 3；不是 partN 形式返回 nil。参数需为小写
    private static func rarPartNumber(_ lowerName: String) -> Int? {
        let stem = (lowerName as NSString).deletingPathExtension      // xxx.part3
        let partExt = (stem as NSString).pathExtension                // part3
        guard partExt.hasPrefix("part") else { return nil }
        let digits = partExt.dropFirst(4)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}
