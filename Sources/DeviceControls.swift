import SwiftUI

private let tileColumns = [GridItem(.adaptive(minimum: 84), spacing: 8)]

/// Android Studio's Running Devices toolbar, same buttons in the same order, as a grid of tiles.
struct AndroidControlsCard: View {
    @EnvironmentObject private var store: Store
    let id: String
    let name: String
    let device: DeviceShell
    @State private var showKeyboard = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Controls")
                Spacer()
                Text("Right-click Power for the power menu").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            LazyVGrid(columns: tileColumns, spacing: 8) {
                ControlTile("power", "Power") { await press("KEYCODE_POWER") }
                    .contextMenu {
                        Button("Power Menu (long press)") {
                            Task {
                                await device.longPress("KEYCODE_POWER")
                                store.refreshPreviewSoon(id, device)
                            }
                        }
                    }
                ControlTile("speaker.plus", "Volume up") { await press("KEYCODE_VOLUME_UP") }
                ControlTile("speaker.minus", "Volume down") { await press("KEYCODE_VOLUME_DOWN") }
                ControlTile("rotate.left", "Rotate left", help: rotateHelp("Rotate left")) {
                    await device.rotate(clockwise: false)
                    store.refreshPreviewSoon(id, device, delay: 1.2)
                }
                ControlTile("rotate.right", "Rotate right", help: rotateHelp("Rotate right")) {
                    await device.rotate(clockwise: true)
                    store.refreshPreviewSoon(id, device, delay: 1.2)
                }
                ControlTile("arrowtriangle.left", "Back") { await press("KEYCODE_BACK") }
                ControlTile("circle", "Home") { await press("KEYCODE_HOME") }
                ControlTile("square", "Overview") { await press("KEYCODE_APP_SWITCH") }
                ControlTile("keyboard", "Type text") { showKeyboard.toggle() }
                    .popover(isPresented: $showKeyboard, arrowEdge: .bottom) { TypeTextView(device: device) }
                ControlTile("camera", "Screenshot", help: "Saved to the Desktop and copied") { store.screenshot(device, name: name) }
                RecordTile(startedAt: store.recordings[id], limit: "3 min max") {
                    store.toggleRecording(device, id: id, name: name)
                }
            }
        }
        .card()
    }

    private func rotateHelp(_ title: String) -> String {
        device.isEmulator ? title : "\(title). Turns auto-rotate off on the device."
    }

    private func press(_ key: String) async {
        await device.key(key)
        store.refreshPreviewSoon(id, device)
    }
}

struct ControlTile: View {
    let symbol: String
    let title: String
    let help: String?
    let action: () async -> Void

    init(_ symbol: String, _ title: String, help: String? = nil, action: @escaping () async -> Void) {
        self.symbol = symbol
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button { Task { await action() } } label: {
            TileLabel(symbol: symbol, title: title)
        }
        .buttonStyle(TileButtonStyle())
        .help(help ?? title)
    }
}

struct RecordTile: View {
    let startedAt: Date?
    let limit: String?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    TileLabel(symbol: "stop.circle.fill", title: String(format: "Stop %d:%02d", seconds / 60, seconds % 60))
                        .foregroundStyle(Theme.bad)
                }
            } else {
                TileLabel(symbol: "record.circle", title: "Record")
            }
        }
        .buttonStyle(TileButtonStyle(highlighted: startedAt != nil))
        .help(startedAt == nil
            ? "Record the screen\(limit.map { " (\($0))" } ?? ""), saved to the Desktop"
            : "Stop recording, saved to the Desktop")
    }
}

private struct TileLabel: View {
    let symbol: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 17)).frame(height: 20)
            Text(title).font(.system(size: 11.5)).lineLimit(1).monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .padding(.horizontal, 4)
    }
}

private struct TileButtonStyle: ButtonStyle {
    var highlighted = false

    func makeBody(configuration: Configuration) -> some View {
        Tile(configuration: configuration, highlighted: highlighted)
    }

    private struct Tile: View {
        let configuration: Configuration
        let highlighted: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Theme.text)
                .background(background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(highlighted ? Theme.bad : Theme.divider))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 }
        }

        private var background: Color {
            if highlighted { return Theme.badBackground }
            if configuration.isPressed { return Theme.tertiary }
            return hovering ? Theme.cardPressed : Theme.surface
        }
    }
}

// MARK: - Device UI

/// Android Studio's Device UI Shortcuts, applied live through adb.
struct AndroidUICard: View {
    let device: DeviceShell
    let apiLevel: Int?
    /// A personal phone has no defaults to reset to, and its rotation tiles turn auto-rotate off.
    var physical = false
    @State private var settings: UISettings?

