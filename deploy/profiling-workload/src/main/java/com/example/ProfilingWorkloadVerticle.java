package com.example;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Vertx;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Pyroscope profiling workload — generates CPU, allocation, and lock contention
 * workloads on a loop so profiles appear in the Pyroscope UI without any external
 * invocation or network changes.
 *
 * Resource budget (safe for shared VMs):
 *   - CPU:    single-threaded bursts, ~5-10% of 1 core average
 *   - Memory: bounded at 128 MB heap (-Xmx128m in Dockerfile)
 *   - Disk:   zero (no file I/O)
 *   - Network: zero (no listening ports, agent push only)
 *   - Threads: fixed pool of 4 (no thread leak)
 *
 * Workloads run on Vert.x periodic timers:
 *   - CPU:        SHA-256 hashing every 2 seconds
 *   - Allocation: list creation and sorting every 3 seconds
 *   - Lock:       contended lock across 4 threads every 5 seconds
 */
public class ProfilingWorkloadVerticle extends AbstractVerticle {

    private static final Random RANDOM = new Random();
    private static final ReentrantLock SHARED_LOCK = new ReentrantLock();

    // Fixed thread pool — avoids creating new threads every 5 seconds
    private final ExecutorService lockPool = Executors.newFixedThreadPool(4, r -> {
        Thread t = new Thread(r);
        t.setDaemon(true);
        t.setName("lock-contention-" + t.getId());
        return t;
    });

    @Override
    public void start() {
        System.out.println("Profiling workload started — generating profiling data");
        System.out.println("  CPU work:        every 2s (SHA-256 hashing, 1000 iterations)");
        System.out.println("  Allocation work: every 3s (10k item list sort)");
        System.out.println("  Lock contention: every 5s (4 threads, fixed pool)");

        // CPU-bound work — hashing
        vertx.setPeriodic(2000, id -> cpuWork());

        // Allocation-heavy work — create and sort lists
        vertx.setPeriodic(3000, id -> allocationWork());

        // Lock contention — fixed thread pool competing for same lock
        vertx.setPeriodic(5000, id -> lockContentionWork());
    }

    @Override
    public void stop() {
        lockPool.shutdownNow();
    }

    /**
     * CPU-bound: hash random data with SHA-256 in a tight loop.
     * 1000 iterations per tick — enough for a visible flame graph hotspot
     * without saturating a CPU core.
     */
    private void cpuWork() {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] data = new byte[1024];
            for (int i = 0; i < 1000; i++) {
                RANDOM.nextBytes(data);
                digest.update(data);
                digest.digest();
                digest.reset();
            }
        } catch (NoSuchAlgorithmException e) {
            // SHA-256 is guaranteed to exist
        }
    }

    /**
     * Allocation-heavy: create a list, populate with random integers, sort.
     * 10,000 items per tick (~400 KB, quickly GC'd) — enough for allocation
     * flame graph visibility without spiking heap.
     */
    private void allocationWork() {
        List<Integer> list = new ArrayList<>(10000);
        for (int i = 0; i < 10000; i++) {
            list.add(RANDOM.nextInt());
        }
        Collections.sort(list);

        // Short-lived strings for GC pressure
        List<String> strings = new ArrayList<>(2000);
        for (int i = 0; i < 2000; i++) {
            strings.add("item-" + RANDOM.nextInt(10000));
        }
    }

    /**
     * Lock contention: 4 threads from a fixed pool compete for the same lock.
     * Each thread does 20 lock/unlock cycles with a small amount of work inside.
     */
    private void lockContentionWork() {
        for (int t = 0; t < 4; t++) {
            lockPool.submit(() -> {
                for (int i = 0; i < 20; i++) {
                    SHARED_LOCK.lock();
                    try {
                        double result = 0;
                        for (int j = 0; j < 500; j++) {
                            result += Math.sin(j) * Math.cos(j);
                        }
                    } finally {
                        SHARED_LOCK.unlock();
                    }
                }
            });
        }
    }

    public static void main(String[] args) {
        Vertx vertx = Vertx.vertx();
        vertx.deployVerticle(new ProfilingWorkloadVerticle());
    }
}
