import Foundation
import SwiftiePod

/// Global DI container — single instance for the entire app.
let pod = SwiftiePod()

/// Bootstraps the app: initializes OTel, logger, and other services.
/// Called once at app launch from `QuickPizzaIosApp.init()`.
enum Bootstrap {
    static func initialize() {
        // 1. Resolve the in-use URLs before anything else so OTelService and
        //    APIClient see the same snapshot for the rest of the session.
        let runtimeConfig = pod.resolve(runtimeConfigHolderProvider).current

        // 2. OpenTelemetry (reads runtimeConfig via otelConfigProvider)
        let otelService = pod.resolve(otelServiceProvider)

        // 3. Log startup. Report what OTel actually did, not what was configured. A valid OTLP
        //    endpoint is required, so there is no "installed but not exporting" state: either the
        //    SDK is up and exporting, or it is not installed at all.
        //
        //    The not-installed message only reaches the Xcode console. `logger` fans out to OSLog
        //    and to OTel, and the OTel half is a no-op provider in exactly that case.
        let config = pod.resolve(configServiceProvider)
        let logger = pod.resolve(loggerProvider)
        if otelService.isExportingOtlp {
            logger.info("OTel initialized, exporting to the OTLP endpoint", attributes: [
                "endpoint": runtimeConfig.otlpEndpoint,
                "hasAuthHeader": runtimeConfig.otlpAuthHeader != nil ? "yes" : "no",
            ])
        } else {
            logger.warning("OTel not initialized; no telemetry will be produced", attributes: [
                "reason": otelService.otlpRejectionReason ?? "unknown",
            ])
        }
        logger.info("QuickPizza iOS app started", attributes: [
            "version": config.appVersion,
            "baseURL": runtimeConfig.backendBaseUrl,
        ])
    }
}
