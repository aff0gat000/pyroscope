package com.demo.verticles;

import com.demo.Env;
import com.demo.Label;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Promise;
import io.vertx.ext.web.Router;
import io.vertx.ext.web.RoutingContext;
import io.vertx.ext.web.client.WebClient;

public class VaultVerticle extends AbstractVerticle {
    private final Router router;
    private WebClient client;
    private String token;
    private String addr;
    public VaultVerticle(Router router) { this.router = router; }

    @Override public void start(Promise<Void> p) {
        client = WebClient.create(vertx);
        addr = Env.get("VAULT_ADDR", "http://vault:8200");
        token = Env.get("VAULT_TOKEN", "root");
        router.get("/vault/read").handler(this::read);
        p.complete();
    }

    private void read(RoutingContext ctx) {
        String path = ctx.request().getParam("path", "secret/data/demo");
        java.net.URI u = java.net.URI.create(addr);
        Label.tag("vault", () -> client.get(u.getPort() == -1 ? 8200 : u.getPort(), u.getHost(), "/v1/" + path)
            .putHeader("X-Vault-Token", token)
            .send(ar -> {
                if (ar.succeeded()) ctx.json(ar.result().bodyAsJsonObject() == null ? new io.vertx.core.json.JsonObject() : ar.result().bodyAsJsonObject());
                else ctx.response().setStatusCode(502).end(ar.cause().getMessage());
            }));
    }
}
