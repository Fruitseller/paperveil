import SwiftUI

@main
struct PaperVeilApp: App {
    @State private var model = AppModel()

    init() {
        // SwiftPM executables start as background processes; make it a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("PaperVeil") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 650)
                .onAppear { NSApplication.shared.activate() }
        }
        Settings {
            SettingsView().environment(model).frame(width: 640, height: 520)
        }
    }
}
