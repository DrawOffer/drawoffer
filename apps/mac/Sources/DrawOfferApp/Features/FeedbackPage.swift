import AppKit
import CoreImage.CIFilterBuiltins
import DrawOfferCore
import SwiftUI
import UniformTypeIdentifiers

/// 反馈得积分（macOS 稿 5:4 · 10.03–10.05，Web `features/feedback/FeedbackPage.tsx`）：整窗页面盖住侧栏，
/// 顶栏 52 高只有右上「← 返回」；左边表单一列（720），右上交流群二维码（232）；1440 宽时表单左缘比居中右移 76。
/// 登录时带账号提交，确认有效后送积分并站内通知；未登录匿名提交，可留联系方式。提交成功后原地换成结果。
struct FeedbackPage: View {
    @Environment(SessionStore.self) private var session
    let back: () -> Void
    let login: () -> Void
    @State private var sent = false
    @State private var formKey = UUID()

    private var user: User? { if case .signedIn(let user) = session.phase { return user }; return nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: back) {
                    HStack(spacing: 4) { Text("←"); Text("返回") }.font(V3.sans(14)).contentShape(Rectangle())
                }.buttonStyle(FeedbackBackStyle()).keyboardShortcut(.cancelAction)
            }.padding(.horizontal, 48).frame(height: 52)
                .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xE8E8E4)).frame(height: 1) }
            if sent {
                GeometryReader { geometry in
                    FeedbackSent(signedIn: user != nil, again: { sent = false; formKey = UUID() }, back: back)
                        .frame(maxWidth: .infinity).padding(.top, min(268, geometry.size.height * 0.28))
                }
            } else {
                GeometryReader { geometry in
                    ScrollView {
                        FeedbackLayout(width: geometry.size.width) {
                            FeedbackForm(user: user, login: login, sent: { sent = true }).id(formKey)
                        } aside: {
                            FeedbackCommunity()
                        }.padding(.top, 64).padding(.bottom, 96)
                    }.scrollIndicators(.automatic)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// `.fb-main`：720 表单 + 64 + 232 二维码；整体居中后右移 clamp((宽 − 1168) / 2, 0, 76)；窄于 1080 时二维码挪到表单下面。
private struct FeedbackLayout<Form: View, Aside: View>: View {
    let width: CGFloat
    @ViewBuilder var form: () -> Form
    @ViewBuilder var aside: () -> Aside
    var body: some View {
        if width >= 1080 {
            let formWidth = min(720, width - 48 - 64 - 232 - 48)
            let shift = min(76, max(0, (width - 1168) / 2))
            HStack(alignment: .top, spacing: 64) {
                form().frame(width: formWidth)
                aside().frame(width: 232, alignment: .leading)
            }.offset(x: shift).frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 40) {
                form()
                aside()
            }.frame(maxWidth: min(768, width - 48)).frame(maxWidth: .infinity)
        }
    }
}

// MARK: 表单

private let fbInk = Color(hex: 0x141413)
private let fbHint = Color(hex: 0x9A9A94)
private let fbLine = Color(hex: 0xE4E4E0)
private let fbFocus = Color(hex: 0xB3B3AD)

private struct FeedbackForm: View {
    @Environment(SessionStore.self) private var session
    let user: User?
    let login: () -> Void
    let sent: () -> Void
    @State private var draft = FeedbackDraft()
    @State private var shots: [FeedbackShot] = []
    @State private var busy = false
    @State private var error: String?
    @State private var pasteMonitor: Any?
    @FocusState private var focus: String?

    private var signedIn: Bool { user != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("反馈得积分").font(V3.sans(24, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19))
                    HStack(spacing: 4) {
                        Image(systemName: "dollarsign.circle").font(.system(size: 12))
                        Text(signedIn ? "确认有效即送积分" : "登录后反馈可得积分").font(V3.sans(12, weight: .medium))
                    }.foregroundStyle(Color(hex: 0xC9711C)).padding(.leading, 8).padding(.trailing, 10).frame(height: 23)
                        .background(Color(hex: 0xC9711C).opacity(0.1), in: Capsule())
                }
                Text(signedIn ? "说得越具体，我们越快定位。确认有效后在站内通知你，并送积分。" : "不登录也能提交。说得越具体，我们越快定位。")
                    .font(V3.sans(13)).foregroundStyle(fbHint)
            }
            row("反馈类型") {
                FeedbackKindPicker(selection: $draft.kind)
            }
            row("涉及功能") {
                FeedbackSelect(value: draft.feature.isEmpty ? nil : draft.feature, placeholder: "选择遇到问题的功能",
                               options: FeedbackDraft.features.map { ($0, $0) }) { draft.feature = $0 }
            }
            row("一句话说明") {
                FeedbackInput(text: $draft.title, placeholder: "例如：导出 PDF 时第二页是空白的", limit: FeedbackDraft.titleLimit, focused: focus == "title")
                    .focused($focus, equals: "title")
            }
            row("详细描述") { detail }
            row("大概什么时候遇到的", optional: true) {
                FeedbackSelect(value: draft.occurred?.label, placeholder: "刚刚 / 今天 / 更早",
                               options: FeedbackDraft.Occurred.allCases.map { ($0.rawValue, $0.label) }) { draft.occurred = FeedbackDraft.Occurred(rawValue: $0) }
            }
            if !signedIn {
                row("联系方式", optional: true) {
                    FeedbackInput(text: $draft.contact, placeholder: "邮箱或微信号，方便我们追问；不填也能提交", limit: FeedbackDraft.contactLimit, focused: focus == "contact")
                        .focused($focus, equals: "contact")
                }
            }
            if let error {
                Text(error).font(V3.sans(13)).foregroundStyle(Color(hex: 0xA13A28)).padding(.top, -12).accessibilityAddTraits(.isStaticText)
            }
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Text(FeedbackDraft.footnote(signedIn: signedIn, nickname: user.map { $0.nickname.isEmpty ? ($0.email ?? "") : $0.nickname } ?? ""))
                    if !signedIn { Button("登录后提交", action: login).buttonStyle(.plain).foregroundStyle(V3.blue).pointingHandCursor() }
                }.font(V3.sans(12)).foregroundStyle(fbHint)
                Spacer()
                Button(busy ? "提交中…" : "提交") { Task { await submit() } }
                    .buttonStyle(AccountPillButtonStyle(kind: .dark, width: 72, height: 35)).disabled(!draft.ready || busy)
            }
        }
        .onAppear { installPaste() }
        .onDisappear { if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }; pasteMonitor = nil }
    }

    private func row<Content: View>(_ label: String, optional: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(label).font(V3.sans(13, weight: .medium)).foregroundStyle(fbInk)
                if optional { Text("（选填）").font(V3.sans(12)).foregroundStyle(fbHint) }
            }.frame(height: 16)
            content()
        }
    }

    /// `.fb-field`：220 高起的描边框，上面多行输入、下面截图条（缩略图、「添加截图」、提示）。
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $draft.content)
                .font(V3.sans(14)).foregroundStyle(fbInk).lineSpacing(7).scrollContentBackground(.hidden)
                .focused($focus, equals: "content")
                .frame(minHeight: 120, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    if draft.content.isEmpty {
                        Text(draft.placeholder).font(V3.sans(14)).foregroundStyle(fbHint).lineSpacing(7)
                            .padding(.leading, 5).allowsHitTesting(false)
                    }
                }
                .onChange(of: draft.content) { if draft.content.count > FeedbackDraft.contentLimit { draft.content = String(draft.content.prefix(FeedbackDraft.contentLimit)) } }
                .accessibilityLabel("详细描述")
            HStack(spacing: 8) {
                ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                    Image(nsImage: shot.image).resizable().scaledToFill().frame(width: 44, height: 44)
                        .background(Color(hex: 0xECEAE4)).clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(alignment: .topTrailing) {
                            Button { shots.removeAll { $0.id == shot.id } } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(.white)
                                    .frame(width: 16, height: 16).background(Color(hex: 0x1B1B19), in: Circle())
                            }.buttonStyle(.plain).padding(2).accessibilityLabel("删除截图 \(index + 1)")
                        }
                        .accessibilityLabel("截图 \(index + 1)")
                }
                if shots.count < FeedbackDraft.maxShots {
                    Button(action: pickShots) {
                        HStack(spacing: 6) { Image(systemName: "photo").font(.system(size: 12)); Text("添加截图") }
                            .font(V3.sans(12)).padding(.leading, 10).padding(.trailing, 12).frame(height: 29)
                            .contentShape(Capsule())
                    }.buttonStyle(FeedbackChipStyle())
                }
                Text("也可以直接粘贴，最多 3 张").font(V3.sans(12)).foregroundStyle(fbHint)
            }
        }
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(focus == "content" ? fbFocus : fbLine))
    }

    private func pickShots() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .gif, .heic, .tiff]
        guard panel.runModal() == .OK else { return }
        add(panel.urls.compactMap(FeedbackShot.init(file:)))
    }

    private func add(_ items: [FeedbackShot]) {
        let room = FeedbackDraft.maxShots - shots.count
        guard room > 0 else { return }
        if items.isEmpty { error = "截图读取失败，换一张试试"; return }
        shots += items.prefix(room)
    }

    /// 剪贴板里是图片（截屏或拷贝的图片文件）时，⌘V 直接加成截图；有文字时照常粘贴文字。
    private func installPaste() {
        guard pasteMonitor == nil else { return }
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, event.charactersIgnoringModifiers == "v" else { return event }
            let board = NSPasteboard.general
            if board.string(forType: .string) != nil, board.availableType(from: [.fileURL]) == nil { return event }
            let found = FeedbackShot.fromPasteboard(board)
            guard !found.isEmpty else { return event }
            add(found)
            return nil
        }
    }

    private func submit() async {
        guard draft.ready, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        var payload = draft
        payload.shots = shots.map(\.url)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let body = payload.body(signedIn: signedIn, clientVersion: "mac-\(version)")
        do {
            if signedIn {
                _ = try await session.api.careerRequest(path: "/api/feedback", method: "POST", query: [:], body: body)
            } else {
                guard let api = session.api as? HTTPAPIClient else { throw APIError.invalidResponse }
                _ = try await api.coordinator.anonymousRequest(path: "/api/feedback", method: "POST", body: body)
            }
            sent()
        } catch {
            self.error = FeedbackDraft.errorText(error)
        }
    }
}

