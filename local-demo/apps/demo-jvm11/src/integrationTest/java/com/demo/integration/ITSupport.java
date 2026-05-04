package com.demo.integration;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Future;
import io.vertx.core.Vertx;
import io.vertx.core.http.HttpServer;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.client.HttpResponse;
import io.vertx.ext.web.client.WebClient;
import io.vertx.junit5.VertxTestContext;

import java.util.concurrent.TimeUnit;
import java.util.function.Function;

/**
 * Self-contained helpers for Testcontainers-backed integration tests.
 * Mirrors the unit-test base but with a longer await window — Testcontainers
 * round trips can take several seconds.
 */
public final class ITSupport {
    private ITSupport() {}

    public static Future<Integer> deployAndServe(Vertx vertx,
                                                  Function<Router, AbstractVerticle> factory) {
        Router router = Router.router(vertx);
        AbstractVerticle v = factory.apply(router);
        return vertx.deployVerticle(v)
            .compose(id -> vertx.createHttpServer().requestHandler(router).listen(0))
            .map(HttpServer::actualPort);
    }

    public static Future<HttpResponse<io.vertx.core.buffer.Buffer>> get(Vertx vertx, int port, String path) {
        return WebClient.create(vertx).get(port, "localhost", path).send();
    }

    public static void await(VertxTestContext ctx) throws Throwable {
        if (!ctx.awaitCompletion(60, TimeUnit.SECONDS)) {
            throw new AssertionError("integration test timed out after 60s");
        }
        if (ctx.failed()) throw ctx.causeOfFailure();
    }
}
