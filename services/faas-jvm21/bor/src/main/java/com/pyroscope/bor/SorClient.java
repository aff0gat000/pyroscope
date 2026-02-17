package com.pyroscope.bor;

import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.buffer.Buffer;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.client.WebClient;
import io.vertx.ext.web.client.WebClientOptions;

import java.net.URI;
import java.util.List;

/**
 * HTTP client for calling SOR layer services.
 * BORs use this to access data — never calling data stores directly.
 *
 * <p>Lite BORs use the single-arg constructor (Profile Data SOR only).
 * Full BORs use the multi-arg constructor to also call Baseline, History,
 * and Registry SORs backed by PostgreSQL.
 */
public class SorClient {

    private final WebClient profileData;
    private WebClient baseline;
    private WebClient history;
    private WebClient registry;

    /** Lite constructor — only Profile Data SOR (Pyroscope, no database). */
    public SorClient(Vertx vertx, String profileDataUrl) {
        this.profileData = createClient(vertx, profileDataUrl);
    }

    /** Full constructor — Profile Data SOR + PostgreSQL-backed SORs. */
    public SorClient(Vertx vertx, String profileDataUrl,
                     String baselineUrl, String historyUrl, String registryUrl) {
        this.profileData = createClient(vertx, profileDataUrl);
        if (baselineUrl != null) this.baseline = createClient(vertx, baselineUrl);
        if (historyUrl != null) this.history = createClient(vertx, historyUrl);
        if (registryUrl != null) this.registry = createClient(vertx, registryUrl);
    }

    private static WebClient createClient(Vertx vertx, String url) {
        URI uri = URI.create(url);
        return WebClient.create(vertx, new WebClientOptions()
                .setDefaultHost(uri.getHost())
                .setDefaultPort(uri.getPort() > 0 ? uri.getPort()
                        : ("https".equals(uri.getScheme()) ? 443 : 80))
                .setSsl("https".equals(uri.getScheme()))
                .setConnectTimeout(5000)
                .setIdleTimeout(30));
    }

    /**
     * Get a parsed profile from the Profile Data SOR.
     * Returns: { appName, profileType, from, to, totalSamples, functions: [...] }
     */
    public Future<JsonObject> getProfile(String appName, String type,
                                         long from, long to, int limit) {
        return profileData.get("/profiles/" + appName)
                .addQueryParam("type", type)
                .addQueryParam("from", String.valueOf(from))
                .addQueryParam("to", String.valueOf(to))
                .addQueryParam("limit", String.valueOf(limit))
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200)
                        throw new RuntimeException(
                                "Profile Data SOR error (" + resp.statusCode() + "): "
                                        + resp.bodyAsString());
                    return resp.bodyAsJsonObject();
                });
    }

    /**
     * Get baseline and current profiles for comparison.
     * Returns: { appName, profileType, baseline: { functions }, current: { functions } }
     */
    public Future<JsonObject> getProfileDiff(String appName, String type,
                                             long baselineFrom, long baselineTo,
                                             long from, long to, int limit) {
        return profileData.get("/profiles/" + appName + "/diff")
                .addQueryParam("type", type)
                .addQueryParam("baselineFrom", String.valueOf(baselineFrom))
                .addQueryParam("baselineTo", String.valueOf(baselineTo))
                .addQueryParam("from", String.valueOf(from))
                .addQueryParam("to", String.valueOf(to))
                .addQueryParam("limit", String.valueOf(limit))
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200)
                        throw new RuntimeException(
                                "Profile Data SOR error (" + resp.statusCode() + "): "
                                        + resp.bodyAsString());
                    return resp.bodyAsJsonObject();
                });
    }

    /**
     * Discover all monitored applications.
     * Returns list of app names.
     */
    public Future<List<String>> getApps(long from, long to) {
        return profileData.get("/profiles/apps")
                .addQueryParam("from", String.valueOf(from))
                .addQueryParam("to", String.valueOf(to))
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200)
                        throw new RuntimeException(
                                "Profile Data SOR error (" + resp.statusCode() + "): "
                                        + resp.bodyAsString());
                    JsonArray arr = resp.bodyAsJsonObject().getJsonArray("apps");
                    return arr.stream().map(Object::toString).collect(java.util.stream.Collectors.toList());
                });
    }

    // ---- Baseline SOR (PostgreSQL) ----

    /**
     * Get stored baselines for an app and profile type.
     * Returns: { appName, profileType, baselines: [...] }
     */
    public Future<JsonObject> getBaselines(String appName, String type) {
        if (baseline == null) return Future.succeededFuture(
                new JsonObject().put("baselines", new JsonArray()));
        return baseline.get("/baselines/" + appName + "/" + type)
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200) return new JsonObject()
                            .put("baselines", new JsonArray());
                    return resp.bodyAsJsonObject();
                });
    }

    // ---- History SOR (PostgreSQL) ----

    /**
     * Save a triage assessment to the audit trail.
     * Fire-and-forget — failure does not block the response.
     */
    public Future<JsonObject> saveHistory(JsonObject assessment) {
        if (history == null) return Future.succeededFuture(new JsonObject());
        return history.post("/history")
                .sendJsonObject(assessment)
                .map(resp -> {
                    if (resp.statusCode() == 201) return resp.bodyAsJsonObject();
                    return new JsonObject().put("saved", false);
                });
    }

    // ---- Registry SOR (PostgreSQL) ----

    /**
     * Get all registered services. Returns: { count, services: [...] }
     */
    public Future<JsonObject> getServices() {
        if (registry == null) return Future.succeededFuture(
                new JsonObject().put("services", new JsonArray()));
        return registry.get("/services")
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200) return new JsonObject()
                            .put("services", new JsonArray());
                    return resp.bodyAsJsonObject();
                });
    }

    /**
     * Get a single service's metadata. Returns service JSON or empty object.
     */
    public Future<JsonObject> getService(String appName) {
        if (registry == null) return Future.succeededFuture(new JsonObject());
        return registry.get("/services/" + appName)
                .send()
                .map(resp -> {
                    if (resp.statusCode() != 200) return new JsonObject();
                    return resp.bodyAsJsonObject();
                });
    }
}
