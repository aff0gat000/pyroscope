package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class HttpClientVerticleTest {

    @Test
    void echo_returns_thread_info(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, HttpClientVerticle::new)
            .compose(port -> get(vertx, port, "/http/echo"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getString("verticle")).isEqualTo("HttpClientVerticle");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }

    @Test
    void client_responds_to_unreachable_host(Vertx vertx, VertxTestContext ctx) throws Throwable {
        // No remote running; verticle must produce a valid HTTP response (502 expected).
        deployAndServe(vertx, HttpClientVerticle::new)
            .compose(port -> get(vertx, port, "/http/client?host=localhost&port=1"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }
}
