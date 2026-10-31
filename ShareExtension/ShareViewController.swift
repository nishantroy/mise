import UIKit
import UniformTypeIdentifiers

/// Takes a shared web link or recipe text (e.g. from the claude.ai app), queues it for the app,
/// says so, and closes.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let icon = UIImageView()
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var started = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black.withAlphaComponent(0.2)

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 16
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        icon.image = UIImage(systemName: "fork.knife")
        icon.tintColor = .tintColor
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .title1)
        icon.isAccessibilityElement = false

        label.font = UIFont.preferredFont(forTextStyle: .headline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        label.textAlignment = .center
        label.text = "Saving to Mise…"

        spinner.startAnimating()

        let stack = UIStackView(arrangedSubviews: [icon, label, spinner])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.layoutMarginsGuide.leadingAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { @MainActor in
            switch await Self.sharedItem(in: providers) {
            case .url(let url)?:
                PendingImports.append(url)
                finish(message: "Saved. Open Mise to finish importing.")
            case .text(_, let text)?:
                PendingImports.appendText(text)
                finish(message: "Saved. Open Mise to add it as a recipe or as your version of one.")
            case nil:
                finish(message: "There's nothing to save here.")
            }
        }
    }

    private func finish(message: String) {
        spinner.stopAnimating()
        spinner.isHidden = true
        label.text = message
        UIAccessibility.post(notification: .announcement, argument: message)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    /// Recipe-like text (several lines, or long) wins, so a write-up shared together with a chat
    /// link is kept as text. Otherwise the first `public.url` attachment, then a link inside
    /// short shared text, then any other non-empty text.
    private static func sharedItem(in providers: [NSItemProvider]) async -> PendingItem? {
        var texts: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            && !provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let text = await loadText(provider)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                texts.append(text)
            }
        }
        if let recipe = texts.first(where: isRecipeLike) { return .text(id: UUID().uuidString, text: recipe) }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider), url.scheme?.hasPrefix("http") == true { return .url(url) }
        }
        for text in texts {
            if let match = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let url = match.url, url.scheme?.hasPrefix("http") == true {
                return .url(url)
            }
        }
        return texts.first.map { .text(id: UUID().uuidString, text: $0) }
    }

    /// At least three non-empty lines, or 120+ characters that aren't just a link.
    static func isRecipeLike(_ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count >= 3 { return true }
        return text.count >= 120 && URL(string: text)?.scheme == nil
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
    }
}
