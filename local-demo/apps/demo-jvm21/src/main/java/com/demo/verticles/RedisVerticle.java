package com.demo.verticles;

import com.demo.Env;
import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.redis.client.Redis;
import io.vertx.redis.client.RedisAPI;
import io.vertx.redis.client.RedisOptions;

import java.util.Arrays;

public class RedisVerticle extends AbstractVerticle {
    private final Router router;
    private RedisAPI redis;
    public RedisVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        String url = Env.get("REDIS_URL", "redis://redis:6379");
        redis = RedisAPI.api(Redis.createClient(vertx, new RedisOptions().setConnectionString(url)));
        router.get("/redis/set").handler(this::set);
        router.get("/redis/get").handler(this::get);
        p.complete();
    }

    private void set(RoutingContext ctx) {
        String k = ctx.request().getParam("k", "demo"), v = ctx.request().getParam("v", "hello");
        Label.tag("redis", () -> redis.set(Arrays.asList(k, v)).onComplete(ar -> reply(ctx, ar.succeeded(), ar.cause())));
    }

    private void get(RoutingContext ctx) {
        String k = ctx.request().getParam("k", "demo");
        Label.tag("redis", () -> redis.get(k).onComplete(ar -> {
            if (ar.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("v", ar.result() == null ? null : ar.result().toString()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }

    private void reply(RoutingContext ctx, boolean ok, Throwable err) {
        if (ok) ctx.json(new io.vertx.core.json.JsonObject().put("ok", true));
        else ctx.response().setStatusCode(502).end(err.getMessage());
    }
}
