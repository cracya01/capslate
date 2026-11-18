import AppKit
import SwiftUI
import Combine

// MARK: - Model

@MainActor
final class ResultItem: ObservableObject, Identifiable {
    let id: String
    let name: String
    @Published var text = ""
    @Published var error = ""
    @Published var busy = false

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

@MainActor
final class TranslateModel: ObservableObject {
    @Published var source = ""
    @Published var results: [ResultItem] = []
    @Published var status = ""
    @Published var isError = false
    @Published var target = ""
    @Published var pinned = false
    @Published var busy = false

    private var task: Task<Void, Never>?
    private var subs: Set<AnyCancellable> = []

    init() {
        let s = AppSettings.shared
        // Re-translate when the language selection changes (sink fires before the value is stored).
        s.$sourceLang.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retranslateIfNeeded() }.store(in: &subs)
        s.$targetLang.dropFirst().removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.retranslateIfNeeded() }.store(in: &subs)
    }

    func reset() {
        task?.cancel()
        source = ""
        results = []
        target = ""
        busy = false
        setStatus("")
    }

    func setStatus(_ s: String, error: Bool = false) {
        status = s
        isError = error
    }

    private func retranslateIfNeeded() {
        if !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { translate() }
    }

    func swapLangs() {
        let s = AppSettings.shared
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let newSource = s.targetLang == Lang.autoTarget ? Lang.autoSource : s.targetLang
        let newTarget: String
        if s.sourceLang == Lang.autoSource {
            newTarget = text.isEmpty ? Lang.autoTarget : (Lang.detect(text) ?? Lang.autoTarget)
        } else {
            newTarget = s.sourceLang
        }
        s.sourceLang = newSource
        s.targetLang = newTarget
    }

    func translate() {
        task?.cancel()
        let s = AppSettings.shared
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setStatus("没有要翻译的文字", error: true); return }
        let providers = s.providers.filter { $0.enabled }
        guard !providers.isEmpty else { setStatus("没有启用的翻译源：设置 → 翻译源", error: true); return }

        let src = s.sourceLang
        let tgt = s.targetLang == Lang.autoTarget ? Lang.autoTarget(for: text) : s.targetLang
        target = tgt
        let items = providers.map { ResultItem(id: $0.id, name: $0.name) }
        results = items
        busy = true
        setStatus("")

        let jobs = zip(providers, items).map { (p, item) in (p, Keychain.read(p.keyAccount) ?? "", item) }
        task = Task { @MainActor [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for (p, key, item) in jobs {
                    group.addTask {
                        await TranslateModel.runOne(p, key: key, item: item, text: text, source: src, target: tgt)
                    }
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.busy = false
            let done = items.filter { !$0.text.isEmpty }
            if !done.isEmpty {
                History.shared.add(HistoryEntry(date: Date(), source: text, target: tgt,
                                                results: done.map { HistoryResult(name: $0.name, text: $0.text) }))
            }
        }
    }

    private static func runOne(_ p: Provider, key: String, item: ResultItem,
                               text: String, source: String, target: String) async {
        item.busy = true
        do {
            try await Engines.run(p, key: key, text: text, source: source, target: target) { piece in
                item.text += piece
            }
            if item.text.isEmpty { item.error = "没有返回译文" }
        } catch {
            if !Task.isCancelled && (error as? URLError)?.code != .cancelled && !(error is CancellationError) {
                item.error = error.localizedDescription
            }
        }
        item.busy = false
    }
}

// MARK: - Views (Control Center–style glass tiles)

enum CC {
    /// Concentric with the tiles: tile radius + padding (+ the glass view's own inset).
    static let panelRadius: CGFloat = 38
    static let tileRadius: CGFloat = 22
    static let pad: CGFloat = 14
    static let gap: CGFloat = 10
    static let control: CGFloat = 34
}

/// Round glass button; `on` renders the white "enabled" look from Control Center.
struct GlassCircleButton: View {
    let symbol: String
    let help: String
    var on = false
    var size: CGFloat = CC.control
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(on ? Color.black : Color.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.white).interactive() : .regular.interactive(), in: Circle())
        .help(help)
    }
}

/// Small text pill (驼峰 / 蛇形).
struct GlassPill: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .help(help)
    }
}

/// Language chip with a dropdown menu.
struct LangMenu: View {
    @Binding var selection: String
    let options: [String]

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(o, systemImage: "checkmark") } else { Text(o) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(selection).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .frame(height: CC.control)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: Capsule())
    }
}

/// A Control Center tile: rounded glass rectangle.
struct Tile<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CC.tileRadius, style: .continuous))
    }
}

struct ResultCard: View {
    @ObservedObject var item: ResultItem
    let fontSize: Double
    let target: String
    @State private var copied = false

    private var tint: Color {
        let palette: [Color] = [.blue, .purple, .teal, .orange, .pink, .green, .indigo]
        let h = item.name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return palette[h % palette.count]
    }

