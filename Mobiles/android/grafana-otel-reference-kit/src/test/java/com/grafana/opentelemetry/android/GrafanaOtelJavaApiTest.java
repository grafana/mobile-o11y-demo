package com.grafana.opentelemetry.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertThrows;

import android.app.Application;
import io.opentelemetry.android.OpenTelemetryRum;
import io.opentelemetry.api.common.Attributes;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.function.BiFunction;
import org.junit.Test;

public class GrafanaOtelJavaApiTest {
    @Test
    public void exposesJavaFriendlyStartupTypes() throws Exception {
        GrafanaOtelConfiguration configuration =
                new GrafanaOtelConfiguration("https://collector.example.test/otlp/app-key", "app");

        assertEquals("app", configuration.getServiceName());

        BiFunction<Application, GrafanaOtelConfiguration, OpenTelemetryRum> initialize =
                GrafanaOtelReferenceKit::initialize;
        assertNotNull(initialize);

        Map<String, String> headers = new LinkedHashMap<>();
        headers.put("Authorization", "Bearer token");
        headers.put("X-Scope-OrgID", "tenant");
        GrafanaOtelConfiguration fullConfiguration =
                new GrafanaOtelConfiguration(
                        "https://collector.example.test/otlp/app-key",
                        "app",
                        headers,
                        "demo",
                        "1.2.3",
                        Attributes.empty(),
                        false);

        assertEquals(headers, fullConfiguration.getHeaders());
        assertEquals("demo", fullConfiguration.getServiceNamespace());
        assertEquals("1.2.3", fullConfiguration.getServiceVersion());
        assertFalse(fullConfiguration.getDiskBufferingEnabled());
        assertThrows(
                UnsupportedOperationException.class,
                () -> fullConfiguration.getHeaders().remove("Authorization"));
    }
}
