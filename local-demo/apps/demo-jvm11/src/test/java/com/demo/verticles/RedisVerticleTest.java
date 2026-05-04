package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;

@ExtendWith(VertxExtension.class)
class RedisVerticleTest {

    @Test
    void set_returns_valid_http_when_backend_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        // No real Redis on the host; verticle should respond with 502, not crash.
        System.setProperty("demo.test.mode", "unit");
        deployAndServe(vertx, RedisVerticle::new)
            .compose(port -> get(vertx, port, "/redis/set?k=t&v=v"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }

    @Test
    void get_returns_valid_http_when_backend_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, RedisVerticle::new)
            .compose(port -> get(vertx, port, "/redis/get?k=t"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }
}
