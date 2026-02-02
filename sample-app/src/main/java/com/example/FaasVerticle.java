package com.example;

import io.micrometer.prometheus.PrometheusMeterRegistry;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.CompositeFuture;
import io.vertx.core.DeploymentOptions;
import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.handler.BodyHandler;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedDeque;
import java.util.concurrent.atomic.AtomicLong;


/**
 * FaaS Runtime — a lightweight Function-as-a-Service verticle that
 * dynamically deploys and undeploys short-lived verticle "functions" on demand.
 *
 * Each invocation deploys a verticle with a unique event bus address, sends it
 * an event, collects the result, then undeploys it, producing a distinct
 * profiling signature: classloader activity, deployment lifecycle overhead,
 * short-burst compute, and concurrent deploy/undeploy contention.
 */
public class FaasVerticle extends AbstractVerticle {

    private static final Random RNG = new Random();
    private final boolean optimized;
    private final PrometheusMeterRegistry registry;

    // Function registry: name -> factory that produces a verticle for a given unique address
    private final Map<String, java.util.function.Function<String, AbstractVerticle>> functions = new LinkedHashMap<>();

    // Invocation stats
    private final Map<String, AtomicLong> invocationCounts = new ConcurrentHashMap<>();
    private final Map<String, AtomicLong> totalLatencyNanos = new ConcurrentHashMap<>();

    // Warm pool: name -> queue of (deploymentId, address) pairs
    private final Map<String, ConcurrentLinkedDeque<String[]>> warmPools = new ConcurrentHashMap<>();

    private final AtomicLong addressCounter = new AtomicLong();

    public FaasVerticle(PrometheusMeterRegistry registry) {
        this.registry = registry;
        this.optimized = "true".equalsIgnoreCase(System.getenv("OPTIMIZED"));
        registerBuiltinFunctions();
    }

    private String nextAddress(String fnName) {
        return "fn." + fnName + "." + addressCounter.incrementAndGet();
    }

