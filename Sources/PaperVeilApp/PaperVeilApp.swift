import SwiftUI

/// Files opened via Finder ("Öffnen mit"), the Dock icon or `open -a PaperVeil x.pdf`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openHandler: (([URL]) -> Void)?
    var pending: [URL] = []
    func application(_ application: NSApplication, open urls: [URL]) {
        if let openHandler { openHandler(urls) } else { pending += urls }
    }
}

@main
struct PaperVeilApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    init() {
        // SwiftPM executables start as background processes; make it a regular app.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("PaperVeil") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1280, minHeight: 700)
                .onAppear {
                    NSApplication.shared.activate()
                    delegate.openHandler = { [model] in model.add(urls: $0) }
                    if !delegate.pending.isEmpty { model.add(urls: delegate.pending); delegate.pending = [] }
                }
        }
        Settings {
            SettingsView().environment(model).frame(width: 640, height: 520)
        }
    }
}
