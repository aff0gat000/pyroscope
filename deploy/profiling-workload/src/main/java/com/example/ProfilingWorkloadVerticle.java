package com.example;

import io.vertx.core.AbstractVerticle;
import io.vertx.core.Vertx;

import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Random;
import java.util.concurrent.locks.ReentrantLock;

/**
 * Pyroscope profiling workload — generates CPU, allocation, and lock contention
 * workloads on a loop so profiles appear in the Pyroscope UI without any external
 * invocation or network changes.
 *
 * Workloads run on Vert.x periodic timers:
 *   - CPU:        SHA-256 hashing every 2 seconds
 *   - Allocation: list creation and sorting every 3 seconds
 *   - Lock:       contended lock across 4 threads every 5 seconds
 */
public class ProfilingWorkloadVerticle extends AbstractVerticle {

    private static final Random RANDOM = new Random();
    private static final ReentrantLock SHARED_LOCK = new ReentrantLock();

    @Override
    public void start() {
        System.out.println("Profiling workload started — generating profiling data");
        System.out.println("  CPU work:        every 2s (SHA-256 hashing)");
        System.out.println("  Allocation work: every 3s (list sort)");
        System.out.println("  Lock contention: every 5s (4 competing threads)");

        // CPU-bound work — hashing
        vertx.setPeriodic(2000, id -> cpuWork());

        // Allocation-heavy work — create and sort large lists
        vertx.setPeriodic(3000, id -> allocationWork());

        // Lock contention — multiple threads competing for same lock
        vertx.setPeriodic(5000, id -> lockContentionWork());
    }

    /**
     * CPU-bound: hash random data with SHA-256 in a tight loop.
     * Produces a visible hotspot in the CPU flame graph.
     */
    private void cpuWork() {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] data = new byte[1024];
            for (int i = 0; i < 5000; i++) {
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
     * Allocation-heavy: create large lists, populate with random integers, sort.
     * Produces hotspots in the allocation flame graph.
     */
    private void allocationWork() {
        List<Integer> list = new ArrayList<>(50000);
        for (int i = 0; i < 50000; i++) {
            list.add(RANDOM.nextInt());
        }
        Collections.sort(list);

        // Create short-lived string objects to add GC pressure
        List<String> strings = new ArrayList<>(10000);
        for (int i = 0; i < 10000; i++) {
            strings.add("item-" + RANDOM.nextInt(100000) + "-" + System.nanoTime());
        }
    }

    /**
     * Lock contention: 4 threads compete for the same lock, each doing work
     * while holding it. Produces hotspots in the lock/mutex flame graph.
     */
    private void lockContentionWork() {
        for (int t = 0; t < 4; t++) {
            new Thread(() -> {
                for (int i = 0; i < 50; i++) {
                    SHARED_LOCK.lock();
                    try {
                        // Hold the lock while doing a small amount of work
                        double result = 0;
                        for (int j = 0; j < 1000; j++) {
                            result += Math.sin(j) * Math.cos(j);
                        }
                    } finally {
                        SHARED_LOCK.unlock();
                    }
                }
            }, "lock-contention-" + t).start();
        }
    }

    public static void main(String[] args) {
        Vertx vertx = Vertx.vertx();
        vertx.deployVerticle(new ProfilingWorkloadVerticle());
    }
}