    var body: some View {
        Tile {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    // Colored round icon, like Wi‑Fi / Bluetooth in Control Center.
                    ZStack {
                        Circle().fill(tint)
                        Text(String(item.name.prefix(1)))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 13, weight: .semibold))
                        Text(item.busy ? "翻译中…" : (item.error.isEmpty ? target : "失败"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !item.text.isEmpty {
                        if TextCase.isEnglish(item.text) {
                            GlassPill(title: "驼峰", help: "复制为 helloWorld 形式") { copyToPasteboard(TextCase.camel(item.text)) }
                            GlassPill(title: "蛇形", help: "复制为 hello_world 形式") { copyToPasteboard(TextCase.snake(item.text)) }
                        }
                        GlassCircleButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "复制译文",
                                          on: copied, size: 28) {
                            copyToPasteboard(item.text)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                        }
                    }
                }

                if !item.error.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(item.error)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                } else if item.text.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().fill(Color.primary.opacity(0.1)).frame(height: 8)
                        Capsule().fill(Color.primary.opacity(0.1)).frame(width: 150, height: 8)
                    }
                    .padding(.vertical, 3)
                } else {
                    Text(item.text)
                        .font(.system(size: fontSize + 1))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct TranslateView: View {
    @ObservedObject var m: TranslateModel
    @ObservedObject var s: AppSettings
    let actions: TranslateWindow.Actions
    @FocusState private var inputFocused: Bool
    @State private var headH: CGFloat = 0
    @State private var contentH: CGFloat = 0

    var body: some View {
        VStack(spacing: CC.gap) {
            VStack(spacing: CC.gap) {
                toolbar
                sourceTile
                langBar
                if !m.status.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: m.isError ? "exclamationmark.circle.fill" : "info.circle")
                        Text(m.status)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(m.isError ? Color.red : Color.secondary)
                    .padding(.horizontal, 6)
                }
            }
            .background(SizeReporter { headH = $0.height; fitWindow() })

            results
        }
        .padding(CC.pad)
        .frame(minWidth: 420, minHeight: 300, alignment: .top)
        .ignoresSafeArea()
        .background(
            Button("") { actions.close() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 8) {
            GlassCircleButton(symbol: m.pinned ? "pin.fill" : "pin",
                              help: m.pinned ? "取消钉住" : "钉住窗口（点别处不隐藏）", on: m.pinned) { m.pinned.toggle() }
            GlassCircleButton(symbol: "doc.on.clipboard",
                              help: s.clipboardWatch ? "关闭剪贴板监听" : "开启剪贴板监听（复制即翻译）",
                              on: s.clipboardWatch) { s.clipboardWatch.toggle() }
            GlassCircleButton(symbol: "photo", help: "识别剪贴板里的图片并翻译") { actions.pasteImage() }
            Spacer()
            GlassCircleButton(symbol: "clock.arrow.circlepath", help: "翻译记录") { actions.openHistory() }
            GlassCircleButton(symbol: "gearshape", help: "设置") { actions.openSettings() }
            GlassCircleButton(symbol: "xmark", help: "关闭（Esc）") { actions.close() }
        }
    }

    // MARK: Source

    private var sourceTile: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("原文").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !m.source.isEmpty {
                    Text("\(m.source.count) 字")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            ZStack(alignment: .topLeading) {
                if m.source.isEmpty {
                    Text("输入或粘贴要翻译的文字…")
                        .font(.system(size: s.fontSize))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $m.source)
                    .font(.system(size: s.fontSize))
                    .lineSpacing(2)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($inputFocused)
            }
            .padding(.horizontal, 11)

            HStack(spacing: 6) {
                Spacer()
                if !m.source.isEmpty {
                    GlassCircleButton(symbol: "xmark", help: "清空", size: 26) { m.reset(); inputFocused = true }
                    GlassCircleButton(symbol: "doc.on.doc", help: "复制原文", size: 26) { copyToPasteboard(m.source) }
                }
            }
            .frame(height: 26)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(minHeight: m.results.isEmpty ? 110 : 170, maxHeight: m.results.isEmpty ? .infinity : 170)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: CC.tileRadius, style: .continuous))
    }

    // MARK: Languages

    private var langBar: some View {
        HStack(spacing: 8) {
            LangMenu(selection: $s.sourceLang, options: [Lang.autoSource] + Lang.all)
            GlassCircleButton(symbol: "arrow.left.arrow.right", help: "互换语言") { m.swapLangs() }
            LangMenu(selection: $s.targetLang, options: [Lang.autoTarget] + Lang.all)
            Button { m.translate() } label: {
                HStack(spacing: 5) {
                    if m.busy {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                            .tint(.white)
                    } else {
                        Image(systemName: "sparkles").font(.system(size: 12, weight: .semibold))
                    }
                    Text("翻译")
                    Text("⌘↩").font(.system(size: 10.5)).opacity(0.8)
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(height: CC.control)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
            .keyboardShortcut(.return, modifiers: .command)
            .fixedSize()
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if m.results.isEmpty {
            Text("⌘↩ 翻译 · Esc 关闭")
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        } else {
            ScrollView {
                VStack(spacing: CC.gap) {
                    ForEach(m.results) { ResultCard(item: $0, fontSize: s.fontSize, target: m.target) }
                }
                .background(SizeReporter { contentH = $0.height; fitWindow() })
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .frame(minHeight: 60)
        }
    }

    /// Size the window to fit: padding + top part + gap + result cards + padding.
    /// Only sizes are measured (not positions), and neither depends on the window height,
    /// so resizing can't feed back into the next measurement.
    private func fitWindow() {
        guard !m.results.isEmpty, headH > 0, contentH > 0 else { return }
        let target = (CC.pad + headH + CC.gap + contentH + CC.pad).rounded()
        // Resize outside the current layout pass, otherwise AppKit drops the frame change.
        DispatchQueue.main.async { actions.fitHeight(target) }
    }
}

/// Reports this view's size whenever it changes.
private struct SizeReporter: View {
    let onChange: (CGSize) -> Void
    var body: some View {
        GeometryReader { g in
            Color.clear
                .onAppear { onChange(g.size) }
                .onChange(of: g.size) { _, new in onChange(new) }
        }
    }
}

// MARK: - Window

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class TranslateWindow: NSObject, NSWindowDelegate {
    struct Actions {
        var pasteImage: () -> Void
        var openHistory: () -> Void
        var openSettings: () -> Void
        var close: () -> Void
        var fitHeight: (CGFloat) -> Void = { _ in }
    }

    let model = TranslateModel()
    var onPasteImage: () -> Void = {}
    var onOpenHistory: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    private weak var glassView: NSGlassEffectView?

    private lazy var panel: KeyPanel = {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.borderless, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        p.title = "翻译"
        p.isOpaque = false
        p.backgroundColor = .clear
        // The content is clipped to a rounded rect (see below), so the window shadow follows that shape.
        p.hasShadow = true
        p.isMovableByWindowBackground = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = self
        let actions = Actions(
            pasteImage: { [weak self] in self?.onPasteImage() },
            openHistory: { [weak self] in self?.onOpenHistory() },
            openSettings: { [weak self] in self?.onOpenSettings() },
            close: { [weak self] in self?.panel.close() },
            fitHeight: { [weak self] h in self?.setHeight(h) }
        )
        let host = NSHostingView(rootView: TranslateView(m: model, s: AppSettings.shared, actions: actions))
        // Only enforce the minimum size; the window height is driven by setHeight(_:).
        host.sizingOptions = [.minSize]
        // Native Liquid Glass panel (like Control Center): the system draws the rim, highlight and corners.
        let glass = NSGlassEffectView()
        glass.cornerRadius = CC.panelRadius
        glass.contentView = host
        glass.frame = NSRect(x: 0, y: 0, width: 520, height: 480)
        glass.autoresizingMask = [.width, .height]
        glassView = glass
        // Clip everything to the rounded shape: no square corners, and the window
        // shadow (computed from content alpha) follows the rounded outline.
        let container = NSView(frame: glass.frame)
        container.wantsLayer = true
        container.layer?.cornerRadius = CC.panelRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.addSubview(glass)
        p.contentView = container
        p.center()
        p.setFrameAutosaveName("TranslateWindow")
        return p
    }()

    /// Set the window height, keeping the top edge fixed and staying above the screen bottom.
    private func setHeight(_ target: CGFloat) {
        guard let vf = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        var f = panel.frame
        let top = f.maxY
        // `target` is the SwiftUI view's height; the glass view insets its content a little,
        // so add whatever the window has beyond the hosting view.
        let chrome = glassView.flatMap { glass in
            glass.contentView.map { glass.bounds.height - $0.frame.height }
        } ?? 0
        var h = max(target + max(chrome, 0), panel.minSize.height)
        h = min(h, top - vf.minY - 8)
        if abs(h - f.height) < 1 { return }
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    /// - activate: false shows the window without taking focus (clipboard watch).
    func show(focusInput: Bool = false, activate: Bool = true) {
        let wasVisible = panel.isVisible
        if !wasVisible && AppSettings.shared.windowPosition == "mouse" { placeNearMouse() }
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        if focusInput, let tv = findTextView(in: panel.contentView) {
            panel.makeFirstResponder(tv)
        }
    }

    private func placeNearMouse() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let size = panel.frame.size
        var x = mouse.x + 12
        var y = mouse.y - size.height - 12
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func windowDidResignKey(_ notification: Notification) {
        if !model.pinned { panel.orderOut(nil) }
    }

    private func findTextView(in v: NSView?) -> NSTextView? {
        guard let v else { return nil }
        if let tv = v as? NSTextView, tv.isEditable { return tv }
        for s in v.subviews { if let f = findTextView(in: s) { return f } }
        return nil
    }
}
