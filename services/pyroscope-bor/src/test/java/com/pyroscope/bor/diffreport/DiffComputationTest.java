package com.pyroscope.bor.diffreport;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import org.junit.jupiter.api.Test;

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
        var baseline = Map.of("foo", 10.0);
        var current = Map.of("foo", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).delta()).isEqualTo(5.0);
    }

    @Test
    void computeDeltas_filtersBelow0Point1() {
        var baseline = Map.of("foo", 10.0, "bar", 10.05);
        var current = Map.of("foo", 10.05, "bar", 10.1);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        // foo: delta=0.05 (filtered), bar: delta=0.05 (filtered)
        assertThat(result).isEmpty();
    }

    @Test
    void computeDeltas_sortsByAbsDescending() {
        var baseline = Map.of("small", 10.0, "big", 10.0);
        var current = Map.of("small", 10.5, "big", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result.get(0).name()).isEqualTo("big");
        assertThat(result.get(1).name()).isEqualTo("small");
    }

    @Test
    void computeDeltas_respectsLimit() {
        var baseline = Map.of("a", 1.0, "b", 2.0, "c", 3.0);
        var current = Map.of("a", 5.0, "b", 6.0, "c", 7.0);
        var result = DiffComputation.computeDeltas(baseline, current, 2);
        assertThat(result).hasSize(2);
    }

    @Test
    void computeDeltas_regressions_positiveDeltaOnly() {
        var baseline = Map.of("foo", 10.0);
        var current = Map.of("foo", 15.0);
        var result = DiffComputation.computeDeltas(baseline, current, 100);
        assertThat(result).allMatch(d -> d.delta() > 0);
    }

    @Test
    void computeDeltas_improvements_negativeDeltaOnly() {
        var baseline = Map.of("foo", 15.0);
        var current = Map.of("foo", 10.0);
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
