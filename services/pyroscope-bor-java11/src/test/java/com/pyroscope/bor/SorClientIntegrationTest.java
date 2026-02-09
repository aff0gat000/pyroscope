package com.pyroscope.bor;

import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServer;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.handler.BodyHandler;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.*;
import org.junit.jupiter.api.extension.ExtendWith;

import java.util.concurrent.CopyOnWriteArrayList;
import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.*;

@ExtendWith(VertxExtension.class)
class SorClientIntegrationTest {

    private HttpServer mockServer;
    private SorClient sor;
    private final CopyOnWriteArrayList<JsonObject> postedHistories = new CopyOnWriteArrayList<>();

    @BeforeEach
    void setUp(Vertx vertx, VertxTestContext ctx) throws Exception {
        Router mockRouter = Router.router(vertx);
        mockRouter.route().handler(BodyHandler.create());

        mockRouter.get("/profiles/apps").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("apps", new JsonArray().add("app1").add("app2"))
                            .encode());
        });

        mockRouter.get("/profiles/:appName").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", rc.pathParam("appName"))
                            .put("functions", new JsonArray()
                                    .add(new JsonObject().put("name", "main").put("selfPercent", 50.0)))
                            .encode());
        });

        mockRouter.get("/baselines/:appName/:type").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("baselines", new JsonArray())
                            .encode());
        });

        mockRouter.post("/history").handler(rc -> {
            postedHistories.add(rc.body().asJsonObject());
            rc.response().setStatusCode(201)
                    .putHeader("content-type", "application/json")
                    .end(new JsonObject().put("id", 1).encode());
        });

        mockRouter.get("/services").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("services", new JsonArray())
                            .encode());
        });

        mockServer = vertx.createHttpServer();
        mockServer.requestHandler(mockRouter).listen(0).onComplete(ctx.succeeding(server -> {
            String url = "http://localhost:" + server.actualPort();
            sor = new SorClient(vertx, url, url, url, url);
            ctx.completeNow();
        }));

        assertThat(ctx.awaitCompletion(10, TimeUnit.SECONDS)).isTrue();
    }

    @AfterEach
    void tearDown() {
        if (mockServer != null) mockServer.close();
    }

    @Test
    void getProfile_sendsCorrectRequest(Vertx vertx, VertxTestContext ctx) {
        sor.getProfile("testApp", "cpu", 100, 200, 10)
                .onComplete(ctx.succeeding(result -> ctx.verify(() -> {
                    assertThat(result.getString("appName")).isEqualTo("testApp");
                    assertThat(result.getJsonArray("functions")).isNotEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void getApps_parsesArray(Vertx vertx, VertxTestContext ctx) {
        sor.getApps(100, 200)
                .onComplete(ctx.succeeding(result -> ctx.verify(() -> {
                    assertThat(result).containsExactly("app1", "app2");
                    ctx.completeNow();
                })));
    }

    @Test
    void getBaselines_nullClient_returnsEmpty(Vertx vertx, VertxTestContext ctx) {
        // Create a lite client with no baseline URL
        SorClient liteClient = new SorClient(vertx, "http://localhost:" + mockServer.actualPort());
        liteClient.getBaselines("app", "cpu")
                .onComplete(ctx.succeeding(result -> ctx.verify(() -> {
                    assertThat(result.getJsonArray("baselines")).isEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void saveHistory_fireAndForget(Vertx vertx, VertxTestContext ctx) {
        JsonObject assessment = new JsonObject()
                .put("appName", "testApp")
                .put("diagnosis", "cpu_bound")
                .put("severity", "medium");

        sor.saveHistory(assessment)
                .onComplete(ctx.succeeding(result -> ctx.verify(() -> {
                    assertThat(postedHistories).hasSize(1);
                    assertThat(postedHistories.get(0).getString("appName")).isEqualTo("testApp");
                    ctx.completeNow();
                })));
    }
}
