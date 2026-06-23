import Foundation
import AppKit
import Vision

/// Talks to a cloud vision model (Anthropic Claude by default) to describe + name an image.
///
/// Swap `endpoint`/`buildRequest`/`parse` if you prefer OpenAI or Gemini — the rest of the
/// app only depends on `describe(imageAt:) -> VisionResult`.
enum VisionError: LocalizedError {
    case noAPIKey
    case badImage
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:      return "No API key set. Add one in Settings."
        case .badImage:      return "Could not read the image file."
        case .http(let c, let m): return "API error \(c): \(m)"
        case .decoding(let m):    return "Could not parse model response: \(m)"
        }
    }
}

struct VisionClient {
    let apiKey: String
    let model: String
    /// User's renaming style instruction, e.g. "Use Title Case, keep under 6 words."
    let namingStyle: String

    private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!

    func describe(imageAt url: URL) async throws -> VisionResult {
        guard !apiKey.isEmpty else { throw VisionError.noAPIKey }

        // Downscale to keep payloads small and cheap.
        guard let (b64, mediaType) = Self.encode(url) else { throw VisionError.badImage }

        let prompt = """
        You are naming and indexing a screenshot. Respond with ONLY a JSON object, no prose.
        Schema: {"name": string, "ocr": string, "summary": string, "keywords": [string]}
        - name: a concise, descriptive file name WITHOUT extension, using spaces and Title Case (never underscores). \(namingStyle)
        - ocr: all visible text in the image, or "" if none.
        - summary: one short sentence describing the image.
        - keywords: 3 to 8 lowercase search keywords.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mediaType, "data": b64]],
                    ["type": "text", "text": prompt]
                ]
            ]]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw VisionError.http(0, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VisionError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        // Anthropic returns { content: [ { type: "text", text: "..." } ] }
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]],
            let text = content.first(where: { $0["type"] as? String == "text" })?["text"] as? String
        else { throw VisionError.decoding("unexpected envelope") }

        let json = Self.extractJSON(from: text)
        guard let result = try? JSONDecoder().decode(VisionResult.self, from: Data(json.utf8)) else {
            throw VisionError.decoding(text)
        }
        return result
    }

    /// Load, downscale (max 1280px on long edge), and base64-encode as JPEG.
    private static func encode(_ url: URL) -> (String, String)? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxEdge: CGFloat = 1280
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)

        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()

        guard
            let tiff = resized.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return nil }

        return (jpeg.base64EncodedString(), "image/jpeg")
    }

    /// Models sometimes wrap JSON in ```json fences. Pull out the object.
    private static func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}

// MARK: - On-device describer (fully private)

/// Produces the same `VisionResult` as `VisionClient`, but entirely on-device:
/// Apple's Vision framework does OCR + image classification, and the name /
/// summary / keywords are derived locally. Nothing is uploaded anywhere.
///
/// This is text-led (ideal for screenshots). For pixel-level description of
/// non-text images you'd add a local vision-language model (e.g. via MLX);
/// the upgrade slots in right here without touching the rest of the app.
struct LocalVisionDescriber {
    let namingStyle: String   // kept for API parity; unused by the heuristics

    func describe(imageAt url: URL) async throws -> VisionResult {
        // 1) OCR + image tags (Vision, on-device, blocking → run off-main).
        let (lines, tags) = try await Self.visionPass(url)
        let fullText = lines.map(\.text).joined(separator: "\n")
        let title    = Self.headingText(from: lines)

        // 2) Name/summary/keywords: prefer Apple Intelligence (on-device),
        //    otherwise fall back to the local heuristics. Both stay private.
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *), AppleIntelligenceNamer.isAvailable {
            if let ai = try? await AppleIntelligenceNamer.name(
                ocr: fullText, tags: tags, title: title, style: namingStyle) {
                return VisionResult(
                    name:     ai.name,
                    ocr:      fullText,
                    summary:  ai.summary,
                    keywords: ai.keywords.isEmpty ? Self.deriveKeywords(from: fullText, tags: tags)
                                                  : ai.keywords
                )
            }
        }
        #endif

        return VisionResult(
            name:     Self.deriveName(title: title, firstLine: lines.first?.text ?? "", tags: tags),
            ocr:      fullText,
            summary:  Self.deriveSummary(title: title, tags: tags, hasText: !fullText.isEmpty),
            keywords: Self.deriveKeywords(from: fullText, tags: tags)
        )
    }

    private static func visionPass(_ url: URL) async throws -> ([Line], [String]) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard
                        let image = NSImage(contentsOf: url),
                        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                    else { throw VisionError.badImage }
                    let lines = try recognizeText(cg)
                    let tags  = (try? classify(cg)) ?? []
                    continuation.resume(returning: (lines, tags))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    // MARK: Vision requests

    private struct Line { let text: String; let height: CGFloat; let width: CGFloat; let y: CGFloat }

    private static func recognizeText(_ cg: CGImage) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])

        let lines: [Line] = (request.results ?? []).compactMap { obs in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return Line(text: s, height: obs.boundingBox.height, width: obs.boundingBox.width, y: obs.boundingBox.midY)
        }
        // Vision's y-origin is bottom-left, so higher y = higher on screen.
        return lines.sorted { $0.y > $1.y }
    }

    /// Best guess at the heading: the tallest *horizontal* line (wider than it
    /// is tall). This skips vertical sidebar/letterhead text — e.g. a rotated
    /// "STRATHCLYDE BUSINESS SCHOOL" — which would otherwise win on height.
    private static func headingText(from lines: [Line]) -> String {
        let horizontal = lines.filter { $0.width >= $0.height }
        return (horizontal.max(by: { $0.height < $1.height })
                ?? lines.max(by: { $0.height < $1.height }))?.text ?? ""
    }

    private static func classify(_ cg: CGImage) throws -> [String] {
        let request = VNClassifyImageRequest()
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.3 }
            .prefix(5)
            .map { $0.identifier }
    }

    // MARK: Heuristics

    private static func deriveName(title: String, firstLine: String, tags: [String]) -> String {
        let candidate = title.isEmpty ? firstLine : title
        let cleaned = candidate
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty {
            return (tags.first.map(titleCase) ?? "Screenshot")
        }
        // Keep it short: first ~6 words, title-cased.
        let words = cleaned.split(separator: " ").prefix(6).joined(separator: " ")
        return titleCase(String(words))
    }

    private static func deriveSummary(title: String, tags: [String], hasText: Bool) -> String {
        let kind = tags.first ?? (hasText ? "text" : "image")
        let lead = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if lead.isEmpty { return "A screenshot containing \(kind)." }
        return "A screenshot of \(kind): \(String(lead.prefix(80)))"
    }

    private static let stopwords: Set<String> = [
        "the","and","for","with","that","this","from","your","you","are","was",
        "have","has","not","but","all","can","will","into","out","about","more"
    ]

    private static func deriveKeywords(from text: String, tags: [String]) -> [String] {
        var counts: [String: Int] = [:]
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let w = String(raw)
            guard w.count > 3, !stopwords.contains(w) else { continue }
            counts[w, default: 0] += 1
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(6).map(\.key)
        // Lead with classifier tags, then frequent words; dedupe, cap at 8.
        var seen = Set<String>()
        return (tags.map { $0.lowercased() } + top).filter { seen.insert($0).inserted }.prefix(8).map { $0 }
    }

    private static func titleCase(_ s: String) -> String {
        s.split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

// MARK: - Apple Intelligence naming (on-device LLM)

#if canImport(FoundationModels)
import FoundationModels

/// Structured output we ask Apple's on-device model to fill in. Guided
/// generation means the model returns a typed value — no string parsing.
@available(macOS 26.0, *)
@Generable
struct ScreenshotNaming {
    @Guide(description: "A specific, descriptive title that leads with the most identifying detail shown — the app or website, document or page title, company, person, or concrete topic. Title Case, words separated by spaces, no underscores, no file extension. Never a generic word like Screenshot, Screen, Image, Document, or Untitled.")
    var name: String
    @Guide(description: "One short sentence naming what the screenshot shows and its key specifics")
    var summary: String
    @Guide(description: "3 to 8 lowercase search keywords, including any specific names, products, or topics visible")
    var keywords: [String]
}

/// Wraps the on-device language model. Used only when Apple Intelligence is
/// available; the caller falls back to heuristics otherwise. Runs locally —
/// the OCR text never leaves the Mac.
@available(macOS 26.0, *)
enum AppleIntelligenceNamer {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func name(ocr: String, tags: [String], title: String, style: String) async throws
        -> (name: String, summary: String, keywords: [String]) {
        let session = LanguageModelSession(instructions: """
            You name and summarize screenshots from the text extracted from them. \(style)

            Name the ACTUAL CONTENT shown — usually the main heading or title and a key \
            specific detail from the body. The provided heading hint is the real title; \
            build the name around it.

            Do NOT base the name on surrounding chrome: ignore app toolbars and menus, \
            video-call participant tiles and initials, browser tabs, and especially \
            letterheads, logos, watermarks, or sidebar branding (e.g. a school or company \
            name printed down the side). Those are context, not the subject.

            Do NOT invent or pad with words that aren't in the text (no guessing \
            "Dashboard", "Overview", "Screen", "Page"). If unsure, use the heading text \
            closely. Be specific, never generic.

            Names use spaces and Title Case — never underscores or snake_case. Convert \
            ALL-CAPS source text to Title Case; do not copy capitalization verbatim.

            Examples of good names:
            - "Selecting Your Company Strategic Decision"
            - "Strathclyde Assignment Feedback 75 Percent"
            - "SwiftUI NavigationStack Documentation"
            - "WhatsApp Chat About Flight Booking"
            """)
        let prompt = """
            Heading hint (the real title — build the name around this): \(title.isEmpty ? "(none detected)" : title)

            All extracted text (may include chrome/branding to ignore):
            \(ocr.isEmpty ? "(no text detected in image)" : ocr)

            Image tags: \(tags.isEmpty ? "none" : tags.joined(separator: ", "))
            """
        let response = try await session.respond(to: prompt, generating: ScreenshotNaming.self)
        let out = response.content
        return (out.name, out.summary, out.keywords)
    }
}
#endif

// MARK: - OpenAI vision client

/// Same `describe(imageAt:)` contract as `VisionClient`, but against OpenAI's
/// chat-completions API with an image attachment.
struct OpenAIClient {
    let apiKey: String
    let model: String
    let namingStyle: String

    private let endpoint = URL(string: "https://api.openai.com/v1/chat/completions")!

    func describe(imageAt url: URL) async throws -> VisionResult {
        guard !apiKey.isEmpty else { throw VisionError.noAPIKey }
        guard let (b64, mediaType) = Self.encode(url) else { throw VisionError.badImage }

        let system = """
        You name and index screenshots. Respond with ONLY a JSON object, no prose.
        Schema: {"name": string, "ocr": string, "summary": string, "keywords": [string]}
        - name: a concise, descriptive file name WITHOUT extension, using spaces and Title Case (never underscores). \(namingStyle)
        - ocr: all visible text in the image, or "".
        - summary: one short sentence.
        - keywords: 3 to 8 lowercase keywords.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": [
                    ["type": "text", "text": "Name and index this screenshot."],
                    ["type": "image_url", "image_url": ["url": "data:\(mediaType);base64,\(b64)"]]
                ]]
            ]
        ]

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw VisionError.http(0, "no response") }
        guard (200..<300).contains(http.statusCode) else {
            throw VisionError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let text = message["content"] as? String
        else { throw VisionError.decoding("unexpected envelope") }

        let json = Self.extractJSON(from: text)
        guard let result = try? JSONDecoder().decode(VisionResult.self, from: Data(json.utf8)) else {
            throw VisionError.decoding(text)
        }
        return result
    }

    private static func encode(_ url: URL) -> (String, String)? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxEdge: CGFloat = 1280
        let size = image.size
        let scale = min(1, maxEdge / max(size.width, size.height))
        let target = NSSize(width: size.width * scale, height: size.height * scale)
        let resized = NSImage(size: target)
        resized.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: target))
        resized.unlockFocus()
        guard
            let tiff = resized.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7])
        else { return nil }
        return (jpeg.base64EncodedString(), "image/jpeg")
    }

    private static func extractJSON(from text: String) -> String {
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }
        return text
    }
}
