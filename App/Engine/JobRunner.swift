import AppKit
import SwiftUI

/// 一个压缩/解压任务
@MainActor
final class Job: ObservableObject, Identifiable {
    enum Kind { case compress, extract }
    enum State { case queued, running }

    let id = UUID()
    let kind: Kind
    let title: String
    @Published var state: State = .queued
    @Published var progress: Double = 0
    let cancel = CancelToken()
    fileprivate let work: @MainActor (Job) async throws -> URL?

    init(kind: Kind, title: String, work: @escaping @MainActor (Job) async throws -> URL?) {
        self.kind = kind
        self.title = title
        self.work = work
    }

    /// 交给 7zz 进程封装的进度回调（在后台线程调用）
    nonisolated var progressHandler: (Int) -> Void {
        { [weak self] pct in
            guard let job = self else { return }
            Task { @MainActor in
                let v = Double(pct) / 100
                if abs(v - job.progress) >= 0.005 || pct == 100 { job.progress = v }
            }
        }
    }
}

/// 串行执行任务；任务超过 0.3 秒才显示进度面板
@MainActor
final class JobRunner: ObservableObject {
    static let shared = JobRunner()

    @Published private(set) var jobs: [Job] = []
    private var running = false

    /// 本次运行期间记住的解压密码（按压缩包路径）
    private var passwords: [String: String] = [:]

    /// 有新任务 / 全部完成时通知 AppDelegate（用于空闲自动退出）
    var onActivity: (@MainActor () -> Void)?
    var onIdle: (@MainActor () -> Void)?

    var isBusy: Bool { !jobs.isEmpty }

    // MARK: 入口

    func handle(_ request: JobRequest) {
        let urls = request.paths.map { URL(fileURLWithPath: $0) }.filter { FileOps.exists($0) }
        guard !urls.isEmpty else { return }
        switch request.op {
        case .compress:
            enqueueCompress(urls)
        case .extract:
            for archive in urls where ArchiveTypes.isExtractable(archive) {
                enqueueExtract(archive, into: archive.deletingLastPathComponent())
            }
        }
    }

    func enqueueCompress(_ items: [URL]) {
        let label = items.count == 1 ? items[0].lastPathComponent : "\(items.count) 个项目"
        add(Job(kind: .compress, title: "压缩 \(label)") { job in
            var password: String?
            if Prefs.format.supportsEncryption {
                switch Prefs.encryption {
                case .off:
                    break
                case .ask:
                    guard let pw = PasswordPrompt.askNew(for: label, confirm: Prefs.confirmPassword,
                                                         asciiOnly: Prefs.format == .zip) else {
                        throw SevenZipError.cancelled
                    }
                    password = pw.isEmpty ? nil : pw
                case .fixed:
                    guard let pw = Keychain.loadPassword(), !pw.isEmpty else {
                        throw SevenZipError.message("设置里选择了“使用固定密码”，但还没有设置密码。")
                    }
                    if Prefs.format == .zip, !pw.allSatisfy({ $0.isASCII }) {
                        throw SevenZipError.message(SevenZip.zipPasswordHint)
                    }
                    password = pw
                }
            }
            let result = try await Compressor.run(items, password: password,
                                                  progress: job.progressHandler, cancel: job.cancel)
            return result
        })
    }

    /// 智能解压整个压缩包到 dir
    func enqueueExtract(_ archive: URL, into dir: URL, after: AfterExtract = Prefs.afterExtract) {
        add(Job(kind: .extract, title: "解压 \(archive.lastPathComponent)") { [weak self] job in
            var password = self?.passwords[archive.path]
            while true {
                do {
                    let result = try await SmartExtract.run(archive, into: dir, password: password,
                                                            progress: job.progressHandler, cancel: job.cancel)
                    if let password { self?.passwords[archive.path] = password }
                    Self.finish(result, after: after)
                    if Prefs.trashArchive, !ArchiveTypes.isMultiVolume(name: archive.lastPathComponent) {
                        try? FileManager.default.trashItem(at: archive, resultingItemURL: nil)
                    }
                    return result
                } catch SevenZipError.wrongPassword {
                    guard let pw = PasswordPrompt.ask(for: archive.lastPathComponent, retry: password != nil) else {
                        throw SevenZipError.cancelled
                    }
                    password = pw
                    job.progress = 0
                }
            }
        })
    }

    /// 从浏览窗口解压选中的条目到 dir；完成后调用 onDone（例如在 Finder 中显示，或直接打开）
    func enqueueExtractEntries(_ archive: URL, entries: [SmartExtract.EntryRef], into dir: URL,
                               title: String? = nil,
                               onDone: (@MainActor ([URL]) -> Void)? = nil) {
        let label = title ?? (entries.count == 1 ? "解压 \(entries[0].name)" : "解压 \(entries.count) 个项目")
        add(Job(kind: .extract, title: label) { [weak self] job in
            var password = self?.passwords[archive.path]
            while true {
                do {
                    let results = try await SmartExtract.extractEntries(
                        archive, entries: entries, to: dir, password: password,
                        conflict: .rename, quarantine: Prefs.quarantine,
                        progress: job.progressHandler, cancel: job.cancel)
                    if let password { self?.passwords[archive.path] = password }
                    onDone?(results)
                    return results.first
                } catch SevenZipError.wrongPassword {
                    guard let pw = PasswordPrompt.ask(for: archive.lastPathComponent, retry: password != nil) else {
                        throw SevenZipError.cancelled
                    }
                    password = pw
                    job.progress = 0
                }
            }
        })
    }

    /// 解压完成后的动作：文件夹 → 在 Finder 中打开；单个文件 → 在 Finder 中选中
    static func finish(_ result: URL, after: AfterExtract) {
        switch after {
        case .nothing:
            break
        case .reveal:
            NSWorkspace.shared.activateFileViewerSelecting([result])
        case .open:
            if FileOps.isDirectory(result) {
                NSWorkspace.shared.open(result)
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([result])
            }
        }
    }

    func rememberPassword(_ password: String, for archive: URL) {
        passwords[archive.path] = password
    }

    func password(for archive: URL) -> String? {
        passwords[archive.path]
    }

    // MARK: 队列

    private func add(_ job: Job) {
        jobs.append(job)
        onActivity?()
        startNextIfNeeded()
        // 超过 0.3 秒还没完成才弹出进度面板，小文件“点了就完成”，不闪窗口
        let jobID = job.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Prefs.showProgress, self.jobs.contains(where: { $0.id == jobID }) {
                ProgressPanel.shared.show()
            }
        }
    }

    private func startNextIfNeeded() {
        guard !running else { return }
        guard let next = jobs.first(where: { $0.state == .queued }) else {
            if jobs.isEmpty {
                ProgressPanel.shared.hide()
                onIdle?()
            }
            return
        }
        running = true
        next.state = .running
        Task { @MainActor in
            var failure: Error?
            do {
                _ = try await next.work(next)
            } catch {
                failure = error
            }
            self.jobs.removeAll { $0.id == next.id }
            self.running = false
            self.startNextIfNeeded()
            if let failure, !Self.isCancellation(failure) {
                Alerts.showError(title: "\(next.title) 失败", error: failure)
            }
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if case SevenZipError.cancelled = error { return true }
        return false
    }

    func cancelAll() {
        jobs.forEach { $0.cancel.cancel() }
    }
}
