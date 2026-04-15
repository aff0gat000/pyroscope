package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.CompositeFuture;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.Arrays;

/**
 * Exercises Vert.x framework primitives: Future.compose / CompositeFuture /
 * WorkerExecutor / periodic timers. These frames show up with vert.x/* package
 * prefixes in flame graphs.
 */
public class FrameworkComponentsVerticle extends AbstractVerticle {
    private final Router router;
    public FrameworkComponentsVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        router.get("/framework/future-chain").handler(this::chain);
        router.get("/framework/timer").handler(this::timer);
        p.complete();
    }

    private void chain(RoutingContext ctx) {
        Future<Integer> a = Future.succeededFuture(1).compose(i -> Future.succeededFuture(i + 1));
        Future<Integer> b = Future.succeededFuture(10).compose(i -> Future.succeededFuture(i * 2));
        CompositeFuture.all(Arrays.asList(a, b)).onComplete(ar -> {
            if (ar.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("a", a.result()).put("b", b.result()));
            else ctx.response().setStatusCode(500).end(ar.cause().getMessage());
        });
    }

    private void timer(RoutingContext ctx) {
        vertx.setTimer(50, tid -> ctx.json(new io.vertx.core.json.JsonObject().put("timer", tid)));
    }
}
