import SwiftUI

@main
struct OTelSwiftSampleApp: App {
    init() {
        // First thing, on the main thread, before any span or log is created.
        OTel.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
