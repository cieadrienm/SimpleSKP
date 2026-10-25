import AppKit
import SwiftUI

/// The dark palette of the Simple family (SimpleAudio, SimplePJ, SimpleText).
enum Theme {
    static let background = NSColor(hex: 0x111317)
    static let panel = NSColor(hex: 0x16191E)
    static let header = NSColor(hex: 0x14171C)
    static let separator = NSColor(hex: 0x0B0C0F)
    static let text = NSColor(hex: 0xE6E8EC)
    static let textDim = NSColor(hex: 0x8A919E)
    static let textFaint = NSColor(hex: 0x565D6A)
    static let accent = NSColor(hex: 0xFFB454)
    static let alive = NSColor(hex: 0x9ECE6A)
    static let warning = NSColor(hex: 0xF2D96B)
    static let danger = NSColor(hex: 0xFF5C57)
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat(hex >> 16 & 0xff) / 255,
            green: CGFloat(hex >> 8 & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }

    var swiftUI: Color { Color(nsColor: self) }
}
