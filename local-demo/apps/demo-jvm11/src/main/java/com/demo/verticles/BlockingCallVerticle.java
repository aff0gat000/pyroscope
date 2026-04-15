package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

/**
 * Demonstrates the classic Vert.x antipattern:
 *   /blocking/on-eventloop    — Thread.sleep on the event loop (BAD)
 *   /blocking/execute-blocking — same work dispatched to worker pool (GOOD)
 * Flame graphs will show blocked time on eventloop-* vs worker-* threads.
 */
public class BlockingCallVerticle extends AbstractVerticle {
    private final Router router;
    public BlockingCallVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        router.get("/blocking/on-eventloop").handler(this::onEventLoop);
        router.get("/blocking/execute-blocking").handler(this::onWorker);
        p.complete();
    }

    private void onEventLoop(RoutingContext ctx) {
        int ms = Integer.parseInt(ctx.request().getParam("ms", "200"));
        try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
        ctx.json(new io.vertx.core.json.JsonObject().put("slept_ms", ms).put("thread", Thread.currentThread().getName()));
    }

    private void onWorker(RoutingContext ctx) {
        int ms = Integer.parseInt(ctx.request().getParam("ms", "200"));
        vertx.executeBlocking(promise -> {
            try { Thread.sleep(ms); } catch (InterruptedException ignored) {}
            promise.complete(Thread.currentThread().getName());
        }, res -> ctx.json(new io.vertx.core.json.JsonObject().put("slept_ms", ms).put("thread", res.result())));
    }
}
