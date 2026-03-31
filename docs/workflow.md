# Development Workflow

How this project manages work, code changes, and async communication.
Currently single-contributor pushing to main. This document defines the target
workflow for when the project grows beyond one person.

---

## Current state (solo contributor)

- All work pushed directly to `main`
- No branch protection, no PR reviews
- Issues used informally for tracking ideas
- This is fine for the POC phase — adopt the full workflow incrementally as
  contributors join

---

## Target workflow

### Issues as the source of truth

Every piece of work starts as an issue. Issues are the async record of what was
decided and why — they replace meetings and Slack threads that get lost.

| Issue type | When to create | Example |
|-----------|----------------|---------|
| **Feature** | New capability | "Add Triage BOR function" |
| **Bug** | Something is broken | "Pyroscope agent not pushing profiles on OCP" |
| **Task** | Operational or infrastructure work | "Open firewall rule for port 4040" |
| **Question** | Need a decision before proceeding | "Should Phase 3 use OCP or raw K8s?" |

**What goes in an issue:**
- Clear title (imperative: "Add X", "Fix Y", not "X doesn't work")
- Context: what, why, and any constraints
- Acceptance criteria: how do we know it's done
- Labels: `phase-1`, `phase-2`, `infra`, `docs`, `bor`, `sor`

**What does NOT go in an issue:**
- Meeting notes (put those in a wiki or shared doc)
- Long design documents (create an ADR or doc in `docs/` and link to it)

### Milestones for phased delivery

| Milestone | Scope |
|-----------|-------|
| **Phase 1 — POC** | Pyroscope on VM, profiling workload validated, initial docs |
| **Phase 1 — Production** | Java agent on OCP, BOR/SOR deployed, Grafana integrated |
| **Phase 2** | Multi-VM monolith with S3-compatible object storage, HA via load balancer |
| **Phase 3** | PostgreSQL SORs, v2 BORs, microservices mode on OpenShift |

Assign every issue to a milestone. This gives a natural burndown view.

### Branches and pull requests

Adopt this when there are 2+ contributors:

```
main (protected)
  └── feature/add-triage-bor
  └── fix/agent-connection-timeout
  └── docs/update-deployment-guide
```

**Branch naming:** `type/short-description` where type is `feature`, `fix`, `docs`,
`infra`, or `chore`.

**PR workflow:**
1. Create branch from `main`
2. Make changes, commit with descriptive messages
3. Open PR — title matches the issue, body explains the change
4. Reviewer approves or requests changes (async, no meetings)
5. Merge to `main` (squash merge to keep history clean)
6. Delete the branch

**PR body should include:**
- What changed and why (1-3 bullets)
- How to test it
- Link to the issue it closes (`Closes #42`)

### Labels

Start with a minimal set. Add more only when you need to filter.

| Label | Color | Purpose |
|-------|-------|---------|
| `phase-1` | blue | Phase 1 scope |
| `phase-2` | purple | Phase 2 scope (multi-VM) |
| `phase-3` | red | Phase 3 scope (microservices on OCP) |
| `bug` | red | Something is broken |
| `feature` | green | New capability |
| `infra` | orange | VM, OCP, networking, firewall |
| `docs` | grey | Documentation only |
| `blocked` | yellow | Waiting on external team (firewall, VM, OCP) |

### Async communication

The goal is that anyone can understand the project state by reading issues and PRs
without attending a meeting or asking someone.

**Rules:**
- Decisions go in issue comments, not Slack/email
- If a conversation happens outside GitHub, summarize the outcome in the relevant issue
- Use `@mentions` for input needed, not for FYI (people can watch the repo for FYI)
- When blocked by another team, comment on the issue with who you're waiting on and
  the expected timeline

### Commit messages

```
Add triage BOR function with v1 diagnosis logic

Implements the /triage/:appName endpoint that fetches CPU and memory
profiles from the Profile Data SOR, runs TriageRules to classify
severity, and returns a structured diagnosis.

Closes #15
```

- First line: imperative, under 72 characters
- Blank line, then body explaining why (not what — the diff shows what)
- Reference the issue number

---

## When to adopt each piece

Not everything needs to happen at once. Adopt incrementally:

| Trigger | What to adopt |
|---------|---------------|
| **Now (solo)** | Push to main, use issues to track ideas and decisions |
| **Second contributor joins** | Branch protection on main, require PRs, add labels |
| **Team grows to 3+** | Milestone tracking, PR templates, code owners file |
| **Production deployment** | Release tags, changelog, runbook links in PRs |

---

## Relationship to documentation

This workflow is orthogonal to the [Diataxis documentation framework](INDEX.md) used
for the `docs/` directory. Diataxis organizes documentation by purpose (tutorial, how-to,
explanation, reference). This workflow organizes development activity (issues, PRs,
milestones). They do not overlap or conflict.

| Concern | Standard | Where |
|---------|----------|-------|
| Documentation structure | Diataxis | `docs/` directory |
| Development workflow | GitHub Issues + PRs | `.github/`, this document |
| Architecture decisions | ADRs (optional, future) | `docs/adr/` when needed |
