package com.demo.integration;

import com.demo.verticles.CouchbaseVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.couchbase.BucketDefinition;
import org.testcontainers.couchbase.CouchbaseContainer;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.utility.DockerImageName;

import java.util.concurrent.TimeUnit;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

/**
 * Couchbase startup is slow (~30-60s). This test is expensive but exercises
 * the blocking SDK + executeBlocking dispatch path end-to-end.
 */
@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class CouchbaseVerticleIT {

    static final CouchbaseContainer cb =
        new CouchbaseContainer(DockerImageName.parse("couchbase/server:community-7.6.2")
                .asCompatibleSubstituteFor("couchbase/server"))
            .withBucket(new BucketDefinition("demo"));

    @BeforeAll
    static void up() {
        cb.start();
        System.setProperty("CB_HOST", cb.getHost() + ":" + cb.getMappedPort(11210));
        System.setProperty("CB_USER", cb.getUsername());
        System.setProperty("CB_PASS", cb.getPassword());
        System.setProperty("CB_BUCKET", "demo");
    }

    @AfterAll
    static void down() {
        System.clearProperty("CB_HOST");
        System.clearProperty("CB_USER");
        System.clearProperty("CB_PASS");
        System.clearProperty("CB_BUCKET");
        cb.stop();
    }

    @Test
    void upsert_then_get_round_trips(Vertx vertx, VertxTestContext ctx) throws Throwable {
        // Couchbase verticle does cluster.connect in executeBlocking on start;
        // need to give it a moment after deployment before hitting the routes.
        deployAndServe(vertx, CouchbaseVerticle::new)
            .compose(port -> {
                // Wait briefly for the async cluster init to finish.
                io.vertx.core.Promise<Integer> p = io.vertx.core.Promise.promise();
                vertx.setTimer(TimeUnit.SECONDS.toMillis(8), id -> p.complete(port));
                return p.future();
            })
            .compose(port -> get(vertx, port, "/couchbase/upsert?id=k1&v=hello-it")
                .compose(up -> {
                    ctx.verify(() -> assertThat(up.statusCode()).isEqualTo(200));
                    return get(vertx, port, "/couchbase/get?id=k1");
                }))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> {
                    assertThat(resp.statusCode()).isEqualTo(200);
                    assertThat(resp.bodyAsString()).contains("hello-it");
                });
                ctx.completeNow();
            }));
        await(ctx);
    }
}
