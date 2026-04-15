package com.demo;

import com.demo.verticles.*;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.CompositeFuture;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.http.HttpServer;
import io.vertx.ext.web.Router;
import io.vertx.micrometer.PrometheusScrapingHandler;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * MainVerticle — bootstraps the HTTP router and deploys all feature verticles.
 * Each feature verticle registers its routes via a shared Router.
 */
public class MainVerticle extends AbstractVerticle {

    @Override
    public void start(Promise<Void> startPromise) {
        Router router = Router.router(vertx);
        router.get("/metrics").handler(PrometheusScrapingHandler.create());
        router.get("/health").handler(ctx -> ctx.json(new io.vertx.core.json.JsonObject().put("ok", true)));
        router.get("/functions").handler(ctx -> ctx.json(new io.vertx.core.json.JsonArray(new ArrayList<>(Arrays.asList(
            "/leak/start", "/leak/stop",
            "/blocking/on-eventloop", "/blocking/execute-blocking",
            "/http/client", "/http/echo",
            "/redis/set", "/redis/get",
            "/postgres/query",
            "/mongo/insert", "/mongo/find",
            "/couchbase/upsert", "/couchbase/get",
            "/kafka/produce", "/kafka/consume",
            "/f2f/call",
            "/framework/future-chain",
            "/vault/read"
        )))));

        List<AbstractVerticle> features = new ArrayList<>();
        features.add(new FunctionRegistryVerticle(router));
        features.add(new ThreadLeakVerticle(router));
        features.add(new BlockingCallVerticle(router));
        features.add(new HttpClientVerticle(router));
        features.add(new RedisVerticle(router));
        features.add(new PostgresVerticle(router));
        features.add(new MongoVerticle(router));
        features.add(new CouchbaseVerticle(router));
        features.add(new KafkaVerticle(router));
        features.add(new F2FVerticle(router));
        features.add(new FrameworkComponentsVerticle(router));
        features.add(new VaultVerticle(router));

        List<Future<?>> deployments = new ArrayList<>();
        for (AbstractVerticle v : features) {
            deployments.add(vertx.deployVerticle(v, new DeploymentOptions()));
        }

        HttpServer server = vertx.createHttpServer().requestHandler(router);
        CompositeFuture.all(new ArrayList<>(deployments))
            .compose(cf -> server.listen(8080))
            .onSuccess(s -> { System.out.println("[demo] http :8080 ready"); startPromise.complete(); })
            .onFailure(startPromise::fail);
    }
}
