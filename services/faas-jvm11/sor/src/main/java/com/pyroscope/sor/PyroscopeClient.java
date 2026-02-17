package com.pyroscope.sor;

import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.client.WebClientOptions;

import java.net.URI;
import java.util.*;
import java.util.stream.Collectors;

/**
 * HTTP client for the Pyroscope query API — internal to the SOR layer.
 * BORs never use this class directly; they call the Profile Data SOR endpoints.
 */
public class PyroscopeClient {

    private final WebClient client;

    public PyroscopeClient(Vertx vertx, String baseUrl) {
        URI uri = URI.create(baseUrl);
        String host = uri.getHost();
        int port = uri.getPort() > 0 ? uri.getPort()
                : ("https".equals(uri.getScheme()) ? 443 : 80);
        boolean ssl = "https".equals(uri.getScheme());

        this.client = WebClient.create(vertx, new WebClientOptions()
                .setDefaultHost(host)
                .setDefaultPort(port)
                .setSsl(ssl)
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

    public Future<List<String>> discoverApps(long from, long until) {
        return client.get("/pyroscope/label-values")
                .addQueryParam("label", "__name__")
                .addQueryParam("from", String.valueOf(from))
                .addQueryParam("until", String.valueOf(until))
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200) {
                        throw new RuntimeException(
                                "Pyroscope label-values failed (" + resp.statusCode() + "): "
                                        + resp.bodyAsString());
                    }
                    JsonArray arr = resp.bodyAsJsonArray();
                    Set<String> apps = new TreeSet<>();
                    for (int i = 0; i < arr.size(); i++) {
                        String name = arr.getString(i);
                        int lastDot = name.lastIndexOf('.');
                        if (lastDot > 0) {
                            apps.add(name.substring(0, lastDot));
                        }
                    }
                    return List.copyOf(apps);
                });
    }

    // ---- Flamebearer parsing ----

    public static final class FunctionSample {
        private final String name;
        private final long selfSamples;
        private final long totalSamples;
        private final long totalTicks;
        private final double selfPercent;

        public FunctionSample(String name, long selfSamples, long totalSamples,
                              long totalTicks, double selfPercent) {
            this.name = name;
            this.selfSamples = selfSamples;
            this.totalSamples = totalSamples;
            this.totalTicks = totalTicks;
            this.selfPercent = selfPercent;
        }

        public String name() { return name; }
        public long selfSamples() { return selfSamples; }
        public long totalSamples() { return totalSamples; }
        public long totalTicks() { return totalTicks; }
        public double selfPercent() { return selfPercent; }
    }

    /**
     * Parse flamebearer format into ranked function list.
     * Each level is a flat array of [offset, total, self, nameIndex] groups.
     */
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
                .collect(Collectors.toList());
    }
}
