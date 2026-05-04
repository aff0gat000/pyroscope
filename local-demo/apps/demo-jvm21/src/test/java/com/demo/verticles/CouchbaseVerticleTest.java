package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;
import static org.assertj.core.api.Assertions.assertThat;

@ExtendWith(VertxExtension.class)
class CouchbaseVerticleTest {

    @Test
    void upsert_returns_503_when_cluster_not_ready(Vertx vertx, VertxTestContext ctx) throws Throwable {
        // Couchbase cluster init runs in executeBlocking and fails (no host);
        // verticle must respond with 503 ("not ready") rather than crash.
        deployAndServe(vertx, CouchbaseVerticle::new)
            .compose(port -> get(vertx, port, "/couchbase/upsert?id=x&v=y"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> assertThat(resp.statusCode()).isIn(502, 503));
                ctx.completeNow();
            }));
        await(ctx);
    }

    @Test
    void get_returns_503_when_cluster_not_ready(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, CouchbaseVerticle::new)
            .compose(port -> get(vertx, port, "/couchbase/get?id=x"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> assertThat(resp.statusCode()).isIn(502, 503));
                ctx.completeNow();
            }));
        await(ctx);
    }
}