    private void registerBuiltinFunctions() {

        // --- CPU-bound: recursive Fibonacci ---
        functions.put("fibonacci", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int n = msg.body().getInteger("n", 35 + RNG.nextInt(5));
                    long result = fibonacciCompute(n);
                    msg.reply(new JsonObject().put("result", result).put("n", n));
                });
            }
        });

        // --- Alloc-heavy: JSON dataset transformation ---
        functions.put("transform", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int size = msg.body().getInteger("size", 5000);
                    List<Map<String, Object>> dataset = new ArrayList<>(size);
                    for (int i = 0; i < size; i++) {
                        Map<String, Object> row = new HashMap<>();
                        row.put("id", UUID.randomUUID().toString());
                        row.put("value", RNG.nextDouble() * 1000);
                        row.put("label", "item-" + i);
                        row.put("tags", Arrays.asList("a", "b", "c-" + (i % 10)));
                        dataset.add(row);
                    }
                    long count = dataset.stream()
                            .filter(r -> (double) r.get("value") > 500)
                            .count();
                    msg.reply(new JsonObject().put("processed", size).put("filtered", count));
                });
            }
        });

        // --- CPU burst: iterated SHA-256 hashing ---
        functions.put("hash", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int rounds = msg.body().getInteger("rounds", 10000);
                    String input = msg.body().getString("input", UUID.randomUUID().toString());
                    try {
                        MessageDigest md = MessageDigest.getInstance("SHA-256");
                        byte[] data = input.getBytes(StandardCharsets.UTF_8);
                        for (int i = 0; i < rounds; i++) {
                            data = md.digest(data);
                        }
                        msg.reply(new JsonObject()
                                .put("rounds", rounds)
                                .put("hash", bytesToHex(data)));
                    } catch (NoSuchAlgorithmException e) {
                        msg.fail(500, e.getMessage());
                    }
                });
            }
        });

        // --- CPU + alloc: generate and sort large dataset ---
        functions.put("sort", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int size = msg.body().getInteger("size", 100000);
                    List<String> data = new ArrayList<>(size);
                    for (int i = 0; i < size; i++) {
                        data.add("item-" + RNG.nextInt(size * 10));
                    }
                    data.sort(String::compareTo);
                    msg.reply(new JsonObject().put("sorted", size).put("first", data.get(0)));
                });
            }
        });

        // --- Simulated I/O latency ---
        functions.put("sleep", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int ms = msg.body().getInteger("ms", 100 + RNG.nextInt(200));
                    vertx.setTimer(ms, id ->
                            msg.reply(new JsonObject().put("slept_ms", ms)));
                });
            }
        });

        // --- Matrix multiply: CPU-heavy linear algebra workload ---
        functions.put("matrix", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int dim = msg.body().getInteger("dim", 120);
                    double[][] a = randomMatrix(dim);
                    double[][] b = randomMatrix(dim);
                    double[][] c = new double[dim][dim];
                    for (int i = 0; i < dim; i++) {
                        for (int j = 0; j < dim; j++) {
                            double sum = 0;
                            for (int k = 0; k < dim; k++) {
                                sum += a[i][k] * b[k][j];
                            }
                            c[i][j] = sum;
                        }
                    }
                    msg.reply(new JsonObject().put("dim", dim).put("checksum", c[0][0]));
                });
            }
        });

        // --- Regex: pattern matching workload (CPU + backtracking) ---
        functions.put("regex", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int count = msg.body().getInteger("count", 5000);
                    java.util.regex.Pattern pattern = java.util.regex.Pattern.compile(
                            "^(?:[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}|\\d{1,3}(?:\\.\\d{1,3}){3})$");
                    int matches = 0;
                    for (int i = 0; i < count; i++) {
                        String candidate = (i % 3 == 0)
                                ? "user" + i + "@example.com"
                                : "not-an-email-" + RNG.nextInt(99999);
                        if (pattern.matcher(candidate).matches()) {
                            matches++;
                        }
                    }
                    msg.reply(new JsonObject().put("tested", count).put("matches", matches));
                });
            }
        });

        // --- Compress: zlib compression workload (CPU + I/O buffer alloc) ---
        functions.put("compress", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int size = msg.body().getInteger("size", 50000);
                    StringBuilder sb = new StringBuilder(size);
                    for (int i = 0; i < size; i++) {
                        sb.append((char) ('A' + RNG.nextInt(26)));
                    }
                    byte[] input = sb.toString().getBytes(StandardCharsets.UTF_8);
                    java.io.ByteArrayOutputStream baos = new java.io.ByteArrayOutputStream();
                    try (java.util.zip.GZIPOutputStream gz = new java.util.zip.GZIPOutputStream(baos)) {
                        gz.write(input);
                    } catch (java.io.IOException e) {
                        msg.fail(500, e.getMessage());
                        return;
                    }
                    msg.reply(new JsonObject()
                            .put("input_bytes", input.length)
                            .put("compressed_bytes", baos.size())
                            .put("ratio", Math.round((1.0 - (double) baos.size() / input.length) * 10000) / 100.0));
                });
            }
        });

        // --- Prime sieve: CPU-bound number theory workload ---
        functions.put("primes", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int limit = msg.body().getInteger("limit", 200000);
                    boolean[] sieve = new boolean[limit + 1];
                    Arrays.fill(sieve, true);
                    sieve[0] = sieve[1] = false;
                    for (int i = 2; (long) i * i <= limit; i++) {
                        if (sieve[i]) {
                            for (int j = i * i; j <= limit; j += i) {
                                sieve[j] = false;
                            }
                        }
                    }
                    int count = 0;
                    for (boolean b : sieve) if (b) count++;
                    msg.reply(new JsonObject().put("limit", limit).put("primes_found", count));
                });
            }
        });

        // --- Contention: synchronized blocks to produce mutex profile data ---
        functions.put("contention", addr -> new AbstractVerticle() {
            private final Object lock = new Object();
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int threads = msg.body().getInteger("threads", 4);
                    int iterations = msg.body().getInteger("iterations", 200);
                    java.util.concurrent.CountDownLatch latch = new java.util.concurrent.CountDownLatch(threads);
                    java.util.concurrent.atomic.AtomicLong total = new java.util.concurrent.atomic.AtomicLong();
                    for (int t = 0; t < threads; t++) {
                        final int threadId = t;
                        new Thread(() -> {
                            for (int i = 0; i < iterations; i++) {
                                synchronized (lock) {
                                    long v = threadId * 1000L + i;
                                    for (int j = 0; j < 2000; j++) {
                                        v = (v * 6364136223846793005L + 1442695040888963407L);
                                    }
                                    total.addAndGet(v);
                                }
                            }
                            latch.countDown();
                        }).start();
                    }
                    vertx.executeBlocking(p -> {
                        try { latch.await(); } catch (InterruptedException e) { Thread.currentThread().interrupt(); }
                        p.complete(total.get());
                    }, false, ar -> msg.reply(new JsonObject()
                            .put("threads", threads).put("iterations", iterations)
                            .put("result", total.get())));
                });
            }
        });

        // --- Fanout: deploys N child function verticles in parallel ---
        functions.put("fanout", addr -> new AbstractVerticle() {
            @Override
            public void start() {
                vertx.eventBus().<JsonObject>consumer(addr, msg -> {
                    int fanCount = msg.body().getInteger("count", 3);
                    String childFnName = msg.body().getString("function", "hash");
                    var childFactory = functions.get(childFnName);
                    if (childFactory == null) {
                        msg.fail(404, "unknown child function: " + childFnName);
                        return;
                    }

                    @SuppressWarnings("rawtypes")
                    List<Future> futures = new ArrayList<>();
                    for (int i = 0; i < fanCount; i++) {
                        String childAddr = nextAddress(childFnName);
                        JsonObject childParams = new JsonObject().put("rounds", 1000);
                        futures.add(
                                vertx.deployVerticle(childFactory.apply(childAddr), new DeploymentOptions())
                                        .compose(depId ->
                                                vertx.eventBus().<JsonObject>request(childAddr, childParams)
                                                        .map(r -> new Object[]{depId, r.body()}))
                                        .compose(arr -> {
                                            String depId = (String) arr[0];
                                            JsonObject result = (JsonObject) arr[1];
                                            return vertx.undeploy(depId).map(result);
                                        }));
                    }

                    CompositeFuture.all(futures).onComplete(ar -> {
                        if (ar.succeeded()) {
                            JsonArray results = new JsonArray();
                            for (int i = 0; i < ar.result().size(); i++) {
                                results.add(ar.result().resultAt(i));
                            }
                            msg.reply(new JsonObject().put("fanout", fanCount).put("results", results));
                        } else {
                            msg.fail(500, ar.cause().getMessage());
                        }
                    });
                });
            }
        });
    }

    @Override
    public void start() {
        Router router = Router.router(vertx);
        router.route().handler(BodyHandler.create());

        // Health & metrics
        router.get("/health").handler(ctx -> ctx.response().end("OK"));
        router.get("/metrics").handler(ctx ->
                ctx.response().putHeader("content-type", "text/plain").end(registry.scrape()));

        // FaaS endpoints
        router.post("/fn/invoke/:name").handler(this::handleInvoke);
        router.post("/fn/burst/:name").handler(this::handleBurst);
        router.get("/fn/list").handler(this::handleList);
        router.get("/fn/stats").handler(this::handleStats);
        router.post("/fn/chain").handler(this::handleChain);
        router.post("/fn/warmpool/:name").handler(this::handleWarmPoolCreate);
        router.delete("/fn/warmpool/:name").handler(this::handleWarmPoolDelete);

        vertx.createHttpServer()
                .requestHandler(router)
                .listen(8080)
                .onSuccess(s -> System.out.println("FaaS server started on port 8080"));
    }

    // ---- Invoke: deploy → execute → undeploy ----

    private void handleInvoke(RoutingContext ctx) {
        String name = ctx.pathParam("name");
        var factory = functions.get(name);
        if (factory == null) {
            ctx.response().setStatusCode(404).end(new JsonObject().put("error", "unknown function: " + name).encode());
            return;
        }

        JsonObject params = ctx.body().asJsonObject() != null ? ctx.body().asJsonObject() : new JsonObject();
        long start = System.nanoTime();

        invokeFunction(name, factory, params).onComplete(ar -> {
            long elapsed = System.nanoTime() - start;
            recordInvocation(name, elapsed);
            if (ar.succeeded()) {
                ctx.response()
                        .putHeader("content-type", "application/json")
                        .end(ar.result().put("latency_ms", elapsed / 1_000_000.0).encode());
            } else {
                ctx.response().setStatusCode(500)
                        .end(new JsonObject().put("error", ar.cause().getMessage()).encode());
            }
        });
    }

    private Future<JsonObject> invokeFunction(String name,
                                               java.util.function.Function<String, AbstractVerticle> factory,
                                               JsonObject params) {
        if (optimized) {
            return invokeFunctionFromWarmPool(name, factory, params);
        }
        return invokeFunctionCold(name, factory, params);
    }

    private Future<JsonObject> invokeFunctionCold(String name,
                                                   java.util.function.Function<String, AbstractVerticle> factory,
                                                   JsonObject params) {
        Promise<JsonObject> promise = Promise.promise();
        String address = nextAddress(name);

        vertx.deployVerticle(factory.apply(address), new DeploymentOptions())
                .compose(deploymentId ->
                        vertx.eventBus().<JsonObject>request(address, params)
                                .map(msg -> new Object[]{deploymentId, msg.body()}))
                .compose(arr -> {
                    String depId = (String) arr[0];
                    JsonObject result = (JsonObject) arr[1];
                    return vertx.undeploy(depId).map(result);
                })
                .onSuccess(promise::complete)
                .onFailure(promise::fail);

        return promise.future();
    }

    private Future<JsonObject> invokeFunctionFromWarmPool(String name,
                                                           java.util.function.Function<String, AbstractVerticle> factory,
                                                           JsonObject params) {
        ConcurrentLinkedDeque<String[]> pool = warmPools.get(name);
        if (pool != null) {
            String[] entry = pool.pollFirst();
            if (entry != null) {
                String depId = entry[0];
                String address = entry[1];
                return vertx.eventBus().<JsonObject>request(address, params)
                        .map(msg -> {
                            pool.addLast(entry); // Return to pool
                            return msg.body().put("warm", true);
                        });
            }
        }
        return invokeFunctionCold(name, factory, params);
    }

    // ---- Burst: N concurrent invocations ----

    private void handleBurst(RoutingContext ctx) {
        String name = ctx.pathParam("name");
        var factory = functions.get(name);
        if (factory == null) {
            ctx.response().setStatusCode(404).end(new JsonObject().put("error", "unknown function: " + name).encode());
            return;
        }

        int count = Integer.parseInt(ctx.request().getParam("count", "5"));
        JsonObject params = ctx.body().asJsonObject() != null ? ctx.body().asJsonObject() : new JsonObject();
        long start = System.nanoTime();

        @SuppressWarnings("rawtypes")
        List<Future> futures = new ArrayList<>();
        for (int i = 0; i < count; i++) {
            futures.add(invokeFunction(name, factory, params));
        }

        CompositeFuture.all(futures).onComplete(ar -> {
            long elapsed = System.nanoTime() - start;
            JsonObject resp = new JsonObject()
                    .put("function", name)
                    .put("count", count)
                    .put("total_ms", elapsed / 1_000_000.0);
            if (ar.succeeded()) {
                JsonArray results = new JsonArray();
                for (int i = 0; i < ar.result().size(); i++) {
                    results.add(ar.result().resultAt(i));
                }
                resp.put("results", results);
            } else {
                resp.put("error", ar.cause().getMessage());
            }
            ctx.response().putHeader("content-type", "application/json").end(resp.encode());
        });
    }

    // ---- List functions ----

    private void handleList(RoutingContext ctx) {
        JsonArray arr = new JsonArray();
        functions.keySet().forEach(arr::add);
        ctx.response().putHeader("content-type", "application/json")
                .end(new JsonObject().put("functions", arr).encode());
    }

    // ---- Stats ----

    private void handleStats(RoutingContext ctx) {
        JsonObject stats = new JsonObject();
        for (String name : functions.keySet()) {
            long count = invocationCounts.getOrDefault(name, new AtomicLong()).get();
            long totalNs = totalLatencyNanos.getOrDefault(name, new AtomicLong()).get();
            double avgMs = count > 0 ? (totalNs / (double) count) / 1_000_000.0 : 0;
            stats.put(name, new JsonObject()
                    .put("invocations", count)
                    .put("avg_latency_ms", Math.round(avgMs * 100.0) / 100.0));
        }
        ctx.response().putHeader("content-type", "application/json").end(stats.encode());
    }

    // ---- Chain: sequential function execution ----

    private void handleChain(RoutingContext ctx) {
        JsonObject body = ctx.body().asJsonObject();
        if (body == null || !body.containsKey("chain")) {
            ctx.response().setStatusCode(400)
                    .end(new JsonObject().put("error", "body must contain 'chain' array of function names").encode());
            return;
        }

        JsonArray chain = body.getJsonArray("chain");
        JsonObject params = body.getJsonObject("params", new JsonObject());
        long start = System.nanoTime();

        Future<JsonObject> future = Future.succeededFuture(params);
        JsonArray stepResults = new JsonArray();

        for (int i = 0; i < chain.size(); i++) {
            String fnName = chain.getString(i);
            var factory = functions.get(fnName);
            if (factory == null) {
                ctx.response().setStatusCode(404)
                        .end(new JsonObject().put("error", "unknown function in chain: " + fnName).encode());
                return;
            }
            future = future.compose(p -> {
                long stepStart = System.nanoTime();
                return invokeFunction(fnName, factory, p).map(result -> {
                    long stepElapsed = System.nanoTime() - stepStart;
                    recordInvocation(fnName, stepElapsed);
                    stepResults.add(new JsonObject()
                            .put("function", fnName)
                            .put("latency_ms", stepElapsed / 1_000_000.0)
                            .put("result", result));
                    return result;
                });
            });
        }

        future.onComplete(ar -> {
            long elapsed = System.nanoTime() - start;
            JsonObject resp = new JsonObject()
                    .put("chain_length", chain.size())
                    .put("total_ms", elapsed / 1_000_000.0)
                    .put("steps", stepResults);
            if (ar.failed()) {
                resp.put("error", ar.cause().getMessage());
            }
            ctx.response().putHeader("content-type", "application/json").end(resp.encode());
        });
    }

    // ---- Warm Pool ----

    private void handleWarmPoolCreate(RoutingContext ctx) {
        String name = ctx.pathParam("name");
        var factory = functions.get(name);
        if (factory == null) {
            ctx.response().setStatusCode(404).end(new JsonObject().put("error", "unknown function: " + name).encode());
            return;
        }

        int size = Integer.parseInt(ctx.request().getParam("size", "5"));
        ConcurrentLinkedDeque<String[]> pool = warmPools.computeIfAbsent(name, k -> new ConcurrentLinkedDeque<>());

        @SuppressWarnings("rawtypes")
        List<Future> futures = new ArrayList<>();
        for (int i = 0; i < size; i++) {
            String address = nextAddress(name);
            futures.add(vertx.deployVerticle(factory.apply(address), new DeploymentOptions())
                    .map(depId -> {
                        pool.addLast(new String[]{depId, address});
                        return depId;
                    }));
        }

        CompositeFuture.all(futures).onComplete(ar -> {
            if (ar.succeeded()) {
                ctx.response().putHeader("content-type", "application/json")
                        .end(new JsonObject()
                                .put("function", name)
                                .put("pool_size", pool.size())
                                .put("deployed", size).encode());
            } else {
                ctx.response().setStatusCode(500)
                        .end(new JsonObject().put("error", ar.cause().getMessage()).encode());
            }
        });
    }

    private void handleWarmPoolDelete(RoutingContext ctx) {
        String name = ctx.pathParam("name");
        ConcurrentLinkedDeque<String[]> pool = warmPools.remove(name);
        if (pool == null || pool.isEmpty()) {
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject().put("function", name).put("undeployed", 0).encode());
            return;
        }

        @SuppressWarnings("rawtypes")
        List<Future> futures = new ArrayList<>();
        String[] entry;
        while ((entry = pool.pollFirst()) != null) {
            futures.add(vertx.undeploy(entry[0]));
        }

        int count = futures.size();
        CompositeFuture.all(futures).onComplete(ar ->
                ctx.response().putHeader("content-type", "application/json")
                        .end(new JsonObject().put("function", name).put("undeployed", count).encode()));
    }

    // ---- Helpers ----

    private void recordInvocation(String name, long elapsedNanos) {
        invocationCounts.computeIfAbsent(name, k -> new AtomicLong()).incrementAndGet();
        totalLatencyNanos.computeIfAbsent(name, k -> new AtomicLong()).addAndGet(elapsedNanos);
    }

    private static long fibonacciCompute(int n) {
        if (n <= 1) return n;
        return fibonacciCompute(n - 1) + fibonacciCompute(n - 2);
    }

    private static String bytesToHex(byte[] bytes) {
        StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }

    private static double[][] randomMatrix(int dim) {
        double[][] m = new double[dim][dim];
        for (int i = 0; i < dim; i++) {
            for (int j = 0; j < dim; j++) {
                m[i][j] = RNG.nextDouble();
            }
        }
        return m;
    }
}
