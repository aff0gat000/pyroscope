package com.pyroscope.bor;

import com.pyroscope.bor.triage.TriageVerticle;
import com.pyroscope.bor.triage.TriageFullVerticle;
import com.pyroscope.bor.diffreport.DiffReportVerticle;
import com.pyroscope.bor.diffreport.DiffReportFullVerticle;
import com.pyroscope.bor.fleetsearch.FleetSearchVerticle;
import com.pyroscope.bor.fleetsearch.FleetSearchFullVerticle;
import io.vertx.core.AbstractVerticle;
import io.vertx.core.Vertx;

public class Main {

    public static void main(String[] args) {
        Vertx vertx = Vertx.vertx();
        String function = env("FUNCTION", "ReadPyroscopeTriageAssessment.v1");
        int port = Integer.parseInt(env("PORT", "8080"));

        // Standalone — calls Pyroscope directly (no SOR needed)
        String pyroscopeUrl = env("PYROSCOPE_URL", "http://localhost:4040");

        // SOR URLs — used by v1 lite and v2 full variants
        String profileDataUrl = env("PROFILE_DATA_URL", "http://localhost:8082");
        String baselineUrl = env("BASELINE_URL", null);
        String historyUrl = env("HISTORY_URL", null);
        String registryUrl = env("REGISTRY_URL", null);

        AbstractVerticle verticle;
        switch (function) {
            // Phase 1 — standalone, calls Pyroscope directly
            case "ReadPyroscopeTriageAssessment.v1":
                verticle = new TriageVerticle(pyroscopeUrl, port);
                break;

            // Phase 2 v1 — needs ReadPyroscopeProfile.sor.v1 deployed separately
            case "ReadPyroscopeDiffReport.v1":
                verticle = new DiffReportVerticle(profileDataUrl, port);
                break;
            case "ReadPyroscopeFleetSearch.v1":
                verticle = new FleetSearchVerticle(profileDataUrl, port);
                break;

            // Phase 2 v2 — also calls PostgreSQL-backed SORs
            case "ReadPyroscopeTriageAssessment.v2":
                verticle = new TriageFullVerticle(
                        profileDataUrl, baselineUrl, historyUrl, port);
                break;
            case "ReadPyroscopeDiffReport.v2":
                verticle = new DiffReportFullVerticle(
                        profileDataUrl, baselineUrl, historyUrl, port);
                break;
            case "ReadPyroscopeFleetSearch.v2":
                verticle = new FleetSearchFullVerticle(
                        profileDataUrl, registryUrl, port);
                break;

            default:
                System.err.println("Unknown FUNCTION: " + function);
                System.err.println("Phase 1: ReadPyroscopeTriageAssessment.v1");
                System.err.println("Phase 2 v1: ReadPyroscopeDiffReport.v1, ReadPyroscopeFleetSearch.v1");
                System.err.println("Phase 2 v2: ReadPyroscopeTriageAssessment.v2, ReadPyroscopeDiffReport.v2, ReadPyroscopeFleetSearch.v2");
                System.exit(1);
                verticle = null;
                break;
        }

        vertx.deployVerticle(verticle)
                .onSuccess(id -> System.out.println(function + " BOR started on port " + port))
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
