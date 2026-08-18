package com.grafana.quickpizza.core.o11y.otelfixture;

// Public factory so the test (in a different package) can obtain an instance without itself
// needing access to the package-private PackagePrivateObfuscator type.
public final class Fixture {
    private Fixture() {
    }

    public static Object obfuscate(Object target) {
        return new PackagePrivateObfuscator(target);
    }

    public static Object noUnobfuscateMethod() {
        return new Object();
    }
}
