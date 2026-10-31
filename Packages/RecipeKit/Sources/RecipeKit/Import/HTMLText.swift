import Foundation

/// HTML → text helpers: entity decoding, tag stripping and block-aware line splitting.
public enum HTMLText {
    public struct Line: Hashable, Sendable {
        public var text: String
        /// True when the line came from an `<h1>`–`<h6>` element.
        public var isHeading: Bool
        public init(text: String, isHeading: Bool = false) {
            self.text = text
            self.isHeading = isHeading
        }
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "frac12": "½", "frac14": "¼", "frac34": "¾", "frac13": "⅓", "frac23": "⅔", "frac18": "⅛",
        "deg": "°", "times": "×", "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "aacute": "á", "agrave": "à", "acirc": "â",
        "iacute": "í", "oacute": "ó", "uacute": "ú", "ntilde": "ñ", "ccedil": "ç", "uuml": "ü",
        "ouml": "ö", "auml": "ä", "szlig": "ß", "laquo": "«", "raquo": "»", "minus": "−", "prime": "′",
    ]

    /// Decodes named and numeric entities. Runs twice so double-encoded text ("&amp;#8217;") comes out clean.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for _ in 0..<2 {
            guard result.contains("&") else { break }
            result = decodeOnce(result)
        }
        return result
    }

    private static func decodeOnce(_ text: String) -> String {
        let ns = text as NSString
        let matches = Rx.re("&(#[0-9]+|#[xX][0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);", []).matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let body = ns.substring(with: m.range(at: 1))
            var replacement: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                replacement = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if body.hasPrefix("#") {
                replacement = UInt32(body.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = named[body] ?? named[body.lowercased()]
            }
            out += replacement ?? ns.substring(with: m.range)
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    /// Removes tags, decodes entities and collapses whitespace. Safe on plain text.
    public static func clean(_ text: String) -> String {
        var s = text
        if s.contains("<") {
            s = Rx.replace("<(script|style)\\b[^>]*>.*?</\\1\\s*>", in: s, with: " ", [.caseInsensitive, .dotMatchesLineSeparators])
            s = Rx.replace("<br\\s*/?>", in: s, with: " ")
            s = Rx.replace("</?[a-zA-Z][^>]*>", in: s, with: "")
        }
        s = decodeEntities(s)
        // Entity-decoded text can itself contain tags (e.g. "&lt;p&gt;").
        if s.contains("</") || s.contains("<p") || s.contains("<a ") {
            s = Rx.replace("</?[a-zA-Z][^>]*>", in: s, with: "")
        }
        return s.collapsedWhitespace
    }

    private static let blockTags: Set<String> = [
        "p", "div", "li", "ul", "ol", "br", "tr", "td", "th", "table", "tbody", "thead", "section", "article",
        "header", "footer", "aside", "nav", "main", "dd", "dt", "dl", "blockquote", "pre", "figure", "figcaption",
        "form", "hr", "h1", "h2", "h3", "h4", "h5", "h6", "title", "body", "html", "head",
    ]

    /// Splits a page into visible text lines. Block elements start new lines; inline ones don't.
    public static func lines(fromHTML html: String) -> [Line] {
        var s = Rx.replace("<!--.*?-->", in: html, with: " ", [.dotMatchesLineSeparators])
        s = Rx.replace("<(script|style|noscript|svg|template|head|iframe|button|select)\\b[^>]*>.*?</\\1\\s*>", in: s, with: " ", [.caseInsensitive, .dotMatchesLineSeparators])
        let ns = s as NSString
        let tagRe = Rx.re("<(/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>", [])
        var lines: [Line] = []
        var current = ""
        var headingDepth = 0
        var lineIsHeading = false
        func flush() {
            let text = decodeEntities(current).collapsedWhitespace
            if !text.isEmpty { lines.append(Line(text: text, isHeading: lineIsHeading)) }
            current = ""
            lineIsHeading = headingDepth > 0
        }
        var cursor = 0
        for m in tagRe.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            current += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            cursor = m.range.location + m.range.length
            let closing = ns.substring(with: m.range(at: 1)) == "/"
            let name = ns.substring(with: m.range(at: 2)).lowercased()
            guard blockTags.contains(name) else { continue }
            let isHeadingTag = name.count == 2 && name.hasPrefix("h") && name.last!.isNumber
            flush()
            if isHeadingTag {
                headingDepth = max(0, headingDepth + (closing ? -1 : 1))
                lineIsHeading = headingDepth > 0
            }
        }
        current += ns.substring(from: cursor)
        flush()
        return lines
    }

    /// Plain text → lines (for pasted recipes). Bullets and numbering are left for the parser.
    public static func lines(fromText text: String) -> [Line] {
        text.components(separatedBy: .newlines)
            .map { $0.collapsedWhitespace }
            .filter { !$0.isEmpty }
            .map { Line(text: $0) }
    }

    /// `content` of `<meta property|name="…">`, entity-decoded.
    public static func metaContent(_ property: String, in html: String) -> String? {
        let p = Rx.escape(property)
        let patterns = [
            "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(p)[\"'][^>]*content\\s*=\\s*\"([^\"]*)\"",
            "<meta[^>]+(?:property|name)\\s*=\\s*[\"']\(p)[\"'][^>]*content\\s*=\\s*'([^']*)'",
            "<meta[^>]+content\\s*=\\s*\"([^\"]*)\"[^>]*(?:property|name)\\s*=\\s*[\"']\(p)[\"']",
        ]
        for pattern in patterns {
            if let m = Rx.firstMatch(pattern, in: html), let v = m[1] {
                let cleaned = clean(v)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    public static func titleTag(in html: String) -> String? {
        guard let m = Rx.firstMatch("<title[^>]*>(.*?)</title>", in: html, [.caseInsensitive, .dotMatchesLineSeparators]), let t = m[1] else { return nil }
        let cleaned = clean(t)
        return cleaned.isEmpty ? nil : cleaned
    }
}
