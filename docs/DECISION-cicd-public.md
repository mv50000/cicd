# Decision: `mv50000/cicd` stays public in mv50000 (RK9-38)

**Decision (2026-06-13): keep `mv50000/cicd` PUBLIC, in `mv50000` — 0 changes.**

Why: every rk9-ai repo calls `uses: mv50000/cicd/...@v1`. GitHub disallows calling
a **private** reusable workflow/action across owners, so cicd must be **public** to
be callable cross-owner from `rk9-ai/*`. It contains only deploy/CI logic — all
hosts/IPs/credentials come via `secrets.`/`inputs.`, nothing sensitive in source.

Alternative (rejected for now): move cicd into `rk9-ai` LAST and rewrite every
`uses: mv50000/cicd` → `uses: rk9-ai/cicd` across all repos. More churn, no benefit
while the public-in-mv50000 path works unchanged. Revisit only if mv50000 is retired.
