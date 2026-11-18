import AppKit
import SwiftUI
import Carbon
import ServiceManagement
import ApplicationServices

extension Notification.Name {
    static let recorderBegan = Notification.Name("translator.recorderBegan")
    static let recorderEnded = Notification.Name("translator.recorderEnded")
}

// MARK: - Settings UI state

@MainActor
final class SettingsUIModel: ObservableObject {
    @Published var tab = "general"
    @Published var selectedProvider: String?
    @Published var keyDraft = ""
    @Published var keyNote = ""
    @Published var testNote = ""
    @Published var testing = false
    @Published var selectedHistory: String?
    @Published var axOK = false
    @Published var capOK = false
    @Published var loginOK = false
    @Published var loginNote = ""
    @Published var hotkeyFailures: [String] = []

    func refresh() {
        axOK = AXIsProcessTrusted()
        capOK = CGPreflightScreenCaptureAccess()
        loginOK = SMAppService.mainApp.status == .enabled
    }

    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginNote = ""
        } catch {
            loginNote = "设置失败：\(error.localizedDescription)"
        }
        refresh()
    }

    func loadKey() {
        keyNote = ""
        testNote = ""
        guard let id = selectedProvider,
              let p = AppSettings.shared.providers.first(where: { $0.id == id }) else { keyDraft = ""; return }
        keyDraft = Keychain.read(p.keyAccount) ?? ""
    }

    func saveKey() {
        guard let id = selectedProvider,
              let p = AppSettings.shared.providers.first(where: { $0.id == id }) else { return }
        Keychain.save(p.keyAccount, keyDraft.trimmingCharacters(in: .whitespacesAndNewlines))
        keyNote = "密钥已保存"
    }

    func test() {
        guard let id = selectedProvider,
              let p = AppSettings.shared.providers.first(where: { $0.id == id }) else { return }
        let key = Keychain.read(p.keyAccount) ?? ""
        testing = true
        testNote = ""
        Task { @MainActor in
            var out = ""
            do {
                try await Engines.run(p, key: key, text: "Hello, world", source: Lang.autoSource,
                                      target: "中文(简体)") { out += $0 }
                testNote = "✅ 可用：Hello, world → \(out)"
            } catch {
                testNote = "❌ \(error.localizedDescription)"
            }
            testing = false
        }
    }
}

// MARK: - Shortcut recorder

