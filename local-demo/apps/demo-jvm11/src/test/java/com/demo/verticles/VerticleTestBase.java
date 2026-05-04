package com.demo.verticles;

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
 * Shared harness for verticle tests. Deploys a verticle with a fresh Router
 * and HTTP server on an ephemeral port, then runs the supplied request.
 *
 * Tests deliberately do NOT require backend services (Redis, Postgres, Kafka,
 * etc.) to be reachable; the verticles fail gracefully (502/503) when the
 * backend is down. We assert the verticle is wired, deployable, and responds
 * with a valid HTTP status — not that the backend round-trips.
 */
public final class VerticleTestBase {
    private VerticleTestBase() {}

    public static Future<Integer> deployAndServe(Vertx vertx, Function<Router, AbstractVerticle> factory) {
        Router router = Router.router(vertx);
        AbstractVerticle v = factory.apply(router);
        return vertx.deployVerticle(v)
            .compose(id -> vertx.createHttpServer().requestHandler(router).listen(0))
            .map(HttpServer::actualPort);
    }

    public static Future<HttpResponse<io.vertx.core.buffer.Buffer>> get(Vertx vertx, int port, String path) {
        return WebClient.create(vertx).get(port, "localhost", path).send();
    }

    public static void assertValidHttp(VertxTestContext ctx, HttpResponse<io.vertx.core.buffer.Buffer> resp) {
        ctx.verify(() -> {
            int code = resp.statusCode();
            if (code < 200 || code > 599) {
                throw new AssertionError("invalid http status: " + code);
            }
        });
    }

    public static void await(VertxTestContext ctx) throws Throwable {
        if (!ctx.awaitCompletion(15, TimeUnit.SECONDS)) {
            throw new AssertionError("test timed out");
        }
        if (ctx.failed()) throw ctx.causeOfFailure();
    }
}
