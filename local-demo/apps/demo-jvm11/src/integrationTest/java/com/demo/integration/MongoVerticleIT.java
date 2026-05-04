package com.demo.integration;

import com.demo.verticles.MongoVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.containers.MongoDBContainer;
import org.testcontainers.junit.jupiter.Testcontainers;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class MongoVerticleIT {

    static final MongoDBContainer mongo = new MongoDBContainer("mongo:7");

    @BeforeAll
    static void up() {
        mongo.start();
        System.setProperty("MONGO_URL", mongo.getReplicaSetUrl());
    }

    @AfterAll
    static void down() {
        System.clearProperty("MONGO_URL");
        mongo.stop();
    }

    @Test
    void insert_then_find_round_trips(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, MongoVerticle::new)
            .compose(port -> get(vertx, port, "/mongo/insert?msg=hi")
                .compose(ins -> {
                    ctx.verify(() -> assertThat(ins.statusCode()).isEqualTo(200));
                    return get(vertx, port, "/mongo/find");
                }))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("count")).isGreaterThanOrEqualTo(1);
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
