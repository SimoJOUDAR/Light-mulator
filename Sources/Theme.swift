import AppKit
import SwiftUI

/// Design tokens, light and dark.
enum Theme {
    static let canvas = Color(light: 0xF2EEEA, dark: 0x0F0F0F)
    static let surface = Color(light: 0xF7F5F3, dark: 0x0F0F0F)
    static let card = Color(light: 0xFFFFFF, dark: 0x2D2B28)
    static let cardPressed = Color(light: 0xF2EEEA, dark: 0x45413E)
    static let tertiary = Color(light: 0xDDD9D5, dark: 0x53504C)
    static let divider = Color(light: 0xDDD9D5, dark: 0x45413E)
    static let dividerSoft = Color(light: 0xDDD9D5, dark: 0x45413E, alpha: 0.6)

    static let text = Color(light: 0x0F0F0F, dark: 0xFFFFFF)
    static let textSecondary = Color(light: 0x45413E, dark: 0xDDD9D5)
    static let placeholder = Color(light: 0x918C88, dark: 0xA49F9B)
    static let link = Color(light: 0x5168CC, dark: 0x9DB2FF)

    static let action = Color(light: 0x0F0F0F, dark: 0xFFFFFF)
    static let actionHover = Color(light: 0x393633, dark: 0xDDD9D5)
    static let actionPress = Color(light: 0x45413E, dark: 0xC4C0BC)
    static let actionDisabled = Color(light: 0xC4C0BC, dark: 0x45413E)
    static let onAction = Color(light: 0xFFFFFF, dark: 0x0F0F0F)
    static let secondaryAction = Color(light: 0xE7EEFF, dark: 0x263369)
    static let secondaryActionHover = Color(light: 0xCBD9FF, dark: 0x2F3E7D)
    static let onSecondaryAction = Color(light: 0x5168CC, dark: 0xE7EEFF)
    static let disabledText = Color(light: 0xA49F9B, dark: 0x53504C)
    static let disabledBorder = Color(light: 0xC4C0BC, dark: 0x45413E)
    static let toggleOff = Color(light: 0x726F6B, dark: 0x918C88)

    static let good = Color(light: 0x3D7D3E, dark: 0x6DAF6D)
    static let goodBackground = Color(light: 0xE6F3E6, dark: 0x173E18)
    static let goodText = Color(light: 0x173E18, dark: 0x8BEFA3)
    static let moderateBackground = Color(light: 0xFFEDBB, dark: 0x433506)
    static let moderateText = Color(light: 0x433506, dark: 0xFFD295)
    static let bad = Color(light: 0xCF3336, dark: 0xFF756F)
    static let badAction = Color(light: 0xCF3336, dark: 0xFB4F4E)
    static let badActionHover = Color(light: 0xFB4F4E, dark: 0xFF756F)
    static let badBackground = Color(light: 0xFFEAE6, dark: 0x4A1013)
    static let badText = Color(light: 0x6E0F14, dark: 0xFFB4AB)
    static let neutralTag = Color(light: 0xF2EEEA, dark: 0x232220)
    static let undefined = Color(light: 0xA49F9B, dark: 0x6E6A66)

    /// Monochromatic dataviz ramp, darkest first: one shade per running device.
    static let series = [
        Color(light: 0x5168CC, dark: 0xAABFFF),
        Color(light: 0x7F9BFF, dark: 0xE7EEFF),
        Color(light: 0x394B96, dark: 0x7F9BFF),
        Color(light: 0xAABFFF, dark: 0xE3E8F5),
        Color(light: 0x6784FE, dark: 0xCBD9FF),
    ]
    static let otherUse = Color(light: 0xA49F9B, dark: 0x918C88)
    static let otherDisk = Color(light: 0xC4C0BC, dark: 0x726F6B)
    static let track = Color(light: 0xDDD9D5, dark: 0x53504C)

    static let deviceFrame = Color(light: 0x0F0F0F, dark: 0x000000)
    static let deviceScreen = Color(light: 0x2D2B28, dark: 0x232220)
}

extension Color {
    init(light: UInt32, dark: UInt32, alpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha
            )
        })
    }
}

enum Format {
    private static let gibibyte = 1_073_741_824.0

