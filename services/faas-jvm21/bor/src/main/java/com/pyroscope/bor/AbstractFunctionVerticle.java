package com.pyroscope.bor;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

public abstract class AbstractFunctionVerticle extends AbstractVerticle {

    protected final int port;
    protected Router router;

    protected AbstractFunctionVerticle(int port) {
        this.port = port;
    }

    @Override
    public void start(Promise<Void> startPromise) {
        router = Router.router(vertx);
        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        initFunction();
        vertx.createHttpServer()
                .requestHandler(router)
                .listen(port)
                .<Void>mapEmpty()
                .onComplete(startPromise);
    }

    protected abstract void initFunction();

    @Override
    public void stop(Promise<Void> stopPromise) {
        stopPromise.complete();
    }

    protected static long paramLong(RoutingContext ctx, String name, long defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Long.parseLong(val) : defaultValue;
    }

    protected static int paramInt(RoutingContext ctx, String name, int defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Integer.parseInt(val) : defaultValue;
    }

    protected static String paramStr(RoutingContext ctx, String name, String defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null && !val.isBlank() ? val : defaultValue;
    }

    protected static void sendError(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encode());
    }
}
