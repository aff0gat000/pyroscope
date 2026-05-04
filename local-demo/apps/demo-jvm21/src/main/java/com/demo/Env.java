package com.demo;

/**
 * Two-layer env lookup: system property first, OS env var second, default last.
 * Lets integration tests inject backend URLs via {@code System.setProperty}
 * (env vars are immutable at runtime on most JVMs).
 */
public final class Env {
    private Env() {}

    public static String get(String key, String defaultValue) {
        String v = System.getProperty(key);
        if (v != null) return v;
        v = System.getenv(key);
        return v != null ? v : defaultValue;
    }
}
