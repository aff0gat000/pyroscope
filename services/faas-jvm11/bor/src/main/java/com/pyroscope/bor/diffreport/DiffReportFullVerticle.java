package com.pyroscope.bor.diffreport;

import com.pyroscope.bor.AbstractFunctionVerticle;
import com.pyroscope.bor.SorClient;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;

import java.time.Instant;
import java.time.ZoneId;
import java.time.format.DateTimeFormatter;
import java.util.*;
import java.util.stream.Collectors;

import static com.pyroscope.bor.diffreport.DiffComputation.*;

public class DiffReportFullVerticle extends AbstractFunctionVerticle {

    private final String profileDataUrl;
    private final String baselineUrl;
    private final String historyUrl;
    private SorClient sor;

    public DiffReportFullVerticle(String profileDataUrl, String baselineUrl,
                                  String historyUrl, int port) {
        super(port);
        this.profileDataUrl = profileDataUrl;
        this.baselineUrl = baselineUrl;
        this.historyUrl = historyUrl;
    }

    @Override
    protected void initFunction() {
        sor = new SorClient(vertx, profileDataUrl, baselineUrl, historyUrl, null);
        router.get("/diff/:appName").handler(this::handleDiff);
    }

    private void handleDiff(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        long now = Instant.now().getEpochSecond();
        long to = paramLong(ctx, "to", now);
        long from = paramLong(ctx, "from", to - 3600);
        long baselineTo = paramLong(ctx, "baselineTo", from);
        long baselineFrom = paramLong(ctx, "baselineFrom", baselineTo - 3600);
        String type = paramStr(ctx, "type", "cpu");
        int limit = paramInt(ctx, "limit", 20);
        String format = paramStr(ctx, "format", "json");

        var diffFuture = sor.getProfileDiff(appName, type, baselineFrom, baselineTo, from, to, 500);
        var baselinesFuture = sor.getBaselines(appName, type);

        diffFuture.onSuccess(diffData -> baselinesFuture.onComplete(blAr -> {
            Map<String, Double> thresholds = new HashMap<>();
            if (blAr.succeeded()) {
                JsonArray baselines = blAr.result().getJsonArray("baselines", new JsonArray());
                for (int i = 0; i < baselines.size(); i++) {
                    JsonObject b = baselines.getJsonObject(i);
                    thresholds.put(b.getString("functionName"), b.getDouble("maxSelfPercent"));
                }
            }

            JsonArray baselineFns = diffData.getJsonObject("baseline")
                    .getJsonArray("functions");
            JsonArray currentFns = diffData.getJsonObject("current")
                    .getJsonArray("functions");

            Map<String, Double> baselineMap = toPercentMap(baselineFns);
            Map<String, Double> currentMap = toPercentMap(currentFns);

            List<DiffEntry> diffs = computeDeltasWithThresholds(baselineMap, currentMap, thresholds, limit);

            List<DiffEntry> regressions = diffs.stream()
                    .filter(d -> d.delta() > 0).collect(Collectors.toList());
            List<DiffEntry> improvements = diffs.stream()
                    .filter(d -> d.delta() < 0).collect(Collectors.toList());

            long thresholdBreaches = regressions.stream()
                    .filter(d -> d.threshold() != null && d.currentPercent() > d.threshold())
                    .count();

            if ("markdown".equals(format)) {
                ctx.response()
                        .putHeader("content-type", "text/markdown")
                        .end(formatMarkdown(appName, type,
                                baselineFrom, baselineTo, from, to,
                                regressions, improvements));
            } else {
                ctx.response()
                        .putHeader("content-type", "application/json")
                        .end(new JsonObject()
                                .put("appName", appName)
                                .put("profileType", type)
                                .put("baseline", new JsonObject()
                                        .put("from", baselineFrom)
                                        .put("to", baselineTo))
                                .put("current", new JsonObject()
                                        .put("from", from).put("to", to))
                                .put("regressions", toJsonArray(regressions))
                                .put("improvements", toJsonArray(improvements))
                                .put("summary", new JsonObject()
                                        .put("regressionsCount", regressions.size())
                                        .put("improvementsCount", improvements.size())
                                        .put("thresholdBreaches", thresholdBreaches)
                                        .put("topRegression",
                                                regressions.isEmpty() ? null
                                                        : regressions.get(0).name()
                                                        + " (+" + round(regressions.get(0).delta()) + "%)"))
                                .encodePrettily());
            }

            sor.saveHistory(new JsonObject()
                    .put("appName", appName)
                    .put("profileTypes", type)
                    .put("diagnosis", regressions.isEmpty() ? "no_regressions"
                            : "regressions_detected")
                    .put("severity", thresholdBreaches > 0 ? "high"
                            : regressions.isEmpty() ? "low" : "medium")
                    .put("recommendation", regressions.isEmpty()
                            ? "No regressions detected in deployment diff"
                            : regressions.size() + " regressions, "
                            + thresholdBreaches + " threshold breaches"));
        })).onFailure(err -> ctx.response().setStatusCode(502)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", err.getMessage())
                        .encodePrettily()));
    }

    private JsonArray toJsonArray(List<DiffEntry> entries) {
        JsonArray arr = new JsonArray();
        for (var e : entries) {
            JsonObject obj = new JsonObject()
                    .put("function", e.name())
                    .put("baselinePercent", round(e.baselinePercent()))
                    .put("currentPercent", round(e.currentPercent()))
                    .put("deltaPercent", round(e.delta()));
            if (e.threshold() != null) {
                obj.put("approvedThreshold", round(e.threshold()));
                obj.put("exceedsThreshold", e.currentPercent() > e.threshold());
            }
            arr.add(obj);
        }
        return arr;
    }

    private String formatMarkdown(String appName, String type,
                                  long baselineFrom, long baselineTo,
                                  long currentFrom, long currentTo,
                                  List<DiffEntry> regressions,
                                  List<DiffEntry> improvements) {
        DateTimeFormatter fmt = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm")
                .withZone(ZoneId.systemDefault());
        StringBuilder sb = new StringBuilder();
        sb.append("# Diff Report: ").append(appName).append("\n\n");
        sb.append("**Profile**: ").append(type).append("\n");
        sb.append("**Baseline**: ").append(fmt.format(Instant.ofEpochSecond(baselineFrom)))
                .append(" - ").append(fmt.format(Instant.ofEpochSecond(baselineTo))).append("\n");
        sb.append("**Current**: ").append(fmt.format(Instant.ofEpochSecond(currentFrom)))
                .append(" - ").append(fmt.format(Instant.ofEpochSecond(currentTo))).append("\n\n");

        if (!regressions.isEmpty()) {
            sb.append("## Regressions\n\n");
            sb.append("| Function | Baseline | Current | Change | Threshold |\n");
            sb.append("|----------|----------|---------|--------|----------|\n");
            for (var r : regressions) {
                sb.append("| ").append(shortName(r.name()))
                        .append(" | ").append(round(r.baselinePercent())).append("%")
                        .append(" | ").append(round(r.currentPercent())).append("%")
                        .append(" | +").append(round(r.delta())).append("%")
                        .append(" | ").append(r.threshold() != null
                                ? round(r.threshold()) + "%" + (r.currentPercent() > r.threshold() ? " BREACH" : "")
                                : "\u2014")
                        .append(" |\n");
            }
            sb.append("\n");
        }
        if (!improvements.isEmpty()) {
            sb.append("## Improvements\n\n");
            sb.append("| Function | Baseline | Current | Change |\n");
            sb.append("|----------|----------|---------|--------|\n");
            for (var imp : improvements) {
                sb.append("| ").append(shortName(imp.name()))
                        .append(" | ").append(round(imp.baselinePercent())).append("%")
                        .append(" | ").append(round(imp.currentPercent())).append("%")
                        .append(" | ").append(round(imp.delta())).append("% |\n");
            }
            sb.append("\n");
        }
        sb.append("## Summary\n\n");
        sb.append("- ").append(regressions.size()).append(" regressions\n");
        sb.append("- ").append(improvements.size()).append(" improvements\n");
        long breaches = regressions.stream()
                .filter(d -> d.threshold() != null && d.currentPercent() > d.threshold()).count();
        if (breaches > 0) {
            sb.append("- ").append(breaches).append(" threshold breaches\n");
        }
        if (!regressions.isEmpty()) {
            sb.append("- Top regression: `").append(shortName(regressions.get(0).name()))
                    .append("` (+").append(round(regressions.get(0).delta())).append("%)\n");
        }
        return sb.toString();
    }

}
