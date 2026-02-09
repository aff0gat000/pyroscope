# Reading Flame Graphs

## What is a Flame Graph

A flame graph is a visualization of profiled stack traces. Each box represents a function in the call stack, and its width represents how much of the profiled resource (CPU, memory, lock time) that function consumed.

### How to Read

- **Y-axis (vertical)**: Stack depth. Bottom is the entry point (e.g., `main`), top is the leaf function executing when the sample was taken.
- **X-axis (horizontal)**: **Not time.** Functions are sorted alphabetically. Width represents the proportion of samples that include this function.
- **Width**: Wider = more samples = higher resource usage. A function appearing in 30% of samples is 30% wide.
- **Color**: In standard mode, colors are random and distinguish adjacent boxes. In diff mode, red = regression, green = improvement.

### Key Terminology

| Term | Meaning |
|------|---------|
| Self time | Time spent executing code directly in this function (not in callees) |
| Total time | Time spent in this function and all functions it calls |
| Sample | A single snapshot of the call stack at a point in time |
| Root | The bottom of the flame graph (entry point) |
| Leaf | The top of the flame graph (function that was actually running) |

### What to Look For

1. **Wide plateaus at the top** — functions with high self time, doing actual work
2. **Wide towers** — a function with high total time delegating to many callees; the function itself may not be the problem, but it leads to expensive work
3. **Missing frames** — gaps in the stack usually mean inlined functions (JIT-optimized) or native frames

---

## CPU Profile (`cpu` / `itimer`)

**What it measures**: Which functions consume CPU cycles. The profiler samples the call stack at regular intervals (typically every 10ms) and counts how often each function appears.

**When to use**: High CPU utilization, slow response times under load, throughput optimization.

### Patterns

| Pattern | What it Means | Action |
|---------|---------------|--------|
| Wide plateau: `MessageDigest.digest` | Cryptographic hashing consuming CPU | Cache hash results, reduce hash frequency |
| Wide plateau: `String.concat` / `StringBuilder.append` | String manipulation hotspot | Use StringBuilder (not `+` in loops), pre-size builder |
| Wide plateau: `HashMap.resize` | Hash map resizing | Pre-size: `new HashMap<>(expectedSize)` |
| Tower through GC frames | Garbage collection overhead | Reduce allocation rate (see alloc profile), tune heap |
| Wide plateau: `Thread.sleep` / `Object.wait` | Threads blocking on CPU profile = too many threads | Reduce thread pool size, investigate why threads park |
| Tower through `synchronized` | Monitor contention appearing in CPU | Use concurrent data structures, reduce critical section |

### Example

```
com.example.PaymentService.processPayment ██████████████████ 18.2%
  com.example.crypto.HashUtil.sha256       ████████████       12.1%
    java.security.MessageDigest.digest     ██████████         10.3%
  com.example.db.AccountDAO.findById       ████                4.1%
```

**Reading**: `processPayment` consumes 18.2% of CPU. Most of that (12.1%) is SHA-256 hashing, where `digest` itself has 10.3% self time — that is the hotspot. Consider caching payment hashes or using a faster algorithm for non-security-critical operations.

---

## Allocation Profile (`alloc`)

**What it measures**: Which functions allocate heap memory. async-profiler hooks into TLAB (Thread Local Allocation Buffer) events to track every significant allocation.

**When to use**: High GC pause times, frequent GC cycles, growing heap, OutOfMemoryError risk.

### Patterns

| Pattern | What it Means | Action |
|---------|---------------|--------|
| Wide plateau: `String.concat`, `StringBuilder.toString` | String allocation hotspot | Pre-size StringBuilder, use `String.join()` |
| Wide plateau: `Arrays.copyOf` | Array/collection resizing | Pre-size collections: `new ArrayList<>(capacity)` |
| Tower through `ObjectMapper.readValue` | JSON deserialization allocating heavily | Stream parsing, reuse ObjectMapper, consider protobuf |
| Wide plateau: `byte[]` allocation | Buffer allocation | Pool buffers (ByteBuffer pool, Netty ByteBuf) |
| Tower through `Stream.collect` | Stream API creating intermediate objects | Use for-loops on hot paths, or primitive streams |
| Wide plateau in logging framework | Log formatting even when level is disabled | Use `log.isDebugEnabled()` guards, parameterized logging |

### Example

```
com.example.api.ResponseBuilder.build            ██████████████████████ 24.5%
  com.fasterxml.jackson.ObjectMapper.writeValue   ████████████████       18.2%
    com.fasterxml.jackson.ser.BeanSerializer       ████████████          14.1%
      byte[] allocation                            ██████████            11.8%
```

**Reading**: Response serialization accounts for 24.5% of all allocations. Jackson allocates 11.8% of total heap in byte arrays for JSON output. Consider response caching, streaming serialization, or a zero-copy serializer for high-throughput endpoints.

