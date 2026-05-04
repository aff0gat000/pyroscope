package com.demo;

import io.vertx.core.DeploymentOptions;
import io.vertx.core.Vertx;
import io.vertx.core.VertxOptions;
import io.vertx.micrometer.MicrometerMetricsOptions;
import io.vertx.micrometer.VertxPrometheusOptions;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

public final class Launcher {
    private static final Logger log = LoggerFactory.getLogger(Launcher.class);

    private Launcher() {}

    public static void main(String[] args) {
        VertxOptions opts = new VertxOptions()
            .setMetricsOptions(new MicrometerMetricsOptions()
                .setPrometheusOptions(new VertxPrometheusOptions().setEnabled(true))
                .setEnabled(true))
            .setWorkerPoolSize(8)
            .setInternalBlockingPoolSize(4);
        Vertx vertx = Vertx.vertx(opts);
        vertx.deployVerticle(new MainVerticle(), new DeploymentOptions(), res -> {
            if (res.failed()) {
                log.error("MainVerticle deployment failed", res.cause());
                System.exit(1);
            } else {
                log.info("deployed MainVerticle: {}", res.result());
            }
        });
    }
}
