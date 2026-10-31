import Foundation

/// Fetches a page's HTML. A protocol so previews and UI tests can stub the network.
protocol RecipeFetching: Sendable {
    func fetchHTML(from url: URL) async throws -> String
}

enum FetchError: LocalizedError {
    case badStatus(Int)
    case notText
    case notFound

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): "The site answered with an error (HTTP \(code))."
        case .notText: "That link didn't return a web page."
        case .notFound: "That page isn't available."
        }
    }
}

struct RecipeFetcher: RecipeFetching {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        if let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) {
            return text
        }
        throw FetchError.notText
    }
}

/// Serves canned HTML by URL. Used by previews and UI tests (see `LaunchOptions.stubPages`).
struct StubRecipeFetcher: RecipeFetching {
    var pages: [String: String]

    func fetchHTML(from url: URL) async throws -> String {
        try await Task.sleep(for: .milliseconds(150))
        guard let html = pages[url.absoluteString] else { throw FetchError.notFound }
        return html
    }
}
