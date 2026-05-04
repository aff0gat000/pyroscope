package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;

@ExtendWith(VertxExtension.class)
class PostgresVerticleTest {

    @Test
    void query_responds_when_pg_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, PostgresVerticle::new)
            .compose(port -> get(vertx, port, "/postgres/query"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }
}
