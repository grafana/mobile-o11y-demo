package main

import "testing"

func TestMonolithicEndpointUsesHTTPPort(t *testing.T) {
	t.Setenv("QUICKPIZZA_ENABLE_ALL_SERVICES", "1")
	for _, port := range []string{"", "29333"} {
		t.Setenv("QUICKPIZZA_HTTP_PORT", port)
		want := "3333"
		if port != "" {
			want = port
		}
		if got := envEndpoint("QUICKPIZZA_ENABLE_CATALOG_SERVICE", "QUICKPIZZA_CATALOG_ENDPOINT"); got != "http://localhost:"+want {
			t.Fatalf("internal client points at %q, want listener port %s", got, want)
		}
	}
	t.Setenv("QUICKPIZZA_ENABLE_ALL_SERVICES", "0")
	t.Setenv("QUICKPIZZA_ENABLE_CATALOG_SERVICE", "0")
	t.Setenv("QUICKPIZZA_CATALOG_ENDPOINT", "http://catalog:3333")
	if got := envEndpoint("QUICKPIZZA_ENABLE_CATALOG_SERVICE", "QUICKPIZZA_CATALOG_ENDPOINT"); got != "http://catalog:3333" {
		t.Fatalf("external service endpoint changed: %s", got)
	}
}
