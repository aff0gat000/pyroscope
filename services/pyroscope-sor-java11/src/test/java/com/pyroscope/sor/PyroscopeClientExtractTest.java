package com.pyroscope.sor;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;

class PyroscopeClientExtractTest {

    @Test
    void extractTopFunctions_singleLevel_singleFunction() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("foo"),
                new JsonArray().add(new JsonArray().add(0).add(100).add(0).add(0)
                        .add(0).add(80).add(80).add(1)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).name()).isEqualTo("foo");
        assertThat(result.get(0).selfSamples()).isEqualTo(80);
    }

    @Test
    void extractTopFunctions_multipleLevel_aggregatesSelf() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("foo"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(100).add(0).add(0))
                        .add(new JsonArray().add(0).add(50).add(30).add(1)
                                .add(50).add(50).add(20).add(1)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).selfSamples()).isEqualTo(50);
    }

    @Test
    void extractTopFunctions_sortsBySelfDescending() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("low").add("high"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(100).add(0).add(0))
                        .add(new JsonArray().add(0).add(30).add(10).add(1)
                                .add(30).add(70).add(70).add(2)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).hasSize(2);
        assertThat(result.get(0).name()).isEqualTo("high");
    }

    @Test
    void extractTopFunctions_respectsLimit() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("a").add("b").add("c"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(100).add(0).add(0))
                        .add(new JsonArray().add(0).add(30).add(30).add(1)
                                .add(30).add(40).add(40).add(2)
                                .add(70).add(30).add(20).add(3)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 2);
        assertThat(result).hasSize(2);
    }

    @Test
    void extractTopFunctions_filtersZeroSelf() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("noself").add("hasself"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(100).add(0).add(0))
                        .add(new JsonArray().add(0).add(50).add(0).add(1)
                                .add(50).add(50).add(50).add(2)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).name()).isEqualTo("hasself");
    }

    @Test
    void extractTopFunctions_calculatesPercentCorrectly() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("foo"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(200).add(0).add(0))
                        .add(new JsonArray().add(0).add(200).add(50).add(1)),
                200L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result.get(0).selfPercent()).isEqualTo(25.0);
    }

    @Test
    void extractTopFunctions_sameFunctionAcrossLevels_merges() {
        var response = flamebearerResponse(
                new JsonArray().add("root").add("recursive"),
                new JsonArray()
                        .add(new JsonArray().add(0).add(100).add(0).add(0))
                        .add(new JsonArray().add(0).add(100).add(10).add(1))
                        .add(new JsonArray().add(0).add(90).add(15).add(1)),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).hasSize(1);
        assertThat(result.get(0).selfSamples()).isEqualTo(25);
    }

    @Test
    void extractTopFunctions_nullFlamebearer_returnsEmpty() {
        var result = PyroscopeClient.extractTopFunctions(new JsonObject(), 10);
        assertThat(result).isEmpty();
    }

    @Test
    void extractTopFunctions_zeroNumTicks_returnsEmpty() {
        var response = flamebearerResponse(
                new JsonArray().add("root"),
                new JsonArray().add(new JsonArray().add(0).add(0).add(0).add(0)),
                0L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).isEmpty();
    }

    @Test
    void extractTopFunctions_emptyLevels_returnsEmpty() {
        var response = flamebearerResponse(
                new JsonArray().add("root"),
                new JsonArray(),
                100L
        );
        var result = PyroscopeClient.extractTopFunctions(response, 10);
        assertThat(result).isEmpty();
    }

    private static JsonObject flamebearerResponse(JsonArray names, JsonArray levels, long numTicks) {
        return new JsonObject().put("flamebearer", new JsonObject()
                .put("names", names)
                .put("levels", levels)
                .put("numTicks", numTicks));
    }
}
