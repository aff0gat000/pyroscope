package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServer;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.client.WebClient;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import java.util.concurrent.TimeUnit;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Java 21 only — verifies the verticle dispatches handlers onto virtual
 * threads and reports isVirtual=true.
 */
@ExtendWith(VertxExtension.class)
class VirtualThreadVerticleTest {

    @Test
    void info_reports_virtual_thread(Vertx vertx, VertxTestContext ctx) throws Throwable {
        Router router = Router.router(vertx);
        AbstractVerticle v = new VirtualThreadVerticle(router);
        Future<Integer> port = vertx.deployVerticle(v, VirtualThreadVerticle.options())
            .compose(id -> vertx.createHttpServer().requestHandler(router).listen(0))
            .map(HttpServer::actualPort);

        port.compose(p -> WebClient.create(vertx).get(p, "localhost", "/vt/info").send())
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getBoolean("isVirtual")).isTrue();
                    assertThat(resp.bodyAsJsonObject().getString("thread")).contains("VirtualThread");
                });
                ctx.completeNow();
            }));
        if (!ctx.awaitCompletion(15, TimeUnit.SECONDS)) {
            throw new AssertionError("test timed out");
        }
        if (ctx.failed()) throw ctx.causeOfFailure();
    }

    @Test
    void sleep_unblocks_via_loom(Vertx vertx, VertxTestContext ctx) throws Throwable {
        Router router = Router.router(vertx);
        AbstractVerticle v = new VirtualThreadVerticle(router);
        Future<Integer> port = vertx.deployVerticle(v, VirtualThreadVerticle.options())
            .compose(id -> vertx.createHttpServer().requestHandler(router).listen(0))
            .map(HttpServer::actualPort);

        port.compose(p -> WebClient.create(vertx).get(p, "localhost", "/vt/sleep?ms=20").send())
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsJsonObject().getInteger("slept_ms")).isEqualTo(20);
                    assertThat(resp.bodyAsJsonObject().getBoolean("isVirtual")).isTrue();
                });
                ctx.completeNow();
            }));
        if (!ctx.awaitCompletion(15, TimeUnit.SECONDS)) {
            throw new AssertionError("test timed out");
        }
        if (ctx.failed()) throw ctx.causeOfFailure();
    }
}
