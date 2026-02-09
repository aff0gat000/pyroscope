package com.pyroscope.bor.diffreport;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.*;

class DiffComputationTest {

    @Test
    void toPercentMap_extractsFunctionPercents() {
        var fns = new JsonArray()
                .add(new JsonObject().put("name", "foo").put("selfPercent", 10.5))
                .add(new JsonObject().put("name", "bar").put("selfPercent", 5.2));
        var map = DiffComputation.toPercentMap(fns);
        assertThat(map).containsEntry("foo", 10.5).containsEntry("bar", 5.2);
    }

    @Test
    void computeDeltas_currentMinusBaseline() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("foo", 10.0);
        Map<String, Double> current = new HashMap<>();
        current.put("foo", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).delta()).isEqualTo(5.0);
    }

    @Test
    void computeDeltas_filtersBelow0Point1() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("foo", 10.0);
        baseline.put("bar", 10.05);
        Map<String, Double> current = new HashMap<>();
        current.put("foo", 10.05);
        current.put("bar", 10.1);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).isEmpty();
    }

    @Test
    void computeDeltas_sortsByAbsDescending() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("small", 10.0);
        baseline.put("big", 10.0);
        Map<String, Double> current = new HashMap<>();
        current.put("small", 10.5);
        current.put("big", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result.get(0).name()).isEqualTo("big");
        assertThat(result.get(1).name()).isEqualTo("small");
    }

    @Test
    void computeDeltas_respectsLimit() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("a", 1.0);
        baseline.put("b", 2.0);
        baseline.put("c", 3.0);
        Map<String, Double> current = new HashMap<>();
        current.put("a", 5.0);
        current.put("b", 6.0);
        current.put("c", 7.0);
        var result = DiffComputation.computeDeltas(baseline, current, 2);
        assertThat(result).hasSize(2);
    }

    @Test
    void computeDeltas_regressions_positiveDeltaOnly() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("foo", 10.0);
        Map<String, Double> current = new HashMap<>();
        current.put("foo", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).allMatch(d -> d.delta() > 0);
    }

    @Test
    void computeDeltas_improvements_negativeDeltaOnly() {
        Map<String, Double> baseline = new HashMap<>();
        baseline.put("foo", 15.0);
        Map<String, Double> current = new HashMap<>();
        current.put("foo", 10.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).allMatch(d -> d.delta() < 0);
    }

    @Test
    void shortName_fullyQualified_returnsLastTwoSegments() {
        assertThat(DiffComputation.shortName("com.example.service.MyClass.method"))
                .isEqualTo("MyClass.method");
    }

    @Test
    void shortName_noDots_returnsFullName() {
        assertThat(DiffComputation.shortName("main")).isEqualTo("main");
    }

    @Test
    void round_roundsToTwoDecimalPlaces() {
        assertThat(DiffComputation.round(3.14159)).isEqualTo(3.14);
        assertThat(DiffComputation.round(2.005)).isEqualTo(2.01);
        assertThat(DiffComputation.round(10.0)).isEqualTo(10.0);
    }
}