final class RecorderField: NSView {
    var shortcut: Shortcut? { didSet { update() } }
    var onChange: ((Shortcut?) -> Void)?
    private var recording = false { didSet { update() } }
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        label.alignment = .center
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
        ])
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 24) }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }

    override func becomeFirstResponder() -> Bool {
        recording = true
        NotificationCenter.default.post(name: .recorderBegan, object: nil)
        return true
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        NotificationCenter.default.post(name: .recorderEnded, object: nil)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        handle(event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        handle(event)
    }

    private func handle(_ e: NSEvent) {
        let code = Int(e.keyCode)
        if code == kVK_Escape { window?.makeFirstResponder(nil); return }
        if code == kVK_Delete || code == kVK_ForwardDelete {
            shortcut = nil
            onChange?(nil)
            window?.makeFirstResponder(nil)
            return
        }
        let mods = Shortcut.carbonModifiers(e.modifierFlags)
        guard mods & UInt32(cmdKey | optionKey | controlKey) != 0 else {
            label.stringValue = "要包含 ⌘ ⌥ 或 ⌃"
            NSSound.beep()
            return
        }
        let s = Shortcut(keyCode: UInt32(e.keyCode), modifiers: mods)
        shortcut = s
        onChange?(s)
        window?.makeFirstResponder(nil)
    }

    private func update() {
        label.stringValue = recording ? "请按下快捷键…" : (shortcut?.display ?? "未设置")
        label.textColor = shortcut == nil && !recording ? .secondaryLabelColor : .labelColor
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: Shortcut?
    var onChange: (Shortcut?) -> Void

    func makeNSView(context: Context) -> RecorderField {
        let f = RecorderField()
        f.shortcut = shortcut
        f.onChange = onChange
        return f
    }

    func updateNSView(_ v: RecorderField, context: Context) {
        if v.window?.firstResponder !== v { v.shortcut = shortcut }
        v.onChange = onChange
    }
}

// MARK: - Tabs

struct GeneralTab: View {
    @ObservedObject var s: AppSettings
    @ObservedObject var ui: SettingsUIModel

    var body: some View {
        Form {
            Section("外观") {
                Picker("主题", selection: $s.theme) {
                    Text("跟随系统").tag("system")
                    Text("明亮").tag("light")
                    Text("暗黑").tag("dark")
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("翻译窗口字号")
                    Slider(value: $s.fontSize, in: 11...24, step: 1)
                    Text("\(Int(s.fontSize))").monospacedDigit().frame(width: 28)
                }
                Picker("翻译窗口位置", selection: $s.windowPosition) {
                    Text("跟随鼠标").tag("mouse")
                    Text("上次位置").tag("last")
                }
            }
            Section("功能") {
                Toggle("OCR 断行合并（把被拆成多行的同一段文字合回去）", isOn: $s.mergeLines)
                Toggle("剪贴板监听（复制文字后自动翻译）", isOn: $s.clipboardWatch)
                Toggle("开机自动启动", isOn: Binding(get: { ui.loginOK }, set: { ui.setLogin($0) }))
                if !ui.loginNote.isEmpty {
                    Text(ui.loginNote).font(.caption).foregroundStyle(.red)
                }
            }
            Section("权限") {
                permRow(ok: ui.axOK, title: "辅助功能（划词翻译）",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                permRow(ok: ui.capOK, title: "屏幕录制（截图翻译、截图识字）",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                HStack {
                    Text("屏幕录制授权后需要退出再打开本软件").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("刷新") { ui.refresh() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func permRow(ok: Bool, title: String, url: String) -> some View {
        HStack {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 8, height: 8)
            Text(title)
            Text(ok ? "已授权" : "未授权").foregroundStyle(.secondary)
            Spacer()
            Button("打开系统设置") { if let u = URL(string: url) { NSWorkspace.shared.open(u) } }
        }
    }
}

struct ShortcutTab: View {
    @ObservedObject var s: AppSettings
    @ObservedObject var ui: SettingsUIModel

    var body: some View {
        Form {
            Section {
                Toggle("停用所有快捷键", isOn: $s.hotkeysDisabled)
            }
            Section {
                ForEach(HotAction.allCases) { a in
                    HStack {
                        Text(a.title)
                        Spacer()
                        ShortcutRecorder(shortcut: s.shortcuts[a.rawValue]) { s.shortcuts[a.rawValue] = $0 }
                            .frame(width: 160, height: 24)
                        Button {
                            s.shortcuts[a.rawValue] = nil
                        } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.borderless)
                            .help("清除")
                    }
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("点一下右边的框再按组合键；Delete 清除，Esc 取消。必须包含 ⌘、⌥ 或 ⌃。")
                    Text("注意：⌘W、⌘E 这类常用组合设成全局快捷键后，其他软件里就不能再用它们了。")
                    if !ui.hotkeyFailures.isEmpty {
                        Text("注册失败（被其他软件占用）：\(ui.hotkeyFailures.joined(separator: "、"))")
                            .foregroundStyle(.red)
                    }
                    Button("恢复默认快捷键") { s.shortcuts = HotAction.defaults }
                        .padding(.top, 4)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProvidersTab: View {
    @ObservedObject var s: AppSettings
    @ObservedObject var ui: SettingsUIModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                List(selection: $ui.selectedProvider) {
                    ForEach(s.providers) { p in
                        HStack {
                            Toggle("", isOn: field(p.id, \.enabled, false)).labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(p.name)
                                Text(p.kind.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        .tag(p.id)
                    }
                }
                HStack(spacing: 4) {
                    Menu {
                        Button("DeepSeek") { add(.deepseek()) }
                        Button("OpenAI 兼容（OpenAI / Ollama / 其他）") { add(.openaiCompatible()) }
                        Button("谷歌翻译（免费）") { add(.google()) }
                        Button("DeepL") { add(.deepl()) }
                    } label: { Image(systemName: "plus") }
                        .menuStyle(.borderlessButton)
                        .frame(width: 34)
                    Button { remove() } label: { Image(systemName: "minus") }
                        .disabled(ui.selectedProvider == nil)
                    Spacer()
                    Button { move(-1) } label: { Image(systemName: "arrow.up") }.help("上移")
                    Button { move(1) } label: { Image(systemName: "arrow.down") }.help("下移")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(width: 220)

            Divider()

            if let id = ui.selectedProvider, let p = s.providers.first(where: { $0.id == id }) {
                editor(p)
            } else {
                Text("选择左侧的翻译源进行设置").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if ui.selectedProvider == nil { ui.selectedProvider = s.providers.first?.id }
            ui.loadKey()
        }
        .onChange(of: ui.selectedProvider) { _, _ in ui.loadKey() }
    }

    @ViewBuilder
    private func editor(_ p: Provider) -> some View {
        Form {
            Section(p.kind.label) {
                TextField("名称", text: field(p.id, \.name, ""))
                switch p.kind {
                case .openai:
                    TextField("接口地址", text: field(p.id, \.baseURL, ""), prompt: Text("https://api.deepseek.com"))
                    TextField("模型", text: field(p.id, \.model, ""), prompt: Text("deepseek-chat"))
                    keyRow
                case .google:
                    TextField("接口地址", text: field(p.id, \.baseURL, ""), prompt: Text("https://translate.googleapis.com"))
                    Text("免费，不用密钥。这是谷歌网页翻译的非官方接口，可能被限流；需要能访问谷歌的网络。")
                        .font(.caption).foregroundStyle(.secondary)
                case .deepl:
                    keyRow
                    TextField("接口地址", text: field(p.id, \.baseURL, ""), prompt: Text("留空自动：:fx 结尾的免费 key 用 api-free.deepl.com"))
                }
            }
            if p.kind == .openai {
                Section {
                    TextEditor(text: field(p.id, \.prompt, ""))
                        .font(.system(size: 13))
                        .frame(height: 140)
                    HStack {
                        Text("{target_lang} 替换成目标语言，{source_lang} 替换成原文语言")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("恢复默认提示词") {
                            if let i = s.providers.firstIndex(where: { $0.id == p.id }) { s.providers[i].prompt = defaultPrompt }
                        }
                    }
                } header: { Text("翻译提示词") }
            }
            Section {
                HStack {
                    Button(ui.testing ? "测试中…" : "测试") { ui.test() }.disabled(ui.testing)
                    Text(ui.testNote).font(.caption).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var keyRow: some View {
        HStack {
            SecureField("API Key", text: $ui.keyDraft)
            Button("保存密钥") { ui.saveKey() }
            if !ui.keyNote.isEmpty { Text(ui.keyNote).font(.caption).foregroundStyle(.green) }
        }
    }

    private func field<T>(_ id: String, _ kp: WritableKeyPath<Provider, T>, _ fallback: T) -> Binding<T> {
        Binding(
            get: { s.providers.first(where: { $0.id == id })?[keyPath: kp] ?? fallback },
            set: { v in
                if let i = s.providers.firstIndex(where: { $0.id == id }) { s.providers[i][keyPath: kp] = v }
            }
        )
    }

    private func add(_ p: Provider) {
        s.providers.append(p)
        ui.selectedProvider = p.id
    }

    private func remove() {
        guard let id = ui.selectedProvider, let i = s.providers.firstIndex(where: { $0.id == id }) else { return }
        let p = s.providers[i]
        let alert = NSAlert()
        alert.messageText = "删除翻译源「\(p.name)」？"
        alert.informativeText = "它保存的密钥也会一起删除。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Keychain.save(p.keyAccount, "")
        s.providers.remove(at: i)
        ui.selectedProvider = s.providers.first?.id
    }

    private func move(_ delta: Int) {
        guard let id = ui.selectedProvider, let i = s.providers.firstIndex(where: { $0.id == id }) else { return }
        let j = i + delta
        guard j >= 0, j < s.providers.count else { return }
        s.providers.swapAt(i, j)
    }
}

struct HistoryTab: View {
    @ObservedObject var h: History
    @ObservedObject var ui: SettingsUIModel

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 6) {
                List(selection: $ui.selectedHistory) {
                    ForEach(h.entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.source).lineLimit(1)
                            Text("\(HistoryTab.fmt.string(from: e.date)) → \(e.target)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .tag(e.id)
                    }
                }
                HStack {
                    Text("共 \(h.entries.count) 条（最多 \(History.limit)）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") {
                        let a = NSAlert()
                        a.messageText = "清空全部翻译记录？"
                        a.addButton(withTitle: "清空")
                        a.addButton(withTitle: "取消")
                        if a.runModal() == .alertFirstButtonReturn { h.clear(); ui.selectedHistory = nil }
                    }
                    .disabled(h.entries.isEmpty)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .frame(width: 240)

            Divider()

            if let id = ui.selectedHistory, let e = h.entries.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        block(title: "原文", text: e.source)
                        ForEach(e.results, id: \.self) { r in block(title: r.name, text: r.text) }
                        Button("删除这条记录") {
                            h.delete(e.id)
                            ui.selectedHistory = h.entries.first?.id
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(h.entries.isEmpty ? "还没有翻译记录" : "选择左侧的一条记录")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func block(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                Spacer()
                Button { copyToPasteboard(text) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help("复制")
            }
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

struct SettingsView: View {
    @ObservedObject var ui: SettingsUIModel

    var body: some View {
        TabView(selection: $ui.tab) {
            GeneralTab(s: AppSettings.shared, ui: ui)
                .tabItem { Label("通用", systemImage: "gearshape") }.tag("general")
            ShortcutTab(s: AppSettings.shared, ui: ui)
                .tabItem { Label("快捷键", systemImage: "command") }.tag("shortcuts")
            ProvidersTab(s: AppSettings.shared, ui: ui)
                .tabItem { Label("翻译源", systemImage: "globe") }.tag("providers")
            HistoryTab(h: History.shared, ui: ui)
                .tabItem { Label("翻译记录", systemImage: "clock") }.tag("history")
        }
        .padding(12)
        .frame(width: 760, height: 560)
    }
}

@MainActor
final class SettingsWindow {
    let ui = SettingsUIModel()

    private lazy var window: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                         styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
        w.title = "翻译 · 设置"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView(ui: ui))
        w.center()
        return w
    }()

    func show(tab: String? = nil) {
        if let tab { ui.tab = tab }
        ui.refresh()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
