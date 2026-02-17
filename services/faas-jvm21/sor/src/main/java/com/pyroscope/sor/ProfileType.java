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
        return switch (s.toLowerCase()) {
            case "cpu" -> CPU;
            case "alloc", "allocation", "memory" -> ALLOC;
            case "lock", "mutex", "contention" -> LOCK;
            case "wall", "wallclock", "wall-clock" -> WALL;
            default -> throw new IllegalArgumentException(
                    "Unknown profile type: " + s + ". Valid: cpu, alloc, lock, wall");
        };
    }
}
