import AppKit
import Carbon
import Vision
import ImageIO
import ApplicationServices

// MARK: - Selected text

@MainActor
enum Selection {
    /// Try Accessibility first, then fall back to simulating ⌘C (clipboard is restored afterwards).
    static func get(_ done: @escaping @MainActor (String?) -> Void) {
        if let s = viaAX() { done(s); return }
        viaCopy(done)
    }

    private static func viaAX() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let el = focused, CFGetTypeID(el) == AXUIElementGetTypeID() else { return nil }
        var sel: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &sel) == .success,
              let s = sel as? String,
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func viaCopy(_ done: @escaping @MainActor (String?) -> Void) {
        let pb = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pb.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
            return copy
        }
        let before = pb.changeCount
        ClipboardWatcher.shared.suspended = true

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        Task { @MainActor in
            var text: String?
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if pb.changeCount != before {
                    text = pb.string(forType: .string)
                    break
                }
            }
            if pb.changeCount != before {
                pb.clearContents()
                if !saved.isEmpty { pb.writeObjects(saved) }
            }
            ClipboardWatcher.shared.ignoreCurrent()
            ClipboardWatcher.shared.suspended = false
            done(text)
        }
    }
}

// MARK: - Screenshot

enum Capture {
    /// Native interactive region selection. Returns nil when the user presses Esc.
    static func interactive() async -> CGImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                // Last capture is kept (overwritten each time) in the system temp dir for troubleshooting.
                let path = NSTemporaryDirectory() + "translator-last-capture.png"
                try? FileManager.default.removeItem(atPath: path)
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-i", "-x", path]
                try? p.run()
                p.waitUntilExit()
                var img: CGImage?
                if let s = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) {
                    img = CGImageSourceCreateImageAtIndex(s, 0, nil)
                }
                cont.resume(returning: img)
            }
        }
    }

    @MainActor
    static func imageFromPasteboard() -> CGImage? {
        guard let img = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else { return nil }
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

// MARK: - OCR

enum OCR {
    /// Vision loads its text models lazily: the first recognition after launch can take tens of
    /// seconds. Run one tiny recognition in the background at startup so real captures are instant.
    @MainActor
    static func warmUp() {
        let size = NSSize(width: 320, height: 80)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        ("预热 Warm up 테스트 テスト" as NSString).draw(
            at: NSPoint(x: 10, y: 25),
            withAttributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.black])
        img.unlockFocus()
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        Task.detached(priority: .utility) {
            _ = try? await recognize(cg, mergeLines: false)
        }
    }

    static func recognize(_ img: CGImage, mergeLines: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                req.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US", "ja-JP", "ko-KR"]
                do {
                    try VNImageRequestHandler(cgImage: img).perform([req])
                    let obs = req.results ?? []
                    cont.resume(returning: mergeLines ? merge(obs) : plain(obs))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func plain(_ obs: [VNRecognizedTextObservation]) -> String {
        obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// Join lines that belong to the same paragraph: a line continues the previous one unless the
    /// previous line ends a sentence, is noticeably shorter than the text block, or there is a big gap.
    static func merge(_ obs: [VNRecognizedTextObservation]) -> String {
        struct Line { let text: String; let box: CGRect }
        let lines: [Line] = obs.compactMap { o in
            guard let s = o.topCandidates(1).first?.string else { return nil }
            return Line(text: s, box: o.boundingBox)
        }
        guard let first = lines.first else { return "" }
        let right = lines.map { $0.box.maxX }.max() ?? 1
        let left = lines.map { $0.box.minX }.min() ?? 0
        let width = max(right - left, 0.0001)
        let enders: Set<Character> = ["。", "！", "？", ".", "!", "?", ":", "：", ";", "；"]

        var out = first.text
        for i in 1..<lines.count {
            let prev = lines[i - 1], cur = lines[i]
            let gap = prev.box.minY - cur.box.maxY
            let endsSentence = prev.text.last.map { enders.contains($0) } ?? false
            let shortLine = prev.box.maxX < right - width * 0.15
            let bigGap = gap > prev.box.height * 0.9 || gap < -prev.box.height // new column / out of order
            if endsSentence || shortLine || bigGap {
                out += "\n" + cur.text
            } else {
                let a = prev.text.last, b = cur.text.first
                let latin: (Character?) -> Bool = { c in c.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ",") } ?? false }
                if a == "-", let bb = b, bb.isLowercase {
                    out.removeLast()                         // re-join hyphenated word
                    out += cur.text
                } else {
                    out += (latin(a) && latin(b) ? " " : "") + cur.text
                }
            }
        }
        return out
    }
}

// MARK: - Translation engines

enum Engines {
    static func run(_ p: Provider, key: String, text: String, source: String, target: String,
                    onDelta: @escaping @MainActor (String) -> Void) async throws {
        switch p.kind {
        case .openai:
            try await openai(p, key: key, text: text, source: source, target: target, onDelta: onDelta)
        case .google:
            let t = try await google(p, text: text, source: source, target: target)
            await onDelta(t)
        case .deepl:
            let t = try await deepl(p, key: key, text: text, source: source, target: target)
            await onDelta(t)
        }
    }

    private static func trimmedBase(_ s: String) -> String {
        var b = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }

    private static func httpError(_ code: Int, _ body: String) -> AppError {
        AppError("HTTP \(code)：\(String(body.prefix(500)))")
    }

    // OpenAI-compatible chat completions with SSE streaming (DeepSeek, OpenAI, Ollama /v1, …)
    private static func openai(_ p: Provider, key: String, text: String, source: String, target: String,
                               onDelta: @escaping @MainActor (String) -> Void) async throws {
        let base = trimmedBase(p.baseURL)
        guard let url = URL(string: base + "/chat/completions") else { throw AppError("接口地址不对：\(p.baseURL)") }
        let isLocal = base.contains("127.0.0.1") || base.contains("localhost")
        if key.isEmpty && !isLocal { throw AppError("还没填 API Key：设置 → 翻译源") }
        if p.model.isEmpty { throw AppError("还没填模型名：设置 → 翻译源") }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let prompt = (p.prompt.isEmpty ? defaultPrompt : p.prompt)
            .replacingOccurrences(of: "{target_lang}", with: target)
            .replacingOccurrences(of: "{source_lang}", with: source)
        let body: [String: Any] = [
            "model": p.model,
            "stream": true,
            "messages": [
                ["role": "system", "content": prompt],
                ["role": "user", "content": text],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var b = ""
            for try await line in bytes.lines { b += line; if b.count > 500 { break } }
            throw httpError(code, b)
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let d = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let c = delta["content"] as? String else { continue }
            await onDelta(c)
        }
    }

    // Free Google Translate web endpoint (client=gtx), no key.
    private static func google(_ p: Provider, text: String, source: String, target: String) async throws -> String {
        let base = trimmedBase(p.baseURL.isEmpty ? Provider.google().baseURL : p.baseURL)
        guard var comps = URLComponents(string: base + "/translate_a/single") else {
            throw AppError("接口地址不对：\(p.baseURL)")
        }
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: source == Lang.autoSource ? "auto" : Lang.googleCode(source)),
            URLQueryItem(name: "tl", value: Lang.googleCode(target)),
            URLQueryItem(name: "dt", value: "t"),
        ]
        guard let url = comps.url else { throw AppError("接口地址不对：\(p.baseURL)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "q", value: text)]
        req.httpBody = (form.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw httpError(code, String(decoding: data, as: UTF8.self)) }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [Any],
              let parts = arr.first as? [Any] else { throw AppError("谷歌返回的格式无法解析") }
        return parts.compactMap { ($0 as? [Any])?.first as? String }.joined()
    }

    // DeepL API (Free keys end with ":fx").
    private static func deepl(_ p: Provider, key: String, text: String, source: String, target: String) async throws -> String {
        if key.isEmpty { throw AppError("还没填 DeepL API Key：设置 → 翻译源") }
        let fallback = key.hasSuffix(":fx") ? "https://api-free.deepl.com" : "https://api.deepl.com"
        let base = trimmedBase(p.baseURL.isEmpty ? fallback : p.baseURL)
        guard let url = URL(string: base + "/v2/translate") else { throw AppError("接口地址不对：\(p.baseURL)") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("DeepL-Auth-Key \(key)", forHTTPHeaderField: "Authorization")
        var body: [String: Any] = ["text": [text], "target_lang": Lang.deeplTargetCode(target)]
        if source != Lang.autoSource, let s = Lang.deeplSourceCode(source) { body["source_lang"] = s }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw httpError(code, String(decoding: data, as: UTF8.self)) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tr = obj["translations"] as? [[String: Any]],
              let t = tr.first?["text"] as? String else { throw AppError("DeepL 返回的格式无法解析") }
        return t
    }
}
