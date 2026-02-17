package com.pyroscope.bor.triage;

import io.vertx.core.json.JsonArray;
import io.vertx.core.json.JsonObject;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.ValueSource;

import static org.assertj.core.api.Assertions.*;

class TriageRulesTest {

    @Test
    void diagnose_cpu_gcPattern_returnsGcPressure() {
        assertThat(TriageRules.diagnose("cpu", functions("java.lang.GC.collect")))
                .isEqualTo("gc_pressure");
    }

    @Test
    void diagnose_cpu_parkPattern_returnsThreadWaiting() {
        assertThat(TriageRules.diagnose("cpu", functions("sun.misc.Unsafe.park")))
                .isEqualTo("thread_waiting");
    }

    @Test
    void diagnose_cpu_synchronizedPattern_returnsLockContention() {
        assertThat(TriageRules.diagnose("cpu", functions("java.lang.synchronized.block")))
                .isEqualTo("lock_contention");
    }

    @Test
    void diagnose_cpu_compilerPattern_returnsJitOverhead() {
        assertThat(TriageRules.diagnose("cpu", functions("org.graalvm.Compiler.compile")))
                .isEqualTo("jit_overhead");
    }

    @Test
    void diagnose_cpu_noPattern_returnsCpuBound() {
        assertThat(TriageRules.diagnose("cpu", functions("com.app.BusinessService.process")))
                .isEqualTo("cpu_bound");
    }

    @Test
    void diagnose_alloc_stringBuilderPattern_returnsStringAllocation() {
        assertThat(TriageRules.diagnose("alloc", functions("java.lang.StringBuilder.append")))
                .isEqualTo("string_allocation");
    }

    @Test
    void diagnose_alloc_collectionPattern_returnsCollectionResizing() {
        assertThat(TriageRules.diagnose("alloc", functions("java.util.ArrayList.grow")))
                .isEqualTo("collection_resizing");
    }

    @Test
    void diagnose_alloc_parsePattern_returnsDeserializationOverhead() {
        assertThat(TriageRules.diagnose("alloc", functions("com.fasterxml.Jackson.deserialize")))
                .isEqualTo("deserialization_overhead");
    }

    @Test
    void diagnose_alloc_noPattern_returnsAllocationPressure() {
        assertThat(TriageRules.diagnose("alloc", functions("com.app.MyService.handle")))
                .isEqualTo("allocation_pressure");
    }

    @Test
    void diagnose_lock_alwaysReturnsLockContention() {
        assertThat(TriageRules.diagnose("lock", functions("anything")))
                .isEqualTo("lock_contention");
    }

    @Test
    void diagnose_wall_socketPattern_returnsNetworkIo() {
        assertThat(TriageRules.diagnose("wall", functions("java.net.socket.read")))
                .isEqualTo("network_io");
    }

    @Test
    void diagnose_wall_sleepPattern_returnsIdleTime() {
        assertThat(TriageRules.diagnose("wall", functions("java.lang.Thread.sleep")))
                .isEqualTo("idle_time");
    }

    @Test
    void diagnose_wall_noPattern_returnsMixedWorkload() {
        assertThat(TriageRules.diagnose("wall", functions("com.app.Service.handle")))
                .isEqualTo("mixed_workload");
    }

    @Test
    void diagnose_emptyFunctions_returnsNoData() {
        assertThat(TriageRules.diagnose("cpu", new JsonArray())).isEqualTo("no_data");
    }

    @Test
    void diagnose_matchChecksTop5Only() {
        var fns = new JsonArray();
        for (int i = 0; i < 5; i++) {
            fns.add(new JsonObject().put("name", "com.app.clean" + i).put("selfPercent", 10.0));
        }
        fns.add(new JsonObject().put("name", "java.lang.GC.collect").put("selfPercent", 5.0));
        assertThat(TriageRules.diagnose("cpu", fns)).isEqualTo("cpu_bound");
    }

    @ParameterizedTest
    @ValueSource(strings = {
            "gc_pressure", "thread_waiting", "lock_contention", "jit_overhead",
            "cpu_bound", "string_allocation", "collection_resizing",
            "deserialization_overhead", "allocation_pressure", "network_io",
            "idle_time", "mixed_workload", "unknown"
    })
    void recommend_eachDiagnosis_returnsNonEmpty(String diagnosis) {
        assertThat(TriageRules.recommend(diagnosis, "com.app.Foo.bar"))
                .isNotEmpty();
    }

    @Test
    void recommend_includesTopFunctionName() {
        String result = TriageRules.recommend("cpu_bound", "com.app.HotMethod");
        assertThat(result).contains("com.app.HotMethod");
    }

    @Test
    void recommend_nullTopFunction_returnsNoDataMessage() {
        assertThat(TriageRules.recommend("cpu_bound", null))
                .isEqualTo("No profile data available for this type");
    }

    @Test
    void severity_above30_returnsHigh() {
        assertThat(TriageRules.severity(31.0)).isEqualTo("high");
    }

    @Test
    void severity_exactly30_returnsMedium() {
        assertThat(TriageRules.severity(30.0)).isEqualTo("medium");
    }

    @Test
    void severity_above10_returnsMedium() {
        assertThat(TriageRules.severity(15.0)).isEqualTo("medium");
    }

    @Test
    void severity_exactly10_returnsLow() {
        assertThat(TriageRules.severity(10.0)).isEqualTo("low");
    }

    @Test
    void severity_below10_returnsLow() {
        assertThat(TriageRules.severity(5.0)).isEqualTo("low");
    }

    @Test
    void matches_patternPresent_returnsTrue() {
        assertThat(TriageRules.matches(functions("java.lang.GC.collect"), "GC")).isTrue();
    }

    @Test
    void matches_patternAbsent_returnsFalse() {
        assertThat(TriageRules.matches(functions("com.app.Service.handle"), "GC")).isFalse();
    }

    private static JsonArray functions(String... names) {
        var arr = new JsonArray();
        for (String name : names) {
            arr.add(new JsonObject().put("name", name).put("selfPercent", 10.0));
        }
        return arr;
    }
}
