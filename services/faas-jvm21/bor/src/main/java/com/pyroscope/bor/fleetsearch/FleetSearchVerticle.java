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

public class FleetSearchVerticle extends AbstractFunctionVerticle {

    private final String profileDataUrl;
    private SorClient sor;

    public FleetSearchVerticle(String profileDataUrl, int port) {
        super(port);
        this.profileDataUrl = profileDataUrl;
    }

    @Override
    protected void initFunction() {
        sor = new SorClient(vertx, profileDataUrl);
        router.get("/search").handler(this::handleSearch);
        router.get("/fleet/hotspots").handler(this::handleHotspots);
    }

    private void handleSearch(RoutingContext ctx) {
        String functionName = ctx.request().getParam("function");
        if (functionName == null || functionName.isBlank()) {
            sendError(ctx, 400, "query parameter 'function' is required");
            return;
        }

        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);
        String type = paramStr(ctx, "type", "cpu");

        resolveApps(ctx, from, to).compose(apps ->
                queryAllApps(apps, type, from, to).map(results -> {
                    JsonArray matches = new JsonArray();
                    String search = functionName.toLowerCase();
                    for (var entry : results.entrySet()) {
                        JsonArray functions = entry.getValue()
                                .getJsonArray("functions");
                        for (int i = 0; i < functions.size(); i++) {
                            JsonObject f = functions.getJsonObject(i);
                            if (f.getString("name").toLowerCase().contains(search)) {
                                matches.add(new JsonObject()
                                        .put("app", entry.getKey())
                                        .put("function", f.getString("name"))
                                        .put("selfPercent", f.getDouble("selfPercent"))
                                        .put("selfSamples", f.getLong("selfSamples")));
                            }
                        }
                    }
                    return matches;
                })
        ).onComplete(ar -> {
            if (ar.failed()) { sendError(ctx, 502, ar.cause().getMessage()); return; }
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

        resolveApps(ctx, from, to).compose(apps ->
                queryAllApps(apps, type, from, to).map(results -> {
                    Map<String, List<JsonObject>> byFunction = new HashMap<>();
                    for (var entry : results.entrySet()) {
                        JsonArray functions = entry.getValue()
                                .getJsonArray("functions");
                        for (int i = 0; i < functions.size(); i++) {
                            JsonObject f = functions.getJsonObject(i);
                            byFunction.computeIfAbsent(
                                            f.getString("name"), k -> new ArrayList<>())
                                    .add(new JsonObject()
                                            .put("app", entry.getKey())
                                            .put("selfPercent",
                                                    f.getDouble("selfPercent")));
                        }
                    }

                    return HotspotScorer.rankHotspots(byFunction, limit);
                })
        ).onComplete(ar -> {
            if (ar.failed()) { sendError(ctx, 502, ar.cause().getMessage()); return; }
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("profileType", type)
                            .put("from", from).put("to", to)
                            .put("hotspots", ar.result())
                            .encodePrettily());
        });
    }

    private Future<List<String>> resolveApps(RoutingContext ctx, long from, long to) {
        String appsParam = ctx.request().getParam("apps");
        if (appsParam != null && !appsParam.isBlank()) {
            return Future.succeededFuture(
                    Arrays.stream(appsParam.split(","))
                            .map(String::trim).filter(s -> !s.isEmpty()).collect(Collectors.toList()));
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

}
