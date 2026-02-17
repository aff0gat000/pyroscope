package com.pyroscope.bor.triage;

import io.vertx.core.json.JsonArray;

public final class TriageRules {

    private TriageRules() {}

    public static String diagnose(String type, JsonArray functions) {
        if (functions.isEmpty()) return "no_data";

        switch (type) {
            case "cpu":
                if (matches(functions, "GC", "gc_", "G1", "ParallelGC", "ZGC"))
                    return "gc_pressure";
                if (matches(functions, "park", "sleep", "Object.wait", "Unsafe.park"))
                    return "thread_waiting";
                if (matches(functions, "synchronized", "ReentrantLock", "monitor"))
                    return "lock_contention";
                if (matches(functions, "Compiler", "C1", "C2", "compile"))
                    return "jit_overhead";
                return "cpu_bound";
            case "alloc":
                if (matches(functions, "StringBuilder", "concat", "toString", "String.format"))
                    return "string_allocation";
                if (matches(functions, "ArrayList", "HashMap", "resize", "grow", "Arrays.copyOf"))
                    return "collection_resizing";
                if (matches(functions, "read", "decode", "parse", "deserialize", "Jackson",
                        "Gson", "ObjectMapper"))
                    return "deserialization_overhead";
                return "allocation_pressure";
            case "lock":
                return "lock_contention";
            case "wall":
                if (matches(functions, "sleep", "wait", "park", "idle"))
                    return "idle_time";
                if (matches(functions, "socket", "connect", "dns", "InputStream.read",
                        "OutputStream.write", "SocketChannel"))
                    return "network_io";
                return "mixed_workload";
            default:
                return "unknown";
        }
    }

    public static String recommend(String diagnosis, String topFunctionName) {
        if (topFunctionName == null) return "No profile data available for this type";

        switch (diagnosis) {
            case "gc_pressure":
                return "GC activity in CPU profile — check heap sizing (-Xmx), reduce allocation rate. Top: " + topFunctionName;
            case "thread_waiting":
                return "Threads spending CPU in wait/park — possible thread pool exhaustion. Top: " + topFunctionName;
            case "lock_contention":
                return "Lock contention — review synchronized blocks, consider ConcurrentHashMap. Top: " + topFunctionName;
            case "jit_overhead":
                return "JIT compilation overhead — service may need warmup time.";
            case "cpu_bound":
                return "CPU-bound processing — review algorithmic complexity or add caching. Top: " + topFunctionName;
            case "string_allocation":
                return "High string allocation — use StringBuilder, avoid concatenation in loops. Top: " + topFunctionName;
            case "collection_resizing":
                return "Collection resizing — pre-size collections with expected capacity. Top: " + topFunctionName;
            case "deserialization_overhead":
                return "Deserialization allocation — consider streaming parsers or object pooling. Top: " + topFunctionName;
            case "allocation_pressure":
                return "High allocation rate — review object creation patterns. Top: " + topFunctionName;
            case "network_io":
                return "Network I/O dominates wall-clock time — check upstream latency, timeouts. Top: " + topFunctionName;
            case "idle_time":
                return "Significant idle time — thread pool may be oversized.";
            case "mixed_workload":
                return "Mixed workload — no single dominant bottleneck. Top: " + topFunctionName;
            default:
                return "Review top functions for optimization. Top: " + topFunctionName;
        }
    }

    public static String severity(double maxSelfPercent) {
        if (maxSelfPercent > 30) return "high";
        if (maxSelfPercent > 10) return "medium";
        return "low";
    }

    public static boolean matches(JsonArray functions, String... patterns) {
        int checkCount = Math.min(functions.size(), 5);
        for (int i = 0; i < checkCount; i++) {
            String name = functions.getJsonObject(i).getString("name");
            for (String p : patterns) {
                if (name.contains(p)) return true;
            }
        }
        return false;
    }
}