    private static let locales: [(tag: String, name: String)] = [
        ("", "System default"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("fr-FR", "Français"),
        ("de-DE", "Deutsch"), ("es-ES", "Español"), ("it-IT", "Italiano"), ("pt-BR", "Português (Brasil)"),
        ("nl-NL", "Nederlands"), ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("zh-CN", "中文 (简体)"),
        ("ar-EG", "العربية (RTL)"), ("en-XA", "Pseudo — accented"), ("ar-XB", "Pseudo — bidi"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                CardTitle("Device UI")
                Spacer()
                if let settings, !physical {
                    Button("Reset") { reset(settings) }
                        .buttonStyle(.app(.ghost, size: .small))
                        .help("Light theme, 100 % font, default display size, no layout bounds, app language back to the system’s")
                }
            }
            .padding(.bottom, 4)
            if let settings {
                content(settings)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .toggleStyle(AppToggleStyle())
        .card()
        .task(id: device.serial) { settings = await device.readUISettings(apiLevel: apiLevel) }
    }

    @ViewBuilder
    private func content(_ current: UISettings) -> some View {
        SettingRow { Toggle("Dark theme", isOn: bind(\.darkTheme) { await device.setDarkTheme($0) }) }
        SettingRow { Toggle("Gesture navigation", isOn: bind(\.gestureNavigation) { await device.setGestureNavigation($0) }) }
        SettingRow { Toggle("Layout bounds", isOn: bind(\.layoutBounds) { await device.setLayoutBounds($0) }) }
        if physical {
            SettingRow { Toggle("Auto-rotate", isOn: bind(\.autoRotate) { await device.setAutoRotate($0) }) }
        }
        if current.hasTalkBack {
            SettingRow {
                Toggle("TalkBack", isOn: bind(\.talkBack) { await device.setAccessibilityService(DeviceShell.talkBack, enabled: $0) })
            }
            SettingRow {
                Toggle("Select to Speak", isOn: bind(\.selectToSpeak) {
                    await device.setAccessibilityService(DeviceShell.selectToSpeak, enabled: $0)
                })
            }
        }
        SettingRow {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Font size")
                    Spacer()
                    Text("\(Int((current.fontScale * 100).rounded())) %").foregroundStyle(Theme.textSecondary).monospacedDigit()
                }
                AppSegmented(
                    options: current.fontScales,
                    selected: current.fontScales.min { abs($0 - current.fontScale) < abs($1 - current.fontScale) },
                    label: { "\(Int(($0 * 100).rounded()))" }
                ) { scale in
                    settings?.fontScale = scale
                    Task { await device.setFontScale(scale) }
                }
            }
        }
        SettingRow(last: current.foregroundPackage == nil) {
            Stepped(
                title: "Display size",
                values: current.densities.map(Double.init),
                selected: Double(current.density),
                label: { Int($0) == current.physicalDensity ? "Default (\(Int($0)) dpi)" : "\(Int($0)) dpi" }
            ) { density in
                settings?.density = Int(density)
                Task { await device.setDensity(Int(density), physical: current.physicalDensity) }
            }
        }
        if let package = current.foregroundPackage {
            SettingRow(last: true) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("App language").fixedSize()
                        Text(package).font(.system(size: 11)).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Picker("App language", selection: bind(\.appLocale) { await device.setAppLocale(package, $0) }) {
                        ForEach(Self.locales, id: \.tag) { Text($0.name).tag($0.tag) }
                        if !Self.locales.contains(where: { $0.tag == current.appLocale }) {
                            Text(current.appLocale).tag(current.appLocale)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private func bind<Value>(_ path: WritableKeyPath<UISettings, Value>, apply: @escaping (Value) async -> Void) -> Binding<Value> {
        Binding(
            get: { settings![keyPath: path] },
            set: { value in
                settings?[keyPath: path] = value
                Task { await apply(value) }
            }
        )
    }

    private func reset(_ current: UISettings) {
        settings?.darkTheme = false
        settings?.fontScale = 1.0
        settings?.density = current.physicalDensity
        settings?.layoutBounds = false
        settings?.appLocale = ""
        Task {
            await device.setDarkTheme(false)
            await device.setFontScale(1.0)
            await device.setDensity(current.physicalDensity, physical: current.physicalDensity)
            await device.setLayoutBounds(false)
            if let package = current.foregroundPackage { await device.setAppLocale(package, "") }
        }
    }
}

/// A slider that snaps to the given values and applies on release, like the Android settings it mirrors.
struct Stepped: View {
    let title: String
    let values: [Double]
    let selected: Double
    let label: (Double) -> String
    let apply: (Double) -> Void
    @State private var index: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(label(values[Int(index)])).foregroundStyle(Theme.textSecondary).monospacedDigit()
            }
            Slider(value: $index, in: 0...Double(max(values.count - 1, 1)), step: 1) { editing in
                if !editing { apply(values[Int(index)]) }
            }
            .controlSize(.small)
            .tint(Theme.action)
            .disabled(values.count < 2)
        }
        .onAppear {
            let nearest = values.enumerated().min { abs($0.element - selected) < abs($1.element - selected) }
            index = Double(nearest?.offset ?? 0)
        }
    }
}

struct TypeTextView: View {
    let device: DeviceShell
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Type on the device").font(.headline)
            HStack {
                TextField("Text for the focused field", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(send)
                Button("Send", action: send).disabled(text.isEmpty)
            }
            HStack(spacing: 6) {
                key("Enter", "KEYCODE_ENTER")
                key("Tab", "KEYCODE_TAB")
                key("Delete", "KEYCODE_DEL")
                key("Paste", "KEYCODE_PASTE")
            }
            Text("ASCII only. The emulator window itself also takes your Mac keyboard directly.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }

    private func send() {
        guard !text.isEmpty else { return }
        let value = text
        text = ""
        Task { await device.typeText(value) }
    }

    private func key(_ title: String, _ code: String) -> some View {
        Button(title) { Task { await device.key(code) } }
    }
}

// MARK: - iPhone and iPad

/// What devicectl can press on a real iPhone or iPad, as far as its iOS version allows. Home and Lock stay on the device.
struct IOSControlsCard: View {
    @EnvironmentObject private var store: Store
    let device: IOSDevice
    let control: IOSDeviceControl
    let info: IOSDeviceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("Controls")
                Spacer()
                if !info.canShareScreen {
                    Text("Control from the Mac and screen recording need iOS 27").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                } else if !info.supports(IOSDeviceInfo.screenRecording) {
                    Text("Screen recording isn’t available on this device").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            LazyVGrid(columns: tileColumns, spacing: 8) {
                if info.supports(IOSDeviceInfo.orientation) {
                    ControlTile("rotate.left", "Rotate left") {
                        await control.rotate(clockwise: false)
                        store.refreshPreviewSoon(device)
                    }
                    ControlTile("rotate.right", "Rotate right") {
                        await control.rotate(clockwise: true)
                        store.refreshPreviewSoon(device)
                    }
                }
                if info.supports(IOSDeviceInfo.screenshot) {
                    ControlTile("camera", "Screenshot", help: "Saved to the Desktop and copied") { store.screenshot(device) }
                }
                if info.supports(IOSDeviceInfo.screenRecording) {
                    RecordTile(startedAt: store.recordings[device.id], limit: nil) { store.toggleRecording(device) }
                }
            }
            if info.supports(IOSDeviceInfo.pasteboard) {
                SettingRow(last: true) {
                    Toggle(isOn: Binding(
                        get: { store.sharingClipboard.contains(device.id) },
                        set: { _ in store.toggleSharedClipboard(device) }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Shared clipboard")
                            Text("Copy on the Mac, paste on the device, and back. Starts by sending the Mac’s clipboard.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .toggleStyle(AppToggleStyle())
                }
            }
        }
        .card()
    }
}

/// The accessibility and appearance settings devicectl can change, applied live.
struct IOSUICard: View {
    @EnvironmentObject private var store: Store
    let device: IOSDevice
    let control: IOSDeviceControl
    let info: IOSDeviceInfo
    @State private var settings: IOSUISettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("Device UI").padding(.bottom, 4)
            if let settings {
                let appearance = info.supports(IOSDeviceInfo.appearance)
                if appearance {
                    SettingRow {
                        Toggle("Dark appearance", isOn: bind(\.dark) { await control.setAppearance("--mode", $0 ? "dark" : "light") })
                    }
                    SettingRow {
                        Toggle("Increase contrast", isOn: bind(\.increaseContrast) {
                            await control.setAppearance("--increase-contrast", $0 ? "on" : "off")
                        })
                    }
                    SettingRow {
                        Toggle("Reduce motion", isOn: bind(\.reduceMotion) {
                            await control.setAppearance("--reduce-motion", $0 ? "on" : "off")
                        })
                    }
                }
                if info.supports(IOSDeviceInfo.voiceOver) {
                    SettingRow(last: !appearance && settings != IOSUISettings()) {
                        Toggle("VoiceOver", isOn: bind(\.voiceOver) { await control.setVoiceOver($0) })
                    }
                }
                if appearance {
                    SettingRow(last: settings != IOSUISettings()) {
                        let sizes = IOSUISettings.textSizes
                        Stepped(
                            title: "Text size",
                            values: sizes.indices.map(Double.init),
                            selected: Double(sizes.firstIndex(of: settings.textSize ?? "large") ?? 3),
                            label: { Self.sizeLabel(sizes[Int($0)]) }
                        ) { index in
                            self.settings?.textSize = sizes[Int(index)]
                            Task {
                                await control.setAppearance("--text-size", sizes[Int(index)])
                                store.refreshPreviewSoon(device)
                            }
                        }
                    }
                }
                if settings == IOSUISettings() {
                    Text("The device didn’t report its current settings: switches show off until you set them here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .toggleStyle(AppToggleStyle())
        .card()
        .task(id: control.udid) { settings = await control.readUISettings() }
    }

    private static func sizeLabel(_ size: String) -> String {
        size == "large" ? "Default" : size.split(separator: "-").map { $0.capitalized }.joined(separator: " ")
    }

    /// A setting devicectl didn't report shows as off until it is set from here.
    private func bind(_ path: WritableKeyPath<IOSUISettings, Bool?>, apply: @escaping (Bool) async -> Void) -> Binding<Bool> {
        Binding(
            get: { settings?[keyPath: path] ?? false },
            set: { value in
                settings?[keyPath: path] = value
                Task {
                    await apply(value)
                    store.refreshPreviewSoon(device)
                }
            }
        )
    }
}
