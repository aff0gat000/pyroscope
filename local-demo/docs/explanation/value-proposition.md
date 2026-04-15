# Explanation — value proposition

## The problem this demo answers

Continuous profiling is easy to deploy but *hard to interpret* before you
have seen it applied to real problems. Teams install Pyroscope, turn it
on in production, and then only open it during an incident — which is
exactly when they have no spare brain cycles to learn the tool.

This demo is the opposite: a **low-stakes, always-on environment** that
reproduces every common Vert.x problem on demand, with labels and
dashboards tuned so the signal is visible in 30 seconds.

## Who it serves

- **Platform / SRE engineers** evaluating Pyroscope before rolling it out.
- **Application developers** learning to read flame graphs before their
  first production incident.
- **Incident responders** rehearsing debugging workflows on canned
  scenarios — see [how-to/debugging-incidents.md](../how-to/debugging-incidents.md).
- **Architects** comparing JVM 11 worker-pool code against JVM 21
  virtual-thread code for the same workload.

## What makes this different from a vanilla Pyroscope quickstart

| vanilla quickstart            | this demo                                        |
|-------------------------------|--------------------------------------------------|
| one language, one app         | two JVMs (11 + 21) side by side                  |
| synthetic CPU-burn workloads  | real clients: redis, postgres, mongo, couchbase, kafka, vault |
| generic dashboards            | three dashboards tuned to Vert.x threading model |
| no failure modes              | intentional antipatterns (thread leak, eventloop block) |
| "push this metric"            | `Label.tag` per integration → hotspots dashboard |
| ephemeral                     | volumes persist; reproducible over days          |

## The hypothesis

Profiling is most valuable when:
1. Labels match the *shape of the org* (service, team, integration).
2. Dashboards answer *questions engineers actually ask* ("is my loop
   blocked?", "which client dominates GC?"), not generic CPU heatmaps.
3. The first five minutes with the tool are a structured tour, not a
   blank page.

Each of those is baked into the demo. If a principle doesn't survive
contact with your real workloads, the demo is the cheap place to find
out — not production.

## Measurable outcomes

A team that runs through this demo should be able to:

1. Identify an event-loop blocker from a wall-clock flame graph in <2 min.
2. Attribute GC pressure to a specific verticle from the allocation
   profile.
3. Use Pyroscope's comparison view to validate that a fix shrank the
   offending frame.
4. Know when profiling is the right tool — and when to reach for metrics,
   logs, or tracing instead.

## Non-goals

- This is **not** a load / chaos test — k6 here is for traffic, not
  realistic user behaviour.
- Not a reference architecture for production: retention is 7 d, no
  replication, no authn/z on Pyroscope.
- Not a Vert.x tutorial — the verticles are intentionally minimal.
