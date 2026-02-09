# Production Onboarding Questionnaire — Pyroscope BOR/SOR

This initiative is submitted as two phases, each with its own questionnaire:

| Phase | Functions | Database | Questionnaire |
|-------|-----------|----------|---------------|
| **Phase 1** | 3 BOR + 1 SOR | No | [production-questionnaire-phase1.md](production-questionnaire-phase1.md) |
| **Phase 2** | 3 BOR (v2) + 5 SOR | PostgreSQL | [production-questionnaire-phase2.md](production-questionnaire-phase2.md) |

Phase 1 deploys first with no database dependency. Phase 2 builds on Phase 1 by adding 4 PostgreSQL-backed SORs and upgrading the BOR functions to include baseline comparison, audit trails, and ownership enrichment. The upgrade is incremental — v2 BORs gracefully handle missing SOR URLs.
