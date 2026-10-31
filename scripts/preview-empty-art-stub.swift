// The slice of Grove's design system that GroveEmptyArt.swift touches, restated
// for macOS so `scripts/preview-empty-art.swift` can compile the real artwork
// outside the app target.
//
// The app's own GroveTheme is UIKit-backed and therefore iOS-only. These values
// are copied from Grove/DesignSystem.swift — if a colour there changes, the
// contact sheet drifts from the app until it is copied here too. That is an
// acceptable trade for a dev-only preview tool, and the same one
// generate-launch-mark.swift already makes.
//
// Every colour is a computed `var` resolved against `GrovePreviewAppearance`
// rather than a dynamic `NSColor`: `ImageRenderer` resolves SwiftUI colours
// against its own environment and never consults the current NSAppearance, so
// the dynamic-provider approach silently rendered two identical light sheets.

import AppKit
import SwiftUI

enum GrovePreviewAppearance {
    /// Flipped by the renderer between the two passes. Read on the main actor
    /// only, while the sheet for that pass is being produced.
    nonisolated(unsafe) static var isDark = false
}

enum GroveTheme {
    static func adaptive(light: UInt, dark: UInt) -> Color {
        Color(nsColor: NSColor(hex: GrovePreviewAppearance.isDark ? dark : light))
    }

    static var background: Color { adaptive(light: 0xF4F2EC, dark: 0x14130F) }
    static var surface: Color { adaptive(light: 0xFCFBF7, dark: 0x201E18) }
    static var ink: Color { adaptive(light: 0x14130F, dark: 0xF4F2EC) }
    static var mutedInk: Color { adaptive(light: 0x6E6B60, dark: 0xA6A296) }
    static var subtleInk: Color { adaptive(light: 0x9C988B, dark: 0x726E63) }
    static var accent: Color { adaptive(light: 0x3F9128, dark: 0x6FC04A) }
    static var accentStrong: Color { adaptive(light: 0x2C6B1C, dark: 0x8FD46E) }
    static var softAccent: Color { adaptive(light: 0xE4EFDB, dark: 0x1E2A16) }
    static var warning: Color { adaptive(light: 0xB4791C, dark: 0xE0A94C) }
    static var gold: Color { adaptive(light: 0xF0BC33, dark: 0xE6B02E) }
}

enum GroveMotion {
    static let reveal = Animation.spring(response: 0.55, dampingFraction: 0.85)
    static let pop = Animation.spring(response: 0.34, dampingFraction: 0.55)
}

private extension NSColor {
    convenience init(hex: UInt) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
