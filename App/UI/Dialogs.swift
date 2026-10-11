import AppKit

@MainActor
enum Alerts {
    static func showError(title: String, error: Error) {
        show(title: title, message: error.localizedDescription, style: .warning)
    }

    static func show(title: String, message: String, style: NSAlert.Style = .informational) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        _ = alert.runModal()
    }
}

@MainActor
enum PasswordPrompt {

    /// 解压时询问密码；取消返回 nil
    static func ask(for name: String, retry: Bool) -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = retry ? "密码不正确" : "“\(name)”已加密"
        alert.informativeText = retry ? "请重新输入“\(name)”的密码：" : "请输入密码："
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "解压")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    /// 压缩时设置新密码（输入两次）；取消返回 nil，留空表示不加密
    static func askNew(for name: String) -> String? {
        var hint = "留空则不加密。"
        while true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "为“\(name)”设置密码"
            alert.informativeText = hint

            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
            stack.orientation = .vertical
            stack.spacing = 8
            let first = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            first.placeholderString = "密码"
            let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            second.placeholderString = "再次输入"
            stack.addArrangedSubview(first)
            stack.addArrangedSubview(second)
            alert.accessoryView = stack
            alert.addButton(withTitle: "压缩")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = first

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            if first.stringValue == second.stringValue { return first.stringValue }
            hint = "两次输入的密码不一致，请重新输入。"
        }
    }
}
