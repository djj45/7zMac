import Foundation

// MARK: - 错误

enum SevenZipError: LocalizedError {
    case wrongPassword
    case cancelled
    case emptyArchive
    case failed(String)
    case launchFailed(String)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .wrongPassword:        return "密码错误，或压缩包已加密需要密码。"
        case .cancelled:            return "已取消。"
        case .emptyArchive:         return "压缩包是空的。"
        case .failed(let msg):      return msg
        case .launchFailed(let msg): return "无法启动 7zz：\(msg)"
        case .message(let msg):     return msg
        }
    }
}

// MARK: - 取消令牌（线程安全）

final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [() -> Void] = []

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        if cancelled { lock.unlock(); return }
        cancelled = true
        let hs = handlers
        handlers = []
        lock.unlock()
        hs.forEach { $0() }
    }

    /// 注册取消回调；若已取消则立即执行
    func onCancel(_ handler: @escaping () -> Void) {
        lock.lock()
        if cancelled { lock.unlock(); handler(); return }
        handlers.append(handler)
        lock.unlock()
    }
}

/// 可在并发闭包间共享的可变盒子（每个盒子只由一个线程写入）
final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

struct RunResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
}

/// 从 7zz 的 -bsp 输出里扫描 “ 45%” 这样的进度（跨数据块保持状态）
struct PercentScanner {
    private var digits = 0
    private var value = 0

    mutating func feed(_ data: Data) -> Int? {
        var last: Int?
        for b in data {
            if b >= 48 && b <= 57 {
                if digits == 0 { value = 0 }
                value = value * 10 + Int(b - 48)
                digits += 1
            } else {
                if b == 37, digits > 0, digits <= 3 { last = min(value, 100) }   // '%'
                digits = 0
            }
        }
        return last
    }
}

// MARK: - 压缩参数

struct CompressOptions {
    var format: ArchiveFormat
    var level: CompressionLevel
    var solid: Bool
    var threads: Int
    var password: String?
    var encryptNames: Bool
    var volumeMB: Int
    var excludeJunk: Bool

    static func fromPrefs(password: String?) -> CompressOptions {
        CompressOptions(format: Prefs.format,
                        level: Prefs.level,
                        solid: Prefs.solid,
                        threads: Prefs.threads,
                        password: password,
                        encryptNames: Prefs.encryptNames,
                        volumeMB: Prefs.volumeMB,
                        excludeJunk: Prefs.excludeJunk)
    }
}

// MARK: - 7zz 调用

enum SevenZip {

    /// 没有密码时传给 7zz 的占位密码：避免 7zz 在加密包上停下来等待键盘输入，
    /// 遇到加密内容会直接报 “Wrong password”，由界面弹框再重试。
    static let placeholderPassword = "__7zmac_no_password__"

    static var executableURL: URL {
        if let url = Bundle.main.url(forAuxiliaryExecutable: "7zz") { return url }
        return URL(fileURLWithPath: "/usr/local/bin/7zz")
    }

