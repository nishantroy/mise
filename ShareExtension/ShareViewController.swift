import UIKit
import UniformTypeIdentifiers

/// Takes the first shared URL, queues it for the app, says so, and closes.
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
            if let url = await Self.firstURL(in: providers) {
                PendingImports.append(url)
                finish(message: "Saved. Open Mise to finish importing.")
            } else {
                finish(message: "There's no link to save here.")
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

    /// First `public.url` attachment, falling back to a URL inside shared plain text.
    private static func firstURL(in providers: [NSItemProvider]) async -> URL? {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadURL(provider), url.scheme?.hasPrefix("http") == true { return url }
        }
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(provider),
               let match = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
                .firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let url = match.url {
                return url
            }
        }
        return nil
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
