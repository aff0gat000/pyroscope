package com.pyroscope.bor.fleetsearch;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;

import java.util.*;
import java.util.stream.Collectors;

public final class HotspotScorer {

    private HotspotScorer() {}

    public static JsonArray rankHotspots(Map<String, List<JsonObject>> functionToServices,
                                          int limit) {
        JsonArray result = new JsonArray();
        functionToServices.entrySet().stream()
                .map(e -> {
                    double maxPct = e.getValue().stream()
                            .mapToDouble(j -> j.getDouble("selfPercent"))
                            .max().orElse(0);
                    return new JsonObject()
                            .put("function", e.getKey())
                            .put("serviceCount", e.getValue().size())
                            .put("maxSelfPercent", round(maxPct))
                            .put("impactScore", round(e.getValue().size() * maxPct))
                            .put("services", new JsonArray(e.getValue()));
                })
                .sorted((a, b) -> Double.compare(
                        b.getDouble("impactScore"),
                        a.getDouble("impactScore")))
                .limit(limit)
                .forEach(result::add);
        return result;
    }

    static double round(double v) {
        return Math.round(v * 100.0) / 100.0;
    }
}
