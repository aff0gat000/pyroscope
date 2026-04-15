package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.client.WebClient;

public class HttpClientVerticle extends AbstractVerticle {
    private final Router router;
    private WebClient client;
    public HttpClientVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        client = WebClient.create(vertx);
        router.get("/http/echo").handler(ctx -> ctx.json(new io.vertx.core.json.JsonObject()
            .put("verticle", "HttpClientVerticle").put("thread", Thread.currentThread().getName())));
        router.get("/http/client").handler(this::callOut);
        p.complete();
    }

    private void callOut(RoutingContext ctx) {
        String host = ctx.request().getParam("host", "demo-jvm21");
        int port = Integer.parseInt(ctx.request().getParam("port", "8080"));
        Label.tag("http", () -> client.get(port, host, "/http/echo").send(ar -> {
            if (ar.succeeded()) ctx.json(ar.result().bodyAsJsonObject());
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }
}
