package com.pyroscope.bor.triage;

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
class TriageVerticleIntegrationTest {

    private HttpServer mockPyroscope;
    private int mockPort;
    private int verticlePort;
    private WebClient client;

    @BeforeEach
    void setUp(Vertx vertx, VertxTestContext ctx) throws Exception {
        client = WebClient.create(vertx);

        // Mock Pyroscope server
        Router mockRouter = Router.router(vertx);
        mockRouter.get("/pyroscope/render").handler(rc -> {
            String query = rc.request().getParam("query");
            String profileType = query != null && query.contains("alloc") ? "alloc" : "cpu";
            double selfPct = profileType.equals("cpu") ? 35.0 : 8.0;
            String funcName = profileType.equals("cpu") ? "com.app.GC.collect" : "com.app.Service.handle";
            rc.response()
                    .putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("flamebearer", new JsonObject()
                                    .put("names", new JsonArray().add("root").add(funcName))
                                    .put("levels", new JsonArray()
                                            .add(new JsonArray().add(0).add(1000).add(0).add(0))
                                            .add(new JsonArray().add(0).add(1000).add((int)(selfPct * 10)).add(1)))
                                    .put("numTicks", 1000L))
                            .encode());
        });

        mockPyroscope = vertx.createHttpServer();
        mockPyroscope.requestHandler(mockRouter).listen(0).onComplete(ctx.succeeding(server -> {
            mockPort = server.actualPort();
            verticlePort = mockPort + 1000;
            var verticle = new TriageVerticle("http://localhost:" + mockPort, verticlePort);
            vertx.deployVerticle(verticle).onComplete(ctx.succeeding(id -> ctx.completeNow()));
        }));

        assertThat(ctx.awaitCompletion(10, TimeUnit.SECONDS)).isTrue();
    }

    @AfterEach
    void tearDown() {
        if (mockPyroscope != null) mockPyroscope.close();
    }

    @Test
    void healthCheck_returns200(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/health").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsString()).isEqualTo("OK");
                    ctx.completeNow();
                })));
    }

    @Test
    void triage_defaultParams_returnsCpuAndAlloc(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/triage/myapp").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("appName")).isEqualTo("myapp");
                    assertThat(body.getJsonObject("profiles").containsKey("cpu")).isTrue();
                    assertThat(body.getJsonObject("profiles").containsKey("alloc")).isTrue();
                    ctx.completeNow();
                })));
    }

    @Test
    void triage_responseContainsExpectedFields(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/triage/myapp").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.containsKey("appName")).isTrue();
                    assertThat(body.containsKey("from")).isTrue();
                    assertThat(body.containsKey("to")).isTrue();
                    assertThat(body.containsKey("profiles")).isTrue();
                    assertThat(body.containsKey("summary")).isTrue();
                    JsonObject summary = body.getJsonObject("summary");
                    assertThat(summary.containsKey("primaryIssue")).isTrue();
                    assertThat(summary.containsKey("severity")).isTrue();
                    assertThat(summary.containsKey("recommendation")).isTrue();
                    ctx.completeNow();
                })));
    }

    @Test
    void triage_gcProfile_diagnosesGcPressure(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/triage/myapp")
                .addQueryParam("types", "cpu")
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    JsonObject body = resp.bodyAsJsonObject();
                    JsonObject cpuProfile = body.getJsonObject("profiles").getJsonObject("cpu");
                    assertThat(cpuProfile.getString("diagnosis")).isEqualTo("gc_pressure");
                    ctx.completeNow();
                })));
    }

    @Test
    void triage_highSeverity_above30percent(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/triage/myapp")
                .addQueryParam("types", "cpu")
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getJsonObject("summary").getString("severity")).isEqualTo("high");
                    ctx.completeNow();
                })));
    }

    @Test
    void triage_pyroscopeDown_returns502orDiagnosisUnavailable(Vertx vertx, VertxTestContext ctx) {
        // Close mock server to simulate Pyroscope being down
        mockPyroscope.close().onComplete(v -> {
            client.get(verticlePort, "localhost", "/triage/myapp")
                    .addQueryParam("types", "cpu")
                    .send()
                    .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                        JsonObject body = resp.bodyAsJsonObject();
                        // The verticle catches failures per-type and returns "unavailable"
                        JsonObject cpuProfile = body.getJsonObject("profiles").getJsonObject("cpu");
                        assertThat(cpuProfile.getString("diagnosis")).isEqualTo("unavailable");
                        ctx.completeNow();
                    })));
        });
    }
}
