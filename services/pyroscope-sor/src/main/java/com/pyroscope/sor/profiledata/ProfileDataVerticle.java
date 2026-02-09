package com.pyroscope.sor.profiledata;

import com.pyroscope.sor.AbstractFunctionVerticle;
import com.pyroscope.sor.ProfileType;
import com.pyroscope.sor.PyroscopeClient;
import com.pyroscope.sor.PyroscopeClient.FunctionSample;
import io.vertx.core.CompositeFuture;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

import java.time.Instant;
import java.util.List;

/**
 * Profile Data SOR — data access layer for Pyroscope profile data.
 *
 * <p>Wraps the Pyroscope HTTP API, manages connections, parses the vendor-specific
 * flamebearer format, and exposes a clean JSON contract for BOR consumers.
 * No business logic — only data access, mapping, and retry.
 *
 * <h3>API</h3>
 * <pre>
 * GET /profiles/apps
 *   ?from=epoch  &amp;to=epoch
 *
 * GET /profiles/:appName
 *   ?type=cpu  &amp;from=epoch  &amp;to=epoch  &amp;limit=50
 *
 * GET /profiles/:appName/diff
 *   ?type=cpu  &amp;from=epoch  &amp;to=epoch  &amp;baselineFrom=epoch  &amp;baselineTo=epoch  &amp;limit=500
 * </pre>
 */
public class ProfileDataVerticle extends AbstractFunctionVerticle {

    private final String pyroscopeUrl;
    private PyroscopeClient pyroscope;

    public ProfileDataVerticle(String pyroscopeUrl, int port) {
        super(port);
        this.pyroscopeUrl = pyroscopeUrl;
    }

    @Override
    protected void initFunction() {
        pyroscope = new PyroscopeClient(vertx, pyroscopeUrl);
        router.get("/profiles/apps").handler(this::getApps);
        router.get("/profiles/:appName/diff").handler(this::getProfileDiff);
        router.get("/profiles/:appName").handler(this::getProfile);
    }

    /**
     * Render a single profile, parse flamebearer, return top functions.
     */
    private void getProfile(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);
        String type = paramStr(ctx, "type", "cpu");
        int limit = paramInt(ctx, "limit", 50);

        String query = ProfileType.fromString(type).queryFor(appName);

        pyroscope.render(query, from, to).onSuccess(raw -> {
            List<FunctionSample> functions =
                    PyroscopeClient.extractTopFunctions(raw, limit);
            long totalSamples = functions.isEmpty() ? 0
                    : functions.get(0).totalTicks();

            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("profileType", type)
                            .put("from", from)
                            .put("to", to)
                            .put("totalSamples", totalSamples)
                            .put("functions", toJsonArray(functions))
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 502, err.getMessage()));
    }

    /**
     * Render two time ranges, parse both, return baseline + current function lists.
     * The BOR computes deltas — this SOR only handles data access and mapping.
     */
    private void getProfileDiff(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        long now = Instant.now().getEpochSecond();
        long to = paramLong(ctx, "to", now);
        long from = paramLong(ctx, "from", to - 3600);
        long baselineTo = paramLong(ctx, "baselineTo", from);
        long baselineFrom = paramLong(ctx, "baselineFrom", baselineTo - 3600);
        String type = paramStr(ctx, "type", "cpu");
        int limit = paramInt(ctx, "limit", 500);

        String query = ProfileType.fromString(type).queryFor(appName);

        var baselineFuture = pyroscope.render(query, baselineFrom, baselineTo);
        var currentFuture = pyroscope.render(query, from, to);

        CompositeFuture.all(baselineFuture, currentFuture).onComplete(ar -> {
            if (ar.failed()) {
                error(ctx, 502, ar.cause().getMessage());
                return;
            }

            List<FunctionSample> baselineFns =
                    PyroscopeClient.extractTopFunctions(baselineFuture.result(), limit);
            List<FunctionSample> currentFns =
                    PyroscopeClient.extractTopFunctions(currentFuture.result(), limit);

            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("profileType", type)
                            .put("baseline", profileBlock(baselineFrom, baselineTo, baselineFns))
                            .put("current", profileBlock(from, to, currentFns))
                            .encodePrettily());
        });
    }

    /**
     * Discover all application names from Pyroscope label index.
     */
    private void getApps(RoutingContext ctx) {
        long now = Instant.now().getEpochSecond();
        long from = paramLong(ctx, "from", now - 3600);
        long to = paramLong(ctx, "to", now);

        pyroscope.discoverApps(from, to).onSuccess(apps ->
                ctx.response().putHeader("content-type", "application/json")
                        .end(new JsonObject()
                                .put("apps", new JsonArray(apps))
                                .encodePrettily())
        ).onFailure(err -> error(ctx, 502, err.getMessage()));
    }

    // ---- Mapping helpers (data concern, not business logic) ----

    private JsonObject profileBlock(long from, long to, List<FunctionSample> fns) {
        return new JsonObject()
                .put("from", from)
                .put("to", to)
                .put("totalSamples", fns.isEmpty() ? 0 : fns.get(0).totalTicks())
                .put("functions", toJsonArray(fns));
    }

    private JsonArray toJsonArray(List<FunctionSample> functions) {
        JsonArray arr = new JsonArray();
        for (var f : functions) {
            arr.add(new JsonObject()
                    .put("name", f.name())
                    .put("selfPercent", Math.round(f.selfPercent() * 100.0) / 100.0)
                    .put("selfSamples", f.selfSamples())
                    .put("totalSamples", f.totalSamples()));
        }
        return arr;
    }

    private static long paramLong(RoutingContext ctx, String name, long defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Long.parseLong(val) : defaultValue;
    }

    private static int paramInt(RoutingContext ctx, String name, int defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Integer.parseInt(val) : defaultValue;
    }

    private static String paramStr(RoutingContext ctx, String name, String defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null && !val.isBlank() ? val : defaultValue;
    }

    private static void error(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encodePrettily());
    }
}
