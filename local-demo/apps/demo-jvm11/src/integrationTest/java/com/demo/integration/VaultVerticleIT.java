package com.demo.integration;

import com.demo.verticles.VaultVerticle;
import io.vertx.core.Vertx;
import io.vertx.junit5.VertxExtension;
import io.vertx.junit5.VertxTestContext;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.testcontainers.junit.jupiter.Testcontainers;
import org.testcontainers.vault.VaultContainer;

import static com.demo.integration.ITSupport.*;
import static org.assertj.core.api.Assertions.assertThat;

@Testcontainers(disabledWithoutDocker = true)
@ExtendWith(VertxExtension.class)
class VaultVerticleIT {

    static final VaultContainer<?> vault =
        new VaultContainer<>("hashicorp/vault:1.17")
            .withVaultToken("root")
            .withInitCommand("kv put secret/demo value=integration");

    @BeforeAll
    static void up() {
        vault.start();
        System.setProperty("VAULT_ADDR", "http://" + vault.getHost() + ":" + vault.getMappedPort(8200));
        System.setProperty("VAULT_TOKEN", "root");
    }

    @AfterAll
    static void down() {
        System.clearProperty("VAULT_ADDR");
        System.clearProperty("VAULT_TOKEN");
        vault.stop();
    }

    @Test
    void read_returns_secret(Vertx vertx, VertxTestContext ctx) throws Throwable {
        deployAndServe(vertx, VaultVerticle::new)
            .compose(port -> get(vertx, port, "/vault/read?path=secret/data/demo"))
            .onComplete(ctx.succeeding(resp -> {
                ctx.verify(() -> assertThat(resp.statusCode()).isEqualTo(200));
                ctx.completeNow();
            }));
        await(ctx);
    }
}
