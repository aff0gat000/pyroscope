package com.pyroscope.bor.sor;

import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.client.WebClientOptions;

import java.net.URI;
import java.util.*;

/**
 * Pyroscope HTTP client — embedded data access layer for standalone deployment.
 *
 * <p>This is a copy of the SOR-layer Pyroscope client, packaged inside the BOR
 * for single-function deployment. When the Profile Data SOR is deployed as a
 * separate service, this class is unused — the BOR calls the SOR via
 * {@link com.pyroscope.bor.SorClient} instead.
 */
public class PyroscopeClient {

    private final WebClient client;

    public PyroscopeClient(Vertx vertx, String baseUrl) {
        URI uri = URI.create(baseUrl);
        this.client = WebClient.create(vertx, new WebClientOptions()
                .setDefaultHost(uri.getHost())
                .setDefaultPort(uri.getPort() > 0 ? uri.getPort()
                        : ("https".equals(uri.getScheme()) ? 443 : 80))
                .setSsl("https".equals(uri.getScheme()))
                .setConnectTimeout(5000)
                .setIdleTimeout(30));
    }

    public Future<JsonObject> render(String query, long from, long until) {
        return client.get("/pyroscope/render")
                .addQueryParam("query", query)
                .addQueryParam("from", String.valueOf(from))
                .addQueryParam("until", String.valueOf(until))
                .addQueryParam("format", "json")
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200) {
                        throw new RuntimeException(
                                "Pyroscope render failed (" + resp.statusCode() + "): "
                                        + resp.bodyAsString());
                    }
                    return resp.bodyAsJsonObject();
                });
    }

    /**
     * Render a profile and parse into a clean JSON response.
     * Returns: { totalSamples, functions: [{ name, selfPercent, selfSamples }] }
     */
    public Future<JsonObject> getProfile(String appName, String type,
                                          long from, long to, int limit) {
        String query = ProfileType.fromString(type).queryFor(appName);
        return render(query, from, to).map(raw -> {
            List<FunctionSample> functions = extractTopFunctions(raw, limit);
            long totalSamples = functions.isEmpty() ? 0 : functions.get(0).totalTicks();
            JsonArray arr = new JsonArray();
            for (var f : functions) {
                arr.add(new JsonObject()
                        .put("name", f.name())
                        .put("selfPercent", Math.round(f.selfPercent() * 100.0) / 100.0)
                        .put("selfSamples", f.selfSamples()));
            }
            return new JsonObject()
                    .put("appName", appName)
                    .put("profileType", type)
                    .put("from", from)
                    .put("to", to)
                    .put("totalSamples", totalSamples)
                    .put("functions", arr);
        });
    }

    // ---- Flamebearer parsing ----

    public record FunctionSample(
            String name, long selfSamples, long totalSamples,
            long totalTicks, double selfPercent) {}

    public static List<FunctionSample> extractTopFunctions(JsonObject renderResponse, int limit) {
        JsonObject flamebearer = renderResponse.getJsonObject("flamebearer");
        if (flamebearer == null) return List.of();

        JsonArray names = flamebearer.getJsonArray("names");
        JsonArray levels = flamebearer.getJsonArray("levels");
        long numTicks = flamebearer.getLong("numTicks", 0L);
        if (names == null || levels == null || numTicks == 0) return List.of();

        Map<Integer, long[]> samples = new HashMap<>();
        for (int i = 0; i < levels.size(); i++) {
            JsonArray level = levels.getJsonArray(i);
            for (int j = 0; j + 3 < level.size(); j += 4) {
                long total = level.getLong(j + 1);
                long self = level.getLong(j + 2);
                int nameIdx = level.getInteger(j + 3);
                samples.merge(nameIdx, new long[]{self, total},
                        (a, b) -> new long[]{a[0] + b[0], a[1] + b[1]});
            }
        }

        return samples.entrySet().stream()
                .filter(e -> e.getValue()[0] > 0)
                .sorted((a, b) -> Long.compare(b.getValue()[0], a.getValue()[0]))
                .limit(limit)
                .map(e -> new FunctionSample(
                        names.getString(e.getKey()),
                        e.getValue()[0], e.getValue()[1],
                        numTicks,
                        (double) e.getValue()[0] / numTicks * 100))
                .collect(java.util.stream.Collectors.toList());
    }
}
