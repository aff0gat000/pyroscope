package com.pyroscope.bor.sor;

/**
 * Pyroscope profile type to query suffix mapping — embedded data access concern.
 *
 * <p>Packaged inside the BOR for standalone deployment. When the Profile Data
 * SOR is deployed separately, this class is unused.
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
