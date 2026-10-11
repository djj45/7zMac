import Foundation

/// 一键压缩：按设置里的默认参数，在所选项目旁边生成压缩包
enum Compressor {

    struct Plan {
        let cwd: URL          // 7zz 的工作目录（所有项目的共同上级）
        let names: [String]   // 相对 cwd 的路径
        let outputDir: URL    // 压缩包放在哪
        let baseName: String  // 压缩包名（不含后缀）
    }

    static func plan(for items: [URL]) -> Plan {
        let items = items.map { $0.standardizedFileURL }
        let parents = items.map { $0.deletingLastPathComponent() }
        let outputDir = parents[0]

        // 共同上级目录（Finder 里通常就是同一个文件夹；搜索结果里可能不同）
        var common = parents[0].pathComponents
        for p in parents.dropFirst() {
            let comps = p.pathComponents
            var n = 0
            while n < common.count, n < comps.count, common[n] == comps[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        let cwdPath = NSString.path(withComponents: common.isEmpty ? ["/"] : common)
        let cwd = URL(fileURLWithPath: cwdPath, isDirectory: true)
        let prefix = cwdPath.hasSuffix("/") ? cwdPath : cwdPath + "/"
        let names = items.map { item -> String in
            item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.lastPathComponent
        }

        let baseName: String
        if items.count == 1 {
            let item = items[0]
            if FileOps.isDirectory(item) {
                baseName = item.lastPathComponent
            } else {
                // 报告.pdf → 报告；没有后缀或是隐藏文件则保留原名
                let stem = item.deletingPathExtension().lastPathComponent
                baseName = stem.isEmpty ? item.lastPathComponent : stem
            }
        } else {
            let folder = outputDir.lastPathComponent
            baseName = (folder.isEmpty || folder == "/") ? "压缩包" : folder
        }
        return Plan(cwd: cwd, names: names, outputDir: outputDir, baseName: baseName)
    }

    /// - Returns: 生成的压缩包（分卷时为第一卷）
    static func run(_ items: [URL], password: String?,
                    progress: ((Int) -> Void)? = nil,
                    cancel: CancelToken? = nil) async throws -> URL {
        precondition(!items.isEmpty)
        let fm = FileManager.default
        let options = CompressOptions.fromPrefs(password: effectivePassword(password))
        let plan = Self.plan(for: items)
        let ext = options.format.fileExtension

        // 分卷：7zz 直接写 名字.7z.001、.002…，没法先写临时文件再改名
        if options.volumeMB > 0 {
            var n = 1
            var output: URL
            repeat {
                let name = n == 1 ? "\(plan.baseName).\(ext)" : "\(plan.baseName) \(n).\(ext)"
                output = plan.outputDir.appendingPathComponent(name)
                n += 1
            } while FileOps.exists(output) || FileOps.exists(URL(fileURLWithPath: output.path + ".001"))

            do {
                try await SevenZip.compress(plan.names, cwd: plan.cwd, output: output, options: options,
                                            progress: progress, cancel: cancel)
            } catch {
                removeVolumes(of: output)
                throw error
            }
            return URL(fileURLWithPath: output.path + ".001")
        }

        let final = FileOps.uniqueURL(in: plan.outputDir, name: "\(plan.baseName).\(ext)", isDirectory: false)
        let temp = plan.outputDir.appendingPathComponent(".\(final.lastPathComponent).7zmac-tmp")
        try? fm.removeItem(at: temp)
        do {
            try await SevenZip.compress(plan.names, cwd: plan.cwd, output: temp, options: options,
                                        progress: progress, cancel: cancel)
            let dest = FileOps.exists(final)
                ? FileOps.uniqueURL(in: plan.outputDir, name: final.lastPathComponent, isDirectory: false)
                : final
            try fm.moveItem(at: temp, to: dest)
            return dest
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
    }

    /// 只有 7z / zip 支持加密；其他格式忽略密码
    private static func effectivePassword(_ password: String?) -> String? {
        Prefs.format.supportsEncryption ? password : nil
    }

    private static func removeVolumes(of output: URL) {
        let dir = output.deletingLastPathComponent()
        let prefix = output.lastPathComponent + "."
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for f in files where f.hasPrefix(prefix) && f.dropFirst(prefix.count).allSatisfy({ $0.isNumber }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }
}
