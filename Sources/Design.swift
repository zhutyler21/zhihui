import SwiftUI
import AppKit

enum Design {
    enum Spacing {
        static let sidebarInset: CGFloat = 20
        static let listInset: CGFloat = 20
        static let contentInset: CGFloat = 24
    }
    enum Typography {
        static let body = Font.system(size: 16)
        static let callout = Font.system(size: 15)
        static let caption = Font.system(size: 13)
        static let headline = Font.system(size: 17, weight: .semibold)
        static let title3 = Font.system(size: 20, weight: .semibold, design: .rounded)
        static let title2 = Font.system(size: 24, weight: .semibold, design: .rounded)
        static let title = Font.system(size: 28, weight: .semibold, design: .rounded)
        static let largeTitle = Font.system(size: 32, weight: .semibold, design: .rounded)
    }
    private static func adaptive(_ name: String, light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("Zhihui." + name)) { appearance in
            let match = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])
            let value = match == .darkAqua || match == .accessibilityHighContrastDarkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
    static let accent = adaptive("seaSaltBlue", light: 0x365CBA, dark: 0xA9C4FF)
    static let accentFill = adaptive("seaSaltBlueFill", light: 0x365CBA, dark: 0x496BC6)
    static let teal = adaptive("teal", light: 0x247C78, dark: 0x7CD4C9)
    static let success = adaptive("modelReady", light: 0x2C735A, dark: 0x80C8AC)
    static let ink = Color(nsColor: .labelColor)
    static let muted = adaptive("secondaryText", light: 0x5B687A, dark: 0xBDC8D7)
    static let canvas = adaptive("canvas", light: 0xF7F8FA, dark: 0x202831)
    static let surface = Color(nsColor: .textBackgroundColor)
    static let soft = adaptive("subtleSurface", light: 0xF0F4FA, dark: 0x293446)
    static let line = Color(nsColor: .separatorColor)
    static let selection = adaptive("selection", light: 0xE4EDFC, dark: 0x344767)
    static let recording = Color(nsColor: .systemRed)
}

/// Native control styles retain macOS focus, pressed, disabled and keyboard-default behavior.
struct PrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .font(Design.Typography.callout.weight(.medium)).tint(Design.accentFill)
    }
}
struct QuietButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) { configuration.label }
            .buttonStyle(.bordered).controlSize(.regular)
            .font(Design.Typography.callout.weight(.medium)).tint(Design.accent)
    }
}
struct EmptyState: View {
    var icon: String; var title: String; var message: String
    var fillsSpace = true
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
                .symbolRenderingMode(.hierarchical).foregroundStyle(Design.accent)
                .font(Design.Typography.title3)
        } description: {
            Text(message).font(Design.Typography.body).foregroundStyle(Design.muted).lineSpacing(6).frame(maxWidth: 390)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: fillsSpace ? .infinity : nil)
    }
}
struct BrandMark: View {
    private let bars: [(id: String, height: CGFloat)] = [("first", 12), ("second", 24), ("third", 30), ("fourth", 18)]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(bars, id: \.id) { bar in
                RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 4, height: bar.height)
            }
        }
        .frame(width: 40, height: 40)
        .background(Design.accentFill, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
