import AppKit
import ApplicationServices
import Foundation
import WebKit

/// 本地对照用的窗口快照：仅当设置 `DRAWOFFER_SNAPSHOT_DIR` 时启用。
/// 在该目录写入 `request-<name>` 文件后，App 把主窗口内容渲染为 `<name>.png`（不需要系统屏幕录制权限）。
/// 写入 `click-<name>` 文件（内容为窗口内 `x,y` 点坐标，左上角为原点）可模拟一次鼠标点击，便于脚本化对照。
@MainActor
enum DebugSnapshot {
    private static var timer: Timer?
    private static var directory: URL?

    /// 对照模式下把浏览器登录地址写入 `browser-url.txt`，由脚本在受控浏览器里完成登录；返回 true 表示已接管、不打开系统浏览器。
    static func recordBrowserURL(_ url: URL) -> Bool {
        guard let directory, ProcessInfo.processInfo.environment["DRAWOFFER_SNAPSHOT_CAPTURE_LOGIN"] == "1" else { return false }
        try? url.absoluteString.write(to: directory.appendingPathComponent("browser-url.txt"), atomically: true, encoding: .utf8)
        return true
    }

    static func startIfConfigured() {
        guard timer == nil, let path = ProcessInfo.processInfo.environment["DRAWOFFER_SNAPSHOT_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.directory = directory
        let timer = Timer(timeInterval: 0.3, repeats: true) { _ in
            MainActor.assumeIsolated { poll(directory) }
        }
        // 菜单展开时主线程处于事件跟踪模式，加到 common 模式才能继续响应脚本。
        RunLoop.main.add(timer, forMode: .common)
        Self.timer = timer
    }

    private static func poll(_ directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names.sorted() {
            let file = directory.appendingPathComponent(name)
            if name.hasPrefix("request-") {
                try? FileManager.default.removeItem(at: file)
                let base = String(name.dropFirst(8))
                capture(to: directory.appendingPathComponent(base + ".png"))
                dumpAccessibility(to: directory.appendingPathComponent(base + ".ax.txt"))
            } else if name.hasPrefix("press-") {
                // 内容为要按下的元素标签（完整匹配优先，其次包含）；可用 "#2 标签" 指定第几个匹配。
                let text = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: file)
                let result = press(label: text)
                try? result.write(to: directory.appendingPathComponent(String(name.dropFirst(6)) + ".press.txt"), atomically: true, encoding: .utf8)
            } else if name.hasPrefix("menu-") {
                // 内容为主菜单路径，例如 "账号/退出登录"
                let path = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "/").map(String.init)
                try? FileManager.default.removeItem(at: file)
                var menu = NSApplication.shared.mainMenu
                var item: NSMenuItem?
                for title in path { item = menu?.items.first { $0.title == title }; menu = item?.submenu }
                if let item, let parent = item.menu, let index = parent.items.firstIndex(of: item) { parent.performActionForItem(at: index) }
            } else if name.hasPrefix("fill-") {
                // 第一行为输入框标签（包含匹配），其余为要输入的文字；以换行结尾表示回车提交。
                let content = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: file)
                let label = content.prefix { $0 != "\n" }
                let text = content.dropFirst(label.count + 1)
                let ok = focusField(label: String(label))
                try? (ok ? "OK" : "NOT FOUND: \(label)").write(to: directory.appendingPathComponent(String(name.dropFirst(5)) + ".fill.txt"), atomically: true, encoding: .utf8)
                if ok {
                    let pending = directory.appendingPathComponent("type-after-fill-\(name.dropFirst(5))")
                    // 前缀 \u{2} 表示整体替换：先全选再写入（空文本即清空）。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { try? ("\u{2}" + String(text)).write(to: pending, atomically: true, encoding: .utf8) }
                }
            } else if name.hasPrefix("js-") {
                // 对照调试：在第一个网页视图（可编辑纸面）里执行脚本，结果写入 `<name>.js.txt`。
                let script = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: file)
                let out = directory.appendingPathComponent(String(name.dropFirst(3)) + ".js.txt")
                guard let web = window?.contentView.flatMap(firstWebView) else { try? "NO WEBVIEW".write(to: out, atomically: true, encoding: .utf8); return }
                // 脚本体按 async 函数执行：可以 await，用 return 返回结果
                web.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                    let text: String
                    switch result {
                    case .success(let value): text = String(describing: value)
                    case .failure(let error): text = "ERROR \(error)"
                    }
                    try? text.write(to: out, atomically: true, encoding: .utf8)
                }
            } else if name.hasPrefix("type-") {
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: file)
                // 以换行结尾表示输入后回车提交（触发 SwiftUI onSubmit）；"\u{1b}" 表示按 Esc。
                if let responder = (NSApplication.shared.keyWindow ?? window)?.firstResponder as? NSTextView {
                    if text == "\u{1b}" { responder.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
                    else {
                        let replace = text.hasPrefix("\u{2}")
                        var body = replace ? String(text.dropFirst()) : text
                        if body.hasSuffix("\n") { body = String(body.dropLast()) }
                        if replace || !body.isEmpty {
                            responder.selectAll(nil)
                            if body.isEmpty { responder.deleteBackward(nil) } else { responder.insertText(body, replacementRange: responder.selectedRange()) }
                        }
                        if text.hasSuffix("\n") { responder.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
                    }
                }
            }
        }
    }

    private static func firstWebView(_ view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews { if let found = firstWebView(child) { return found } }
        return nil
    }

    private static var window: NSWindow? {
        NSApplication.shared.windows.first { $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }
    }

    private static func capture(to url: URL) {
        guard let view = window?.contentView?.superview ?? window?.contentView else { return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: url) }
    }

    /// 输出窗口的无障碍树（角色、标题/值、窗口内坐标），用于逐项核对按钮与文字是否与 Web 一致。
    /// 走 AX C 接口读本进程：SwiftUI 元素只通过它暴露。
    private static func dumpAccessibility(to url: URL) {
        guard let window else {
            let list = NSApplication.shared.windows.map { "\(type(of: $0)) visible=\($0.isVisible) \($0.frame)" }.joined(separator: "\n")
            try? ("no window\n" + list).write(to: url, atomically: true, encoding: .utf8)
            return
        }
        let app = AXUIElementCreateApplication(getpid())
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let origin = window.frame
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        var lines: [String] = []
        func string(_ element: AXUIElement, _ name: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
            if let text = value as? String { return text.isEmpty ? nil : text }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        func frame(_ element: AXUIElement) -> String {
            var position: CFTypeRef?, size: CFTypeRef?
            var point = CGPoint.zero, extent = CGSize.zero
            if AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success, let position {
                AXValueGetValue(position as! AXValue, .cgPoint, &point)
            }
            if AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success, let size {
                AXValueGetValue(size as! AXValue, .cgSize, &extent)
            }
            let top = point.y - (screenHeight - origin.maxY)
            return String(format: " @%.0f,%.0f %.0fx%.0f", point.x - origin.minX, top, extent.width, extent.height)
        }
        var budget = 20000
        func visit(_ element: AXUIElement, depth: Int) {
            budget -= 1
            guard depth < 40, budget > 0 else { return }
            let role = string(element, kAXRoleAttribute) ?? ""
            if role == "AXApplication" { return }
            var parts: [String] = []
            for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute] {
                if let text = string(element, name), !parts.contains(text) { parts.append(text) }
            }
            let label = parts.joined(separator: " | ").replacingOccurrences(of: "\n", with: "⏎")
            let actionable = ["AXButton", "AXTextField", "AXTextArea", "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXLink", "AXRadioButton", "AXSlider", "AXComboBox"].contains(role)
            if !label.isEmpty || actionable {
                lines.append(String(repeating: "  ", count: min(depth, 24)) + role.replacingOccurrences(of: "AX", with: "") + " " + label + frame(element))
            }
            for child in childList(element) { visit(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
            for item in list { visit(item, depth: 0) }
        }
        if lines.isEmpty { lines.append("AX: empty (trusted=\(AXIsProcessTrusted()))") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 让标签匹配的输入框获得焦点（先激活窗口，非前台时 SwiftUI 不接受焦点）。
    private static func focusField(label: String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if NSApplication.shared.keyWindow == nil { window?.makeKeyAndOrderFront(nil) }
        let app = AXUIElementCreateApplication(getpid())
        var found: AXUIElement?
        func text(_ element: AXUIElement, _ name: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
            return value as? String ?? ""
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard found == nil, depth < 40 else { return }
            let role = text(element, kAXRoleAttribute)
            if role == "AXApplication" { return }
            if ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
               [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].map({ text(element, $0) }).contains(where: { !$0.isEmpty && $0.contains(label) }) {
                found = element; return
            }
            for child in childList(element) { visit(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
            for item in list { visit(item, depth: 0) }
        }
        guard let found else { return false }
        return AXUIElementSetAttributeValue(found, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    /// SwiftUI 宿主首次读取子节点可能返回 cannotComplete：重试一次，再回退到可见子节点。
    private static func childList(_ element: AXUIElement) -> [AXUIElement] {
        for name in [kAXChildrenAttribute, kAXChildrenAttribute, kAXVisibleChildrenAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let list = value as? [AXUIElement], !list.isEmpty { return list }
        }
        return []
    }

    /// 起点：主窗口与其余窗口（只取角色为 AXWindow / AXSheet 的元素）。
    private static func roots(_ app: AXUIElement) -> [AXUIElement] {
        func role(_ element: AXUIElement) -> String {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value)
            return value as? String ?? ""
        }
        var result: [AXUIElement] = []
        for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, name as CFString, &value) == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = value as! AXUIElement
                if !result.contains(where: { CFEqual($0, element) }) { result.append(element) }
            }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success, let list = windows as? [AXUIElement] {
            for element in list where ["AXWindow", "AXSheet"].contains(role(element)) && !result.contains(where: { CFEqual($0, element) }) {
                result.append(element)
            }
        }
        return result.filter { ["AXWindow", "AXSheet"].contains(role($0)) }
    }

    private static func press(label: String) -> String {
        var index = 1
        var target = label
        if label.hasPrefix("#"), let space = label.firstIndex(of: " "), let number = Int(label.dropFirst().prefix(upTo: space)) {
            index = number
            target = String(label[label.index(after: space)...])
        }
        let app = AXUIElementCreateApplication(getpid())
        var exact: [AXUIElement] = [], partial: [AXUIElement] = []
        func text(_ element: AXUIElement, _ name: String) -> String {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return "" }
            return value as? String ?? ""
        }
        func visit(_ element: AXUIElement, depth: Int) {
            guard depth < 80 else { return }
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success, role as? String == "AXApplication" { return }
            var actions: CFArray?
            if AXUIElementCopyActionNames(element, &actions) == .success, let names = actions as? [String],
               names.contains(kAXPressAction) || names.contains(kAXShowMenuAction) {
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].map { text(element, $0) }.filter { !$0.isEmpty }
                if labels.contains(target) { exact.append(element) }
                else if labels.contains(where: { $0.contains(target) }) { partial.append(element) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success, let list = children as? [AXUIElement] {
                for child in list { visit(child, depth: depth + 1) }
            }
        }
        for root in roots(app) { visit(root, depth: 0) }
        let matches = exact.isEmpty ? partial : exact
        guard matches.count >= index else { return "NOT FOUND: \(label)" }
        var names: CFArray?
        AXUIElementCopyActionNames(matches[index - 1], &names)
        let action = (names as? [String])?.contains(kAXPressAction) == true ? kAXPressAction : kAXShowMenuAction
        let status = AXUIElementPerformAction(matches[index - 1], action as CFString)
        return status == .success ? "OK (\(matches.count) matches)" : "FAILED \(status.rawValue)"
    }
}
