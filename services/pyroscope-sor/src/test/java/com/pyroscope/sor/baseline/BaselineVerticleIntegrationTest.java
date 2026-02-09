package com.pyroscope.sor.baseline;

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
class BaselineVerticleIntegrationTest {

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
        testDb.queryWithRetry("TRUNCATE performance_baseline RESTART IDENTITY CASCADE", 1)
                .compose(v -> vertx.deployVerticle(new BaselineVerticle(verticlePort)))
                .onComplete(ctx.succeeding(id -> ctx.completeNow()));

        assertThat(ctx.awaitCompletion(30, TimeUnit.SECONDS)).isTrue();
    }

    @Test
    void create_baseline_returns201(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "my-service")
                .put("profileType", "cpu")
                .put("functionName", "com.example.HotMethod.run")
                .put("maxSelfPercent", 15.5)
                .put("severity", "critical")
                .put("createdBy", "tester");

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    JsonObject json = resp.bodyAsJsonObject();
                    assertThat(json.getInteger("id")).isGreaterThan(0);
                    assertThat(json.getString("appName")).isEqualTo("my-service");
                    assertThat(json.getString("profileType")).isEqualTo("cpu");
                    assertThat(json.getString("functionName")).isEqualTo("com.example.HotMethod.run");
                    assertThat(json.getDouble("maxSelfPercent")).isEqualTo(15.5);
                    assertThat(json.getString("severity")).isEqualTo("critical");
                    assertThat(json.getString("createdAt")).isNotNull();
                    assertThat(json.getString("updatedAt")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void create_baseline_defaultsSeverityToWarning(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-a")
                .put("profileType", "cpu")
                .put("functionName", "com.example.Foo.bar")
                .put("maxSelfPercent", 5.0);

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    assertThat(resp.bodyAsJsonObject().getString("severity")).isEqualTo("warning");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_baseline_missingFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-a");

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("required");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_baseline_upsertOnConflict(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-upsert")
                .put("profileType", "cpu")
                .put("functionName", "com.example.Dup.run")
                .put("maxSelfPercent", 10.0)
                .put("severity", "warning");

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp1 -> ctx.verify(() -> {
                    assertThat(resp1.statusCode()).isEqualTo(201);
                    int firstId = resp1.bodyAsJsonObject().getInteger("id");

                    // Upsert with updated threshold
                    JsonObject updated = body.copy().put("maxSelfPercent", 20.0).put("severity", "critical");
                    client.post(verticlePort, "localhost", "/baselines")
                            .sendJsonObject(updated, ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(201);
                                assertThat(resp2.bodyAsJsonObject().getInteger("id")).isEqualTo(firstId);
                                assertThat(resp2.bodyAsJsonObject().getDouble("maxSelfPercent")).isEqualTo(20.0);
                                ctx.completeNow();
                            })));
                })));
    }

    @Test
    void listByApp_returnsBaselinesForApp(Vertx vertx, VertxTestContext ctx) {
        JsonObject b1 = new JsonObject()
                .put("appName", "app-list")
                .put("profileType", "cpu")
                .put("functionName", "fn1")
                .put("maxSelfPercent", 5.0);
        JsonObject b2 = new JsonObject()
                .put("appName", "app-list")
                .put("profileType", "alloc")
                .put("functionName", "fn2")
                .put("maxSelfPercent", 8.0);

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(b1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/baselines")
                            .sendJsonObject(b2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/baselines/app-list")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getString("appName")).isEqualTo("app-list");
                                            assertThat(json.getJsonArray("baselines").size()).isEqualTo(2);
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listByApp_emptyResult(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/baselines/nonexistent-app")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getJsonArray("baselines")).isEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void listByAppAndType_filtersCorrectly(Vertx vertx, VertxTestContext ctx) {
        JsonObject b1 = new JsonObject()
                .put("appName", "app-type")
                .put("profileType", "cpu")
                .put("functionName", "fn-cpu")
                .put("maxSelfPercent", 5.0);
        JsonObject b2 = new JsonObject()
                .put("appName", "app-type")
                .put("profileType", "alloc")
                .put("functionName", "fn-alloc")
                .put("maxSelfPercent", 8.0);

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(b1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/baselines")
                            .sendJsonObject(b2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/baselines/app-type/cpu")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getString("appName")).isEqualTo("app-type");
                                            assertThat(json.getString("profileType")).isEqualTo("cpu");
                                            assertThat(json.getJsonArray("baselines").size()).isEqualTo(1);
                                            assertThat(json.getJsonArray("baselines")
                                                    .getJsonObject(0).getString("functionName"))
                                                    .isEqualTo("fn-cpu");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void update_baseline_changesThreshold(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-upd")
                .put("profileType", "cpu")
                .put("functionName", "fn-upd")
                .put("maxSelfPercent", 10.0);

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    JsonObject patch = new JsonObject()
                            .put("maxSelfPercent", 25.0)
                            .put("severity", "critical");

                    client.put(verticlePort, "localhost", "/baselines/" + id)
                            .sendJsonObject(patch, ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(200);
                                JsonObject updated = resp2.bodyAsJsonObject();
                                assertThat(updated.getDouble("maxSelfPercent")).isEqualTo(25.0);
                                assertThat(updated.getString("severity")).isEqualTo("critical");
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void update_baseline_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        JsonObject patch = new JsonObject().put("maxSelfPercent", 99.0);

        client.put(verticlePort, "localhost", "/baselines/99999")
                .sendJsonObject(patch, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
    }

    @Test
    void update_baseline_noFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject empty = new JsonObject();

        client.put(verticlePort, "localhost", "/baselines/1")
                .sendJsonObject(empty, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("required");
                    ctx.completeNow();
                })));
    }

    @Test
    void delete_baseline_returns204(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-del")
                .put("profileType", "cpu")
                .put("functionName", "fn-del")
                .put("maxSelfPercent", 5.0);

        client.post(verticlePort, "localhost", "/baselines")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    client.delete(verticlePort, "localhost", "/baselines/" + id)
                            .send(ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(204);

                                // Verify it was actually deleted
                                client.get(verticlePort, "localhost", "/baselines/svc-del")
                                        .send(ctx.succeeding(resp3 -> ctx.verify(() -> {
                                            assertThat(resp3.bodyAsJsonObject()
                                                    .getJsonArray("baselines")).isEmpty();
                                            ctx.completeNow();
                                        })));
                            })));
                }));
    }

    @Test
    void delete_baseline_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.delete(verticlePort, "localhost", "/baselines/99999")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
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
