package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.core.ThreadingModel;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

/**
 * Java 21 only — demonstrates blocking calls on a virtual thread.
 *
 * Routes registered on the shared Router run on the HTTP server's event loop.
 * To exercise Loom on incoming requests, we explicitly dispatch the work
 * onto a virtual thread, then return to the Vert.x context to write the
 * response. Flame graphs will show VirtualThread.run + Continuation frames.
 */
public class VirtualThreadVerticle extends AbstractVerticle {
    private final Router router;
    public VirtualThreadVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        router.get("/vt/sleep").handler(this::sleep);
        router.get("/vt/info").handler(this::info);
        p.complete();
    }

    private void info(RoutingContext ctx) {
        Thread.ofVirtual().name("demo-vt-info").start(() -> {
            String info = Thread.currentThread().toString();
            boolean virtual = Thread.currentThread().isVirtual();
            vertx.runOnContext(v -> ctx.json(new io.vertx.core.json.JsonObject()
                .put("thread", info).put("isVirtual", virtual)));
        });
    }

    private void sleep(RoutingContext ctx) {
        int ms = Integer.parseInt(ctx.request().getParam("ms", "200"));
        Thread.ofVirtual().name("demo-vt-sleep").start(() -> {
            try { Thread.sleep(ms); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
            String info = Thread.currentThread().toString();
            boolean virtual = Thread.currentThread().isVirtual();
            vertx.runOnContext(v -> ctx.json(new io.vertx.core.json.JsonObject()
                .put("slept_ms", ms).put("thread", info).put("isVirtual", virtual)));
        });
    }

    public static io.vertx.core.DeploymentOptions options() {
        return new io.vertx.core.DeploymentOptions().setThreadingModel(ThreadingModel.VIRTUAL_THREAD);
    }
}
