# Endpoint Reference

Complete reference for all service endpoints. Use these to generate specific profiling patterns for investigation in Grafana.

All endpoints accept GET requests and require no request body. Default ports are shown; actual ports are written to `.env` after deployment.

## Prerequisites

- Stack running (`bash scripts/run.sh`).
- To check assigned ports: `cat .env`.

## Service ports

| Service | Default port | Environment variable |
|---|---|---|
| API Gateway | 18080 | `API_GATEWAY_PORT` |
| Order Service | 18081 | `ORDER_SERVICE_PORT` |
| Payment Service | 18082 | `PAYMENT_SERVICE_PORT` |
| Fraud Service | 18083 | `FRAUD_SERVICE_PORT` |
| Account Service | 18084 | `ACCOUNT_SERVICE_PORT` |
| Loan Service | 18085 | `LOAN_SERVICE_PORT` |
| Notification Service | 18086 | `NOTIFICATION_SERVICE_PORT` |

## API Gateway (port 18080)

Pyroscope application name: `bank-api-gateway`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/cpu` | CPU | Recursive Fibonacci. Dominates CPU flame graph. |
| `/alloc` | Memory | Allocates 500 random-sized byte arrays. Visible in alloc profile. |
| `/slow` | I/O (sleep) | Simulates blocking I/O with `Thread.sleep`. |
| `/db` | CPU | Simulates database query by sorting strings. |
| `/mixed` | CPU + Memory | Combination of CPU and allocation work. |
| `/db/select` | CPU | Simulated SELECT with string sorting. |
| `/db/insert` | CPU + Memory | Simulated INSERT with object creation. |
| `/db/join` | CPU | Simulated JOIN with nested iteration. |
| `/json/process` | CPU | Recursive map building and manual JSON serialization. |
| `/xml/process` | CPU | Recursive XML tag construction. |
| `/csv/process` | CPU | Regex parsing and `String.split` on 50K records. |
| `/batch/process` | CPU | Email and phone regex validation on 50K records. |
| `/redis/get` | CPU (light) | Simulated Redis GET with HashMap lookup. |
| `/redis/set` | CPU (light) | Simulated Redis SET. |
| `/redis/scan` | CPU | Simulated Redis SCAN with pattern matching. |
| `/downstream/call` | I/O | Simulated HTTP client call. |
| `/downstream/fanout` | I/O | Simulated fan-out to multiple downstream services. |
| `/health` | None | Health check. Returns `OK`. |

## Order Service (port 18081)

Pyroscope application name: `bank-order-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/order/create` | CPU + Memory | Creates order objects with string concatenation. |
| `/order/list` | CPU (light) | Returns order list. |
| `/order/process` | Lock (mutex) | **Synchronized method.** Causes lock contention under load. Key scenario for mutex profiling. |
| `/order/validate` | CPU | Regex validation compiled per call. |
| `/order/aggregate` | CPU + Memory | Stream API aggregation across orders. |
| `/order/fulfill` | CPU | Multi-step order fulfillment with string building. |

## Payment Service (port 18082)

Pyroscope application name: `bank-payment-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/payment/transfer` | CPU | **SHA-256 per request.** `MessageDigest.getInstance()` lookup on every call. Key scenario for CPU profiling. |
| `/payment/fx` | CPU | Multi-hop BigDecimal currency conversion (20 iterations). |
| `/payment/orchestrate` | CPU | Multi-step payment orchestration. |
| `/payment/history` | CPU + Memory | Generates transaction history with String.format. |
| `/payment/payroll` | Lock (mutex) | **Synchronized payroll processing.** 200-500 employees processed under a single lock. |
| `/payment/reconcile` | CPU | BigDecimal arithmetic for ledger reconciliation. |

## Fraud Service (port 18083)

Pyroscope application name: `bank-fraud-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/fraud/score` | CPU | Risk scoring with weighted calculations. |
| `/fraud/scan` | CPU | **Regex rule engine.** 8 patterns matched against 10K events. Dominates CPU profile. |
| `/fraud/anomaly` | CPU + Memory | Statistical analysis (mean, stddev, percentiles) on 5000 scores with boxed `Double` sorting. |
| `/fraud/ingest` | Memory | Sliding window with HashMap allocation. |
| `/fraud/velocity` | CPU | Velocity check calculations. |
| `/fraud/report` | CPU + Memory | Report generation with aggregation. |

## Account Service (port 18084)

Pyroscope application name: `bank-account-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/account/open` | CPU (light) | Account creation. |
| `/account/balance` | CPU (light) | Balance lookup. |
| `/account/deposit` | Lock (mutex) | **Synchronized deposit.** Contention visible in mutex profile under load. |
| `/account/withdraw` | Lock (mutex) | **Synchronized withdraw.** Same contention pattern as deposit. |
| `/account/statement` | CPU + Memory | `String.format` called 100+ times for statement generation. |
| `/account/interest` | CPU | BigDecimal compound interest loop (30 days). |
| `/account/search` | CPU | Stream API `.filter().sorted().collect()` chain. |
| `/account/branch-summary` | CPU + Memory | LinkedHashMap merge operations across all accounts. |

## Loan Service (port 18085)

Pyroscope application name: `bank-loan-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/loan/apply` | CPU | Loan application with eligibility checks. |
| `/loan/amortize` | CPU | **Amortization schedule.** Up to 360 iterations of BigDecimal arithmetic. |
| `/loan/risk-sim` | CPU | **Monte Carlo simulation.** 10,000 iterations with `Math.random()`. Dominates CPU profile. |
| `/loan/portfolio` | CPU + Memory | Aggregation across 3K loans with BigDecimal totals. |
| `/loan/delinquency` | CPU | Delinquency scoring calculations. |
| `/loan/originate` | CPU | Loan origination processing. |

## Notification Service (port 18086)

Pyroscope application name: `bank-notification-service`

| Endpoint | Bottleneck type | What it exercises |
|---|---|---|
| `/notify/send` | CPU (light) | Single notification dispatch. |
| `/notify/bulk` | Memory | **Bulk message generation.** Creates 500-2000 LinkedHashMap objects. Visible in alloc profile. |
| `/notify/drain` | CPU | Drains notification queue. |
| `/notify/render` | Memory | **Template rendering with String.format.** Key scenario for allocation profiling. |
| `/notify/status` | CPU (light) | Notification status check. |
| `/notify/retry` | Lock + I/O | Exponential backoff retry with `Thread.sleep` and bit-shift loop. |

## curl examples

### Trigger specific profiling patterns

```bash
# CPU hotspot: recursive Fibonacci
curl http://localhost:18080/cpu

