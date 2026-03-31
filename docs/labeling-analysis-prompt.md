# Profiling Label Analysis — AI Copilot Prompt

Reusable prompt for analyzing a Vert.x server codebase to design a Pyroscope continuous
profiling labeling strategy. Use this when the analyst has access to the actual server
repository code.

## How to use

1. Open the Vert.x server repository in an AI copilot with codebase access
2. Paste the prompt below
3. Review the analysis and recommendations
4. Use the updated prompt (section F of the output) for future sessions

---

## Prompt

```
You are analyzing an enterprise Vert.x reactive server codebase to design a
Pyroscope continuous profiling labeling strategy.

## Your primary task

Read this codebase thoroughly before answering. The code is your primary
source of truth — do not assume or guess when the answer is in the source.
Explore the full project structure, dependency graph, and module hierarchy
before making recommendations.

## Architecture context

This is a shared Vert.x 4.x server platform with the following characteristics:

- Hosts hundreds to thousands of functions deployed as Vert.x verticles
- Multiple identical server replicas run behind horizontal pod autoscaling
  on OpenShift Container Platform
- A single Vert.x instance hosts many verticles in the same JVM process
- Functions are primarily event-loop / non-blocking (reactive) but some
  use executeBlocking for legacy or third-party integration code
- Functions call various downstream services: relational databases, caches,
  message queues, other functions via HTTP, and external APIs
- The Pyroscope Java agent (open source, io.pyroscope:agent) is attached
  at runtime via -javaagent in JAVA_TOOL_OPTIONS
- Without profiling labels, all verticles' CPU samples merge into one
  flame graph per event loop thread — making it impossible to attribute
  CPU usage to a specific function

## What you need to find in the codebase

Work through each item below. For each, cite the specific file paths and
code you found. Do not skip items — if you cannot find something, say so
and explain what you looked for.

### 1. Project structure and module hierarchy

- Map the full Gradle (or Maven) multi-module structure
- Identify the layering: which modules are platform/infrastructure, which
  are shared business libraries, which are function modules
- Count the total number of function/verticle modules
- Identify the module dependency direction (what depends on what)

### 2. Server startup and Router creation

- Find where the Vert.x instance is created
- Find where the HTTP server and Router are initialized
- Find where route handlers are registered
- Identify the earliest point where a global router.route().handler()
  can be inserted so it executes before ALL function-specific handlers
- Document the handler chain order

### 3. Verticle deployment model

- How are function verticles discovered and deployed onto the server?
- Is there a registry, deployment descriptor, classpath scan, annotation,
  or manual registration?
- How can the function name be resolved at request time? Options include:
  environment variable, route path prefix, verticle class name, deployment
  ID, or a custom context attribute
- How are verticle lifecycle events handled (deploy, undeploy, failure)?

### 4. Downstream service integration

- Find all WebClient, HttpClient, or HTTP request builder usage
- Find all database client usage (reactive SQL client, JDBC, connection pools)
- Find all cache client usage (Redis, Hazelcast, Infinispan)
- Find all message queue client usage (Kafka, AMQP, JMS)
- Find all EventBus usage (inter-verticle messaging)
- For each, note whether calls are non-blocking (event loop) or blocking
  (worker thread)

### 5. Blocking code paths

- Search for all uses of: executeBlocking, setWorker(true),
  DeploymentOptions().setWorker, Thread.sleep, synchronized blocks,
  and any other blocking patterns
- List each occurrence with file path and what it does
- These represent code paths where event loop labels will not apply and
  need special treatment

### 6. Existing instrumentation

- Search for any existing Pyroscope, Micrometer, OpenTelemetry, or custom
  metrics/tracing/profiling instrumentation
- Note any existing label, tag, or context propagation mechanisms
- Identify if there is already a shared middleware or handler chain that
  could host a label handler

### 7. Configuration and environment model

- How is the server configured? (YAML, properties, environment variables,
  config server)
- How are function-specific settings passed? (per-verticle config, shared
  config, environment variables)
- Is there a standard environment variable or config key that identifies
  the function name at runtime?

## What you need to recommend

Based on your codebase analysis, provide:

### A. Label handler design

Design a single Vert.x Handler<RoutingContext> that:
- Registers as a global handler before all function routes
- Sets one Pyroscope label: `function` — the name/identifier of the
  function handling this request
- Uses io.pyroscope.labels.Pyroscope.LabelsWrapper.run() wrapped in a
  try/catch for NoClassDefFoundError (graceful degradation when agent
  is not attached)
- Stores the label on the RoutingContext via ctx.put() for potential
  async propagation in the future
- Has zero impact on existing function code (no per-verticle changes)
- The Pyroscope agent dependency is compileOnly (not bundled)

### B. Where the handler should live

Based on the module hierarchy, which Gradle subproject or package should
contain the label handler so it is:
- Available to the server startup code
- Automatically applied to all deployed verticles
- Maintainable by the platform team without requiring function team changes

### C. Cardinality analysis

- Count distinct function/verticle names in the codebase
- Count distinct route paths
- Calculate total profiling series: functions x 1 (single label)
- Flag if series count exceeds 10,000 (storage risk)
- Estimate storage impact using: series x 3 GB/month baseline

### D. executeBlocking strategy

For each blocking code path found in item 5:
- Can the label be propagated from the event loop thread to the worker
  thread? (Answer: not automatically via ThreadLocal)
- Recommend whether to: (a) label the executeBlocking call site,
  (b) wrap the blocking code in LabelsWrapper.run() on the worker thread,
  or (c) flag it for the owning team to review

### E. Risk assessment

- What could go wrong with the label handler?
- What is the performance overhead? (Expected: nanoseconds per request)
- Are there any Vert.x version compatibility concerns?
- Are there any thread safety concerns with the ThreadLocal label approach?

### F. Update this prompt

After completing your analysis, produce an updated version of this entire
prompt that incorporates what you learned from the codebase. Specifically:

- Replace generic descriptions with actual module names, package paths,
  and configuration keys you discovered
- Add any codebase-specific patterns, conventions, or components that
  the original prompt did not anticipate
- Remove any assumptions from the context section that turned out to be
  incorrect
- Add new analysis items for anything important you found that was not
  covered by the original prompt
- Keep the updated prompt free of proprietary data, credentials, internal
  URLs, or customer information — use placeholders where needed

The goal is that the updated prompt can be re-run by a different engineer
(or in a future session) and produce faster, more accurate results because
it already reflects the actual codebase structure.

Save the updated prompt as a separate clearly-labeled section at the end
of your output so it can be copied and versioned.

## Constraints

- One label only for now: `function`
- No changes to individual function/verticle code
- Must work with Vert.x 4.x Router
- Must be safe when Pyroscope agent is not attached
- Must not add measurable latency to the request path
- compileOnly dependency on io.pyroscope:agent
- Do not expose proprietary function names, internal URLs, credentials,
  or customer data in your output — use placeholders if needed

## Output format

Structure your response with clear headings matching the numbered items
above. For each finding, show:
- File path(s) and relevant code excerpts
- Your analysis
- Your recommendation
- Any risks or edge cases
```

---

## Cross-references

- [vertx-labeling-guide.md](vertx-labeling-guide.md) — Vert.x component reference and labeling strategy
- [async-profiling-guide.md](async-profiling-guide.md) — Labeling implementation details and LabeledFuture
- [configuration-reference.md](configuration-reference.md) — Pyroscope agent properties
