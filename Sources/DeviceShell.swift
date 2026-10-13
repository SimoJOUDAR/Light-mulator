import Foundation

/// Android Studio's Running Devices toolbar, done with `adb` against one running emulator or connected device.
struct DeviceShell: Sendable {
    let adb: String
    let serial: String

    static let talkBack = "com.google.android.marvin.talkback/com.google.android.marvin.talkback.TalkBackService"
    static let selectToSpeak = "com.google.android.marvin.talkback/com.google.android.accessibility.selecttospeak.SelectToSpeakService"

    @discardableResult
    func shell(_ command: String, timeout: TimeInterval = 10) async -> String {
        await Shell.run(adb, ["-s", serial, "shell", command], timeout: timeout).output
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func key(_ code: String) async {
        await shell("input keyevent \(code)")
    }

    func longPress(_ code: String) async {
        await shell("input keyevent --longpress \(code)")
    }

    /// The console's `rotate` only turns clockwise: a left turn is three of them.
    /// A real device has no console: its rotation gets locked, as the auto-rotate tile would.
    func rotate(clockwise: Bool) async {
        guard isEmulator else {
            let current = Int(await shell("dumpsys window displays | grep -m1 -oE 'mRotation=[0-3]' | cut -d= -f2")) ?? 0
            let next = (current + (clockwise ? 3 : 1)) % 4
            await shell("settings put system accelerometer_rotation 0; settings put system user_rotation \(next)")
            return
        }
        for _ in 0..<(clockwise ? 1 : 3) {
            _ = await Shell.run(adb, ["-s", serial, "emu", "rotate"], timeout: 5)
        }
    }

    func screenshot(to url: URL) async -> Bool {
        let status = await Shell.run(adb, ["-s", serial, "exec-out", "screencap", "-p"], writingTo: url, timeout: 20)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return status == 0 && size > 0
    }

    func typeText(_ text: String) async {
        let spaced = text.replacingOccurrences(of: " ", with: "%s")
        await shell("input text '\(spaced.replacingOccurrences(of: "'", with: "'\\''"))'")
    }

    // MARK: Device UI Shortcuts

    func readUISettings(apiLevel: Int?) async -> UISettings {
        async let night = shell("cmd uimode night")
        async let navigation = shell("settings get secure navigation_mode")
        async let fontScale = shell("settings get system font_scale")
        async let density = shell("wm density")
        async let size = shell("wm size")
        async let layoutBounds = shell("getprop debug.layout")
        async let talkBackPackage = shell("pm list packages com.google.android.marvin.talkback")
        async let services = shell("settings get secure enabled_accessibility_services")
        async let activity = shell("dumpsys activity activities | grep -m1 -E 'topResumedActivity|mResumedActivity'")
        async let autoRotate = shell("settings get system accelerometer_rotation")

        let physical = Self.number(after: "Physical density:", in: await density) ?? 420
        let current = Self.number(after: "Override density:", in: await density) ?? physical
        let sizeText = await size
        let dimensions = (sizeText.components(separatedBy: "Physical size:").last ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix { $0 != "\n" }
            .split(separator: "x")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let enabled = await services
        let package = Self.foregroundPackage(await activity)
        var locale = ""
        if let package { locale = await appLocale(package) }

        return UISettings(
            darkTheme: (await night).hasSuffix("yes"),
            gestureNavigation: await navigation == "2",
            fontScale: Double(await fontScale) ?? 1.0,
            fontScales: (apiLevel ?? 34) >= 34 ? [0.85, 1.0, 1.15, 1.3, 1.5, 1.8, 2.0] : [0.85, 1.0, 1.15, 1.3],
            density: current,
            densities: Self.densitySteps(physical: physical, shortSide: dimensions.min()),
            physicalDensity: physical,
            layoutBounds: await layoutBounds == "true",
            autoRotate: await autoRotate == "1",
            hasTalkBack: (await talkBackPackage).contains("package:"),
            talkBack: enabled.contains(Self.talkBack),
            selectToSpeak: enabled.contains(Self.selectToSpeak),
            foregroundPackage: (apiLevel ?? 33) >= 33 ? package : nil,
            appLocale: locale
        )
    }

    func setDarkTheme(_ on: Bool) async {
        await shell("cmd uimode night \(on ? "yes" : "no")")
    }

    func setGestureNavigation(_ on: Bool) async {
        let overlay = on ? "gestural" : "threebutton"
        await shell("cmd overlay enable-exclusive --category com.android.internal.systemui.navbar.\(overlay)")
    }

    func setFontScale(_ scale: Double) async {
        await shell("settings put system font_scale \(scale)")
    }

    func setDensity(_ density: Int, physical: Int) async {
        await shell(density == physical ? "wm density reset" : "wm density \(density)")
    }

    func setAutoRotate(_ on: Bool) async {
        await shell("settings put system accelerometer_rotation \(on ? 1 : 0)")
    }

    func setLayoutBounds(_ on: Bool) async {
        // The transaction code makes running apps re-read system properties, as Developer options does.
        await shell("setprop debug.layout \(on); service call activity 1599295570")
    }

    func setAccessibilityService(_ service: String, enabled: Bool) async {
        let current = await shell("settings get secure enabled_accessibility_services")
        var list = current == "null" ? [] : current.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        list.removeAll { $0 == service }
        if enabled { list.append(service) }
        if list.isEmpty {
            await shell("settings delete secure enabled_accessibility_services; settings put secure accessibility_enabled 0")
        } else {
            await shell("settings put secure enabled_accessibility_services '\(list.joined(separator: ":"))'; settings put secure accessibility_enabled 1")
        }
    }

    func appLocale(_ package: String) async -> String {
        let output = await shell("cmd locale get-app-locales \(package)")
        guard let open = output.lastIndex(of: "["), let close = output.lastIndex(of: "]"), open < close else { return "" }
        return String(output[output.index(after: open)..<close]).split(separator: ",").first.map(String.init) ?? ""
    }

    func setAppLocale(_ package: String, _ tag: String) async {
        await shell("cmd locale set-app-locales \(package) --locales '\(tag)'")
    }

    private static func number(after label: String, in text: String) -> Int? {
        guard let range = text.range(of: label) else { return nil }
        return Int(text[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
    }

    private static func foregroundPackage(_ line: String) -> String? {
        line.split(separator: " ").first { $0.contains("/") }.map { String($0.split(separator: "/")[0]) }
    }

    /// Like Settings › Display size: one smaller step, then up to three larger ones, never below 320 dp wide.
    private static func densitySteps(physical: Int, shortSide: Int?) -> [Int] {
        var steps = [Int((Double(physical) * 0.85).rounded()), physical]
        let ceiling = min(Int(Double(physical) * 1.5), (shortSide ?? physical * 2) * 160 / 320)
        if ceiling > physical {
            steps += (1...3).map { physical + (ceiling - physical) * $0 / 3 }
        }
        return Array(Set(steps)).sorted()
    }
}

struct UISettings {
    var darkTheme: Bool
    var gestureNavigation: Bool
    var fontScale: Double
    let fontScales: [Double]
    var density: Int
    let densities: [Int]
    let physicalDensity: Int
    var layoutBounds: Bool
    var autoRotate: Bool
    let hasTalkBack: Bool
    var talkBack: Bool
    var selectToSpeak: Bool
    let foregroundPackage: String?
    var appLocale: String
}
