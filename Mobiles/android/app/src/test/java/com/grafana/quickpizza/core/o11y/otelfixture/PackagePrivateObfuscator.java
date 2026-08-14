package com.grafana.quickpizza.core.o11y.otelfixture;

// Package-private on purpose, and in its own package: mirrors OTel-Android's Obfuscated*Provider
// classes, which live in a different package than any caller and expose a public unobfuscate()
// method while keeping the class itself non-public, so callers cannot cast to it directly.
class PackagePrivateObfuscator {
    private final Object target;

    PackagePrivateObfuscator(Object target) {
        this.target = target;
    }

    public Object unobfuscate() {
        return target;
    }
}
