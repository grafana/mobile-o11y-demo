package com.grafana.opentelemetry.android

import io.opentelemetry.api.common.Attributes
import java.time.Duration
import java.util.Collections
import java.util.LinkedHashMap

/**
 * Grafana-owned setup values layered on top of the upstream OpenTelemetry Android SDK.
 *
 * This configures SDK startup only. Applications continue to create telemetry through the
 * standard OpenTelemetry API returned by [GrafanaOtelReferenceKit.initialize].
 */
class GrafanaOtelConfiguration @JvmOverloads constructor(
    val otlpEndpoint: String,
    val serviceName: String,
    headers: Map<String, String> = emptyMap(),
    val serviceNamespace: String? = null,
    val serviceVersion: String? = null,
    val resourceAttributes: Attributes = Attributes.empty(),
    val diskBufferingEnabled: Boolean = true,
    val useLatestExperimentalSemanticConventions: Boolean = false,
    val sessionBackgroundInactivityTimeout: Duration = Duration.ofMinutes(15),
    val sessionMaxLifetime: Duration = Duration.ofHours(4),
) {
    val headers: Map<String, String> = Collections.unmodifiableMap(LinkedHashMap(headers))

    init {
        require(otlpEndpoint.isNotBlank()) { "otlpEndpoint must not be blank" }
        require(serviceName.isNotBlank()) { "serviceName must not be blank" }
        require(serviceNamespace == null || serviceNamespace.isNotBlank()) {
            "serviceNamespace must be null or non-blank"
        }
        require(serviceVersion == null || serviceVersion.isNotBlank()) {
            "serviceVersion must be null or non-blank"
        }
        require(this.headers.keys.none(String::isBlank)) { "header names must not be blank" }
        require(
            !sessionBackgroundInactivityTimeout.isZero &&
                !sessionBackgroundInactivityTimeout.isNegative,
        ) {
            "sessionBackgroundInactivityTimeout must be positive"
        }
        require(!sessionMaxLifetime.isZero && !sessionMaxLifetime.isNegative) {
            "sessionMaxLifetime must be positive"
        }
    }
}
