# Explanation — code walkthrough

A tour of the app source, in the order a reader should approach it.

## Entry point: `Launcher`

```java
VertxOptions opts = new VertxOptions()
    .setMetricsOptions(new MicrometerMetricsOptions()
        .setPrometheusOptions(new VertxPrometheusOptions().setEnabled(true))
        .setEnabled(true))
    .setWorkerPoolSize(8)
    .setInternalBlockingPoolSize(4);
Vertx vertx = Vertx.vertx(opts);
vertx.deployVerticle(new MainVerticle(), …);
```

- Metrics: Micrometer + Prometheus registry exposed at `/metrics`.
- `workerPoolSize=8`: deliberately small so `/couchbase/*` can saturate
  it and you can see contention.

## Router assembly: `MainVerticle`

```java
Router router = Router.router(vertx);
router.get("/metrics").handler(PrometheusScrapingHandler.create());
router.get("/health").handler(ctx -> ctx.json(new JsonObject().put("ok", true)));

List<AbstractVerticle> features = …;  // one per feature
List<Future<?>> deployments = …;
for (AbstractVerticle v : features) deployments.add(vertx.deployVerticle(v));

HttpServer server = vertx.createHttpServer().requestHandler(router);
CompositeFuture.all(deployments)
    .compose(cf -> server.listen(8080))
    .onSuccess(…); onFailure(…);
```

Two properties worth noting:

1. **One shared router.** Each feature verticle adds its own routes. No
   gateway verticle, no dispatching layer — routes are discoverable by
   reading any verticle's `start()`.
2. **Server starts last.** The `CompositeFuture` gate ensures no route is
   served before every verticle has registered.

## The label helper: `Label`

```java
public static void tag(String integration, Runnable fn) {
    Pyroscope.LabelsWrapper.run(new LabelsSet("integration", integration), fn);
}
```

`Pyroscope.LabelsWrapper.run` attaches a label to every profile sample
taken while the thread is inside the lambda. It's thread-local; work
dispatched to other threads (e.g. via `executeBlocking`) needs its own
`Label.tag` call inside the blocking code.

## Pattern: a non-blocking integration verticle

```java
public class RedisVerticle extends AbstractVerticle {
  private RedisAPI redis;
  @Override public void start(Promise<Void> p) {
    redis = RedisAPI.api(Redis.createClient(vertx,
        new RedisOptions().setConnectionString(System.getenv("REDIS_URL"))));
    router.get("/redis/set").handler(this::set);
    p.complete();
  }
  private void set(RoutingContext ctx) {
    Label.tag("redis", () -> redis.set(List.of(k, v))
        .onComplete(ar -> reply(ctx, ar.succeeded(), ar.cause())));
  }
}
```

Every integration verticle follows this shape: construct client in
`start()`, dispatch requests on the event loop, wrap the call in
`Label.tag`.

## Pattern: a blocking client on the worker pool

```java
// CouchbaseVerticle
vertx.executeBlocking(promise -> {
    Label.tag("couchbase", () -> collection.upsert(id, doc));
    promise.complete();
}, false, ar -> reply(ctx, ar.succeeded(), ar.cause()));
```

`false` = `ordered=false` — the worker pool can parallelise calls.

## Pattern: the antipattern (for teaching)

```java
// BlockingCallVerticle.onEventLoop  — DO NOT COPY
private void onEventLoop(RoutingContext ctx) {
    int ms = Integer.parseInt(ctx.request().getParam("ms", "200"));
    try { Thread.sleep(ms); } catch (InterruptedException e) {}
    ctx.json(…);
}
```

Deliberately blocks the event loop. The mirror endpoint
(`onWorker`) dispatches the same sleep via `executeBlocking`. Compare
wall-clock flame graphs across these two endpoints in Grafana.

## Java 21 addition: `VirtualThreadVerticle`

```java
public static DeploymentOptions options() {
    return new DeploymentOptions().setThreadingModel(ThreadingModel.VIRTUAL_THREAD);
}

private void sleep(RoutingContext ctx) {
    Thread.sleep(ms);   // safe on a virtual thread — Loom unmounts the carrier
    ctx.json(…);
}
```

`ThreadingModel.VIRTUAL_THREAD` deploys the verticle onto a virtual-thread
executor. Blocking calls no longer hold a carrier thread.

## Build & packaging

Shadow plugin produces a single fat jar:

```
/app/app.jar   <- demo-fat.jar (shadowed)
```

The Pyroscope agent is downloaded at image build time into `/opt/pyroscope/`
and attached via `JAVA_TOOL_OPTIONS` in compose. The app code does **not**
import the profiler — zero source changes required for profiling.

## File tree recap

```
apps/demo-jvm{11,21}/src/main/java/com/demo/
├── Launcher.java                # main()
├── MainVerticle.java            # router + deployment orchestrator
├── Label.java                   # Pyroscope label helper
└── verticles/
    ├── FunctionRegistryVerticle.java
    ├── ThreadLeakVerticle.java
    ├── BlockingCallVerticle.java
    ├── HttpClientVerticle.java
    ├── RedisVerticle.java
    ├── PostgresVerticle.java
    ├── MongoVerticle.java
    ├── CouchbaseVerticle.java
    ├── KafkaVerticle.java
    ├── F2FVerticle.java
    ├── FrameworkComponentsVerticle.java
    ├── VaultVerticle.java
    └── VirtualThreadVerticle.java   # jvm21 only
```
