import AppKit

/// 双击压缩包时打开的只读“文档”。真正的读取在浏览窗口里异步进行（可能需要密码）。
@objc(ArchiveDocument)
final class ArchiveDocument: NSDocument {

    /// 本窗口里输入过的密码
    var password: String?

    override class var autosavesInPlace: Bool { false }

    override func read(from url: URL, ofType typeName: String) throws {
        // 不在这里读取：列表在 BrowserWindowController 中异步加载
    }

    override func makeWindowControllers() {
        let controller = BrowserWindowController()
        addWindowController(controller)
        controller.load()
    }

    override var isDocumentEdited: Bool { false }
}
