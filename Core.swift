import AppKit
import Carbon
import Combine
import NaturalLanguage
import Security

// MARK: - Errors

struct AppError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

// MARK: - API key storage

/// API keys live in the app's preferences (~/Library/Preferences/com.cracywu.translator.plist),
/// not the keychain: a self-signed app without a Team ID gets a keychain prompt after every rebuild.
/// Keys saved by older versions are copied out of the keychain once per account.
enum Keychain {
    private static let keysKey = "apiKeys.v1"
    private static let migratedKey = "apiKeysMigrated.v1"
    private static let d = UserDefaults.standard

    static func read(_ account: String) -> String? {
        var keys = d.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        if let k = keys[account] { return k.isEmpty ? nil : k }
        var migrated = d.stringArray(forKey: migratedKey) ?? []
        guard !migrated.contains(account) else { return nil }
        // One-time copy from the keychain (may show a single system prompt).
        let old = LegacyKeychain.read(account) ?? ""
        keys[account] = old
        migrated.append(account)
        d.set(keys, forKey: keysKey)
        d.set(migrated, forKey: migratedKey)
        return old.isEmpty ? nil : old
    }

    static func save(_ account: String, _ value: String) {
        var keys = d.dictionary(forKey: keysKey) as? [String: String] ?? [:]
        keys[account] = value
        d.set(keys, forKey: keysKey)
        var migrated = d.stringArray(forKey: migratedKey) ?? []
        if !migrated.contains(account) { migrated.append(account); d.set(migrated, forKey: migratedKey) }
    }
}

enum LegacyKeychain {
    static let service = "com.cracywu.translator"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ account: String, _ value: String) {
        SecItemDelete(base(account) as CFDictionary)
        guard !value.isEmpty else { return }
        var q = base(account)
        q[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }
}

// MARK: - Languages

enum Lang {
    static let autoSource = "自动识别"
    static let autoTarget = "自动（中↔英）"
    static let all = ["中文(简体)", "中文(繁体)", "英语", "日语", "韩语", "法语", "德语", "西班牙语", "俄语"]

    static func detect(_ text: String) -> String? {
        let r = NLLanguageRecognizer()
        r.processString(text)
        switch r.dominantLanguage {
        case .simplifiedChinese?: return "中文(简体)"
        case .traditionalChinese?: return "中文(繁体)"
        case .english?: return "英语"
        case .japanese?: return "日语"
        case .korean?: return "韩语"
        case .french?: return "法语"
        case .german?: return "德语"
        case .spanish?: return "西班牙语"
        case .russian?: return "俄语"
        default: return nil
        }
    }

    /// Chinese text → English, everything else → Simplified Chinese.
    static func autoTarget(for text: String) -> String {
        let d = detect(text)
        return (d == "中文(简体)" || d == "中文(繁体)") ? "英语" : "中文(简体)"
    }

    private static let google: [String: String] = [
        "中文(简体)": "zh-CN", "中文(繁体)": "zh-TW", "英语": "en", "日语": "ja", "韩语": "ko",
        "法语": "fr", "德语": "de", "西班牙语": "es", "俄语": "ru",
    ]
    private static let deeplTarget: [String: String] = [
        "中文(简体)": "ZH-HANS", "中文(繁体)": "ZH-HANT", "英语": "EN-US", "日语": "JA", "韩语": "KO",
        "法语": "FR", "德语": "DE", "西班牙语": "ES", "俄语": "RU",
    ]
    private static let deeplSource: [String: String] = [
        "中文(简体)": "ZH", "中文(繁体)": "ZH", "英语": "EN", "日语": "JA", "韩语": "KO",
        "法语": "FR", "德语": "DE", "西班牙语": "ES", "俄语": "RU",
    ]

    static func googleCode(_ name: String) -> String { google[name] ?? "auto" }
    static func deeplTargetCode(_ name: String) -> String { deeplTarget[name] ?? "ZH-HANS" }
    static func deeplSourceCode(_ name: String) -> String? { deeplSource[name] }
}

// MARK: - Shortcuts

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // Carbon modifier mask

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Shortcut.names[Int(keyCode)] ?? "键\(keyCode)")
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

