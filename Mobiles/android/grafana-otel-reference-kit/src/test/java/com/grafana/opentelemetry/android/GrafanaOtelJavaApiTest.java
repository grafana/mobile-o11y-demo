package com.grafana.opentelemetry.android;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertThrows;
import static org.junit.Assert.assertTrue;

import io.opentelemetry.api.common.Attributes;
import java.lang.reflect.Method;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.Test;

public class GrafanaOtelJavaApiTest {
    @Test
    public void exposesJavaFriendlyStartupTypes() throws Exception {
        GrafanaOtelConfiguration configuration =
                new GrafanaOtelConfiguration("https://collector.example.test/otlp/app-key", "app");

        assertEquals("app", configuration.getServiceName());

        Method[] initializeMethods =
                Arrays.stream(GrafanaOtelReferenceKit.class.getDeclaredMethods())
                        .filter(method -> method.getName().equals("initialize"))
                        .toArray(Method[]::new);
        assertEquals(2, initializeMethods.length);
        assertEquals(
                1,
                Arrays.stream(initializeMethods)
                        .filter(method -> !method.isSynthetic())
                        .count());
        assertTrue(
                Arrays.stream(initializeMethods)
                        .anyMatch(method -> method.isSynthetic() && method.getParameterCount() == 3));

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
