package com.pyroscope.bor.fleetsearch;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import org.junit.jupiter.api.Test;

import java.util.*;

import static org.assertj.core.api.Assertions.*;

class HotspotScorerTest {

    @Test
    void rankHotspots_scoreIsServiceCountTimesMaxPercent() {
        Map<String, List<JsonObject>> input = new HashMap<>();
        input.put("foo", List.of(
                new JsonObject().put("app", "svc1").put("selfPercent", 10.0),
                new JsonObject().put("app", "svc2").put("selfPercent", 20.0)
        ));
        var result = HotspotScorer.rankHotspots(input, 10);
        assertThat(result.size()).isEqualTo(1);
        var hotspot = result.getJsonObject(0);
        assertThat(hotspot.getDouble("impactScore")).isEqualTo(40.0); // 2 * 20.0
        assertThat(hotspot.getInteger("serviceCount")).isEqualTo(2);
        assertThat(hotspot.getDouble("maxSelfPercent")).isEqualTo(20.0);
    }

    @Test
    void rankHotspots_sortsByScoreDescending() {
        Map<String, List<JsonObject>> input = new HashMap<>();
        input.put("low", List.of(
                new JsonObject().put("app", "svc1").put("selfPercent", 5.0)
        ));
        input.put("high", List.of(
                new JsonObject().put("app", "svc1").put("selfPercent", 10.0),
                new JsonObject().put("app", "svc2").put("selfPercent", 15.0)
        ));
        var result = HotspotScorer.rankHotspots(input, 10);
        assertThat(result.getJsonObject(0).getString("function")).isEqualTo("high");
        assertThat(result.getJsonObject(1).getString("function")).isEqualTo("low");
    }

    @Test
    void rankHotspots_respectsLimit() {
        Map<String, List<JsonObject>> input = new HashMap<>();
        input.put("a", List.of(new JsonObject().put("app", "s1").put("selfPercent", 30.0)));
        input.put("b", List.of(new JsonObject().put("app", "s1").put("selfPercent", 20.0)));
        input.put("c", List.of(new JsonObject().put("app", "s1").put("selfPercent", 10.0)));
        var result = HotspotScorer.rankHotspots(input, 2);
        assertThat(result.size()).isEqualTo(2);
    }

    @Test
    void rankHotspots_emptyInput_returnsEmpty() {
        var result = HotspotScorer.rankHotspots(Map.of(), 10);
        assertThat(result.size()).isEqualTo(0);
    }
}
