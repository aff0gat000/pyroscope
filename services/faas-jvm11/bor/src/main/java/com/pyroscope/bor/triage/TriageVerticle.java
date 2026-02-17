package com.pyroscope.bor.triage;

import com.pyroscope.bor.AbstractFunctionVerticle;
import com.pyroscope.bor.sor.PyroscopeClient;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

import java.time.Instant;
import java.util.*;
import java.util.stream.Collectors;

public class TriageVerticle extends AbstractFunctionVerticle {

    private final String pyroscopeUrl;
    private PyroscopeClient pyroscope;

    public TriageVerticle(String pyroscopeUrl, int port) {
        super(port);
        this.pyroscopeUrl = pyroscopeUrl;
    }

    @Override
    protected void initFunction() {
        pyroscope = new PyroscopeClient(vertx, pyroscopeUrl);
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
                .map(String::trim).collect(Collectors.toList());

        Map<String, Future<JsonObject>> futures = new LinkedHashMap<>();
        for (String type : types) {
            futures.put(type, pyroscope.getProfile(appName, type, from, to, limit));
        }

        CompositeFuture.join(new ArrayList<>(futures.values())).onComplete(ar -> {
            JsonObject profiles = new JsonObject();
            String primaryIssue = "healthy";
            String primaryRecommendation = "No significant issues detected";
            double maxSeverity = 0;

            for (var entry : futures.entrySet()) {
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

                    profiles.put(type, new JsonObject()
                            .put("diagnosis", diagnosis)
                            .put("totalSamples", totalSamples)
                            .put("topFunctions", functions)
                            .put("recommendation", recommendation));
                } else {
                    profiles.put(type, new JsonObject()
                            .put("diagnosis", "unavailable")
                            .put("error", future.cause().getMessage()));
                }
            }

            String severityLevel = TriageRules.severity(maxSeverity);

            ctx.response()
                    .putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("from", from)
                            .put("to", to)
                            .put("profiles", profiles)
                            .put("summary", new JsonObject()
                                    .put("primaryIssue", primaryIssue)
                                    .put("severity", severityLevel)
                                    .put("recommendation", primaryRecommendation))
                            .encodePrettily());
        });
    }

}
