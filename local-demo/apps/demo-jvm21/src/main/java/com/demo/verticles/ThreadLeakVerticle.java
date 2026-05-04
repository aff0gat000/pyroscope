package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

import java.util.ArrayList;
import java.util.List;

/**
 * Intentionally leaks platform threads (bounded). Visible as a growing thread
 * count in JVM metrics and as "demo-leak-*" frames in wall-clock flame graphs.
 */
public class ThreadLeakVerticle extends AbstractVerticle {
    private final Router router;
    private final List<Thread> leaked = new ArrayList<>();
    private static final int MAX_LEAK = 200;

    public ThreadLeakVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        router.get("/leak/start").handler(this::start);
        router.get("/leak/stop").handler(this::stop);
        router.get("/leak/status").handler(ctx -> ctx.json(new io.vertx.core.json.JsonObject().put("leaked", leaked.size())));
        p.complete();
    }

    private void start(RoutingContext ctx) {
        int n = Integer.parseInt(ctx.request().getParam("n", "10"));
        for (int i = 0; i < n && leaked.size() < MAX_LEAK; i++) {
            Thread t = new Thread(this::leakBody, "demo-leak-" + leaked.size());
            t.setDaemon(true);
            t.start();
            leaked.add(t);
        }
        ctx.json(new io.vertx.core.json.JsonObject().put("leaked", leaked.size()));
    }

    private void leakBody() {
        try { while (!Thread.currentThread().isInterrupted()) Thread.sleep(5000); }
        catch (InterruptedException e) { /* exiting thread; flag intentionally not restored */ }
    }

    private void stop(RoutingContext ctx) {
        for (Thread t : leaked) t.interrupt();
        int n = leaked.size();
        leaked.clear();
        ctx.json(new io.vertx.core.json.JsonObject().put("stopped", n));
    }
}
