package com.pyroscope.sor.profiledata;

import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServer;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.client.WebClient;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;

import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;

/**
 * Integration tests for ProfileDataVerticle using a mock Pyroscope HTTP server.
 * No Testcontainers needed — this verticle wraps the Pyroscope HTTP API, not PostgreSQL.
 */
@ExtendWith(VertxExtension.class)
@TestMethodOrder(MethodOrderer.OrderAnnotation.class)
class ProfileDataVerticleIntegrationTest {

    private static int mockPyroscopePort;
    private static int verticlePort;
    private static HttpServer mockServer;
    private WebClient client;

    /** Whether the mock should return errors instead of success responses. */
    private static volatile boolean failMode = false;

    @BeforeAll
    static void startMockPyroscope(Vertx vertx, VertxTestContext ctx) throws Exception {
        mockPyroscopePort = 22080 + (int) (Math.random() * 1000);
        verticlePort = mockPyroscopePort + 1000;

        Router mockRouter = Router.router(vertx);

        // Mock: GET /pyroscope/render
        mockRouter.get("/pyroscope/render").handler(rc -> {
            if (failMode) {
                rc.response().setStatusCode(500).end("Internal Server Error");
                return;
            }
            String query = rc.request().getParam("query");
            // Return a minimal flamebearer response with two functions
            rc.response()
                    .putHeader("content-type", "application/json")
                    .end(flamebearerResponse(query).encodePrettily());
        });

        // Mock: GET /pyroscope/label-values
        mockRouter.get("/pyroscope/label-values").handler(rc -> {
            if (failMode) {
                rc.response().setStatusCode(500).end("Internal Server Error");
                return;
            }
            // Return label values in the format Pyroscope uses: appName.profileType
            rc.response()
                    .putHeader("content-type", "application/json")
                    .end(new JsonArray()
                            .add("payments-api.cpu")
                            .add("payments-api.alloc_in_new_tlab_bytes")
                            .add("orders-svc.cpu")
                            .encodePrettily());
        });

        mockServer = vertx.createHttpServer()
                .requestHandler(mockRouter)
                .listen(mockPyroscopePort)
                .toCompletionStage()
                .toCompletableFuture()
                .get(10, TimeUnit.SECONDS);

        // Deploy the real ProfileDataVerticle pointing at the mock
        var verticle = new ProfileDataVerticle(
                "http://localhost:" + mockPyroscopePort, verticlePort);
        vertx.deployVerticle(verticle)
                .onComplete(ctx.succeeding(id -> ctx.completeNow()));

        assertThat(ctx.awaitCompletion(30, TimeUnit.SECONDS)).isTrue();
    }

    @BeforeEach
    void setUp(Vertx vertx) {
        client = WebClient.create(vertx);
        failMode = false;
    }

    @Test
    void getProfile_returnsFormattedFunctions(Vertx vertx, VertxTestContext ctx) {
        long now = System.currentTimeMillis() / 1000;
        client.get(verticlePort, "localhost",
                        "/profiles/test-app?type=cpu&from=" + (now - 3600) + "&to=" + now)
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("appName")).isEqualTo("test-app");
                    assertThat(body.getString("profileType")).isEqualTo("cpu");
                    JsonArray functions = body.getJsonArray("functions");
                    assertThat(functions).isNotNull();
                    assertThat(functions.size()).isGreaterThan(0);
                    // Verify function structure
                    JsonObject firstFn = functions.getJsonObject(0);
                    assertThat(firstFn.getString("name")).isNotNull();
                    assertThat(firstFn.getDouble("selfPercent")).isNotNull();
                    assertThat(firstFn.getLong("selfSamples")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void getProfileDiff_returnsBothWindows(Vertx vertx, VertxTestContext ctx) {
        long now = System.currentTimeMillis() / 1000;
        String url = "/profiles/test-app/diff?type=cpu"
                + "&from=" + (now - 3600) + "&to=" + now
                + "&baselineFrom=" + (now - 7200) + "&baselineTo=" + (now - 3600);

        client.get(verticlePort, "localhost", url).send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("appName")).isEqualTo("test-app");
                    assertThat(body.getString("profileType")).isEqualTo("cpu");
                    // Both baseline and current windows present
                    JsonObject baseline = body.getJsonObject("baseline");
                    JsonObject current = body.getJsonObject("current");
                    assertThat(baseline).isNotNull();
                    assertThat(current).isNotNull();
                    assertThat(baseline.getJsonArray("functions")).isNotNull();
                    assertThat(current.getJsonArray("functions")).isNotNull();
                    assertThat(baseline.containsKey("from")).isTrue();
                    assertThat(baseline.containsKey("to")).isTrue();
                    assertThat(current.containsKey("from")).isTrue();
                    assertThat(current.containsKey("to")).isTrue();
                    ctx.completeNow();
                })));
    }

    @Test
    void getApps_returnsDiscoveredApps(Vertx vertx, VertxTestContext ctx) {
        long now = System.currentTimeMillis() / 1000;
        client.get(verticlePort, "localhost",
                        "/profiles/apps?from=" + (now - 3600) + "&to=" + now)
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    JsonArray apps = body.getJsonArray("apps");
                    assertThat(apps).isNotNull();
                    // The mock returns payments-api.cpu, payments-api.alloc, orders-svc.cpu
                    // PyroscopeClient strips the suffix, deduplicates, and sorts
                    assertThat(apps.size()).isEqualTo(2);
                    assertThat(apps.contains("orders-svc")).isTrue();
                    assertThat(apps.contains("payments-api")).isTrue();
                    ctx.completeNow();
                })));
    }

    @Test
    void pyroscopeFailure_returns502(Vertx vertx, VertxTestContext ctx) {
        failMode = true;
        long now = System.currentTimeMillis() / 1000;
        client.get(verticlePort, "localhost",
                        "/profiles/test-app?type=cpu&from=" + (now - 3600) + "&to=" + now)
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(502);
                    assertThat(resp.bodyAsJsonObject().getString("error")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void getProfile_defaultParams_works(Vertx vertx, VertxTestContext ctx) {
        // Call without explicit from/to/type to test defaults
        client.get(verticlePort, "localhost", "/profiles/test-app").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("appName")).isEqualTo("test-app");
                    assertThat(body.getString("profileType")).isEqualTo("cpu");
                    ctx.completeNow();
                })));
    }

    /**
     * Build a minimal valid flamebearer response that the PyroscopeClient can parse.
     * Contains two functions: "com.app.Main.run" (high self) and "java.lang.Thread.run" (low self).
     */
    private static JsonObject flamebearerResponse(String query) {
        return new JsonObject().put("flamebearer", new JsonObject()
                .put("names", new JsonArray()
                        .add("total")
                        .add("com.app.Main.run")
                        .add("java.lang.Thread.run"))
                .put("levels", new JsonArray()
                        // Level 0: root
                        .add(new JsonArray().add(0).add(1000).add(0).add(0))
                        // Level 1: two children
                        .add(new JsonArray()
                                .add(0).add(700).add(500).add(1)
                                .add(700).add(300).add(200).add(2)))
                .put("numTicks", 1000L));
    }
}