/// 一张待发的截图：data URL 与缩略图。超过 4.5 MB 或不是 PNG/JPEG/WebP/GIF 的先缩成不超过 2000 px 的 JPEG（Web `screenshotUrl`）。
struct FeedbackShot: Identifiable {
    let id = UUID()
    let url: String
    let image: NSImage

    init?(file: URL) {
        guard let data = try? Data(contentsOf: file), let image = NSImage(data: data) else { return nil }
        let mime: String? = switch file.pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "webp": "image/webp"
        case "gif": "image/gif"
        default: nil
        }
        self.init(data: data, mime: mime, image: image)
    }

    init?(data: Data, mime: String?, image: NSImage) {
        if let mime, data.count <= FeedbackDraft.maxShotBytes {
            url = "data:\(mime);base64," + data.base64EncodedString()
        } else {
            guard let jpeg = Self.jpeg(image) else { return nil }
            url = "data:image/jpeg;base64," + jpeg.base64EncodedString()
        }
        self.image = image
    }

    static func fromPasteboard(_ board: NSPasteboard) -> [FeedbackShot] {
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.compactMap(FeedbackShot.init(file:))
        }
        if let png = board.data(forType: .png), let image = NSImage(data: png) {
            return FeedbackShot(data: png, mime: "image/png", image: image).map { [$0] } ?? []
        }
        guard let image = NSImage(pasteboard: board), let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return [] }
        return FeedbackShot(data: png, mime: "image/png", image: image).map { [$0] } ?? []
    }

    private static func jpeg(_ image: NSImage) -> Data? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 2000 / CGFloat(max(source.width, source.height)))
        let width = max(1, Int(CGFloat(source.width) * scale)), height = max(1, Int(CGFloat(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(.white); context.fill(rect)
        context.interpolationQuality = .high
        context.draw(source, in: rect)
        guard let output = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: output).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}

/// 反馈类型（`.fb-row .v3-seg`）：浅灰槽 #F3F2EE、内边 3；30 高的项，选中白底 1px 浅描边、墨色中粗字。
private struct FeedbackKindPicker: View {
    @Binding var selection: FeedbackDraft.Kind
    var body: some View {
        HStack(spacing: 2) {
            ForEach(FeedbackDraft.Kind.allCases, id: \.self) { kind in
                let on = kind == selection
                Button { selection = kind } label: {
                    Text(kind.label).font(V3.sans(13, weight: on ? .medium : .regular)).foregroundStyle(on ? Color(hex: 0x1B1B19) : Color(hex: 0x5F5F5A))
                        .padding(.horizontal, 18).frame(height: 30)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 8).fill(.white).overlay(RoundedRectangle(cornerRadius: 8).stroke(V3.cl)) }
                        }
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.padding(3).background(Color(hex: 0xF3F2EE), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .contain).accessibilityLabel("反馈类型")
    }
}

/// `.fb-select`：300×41、圆角 10、浅描边，右侧细尖角；没选时灰字占位。
private struct FeedbackSelect: View {
    let value: String?
    let placeholder: String
    let options: [(String, String)]
    let pick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in Button(option.1) { pick(option.0) } }
        } label: {
            HStack {
                Text(value ?? placeholder).font(V3.sans(14)).foregroundStyle(value == nil ? fbHint : fbInk)
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .medium)).foregroundStyle(V3.fnt)
            }.padding(.horizontal, 14).frame(width: 300, height: 41)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(fbLine))
                .contentShape(Rectangle())
        }.menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(value.map { "\(placeholder)：\($0)" } ?? placeholder)
    }
}

