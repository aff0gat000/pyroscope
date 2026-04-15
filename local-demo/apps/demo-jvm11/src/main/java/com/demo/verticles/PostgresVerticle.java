package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.pgclient.PgPool;
import io.vertx.sqlclient.PoolOptions;

public class PostgresVerticle extends AbstractVerticle {
    private final Router router;
    private PgPool pool;
    public PostgresVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        PgConnectOptions co = new PgConnectOptions()
            .setHost(System.getenv().getOrDefault("PG_HOST", "postgres"))
            .setPort(Integer.parseInt(System.getenv().getOrDefault("PG_PORT", "5432")))
            .setDatabase(System.getenv().getOrDefault("PG_DB", "demo"))
            .setUser(System.getenv().getOrDefault("PG_USER", "demo"))
            .setPassword(System.getenv().getOrDefault("PG_PASS", "demo"));
        pool = PgPool.pool(vertx, co, new PoolOptions().setMaxSize(4));
        router.get("/postgres/query").handler(this::query);
        p.complete();
    }

    private void query(RoutingContext ctx) {
        Label.tag("postgres", () -> pool.query("SELECT now() AS ts, version() AS v").execute(ar -> {
            if (ar.succeeded()) {
                io.vertx.sqlclient.Row row = ar.result().iterator().next();
                ctx.json(new io.vertx.core.json.JsonObject().put("ts", row.getValue(0).toString()).put("v", row.getString(1)));
            } else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }
}
