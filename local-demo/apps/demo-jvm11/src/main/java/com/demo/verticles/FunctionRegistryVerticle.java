package com.demo.verticles;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;

/** Exposes /registry — named so it shows up in CPU flame graphs. */
public class FunctionRegistryVerticle extends AbstractVerticle {
    private final Router router;
    public FunctionRegistryVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        router.get("/registry").handler(this::handleRegistry);
        p.complete();
    }

    private void handleRegistry(io.vertx.ext.web.RoutingContext ctx) {
        ctx.json(new JsonObject().put("verticle", "FunctionRegistryVerticle").put("jvm", System.getProperty("java.version")));
    }
}