/// `.fb-input`：整行宽、41 高、圆角 10，聚焦时描边加深。
private struct FeedbackInput: View {
    @Binding var text: String
    let placeholder: String
    let limit: Int
    let focused: Bool
    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(fbHint))
            .textFieldStyle(.plain).font(V3.sans(14)).foregroundStyle(fbInk)
            .padding(.horizontal, 14).frame(height: 41)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? fbFocus : fbLine))
            .onChange(of: text) { if text.count > limit { text = String(text.prefix(limit)) } }
    }
}

private struct FeedbackChipStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hover ? V3.txt : Color(hex: 0x5F5F5A))
            .background(.white, in: Capsule()).overlay(Capsule().stroke(hover ? fbFocus : Color(hex: 0xECECE8)))
            .onHover { hover = $0 }
    }
}

private struct FeedbackBackStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.foregroundStyle(hover || configuration.isPressed ? V3.txt : Color(hex: 0x73736E)).onHover { hover = $0 }
    }
}

// MARK: 交流群

/// 右上交流群（`.fb-community`）：192 白底圆角二维码（中间盖品牌花），「也可以进群说」与说明，两个群都有时 QQ / 微信切换；
/// 接口读不到或两个链接都没设时整块不显示。
private struct FeedbackCommunity: View {
    @Environment(SessionStore.self) private var session
    @State private var groups: CommunityGroups?
    @State private var pick = "qq"

