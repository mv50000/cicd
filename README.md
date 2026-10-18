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

v4:n gate-tilassa (`deploy_transport: gate`) deploy-jobi ei synkkaa tiedostoja eikä aja etäshelliä. Se lähettää `actions/gated-deploy`n kautta vain palvelinpään deploy-gaten verbejä. Ks. [Gate-tila (v4)](#gate-tila-v4).

## Reusable workflows

| Workflow | Kuvaus |
|----------|--------|
| `build-and-deploy.yml` | Build Docker-image, push GHCR:lle, sitten `deploy_transport`-inputin mukaan: `ssh` (oletus) = rsync compose-files + ssh-deploy + health-check, `gate` = deploy-gaten verbit `deploy`, `health` ja tarvittaessa `rollback` |
| `pr-checks.yml` | Standardoidut PR-tarkistukset (typecheck, test, build) — yritys voi kustomoida |
| `rollback.yml` | `workflow_dispatch`: deploy aiemman `:sha-XXX`-tagin. Vain ssh-tila, ks. [Rajaukset](#rajaukset) |
| `guard-deploy-labels.yml` | PR-vahti: host-kontaktijobit self-hostedille, gate-tila lan-deploy-runnerille |

## Composite actions

| Action | Kuvaus |
|--------|--------|
| `setup-toolchain` | Asenna Docker buildx + GHCR-kirjautuminen |
| `docker-build-push` | Multi-stage build BuildKit-cachella, push GHCR:lle, output: image-tag |
| `ssh-deploy` | rsync `deploy/` deploy-targetille, `docker compose pull && up -d --wait` |
| `gated-deploy` | (v4) yksi deploy-gaten verbi yhdellä ssh-kutsulla: `deploy <tag>`, `health`, `rollback` tai `status`. Token stdinissä, pinnattu host key, avain `$RUNNER_TEMP`issa |
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
    uses: mv50000/cicd/.github/workflows/build-and-deploy.yml@v4
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

## Gate-tila (v4)

Gate-tilassa deploy-jobi ajaa lan-deploy-runnerilla ja puhuu vain palvelinpään deploy-gatelle (verbisopimus v1). Gate on forced-command-avain: avainrivi määrää sovelluksen, ympäristön ja roolin, eikä pyyntö voi valita niitä.

```yaml
jobs:
  deploy:
    uses: mv50000/cicd/.github/workflows/build-and-deploy.yml@v4
    with:
      company: saatavilla
      environment: dev
      image_name: ghcr.io/<org>/saatavilla
      deploy_host: ${{ vars.DEPLOY_HOST }}
      deploy_path: <palvelimen polku, käytössä vain ssh-tilassa>
      health_url: <käytössä vain ssh-tilassa>
      deploy_transport: gate
      runner_label: lan-deploy
    secrets:
      DEPLOY_GATE_KEY: ${{ secrets.<APP>_DEPLOY_GATE_KEY }}
      DEPLOY_GATE_KNOWN_HOSTS: ${{ secrets.DEPLOY_GATE_KNOWN_HOSTS }}
```

**Deploy-jobi gate-tilassa:**

1. `deploy <tag>`. GHCR-token (jobin `GITHUB_TOKEN`, `packages: read`) menee vain ssh-prosessin stdiniin. Gate kirjautuu, pullaa, vaihtaa `IMAGE_TAG`in, käynnistää palvelut ja tarkistaa healthin.
2. `health` pollataan, kunnes vastaus on ok tai `health_timeout_s` täyttyy.
3. `rollback` lähetetään vain, jos health epäonnistuu ja tämä ajo oikeasti vaihtoi tagin (`"changed":true`).

Epäonnistunut `deploy` ei käynnistä rollbackia. Gate palauttaa vanhan tilan itse ja kertoo sen `restored`-kentässä. Asiakkaan rollback veisi previous-tagiin eli kaksi versiota taaksepäin.

**Turvarajat:**

- Jokainen ssh-kutsu välittää yhden verbin. Tagi tarkistetaan regexillä `^sha-[0-9a-f]{7,40}$` ennen lähetystä.
- Host key pinnataan secretillä `DEPLOY_GATE_KNOWN_HOSTS` (known_hosts-rivi). Skannausta ei ole, ja puuttuva pinni failaa.
- Avain ja known_hosts kirjoitetaan `mktemp -p "$RUNNER_TEMP"` -tiedostoihin (600). `if: always()` -askel poistaa ne, ja viimeinen askel failaa, jos avaintiedosto on yhä olemassa.
- ssh ajetaan `-F /dev/null`-asetuksella: käyttäjän tai järjestelmän ssh_config ei vaikuta kutsuun.
- `runner_label`illa ei ole gate-tilassa oletusta. Arvon on oltava `lan-deploy` tai `lan-deploy-<pääte>`. Tyhjä, `self-hosted`, `paperclip`, `docker` tai pilvilabel failaa build-jobin ensimmäisessä askeleessa, joten deploy-jobi ei mene jonoon. Build-jobi (pilvi) ei viittaa deploy-secreteihin. Sillä on vain automaattinen `GITHUB_TOKEN` imagen pushiin.
- Gate-jobi tarkistaa secretit ensimmäisessä askeleessaan. Se failaa, jos gate-avain tai pinni puuttuu tai jos sille annetaan `DEPLOY_SSH_KEY` (esim. `secrets: inherit`). Tarkistus estää avaimen käytön, mutta ei sitä, että runner on jo saanut sen. Siksi kutsuja nimeää secretit itse.
- `actions/gated-deploy` kieltäytyy GitHub-hostatulta runnerilta (`RUNNER_ENVIRONMENT=github-hosted`). Tarkistus on vain lisäsuoja: muut pilvirunnerit (esim. Blacksmith) rekisteröityvät self-hostediksi. Varsinainen kontrolli on `runs-on`/`runner_label` ja guard.
- Jos ssh-yhteys katkeaa kesken `deploy`- tai `rollback`-kutsun, action kysyy `status`in kerran lokiin, jotta hostin tila näkyy.
- Gate-jobi ei checkouttaa repoa.

### Verbisopimus v1 (asiakkaan näkökulma)

Kanoninen sopimus on palvelinpään deploy-gaten dokumentaatiossa. Tähän on kopioitu vain se, mitä asiakas tarvitsee.

| Verbi | Argumentti | stdin |
|---|---|---|
| `deploy <tag>` | `^sha-[0-9a-f]{7,40}$` | GHCR-token yhtenä rivinä (`^[A-Za-z0-9_.-]{1,8000}$`, enintään 8192 tavua) tai tyhjä (ei registry-loginia) |
| `health` | – | ei lueta |
| `rollback` | – | ei lueta |
| `status` | – | ei lueta |

Pyyntö on enintään 128 merkkiä merkistöstä `[A-Za-z0-9 ._:@/+=-]`, ja tokenien välissä on tasan yksi välilyönti.

Vastaus on tasan yksi JSON-rivi, esimerkiksi:

```
{"ok":true,"verb":"deploy","tag":"sha-26a9715","changed":false,"health":"ok","current":"sha-26a9715","previous":"sha-ab9fe40"}
{"ok":false,"error":"rejected","reason":"bad_tag"}
{"ok":false,"verb":"deploy","error":"health_failed","tag":"sha-1234567","restored":"ok"}
```

| Poistumiskoodi | Merkitys |
|---|---|
| 0 | ok |
| 1 | hyväksytty, mutta toimenpide epäonnistui (`error`) |
| 2 | hylätty ennen toimenpidettä (`reason`) |
| 70 | audit-rivin kirjoitus epäonnistui, mitään ei tehty |
| 255 | ssh itse: yhteys, lähdeosoiterajaus tai avain (gatea ei ajettu) |

`actions/gated-deploy` pitää onnistumisena vain riviä, joka alkaa `{"ok":true`. Muu muoto failaa. Vastaus ja ssh:n stderr tulostetaan `::stop-commands::`-merkkien väliin etuliitteen kanssa, ja `##[` muutetaan muotoon `# #[`. Siksi gaten tuloste ei aja workflow-komentoja.

### Compose-tiedostot gate-tilassa (K4)

Gate-tila ei synkkaa repon `deploy/`-hakemistoa hostille. Compose-tiedostot omistaa host. Muutos (uusi palvelu, uusi env-avain) tehdään toistaiseksi käsin operaattorin runbookilla ennen deployta, joka tarvitsee sen. Validoiva sync-verbi on myöhempi lisäys deploy-gateen. Jos repon `deploy/`-hakemisto muuttuu, deploy ei vie muutosta perille.

### Rajaukset

- `rollback.yml` pysyy ssh-tilassa. Gate-kuluttaja tekee manuaalisen rollbackin omalla `workflow_dispatch`-workflowllaan, joka kutsuu `mv50000/cicd/actions/gated-deploy@v4` verbillä `rollback` (`runs-on: [self-hosted, lan-deploy]`). Erillinen reusable tehdään myöhemmin.
- `deploy_path`, `compose_file` ja `health_url` eivät vaikuta gate-tilaan: gaten profiili määrää ne hostilla.

### Migraatio v2 → v4

1. Vaihda `build-and-deploy.yml@v2` → `@v4`. Ilman muita muutoksia käytös on sama kuin v2:ssa ja v3:ssa (ssh-tila).
2. Gate-tilaan: lisää `deploy_transport: gate` ja `runner_label: lan-deploy`, ja anna secretit `DEPLOY_GATE_KEY` ja `DEPLOY_GATE_KNOWN_HOSTS` nimettyinä. Älä anna `DEPLOY_SSH_KEY`tä äläkä käytä `secrets: inherit`iä: gate-jobi failaa silloin.
3. Jos repo kutsuu `guard-deploy-labels.yml`ää, vaihda sekin `@v4`:ään. Vain v4:n guard tuntee gate-tilan. Se tarkistaa gate-jobit kaikista workflow-tiedostoista, ei vain `deploy*`- ja `release*`-tiedostoista.
4. Tarkista, ettei `deploy/`-hakemistossa ole vientiä odottavia compose-muutoksia (K4).

## Versiointi

Tagit ovat jäädytettyjä. Uusi käytös julkaistaan uutena major-tagina, eikä vanhaa tagia siirretä.

| Tagi | Commit | Sisältö |
|---|---|---|
| `v1` | `599d717` | alkuperäiset actionit + RK9-503 (`.env` 600) |
| `v2` | `c7d6e0e` | build (pilvi) ja deploy (self-hosted) eri jobeissa |
| `v3` | `8fc0cdd` | + isolation-probe, secret-scan, RK9-503 |
| `v4` | (main, RK9-545) | + `deploy_transport: gate`, `actions/gated-deploy`, sisäiset viittaukset `@v4` |

v1–v3 ovat jäädytettyjä, koska kuluttajat (mm. sunspot, alli-audit, rk9-site) pinnaavat niitä. v2:n ja v3:n workflowt viittaavat actioneihin `@v1`:llä. v4:n workflowt viittaavat omiin actioneihinsa `@v4`:llä, joten v4 ei muutu, vaikka vanhempi tagi joskus siirtyisi. Tarkka versio lukitaan commit-SHA:lla (`@<sha>`).

## Testit

```
python3 -m unittest discover -s scripts
```

`test_check_deploy_labels.py` testaa runner-vahdin ja `test_gated_deploy.py` ajaa gated-deployn askeleet tynkä-ssh:ta vasten (vaatii PyYAML:n). `self-test.yml` ajaa ne PR:issä.

## Lisenssi

MIT.

## Deploy-runner policy (RK9-37)
Deploy jobs that contact a host must be self-hosted (dev-proxy 403s cloud IPs); gate-mode deploys must run on a lan-deploy runner. See [docs/deploy-runner-policy.md](docs/deploy-runner-policy.md); enforced by `scripts/check-deploy-labels.py` + reusable `.github/workflows/guard-deploy-labels.yml`.

## Blacksmith CI onboarding (RK9-38)
New repo → Blacksmith-first CI in <30 min: see [ONBOARDING-BLACKSMITH.md](ONBOARDING-BLACKSMITH.md). Templates in `templates/workflows/` (pr-checks-rust, pr-checks-node, ai-auto-merge with conclusion+protected-path gate, deploy-stub). cicd stays public: [docs/DECISION-cicd-public.md](docs/DECISION-cicd-public.md).
