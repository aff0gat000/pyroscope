package com.demo.verticles;

import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.kafka.client.consumer.KafkaConsumer;
import io.vertx.kafka.client.producer.KafkaProducer;
import io.vertx.kafka.client.producer.KafkaProducerRecord;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicLong;

public class KafkaVerticle extends AbstractVerticle {
    private final Router router;
    private KafkaProducer<String, String> producer;
    private KafkaConsumer<String, String> consumer;
    private final AtomicLong consumed = new AtomicLong();
    public KafkaVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        String brokers = System.getenv().getOrDefault("KAFKA_BROKERS", "kafka:9092");
        Map<String, String> prod = new HashMap<>();
        prod.put("bootstrap.servers", brokers);
        prod.put("key.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        prod.put("value.serializer", "org.apache.kafka.common.serialization.StringSerializer");
        prod.put("acks", "1");
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

        router.get("/kafka/produce").handler(this::produce);
        router.get("/kafka/consume").handler(this::consumeStatus);
        p.complete();
    }

    private void produce(RoutingContext ctx) {
        String v = ctx.request().getParam("v", "msg-" + System.nanoTime());
        Label.tag("kafka", () -> producer.send(KafkaProducerRecord.create("demo", v), ar -> {
            if (ar.succeeded()) ctx.json(new io.vertx.core.json.JsonObject().put("offset", ar.result().getOffset()));
            else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
        }));
    }

    private void consumeStatus(RoutingContext ctx) {
        ctx.json(new io.vertx.core.json.JsonObject().put("consumed", consumed.get()));
    }
}
