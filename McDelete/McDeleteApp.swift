import SwiftUI

@main
struct McDeleteApp: App {
    @State private var library = PhotoLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(library)
                .frame(minWidth: 760, minHeight: 620)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .help) {
                Text("← Delete   → Keep   ↑ Undo   Space Play/Pause")
            }
        }
    }
}
