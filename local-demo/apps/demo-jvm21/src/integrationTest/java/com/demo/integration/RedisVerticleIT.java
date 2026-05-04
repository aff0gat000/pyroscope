package com.demo.integration;

import com.demo.verticles.RedisVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.containers.GenericContainer;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class RedisVerticleIT {

    static final GenericContainer<?> redis =
        new GenericContainer<>(DockerImageName.parse("redis:7-alpine")).withExposedPorts(6379);

    @BeforeAll
    static void up() {
        redis.start();
        System.setProperty("REDIS_URL",
            "redis://" + redis.getHost() + ":" + redis.getMappedPort(6379));
    }

    @AfterAll
    static void down() {
        System.clearProperty("REDIS_URL");
        redis.stop();
    }

    @Test
    void set_then_get_round_trips_through_real_redis(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, RedisVerticle::new)
            .compose(port -> get(vertx, port, "/redis/set?k=greeting&v=world")
                .compose(set -> {
                    ctx.verify(() -> assertThat(set.statusCode()).isEqualTo(200));
                    return get(vertx, port, "/redis/get?k=greeting");
                }))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getString("v")).isEqualTo("world");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