# Memory allocation pressure: String.format in a loop
curl http://localhost:18086/notify/render

# Lock contention: synchronized order processing
curl http://localhost:18081/order/process

# Hidden CPU overhead: MessageDigest.getInstance per request
curl http://localhost:18082/payment/transfer

# CPU-heavy computation: Monte Carlo simulation
curl http://localhost:18085/loan/risk-sim

# Regex CPU overhead: 8 patterns x 10K events
curl http://localhost:18083/fraud/scan
```

### Generate sustained load on a single endpoint

Repeated requests are needed to build up enough profiling data for clear flame graphs. Run these in a loop for at least 30 seconds.

```bash
# Sustained CPU load on API Gateway
for i in $(seq 1 100); do curl -s http://localhost:18080/cpu > /dev/null & done; wait

# Sustained lock contention on Order Service
for i in $(seq 1 100); do curl -s http://localhost:18081/order/process > /dev/null & done; wait

# Sustained allocation pressure on Notification Service
for i in $(seq 1 100); do curl -s http://localhost:18086/notify/render > /dev/null & done; wait

# Sustained load on Payment Service (sha256)
for i in $(seq 1 100); do curl -s http://localhost:18082/payment/transfer > /dev/null & done; wait
```

### Continuous load loop (similar to generate-load.sh)

```bash
# Hit a specific endpoint continuously for 60 seconds
END=$(($(date +%s) + 60))
while [ $(date +%s) -lt $END ]; do
  curl -sf -o /dev/null http://localhost:18081/order/process &
  curl -sf -o /dev/null http://localhost:18082/payment/transfer &
  wait
  sleep 0.2
