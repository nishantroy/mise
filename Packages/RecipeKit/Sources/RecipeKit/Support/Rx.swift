import Foundation

/// Small NSRegularExpression helper. Patterns are compiled once and cached.
enum Rx {
    nonisolated(unsafe) private static var cache: [String: NSRegularExpression] = [:]
    private static let lock = NSLock()

    static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        // Patterns are compile-time constants; a bad one is a programmer error.
        let compiled = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = compiled
        return compiled
    }

    /// Capture groups of the first match (index 0 = whole match). Missing groups are nil.
    static func firstMatch(_ pattern: String, in text: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> [String?]? {
        let ns = text as NSString
        guard let m = re(pattern, options).firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    static func matches(_ pattern: String, in text: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> [[String?]] {
        let ns = text as NSString
        return re(pattern, options).matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
        }
    }

    static func replace(_ pattern: String, in text: String, with template: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        re(pattern, options).stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }

    static func test(_ pattern: String, _ text: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> Bool {
        re(pattern, options).firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Collapses runs of whitespace (including non-breaking spaces) to single spaces and trims.
    var collapsedWhitespace: String {
        Rx.replace("[\\s\\u00A0]+", in: self, with: " ").trimmed
    }
}
