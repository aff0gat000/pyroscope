package com.pyroscope.bor.diffreport;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;

import java.util.*;
import java.util.stream.Collectors;

public final class DiffComputation {

    private DiffComputation() {}

    public record DiffEntry(String name, double baselinePercent,
                            double currentPercent, double delta,
                            Double threshold) {
        public DiffEntry(String name, double baselinePercent,
                         double currentPercent, double delta) {
            this(name, baselinePercent, currentPercent, delta, null);
        }
    }

    public static Map<String, Double> toPercentMap(JsonArray functions) {
        Map<String, Double> map = new HashMap<>();
        for (int i = 0; i < functions.size(); i++) {
            JsonObject f = functions.getJsonObject(i);
            map.put(f.getString("name"), f.getDouble("selfPercent"));
        }
        return map;
    }

    public static List<DiffEntry> computeDeltas(Map<String, Double> baseline,
                                                  Map<String, Double> current,
                                                  int limit) {
        Set<String> allFunctions = new HashSet<>();
        allFunctions.addAll(baseline.keySet());
        allFunctions.addAll(current.keySet());

        return allFunctions.stream()
                .map(name -> {
                    double bp = baseline.getOrDefault(name, 0.0);
                    double cp = current.getOrDefault(name, 0.0);
                    return new DiffEntry(name, bp, cp, cp - bp);
                })
                .filter(d -> Math.abs(d.delta) > 0.1)
                .sorted((a, b) -> Double.compare(
                        Math.abs(b.delta), Math.abs(a.delta)))
                .limit(limit)
                .collect(Collectors.toList());
    }

    public static List<DiffEntry> computeDeltasWithThresholds(
            Map<String, Double> baseline, Map<String, Double> current,
            Map<String, Double> thresholds, int limit) {
        Set<String> allFunctions = new HashSet<>();
        allFunctions.addAll(baseline.keySet());
        allFunctions.addAll(current.keySet());

        return allFunctions.stream()
                .map(name -> {
                    double bp = baseline.getOrDefault(name, 0.0);
                    double cp = current.getOrDefault(name, 0.0);
                    Double threshold = thresholds.get(name);
                    return new DiffEntry(name, bp, cp, cp - bp, threshold);
                })
                .filter(d -> Math.abs(d.delta) > 0.1)
                .sorted((a, b) -> Double.compare(
                        Math.abs(b.delta), Math.abs(a.delta)))
                .limit(limit)
                .collect(Collectors.toList());
    }

    public static String shortName(String fullName) {
        int lastDot = fullName.lastIndexOf('.');
        if (lastDot <= 0) return fullName;
        int secondLastDot = fullName.lastIndexOf('.', lastDot - 1);
        return secondLastDot <= 0 ? fullName : fullName.substring(secondLastDot + 1);
    }

    public static double round(double v) {
        return Math.round(v * 100.0) / 100.0;
    }
}
