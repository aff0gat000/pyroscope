package com.demo.verticles;

import io.vertx.core.CompositeFuture;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class BlockingCallVerticleTest {

    @Test
    void on_eventloop_runs_on_eventloop(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, BlockingCallVerticle::new)
            .compose(port -> CompositeFuture.all(
                get(vertx, port, "/blocking/on-eventloop?ms=10"),
                get(vertx, port, "/blocking/execute-blocking?ms=10")
            ))
            .onComplete(ctx.succeeding(cf -> {
                ctx.verify(() -> {
                    String onEvLoopThread = cf.<io.vertx.ext.web.client.HttpResponse<io.vertx.core.buffer.Buffer>>resultAt(0).bodyAsJsonObject().getString("thread");
                    String onWorkerThread = cf.<io.vertx.ext.web.client.HttpResponse<io.vertx.core.buffer.Buffer>>resultAt(1).bodyAsJsonObject().getString("thread");
                    assertThat(onEvLoopThread).contains("eventloop");
                    assertThat(onWorkerThread).contains("worker");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
