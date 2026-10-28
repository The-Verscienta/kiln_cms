import KilnReader
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Point it at a Kiln with `KILN_URL` (default http://localhost:4000). The
/// iOS Simulator reaches the Mac's localhost directly.
@main
struct ReaderApp: App {
    @State private var reader: Reader

    init() {
        let environment = ProcessInfo.processInfo.environment
        let base = URL(string: environment["KILN_URL"] ?? "http://localhost:4000")!
        let store: MirrorStore = (try? FileMirrorStore.default())
            ?? FileMirrorStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("mirror.json"))
        _reader = State(initialValue: Reader(
            client: KilnClient(baseURL: base),
            store: store,
            featuredSlug: environment["KILN_FEATURED"] ?? "buttermilk-pancakes"
        ))
        #if os(macOS)
        // `swift run` starts a bare executable; make it a regular app with a
        // window in front.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        #endif
    }

    var body: some Scene {
        WindowGroup("Recipes") {
            RecipeListView(reader: reader)
        }
    }
}
