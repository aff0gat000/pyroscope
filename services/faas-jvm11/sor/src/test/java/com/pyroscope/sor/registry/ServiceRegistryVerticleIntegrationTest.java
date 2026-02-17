package com.pyroscope.sor.registry;

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
class ServiceRegistryVerticleIntegrationTest {

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
        testDb.queryWithRetry("TRUNCATE service_registry RESTART IDENTITY CASCADE", 1)
                .compose(v -> vertx.deployVerticle(new ServiceRegistryVerticle(verticlePort)))
                .onComplete(ctx.succeeding(id -> ctx.completeNow()));

        assertThat(ctx.awaitCompletion(30, TimeUnit.SECONDS)).isTrue();
    }

    @Test
    void create_service_returns201(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "order-service")
                .put("teamOwner", "platform-team")
                .put("tier", "critical")
                .put("environment", "production")
                .put("notificationChannel", "#alerts-orders")
                .put("pyroscopeLabels", new JsonObject().put("region", "us-east-1"))
                .put("metadata", new JsonObject().put("repo", "github.com/org/order-service"));

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    JsonObject json = resp.bodyAsJsonObject();
                    assertThat(json.getString("appName")).isEqualTo("order-service");
                    assertThat(json.getString("teamOwner")).isEqualTo("platform-team");
                    assertThat(json.getString("tier")).isEqualTo("critical");
                    assertThat(json.getString("environment")).isEqualTo("production");
                    assertThat(json.getString("notificationChannel")).isEqualTo("#alerts-orders");
                    assertThat(json.getString("createdAt")).isNotNull();
                    assertThat(json.getString("updatedAt")).isNotNull();
                    ctx.completeNow();
                })));
    }

    @Test
    void create_service_defaultsTierToStandard(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "simple-svc");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(201);
                    assertThat(resp.bodyAsJsonObject().getString("tier")).isEqualTo("standard");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_service_missingAppName_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("teamOwner", "some-team");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("appName");
                    ctx.completeNow();
                })));
    }

    @Test
    void create_service_upsertOnConflict(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "upsert-svc")
                .put("teamOwner", "team-a")
                .put("tier", "standard");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(resp1 -> ctx.verify(() -> {
                    assertThat(resp1.statusCode()).isEqualTo(201);

                    JsonObject updated = new JsonObject()
                            .put("appName", "upsert-svc")
                            .put("teamOwner", "team-b")
                            .put("tier", "critical");

                    client.post(verticlePort, "localhost", "/services")
                            .sendJsonObject(updated, ctx.succeeding(resp2 -> ctx.verify(() -> {
                                assertThat(resp2.statusCode()).isEqualTo(201);
                                assertThat(resp2.bodyAsJsonObject().getString("teamOwner"))
                                        .isEqualTo("team-b");
                                assertThat(resp2.bodyAsJsonObject().getString("tier"))
                                        .isEqualTo("critical");
                                ctx.completeNow();
                            })));
                })));
    }

    @Test
    void listAll_returnsAllServices(Vertx vertx, VertxTestContext ctx) {
        JsonObject svc1 = new JsonObject().put("appName", "alpha-svc").put("tier", "critical");
        JsonObject svc2 = new JsonObject().put("appName", "beta-svc").put("tier", "standard");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(svc1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/services")
                            .sendJsonObject(svc2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/services")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getInteger("count")).isEqualTo(2);
                                            assertThat(json.getJsonArray("services").size()).isEqualTo(2);
                                            // Sorted by app_name
                                            assertThat(json.getJsonArray("services")
                                                    .getJsonObject(0).getString("appName"))
                                                    .isEqualTo("alpha-svc");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listAll_filtersByTier(Vertx vertx, VertxTestContext ctx) {
        JsonObject svc1 = new JsonObject().put("appName", "crit-svc").put("tier", "critical");
        JsonObject svc2 = new JsonObject().put("appName", "std-svc").put("tier", "standard");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(svc1, ctx.succeeding(r1 -> {
                    client.post(verticlePort, "localhost", "/services")
                            .sendJsonObject(svc2, ctx.succeeding(r2 -> {
                                client.get(verticlePort, "localhost", "/services?tier=critical")
                                        .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                            assertThat(resp.statusCode()).isEqualTo(200);
                                            JsonObject json = resp.bodyAsJsonObject();
                                            assertThat(json.getInteger("count")).isEqualTo(1);
                                            assertThat(json.getJsonArray("services")
                                                    .getJsonObject(0).getString("appName"))
                                                    .isEqualTo("crit-svc");
                                            ctx.completeNow();
                                        })));
                            }));
                }));
    }

    @Test
    void listAll_emptyResult(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/services")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("count")).isEqualTo(0);
                    assertThat(resp.bodyAsJsonObject().getJsonArray("services")).isEmpty();
                    ctx.completeNow();
                })));
    }

    @Test
    void getByName_returnsService(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "lookup-svc")
                .put("teamOwner", "team-x")
                .put("tier", "critical");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(r1 -> {
                    client.get(verticlePort, "localhost", "/services/lookup-svc")
                            .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(200);
                                JsonObject json = resp.bodyAsJsonObject();
                                assertThat(json.getString("appName")).isEqualTo("lookup-svc");
                                assertThat(json.getString("teamOwner")).isEqualTo("team-x");
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void getByName_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.get(verticlePort, "localhost", "/services/nonexistent")
                .send(ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("service not found");
                    ctx.completeNow();
                })));
    }

    @Test
    void update_service_changesFields(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "upd-svc")
                .put("teamOwner", "team-old")
                .put("tier", "standard");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(r1 -> {
                    JsonObject patch = new JsonObject()
                            .put("teamOwner", "team-new")
                            .put("tier", "critical")
                            .put("environment", "staging");

                    client.put(verticlePort, "localhost", "/services/upd-svc")
                            .sendJsonObject(patch, ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(200);
                                JsonObject json = resp.bodyAsJsonObject();
                                assertThat(json.getString("teamOwner")).isEqualTo("team-new");
                                assertThat(json.getString("tier")).isEqualTo("critical");
                                assertThat(json.getString("environment")).isEqualTo("staging");
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void update_service_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        JsonObject patch = new JsonObject().put("tier", "critical");

        client.put(verticlePort, "localhost", "/services/missing-svc")
                .sendJsonObject(patch, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(404);
                    ctx.completeNow();
                })));
    }

    @Test
    void update_service_noFields_returns400(Vertx vertx, VertxTestContext ctx) {
        JsonObject empty = new JsonObject();

        client.put(verticlePort, "localhost", "/services/any-svc")
                .sendJsonObject(empty, ctx.succeeding(resp -> ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(400);
                    assertThat(resp.bodyAsJsonObject().getString("error")).contains("no fields");
                    ctx.completeNow();
                })));
    }

    @Test
    void update_service_jsonbFields(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject()
                .put("appName", "jsonb-svc")
                .put("pyroscopeLabels", new JsonObject().put("env", "dev"));

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(r1 -> {
                    JsonObject patch = new JsonObject()
                            .put("pyroscopeLabels", new JsonObject().put("env", "prod").put("region", "eu"))
                            .put("metadata", new JsonObject().put("version", "2.0"));

                    client.put(verticlePort, "localhost", "/services/jsonb-svc")
                            .sendJsonObject(patch, ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(200);
                                JsonObject json = resp.bodyAsJsonObject();
                                assertThat(json.containsKey("pyroscopeLabels")).isTrue();
                                assertThat(json.containsKey("metadata")).isTrue();
                                ctx.completeNow();
                            })));
                }));
    }

    @Test
    void delete_service_returns204(Vertx vertx, VertxTestContext ctx) {
        JsonObject body = new JsonObject().put("appName", "del-svc");

        client.post(verticlePort, "localhost", "/services")
                .sendJsonObject(body, ctx.succeeding(r1 -> {
                    client.delete(verticlePort, "localhost", "/services/del-svc")
                            .send(ctx.succeeding(resp -> ctx.verify(() -> {
                                assertThat(resp.statusCode()).isEqualTo(204);

                                // Verify it was actually deleted
                                client.get(verticlePort, "localhost", "/services/del-svc")
                                        .send(ctx.succeeding(resp2 -> ctx.verify(() -> {
                                            assertThat(resp2.statusCode()).isEqualTo(404);
                                            ctx.completeNow();
                                        })));
                            })));
                }));
    }

    @Test
    void delete_service_notFound_returns404(Vertx vertx, VertxTestContext ctx) {
        client.delete(verticlePort, "localhost", "/services/nonexistent-svc")
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
