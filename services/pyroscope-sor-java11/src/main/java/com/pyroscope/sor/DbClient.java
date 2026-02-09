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

// PostgreSQL pool with exponential backoff retry.
// Config: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DB_POOL_SIZE
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

    public Future<RowSet<Row>> queryWithRetry(String sql, Tuple params, int maxRetries) {
        return withRetry(() -> pool.preparedQuery(sql).execute(params), maxRetries, 100);
    }

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
