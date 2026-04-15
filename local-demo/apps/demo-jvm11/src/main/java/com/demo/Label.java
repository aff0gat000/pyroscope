package com.demo;

import io.pyroscope.labels.LabelsSet;
import io.pyroscope.labels.Pyroscope;

/**
 * Small wrapper around Pyroscope dynamic labels so the integration-hotspots
 * dashboard can filter flame graphs by integration=redis|postgres|kafka|...
 */
public final class Label {
    private Label() {}

    public static <T> T tag(String integration, java.util.concurrent.Callable<T> fn) {
        try {
            final Object[] out = new Object[1];
            final Exception[] err = new Exception[1];
            Pyroscope.LabelsWrapper.run(new LabelsSet("integration", integration), () -> {
                try { out[0] = fn.call(); } catch (Exception e) { err[0] = e; }
            });
            if (err[0] != null) throw err[0];
            @SuppressWarnings("unchecked") T t = (T) out[0];
            return t;
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    public static void tag(String integration, Runnable fn) {
        Pyroscope.LabelsWrapper.run(new LabelsSet("integration", integration), fn);
    }
}
