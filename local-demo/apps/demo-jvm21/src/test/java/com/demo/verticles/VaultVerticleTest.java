package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;

@ExtendWith(VertxExtension.class)
class VaultVerticleTest {

    @Test
    void read_responds_when_vault_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, VaultVerticle::new)
            .compose(port -> get(vertx, port, "/vault/read"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }
}