enum HotAction: String, Codable, CaseIterable, Identifiable {
    case input, screenshot, selection, ocr, silentOCR, pasteImage
    var id: String { rawValue }

    var title: String {
        switch self {
        case .input: return "输入翻译"
        case .screenshot: return "截图翻译"
        case .selection: return "划词翻译"
        case .ocr: return "截图识字（弹窗）"
        case .silentOCR: return "静默截图识字（只写剪贴板）"
        case .pasteImage: return "粘贴图片识别翻译"
        }
    }

    var defaultShortcut: Shortcut? {
        switch self {
        case .input: return Shortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        case .screenshot: return Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(cmdKey))
        case .selection: return Shortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey))
        case .silentOCR: return Shortcut(keyCode: UInt32(kVK_ANSI_W), modifiers: UInt32(optionKey))
        case .ocr, .pasteImage: return nil
        }
    }

    static var defaults: [String: Shortcut] {
        var d: [String: Shortcut] = [:]
        for a in allCases { if let s = a.defaultShortcut { d[a.rawValue] = s } }
        return d
    }
}

// MARK: - Translation providers

enum ProviderKind: String, Codable {
    case openai, google, deepl

    var label: String {
        switch self {
        case .openai: return "OpenAI 兼容接口"
        case .google: return "谷歌翻译（免费）"
        case .deepl: return "DeepL"
        }
    }
}

let defaultPrompt = """
你是一名专业翻译。把用户发来的文本翻译成{target_lang}。
只输出译文，不要解释，保留原文的换行和格式。
"""

struct Provider: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: ProviderKind
    var name: String
    var enabled: Bool = true
    var baseURL: String = ""
    var model: String = ""
    var prompt: String = ""

    var keyAccount: String { "provider-\(id)" }
    var needsKey: Bool { kind != .google }

    static func deepseek() -> Provider {
        Provider(kind: .openai, name: "DeepSeek", baseURL: "https://api.deepseek.com",
                 model: "deepseek-chat", prompt: defaultPrompt)
    }
    static func openaiCompatible() -> Provider {
        Provider(kind: .openai, name: "OpenAI 兼容", baseURL: "https://api.openai.com/v1",
                 model: "", prompt: defaultPrompt)
    }
    static func google() -> Provider {
        Provider(kind: .google, name: "谷歌翻译", baseURL: "https://translate.googleapis.com")
    }
    static func deepl() -> Provider {
        Provider(kind: .deepl, name: "DeepL", baseURL: "")
    }
}

// MARK: - Settings

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var theme: String { didSet { d.set(theme, forKey: "theme") } }
    @Published var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    @Published var windowPosition: String { didSet { d.set(windowPosition, forKey: "windowPosition") } }
    @Published var mergeLines: Bool { didSet { d.set(mergeLines, forKey: "mergeLines") } }
    @Published var clipboardWatch: Bool { didSet { d.set(clipboardWatch, forKey: "clipboardWatch") } }
    @Published var hotkeysDisabled: Bool { didSet { d.set(hotkeysDisabled, forKey: "hotkeysDisabled") } }
    @Published var sourceLang: String { didSet { d.set(sourceLang, forKey: "sourceLang") } }
    @Published var targetLang: String { didSet { d.set(targetLang, forKey: "targetLang") } }
    @Published var shortcuts: [String: Shortcut] {
        didSet { d.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts.v1") }
    }
    @Published var providers: [Provider] {
        didSet { d.set(try? JSONEncoder().encode(providers), forKey: "providers.v1") }
    }

    private init() {
        theme = d.string(forKey: "theme") ?? "system"
        fontSize = d.object(forKey: "fontSize") as? Double ?? 14
        windowPosition = d.string(forKey: "windowPosition") ?? "mouse"
        mergeLines = d.object(forKey: "mergeLines") as? Bool ?? true
        clipboardWatch = d.bool(forKey: "clipboardWatch")
        hotkeysDisabled = d.bool(forKey: "hotkeysDisabled")
        sourceLang = d.string(forKey: "sourceLang") ?? Lang.autoSource
        targetLang = d.string(forKey: "targetLang") ?? Lang.autoTarget

        if let data = d.data(forKey: "shortcuts.v1"),
           let s = try? JSONDecoder().decode([String: Shortcut].self, from: data) {
            shortcuts = s
        } else {
            shortcuts = HotAction.defaults
        }

        if let data = d.data(forKey: "providers.v1"),
           let p = try? JSONDecoder().decode([Provider].self, from: data) {
            providers = p
        } else {
            // First run of v2: migrate the single DeepSeek config from v1, add free Google.
            var ds = Provider.deepseek()
            if let b = d.string(forKey: "baseURL"), !b.isEmpty { ds.baseURL = b }
            if let m = d.string(forKey: "model"), !m.isEmpty { ds.model = m }
            if let p = d.string(forKey: "prompt"), !p.isEmpty {
                ds.prompt = p
            }
            if let oldKey = Keychain.read("deepseek-api-key"), !oldKey.isEmpty {
                Keychain.save(ds.keyAccount, oldKey)
            }
            providers = [ds, Provider.google()]
        }

        // didSet does not fire inside init: persist first-run defaults/migration right away,
        // so provider ids (and the keychain accounts tied to them) stay stable across launches.
        d.set(try? JSONEncoder().encode(providers), forKey: "providers.v1")
        d.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts.v1")
    }
}

