import SwiftUI

@main
struct LightmulatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store()

    var body: some Scene {
        Window("Light-mulator", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 620)
        }
        .defaultSize(width: 1260, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("Refresh") { store.reload() }.keyboardShortcut("r")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
