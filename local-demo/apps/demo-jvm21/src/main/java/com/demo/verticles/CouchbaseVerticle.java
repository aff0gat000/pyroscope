package com.demo.verticles;

import com.couchbase.client.java.Bucket;
import com.couchbase.client.java.Cluster;
import com.couchbase.client.java.Collection;
import com.couchbase.client.java.json.JsonObject;
import com.demo.Env;
import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Couchbase SDK is blocking — calls are dispatched via executeBlocking so the
 * event loop stays free. Flame graphs on worker threads will show couchbase frames.
 */
public class CouchbaseVerticle extends AbstractVerticle {
    private static final Logger log = LoggerFactory.getLogger(CouchbaseVerticle.class);
    private final Router router;
    private Cluster cluster;
    private Collection collection;
    public CouchbaseVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        vertx.executeBlocking(promise -> {
            try {
                String host = Env.get("CB_HOST", "couchbase");
                String user = Env.get("CB_USER", "Administrator");
                String pass = Env.get("CB_PASS", "password");
                String bucket = Env.get("CB_BUCKET", "demo");
                cluster = Cluster.connect(host, user, pass);
                Bucket b = cluster.bucket(bucket);
                b.waitUntilReady(java.time.Duration.ofSeconds(20));
                collection = b.defaultCollection();
                promise.complete();
            } catch (Exception e) { promise.fail(e); }
        }, false, ar -> {
            if (ar.failed()) log.warn("couchbase init failed: {}", ar.cause().getMessage());
        });

        router.get("/couchbase/upsert").handler(this::upsert);
        router.get("/couchbase/get").handler(this::get);
        p.complete();
    }

    private void upsert(RoutingContext ctx) {
        if (collection == null) { ctx.response().setStatusCode(503).end("couchbase not ready"); return; }
        String id = ctx.request().getParam("id", "demo-1");
        String v = ctx.request().getParam("v", "hello");
        vertx.executeBlocking(promise -> {
            Label.tag("couchbase", () -> collection.upsert(id, JsonObject.create().put("v", v)));
            promise.complete();
        }, false, ar -> reply(ctx, ar.succeeded(), ar.cause()));
    }

    private void get(RoutingContext ctx) {
        if (collection == null) { ctx.response().setStatusCode(503).end("couchbase not ready"); return; }
        String id = ctx.request().getParam("id", "demo-1");
        vertx.executeBlocking(promise -> {
            try { promise.complete(Label.tag("couchbase", () -> collection.get(id).contentAsObject().toString())); }
            catch (Exception e) { promise.fail(e); }
        }, false, ar -> {
            if (ar.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("doc", ar.result().toString()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        });
    }

    private void reply(RoutingContext ctx, boolean ok, Throwable err) {
        if (ok) ctx.json(new io.vertx.core.json.JsonObject().put("ok", true));
        else ctx.response().setStatusCode(502).end(err.getMessage());
    }

    @Override public void stop() { if (cluster != null) cluster.disconnect(); }
}
