package com.pyroscope.sor;

/**
 * Pyroscope profile types and their query suffix mapping.
 * This is data-access concern — the SOR knows how to translate
 * a profile type name into a Pyroscope query format.
 */
public enum ProfileType {

    CPU("cpu"),
    ALLOC("alloc_in_new_tlab_bytes"),
    LOCK("lock_count"),
    WALL("wall");

    private final String suffix;

    ProfileType(String suffix) {
        this.suffix = suffix;
    }

    /** Build a Pyroscope query: {@code appName.suffix{}} */
    public String queryFor(String appName) {
        return appName + "." + suffix + "{}";
    }

    public static ProfileType fromString(String s) {
        switch (s.toLowerCase()) {
            case "cpu":
                return CPU;
            case "alloc":
            case "allocation":
            case "memory":
                return ALLOC;
            case "lock":
            case "mutex":
            case "contention":
                return LOCK;
            case "wall":
            case "wallclock":
            case "wall-clock":
                return WALL;
            default:
                throw new IllegalArgumentException(
                        "Unknown profile type: " + s + ". Valid: cpu, alloc, lock, wall");
        }
    }
}
