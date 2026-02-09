package com.pyroscope.bor.sor;

import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.*;

class ProfileTypeTest {

    @Test
    void fromString_cpu_returnsCPU() {
        assertThat(ProfileType.fromString("cpu")).isEqualTo(ProfileType.CPU);
    }

    @Test
    void fromString_alloc_returnsALLOC() {
        assertThat(ProfileType.fromString("alloc")).isEqualTo(ProfileType.ALLOC);
    }

    @Test
    void fromString_allocation_alias_returnsALLOC() {
        assertThat(ProfileType.fromString("allocation")).isEqualTo(ProfileType.ALLOC);
    }

    @Test
    void fromString_memory_alias_returnsALLOC() {
        assertThat(ProfileType.fromString("memory")).isEqualTo(ProfileType.ALLOC);
    }

    @Test
    void fromString_lock_returnsLOCK() {
        assertThat(ProfileType.fromString("lock")).isEqualTo(ProfileType.LOCK);
    }

    @Test
    void fromString_mutex_alias_returnsLOCK() {
        assertThat(ProfileType.fromString("mutex")).isEqualTo(ProfileType.LOCK);
    }

    @Test
    void fromString_contention_alias_returnsLOCK() {
        assertThat(ProfileType.fromString("contention")).isEqualTo(ProfileType.LOCK);
    }

    @Test
    void fromString_wall_returnsWALL() {
        assertThat(ProfileType.fromString("wall")).isEqualTo(ProfileType.WALL);
    }

    @Test
    void fromString_wallclock_alias_returnsWALL() {
        assertThat(ProfileType.fromString("wallclock")).isEqualTo(ProfileType.WALL);
    }

    @Test
    void fromString_wallDash_alias_returnsWALL() {
        assertThat(ProfileType.fromString("wall-clock")).isEqualTo(ProfileType.WALL);
    }

    @Test
    void fromString_caseInsensitive() {
        assertThat(ProfileType.fromString("CPU")).isEqualTo(ProfileType.CPU);
        assertThat(ProfileType.fromString("Alloc")).isEqualTo(ProfileType.ALLOC);
        assertThat(ProfileType.fromString("WALL")).isEqualTo(ProfileType.WALL);
    }

    @Test
    void fromString_unknown_throwsIllegalArgumentException() {
        assertThatThrownBy(() -> ProfileType.fromString("unknown"))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("Unknown profile type");
    }

    @Test
    void queryFor_cpu_buildsCorrectQuery() {
        assertThat(ProfileType.CPU.queryFor("myapp")).isEqualTo("myapp.cpu{}");
    }

    @Test
    void queryFor_alloc_buildsCorrectQuery() {
        assertThat(ProfileType.ALLOC.queryFor("myapp")).isEqualTo("myapp.alloc_in_new_tlab_bytes{}");
    }

    @Test
    void queryFor_lock_buildsCorrectQuery() {
        assertThat(ProfileType.LOCK.queryFor("myapp")).isEqualTo("myapp.lock_count{}");
    }

    @Test
    void queryFor_wall_buildsCorrectQuery() {
        assertThat(ProfileType.WALL.queryFor("myapp")).isEqualTo("myapp.wall{}");
    }
}
