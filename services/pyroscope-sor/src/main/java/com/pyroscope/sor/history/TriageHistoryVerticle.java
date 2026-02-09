package com.pyroscope.sor.history;

import com.pyroscope.sor.AbstractFunctionVerticle;
import com.pyroscope.sor.DbClient;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

import java.time.Instant;
import java.time.LocalDateTime;
import java.time.ZoneOffset;

public class TriageHistoryVerticle extends AbstractFunctionVerticle {

    private DbClient db;

    public TriageHistoryVerticle(int port) {
        super(port);
    }

    @Override
    protected void initFunction() {
        db = new DbClient(vertx);
        router.post("/history").handler(this::create);
        router.get("/history/:appName").handler(this::listByApp);
        router.get("/history/:appName/latest").handler(this::latest);
        router.delete("/history/:id").handler(this::delete);
    }

    private void create(RoutingContext ctx) {
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        String appName = body.getString("appName");
        String profileTypes = body.getString("profileTypes");
        String diagnosis = body.getString("diagnosis");
        String severity = body.getString("severity");
        if (appName == null || diagnosis == null || severity == null) {
            error(ctx, 400, "appName, diagnosis, severity are required");
            return;
        }

        JsonObject topFunctions = body.getJsonObject("topFunctions");
        String recommendation = body.getString("recommendation");
        String requestedBy = body.getString("requestedBy");

        db.queryWithRetry("""
                INSERT INTO triage_history
                    (app_name, profile_types, diagnosis, severity, top_functions, recommendation, requested_by)
                VALUES ($1, $2, $3, $4, $5::jsonb, $6, $7)
                RETURNING id, created_at
                """,
                Tuple.of(appName,
                        profileTypes != null ? profileTypes : "cpu",
                        diagnosis, severity,
                        topFunctions != null ? topFunctions.encode() : "{}",
                        recommendation, requestedBy),
                3
        ).onSuccess(rows -> {
            Row row = rows.iterator().next();
            ctx.response().setStatusCode(201)
                    .putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("id", row.getInteger("id"))
                            .put("appName", appName)
                            .put("diagnosis", diagnosis)
                            .put("severity", severity)
                            .put("createdAt", row.getLocalDateTime("created_at").toString())
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void listByApp(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        int limit = paramInt(ctx, "limit", 50);

        String fromParam = ctx.request().getParam("from");
        String toParam = ctx.request().getParam("to");

        String sql;
        Tuple params;

        if (fromParam != null && toParam != null) {
            LocalDateTime from = LocalDateTime.ofInstant(
                    Instant.ofEpochSecond(Long.parseLong(fromParam)), ZoneOffset.UTC);
            LocalDateTime to = LocalDateTime.ofInstant(
                    Instant.ofEpochSecond(Long.parseLong(toParam)), ZoneOffset.UTC);
            sql = """
                SELECT * FROM triage_history
                WHERE app_name = $1 AND created_at BETWEEN $2 AND $3
                ORDER BY created_at DESC LIMIT $4
                """;
            params = Tuple.of(appName, from, to, limit);
        } else {
            sql = """
                SELECT * FROM triage_history
                WHERE app_name = $1
                ORDER BY created_at DESC LIMIT $2
                """;
            params = Tuple.of(appName, limit);
        }

        db.queryWithRetry(sql, params, 3).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("count", arr.size())
                            .put("history", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void latest(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        db.queryWithRetry(
                "SELECT * FROM triage_history WHERE app_name = $1 ORDER BY created_at DESC LIMIT 1",
                Tuple.of(appName), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "no triage history for " + appName);
            } else {
                ctx.response().putHeader("content-type", "application/json")
                        .end(rowToJson(rows.iterator().next()).encodePrettily());
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void delete(RoutingContext ctx) {
        int id = Integer.parseInt(ctx.pathParam("id"));
        db.queryWithRetry(
                "DELETE FROM triage_history WHERE id = $1", Tuple.of(id), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "record not found");
            } else {
                ctx.response().setStatusCode(204).end();
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private JsonObject rowToJson(Row row) {
        JsonObject json = new JsonObject()
                .put("id", row.getInteger("id"))
                .put("appName", row.getString("app_name"))
                .put("profileTypes", row.getString("profile_types"))
                .put("diagnosis", row.getString("diagnosis"))
                .put("severity", row.getString("severity"))
                .put("recommendation", row.getString("recommendation"))
                .put("requestedBy", row.getString("requested_by"))
                .put("createdAt", row.getLocalDateTime("created_at").toString());
        Object topFunctions = row.getJson("top_functions");
        if (topFunctions != null) {
            json.put("topFunctions", topFunctions);
        }
        return json;
    }

    private static int paramInt(RoutingContext ctx, String name, int defaultValue) {
        String val = ctx.request().getParam(name);
        return val != null ? Integer.parseInt(val) : defaultValue;
    }

    private static void error(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encodePrettily());
    }
}