    private var account: String { if case .signedIn(let user) = session.phase { return user.id }; return "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let groups, let current = groups.current(pick) {
                VStack(alignment: .leading, spacing: 16) {
                    CommunityQRCode(link: current.link, size: 192)
                        .accessibilityLabel(current.key == "qq" ? "QQ 交流群二维码" : "微信交流群二维码")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("也可以进群说").font(V3.sans(15, weight: .medium)).foregroundStyle(Color(hex: 0x1B1B19))
                        Text("群里回复更快，新功能先在群里说").font(V3.sans(12)).foregroundStyle(fbHint).padding(.bottom, 4)
                        if groups.both {
                            HStack(spacing: 6) {
                                tab("qq", "QQ 群", on: current.key == "qq")
                                tab("wechat", "微信群", on: current.key == "wechat")
                            }
                        } else {
                            Text(current.key == "qq" ? "QQ 扫码进群" : "微信扫码进群").font(V3.sans(12)).foregroundStyle(fbHint)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 1, minHeight: 1, alignment: .topLeading)
        .task(id: account) { await load() }
    }

    private func tab(_ key: String, _ title: String, on: Bool) -> some View {
        Button { pick = key } label: {
            HStack(spacing: 6) {
                SVGFillShape(paths: key == "qq" ? CommunityIcon.qq : CommunityIcon.wechat, box: 14).frame(width: 14, height: 14).opacity(on ? 1 : 0.45)
                Text(title).font(V3.sans(12, weight: on ? .medium : .regular))
            }.foregroundStyle(on ? Color(hex: 0x1B1B19) : fbHint).padding(.leading, 10).padding(.trailing, 12).frame(height: 29)
                .background { if on { Capsule().fill(.white).overlay(Capsule().stroke(Color(hex: 0xECECE8))) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    private func load() async {
        do {
            let json: JSONValue
            if !account.isEmpty {
                json = try await session.api.careerRequest(path: "/api/community-groups", method: "GET", query: [:], body: nil)
            } else {
                guard let api = session.api as? HTTPAPIClient else { return }
                json = try await api.coordinator.anonymousRequest(path: "/api/community-groups", method: "GET", body: nil)
            }
            let value = CommunityGroups(json: json)
            groups = value.isEmpty ? nil : value
            if value.qq == nil, value.wechat != nil { pick = "wechat" }
        } catch {}
    }
}

/// 群邀请链接画成二维码（纠错 H，中间盖品牌花不影响识别），与 Web `CommunityQr` 一致。
private struct CommunityQRCode: View {
    let link: String
    let size: CGFloat
    var body: some View {
        ZStack {
            if let image = Self.render(link) {
                Image(nsImage: image).interpolation(.none).resizable().frame(width: size - 16, height: size - 16)
                RoundedRectangle(cornerRadius: size * 0.21 * 0.23).fill(.white).frame(width: size * 0.21, height: size * 0.21)
                    .overlay { AssistantBrandMark(size: size * 0.21 * 0.8) }
            }
        }
        .frame(width: size, height: size)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(hex: 0xECECE8)))
    }

    static func render(_ link: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        filter.correctionLevel = "H"
        let tint = CIFilter.falseColor()
        tint.inputImage = filter.outputImage
        tint.color0 = CIColor(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1B / 255)
        tint.color1 = CIColor(red: 1, green: 1, blue: 1)
        guard let output = tint.outputImage, let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

/// QQ、微信图标（Web `feedback-qq.svg` / `feedback-wechat.svg`，14 画板）。
private enum CommunityIcon {
    static let qq = ["M12.4804 8.77042C12.3375 8.3256 12.1813 7.88518 12.012 7.44975L11.3826 5.87767C11.3832 5.859 11.3908 5.54983 11.3908 5.39C11.3902 2.702 10.1214 0 7 0C3.87858 0 2.60983 2.702 2.60983 5.39058C2.60983 5.55042 2.61742 5.85958 2.618 5.87825L1.988 7.45033C1.81853 7.88565 1.66252 8.32608 1.52017 8.771C0.924584 10.6861 1.11767 11.4794 1.26467 11.4969C1.57967 11.5348 2.49142 10.0549 2.49142 10.0549C2.49142 10.9118 2.93242 12.0307 3.88792 12.838C3.53092 12.9477 3.09283 13.1174 2.81167 13.3251C2.5585 13.5118 2.59058 13.7019 2.63608 13.7789C2.83617 14.1161 6.06783 13.9942 7.00058 13.8892C7.93392 13.9942 11.1656 14.1161 11.3657 13.7789C11.4112 13.7019 11.4427 13.5118 11.1901 13.3251C10.9083 13.1174 10.4708 12.9483 10.1132 12.8374C11.0682 12.0301 11.5092 10.9113 11.5092 10.0543C11.5092 10.0543 12.4209 11.5342 12.7359 11.4963C12.8823 11.4788 13.0748 10.6855 12.4804 8.77042Z"]
    static let wechat = [
        "M5.425 1.4C2.74167 1.4 0.583334 3.15 0.583334 5.30833C0.583334 6.53333 1.28333 7.64167 2.33333 8.34167L1.925 9.625L3.44167 8.80833C4.025 8.98333 4.66667 9.1 5.30833 9.1H5.775C5.65833 8.80833 5.6 8.51667 5.6 8.16667C5.6 6.06667 7.58333 4.43333 10.0333 4.43333H10.2667C9.85833 2.68333 7.875 1.4 5.425 1.4ZM3.85 3.675C4.02018 3.675 4.18339 3.7426 4.30373 3.86294C4.42406 3.98328 4.49167 4.14649 4.49167 4.31667C4.49167 4.48685 4.42406 4.65006 4.30373 4.77039C4.18339 4.89073 4.02018 4.95833 3.85 4.95833C3.67982 4.95833 3.51661 4.89073 3.39627 4.77039C3.27594 4.65006 3.20833 4.48685 3.20833 4.31667C3.20833 4.14649 3.27594 3.98328 3.39627 3.86294C3.51661 3.7426 3.67982 3.675 3.85 3.675ZM7.11667 3.675C7.28685 3.675 7.45006 3.7426 7.57039 3.86294C7.69073 3.98328 7.75833 4.14649 7.75833 4.31667C7.75833 4.48685 7.69073 4.65006 7.57039 4.77039C7.45006 4.89073 7.28685 4.95833 7.11667 4.95833C6.94649 4.95833 6.78328 4.89073 6.66294 4.77039C6.5426 4.65006 6.475 4.48685 6.475 4.31667C6.475 4.14649 6.5426 3.98328 6.66294 3.86294C6.78328 3.7426 6.94649 3.675 7.11667 3.675Z",
        "M13.4167 8.34167C13.4167 6.475 11.6083 5.01667 9.45 5.01667C7.29167 5.01667 5.48333 6.475 5.48333 8.34167C5.48333 10.2083 7.29167 11.6667 9.45 11.6667C9.91667 11.6667 10.3833 11.6083 10.7917 11.4917L12.0167 12.1917L11.6667 11.0833C12.7167 10.4417 13.4167 9.45 13.4167 8.34167ZM8.16667 7.23333C8.30591 7.23333 8.43944 7.28865 8.5379 7.3871C8.63635 7.48556 8.69167 7.61909 8.69167 7.75833C8.69167 7.89757 8.63635 8.03111 8.5379 8.12956C8.43944 8.22802 8.30591 8.28333 8.16667 8.28333C8.02743 8.28333 7.89389 8.22802 7.79544 8.12956C7.69698 8.03111 7.64167 7.89757 7.64167 7.75833C7.64167 7.61909 7.69698 7.48556 7.79544 7.3871C7.89389 7.28865 8.02743 7.23333 8.16667 7.23333ZM10.7917 7.23333C10.9309 7.23333 11.0644 7.28865 11.1629 7.3871C11.2614 7.48556 11.3167 7.61909 11.3167 7.75833C11.3167 7.89757 11.2614 8.03111 11.1629 8.12956C11.0644 8.22802 10.9309 8.28333 10.7917 8.28333C10.6524 8.28333 10.5189 8.22802 10.4204 8.12956C10.322 8.03111 10.2667 7.89757 10.2667 7.75833C10.2667 7.61909 10.322 7.48556 10.4204 7.3871C10.5189 7.28865 10.6524 7.23333 10.7917 7.23333Z",
    ]
}

/// 按画板实心填充一组 SVG 路径（奇偶规则），颜色取前景色。
private struct SVGFillShape: View {
    let paths: [String]
    let box: CGFloat
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for d in paths { path.addPath(SVGPath.parse(d)) }
            let scale = min(size.width, size.height) / box
            context.fill(path.applying(CGAffineTransform(scaleX: scale, y: scale)), with: .foreground, style: FillStyle(eoFill: true))
        }
    }
}

// MARK: 提交成功

/// 10.05：44 墨黑圆勾、20 号「已收到，谢谢你的反馈」、14 灰说明，下面「再反馈一条」（白底描边）与墨黑「返回」两个胶囊。
private struct FeedbackSent: View {
    let signedIn: Bool
    let again: () -> Void
    let back: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark").font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 44, height: 44).background(fbInk, in: Circle())
            Text("已收到，谢谢你的反馈").font(V3.sans(20, weight: .medium)).foregroundStyle(fbInk)
            Text(signedIn ? "确认有效后会在站内通知告诉你，并送你积分。" : "我们会尽快查看。").font(V3.sans(14)).foregroundStyle(Color(hex: 0x73736E))
                .padding(.bottom, 8)
            HStack(spacing: 12) {
                Button("再反馈一条", action: again).buttonStyle(AccountPillButtonStyle(kind: .ghost, height: 35))
                Button("返回", action: back).buttonStyle(AccountPillButtonStyle(kind: .dark, width: 72, height: 35)).keyboardShortcut(.defaultAction)
            }
        }.accessibilityElement(children: .contain)
    }
}
