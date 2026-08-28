package com.grafana.opentelemetry.android

import io.opentelemetry.api.common.Attributes
import java.net.URI
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
        val endpoint = runCatching { URI(otlpEndpoint) }.getOrNull()
        require(
            endpoint != null &&
                endpoint.isAbsolute &&
                endpoint.host != null &&
                endpoint.scheme in setOf("http", "https"),
        ) {
            "otlpEndpoint must be an absolute URL starting with lowercase http:// or https://"
        }
        require(endpoint.rawQuery == null) {
            "otlpEndpoint must not contain a query string"
        }
        require(endpoint.rawFragment == null) {
            "otlpEndpoint must not contain a fragment"
        }
        require(serviceName.isNotBlank()) { "serviceName must not be blank" }
        require(serviceNamespace == null || serviceNamespace.isNotBlank()) {
            "serviceNamespace must be null or non-blank"
        }
        require(serviceVersion == null || serviceVersion.isNotBlank()) {
            "serviceVersion must be null or non-blank"
        }
        require(this.headers.keys.all(String::isValidHeaderName)) {
            "header names must contain only visible ASCII characters"
        }
        require(this.headers.values.all(String::isValidHeaderValue)) {
            "header values must contain only tabs or visible ASCII characters"
        }
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

// Match the character ranges enforced by the runtime HTTP sender before export.
private fun String.isValidHeaderName(): Boolean =
    isNotEmpty() && all { character -> character.code in 0x21..0x7e }

private fun String.isValidHeaderValue(): Boolean =
    all { character -> character == '\t' || character.code in 0x20..0x7e }