done
```

### Check service health

```bash
# All services at once
for port in 18080 18081 18082 18083 18084 18085 18086; do
  printf "localhost:%-5s → %s\n" "$port" "$(curl -sf http://localhost:$port/health)"
done
```

## Postman collection

Import the following endpoints into Postman as a collection. All requests are GET with no authentication or request body.

### Collection structure

```
Pyroscope Bank Demo
├── API Gateway (localhost:18080)
│   ├── CPU Hotspot            GET http://localhost:18080/cpu
│   ├── Memory Allocation      GET http://localhost:18080/alloc
│   ├── Slow (blocking I/O)    GET http://localhost:18080/slow
│   ├── Database Sim           GET http://localhost:18080/db
│   ├── Mixed Workload         GET http://localhost:18080/mixed
│   ├── DB Select              GET http://localhost:18080/db/select
│   ├── DB Join                GET http://localhost:18080/db/join
│   ├── JSON Process           GET http://localhost:18080/json/process
│   ├── XML Process            GET http://localhost:18080/xml/process
│   ├── CSV Process            GET http://localhost:18080/csv/process
│   ├── Batch Process          GET http://localhost:18080/batch/process
│   ├── Redis Get              GET http://localhost:18080/redis/get
│   ├── Redis Set              GET http://localhost:18080/redis/set
│   ├── Downstream Fanout      GET http://localhost:18080/downstream/fanout
│   └── Health                 GET http://localhost:18080/health
│
├── Order Service (localhost:18081)
│   ├── Create Order           GET http://localhost:18081/order/create
│   ├── List Orders            GET http://localhost:18081/order/list
│   ├── Process (lock)         GET http://localhost:18081/order/process
│   ├── Validate               GET http://localhost:18081/order/validate
│   ├── Aggregate              GET http://localhost:18081/order/aggregate
│   └── Fulfill                GET http://localhost:18081/order/fulfill
│
├── Payment Service (localhost:18082)
│   ├── Transfer (sha256)      GET http://localhost:18082/payment/transfer
│   ├── FX Conversion          GET http://localhost:18082/payment/fx
│   ├── Orchestrate            GET http://localhost:18082/payment/orchestrate
│   ├── History                GET http://localhost:18082/payment/history
│   ├── Payroll (lock)         GET http://localhost:18082/payment/payroll
│   └── Reconcile              GET http://localhost:18082/payment/reconcile
│
├── Fraud Service (localhost:18083)
│   ├── Risk Score             GET http://localhost:18083/fraud/score
│   ├── Scan (regex)           GET http://localhost:18083/fraud/scan
│   ├── Anomaly Detection      GET http://localhost:18083/fraud/anomaly
│   ├── Ingest                 GET http://localhost:18083/fraud/ingest
│   ├── Velocity Check         GET http://localhost:18083/fraud/velocity
│   └── Report                 GET http://localhost:18083/fraud/report
│
├── Account Service (localhost:18084)
│   ├── Open Account           GET http://localhost:18084/account/open
│   ├── Balance                GET http://localhost:18084/account/balance
│   ├── Deposit (lock)         GET http://localhost:18084/account/deposit
│   ├── Withdraw (lock)        GET http://localhost:18084/account/withdraw
│   ├── Statement              GET http://localhost:18084/account/statement
│   ├── Interest Calc          GET http://localhost:18084/account/interest
│   ├── Search                 GET http://localhost:18084/account/search
│   └── Branch Summary         GET http://localhost:18084/account/branch-summary
│
├── Loan Service (localhost:18085)
│   ├── Apply                  GET http://localhost:18085/loan/apply
│   ├── Amortize               GET http://localhost:18085/loan/amortize
│   ├── Risk Simulation        GET http://localhost:18085/loan/risk-sim
│   ├── Portfolio              GET http://localhost:18085/loan/portfolio
│   ├── Delinquency            GET http://localhost:18085/loan/delinquency
│   └── Originate              GET http://localhost:18085/loan/originate
│
└── Notification Service (localhost:18086)
    ├── Send                   GET http://localhost:18086/notify/send
    ├── Bulk (alloc)           GET http://localhost:18086/notify/bulk
    ├── Drain                  GET http://localhost:18086/notify/drain
    ├── Render (alloc)         GET http://localhost:18086/notify/render
    ├── Status                 GET http://localhost:18086/notify/status
    └── Retry (backoff)        GET http://localhost:18086/notify/retry
