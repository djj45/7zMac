import AppKit
import Combine
import SwiftUI

/// 右上角的浮动进度小面板：一行一个任务，可取消。
/// 不抢焦点、不出现在 Dock，任务全部结束后自动消失。
@MainActor
final class ProgressPanel {
    static let shared = ProgressPanel()

    private let width: CGFloat = 380
    private let rowHeight: CGFloat = 50
    private let padding: CGFloat = 14
    private var jobsSubscription: AnyCancellable?

    private init() {}

    private lazy var panel: NSPanel = {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: rowHeight + padding * 2),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.title = "7zMac"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let host = NSHostingView(rootView: ProgressListView(runner: JobRunner.shared))
        host.autoresizingMask = [.width, .height]
        host.frame = panel.contentLayoutRect
        panel.contentView = host
        return panel
    }()

    func show() {
        if jobsSubscription == nil {
            // 任务数变化时调整面板高度；没有任务时收起
            jobsSubscription = JobRunner.shared.$jobs
                .receive(on: RunLoop.main)
                .sink { [weak self] jobs in
                    guard let self else { return }
                    if jobs.isEmpty {
                        self.hide()
                    } else if self.panel.isVisible {
                        self.resize(rows: jobs.count)
                    }
                }
        }
        let count = JobRunner.shared.jobs.count
        guard count > 0 else { return }
        resize(rows: count)
        if !panel.isVisible {
            placeAtTopRight()
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// 保持面板上边缘不动，按行数调整高度
    private func resize(rows: Int) {
        let contentHeight = CGFloat(min(max(rows, 1), 8)) * rowHeight + padding * 2 + 20   // +20：透明标题栏
        let target = panel.frameRect(forContentRect: NSRect(x: 0, y: 0, width: width, height: contentHeight))
        var frame = panel.frame
        let top = frame.maxY
        frame.size = target.size
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true)
    }

    private func placeAtTopRight() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: vf.maxX - size.width - 16, y: vf.maxY - size.height - 12))
    }
}

private struct ProgressListView: View {
    @ObservedObject var runner: JobRunner

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(runner.jobs) { job in
                JobRow(job: job)
                    .frame(height: 50)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 26)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct JobRow: View {
    @ObservedObject var job: Job

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.kind == .compress ? "archivebox" : "shippingbox")
                .font(.system(size: 18))
                .foregroundColor(.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(job.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if job.state == .running {
                        Text("\(Int(job.progress * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }
                }
                if job.state == .queued {
                    Text("等待中…").font(.system(size: 11)).foregroundColor(.secondary)
                } else {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                }
            }
            Button {
                job.cancel.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("取消")
        }
    }
}
