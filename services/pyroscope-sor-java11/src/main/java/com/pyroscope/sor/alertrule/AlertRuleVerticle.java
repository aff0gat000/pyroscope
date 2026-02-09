package com.pyroscope.sor.alertrule;

import com.pyroscope.sor.AbstractFunctionVerticle;
import com.pyroscope.sor.DbClient;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

public class AlertRuleVerticle extends AbstractFunctionVerticle {

    private DbClient db;

    public AlertRuleVerticle(int port) {
        super(port);
    }

    @Override
    protected void initFunction() {
        db = new DbClient(vertx);
        router.post("/rules").handler(this::create);
        router.get("/rules/active/:appName").handler(this::activeByApp);
        router.get("/rules/:id").handler(this::getById);
        router.get("/rules").handler(this::listAll);
        router.put("/rules/:id").handler(this::update);
        router.delete("/rules/:id").handler(this::delete);
    }

    private void create(RoutingContext ctx) {
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        String appName = body.getString("appName");
        String profileType = body.getString("profileType");
        Double thresholdPercent = body.getDouble("thresholdPercent");
        if (appName == null || profileType == null || thresholdPercent == null) {
            error(ctx, 400, "appName, profileType, thresholdPercent are required");
            return;
        }

        String functionPattern = body.getString("functionPattern");
        String severity = body.getString("severity", "warning");
        String notificationChannel = body.getString("notificationChannel");
        Boolean enabled = body.getBoolean("enabled", true);
        String createdBy = body.getString("createdBy");

        db.queryWithRetry(
                "INSERT INTO alert_rule" +
                "    (app_name, profile_type, function_pattern, threshold_percent," +
                "     severity, notification_channel, enabled, created_by)" +
                " VALUES ($1, $2, $3, $4, $5, $6, $7, $8)" +
                " RETURNING *",
                Tuple.of(appName, profileType, functionPattern, thresholdPercent,
                        severity, notificationChannel, enabled, createdBy),
                3
        ).onSuccess(rows -> {
            ctx.response().setStatusCode(201)
                    .putHeader("content-type", "application/json")
                    .end(rowToJson(rows.iterator().next()).encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void listAll(RoutingContext ctx) {
        String appName = ctx.request().getParam("appName");

        String sql;
        Tuple params;
        if (appName != null) {
            sql = "SELECT * FROM alert_rule WHERE app_name = $1 ORDER BY created_at DESC";
            params = Tuple.of(appName);
        } else {
            sql = "SELECT * FROM alert_rule ORDER BY app_name, created_at DESC";
            params = Tuple.tuple();
        }

        db.queryWithRetry(sql, params, 3).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("count", arr.size())
                            .put("rules", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void getById(RoutingContext ctx) {
        int id = Integer.parseInt(ctx.pathParam("id"));
        db.queryWithRetry(
                "SELECT * FROM alert_rule WHERE id = $1", Tuple.of(id), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "rule not found");
            } else {
                ctx.response().putHeader("content-type", "application/json")
                        .end(rowToJson(rows.iterator().next()).encodePrettily());
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void activeByApp(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        db.queryWithRetry(
                "SELECT * FROM alert_rule WHERE app_name = $1 AND enabled = TRUE ORDER BY profile_type",
                Tuple.of(appName), 3
        ).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("count", arr.size())
                            .put("rules", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void update(RoutingContext ctx) {
        int id = Integer.parseInt(ctx.pathParam("id"));
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        StringBuilder sql = new StringBuilder("UPDATE alert_rule SET updated_at = NOW()");
        var params = new java.util.ArrayList<>();
        int idx = 1;

        Double threshold = body.getDouble("thresholdPercent");
        String severity = body.getString("severity");
        String functionPattern = body.getString("functionPattern");
        String notificationChannel = body.getString("notificationChannel");
        Boolean enabled = body.getBoolean("enabled");

        if (threshold != null) { sql.append(", threshold_percent = $").append(idx++); params.add(threshold); }
        if (severity != null) { sql.append(", severity = $").append(idx++); params.add(severity); }
        if (functionPattern != null) { sql.append(", function_pattern = $").append(idx++); params.add(functionPattern); }
        if (notificationChannel != null) { sql.append(", notification_channel = $").append(idx++); params.add(notificationChannel); }
        if (enabled != null) { sql.append(", enabled = $").append(idx++); params.add(enabled); }

        if (params.isEmpty()) { error(ctx, 400, "no fields to update"); return; }

        sql.append(" WHERE id = $").append(idx);
        params.add(id);
        sql.append(" RETURNING *");

        db.queryWithRetry(sql.toString(), Tuple.from(params), 3)
                .onSuccess(rows -> {
                    if (rows.rowCount() == 0) {
                        error(ctx, 404, "rule not found");
                    } else {
                        ctx.response().putHeader("content-type", "application/json")
                                .end(rowToJson(rows.iterator().next()).encodePrettily());
                    }
                })
                .onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void delete(RoutingContext ctx) {
        int id = Integer.parseInt(ctx.pathParam("id"));
        db.queryWithRetry(
                "DELETE FROM alert_rule WHERE id = $1", Tuple.of(id), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "rule not found");
            } else {
                ctx.response().setStatusCode(204).end();
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private JsonObject rowToJson(Row row) {
        return new JsonObject()
                .put("id", row.getInteger("id"))
                .put("appName", row.getString("app_name"))
                .put("profileType", row.getString("profile_type"))
                .put("functionPattern", row.getString("function_pattern"))
                .put("thresholdPercent", row.getDouble("threshold_percent"))
                .put("severity", row.getString("severity"))
                .put("notificationChannel", row.getString("notification_channel"))
                .put("enabled", row.getBoolean("enabled"))
                .put("createdBy", row.getString("created_by"))
                .put("createdAt", row.getLocalDateTime("created_at").toString())
                .put("updatedAt", row.getLocalDateTime("updated_at").toString());
    }

    private static void error(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encodePrettily());
    }
}
