package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class KafkaVerticleTest {

    @Test
    void consume_status_responds(Vertx vertx, VertxTestContext ctx) throws Throwable {
        // Kafka clients connect lazily; /kafka/consume is a status endpoint
        // that should always succeed regardless of broker availability.
        deployAndServe(vertx, KafkaVerticle::new)
            .compose(port -> get(vertx, port, "/kafka/consume"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getLong("consumed")).isNotNull();
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
