package com.pyroscope.sor.history;

import com.pyroscope.sor.DbClient;
import io.vertx.core.Vertx;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.client.WebClient;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import io.vertx.pgclient.PgConnectOptions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers
@ExtendWith(VertxExtension.class)
class TriageHistoryVerticleIntegrationTest {

    @Container
    static PostgreSQLContainer<?> pg = new PostgreSQLContainer<>("postgres:15")
            .withInitScript("schema.sql");

    private static int verticlePort;
    private WebClient client;

    @BeforeAll
    static void configureEnv() throws Exception {
        setEnv("DB_HOST", pg.getHost());
        setEnv("DB_PORT", String.valueOf(pg.getMappedPort(5432)));
        setEnv("DB_NAME", pg.getDatabaseName());
        setEnv("DB_USER", pg.getUsername());
        setEnv("DB_PASSWORD", pg.getPassword());
    }

    @BeforeEach
    void setUp(Vertx vertx, VertxTestContext ctx) throws Exception {
        client = WebClient.create(vertx);
        verticlePort = 18080 + (int) (Math.random() * 1000);

        var connectOptions = new PgConnectOptions()
                .setHost(pg.getHost())
                .setPort(pg.getMappedPort(5432))
                .setDatabase(pg.getDatabaseName())
                .setUser(pg.getUsername())
                .setPassword(pg.getPassword());
        var testDb = new DbClient(vertx, connectOptions, 2);
        testDb.queryWithRetry("TRUNCATE triage_history RESTART IDENTITY CASCADE", 1)
                .compose(v -> vertx.deployVerticle(new TriageHistoryVerticle(verticlePort)))
                .onComplete(ctx.succeeding(id -> ctx.completeNow()));

        assertThat(ctx.awaitCompletion(30, TimeUnit.SECONDS)).isTrue();
    }

    @Test
    void create_history_returns201(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "my-service")
                .put("profileTypes", "cpu,alloc")
                .put("diagnosis", "high CPU in serializer")
                .put("severity", "critical")
                .put("topFunctions", new JsonObject().put("serialize", 42.5))
                .put("recommendation", "optimize serialization path")
                .put("requestedBy", "tester");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    JsonObject json = resp.bodyAsJsonObject();
                    assertThat(json.getInteger("id")).isGreaterThan(0);
                    assertThat(json.getString("appName")).isEqualTo("my-service");
                    assertThat(json.getString("diagnosis")).isEqualTo("high CPU in serializer");
                    assertThat(json.getString("severity")).isEqualTo("critical");
                    assertThat(json.getString("createdAt")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void create_history_defaultsProfileTypesToCpu(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-default")
                .put("diagnosis", "normal")
                .put("severity", "info");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    // Verify default profile type by fetching the record
                    client.get(verticlePort, "localhost", "/history/svc-default")
                            .send(ctx.succeeding(listResp -> ctx.verify(() -> {
                                var history = listResp.bodyAsJsonObject()
                                        .getJsonArray("history").getJsonObject(0);
                                assertThat(history.getString("profileTypes")).isEqualTo("cpu");
                                ctx.completeNow();
                            })));
                })));
    }

    @Test
    void create_history_missingFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-a");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("required");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_history_noBody_returns400(Vertx vertx, VertxTestContext ctx) {
        client.post(verticlePort, "localhost", "/history")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    ctx.completeNow();
                })));
    }

    @Test
    void listByApp_returnsHistoryEntries(Vertx vertx, VertxTestContext ctx) {
        JsonObject entry1 = new JsonObject()
                .put("appName", "app-list")
                .put("diagnosis", "high CPU")
                .put("severity", "warning");
        JsonObject entry2 = new JsonObject()
                .put("appName", "app-list")
                .put("diagnosis", "memory leak")
                .put("severity", "critical");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(entry1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/history")
                            .sendJsonObject(entry2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/history/app-list")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getString("appName")).isEqualTo("app-list");
                                            assertThat(json.getInteger("count")).isEqualTo(2);
                                            assertThat(json.getJsonArray("history").size()).isEqualTo(2);
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listByApp_respectsLimitParam(Vertx vertx, VertxTestContext ctx) {
        JsonObject entry1 = new JsonObject()
                .put("appName", "app-limit")
                .put("diagnosis", "issue1")
                .put("severity", "info");
        JsonObject entry2 = new JsonObject()
                .put("appName", "app-limit")
                .put("diagnosis", "issue2")
                .put("severity", "warning");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(entry1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/history")
                            .sendJsonObject(entry2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/history/app-limit?limit=1")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            assertThat(resp.bodyAsJsonObject()
                                                    .getJsonArray("history").size()).isEqualTo(1);
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listByApp_emptyResult(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/history/nonexistent-app")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("count")).isEqualTo(0);
                    assertThat(resp.bodyAsJsonObject().getJsonArray("history")).isEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void latest_returnsLatestEntry(Vertx vertx, VertxTestContext ctx) {
        JsonObject entry1 = new JsonObject()
                .put("appName", "app-latest")
                .put("diagnosis", "first issue")
                .put("severity", "info");
        JsonObject entry2 = new JsonObject()
                .put("appName", "app-latest")
                .put("diagnosis", "second issue")
                .put("severity", "critical");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(entry1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/history")
                            .sendJsonObject(entry2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/history/app-latest/latest")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getString("appName")).isEqualTo("app-latest");
                                            assertThat(json.getString("diagnosis")).isEqualTo("second issue");
                                            assertThat(json.getString("severity")).isEqualTo("critical");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void latest_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/history/no-such-app/latest")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("no triage history");
                    ctx.completeNow();
                })));
    }

    @Test
    void delete_history_returns204(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-del")
                .put("diagnosis", "to be deleted")
                .put("severity", "info");

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    client.delete(verticlePort, "localhost", "/history/" + id)
                            .send(ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(204);

                                // Verify it was actually deleted
                                client.get(verticlePort, "localhost", "/history/svc-del")
                                        .send(ctx.succeeding(resp3 -> ctx.verify(() -> {
                                            assertThat(resp3.bodyAsJsonObject()
                                                    .getJsonArray("history")).isEmpty();
                                            ctx.completeNow();
                                        })));
                            })));
                }));
    }

    @Test
    void delete_history_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.delete(verticlePort, "localhost", "/history/99999")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
    }

    @Test
    void create_history_withTopFunctions_persists(Vertx vertx, VertxTestContext ctx) {
        JsonObject topFunctions = new JsonObject()
                .put("com.example.Foo.bar", 35.2)
                .put("com.example.Baz.qux", 12.1);

        JsonObject body = new JsonObject()
                .put("appName", "app-topfn")
                .put("diagnosis", "hotspot detected")
                .put("severity", "warning")
                .put("topFunctions", topFunctions);

        client.post(verticlePort, "localhost", "/history")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    client.get(verticlePort, "localhost", "/history/app-topfn/latest")
                            .send(ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(200);
                                JsonObject json = resp2.bodyAsJsonObject();
                                assertThat(json.getString("diagnosis")).isEqualTo("hotspot detected");
                                // topFunctions should be persisted as JSONB
                                assertThat(json.containsKey("topFunctions")).isTrue();
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void health_endpoint_returnsOK(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/health")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsString()).isEqualTo("OK");
                    ctx.completeNow();
                })));
    }

    @SuppressWarnings("unchecked")
    private static void setEnv(String key, String value) throws Exception {
        var env = System.getenv();
        java.lang.reflect.Field field = env.getClass().getDeclaredField("m");
        field.setAccessible(true);
        ((java.util.Map<String, String>) field.get(env)).put(key, value);
    }
}
