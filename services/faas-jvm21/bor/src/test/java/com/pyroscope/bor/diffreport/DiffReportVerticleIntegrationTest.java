package com.pyroscope.bor.diffreport;

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
class DiffReportVerticleIntegrationTest {

    private HttpServer mockSor;
    private int verticlePort;
    private WebClient client;

    @BeforeEach
    void setUp(Vertx vertx, VertxTestContext ctx) throws Exception {
        client = WebClient.create(vertx);

        Router mockRouter = Router.router(vertx);
        mockRouter.get("/profiles/:appName/diff").handler(rc -> {
            rc.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("baseline", new JsonObject()
                                    .put("functions", new JsonArray()
                                            .add(fn("com.app.Foo.bar", 10.0))
                                            .add(fn("com.app.Baz.qux", 5.0))))
                            .put("current", new JsonObject()
                                    .put("functions", new JsonArray()
                                            .add(fn("com.app.Foo.bar", 15.0))
                                            .add(fn("com.app.Baz.qux", 3.0))))
                            .encode());
        });

        mockSor = vertx.createHttpServer();
        mockSor.requestHandler(mockRouter).listen(0).onComplete(ctx.succeeding(server -> {
            int mockPort = server.actualPort();
            verticlePort = mockPort + 1000;
            var verticle = new DiffReportVerticle("http://localhost:" + mockPort, verticlePort);
            vertx.deployVerticle(verticle).onComplete(ctx.succeeding(id -> ctx.completeNow()));
        }));

        assertThat(ctx.awaitCompletion(10, TimeUnit.SECONDS)).isTrue();
    }

    @AfterEach
    void tearDown() {
        if (mockSor != null) mockSor.close();
    }

    @Test
    void diff_jsonFormat_containsRegressionsAndImprovements(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/diff/myapp").send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    JsonObject body = resp.bodyAsJsonObject();
                    assertThat(body.getString("appName")).isEqualTo("myapp");
                    assertThat(body.getJsonArray("regressions")).isNotEmpty();
                    assertThat(body.getJsonArray("improvements")).isNotEmpty();
                    // Foo.bar went from 10 to 15 = +5 regression
                    // Baz.qux went from 5 to 3 = -2 improvement
                    ctx.completeNow();
                })));
    }

    @Test
    void diff_markdownFormat_returnsTextMarkdown(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/diff/myapp")
                .addQueryParam("format", "markdown")
                .send()
                .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.getHeader("content-type")).isEqualTo("text/markdown");
                    assertThat(resp.bodyAsString()).contains("# Diff Report: myapp");
                    ctx.completeNow();
                })));
    }

    @Test
    void diff_sorFailure_returns502(Vertx vertx, VertxTestContext ctx) {
        mockSor.close().onComplete(v -> {
            client.get(verticlePort, "localhost", "/diff/myapp").send()
                    .onComplete(ctx.succeeding(resp -> ctx.verify(() -> {
                        assertThat(resp.statusCode()).isEqualTo(502);
                        ctx.completeNow();
                    })));
        });
    }

    private static JsonObject fn(String name, double selfPercent) {
        return new JsonObject().put("name", name).put("selfPercent", selfPercent);
    }
}
