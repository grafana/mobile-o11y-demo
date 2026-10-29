import OpenTelemetryApi
import SwiftUI

/// One button per kind of telemetry. Each action is plain OpenTelemetry API.
struct ContentView: View {
    @State private var status = "Tap a button"

    // A public demo API. Like every request, it gets a W3C `traceparent` header automatically.
    private let okURL = URL(string: "https://quickpizza.grafana.com/api/quotes")!
    private let notFoundURL = URL(string: "https://quickpizza.grafana.com/api/does-not-exist")!

    var body: some View {
        NavigationStack {
            List {
                Section("Logs") {
                    Button("Send info log") { sendLog() }
                    Button("Send custom event") { sendEvent() }
                    Button("Report handled error") { reportError() }
                }
                Section("HTTP (automatic spans)") {
                    Button("GET 200") { Task { await get(okURL) } }
                    Button("GET 404") { Task { await get(notFoundURL) } }
                }
                Section("Traces") {
                    Button("Manual span with child HTTP call") { Task { await manualSpan() } }
                }
                Section("Status") {
                    Text(status)
                    Text("session.id: \(OTel.sessionId ?? "-")")
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("OTel Swift Sample")
        }
    }

    private func sendLog() {
        OTel.log("Hello from OTel Swift", attributes: ["screen": .string("home")])
        status = "Log sent"
    }

    private func sendEvent() {
        OTel.event("add_to_cart", attributes: [
            "item": .string("margherita"),
            "quantity": .int(2),
        ])
        status = "Event sent"
    }

    private func reportError() {
        OTel.logException(CheckoutError.paymentDeclined)
        status = "Error reported"
    }

    /// Nothing to add here: `URLSessionInstrumentation` creates a client span for the request.
    private func get(_ url: URL) async {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            status = "GET \(url.path) → \((response as? HTTPURLResponse)?.statusCode ?? 0)"
        } catch {
            status = "GET \(url.path) failed: \(error.localizedDescription)"
        }
    }

    /// A manual span. Because it is made active, the automatic HTTP span becomes its child.
    private func manualSpan() async {
        let span = OTel.startSpan("load_quotes")
        span.setAttribute(key: "screen", value: "home")
        await get(okURL)
        span.end()
        status = "Span load_quotes sent"
    }
}

/// An example app error. `LocalizedError` gives it a readable message in Grafana.
enum CheckoutError: LocalizedError {
    case paymentDeclined

    var errorDescription: String? { "Payment declined" }
}

#Preview {
    ContentView()
}
