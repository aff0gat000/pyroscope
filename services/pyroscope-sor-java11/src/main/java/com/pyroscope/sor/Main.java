package com.pyroscope.sor;

import com.pyroscope.sor.baseline.BaselineVerticle;
import com.pyroscope.sor.history.TriageHistoryVerticle;
import com.pyroscope.sor.profiledata.ProfileDataVerticle;
import com.pyroscope.sor.registry.ServiceRegistryVerticle;
import com.pyroscope.sor.alertrule.AlertRuleVerticle;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Vertx;

public class Main {

    public static void main(String[] args) {
        Vertx vertx = Vertx.vertx();
        String function = env("FUNCTION", "ReadPyroscopeProfile.sor.v1");
        int port = Integer.parseInt(env("PORT", "8082"));
        String pyroscopeUrl = env("PYROSCOPE_URL", "http://localhost:4040");

        AbstractVerticle verticle;
        switch (function) {
            case "ReadPyroscopeProfile.sor.v1":
                verticle = new ProfileDataVerticle(pyroscopeUrl, port);
                break;
            case "ReadPyroscopeBaseline.sor.v1":
                verticle = new BaselineVerticle(port);
                break;
            case "CreatePyroscopeTriageHistory.sor.v1":
                verticle = new TriageHistoryVerticle(port);
                break;
            case "ReadPyroscopeServiceRegistry.sor.v1":
                verticle = new ServiceRegistryVerticle(port);
                break;
            case "ReadPyroscopeAlertRule.sor.v1":
                verticle = new AlertRuleVerticle(port);
                break;
            default:
                System.err.println("Unknown FUNCTION: " + function);
                System.err.println("Valid: ReadPyroscopeProfile.sor.v1, ReadPyroscopeBaseline.sor.v1, "
                        + "CreatePyroscopeTriageHistory.sor.v1, ReadPyroscopeServiceRegistry.sor.v1, "
                        + "ReadPyroscopeAlertRule.sor.v1");
                System.exit(1);
                verticle = null;
                break;
        }

        vertx.deployVerticle(verticle)
                .onSuccess(id -> System.out.println(function + " SOR started on port " + port))
                .onFailure(err -> {
                    System.err.println("Failed to start: " + err.getMessage());
                    System.exit(1);
                });
    }

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return val != null && !val.isBlank() ? val : defaultValue;
    }
}
