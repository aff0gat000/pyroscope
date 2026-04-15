package com.demo;

import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.micrometer.MicrometerMetricsOptions;
import io.vertx.micrometer.VertxPrometheusOptions;

public class Launcher {
    public static void main(String[] args) {
        VertxOptions opts = new VertxOptions()
            .setMetricsOptions(new MicrometerMetricsOptions()
                .setPrometheusOptions(new VertxPrometheusOptions().setEnabled(true))
                .setEnabled(true))
            .setWorkerPoolSize(8)
            .setInternalBlockingPoolSize(4);
        Vertx vertx = Vertx.vertx(opts);
        vertx.deployVerticle(new MainVerticle(), new DeploymentOptions(), res -> {
            if (res.failed()) { res.cause().printStackTrace(); System.exit(1); }
            else System.out.println("[demo] deployed MainVerticle: " + res.result());
        });
    }
}
