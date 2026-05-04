package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class FunctionRegistryVerticleTest {

    @Test
    void registry_returns_verticle_name(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, FunctionRegistryVerticle::new)
            .compose(port -> get(vertx, port, "/registry"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getString("verticle"))
                        .isEqualTo("FunctionRegistryVerticle");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