    /// 7zz 第一行版本信息，例如 “7-Zip (z) 26.04 (arm64) …”
    static func versionString() -> String {
        let p = Process()
        p.executableURL = executableURL
        p.arguments = []
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "未找到 7zz" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix("7-Zip") }) ?? "未知版本"
    }

    // MARK: 列表

    struct ListResult {
        var entries: [ArchiveEntry]
        var type: String?
    }

    static func list(_ archive: URL, password: String?, cancel: CancelToken? = nil) async throws -> ListResult {
        let pw = "-p" + (password ?? placeholderPassword)
        let name = archive.lastPathComponent
        let results: [RunResult]

        if ArchiveTypes.isCompoundTar(name: name) {
            // tar.gz 等：先解出 tar 流，再列出 tar 的内容
            results = try await execute([
                ["x", "-so", "-bsp0", "-bse2", "-sccUTF-8", pw, "--", archive.path],
                ["l", "-slt", "-si", "-ttar", "-sccUTF-8"],
            ], captureStdout: true, cancel: cancel)
        } else {
            var args = ["l", "-slt", "-sccUTF-8", pw]
            if ArchiveTypes.isZip(name: name) { args.append("-mcp=\(Prefs.zipCodePage.rawValue)") }
            args += ["--", archive.path]
            results = try await execute([args], captureStdout: true, cancel: cancel)
        }

        for r in results { try check(r, cancel: cancel) }
        let text = String(decoding: results.last?.stdout ?? Data(), as: UTF8.self)
        return ListParser.parse(text)
    }

    // MARK: 解压

    /// 把整个压缩包（或其中 entries 指定的条目）解压到 dir
    static func extract(_ archive: URL, to dir: URL, entries: [String] = [],
                        password: String?, unwrapTar: Bool = true,
                        progress: ((Int) -> Void)? = nil, cancel: CancelToken? = nil) async throws {
        let pw = "-p" + (password ?? placeholderPassword)
        let name = archive.lastPathComponent
        let out = "-o" + dir.path

        if unwrapTar && ArchiveTypes.isCompoundTar(name: name) {
            var second = ["x", "-si", "-ttar", "-y", "-bso0", "-bse2", "-bsp0", "-sccUTF-8", out]
            if !entries.isEmpty { second += ["-spd", "--"] + entries }
            let results = try await execute([
                ["x", "-so", "-bsp2", "-bse2", "-sccUTF-8", pw, "--", archive.path],
                second,
            ], progress: progress, cancel: cancel)
            for r in results { try check(r, cancel: cancel) }
            return
        }

        func args(withCodePage: Bool) -> [String] {
            var a = ["x", "-y", "-bso0", "-bse2", "-bsp1", "-sccUTF-8", pw, out]
            if withCodePage { a.append("-mcp=\(Prefs.zipCodePage.rawValue)") }
            if !entries.isEmpty { a.append("-spd") }
            return a + ["--", archive.path] + entries
        }

        let useCP = ArchiveTypes.isZip(name: name)
        let r = try await execute([args(withCodePage: useCP)], progress: progress, cancel: cancel)[0]
        if useCP, r.exitCode == 2, r.stderr.contains("E_INVALIDARG") {
            // 后缀是 .zip 但实际不是 ZIP：去掉代码页参数重试
            let r2 = try await execute([args(withCodePage: false)], progress: progress, cancel: cancel)[0]
            try check(r2, cancel: cancel)
            return
        }
        try check(r, cancel: cancel)
    }

    // MARK: 压缩

    /// 在 cwd 目录下，把 names（相对路径）压缩成 output
    static func compress(_ names: [String], cwd: URL, output: URL, options o: CompressOptions,
                         progress: ((Int) -> Void)? = nil, cancel: CancelToken? = nil) async throws {
        let excludes = o.excludeJunk ? ["-xr!.DS_Store", "-xr!__MACOSX", "-xr!._*"] : []
        let mt = o.threads > 0 ? "-mmt=\(o.threads)" : "-mmt=on"
        let common = ["-bso0", "-bse2", "-bsp1", "-sccUTF-8", "-y", "-snl"]
        let volume = o.volumeMB > 0 ? ["-v\(o.volumeMB)m"] : []

        switch o.format {
        case .sevenZ:
            var a = ["a", "-t7z", "-mx=\(o.level.rawValue)", mt, "-ms=\(o.solid ? "on" : "off")"] + common + excludes + volume
            if let pw = o.password, !pw.isEmpty {
                a.append("-p\(pw)")
                if o.encryptNames { a.append("-mhe=on") }
            }
            a += ["--", output.path] + names
            let r = try await execute([a], cwd: cwd, progress: progress, cancel: cancel)[0]
            try check(r, cancel: cancel)

        case .zip:
            var a = ["a", "-tzip", "-mx=\(o.level.rawValue)", mt, "-mcu=on"] + common + excludes + volume
            if let pw = o.password, !pw.isEmpty {
                a += ["-p\(pw)", "-mem=AES256"]
            }
            a += ["--", output.path] + names
            let r = try await execute([a], cwd: cwd, progress: progress, cancel: cancel)[0]
            try check(r, cancel: cancel)

        case .tarGz, .tarXz:
            let tar = ["a", "-ttar", "-so", "-an", "-snl", "-bso0", "-bse2", "-bsp2", "-sccUTF-8"] + excludes + ["--"] + names
            var comp = ["a", o.format == .tarGz ? "-tgzip" : "-txz", "-si",
                        "-mx=\(max(o.level.rawValue, 1))", "-bso0", "-bse2", "-bsp0", "-sccUTF-8", "-y"] + volume
            if o.format == .tarXz { comp.append(mt) }
            comp += ["--", output.path]
            let results = try await execute([tar, comp], cwd: cwd, progress: progress, cancel: cancel)
            // 压缩端失败时 tar 端会因为管道断开而报错，优先报告压缩端的错误
            try check(results[1], cancel: cancel)
            try check(results[0], cancel: cancel)
        }
    }

    // MARK: - 结果检查

    static func check(_ r: RunResult, cancel: CancelToken?) throws {
        if cancel?.isCancelled == true { throw SevenZipError.cancelled }
        // 0 = 成功，1 = 警告（例如个别文件被占用），都按成功处理
        if r.exitCode == 0 || r.exitCode == 1 { return }
        if r.stderr.contains("Wrong password") { throw SevenZipError.wrongPassword }
        if r.exitCode == 255 { throw SevenZipError.cancelled }
        throw SevenZipError.failed(cleanMessage(r.stderr, code: r.exitCode))
    }

    static func cleanMessage(_ stderr: String, code: Int32) -> String {
        let lines = stderr
            .replacingOccurrences(of: "\u{8}", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.isEmpty else { return false }
                // 去掉进度残留，例如 “45% 3 - file”
                if let first = line.split(separator: " ").first, first.hasSuffix("%"),
                   Int(first.dropLast()) != nil { return false }
                return true
            }
        var seen = Set<String>()
        let unique = lines.filter { seen.insert($0).inserted }
        let body = unique.suffix(8).joined(separator: "\n")
        let head: String
        switch code {
        case 2:  head = "7-Zip 出错"
        case 7:  head = "7-Zip 参数错误"
        case 8:  head = "内存不足"
        default: head = "7-Zip 失败（退出码 \(code)）"
        }
        return body.isEmpty ? head : "\(head)：\n\(body)"
    }

    // MARK: - 进程执行（支持 a | b 管道）

    private static func makeProcess(_ args: [String], cwd: URL?) -> Process {
        let p = Process()
        p.executableURL = executableURL
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        p.environment = env
        return p
    }

    /// 依次启动 stages 中的进程并用管道串联；返回每个进程的结果。
    /// 进度：扫描最后一个进程的 stdout（-bsp1，未捕获 stdout 时）和第一个进程的 stderr（-bsp2）。
    static func execute(_ stages: [[String]], cwd: URL? = nil, captureStdout: Bool = false,
                        progress: ((Int) -> Void)? = nil,
                        cancel: CancelToken? = nil) async throws -> [RunResult] {
        precondition(!stages.isEmpty)
        if cancel?.isCancelled == true { throw SevenZipError.cancelled }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[RunResult], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let procs = stages.map { makeProcess($0, cwd: cwd) }
                let errPipes = procs.map { _ in Pipe() }
                let outPipe = Pipe()

                procs[0].standardInput = FileHandle.nullDevice
                for i in 0..<procs.count {
                    procs[i].standardError = errPipes[i]
                    if i + 1 < procs.count {
                        let link = Pipe()
                        procs[i].standardOutput = link
                        procs[i + 1].standardInput = link
                    }
                }
                procs[procs.count - 1].standardOutput = outPipe

                let outBox = Box(Data())
                let errBoxes = procs.map { _ in Box(Data()) }
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    var scanner = PercentScanner()
                    let h = outPipe.fileHandleForReading
                    while true {
                        let chunk = h.availableData
                        if chunk.isEmpty { break }
                        if captureStdout {
                            outBox.value.append(chunk)
                        } else if let progress, let pct = scanner.feed(chunk) {
                            progress(pct)
                        }
                    }
                    group.leave()
                }

                for i in 0..<procs.count {
                    let box = errBoxes[i]
                    let pipe = errPipes[i]
                    let scanProgress = (i == 0) && procs.count > 1
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        var scanner = PercentScanner()
                        let h = pipe.fileHandleForReading
                        while true {
                            let chunk = h.availableData
                            if chunk.isEmpty { break }
                            box.value.append(chunk)
                            if scanProgress, let progress, let pct = scanner.feed(chunk) {
                                progress(pct)
                            }
                        }
                        group.leave()
                    }
                }

                var launched: [Process] = []
                do {
                    for p in procs {
                        try p.run()
                        launched.append(p)
                    }
                } catch {
                    for p in launched where p.isRunning { p.terminate() }
                    for p in launched { p.waitUntilExit() }
                    // 关掉未启动进程的写端，让读取线程结束
                    try? outPipe.fileHandleForWriting.close()
                    for pipe in errPipes { try? pipe.fileHandleForWriting.close() }
                    group.wait()
                    cont.resume(throwing: SevenZipError.launchFailed(error.localizedDescription))
                    return
                }

                cancel?.onCancel {
                    for p in procs where p.isRunning { p.interrupt() }
                }

                for p in procs { p.waitUntilExit() }
                group.wait()

                var results: [RunResult] = []
                for (i, p) in procs.enumerated() {
                    results.append(RunResult(
                        exitCode: p.terminationStatus,
                        stdout: i == procs.count - 1 ? outBox.value : Data(),
                        stderr: String(decoding: errBoxes[i].value, as: UTF8.self)))
                }
                cont.resume(returning: results)
            }
        }
    }
}
