import AppKit

enum ProviderArtwork {
    private static var resourceBundle: Bundle {
        // SwiftPM's generated accessor looks beside the executable bundle. Packaged
        // apps keep their assets in Contents/Resources, including on another Mac.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AIUsage_AIUsage.bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return .module
    }

    private static let images: [Provider: NSImage] = Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
        guard let url = resourceBundle.url(forResource: provider.rawValue, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            preconditionFailure("Missing bundled artwork for \(provider.rawValue)")
        }
        let circular = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { bounds in
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: bounds).addClip()
            // The Codex app icon includes outer transparent macOS icon padding.
            // Draw its inner tile into the circle so it reads as a circular badge.
            let source = provider == .codex
                ? CGRect(origin: .zero, size: image.size).insetBy(dx: image.size.width * 0.10, dy: image.size.height * 0.10)
                : CGRect(origin: .zero, size: image.size)
            image.draw(in: bounds, from: source, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return (provider, circular)
    })

    static func image(_ provider: Provider) -> NSImage { images[provider]! }
}

enum MenuBarLabel {
    static func make(style: ProviderLabelStyle, percentage: (Provider) -> String) -> NSAttributedString {
        let label = NSMutableAttributedString()
        let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        for (index, provider) in Provider.allCases.enumerated() {
            if index > 0 { label.append(NSAttributedString(string: "  ·  ", attributes: attributes)) }
            if style.showsIcons {
                let attachment = NSTextAttachment()
                attachment.image = ProviderArtwork.image(provider)
                attachment.bounds = CGRect(x: 0, y: -3, width: 16, height: 16)
                label.append(NSAttributedString(attachment: attachment))
                label.append(NSAttributedString(string: " ", attributes: attributes))
            }
            let abbreviation = provider == .codex ? "CX" : "CL"
            label.append(NSAttributedString(string: (style.showsLetters ? "\(abbreviation) " : "") + percentage(provider), attributes: attributes))
        }
        return label
    }
}
