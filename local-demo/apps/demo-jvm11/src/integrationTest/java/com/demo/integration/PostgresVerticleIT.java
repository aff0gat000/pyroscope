package com.demo.integration;

import com.demo.verticles.PostgresVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class PostgresVerticleIT {

    static final PostgreSQLContainer<?> pg =
        new PostgreSQLContainer<>("postgres:16-alpine")
            .withDatabaseName("demo").withUsername("demo").withPassword("demo");

    @BeforeAll
    static void up() {
        pg.start();
        System.setProperty("PG_HOST", pg.getHost());
        System.setProperty("PG_PORT", String.valueOf(pg.getMappedPort(5432)));
        System.setProperty("PG_DB", "demo");
        System.setProperty("PG_USER", "demo");
        System.setProperty("PG_PASS", "demo");
    }

    @AfterAll
    static void down() {
        System.clearProperty("PG_HOST");
        System.clearProperty("PG_PORT");
        System.clearProperty("PG_DB");
        System.clearProperty("PG_USER");
        System.clearProperty("PG_PASS");
        pg.stop();
    }

    @Test
    void query_round_trips_real_postgres(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, PostgresVerticle::new)
            .compose(port -> get(vertx, port, "/postgres/query"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getString("v")).contains("PostgreSQL");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
