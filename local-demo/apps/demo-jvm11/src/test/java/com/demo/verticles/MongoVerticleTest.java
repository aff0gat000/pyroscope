package com.demo.verticles;

import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;

import static com.demo.verticles.VerticleTestBase.*;

@ExtendWith(VertxExtension.class)
class MongoVerticleTest {

    @Test
    void insert_responds_when_mongo_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, MongoVerticle::new)
            .compose(port -> get(vertx, port, "/mongo/insert?msg=t"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }

    @Test
    void find_responds_when_mongo_unavailable(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, MongoVerticle::new)
            .compose(port -> get(vertx, port, "/mongo/find"))
            .onComplete(ctx.succeeding(resp -> {
                assertValidHttp(ctx, resp);
                ctx.completeNow();
            }));
        await(ctx);
    }
}
