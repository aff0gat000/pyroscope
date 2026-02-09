package com.pyroscope.sor.alertrule;

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
class AlertRuleVerticleIntegrationTest {

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
        testDb.queryWithRetry("TRUNCATE alert_rule RESTART IDENTITY CASCADE", 1)
                .compose(v -> vertx.deployVerticle(new AlertRuleVerticle(verticlePort)))
                .onComplete(ctx.succeeding(id -> ctx.completeNow()));

        assertThat(ctx.awaitCompletion(30, TimeUnit.SECONDS)).isTrue();
    }

    @Test
    void create_rule_returns201(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "my-service")
                .put("profileType", "cpu")
                .put("functionPattern", "com.example.Hot*")
                .put("thresholdPercent", 25.0)
                .put("severity", "critical")
                .put("notificationChannel", "#alerts-cpu")
                .put("enabled", true)
                .put("createdBy", "tester");

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    JsonObject json = resp.bodyAsJsonObject();
                    assertThat(json.getInteger("id")).isGreaterThan(0);
                    assertThat(json.getString("appName")).isEqualTo("my-service");
                    assertThat(json.getString("profileType")).isEqualTo("cpu");
                    assertThat(json.getString("functionPattern")).isEqualTo("com.example.Hot*");
                    assertThat(json.getDouble("thresholdPercent")).isEqualTo(25.0);
                    assertThat(json.getString("severity")).isEqualTo("critical");
                    assertThat(json.getString("notificationChannel")).isEqualTo("#alerts-cpu");
                    assertThat(json.getBoolean("enabled")).isTrue();
                    assertThat(json.getString("createdBy")).isEqualTo("tester");
                    assertThat(json.getString("createdAt")).isNotNull();
                    assertThat(json.getString("updatedAt")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void create_rule_defaultsSeverityAndEnabled(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-defaults")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    JsonObject json = resp.bodyAsJsonObject();
                    assertThat(json.getString("severity")).isEqualTo("warning");
                    assertThat(json.getBoolean("enabled")).isTrue();
                    ctx.completeNow();
                })));
    }

    @Test
    void create_rule_missingFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "svc-a");

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("required");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_rule_noBody_returns400(Vertx vertx, VertxTestContext ctx) {
        client.post(verticlePort, "localhost", "/rules")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    ctx.completeNow();
                })));
    }

    @Test
    void listAll_returnsAllRules(Vertx vertx, VertxTestContext ctx) {
        JsonObject rule1 = new JsonObject()
                .put("appName", "svc-a")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0);
        JsonObject rule2 = new JsonObject()
                .put("appName", "svc-b")
                .put("profileType", "alloc")
                .put("thresholdPercent", 20.0);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(rule1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/rules")
                            .sendJsonObject(rule2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/rules")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getInteger("count")).isEqualTo(2);
                                            assertThat(json.getJsonArray("rules").size()).isEqualTo(2);
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listAll_filtersByAppName(Vertx vertx, VertxTestContext ctx) {
        JsonObject rule1 = new JsonObject()
                .put("appName", "filter-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0);
        JsonObject rule2 = new JsonObject()
                .put("appName", "other-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 15.0);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(rule1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/rules")
                            .sendJsonObject(rule2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/rules?appName=filter-svc")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getInteger("count")).isEqualTo(1);
                                            assertThat(json.getJsonArray("rules")
                                                    .getJsonObject(0).getString("appName"))
                                                    .isEqualTo("filter-svc");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listAll_emptyResult(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/rules")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("count")).isEqualTo(0);
                    assertThat(resp.bodyAsJsonObject().getJsonArray("rules")).isEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void getById_returnsRule(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "lookup-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 12.5);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    client.get(verticlePort, "localhost", "/rules/" + id)
                            .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(200);
                                JsonObject json = resp.bodyAsJsonObject();
                                assertThat(json.getInteger("id")).isEqualTo(id);
                                assertThat(json.getString("appName")).isEqualTo("lookup-svc");
                                assertThat(json.getDouble("thresholdPercent")).isEqualTo(12.5);
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void getById_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/rules/99999")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("rule not found");
                    ctx.completeNow();
                })));
    }

    @Test
    void activeByApp_returnsOnlyEnabledRules(Vertx vertx, VertxTestContext ctx) {
        JsonObject enabled = new JsonObject()
                .put("appName", "active-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0)
                .put("enabled", true);
        JsonObject disabled = new JsonObject()
                .put("appName", "active-svc")
                .put("profileType", "alloc")
                .put("thresholdPercent", 20.0)
                .put("enabled", false);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(enabled, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/rules")
                            .sendJsonObject(disabled, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/rules/active/active-svc")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getString("appName")).isEqualTo("active-svc");
                                            assertThat(json.getInteger("count")).isEqualTo(1);
                                            assertThat(json.getJsonArray("rules")
                                                    .getJsonObject(0).getString("profileType"))
                                                    .isEqualTo("cpu");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void activeByApp_emptyWhenAllDisabled(Vertx vertx, VertxTestContext ctx) {
        JsonObject disabled = new JsonObject()
                .put("appName", "all-disabled")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0)
                .put("enabled", false);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(disabled, ctx.succeeding(r1 -> {
                    client.get(verticlePort, "localhost", "/rules/active/all-disabled")
                            .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(200);
                                assertThat(resp.bodyAsJsonObject().getInteger("count")).isEqualTo(0);
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void update_rule_changesFields(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "upd-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0)
                .put("severity", "warning")
                .put("enabled", true);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    JsonObject patch = new JsonObject()
                            .put("thresholdPercent", 30.0)
                            .put("severity", "critical")
                            .put("enabled", false)
                            .put("notificationChannel", "#new-channel");

                    client.put(verticlePort, "localhost", "/rules/" + id)
                            .sendJsonObject(patch, ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(200);
                                JsonObject updated = resp2.bodyAsJsonObject();
                                assertThat(updated.getDouble("thresholdPercent")).isEqualTo(30.0);
                                assertThat(updated.getString("severity")).isEqualTo("critical");
                                assertThat(updated.getBoolean("enabled")).isFalse();
                                assertThat(updated.getString("notificationChannel"))
                                        .isEqualTo("#new-channel");
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void update_rule_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        JsonObject patch = new JsonObject().put("thresholdPercent", 99.0);

        client.put(verticlePort, "localhost", "/rules/99999")
                .sendJsonObject(patch, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
    }

    @Test
    void update_rule_noFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject empty = new JsonObject();

        client.put(verticlePort, "localhost", "/rules/1")
                .sendJsonObject(empty, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("no fields");
                    ctx.completeNow();
                })));
    }

    @Test
    void delete_rule_returns204(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "del-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 5.0);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(body, ctx.succeeding(resp1 -> {
                    int id = resp1.bodyAsJsonObject().getInteger("id");

                    client.delete(verticlePort, "localhost", "/rules/" + id)
                            .send(ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(204);

                                // Verify it was actually deleted
                                client.get(verticlePort, "localhost", "/rules/" + id)
                                        .send(ctx.succeeding(resp3 -> ctx.verify(() -> {
                                            assertThat(resp3.statusCode()).isEqualTo(404);
                                            ctx.completeNow();
                                        })));
                            })));
                }));
    }

    @Test
    void delete_rule_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.delete(verticlePort, "localhost", "/rules/99999")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
    }

    @Test
    void create_multipleRulesForSameApp(Vertx vertx, VertxTestContext ctx) {
        JsonObject rule1 = new JsonObject()
                .put("appName", "multi-rule-svc")
                .put("profileType", "cpu")
                .put("thresholdPercent", 10.0);
        JsonObject rule2 = new JsonObject()
                .put("appName", "multi-rule-svc")
                .put("profileType", "cpu")
                .put("functionPattern", "com.example.*")
                .put("thresholdPercent", 5.0);

        client.post(verticlePort, "localhost", "/rules")
                .sendJsonObject(rule1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/rules")
                            .sendJsonObject(rule2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/rules?appName=multi-rule-svc")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            assertThat(resp.bodyAsJsonObject()
                                                    .getInteger("count")).isEqualTo(2);
                                            ctx.completeNow();
                                        })));
                            }));
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
