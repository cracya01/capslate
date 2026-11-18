import AppKit
import Combine
import ApplicationServices

// App entry, menu bar item, hotkey / clipboard wiring.

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let tw = TranslateWindow()
    private let settingsWindow = SettingsWindow()
    private let settings = AppSettings.shared
    private var subs: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()
        OCR.warmUp()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "翻译")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        tw.onPasteImage = { [weak self] in self?.pasteImage() }
        tw.onOpenHistory = { [weak self] in self?.settingsWindow.show(tab: "history") }
        tw.onOpenSettings = { [weak self] in self?.settingsWindow.show() }

        HotKeys.install()
        HotKeys.handler = { [weak self] a in self?.perform(a) }
        registerHotkeys()

        settings.$shortcuts.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotkeys() }.store(in: &subs)
        settings.$hotkeysDisabled.dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.registerHotkeys() }.store(in: &subs)
        settings.$clipboardWatch.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyClipboardWatch() }.store(in: &subs)
        settings.$theme.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyTheme() }.store(in: &subs)

        NotificationCenter.default.addObserver(forName: .recorderBegan, object: nil, queue: .main) { _ in
            Task { @MainActor in HotKeys.unregisterAll() }
        }
        NotificationCenter.default.addObserver(forName: .recorderEnded, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.registerHotkeys() }
        }

        ClipboardWatcher.shared.onText = { [weak self] text in
            guard let self else { return }
            self.tw.model.reset()
            self.tw.model.source = text
            self.tw.show(activate: false)
            self.tw.model.translate()
        }

        // First run: no key for any provider that needs one → open the sources tab.
        // Reading every key once also finishes the one-time keychain → preferences migration up front.
        let keys = settings.providers.map { Keychain.read($0.keyAccount) ?? "" }
        let hasKey = zip(settings.providers, keys).contains { !$0.needsKey || !$1.isEmpty }
        if !hasKey { settingsWindow.show(tab: "providers") }
    }

    // MARK: Settings side effects

    private func registerHotkeys() {
        if settings.hotkeysDisabled {
            HotKeys.unregisterAll()
            settingsWindow.ui.hotkeyFailures = []
            return
        }
        let failed = HotKeys.registerAll(settings.shortcuts)
        settingsWindow.ui.hotkeyFailures = failed
    }

    private func applyClipboardWatch() {
        if settings.clipboardWatch { ClipboardWatcher.shared.start() } else { ClipboardWatcher.shared.stop() }
    }

    private func applyTheme() {
        switch settings.theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    // MARK: Menus

    /// Menu-bar-only apps have no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z do nothing in text fields without this.
    private func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for a in HotAction.allCases {
            var title = a.title
            if let s = settings.shortcuts[a.rawValue], !settings.hotkeysDisabled { title += "    \(s.display)" }
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.representedObject = a.rawValue
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let watch = NSMenuItem(title: "剪贴板监听", action: #selector(toggleClipboard), keyEquivalent: "")
        watch.state = settings.clipboardWatch ? .on : .off
        watch.target = self
        menu.addItem(watch)
        let off = NSMenuItem(title: "停用快捷键", action: #selector(toggleHotkeys), keyEquivalent: "")
        off.state = settings.hotkeysDisabled ? .on : .off
        off.target = self
        menu.addItem(off)
        menu.addItem(.separator())
        let hist = NSMenuItem(title: "翻译记录…", action: #selector(openHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)
        let set = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        set.target = self
        menu.addItem(set)
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = HotAction(rawValue: raw) else { return }
        perform(a)
    }

    @objc private func toggleClipboard() { settings.clipboardWatch.toggle() }
    @objc private func toggleHotkeys() { settings.hotkeysDisabled.toggle() }
    @objc private func openHistory() { settingsWindow.show(tab: "history") }
    @objc private func openSettings() { settingsWindow.show() }

    // MARK: Actions

    private func perform(_ a: HotAction) {
        switch a {
        case .input: inputTranslate()
        case .screenshot: capture(.translate)
        case .selection: selectionTranslate()
        case .ocr: capture(.ocrWindow)
        case .silentOCR: capture(.silent)
        case .pasteImage: pasteImage()
        }
    }

    private func inputTranslate() {
        tw.model.reset()
        tw.model.setStatus("输入文字后按 ⌘↩ 翻译")
        tw.show(focusInput: true)
    }

    private func selectionTranslate() {
        guard AXIsProcessTrusted() else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
            tw.model.reset()
            tw.model.setStatus("划词翻译需要「辅助功能」权限：在系统设置里打开 Translator 的开关，再试一次。", error: true)
            tw.show()
            return
        }
        Selection.get { [weak self] text in
            guard let self else { return }
            self.tw.model.reset()
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.tw.model.setStatus("没取到选中的文字：先选中文字再按划词翻译快捷键", error: true)
                self.tw.show()
                return
            }
            self.tw.model.source = text
            self.tw.show()
            self.tw.model.translate()
        }
    }

    private enum CaptureMode { case translate, ocrWindow, silent }

    private func capture(_ mode: CaptureMode) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            tw.model.reset()
            tw.model.setStatus("截图需要「屏幕录制」权限：在系统设置里打开 Translator 的开关，然后退出并重新打开本软件。", error: true)
            tw.show()
            return
        }
        Task { @MainActor in
            guard let img = await Capture.interactive() else { return } // Esc
            await self.handleImage(img, mode: mode)
        }
    }

    private func pasteImage() {
        guard let img = Capture.imageFromPasteboard() else {
            tw.model.reset()
            tw.model.setStatus("剪贴板里没有图片", error: true)
            tw.show()
            return
        }
        Task { @MainActor in await self.handleImage(img, mode: .translate) }
    }

    private func handleImage(_ img: CGImage, mode: CaptureMode) async {
        if mode != .silent {
            tw.model.reset()
            tw.model.setStatus("识别中…")
            tw.show()
        }
        do {
            let text = try await OCR.recognize(img, mergeLines: settings.mergeLines)
            guard !text.isEmpty else {
                if mode == .silent { flashStatus(ok: false) } else { tw.model.setStatus("没识别出文字", error: true) }
                return
            }
            switch mode {
            case .silent:
                copyToPasteboard(text)
                flashStatus(ok: true)
            case .ocrWindow:
                copyToPasteboard(text)
                tw.model.source = text
                tw.model.setStatus("已识别，文字已复制到剪贴板")
            case .translate:
                tw.model.source = text
                tw.model.setStatus("")
                tw.model.translate()
            }
        } catch {
            if mode == .silent { flashStatus(ok: false) } else { tw.model.setStatus("识别失败：\(error.localizedDescription)", error: true) }
        }
    }

    /// Brief menu bar icon feedback for silent OCR.
    private func flashStatus(ok: Bool) {
        let symbol = ok ? "checkmark.circle.fill" : "xmark.circle"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: ok ? "已复制" : "失败")
        if !ok { NSSound.beep() }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.statusItem.button?.image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "翻译")
        }
    }
}

@main
@MainActor
struct Main {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
