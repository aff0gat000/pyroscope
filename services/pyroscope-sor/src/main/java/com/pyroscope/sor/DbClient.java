package com.pyroscope.sor;

import io.vertx.core.Future;
import io.vertx.core.Promise;
import io.vertx.core.Vertx;
import io.vertx.pgclient.PgConnectOptions;
import io.vertx.sqlclient.Pool;
import io.vertx.sqlclient.PoolOptions;
import io.vertx.sqlclient.Row;
import io.vertx.sqlclient.RowSet;
import io.vertx.sqlclient.Tuple;

import java.util.function.Supplier;

/**
 * Shared database client for all SOR services.
 *
 * <p>Manages the PostgreSQL connection pool and provides retry logic
 * with exponential backoff for transient failures.
 *
 * <p>Configuration via environment variables:
 * <ul>
 *   <li>{@code DB_HOST} — PostgreSQL host (default: localhost)</li>
 *   <li>{@code DB_PORT} — PostgreSQL port (default: 5432)</li>
 *   <li>{@code DB_NAME} — database name (default: pyroscope)</li>
 *   <li>{@code DB_USER} — database user (default: pyroscope)</li>
 *   <li>{@code DB_PASSWORD} — database password (default: pyroscope)</li>
 *   <li>{@code DB_POOL_SIZE} — connection pool size (default: 5)</li>
 * </ul>
 */
public class DbClient {

    private final Pool pool;
    private final Vertx vertx;

    public DbClient(Vertx vertx) {
        this.vertx = vertx;

        PgConnectOptions connectOptions = new PgConnectOptions()
                .setHost(env("DB_HOST", "localhost"))
                .setPort(Integer.parseInt(env("DB_PORT", "5432")))
                .setDatabase(env("DB_NAME", "pyroscope"))
                .setUser(env("DB_USER", "pyroscope"))
                .setPassword(env("DB_PASSWORD", "pyroscope"))
                .setReconnectAttempts(3)
                .setReconnectInterval(1000);

        PoolOptions poolOptions = new PoolOptions()
                .setMaxSize(Integer.parseInt(env("DB_POOL_SIZE", "5")));

        this.pool = Pool.pool(vertx, connectOptions, poolOptions);
    }

    public DbClient(Vertx vertx, PgConnectOptions connectOptions, int poolSize) {
        this.vertx = vertx;
        PoolOptions poolOptions = new PoolOptions().setMaxSize(poolSize);
        this.pool = Pool.pool(vertx, connectOptions, poolOptions);
    }

    public Pool pool() {
        return pool;
    }

    /**
     * Execute a query with retry and exponential backoff.
     */
    public Future<RowSet<Row>> queryWithRetry(String sql, Tuple params, int maxRetries) {
        return withRetry(() -> pool.preparedQuery(sql).execute(params), maxRetries, 100);
    }

    /**
     * Execute a query with retry (no parameters).
     */
    public Future<RowSet<Row>> queryWithRetry(String sql, int maxRetries) {
        return withRetry(() -> pool.query(sql).execute(), maxRetries, 100);
    }

    private <T> Future<T> withRetry(Supplier<Future<T>> operation,
                                    int remaining, long delayMs) {
        return operation.get().recover(err -> {
            if (remaining <= 0) return Future.failedFuture(err);
            Promise<T> promise = Promise.promise();
            vertx.setTimer(delayMs, id ->
                    withRetry(operation, remaining - 1, Math.min(delayMs * 2, 5000))
                            .onComplete(promise));
            return promise.future();
        });
    }

    private static String env(String key, String defaultValue) {
        String val = System.getenv(key);
        return val != null && !val.isBlank() ? val : defaultValue;
    }
}
