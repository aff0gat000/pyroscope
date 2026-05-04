package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.kafka.client.consumer.KafkaConsumer;
import io.vertx.kafka.client.producer.KafkaProducer;
import io.vertx.kafka.client.producer.KafkaProducerRecord;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

public class KafkaVerticle extends AbstractVerticle {
    private static final Logger log = LoggerFactory.getLogger(KafkaVerticle.class);
    private final Router router;
    private KafkaProducer<String, String> producer;
    private KafkaConsumer<String, String> consumer;
    private final AtomicLong consumed = new AtomicLong();
    public KafkaVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        // Kafka producer/consumer construction does eager DNS resolution and
        // throws ConfigException if no bootstrap server is resolvable. Wrap
        // so the verticle still deploys (and routes still register) when no
        // broker is reachable — matches the "graceful degradation" pattern
        // used by Couchbase + Mongo here.
        String brokers = System.getenv().getOrDefault("KAFKA_BROKERS", "kafka:9092");
        Map<String, String> prod = new HashMap<>();
        prod.put("bootstrap.servers", brokers);
        prod.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        prod.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        prod.put("acks", "1");
        try {
            producer = KafkaProducer.create(vertx, prod);

            Map<String, String> cons = new HashMap<>(prod);
            cons.remove("key.serializer"); cons.remove("value.serializer"); cons.remove("acks");
            cons.put("key.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
            cons.put("value.deserializer", "org.apache.kafka.common.serialization.StringDeserializer");
            cons.put("group.id", "demo-" + System.getProperty("java.version"));
            cons.put("auto.offset.reset", "earliest");
            consumer = KafkaConsumer.create(vertx, cons);
            consumer.handler(r -> Label.tag("kafka", () -> consumed.incrementAndGet()));
            consumer.subscribe("demo");
        } catch (Exception e) {
            log.warn("kafka init failed (broker unreachable): {}", e.getMessage());
        }

        router.get("/kafka/produce").handler(this::produce);
        router.get("/kafka/consume").handler(this::consumeStatus);
        p.complete();
    }

    private void produce(RoutingContext ctx) {
        if (producer == null) { ctx.response().setStatusCode(503).end("kafka not ready"); return; }
        String v = ctx.request().getParam("v", "msg-" + System.nanoTime());
        Label.tag("kafka", () -> producer.send(KafkaProducerRecord.create("demo", v), ar -> {
            if (ar.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("offset", ar.result().getOffset()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }

    private void consumeStatus(RoutingContext ctx) {
        ctx.json(new io.vertx.core.json.JsonObject().put("consumed", consumed.get()));
    }

    @Override public void stop(io.vertx.core.Promise<Void> stopPromise) {
        // Close producer + consumer; ignore failures (best-effort cleanup).
        java.util.List<io.vertx.core.Future<?>> futures = new java.util.ArrayList<>();
        if (producer != null) futures.add(producer.close().otherwiseEmpty());
        if (consumer != null) futures.add(consumer.close().otherwiseEmpty());
        io.vertx.core.CompositeFuture.join(new java.util.ArrayList<>(futures))
            .<Void>mapEmpty().onComplete(ar -> stopPromise.complete());
    }
}