---

## Lock / Contention Profile (`lock`)

**What it measures**: Which `synchronized` blocks or `Lock` acquisitions cause threads to wait. async-profiler tracks `park`/`monitorenter` events and measures blocking duration.

**When to use**: High latency variance, thread pool exhaustion, suspected thread contention.

### Patterns

| Pattern | What it Means | Action |
|---------|---------------|--------|
| Wide plateau on a `synchronized` method | Single lock is a bottleneck | Reduce critical section scope, use ReadWriteLock |
| Wide plateau: `ReentrantLock.lock` | Explicit lock contention | Use `tryLock()` with timeout, consider lock striping |
| Tower through `ConnectionPool.getConnection` | Database connection pool exhaustion | Increase pool size, reduce query time, add timeout |
| Tower through `LinkedBlockingQueue.put/take` | Producer-consumer contention | Use `ConcurrentLinkedQueue`, increase capacity |
| Multiple locks with similar widths | Distributed contention | Systemic issue — consider lock-free architecture |

### Example

```
com.example.cache.LocalCache.get             ██████████████████████████████ 35.2%
  ReentrantReadWriteLock.readLock             ████████████                   14.8%
com.example.cache.LocalCache.put             ████████████████               18.7%
  ReentrantReadWriteLock.writeLock            ██████████                     12.1%
```

**Reading**: Cache operations account for 53.9% of lock contention. Read and write locks compete with each other. Switch to `ConcurrentHashMap`, segmented locking, or a lock-free cache like Caffeine.

---

## Wall-Clock Profile (`wall`)

**What it measures**: Where real (wall-clock) time is spent, regardless of CPU activity. Samples ALL threads at regular intervals, including those sleeping, waiting, or blocked on I/O.

**When to use**: High latency but low CPU utilization — time is spent waiting, not computing. This is the first profile to check for latency investigations.

### Patterns

| Pattern | What it Means | Action |
|---------|---------------|--------|
| Wide plateau: `SocketInputStream.read` | Waiting on network response | Check upstream latency, add timeouts, consider async I/O |
| Wide plateau: `Thread.sleep` | Intentional delays | Review necessity, reduce duration |
| Wide plateau: `Object.wait` / `Condition.await` | Waiting for signals | Check notify/signal delivery, investigate deadlocks |
| Wide plateau: `Unsafe.park` / `LockSupport.park` | Thread pool idle or waiting | Normal at low utilization; investigate if latency is high |
| Tower through DNS resolution | DNS lookup latency | Cache DNS, use IP addresses, reduce TTL |
| Tower through SSL/TLS handshake | TLS negotiation overhead | Enable session resumption, use TLS 1.3 |

### Example

```
com.example.OrderService.placeOrder          ██████████████████████████████████████ 45.0%
  com.example.client.PaymentClient.charge    ██████████████████████                 25.3%
    java.net.SocketInputStream.read          ████████████████████                   22.1%
  com.example.client.InventoryClient.reserve ████████████                           13.4%
    java.net.SocketInputStream.read          ██████████                             11.2%
  com.example.db.OrderDAO.insert             ████                                    4.3%
```

**Reading**: `placeOrder` takes 45% of wall-clock time. Most is spent waiting on two downstream services: payment (25.3%) and inventory (13.4%), both dominated by socket reads — these are network round-trips. Parallelize the payment and inventory calls (they appear independent), add circuit breakers, and review SLAs for those upstream services.

---

## Which Profile to Use

| Question | Profile Type |
|----------|--------------|
| Why is CPU utilization high? | CPU |
| Why are GC pauses long? | Allocation |
| Why is latency high but CPU low? | Wall-clock |
| Why does throughput drop under concurrency? | Lock |
| Where should I optimize first? | Start with CPU, then Wall-clock |
| Is this a compute or I/O problem? | Compare CPU vs Wall-clock |

## Practical Tips

1. **Start with wall-clock for latency issues.** CPU profiles miss I/O wait time entirely.
2. **Allocation profiles explain GC behavior.** If GC shows up in your CPU profile, switch to allocation to find the root cause.
3. **Lock profiles need load.** Contention only appears under concurrent access — profile during peak traffic.
4. **Compare before and after.** Use the Diff Report BOR or Pyroscope's built-in diff view to see what changed after a deployment.
5. **Look at self time, not total time.** A function with 50% total time but 0.1% self time is just a caller — the problem is deeper in the stack.
6. **Filter by label.** In Pyroscope, use labels to narrow to specific endpoints or regions: `myapp.cpu{endpoint="/api/payment"}`.
7. **Ignore narrow frames.** Functions under 1% are noise. Focus on the widest boxes first.
