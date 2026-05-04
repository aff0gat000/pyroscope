package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class ThreadLeakVerticleTest {

    @Test
    void start_then_stop_round_trips(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, ThreadLeakVerticle::new)
            .compose(port -> get(vertx, port, "/leak/start?n=3")
                .compose(r1 -> get(vertx, port, "/leak/status")
                    .compose(r2 -> get(vertx, port, "/leak/stop")
                        .map(r3 -> new int[]{
                            r1.bodyAsJsonObject().getInteger("leaked"),
                            r2.bodyAsJsonObject().getInteger("leaked"),
                            r3.bodyAsJsonObject().getInteger("stopped")}))))
            .onComplete(ctx.succeeding(counts -> {
                ctx.verify(() -> {
                    assertThat(counts[0]).isEqualTo(3);
                    assertThat(counts[1]).isEqualTo(3);
                    assertThat(counts[2]).isEqualTo(3);
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
