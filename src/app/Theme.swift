// Fonts, colours and spacing. Everything scales with the body size, which the zoom commands change.

import AppKit

struct Theme {
    /// The body text size in points.
    let size: CGFloat

    static let defaultSize: CGFloat = 15

    init(zoom: CGFloat) {
        size = (Theme.defaultSize * zoom).rounded()
    }

    /// Latin Modern's x-height is about 0.83 of SF Pro's, so formulas are set 1.21 times larger to
    /// sit level with the text around them (the same ratio KaTeX uses).
    var mathSize: CGFloat { (size * 1.21).rounded() }
    var lineHeightMultiple: CGFloat { 1.22 }
    var paragraphSpacing: CGFloat { (size * 0.8).rounded() }
    /// The widest the text column grows, about 75 characters.
    var columnWidth: CGFloat { (size * 46).rounded() }
    var listIndent: CGFloat { (size * 1.6).rounded() }

    func headingSize(_ level: Int) -> CGFloat {
        let scale: [CGFloat] = [2.0, 1.55, 1.27, 1.1, 1.0, 0.9]
        return (size * scale[max(0, min(5, level - 1))]).rounded()
    }

    func headingWeight(_ level: Int) -> NSFont.Weight {
        level <= 2 ? .bold : .semibold
    }

    // MARK: Fonts

    func font(size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, monospaced: Bool = false) -> NSFont {
        let base = monospaced ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        guard italic else { return base }
        let descriptor = base.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    // MARK: Colours (all dynamic, so light and dark mode follow the system)

    static let text = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    static let link = NSColor.linkColor
    static let rule = NSColor.separatorColor
    static let codeBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.075) : NSColor(white: 0, alpha: 0.045)
    }
    static let tableHeaderBackground = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.03)
    }
    static let highlight = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemYellow.withAlphaComponent(0.32) : NSColor.systemYellow.withAlphaComponent(0.38)
    }

    static func alertColor(_ kind: String) -> NSColor {
        switch kind {
        case "tip": return .systemGreen
        case "important": return .systemPurple
        case "warning": return .systemOrange
        case "caution": return .systemRed
        default: return .systemBlue
        }
    }

    static func alertTitle(_ kind: String) -> String {
        switch kind {
        case "tip": return "Tip"
        case "important": return "Important"
        case "warning": return "Warning"
        case "caution": return "Caution"
        default: return "Note"
        }
    }

    static func alertSymbol(_ kind: String) -> String {
        switch kind {
        case "tip": return "lightbulb"
        case "important": return "exclamationmark.bubble"
        case "warning": return "exclamationmark.triangle"
        case "caution": return "exclamationmark.octagon"
        default: return "info.circle"
        }
    }
}

extension NSAttributedString.Key {
    /// Marks inline code, which gets a rounded background.
    static let markyCode = NSAttributedString.Key("MarkyCode")
    /// Marks ==highlighted== text.
    static let markyHighlight = NSAttributedString.Key("MarkyHighlight")
    /// A heading's anchor, for links such as [see](#limits).
    static let markyAnchor = NSAttributedString.Key("MarkyAnchor")
}
