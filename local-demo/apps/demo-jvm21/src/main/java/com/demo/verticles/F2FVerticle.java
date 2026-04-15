package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Promise;
import io.vertx.core.eventbus.Message;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

/**
 * Function-to-function call via EventBus: caller verticle sends a request,
 * child verticle handles. Flame graphs on eventloop threads will show send()
 * + handler frames tagged integration=eventbus.
 */
public class F2FVerticle extends AbstractVerticle {
    private final Router router;
    public static final String ADDR = "demo.f2f";
    public F2FVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        vertx.deployVerticle(ChildHandlerVerticle.class.getName(), new DeploymentOptions().setInstances(2));
        router.get("/f2f/call").handler(this::call);
        p.complete();
    }

    private void call(RoutingContext ctx) {
        String payload = ctx.request().getParam("p", "ping");
        Label.tag("eventbus", () -> vertx.eventBus().<String>request(ADDR, payload, reply -> {
            if (reply.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("reply", reply.result().body()));
            else ctx.response().setStatusCode(502).end(reply.cause().getMessage());
        }));
    }

    public static class ChildHandlerVerticle extends AbstractVerticle {
        @Override public void start() {
            vertx.eventBus().<String>consumer(ADDR, (Message<String> m) ->
                Label.tag("eventbus", () -> m.reply("pong:" + m.body())));
        }
    }
}
