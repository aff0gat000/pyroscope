package com.pyroscope.vertx;

import io.vertx.core.AsyncResult;
import io.vertx.core.Future;
import io.vertx.core.Handler;
import io.vertx.ext.web.RoutingContext;

import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import java.util.function.Function;
import java.util.function.Supplier;

/**
 * Propagates Pyroscope labels across Vert.x async boundaries.
 *
 * <p>The Tier 1 label handler in AbstractFunctionVerticle sets labels on the
 * RoutingContext during the synchronous handler path. LabeledFuture captures
 * those labels and re-applies them inside async callbacks (onSuccess, compose,
 * map) so that CPU samples taken during async processing are still attributed
 * to the originating endpoint and function.
 *
 * <p>Usage:
 * <pre>{@code
 * // Basic — labels from Tier 1 handler carry into the callback
 * LabeledFuture.from(ctx, webClient.get(port, host, "/baseline").send())
 *     .onSuccess(response -> {
 *         // Labels active: endpoint, function, layer, http.method
 *         JsonObject result = heavyComputation(response.bodyAsJsonObject());
 *         ctx.response().end(result.encode());
 *     });
 *
 * // With downstream attribution
 * LabeledFuture.from(ctx, "pyroscope-sor", webClient.get(port, host, "/baseline").send())
 *     .onSuccess(response -> {
 *         // Labels active: endpoint, function, layer, http.method, downstream=pyroscope-sor
 *     });
 *
 * // Chained async calls
 * LabeledFuture.from(ctx, "pyroscope-sor", webClient.get(...).send())
 *     .compose(sorResponse -> {
 *         JsonObject baseline = sorResponse.bodyAsJsonObject();
 *         return webClient.post(apiPort, "localhost", "/render")
 *             .sendJsonObject(baseline);
 *     })
 *     .onSuccess(apiResponse -> {
 *         ctx.response().end(apiResponse.bodyAsJsonObject().encode());
 *     });
 * }</pre>
 *
 * <p>When the Pyroscope agent is not attached (local dev, tests), all label
 * operations are no-ops — the wrapped code runs normally with zero overhead.
 */
public class LabeledFuture<T> {

    static final String LABELS_KEY = "pyroscope.labels";

    private final Future<T> delegate;
    private final Map<String, String> labels;

    LabeledFuture(Future<T> delegate, Map<String, String> labels) {
        this.delegate = delegate;
        this.labels = labels != null ? labels : Collections.emptyMap();
    }

    /**
     * Wrap a Future with the labels stored on the RoutingContext by the Tier 1 handler.
     */
    public static <T> LabeledFuture<T> from(RoutingContext ctx, Future<T> future) {
        Map<String, String> labels = ctx.get(LABELS_KEY);
        return new LabeledFuture<>(future, labels);
    }

    /**
     * Wrap a Future with labels from RoutingContext plus a downstream service label.
     * Use this when making outbound HTTP calls to identify which dependency is being called.
     */
    public static <T> LabeledFuture<T> from(RoutingContext ctx, String downstream, Future<T> future) {
        Map<String, String> base = ctx.get(LABELS_KEY);
        Map<String, String> labels = new HashMap<>(base != null ? base : Collections.emptyMap());
        labels.put("downstream", downstream);
        return new LabeledFuture<>(future, labels);
    }

    public LabeledFuture<T> onSuccess(Handler<T> handler) {
        delegate.onSuccess(result -> runWithLabels(() -> handler.handle(result)));
        return this;
    }

    public LabeledFuture<T> onFailure(Handler<Throwable> handler) {
        delegate.onFailure(err -> runWithLabels(() -> handler.handle(err)));
        return this;
    }

    public LabeledFuture<T> onComplete(Handler<AsyncResult<T>> handler) {
        delegate.onComplete(ar -> runWithLabels(() -> handler.handle(ar)));
        return this;
    }

    public <U> LabeledFuture<U> compose(Function<T, Future<U>> fn) {
        Future<U> composed = delegate.compose(result ->
                callWithLabels(() -> fn.apply(result)));
        return new LabeledFuture<>(composed, labels);
    }

    public <U> LabeledFuture<U> map(Function<T, U> fn) {
        Future<U> mapped = delegate.map(result ->
                callWithLabels(() -> fn.apply(result)));
        return new LabeledFuture<>(mapped, labels);
    }

    /**
     * Access the underlying Vert.x Future for methods not wrapped by LabeledFuture.
     */
    public Future<T> unwrap() {
        return delegate;
    }

    private void runWithLabels(Runnable action) {
        if (labels.isEmpty()) {
            action.run();
            return;
        }
        try {
            String[] pairs = toPairs();
            io.pyroscope.labels.Pyroscope.LabelsWrapper.run(
                    new io.pyroscope.labels.LabelsSet((Object[]) pairs),
                    action
            );
        } catch (NoClassDefFoundError e) {
            action.run();
        }
    }

    private <R> R callWithLabels(Supplier<R> supplier) {
        if (labels.isEmpty()) {
            return supplier.get();
        }
        try {
            @SuppressWarnings("unchecked")
            R[] holder = (R[]) new Object[1];
            String[] pairs = toPairs();
            Runnable wrapped = () -> holder[0] = supplier.get();
            io.pyroscope.labels.Pyroscope.LabelsWrapper.run(
                    new io.pyroscope.labels.LabelsSet((Object[]) pairs),
                    wrapped
            );
            return holder[0];
        } catch (NoClassDefFoundError e) {
            return supplier.get();
        }
    }

    private String[] toPairs() {
        String[] pairs = new String[labels.size() * 2];
        int i = 0;
        for (Map.Entry<String, String> entry : labels.entrySet()) {
            pairs[i++] = entry.getKey();
            pairs[i++] = entry.getValue();
        }
        return pairs;
    }
}
