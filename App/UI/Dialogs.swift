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

/// 密码输入框组：macOS 的密码框（NSSecureTextField）会禁用输入法，打不了中文；
/// 勾选“显示密码”后换成普通输入框，就可以用拼音输入法输入中文密码。
@MainActor
final class PasswordFields: NSObject {
    private var secures: [NSSecureTextField] = []
    private var plains: [NSTextField] = []
    private let checkbox: NSButton
    let view: NSStackView

    init(placeholders: [String]) {
        view = NSStackView()
        checkbox = NSButton(checkboxWithTitle: "显示密码（输入中文密码时请勾选）", target: nil, action: nil)
        super.init()
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 8
        for placeholder in placeholders {
            let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            let plain = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            for field in [secure, plain] as [NSTextField] {
                field.placeholderString = placeholder
                field.translatesAutoresizingMaskIntoConstraints = false
                field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            }
            plain.isHidden = true
            view.addArrangedSubview(secure)
            view.addArrangedSubview(plain)
            secures.append(secure)
            plains.append(plain)
        }
        checkbox.target = self
        checkbox.action = #selector(toggle(_:))
        view.addArrangedSubview(checkbox)
        view.frame = NSRect(x: 0, y: 0, width: 280, height: CGFloat(placeholders.count) * 32 + 22)
    }

    private var showing: Bool { checkbox.state == .on }

    var values: [String] { showing ? plains.map(\.stringValue) : secures.map(\.stringValue) }

    var firstField: NSView { showing ? plains[0] : secures[0] }

    @objc private func toggle(_ sender: NSButton) {
        for i in secures.indices {
            if showing {
                plains[i].stringValue = secures[i].stringValue
            } else {
                secures[i].stringValue = plains[i].stringValue
            }
            secures[i].isHidden = showing
            plains[i].isHidden = !showing
        }
        view.window?.makeFirstResponder(firstField)
    }
}

@MainActor
enum PasswordPrompt {

    /// 询问压缩包密码；取消返回 nil。button：确认按钮文字（解压时“解压”，浏览时“打开”）
    static func ask(for name: String, retry: Bool, button: String = "解压") -> String? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = retry ? "密码不正确" : "“\(name)”已加密"
        alert.informativeText = retry ? "请重新输入“\(name)”的密码：" : "请输入密码："
        let fields = PasswordFields(placeholders: ["密码"])
        alert.accessoryView = fields.view
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = fields.firstField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return fields.values[0]
    }

    /// 压缩时设置新密码；取消返回 nil，留空表示不加密。
    /// confirm：是否要求再输入一遍；asciiOnly：ZIP 格式只允许英文密码
    static func askNew(for name: String, confirm: Bool = true, asciiOnly: Bool = false) -> String? {
        var hint = asciiOnly ? "留空则不加密。ZIP 格式只能使用英文密码。" : "留空则不加密。"
        while true {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "为“\(name)”设置密码"
            alert.informativeText = hint
            let fields = PasswordFields(placeholders: confirm ? ["密码", "再次输入"] : ["密码"])
            alert.accessoryView = fields.view
            alert.addButton(withTitle: "压缩")
            alert.addButton(withTitle: "取消")
            alert.window.initialFirstResponder = fields.firstField

            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let values = fields.values
            if confirm && values[0] != values[1] {
                hint = "两次输入的密码不一致，请重新输入。"
            } else if asciiOnly && !values[0].allSatisfy({ $0.isASCII }) {
                hint = SevenZip.zipPasswordHint
            } else {
                return values[0]
            }
        }
    }
}
