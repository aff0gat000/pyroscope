package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.mongo.MongoClient;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;

public class MongoVerticle extends AbstractVerticle {
    private final Router router;
    private MongoClient mongo;
    public MongoVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        // Short server-selection / connect timeouts so requests fail fast (and
        // tests don't hang) when Mongo is unreachable.
        String uri = System.getenv().getOrDefault("MONGO_URL",
            "mongodb://mongo:27017/?serverSelectionTimeoutMS=2000&connectTimeoutMS=2000");
        mongo = MongoClient.createShared(vertx, new JsonObject().put("connection_string", uri).put("db_name", "demo"));
        router.get("/mongo/insert").handler(this::insert);
        router.get("/mongo/find").handler(this::find);
        p.complete();
    }

    private void insert(RoutingContext ctx) {
        JsonObject doc = new JsonObject().put("ts", System.currentTimeMillis()).put("msg", ctx.request().getParam("msg", "hello"));
        Label.tag("mongo", () -> mongo.insert("events", doc, ar -> {
            if (ar.succeeded()) ctx.json(new JsonObject().put("id", ar.result()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }

    private void find(RoutingContext ctx) {
        Label.tag("mongo", () -> mongo.find("events", new JsonObject(), ar -> {
            if (ar.succeeded()) ctx.json(new JsonObject().put("count", ar.result().size()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }
}
