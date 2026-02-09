package com.pyroscope.sor.registry;

import com.pyroscope.sor.AbstractFunctionVerticle;
import com.pyroscope.sor.DbClient;
import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import io.vertx.ext.web.RoutingContext;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.Tuple;

public class ServiceRegistryVerticle extends AbstractFunctionVerticle {

    private DbClient db;

    public ServiceRegistryVerticle(int port) {
        super(port);
    }

    @Override
    protected void initFunction() {
        db = new DbClient(vertx);
        router.post("/services").handler(this::create);
        router.get("/services").handler(this::listAll);
        router.get("/services/:appName").handler(this::getByName);
        router.put("/services/:appName").handler(this::update);
        router.delete("/services/:appName").handler(this::delete);
    }

    private void create(RoutingContext ctx) {
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        String appName = body.getString("appName");
        if (appName == null) { error(ctx, 400, "appName is required"); return; }

        String teamOwner = body.getString("teamOwner");
        String tier = body.getString("tier", "standard");
        String environment = body.getString("environment");
        String notificationChannel = body.getString("notificationChannel");
        JsonObject pyroscopeLabels = body.getJsonObject("pyroscopeLabels", new JsonObject());
        JsonObject metadata = body.getJsonObject("metadata", new JsonObject());

        db.queryWithRetry(
                "INSERT INTO service_registry" +
                "    (app_name, team_owner, tier, environment, notification_channel," +
                "     pyroscope_labels, metadata)" +
                " VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7::jsonb)" +
                " ON CONFLICT (app_name)" +
                " DO UPDATE SET team_owner = COALESCE($2, service_registry.team_owner)," +
                "              tier = $3," +
                "              environment = COALESCE($4, service_registry.environment)," +
                "              notification_channel = COALESCE($5, service_registry.notification_channel)," +
                "              pyroscope_labels = $6::jsonb," +
                "              metadata = $7::jsonb," +
                "              updated_at = NOW()" +
                " RETURNING *",
                Tuple.of(appName, teamOwner, tier, environment, notificationChannel,
                        pyroscopeLabels.encode(), metadata.encode()),
                3
        ).onSuccess(rows -> {
            ctx.response().setStatusCode(201)
                    .putHeader("content-type", "application/json")
                    .end(rowToJson(rows.iterator().next()).encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void listAll(RoutingContext ctx) {
        String tier = ctx.request().getParam("tier");

        String sql;
        Tuple params;
        if (tier != null) {
            sql = "SELECT * FROM service_registry WHERE tier = $1 ORDER BY app_name";
            params = Tuple.of(tier);
        } else {
            sql = "SELECT * FROM service_registry ORDER BY app_name";
            params = Tuple.tuple();
        }

        db.queryWithRetry(sql, params, 3).onSuccess(rows -> {
            JsonArray arr = new JsonArray();
            for (Row row : rows) arr.add(rowToJson(row));
            ctx.response().putHeader("content-type", "application/json")
                    .end(new JsonObject()
                            .put("count", arr.size())
                            .put("services", arr)
                            .encodePrettily());
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void getByName(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        db.queryWithRetry(
                "SELECT * FROM service_registry WHERE app_name = $1",
                Tuple.of(appName), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "service not found: " + appName);
            } else {
                ctx.response().putHeader("content-type", "application/json")
                        .end(rowToJson(rows.iterator().next()).encodePrettily());
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void update(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        JsonObject body = ctx.body().asJsonObject();
        if (body == null) { error(ctx, 400, "JSON body required"); return; }

        String teamOwner = body.getString("teamOwner");
        String tier = body.getString("tier");
        String environment = body.getString("environment");
        String notificationChannel = body.getString("notificationChannel");
        JsonObject pyroscopeLabels = body.getJsonObject("pyroscopeLabels");
        JsonObject metadata = body.getJsonObject("metadata");

        StringBuilder sql = new StringBuilder("UPDATE service_registry SET updated_at = NOW()");
        var params = new java.util.ArrayList<>();
        int idx = 1;
        if (teamOwner != null) { sql.append(", team_owner = $").append(idx++); params.add(teamOwner); }
        if (tier != null) { sql.append(", tier = $").append(idx++); params.add(tier); }
        if (environment != null) { sql.append(", environment = $").append(idx++); params.add(environment); }
        if (notificationChannel != null) { sql.append(", notification_channel = $").append(idx++); params.add(notificationChannel); }
        if (pyroscopeLabels != null) { sql.append(", pyroscope_labels = $").append(idx).append("::jsonb"); params.add(pyroscopeLabels.encode()); idx++; }
        if (metadata != null) { sql.append(", metadata = $").append(idx).append("::jsonb"); params.add(metadata.encode()); idx++; }

        if (params.isEmpty()) { error(ctx, 400, "no fields to update"); return; }

        sql.append(" WHERE app_name = $").append(idx);
        params.add(appName);
        sql.append(" RETURNING *");

        db.queryWithRetry(sql.toString(), Tuple.from(params), 3)
                .onSuccess(rows -> {
                    if (rows.rowCount() == 0) {
                        error(ctx, 404, "service not found: " + appName);
                    } else {
                        ctx.response().putHeader("content-type", "application/json")
                                .end(rowToJson(rows.iterator().next()).encodePrettily());
                    }
                })
                .onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private void delete(RoutingContext ctx) {
        String appName = ctx.pathParam("appName");
        db.queryWithRetry(
                "DELETE FROM service_registry WHERE app_name = $1",
                Tuple.of(appName), 3
        ).onSuccess(rows -> {
            if (rows.rowCount() == 0) {
                error(ctx, 404, "service not found: " + appName);
            } else {
                ctx.response().setStatusCode(204).end();
            }
        }).onFailure(err -> error(ctx, 500, err.getMessage()));
    }

    private JsonObject rowToJson(Row row) {
        JsonObject json = new JsonObject()
                .put("appName", row.getString("app_name"))
                .put("teamOwner", row.getString("team_owner"))
                .put("tier", row.getString("tier"))
                .put("environment", row.getString("environment"))
                .put("notificationChannel", row.getString("notification_channel"))
                .put("createdAt", row.getLocalDateTime("created_at").toString())
                .put("updatedAt", row.getLocalDateTime("updated_at").toString());
        Object labels = row.getJson("pyroscope_labels");
        if (labels != null) json.put("pyroscopeLabels", labels);
        Object meta = row.getJson("metadata");
        if (meta != null) json.put("metadata", meta);
        return json;
    }

    private static void error(RoutingContext ctx, int status, String message) {
        ctx.response().setStatusCode(status)
                .putHeader("content-type", "application/json")
                .end(new JsonObject().put("error", message).encodePrettily());
    }
}