```

To import into Postman:

1. Create a new collection named "Pyroscope Bank Demo".
2. Add a collection variable `baseUrl` with value `http://localhost`.
3. Create folders for each service.
4. Add GET requests using the URLs listed above.
5. Use the Postman Runner to execute an entire folder repeatedly for sustained load generation.

To generate profiling data with Postman Runner:

1. Select a folder (for example, "Order Service").
2. Set **Iterations** to 50 or more.
3. Set **Delay** to 100ms.
4. Run the collection.
5. Switch to Grafana and observe the flame graph update in near real-time.

## Switching between optimized and unoptimized modes

Toggle service optimizations on a running stack without a full redeploy:

```bash
# Switch to optimized code paths (OPTIMIZED=true)
bash scripts/run.sh optimize

# Generate load to capture optimized flame graphs
bash scripts/run.sh load 60

# Switch back to unoptimized code paths (default)
bash scripts/run.sh unoptimize

# Generate load to capture unoptimized flame graphs
bash scripts/run.sh load 60
```

You can toggle back and forth for A/B comparison. Use the **Before vs After Fix** dashboard in Grafana to compare flame graphs from each phase.

## Recommended investigation sequences

### Investigate CPU bottlenecks

```bash
# 1. Generate targeted CPU load
for i in $(seq 1 50); do curl -s http://localhost:18080/cpu > /dev/null & done; wait

# 2. Open Grafana: Pyroscope Java Overview → bank-api-gateway → cpu
# 3. Look for the widest bar (fibonacci)

# 4. Compare with another CPU-heavy endpoint
for i in $(seq 1 50); do curl -s http://localhost:18085/loan/risk-sim > /dev/null & done; wait

# 5. Switch to bank-loan-service in Grafana → see Math.random() in Monte Carlo
```

### Investigate lock contention

```bash
# 1. Send concurrent requests to trigger contention
for i in $(seq 1 100); do curl -s http://localhost:18081/order/process > /dev/null & done; wait

# 2. Open Grafana: Pyroscope Java Overview → bank-order-service → mutex (lock)
# 3. Look for processOrdersSynchronized frame

# 4. Compare with account service locks
for i in $(seq 1 100); do curl -s http://localhost:18084/account/deposit > /dev/null & done; wait

# 5. Switch to bank-account-service → mutex (lock) → see handleDeposit frame
```

### Investigate memory allocation

```bash
# 1. Generate allocation pressure
for i in $(seq 1 50); do curl -s http://localhost:18086/notify/render > /dev/null & done; wait

# 2. Open Grafana: Pyroscope Java Overview → bank-notification-service → alloc (memory)
# 3. Look for String.format / Formatter.format frames

# 4. Check JVM Metrics Deep Dive for GC impact
# 5. Correlate: high GC rate + wide allocation bars = the cause of GC pressure
```

### Investigate before and after optimization

```bash
# 1. Generate load against unoptimized services
bash scripts/run.sh load 60

# 2. Open Grafana: Pyroscope Java Overview → bank-api-gateway → cpu
# 3. Note the fibonacci() frame width

# 4. Switch to optimized mode
bash scripts/run.sh optimize

# 5. Generate load again
bash scripts/run.sh load 60

# 6. Open Before vs After Fix dashboard → compare flame graphs
# 7. fibonacci frame should shrink from dominant to near-zero

# 8. Switch back to unoptimized to repeat or test other services
bash scripts/run.sh unoptimize
```