    /// Memory in GB as Activity Monitor counts it (binary), one decimal.
    static func memory(_ bytes: UInt64) -> String { "\(memoryNumber(bytes)) GB" }
    static func memoryNumber(_ bytes: UInt64) -> String { decimal(Double(bytes) / gibibyte) }
    static func wholeMemory(_ bytes: UInt64) -> String { String(format: "%.0f GB", Double(bytes) / gibibyte) }

    /// Disk in GB as Finder counts it (decimal), one decimal.
    static func diskNumber(_ bytes: Int64) -> String { decimal(Double(bytes) / 1_000_000_000) }
    static func wholeDisk(_ bytes: Int64) -> String { String(format: "%.0f GB", Double(bytes) / 1_000_000_000) }

    /// One decimal with the user's separator, so "7,6 GB" matches Finder's sizes.
    static func decimal(_ value: Double) -> String { String(format: "%.1f", locale: .current, value) }

    static func runningFor(since start: Date, now: Date) -> String {
        let minutes = Int(now.timeIntervalSince(start) / 60)
        if minutes < 1 { return "Running for less than a minute" }
        if minutes < 60 { return "Running for \(minutes) min" }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "Running for \(hours) h" : "Running for \(hours) h \(minutes % 60) min"
    }
}

// MARK: - Text

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .medium))
            .tracking(0.9)
            .foregroundStyle(Theme.textSecondary)
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
    }
}

/// "13.9 GB of 16 GB used": the data style for a number with its unit.
struct BigNumber: View {
    let value: String
    let unit: String
    let caption: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value).font(.system(size: 26, weight: .bold)).monospacedDigit()
            Text(unit).font(.system(size: 14, weight: .heavy))
            Text(caption).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .foregroundStyle(Theme.text)
    }
}

// MARK: - Surfaces

extension View {
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider))
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

struct AppTag: View {
    enum Variant { case neutral, good, moderate, bad, info }
    let label: String
    var variant: Variant = .neutral

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .foregroundStyle(colors.fg)
            .background(colors.bg, in: RoundedRectangle(cornerRadius: 8))
    }

    private var colors: (bg: Color, fg: Color) {
        switch variant {
        case .neutral: (Theme.neutralTag, Theme.text)
        case .good: (Theme.goodBackground, Theme.goodText)
        case .moderate: (Theme.moderateBackground, Theme.moderateText)
        case .bad: (Theme.badBackground, Theme.badText)
        case .info: (Theme.secondaryAction, Color(light: 0x263369, dark: 0x9DB2FF))
        }
    }
}

/// A 8 pt bar split into proportional segments; whatever is left shows the track.
struct StackedBar: View {
    struct Segment: Identifiable {
        let id: String
        let value: Double
        let color: Color
    }

    let segments: [Segment]
    let total: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(segments.filter { $0.value > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(2, proxy.size.width * segment.value / max(total, 1) - 2))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8)
        .background(Theme.track)
        .clipShape(Capsule())
    }
}

struct LegendRow: View {
    let color: Color?
    let label: String
    let value: String
    var valueColor: Color = Theme.textSecondary

    var body: some View {
        HStack(spacing: 8) {
            if let color {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            } else {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.divider).frame(width: 8, height: 8)
            }
            Text(label).lineLimit(1).truncationMode(.tail).layoutPriority(1)
            Spacer(minLength: 6)
            Text(value).foregroundStyle(valueColor).monospacedDigit().fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.text)
    }
}

// MARK: - Controls

