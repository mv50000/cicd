# mv50000/cicd

Yhtenäinen, Docker-pohjainen, multi-host CI/CD-putki Paperclip-yrityksille. Tarjoaa keskitetyt **reusable workflows** ja **composite actions**, joita yritysrepot kutsuvat ohuesta ~30-rivisestä `deploy.yml`-tiedostosta.

## Arkkitehtuuri

```
Yritysrepo (mv50000/saatavilla)              mv50000/cicd                 paperclip-01.rk9.fi
─────────────────────────────────            ─────────────────────            ──────────────────
.github/workflows/deploy.yml ──uses──►  .github/workflows/build-and-deploy.yml
                                                  │
                                        actions/docker-build-push/  ──push──►  ghcr.io/mv50000/saatavilla:sha-abc1234
                                                  │
                                        actions/ssh-deploy/  ──rsync+ssh──►  /srv/saatavilla/prod/
                                                  │                            docker compose pull && up -d
                                        actions/wait-for-health/  ──curl──►  health endpoint
```

## Reusable workflows

| Workflow | Kuvaus |
|----------|--------|
| `build-and-deploy.yml` | Build Docker-image, push GHCR:lle, rsync compose-files, ssh-deploy, health-check |
| `pr-checks.yml` | Standardoidut PR-tarkistukset (typecheck, test, build) — yritys voi kustomoida |
| `rollback.yml` | `workflow_dispatch`: deploy aiemman `:sha-XXX`-tagin |

## Composite actions

| Action | Kuvaus |
|--------|--------|
| `setup-toolchain` | Asenna Docker buildx + GHCR-kirjautuminen |
| `docker-build-push` | Multi-stage build BuildKit-cachella, push GHCR:lle, output: image-tag |
| `ssh-deploy` | rsync `deploy/` deploy-targetille, `docker compose pull && up -d --wait` |
| `wait-for-health` | Poll `health_url`, timeout, automaattinen tag-pointer-rollback fail-tilassa |
| `slack-notify` | Slack-webhook (no-op jos `SLACK_WEBHOOK_URL` puuttuu) |

## Käyttö yritysrepossa

`deploy.yml`:
```yaml
name: Deploy
on:
  push: { branches: [main] }
  workflow_dispatch:
    inputs: { environment: { type: choice, options: [dev, prod] } }

jobs:
  deploy:
    uses: mv50000/cicd/.github/workflows/build-and-deploy.yml@v1
    with:
      company: saatavilla
      environment: ${{ github.event.inputs.environment || 'prod' }}
      image_name: ghcr.io/mv50000/saatavilla
      deploy_host: paperclip-01.rk9.fi
      deploy_path: /srv/saatavilla/${{ github.event.inputs.environment || 'prod' }}
      health_url: http://localhost:3000/api/health
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
```

## Konventiot

- **Image namespace:** `ghcr.io/mv50000/{company}` — sama kuin lähdekoodi-repo, `${{ secrets.GITHUB_TOKEN }}` riittää push/pull-oikeuksiin
- **Tagit:** `:sha-<7>` (immutable), `:env-prod` / `:env-dev` (deploy-pointer), `:branch-<slug>`, `:pr-<n>`, `:vX.Y.Z`
- **Deploy host -hakemisto:** `/srv/{company}/{env}/` sisältää `docker-compose.yml`, `.env` (manual), `current-tag`, `previous-tag`, `data/`, `logs/`
- **Concurrency:** `deploy-{company}-{env}` estää race-deployt samassa ympäristössä
- **Runner labels:** `[self-hosted, paperclip]` paperclip-01:llä, valinnainen `runner_label`-parametri muille hosteille

## Skriptit

- `scripts/server-bootstrap.sh <company> <env>` — luo `/srv/{co}/{env}/`-rakenteen, asentaa Dockerin tarvittaessa, lisää deploy-userin
- `scripts/rollback.sh <company> <env>` — palaa `previous-tag`-tagiin
- `scripts/healthcheck.sh <url>` — pollaa health-endpointia konfiguroidulla timeoutilla
- `scripts/post-transfer-check.sh <owner/repo> [clone-polku]` — GitHub org-siirron jälkeinen per-repo-tarkistus (runnerit, webhookit, jäännös-`ghcr.io/mv50000`-viittaukset, lokaalin kloonin remote). Ks. [docs/org-transfer-fallout.md](docs/org-transfer-fallout.md)
- `scripts/ghcr-rewrite-apply.sh <repo-polku> [--new-owner O] [--apply]` — GHCR-namespacen uudelleenkirjoitus org-siirron jälkeen (dry-run-diff oletuksena, `--apply` kuittauksella). Ks. [docs/org-transfer-fallout.md](docs/org-transfer-fallout.md)

## Versiointi

Tagit `v1`, `v2`, ... rolling — `v1` osoittaa aina viimeiseen v1-yhteensopivaan committiin. Yritykset pinnaavat `@v1` saadakseen rolling-päivitykset, tai `@v1.4.2` lukitakseen tarkan version.

## Lisenssi

MIT.
