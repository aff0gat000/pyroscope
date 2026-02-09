package com.pyroscope.bor.triage;

import com.pyroscope.bor.AbstractFunctionVerticle;
import com.pyroscope.bor.SorClient;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

import java.time.Instant;
import java.util.*;

public class TriageFullVerticle extends AbstractFunctionVerticle {

    private final String profileDataUrl;
    private final String baselineUrl;
    private final String historyUrl;
    private SorClient sor;

    public TriageFullVerticle(String profileDataUrl, String baselineUrl,
                              String historyUrl, int port) {
        super(port);
        this.profileDataUrl = profileDataUrl;
        this.baselineUrl = baselineUrl;
        this.historyUrl = historyUrl;
    }

    @Override
    protected void initFunction() {
        sor = new SorClient(vertx, profileDataUrl, baselineUrl, historyUrl, null);
        router.get("/triage/:appName").handler(this::handleTriage);
    }

    private void handleTriage(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);
        int limit = paramInt(ctx, "limit", 10);

        String typesParam = paramStr(ctx, "types", "cpu,alloc");
        List<String> types = Arrays.stream(typesParam.split(","))
                .map(String::trim).collect(java.util.stream.Collectors.toList());

        Map<String, Future<JsonObject>> profileFutures = new LinkedHashMap<>();
        for (String type : types) {
            profileFutures.put(type, sor.getProfile(appName, type, from, to, limit));
        }

        Map<String, Future<JsonObject>> baselineFutures = new LinkedHashMap<>();
        for (String type : types) {
            baselineFutures.put(type, sor.getBaselines(appName, type));
        }

        List<Future> allFutures = new ArrayList<>();
        allFutures.addAll(profileFutures.values());
        allFutures.addAll(baselineFutures.values());

        CompositeFuture.join(allFutures).onComplete(ar -> {
            JsonObject profiles = new JsonObject();
            String primaryIssue = "healthy";
            String primaryRecommendation = "No significant issues detected";
            double maxSeverity = 0;
            int baselineViolations = 0;

            for (var entry : profileFutures.entrySet()) {
                String type = entry.getKey();
                Future<JsonObject> future = entry.getValue();

                if (future.succeeded()) {
                    JsonArray functions = future.result().getJsonArray("functions");
                    long totalSamples = future.result().getLong("totalSamples", 0L);
                    String diagnosis = TriageRules.diagnose(type, functions);
                    String topFunc = functions.isEmpty() ? null
                            : functions.getJsonObject(0).getString("name");
                    String recommendation = TriageRules.recommend(diagnosis, topFunc);
                    double severity = functions.isEmpty() ? 0
                            : functions.getJsonObject(0).getDouble("selfPercent");

                    if (severity > maxSeverity) {
                        maxSeverity = severity;
                        primaryIssue = diagnosis;
                        primaryRecommendation = recommendation;
                    }

                    JsonArray violations = new JsonArray();
                    Future<JsonObject> baselineFuture = baselineFutures.get(type);
                    if (baselineFuture != null && baselineFuture.succeeded()) {
                        JsonArray baselines = baselineFuture.result()
                                .getJsonArray("baselines", new JsonArray());
                        violations = checkBaselines(functions, baselines);
                        baselineViolations += violations.size();
                    }

                    JsonObject profileResult = new JsonObject()
                            .put("diagnosis", diagnosis)
                            .put("totalSamples", totalSamples)
                            .put("topFunctions", functions)
                            .put("recommendation", recommendation);

                    if (!violations.isEmpty()) {
                        profileResult.put("baselineViolations", violations);
                    }

                    profiles.put(type, profileResult);
                } else {
                    profiles.put(type, new JsonObject()
                            .put("diagnosis", "unavailable")
                            .put("error", future.cause().getMessage()));
                }
            }

            String severityLevel = TriageRules.severity(maxSeverity);

            JsonObject response = new JsonObject()
                    .put("appName", appName)
                    .put("from", from)
                    .put("to", to)
                    .put("profiles", profiles)
                    .put("summary", new JsonObject()
                            .put("primaryIssue", primaryIssue)
                            .put("severity", severityLevel)
                            .put("recommendation", primaryRecommendation)
                            .put("baselineViolations", baselineViolations));

            ctx.response()
                    .putHeader("content-type", "application/json")
                    .end(response.encodePrettily());

            sor.saveHistory(new JsonObject()
                    .put("appName", appName)
                    .put("profileTypes", typesParam)
                    .put("diagnosis", primaryIssue)
                    .put("severity", severityLevel)
                    .put("recommendation", primaryRecommendation)
                    .put("topFunctions", profiles));
        });
    }

    private JsonArray checkBaselines(JsonArray functions, JsonArray baselines) {
        Map<String, JsonObject> baselineMap = new HashMap<>();
        for (int i = 0; i < baselines.size(); i++) {
            JsonObject b = baselines.getJsonObject(i);
            baselineMap.put(b.getString("functionName"), b);
        }

        JsonArray violations = new JsonArray();
        for (int i = 0; i < functions.size(); i++) {
            JsonObject f = functions.getJsonObject(i);
            String name = f.getString("name");
            JsonObject b = baselineMap.get(name);
            if (b != null) {
                double current = f.getDouble("selfPercent");
                double threshold = b.getDouble("maxSelfPercent");
                if (current > threshold) {
                    violations.add(new JsonObject()
                            .put("function", name)
                            .put("currentPercent", round(current))
                            .put("threshold", round(threshold))
                            .put("exceededBy", round(current - threshold))
                            .put("severity", b.getString("severity", "warning")));
                }
            }
        }
        return violations;
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