struct AppButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, outlined, ghost }
    enum Size { case medium, small }

    var variant: Variant = .primary
    var size: Size = .medium
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, style: self)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let style: AppButtonStyle
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            let colors = palette
            configuration.label
                .font(.system(size: style.size == .medium ? 13.5 : 12.5, weight: .medium))
                .lineLimit(1)
                .padding(.horizontal, style.size == .medium ? 14 : 10)
                .frame(minHeight: style.size == .medium ? 32 : 26)
                .foregroundStyle(colors.fg)
                .background(colors.bg, in: shape)
                .overlay(shape.strokeBorder(colors.border))
                .contentShape(shape)
                .onHover { hovering = $0 }
        }

        private var shape: RoundedRectangle {
            RoundedRectangle(cornerRadius: style.size == .medium ? 10 : 8)
        }

        private var state: Int { !isEnabled ? 0 : configuration.isPressed ? 3 : hovering ? 2 : 1 }

        private var palette: (bg: Color, fg: Color, border: Color) {
            let pressedOrHover = state >= 2
            switch (style.variant, style.destructive) {
            case (.primary, false):
                if state == 0 { return (Theme.actionDisabled, Theme.textSecondary, .clear) }
                return (state == 3 ? Theme.actionPress : state == 2 ? Theme.actionHover : Theme.action, Theme.onAction, .clear)
            case (.primary, true):
                if state == 0 { return (Theme.actionDisabled, Theme.textSecondary, .clear) }
                return (pressedOrHover ? Theme.badActionHover : Theme.badAction, .white, .clear)
            case (.secondary, false):
                if state == 0 { return (Theme.tertiary, Theme.placeholder, .clear) }
                return (pressedOrHover ? Theme.secondaryActionHover : Theme.secondaryAction, Theme.onSecondaryAction, .clear)
            case (.secondary, true):
                if state == 0 { return (Theme.tertiary, Theme.placeholder, .clear) }
                return (Theme.badBackground, Theme.bad, .clear)
            case (.outlined, let bad):
                if state == 0 { return (.clear, Theme.disabledText, Theme.disabledBorder) }
                let fg = bad ? Theme.bad : Theme.action
                return (pressedOrHover ? (bad ? Theme.badBackground : Theme.cardPressed) : .clear, fg, fg)
            case (.ghost, let bad):
                if state == 0 { return (.clear, Theme.disabledText, .clear) }
                return (pressedOrHover ? (bad ? Theme.badBackground : Theme.cardPressed) : .clear, bad ? Theme.bad : Theme.action, .clear)
            }
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static func app(
        _ variant: AppButtonStyle.Variant = .primary,
        size: AppButtonStyle.Size = .medium,
        destructive: Bool = false
    ) -> AppButtonStyle {
        AppButtonStyle(variant: variant, size: size, destructive: destructive)
    }
}

/// Desktop switch: 39 × 24, ink when on.
struct AppToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            HStack(spacing: 12) {
                configuration.label.frame(maxWidth: .infinity, alignment: .leading)
                Capsule()
                    .fill(isEnabled ? (configuration.isOn ? Theme.action : Theme.toggleOff) : Theme.actionDisabled)
                    .opacity(!configuration.isOn && isEnabled ? 0.85 : 1)
                    .frame(width: 39, height: 24)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .overlay(Circle().strokeBorder(Color(light: 0xDDD9D5, dark: 0x2D2B28)))
                            .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                            .frame(width: 21, height: 21)
                            .padding(1.5)
                    }
                    .animation(.easeOut(duration: 0.18), value: configuration.isOn)
                    .contentShape(Capsule())
                    .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityValue(configuration.isOn ? "On" : "Off")
            }
        }
    }
}

/// Segmented control, for a handful of short options.
struct AppSegmented<Value: Hashable>: View {
    let options: [Value]
    let selected: Value?
    let label: (Value) -> String
    let select: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selected
                Button { select(option) } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: isOn ? .semibold : .regular))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 24)
                        .foregroundStyle(isOn ? Theme.text : Theme.textSecondary)
                        .background {
                            if isOn {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Theme.card)
                                    .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.cardPressed, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// One line of a settings card, with the soft divider between lines.
struct SettingRow<Content: View>: View {
    var last = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.system(size: 13))
            .foregroundStyle(Theme.text)
            .padding(.vertical, 9)
            .overlay(alignment: .bottom) {
                if !last { Rectangle().fill(Theme.dividerSoft).frame(height: 1) }
            }
    }
}

struct DetailRow: View {
    let label: String
    let value: String?
    var last = false
    /// For identifiers: one line, cut in the middle, still selectable in full.
    var identifier = false

    var body: some View {
        if let value, !value.isEmpty {
            SettingRow(last: last) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(label).foregroundStyle(Theme.textSecondary).fixedSize()
                    Spacer(minLength: 8)
                    Text(value)
                        .font(identifier ? .system(size: 12, design: .monospaced) : nil)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                        .lineLimit(identifier ? 1 : 2)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

/// A square "⋯" button opening a menu, sized like a medium button.
struct MoreMenu<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Menu { content } label: {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 32, height: 32)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider))
        .help("More actions")
    }
}
