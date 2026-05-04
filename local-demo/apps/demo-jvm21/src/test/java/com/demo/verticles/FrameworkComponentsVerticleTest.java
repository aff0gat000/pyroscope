package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class FrameworkComponentsVerticleTest {

    @Test
    void future_chain_returns_combined_result(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, FrameworkComponentsVerticle::new)
            .compose(port -> get(vertx, port, "/framework/future-chain"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("a")).isEqualTo(2);
                    assertThat(resp.bodyAsJsonObject().getInteger("b")).isEqualTo(20);
                });
                ctx.completeNow();
            }));
        await(ctx);
    }

    @Test
    void timer_returns_id(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, FrameworkComponentsVerticle::new)
            .compose(port -> get(vertx, port, "/framework/timer"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> assertThat(resp.statusCode()).isEqualTo(200));
                ctx.completeNow();
            }));
        await(ctx);
    }
}
