package com.pyroscope.sor.baseline;

import com.pyroscope.sor.AbstractFunctionVerticle;
import com.pyroscope.sor.DbClient;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

public class BaselineVerticle extends AbstractFunctionVerticle {

    private DbClient db;

    public BaselineVerticle(int port) {
        super(port);
    }

    @Override
    protected void initFunction() {
        db = new DbClient(vertx);
        router.post("/baselines").handler(this::create);
        router.get("/baselines/:appName").handler(this::listByApp);
        router.get("/baselines/:appName/:type").handler(this::listByAppAndType);
        router.put("/baselines/:id").handler(this::update);
        router.delete("/baselines/:id").handler(this::delete);
    }

    private void create(RoutingContext ctx) {
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        String appName = body.getString("appName");
        String profileType = body.getString("profileType");
        String functionName = body.getString("functionName");
        Double maxSelfPercent = body.getDouble("maxSelfPercent");
        if (appName == null || profileType == null || functionName == null || maxSelfPercent == null) {
            error(ctx, 400, "appName, profileType, functionName, maxSelfPercent are required");
            return;
        }

        String severity = body.getString("severity", "warning");
        String createdBy = body.getString("createdBy");

        db.queryWithRetry(
                "INSERT INTO performance_baseline" +
                "    (app_name, profile_type, function_name, max_self_percent, severity, created_by)" +
                " VALUES ($1, $2, $3, $4, $5, $6)" +
                " ON CONFLICT (app_name, profile_type, function_name)" +
                " DO UPDATE SET max_self_percent = $4, severity = $5, updated_at = NOW()" +
                " RETURNING id, created_at, updated_at",
                Tuple.of(appName, profileType, functionName, maxSelfPercent, severity, createdBy),
                3
        ).onSuccess(rows -> {
            Row row = rows.iterator().next();
            ctx.response().setStatusCode(201)
                    .putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("id", row.getInteger("id"))
                            .put("appName", appName)
                            .put("profileType", profileType)
                            .put("functionName", functionName)
                            .put("maxSelfPercent", maxSelfPercent)
                            .put("severity", severity)
                            .put("createdAt", row.getLocalDateTime("created_at").toString())
                            .put("updatedAt", row.getLocalDateTime("updated_at").toString())
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void listByApp(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        db.queryWithRetry(
                "SELECT * FROM performance_baseline WHERE app_name = $1 ORDER BY profile_type, function_name",
                Tuple.of(appName), 3
        ).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("baselines", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void listByAppAndType(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        String type = ctx.pathParam("type");
        db.queryWithRetry(
                "SELECT * FROM performance_baseline WHERE app_name = $1 AND profile_type = $2 ORDER BY function_name",
                Tuple.of(appName, type), 3
        ).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("appName", appName)
                            .put("profileType", type)
                            .put("baselines", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void update(RoutingContext ctx) {
        int id = Integer.parseInt(ctx.pathParam("id"));
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        Double maxSelfPercent = body.getDouble("maxSelfPercent");
        String severity = body.getString("severity");
        if (maxSelfPercent == null && severity == null) {
            error(ctx, 400, "at least one of maxSelfPercent or severity is required");
            return;
        }

        StringBuilder sql = new StringBuilder("UPDATE performance_baseline SET updated_at = NOW()");
        var params = new java.util.ArrayList<>();
        int idx = 1;
        if (maxSelfPercent != null) {
            sql.append(", max_self_percent = $").append(idx++);
            params.add(maxSelfPercent);
        }
        if (severity != null) {
            sql.append(", severity = $").append(idx++);
            params.add(severity);
        }
        sql.append(" WHERE id = $").append(idx);
        params.add(id);
        sql.append(" RETURNING *");

        db.queryWithRetry(sql.toString(), Tuple.from(params), 3)
                .onSuccess(rows -> {
                    if (rows.rowCount() == 0) {
                        error(ctx, 404, "baseline not found");
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
                "DELETE FROM performance_baseline WHERE id = $1", Tuple.of(id), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "baseline not found");
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
                .put("functionName", row.getString("function_name"))
                .put("maxSelfPercent", row.getDouble("max_self_percent"))
                .put("severity", row.getString("severity"))
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
