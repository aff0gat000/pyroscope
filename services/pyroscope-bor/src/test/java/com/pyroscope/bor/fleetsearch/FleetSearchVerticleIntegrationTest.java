package com.pyroscope.bor.fleetsearch;

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

@ExtendWith(VertxExtension.class)
class FleetSearchVerticleIntegrationTest {

    private HttpServer mockSor;
    private int verticlePort;
    private WebClient client;

    @BeforeEach
    void setUp(Vertx vertx, VertxTestContext ctx) throws Exception {
        client = WebClient.create(vertx);

        Router mockRouter = Router.router(vertx);

        // Mock profile endpoint
        mockRouter.get("/profiles/:appName").handler(rc -> {
            String appName = rc.pathParam("appName");
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("functions", new JsonArray()
                                    .add(new JsonObject()
                                            .put("name", "com.app.processPayment")
                                            .put("selfPercent", 15.0)
                                            .put("selfSamples", 1500L))
                                    .add(new JsonObject()
                                            .put("name", "com.app.handleRequest")
                                            .put("selfPercent", 8.0)
                                            .put("selfSamples", 800L)))
                            .encode());
        });

        // Mock apps endpoint
        mockRouter.get("/profiles/apps").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("apps", new JsonArray().add("svc-a").add("svc-b"))
                            .encode());
        });

        mockSor = vertx.createHttpServer();
        mockSor.requestHandler(mockRouter).listen(0).onComplete(ctx.succeeding(server -> {
            int mockPort = server.actualPort();
            verticlePort = mockPort + 1000;
            var verticle = new FleetSearchVerticle("http://localhost:" + mockPort, verticlePort);
            vertx.deployVerticle(verticle).onComplete(ctx.succeeding(id -> ctx.completeNow()));
        }));

        assertThat(ctx.awaitCompletion(10, TimeUnit.SECONDS)).isTrue();
    }

    @AfterEach
    void tearDown() {
        if (mockSor != null) mockSor.close();
    }

    @Test
    void search_missingFunction_returns400(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/search").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    ctx.completeNow();
                })));
    }

    @Test
    void search_matchesFound_returnsResults(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/search")
                .addQueryParam("function", "processPayment")
                .addQueryParam("apps", "svc-a,svc-b")
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("query")).isEqualTo("processPayment");
                    assertThat(body.getInteger("matchCount")).isGreaterThan(0);
                    ctx.completeNow();
                })));
    }

    @Test
    void hotspots_rankedByImpactScore(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/fleet/hotspots")
                .addQueryParam("apps", "svc-a,svc-b")
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    JsonArray hotspots = body.getJsonArray("hotspots");
                    assertThat(hotspots).isNotNull();
                    assertThat(hotspots.size()).isGreaterThan(0);
                    // First hotspot should have highest impact score
                    if (hotspots.size() > 1) {
                        double first = hotspots.getJsonObject(0).getDouble("impactScore");
                        double second = hotspots.getJsonObject(1).getDouble("impactScore");
                        assertThat(first).isGreaterThanOrEqualTo(second);
                    }
                    ctx.completeNow();
                })));
    }
}
