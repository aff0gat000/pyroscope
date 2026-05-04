package com.demo.integration;

import com.demo.verticles.KafkaVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.containers.KafkaContainer;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class KafkaVerticleIT {

    static final KafkaContainer kafka =
        new KafkaContainer(DockerImageName.parse("confluentinc/cp-kafka:7.6.1"));

    @BeforeAll
    static void up() {
        kafka.start();
        System.setProperty("KAFKA_BROKERS", kafka.getBootstrapServers());
    }

    @AfterAll
    static void down() {
        System.clearProperty("KAFKA_BROKERS");
        kafka.stop();
    }

    @Test
    void produce_returns_offset(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, KafkaVerticle::new)
            .compose(port -> get(vertx, port, "/kafka/produce?v=hello-it"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getLong("offset")).isNotNull();
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
