import Foundation
import CoreGraphics
import CoreText
import DeepwellTagging

/// Source of title-free cover artwork. Production: `OpenRouterCoverArt`; tests: a stub.
public protocol CoverArtist: Sendable {
    /// Raw image bytes (any ImageIO format). Throws on any failure; the caller falls back to a plain cover.
    func artwork(title: String, articleTitles: [String]) async throws -> Data
}

public enum CoverError: Error, Equatable, CustomStringConvertible {
    case missingKey
    case api(Int, String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .missingKey: "no OpenRouter key set"
        case .api(let s, let m): "OpenRouter error \(s): \(m)"
        case .badResponse(let m): "unexpected OpenRouter reply (\(m))"
        }
    }
}

/// Text-free art from an OpenRouter image model; the exact title is typeset locally afterwards, so a model can
/// never misspell it. Same model and endpoint readpack used.
public struct OpenRouterCoverArt: CoverArtist {
    public static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    public static let defaultModel = "openai/gpt-5.4-image-2"

    let keys: APIKeyStore
    let transport: HTTPTransport
    let model: String

    public init(keys: APIKeyStore, transport: HTTPTransport = URLSessionTransport(), model: String = defaultModel) {
        self.keys = keys; self.transport = transport; self.model = model
    }

    static func prompt(title: String, articleTitles: [String]) -> String {
        "Create text-free, portrait ebook cover artwork. Do not include lettering, words, numbers, or typography. "
            + "Leave the lower third calm and uncluttered. Minimalist, elegant, a distinct visual metaphor. "
            + "Use these titles only as thematic inspiration. Collection: \(title). Articles: "
            + articleTitles.prefix(20).joined(separator: "; ")
    }

    public func artwork(title: String, articleTitles: [String]) async throws -> Data {
        guard let key = keys.load() else { throw CoverError.missingKey }
        var req = URLRequest(url: Self.endpoint, timeoutInterval: 180)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Deepwell", forHTTPHeaderField: "X-Title")
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": Self.prompt(title: title, articleTitles: articleTitles)]],
            "modalities": ["image", "text"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await transport.send(req)
        guard (200..<300).contains(resp.statusCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(decoding: data.prefix(200), as: UTF8.self)
            throw CoverError.api(resp.statusCode, msg)
        }
        return try Self.decodeImage(data)
    }

    /// `choices[0].message.images[0].image_url.url` is a `data:image/...;base64,` URL.
    static func decodeImage(_ data: Data) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first,
              let message = choice["message"] as? [String: Any],
              let image = (message["images"] as? [[String: Any]])?.first,
              let url = (image["image_url"] as? [String: Any])?["url"] as? String
        else { throw CoverError.badResponse("no image in reply") }
        let b64 = url.split(separator: ",", maxSplits: 1).last.map(String.init) ?? url
        guard let bytes = Data(base64Encoded: b64, options: .ignoreUnknownCharacters), !bytes.isEmpty else {
            throw CoverError.badResponse("image is not base64")
        }
        return bytes
    }
}

/// Draws the cover: artwork (aspect-filled) with the title on a dark band, or a plain Ayu Mirage cover without art.
public enum CoverTypesetter {
    public static let size = (width: 1600, height: 2560)

    public static func render(title: String, subtitle: String, art: Data?) -> Data? {
        let (w, h) = size
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: w, height: h)
        let mirage = rgb(0x242936), text = rgb(0xCCCAC2), accent = rgb(0xFFCC66)

        ctx.setFillColor(mirage)
        ctx.fill(full)
        let bandHeight = CGFloat(h) * 0.34
        if let art, let img = ImageProcessing.decode(art) {
            // Aspect-fill.
            let scale = max(CGFloat(w) / CGFloat(img.width), CGFloat(h) / CGFloat(img.height))
            let dw = CGFloat(img.width) * scale, dh = CGFloat(img.height) * scale
            ctx.draw(img, in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
            ctx.setFillColor(mirage.copy(alpha: 0.88)!)
            ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: bandHeight))
        }
        // Accent rule above the title block. CoreGraphics' origin is bottom-left.
        ctx.setFillColor(accent)
        ctx.fill(CGRect(x: 120, y: bandHeight - 40, width: 220, height: 14))

        let titleRect = CGRect(x: 120, y: 330, width: CGFloat(w) - 240, height: bandHeight - 420)
        draw(title, in: titleRect, font: font(["Georgia-Bold", "TimesNewRomanPS-BoldMT"], size: fitSize(title)), color: text, ctx: ctx)
        draw(subtitle, in: CGRect(x: 120, y: 150, width: CGFloat(w) - 240, height: 140),
             font: font(["Georgia-Italic", "TimesNewRomanPS-ItalicMT"], size: 64), color: accent, ctx: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return ImageProcessing.jpeg(img, quality: 0.9)
    }

    private static func fitSize(_ title: String) -> CGFloat {
        switch title.count { case ..<30: 150; case ..<60: 120; case ..<100: 96; default: 76 }
    }

    private static func rgb(_ hex: UInt32) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    private static func font(_ names: [String], size: CGFloat) -> CTFont {
        for n in names {
            let f = CTFontCreateWithName(n as CFString, size, nil)
            if (CTFontCopyPostScriptName(f) as String) == n { return f }
        }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// Text set from the top of `rect`; overflow is clipped by the frame.
    private static func draw(_ s: String, in rect: CGRect, font: CTFont, color: CGColor, ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let str = NSAttributedString(string: s, attributes: attrs)
        let setter = CTFramesetterCreateWithAttributedString(str)
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, ctx)
    }
}
