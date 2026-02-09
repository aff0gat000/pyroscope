package com.pyroscope.sor;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.handler.BodyHandler;

public abstract class AbstractFunctionVerticle extends AbstractVerticle {

    protected final int port;
    protected Router router;

    protected AbstractFunctionVerticle(int port) {
        this.port = port;
    }

    @Override
    public void start(Promise<Void> startPromise) {
        router = Router.router(vertx);
        router.route().handler(BodyHandler.create());
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
}
