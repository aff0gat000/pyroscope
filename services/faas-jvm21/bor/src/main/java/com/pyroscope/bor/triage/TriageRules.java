package com.pyroscope.bor.triage;

import io.vertx.core.json.JsonArray;

public final class TriageRules {

    private TriageRules() {}

    public static String diagnose(String type, JsonArray functions) {
        if (functions.isEmpty()) return "no_data";

        return switch (type) {
            case "cpu" -> {
                if (matches(functions, "GC", "gc_", "G1", "ParallelGC", "ZGC"))
                    yield "gc_pressure";
                if (matches(functions, "park", "sleep", "Object.wait", "Unsafe.park"))
                    yield "thread_waiting";
                if (matches(functions, "synchronized", "ReentrantLock", "monitor"))
                    yield "lock_contention";
                if (matches(functions, "Compiler", "C1", "C2", "compile"))
                    yield "jit_overhead";
                yield "cpu_bound";
            }
            case "alloc" -> {
                if (matches(functions, "StringBuilder", "concat", "toString", "String.format"))
                    yield "string_allocation";
                if (matches(functions, "ArrayList", "HashMap", "resize", "grow", "Arrays.copyOf"))
                    yield "collection_resizing";
                if (matches(functions, "read", "decode", "parse", "deserialize", "Jackson",
                        "Gson", "ObjectMapper"))
                    yield "deserialization_overhead";
                yield "allocation_pressure";
            }
            case "lock" -> "lock_contention";
            case "wall" -> {
                if (matches(functions, "sleep", "wait", "park", "idle"))
                    yield "idle_time";
                if (matches(functions, "socket", "connect", "dns", "InputStream.read",
                        "OutputStream.write", "SocketChannel"))
                    yield "network_io";
                yield "mixed_workload";
            }
            default -> "unknown";
        };
    }

    public static String recommend(String diagnosis, String topFunctionName) {
        if (topFunctionName == null) return "No profile data available for this type";

        return switch (diagnosis) {
            case "gc_pressure" ->
                    "GC activity in CPU profile — check heap sizing (-Xmx), reduce allocation rate. Top: " + topFunctionName;
            case "thread_waiting" ->
                    "Threads spending CPU in wait/park — possible thread pool exhaustion. Top: " + topFunctionName;
            case "lock_contention" ->
                    "Lock contention — review synchronized blocks, consider ConcurrentHashMap. Top: " + topFunctionName;
            case "jit_overhead" ->
                    "JIT compilation overhead — service may need warmup time.";
            case "cpu_bound" ->
                    "CPU-bound processing — review algorithmic complexity or add caching. Top: " + topFunctionName;
            case "string_allocation" ->
                    "High string allocation — use StringBuilder, avoid concatenation in loops. Top: " + topFunctionName;
            case "collection_resizing" ->
                    "Collection resizing — pre-size collections with expected capacity. Top: " + topFunctionName;
            case "deserialization_overhead" ->
                    "Deserialization allocation — consider streaming parsers or object pooling. Top: " + topFunctionName;
            case "allocation_pressure" ->
                    "High allocation rate — review object creation patterns. Top: " + topFunctionName;
            case "network_io" ->
                    "Network I/O dominates wall-clock time — check upstream latency, timeouts. Top: " + topFunctionName;
            case "idle_time" ->
                    "Significant idle time — thread pool may be oversized.";
            case "mixed_workload" ->
                    "Mixed workload — no single dominant bottleneck. Top: " + topFunctionName;
            default -> "Review top functions for optimization. Top: " + topFunctionName;
        };
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