// MARK: - History

struct HistoryResult: Codable, Hashable {
    var name: String
    var text: String
}

struct HistoryEntry: Codable, Identifiable {
    var id: String = UUID().uuidString
    var date: Date
    var source: String
    var target: String
    var results: [HistoryResult]
}

@MainActor
final class History: ObservableObject {
    static let shared = History()
    static let limit = 100
    @Published private(set) var entries: [HistoryEntry] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: "history.v1"),
           let e = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = e
        }
    }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: "history.v1")
    }

    func add(_ e: HistoryEntry) {
        entries.insert(e, at: 0)
        if entries.count > History.limit { entries.removeLast(entries.count - History.limit) }
        persist()
    }

    func delete(_ id: String) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries.removeAll()
        persist()
    }
}

// MARK: - Global hotkeys (Carbon)

@MainActor
enum HotKeys {
    static var handler: ((HotAction) -> Void)?
    private static var refs: [EventHotKeyRef] = []
    private static var actions: [UInt32: HotAction] = [:]

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            Task { @MainActor in
                if let a = HotKeys.actions[id] { HotKeys.handler?(a) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    static func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        actions = [:]
    }

    /// Registers all shortcuts; returns the display strings that failed (taken by another app).
    @discardableResult
    static func registerAll(_ map: [String: Shortcut]) -> [String] {
        unregisterAll()
        var failed: [String] = []
        var next: UInt32 = 1
        for a in HotAction.allCases {
            guard let s = map[a.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x54524E53), id: next) // 'TRNS'
            let st = RegisterEventHotKey(s.keyCode, s.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if st == noErr, let ref {
                refs.append(ref)
                actions[next] = a
            } else {
                failed.append("\(a.title) \(s.display)")
            }
            next += 1
        }
        return failed
    }
}

// MARK: - Clipboard

@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()
    var onText: ((String) -> Void)?
    var suspended = false
    private var timer: Timer?
    private var last = NSPasteboard.general.changeCount

    func start() {
        guard timer == nil else { return }
        last = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Mark the current pasteboard content as seen (used after our own writes).
    func ignoreCurrent() { last = NSPasteboard.general.changeCount }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != last else { return }
        last = pb.changeCount
        guard !suspended, let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onText?(s)
    }
}

@MainActor
func copyToPasteboard(_ s: String) {
    let pb = NSPasteboard.general
    pb.clearContents()
    pb.setString(s, forType: .string)
    ClipboardWatcher.shared.ignoreCurrent()
}

// MARK: - Text helpers

enum TextCase {
    static func isEnglish(_ s: String) -> Bool {
        s.range(of: "\\p{Han}", options: .regularExpression) == nil
            && s.range(of: "[A-Za-z]", options: .regularExpression) != nil
    }

    private static func words(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }

    static func camel(_ s: String) -> String {
        let w = words(s)
        guard let first = w.first else { return "" }
        return first.lowercased() + w.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined()
    }

    static func snake(_ s: String) -> String {
        words(s).map { $0.lowercased() }.joined(separator: "_")
    }
}
