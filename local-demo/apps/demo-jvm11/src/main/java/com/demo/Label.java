package com.demo;

import io.pyroscope.labels.LabelsSet;
import io.pyroscope.labels.Pyroscope;

/**
 * Small wrapper around Pyroscope dynamic labels so the integration-hotspots
 * dashboard can filter flame graphs by integration=redis|postgres|kafka|...
 *
 * Falls back to running the lambda directly when the Pyroscope agent isn't
 * attached (e.g. unit tests, or any JVM started without -javaagent). This
 * keeps verticles testable without changing call sites.
 */
public final class Label {
    private Label() {}

    public static <T> T tag(String integration, java.util.concurrent.Callable<T> fn) {
        try {
            final Object[] out = new Object[1];
            final Exception[] err = new Exception[1];
            Runnable body = () -> {
                try { out[0] = fn.call(); } catch (Exception e) { err[0] = e; }
            };
            try {
                Pyroscope.LabelsWrapper.run(new LabelsSet("integration", integration), body);
            } catch (Throwable t) {
                body.run();   // agent not attached or labels API unavailable
            }
            if (err[0] != null) throw err[0];
            @SuppressWarnings("unchecked") T t = (T) out[0];
            return t;
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    public static void tag(String integration, Runnable fn) {
        try {
            Pyroscope.LabelsWrapper.run(new LabelsSet("integration", integration), fn);
        } catch (Throwable t) {
            fn.run();   // agent not attached or labels API unavailable
        }
    }
}
