package com.pyroscope.bor.fleetsearch;

import com.pyroscope.bor.AbstractFunctionVerticle;
import com.pyroscope.bor.SorClient;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

import java.time.Instant;
import java.util.*;
import java.util.stream.Collectors;

public class FleetSearchFullVerticle extends AbstractFunctionVerticle {

    private final String profileDataUrl;
    private final String registryUrl;
    private SorClient sor;

    public FleetSearchFullVerticle(String profileDataUrl, String registryUrl, int port) {
        super(port);
        this.profileDataUrl = profileDataUrl;
        this.registryUrl = registryUrl;
    }

    @Override
    protected void initFunction() {
        sor = new SorClient(vertx, profileDataUrl, null, null, registryUrl);
        router.get("/search").handler(this::handleSearch);
        router.get("/fleet/hotspots").handler(this::handleHotspots);
    }

    private void handleSearch(RoutingContext ctx) {
        String functionName = ctx.request().getParam("function");
        if (functionName == null || functionName.isBlank()) {
            error(ctx, 400, "query parameter 'function' is required");
            return;
        }

        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);
        String type = paramStr(ctx, "type", "cpu");

        var registryFuture = sor.getServices();

        resolveApps(ctx, from, to).compose(apps ->
                registryFuture.compose(registryData -> {
                    Map<String, JsonObject> serviceMap = buildServiceMap(registryData);
                    return queryAllApps(apps, type, from, to).map(results -> {
                        JsonArray matches = new JsonArray();
                        String search = functionName.toLowerCase();
                        for (var entry : results.entrySet()) {
                            JsonArray functions = entry.getValue()
                                    .getJsonArray("functions");
                            for (int i = 0; i < functions.size(); i++) {
                                JsonObject f = functions.getJsonObject(i);
                                if (f.getString("name").toLowerCase().contains(search)) {
                                    JsonObject match = new JsonObject()
                                            .put("app", entry.getKey())
                                            .put("function", f.getString("name"))
                                            .put("selfPercent", f.getDouble("selfPercent"))
                                            .put("selfSamples", f.getLong("selfSamples"));

                                    JsonObject svc = serviceMap.get(entry.getKey());
                                    if (svc != null) {
                                        match.put("teamOwner", svc.getString("teamOwner"))
                                                .put("tier", svc.getString("tier"))
                                                .put("notificationChannel",
                                                        svc.getString("notificationChannel"));
                                    }

                                    matches.add(match);
                                }
                            }
                        }
                        return matches;
                    });
                })
        ).onComplete(ar -> {
            if (ar.failed()) { error(ctx, 502, ar.cause().getMessage()); return; }
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("query", functionName)
                            .put("profileType", type)
                            .put("from", from).put("to", to)
                            .put("matchCount", ar.result().size())
                            .put("matches", ar.result())
                            .encodePrettily());
        });
    }

    private void handleHotspots(RoutingContext ctx) {
        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);
        String type = paramStr(ctx, "type", "cpu");
        int limit = paramInt(ctx, "limit", 20);

        var registryFuture = sor.getServices();

        resolveApps(ctx, from, to).compose(apps ->
                registryFuture.compose(registryData -> {
                    Map<String, JsonObject> serviceMap = buildServiceMap(registryData);
                    return queryAllApps(apps, type, from, to).map(results -> {
                        Map<String, List<JsonObject>> byFunction = new HashMap<>();
                        for (var entry : results.entrySet()) {
                            JsonArray functions = entry.getValue()
                                    .getJsonArray("functions");
                            for (int i = 0; i < functions.size(); i++) {
                                JsonObject f = functions.getJsonObject(i);
                                JsonObject serviceEntry = new JsonObject()
                                        .put("app", entry.getKey())
                                        .put("selfPercent",
                                                f.getDouble("selfPercent"));

                                JsonObject svc = serviceMap.get(entry.getKey());
                                if (svc != null) {
                                    serviceEntry.put("teamOwner", svc.getString("teamOwner"))
                                            .put("tier", svc.getString("tier"));
                                }

                                byFunction.computeIfAbsent(
                                                f.getString("name"), k -> new ArrayList<>())
                                        .add(serviceEntry);
                            }
                        }

                        JsonArray hotspots = new JsonArray();
                        byFunction.entrySet().stream()
                                .map(e -> {
                                    double maxPct = e.getValue().stream()
                                            .mapToDouble(j -> j.getDouble("selfPercent"))
                                            .max().orElse(0);
                                    long criticalCount = e.getValue().stream()
                                            .filter(j -> "critical".equals(j.getString("tier")))
                                            .count();
                                    return new JsonObject()
                                            .put("function", e.getKey())
                                            .put("serviceCount", e.getValue().size())
                                            .put("criticalServiceCount", criticalCount)
                                            .put("maxSelfPercent", round(maxPct))
                                            .put("impactScore",
                                                    round(e.getValue().size() * maxPct))
                                            .put("services", new JsonArray(e.getValue()));
                                })
                                .sorted((a, b) -> Double.compare(
                                        b.getDouble("impactScore"),
                                        a.getDouble("impactScore")))
                                .limit(limit)
                                .forEach(hotspots::add);
                        return hotspots;
                    });
                })
        ).onComplete(ar -> {
            if (ar.failed()) { error(ctx, 502, ar.cause().getMessage()); return; }
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("profileType", type)
                            .put("from", from).put("to", to)
                            .put("hotspots", ar.result())
                            .encodePrettily());
        });
    }

    private Map<String, JsonObject> buildServiceMap(JsonObject registryData) {
        Map<String, JsonObject> map = new HashMap<>();
        JsonArray services = registryData.getJsonArray("services", new JsonArray());
        for (int i = 0; i < services.size(); i++) {
            JsonObject svc = services.getJsonObject(i);
            map.put(svc.getString("appName"), svc);
        }
        return map;
    }

    private Future<List<String>> resolveApps(RoutingContext ctx, long from, long to) {
        String appsParam = ctx.request().getParam("apps");
        if (appsParam != null && !appsParam.isBlank()) {
            return Future.succeededFuture(
                    Arrays.stream(appsParam.split(","))
                            .map(String::trim).filter(s -> !s.isEmpty())
                            .collect(Collectors.toList()));
        }
        return sor.getApps(from, to);
    }

    private Future<Map<String, JsonObject>> queryAllApps(
            List<String> apps, String type, long from, long to) {
        @SuppressWarnings("rawtypes")
        List<Future> futures = new ArrayList<>();
        List<String> appNames = new ArrayList<>(apps);

        for (String app : apps) {
            futures.add(sor.getProfile(app, type, from, to, 50));
        }

        return CompositeFuture.join(futures).map(cf -> {
            Map<String, JsonObject> results = new LinkedHashMap<>();
            for (int i = 0; i < appNames.size(); i++) {
                if (cf.succeeded(i)) {
                    results.put(appNames.get(i), cf.resultAt(i));
                }
            }
            return results;
        });
    }

    private static void error(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encodePrettily());
    }

    private static long paramLong(RoutingContext ctx, String name, long defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Long.parseLong(val) : defaultValue;
    }

    private static int paramInt(RoutingContext ctx, String name, int defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Integer.parseInt(val) : defaultValue;
    }

    private static String paramStr(RoutingContext ctx, String name, String defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null && !val.isBlank() ? val : defaultValue;
    }

    private static double round(double v) {
        return Math.round(v * 100.0) / 100.0;
    }
}
