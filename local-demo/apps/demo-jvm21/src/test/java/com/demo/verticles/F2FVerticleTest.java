package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class F2FVerticleTest {

    @Test
    void eventbus_round_trip(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, F2FVerticle::new)
            .compose(port -> get(vertx, port, "/f2f/call?p=hello"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getString("reply")).isEqualTo("pong:hello");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
