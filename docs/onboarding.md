# Onboarding a new company to mv50000/cicd

5 vaihetta uudelle yritykselle. Kesto: ~30 min ensimmäinen + ~5 min hostin per env.

## 1. Repo

```bash
gh repo create mv50000/<company> --private --clone
cd <company>
```

Lisää salaisuuksiin GitHubissa (Settings → Secrets and variables → Actions):

- `DEPLOY_SSH_KEY` — deploy-userin yksityinen avain (ed25519). Sama avain voidaan jakaa kaikille yrityksille tai per-yritys eristykseen.

## 2. Dockerfile + compose-tiedostot

Kopioi templatesta:

```bash
# Valitse stack:
curl -L https://raw.githubusercontent.com/mv50000/cicd/v1/templates/dockerfiles/Dockerfile.node -o Dockerfile
# tai Dockerfile.rust

mkdir -p deploy
curl -L https://raw.githubusercontent.com/mv50000/cicd/v1/templates/compose/docker-compose.yml -o deploy/docker-compose.yml
sed -i "s/COMPANY/<company>/g" deploy/docker-compose.yml
```

Mukauta `Dockerfile` projektin todellisiin build-vaiheisiin ja `deploy/docker-compose.yml` kontin portteihin/volumeihin. Säilytä `image: ghcr.io/mv50000/<company>:${IMAGE_TAG}`-rivi.

## 3. Workflow

```bash
mkdir -p .github/workflows
curl -L https://raw.githubusercontent.com/mv50000/cicd/v1/templates/workflows/deploy.yml -o .github/workflows/deploy.yml
curl -L https://raw.githubusercontent.com/mv50000/cicd/v1/templates/workflows/pr.yml -o .github/workflows/pr.yml
sed -i "s/COMPANY/<company>/g" .github/workflows/deploy.yml
```

Päivitä `health_url` jos health-endpoint poikkeaa `/api/health`-oletuksesta.

## 4. Server-puolen valmistelu (paperclip-01)

```bash
ssh paperclip-01.rk9.fi
sudo bash <(curl -L https://raw.githubusercontent.com/mv50000/cicd/v1/scripts/server-bootstrap.sh) <company> prod
```

Toista `dev`-ympäristölle jos tarvitaan. Lisää `/srv/<company>/<env>/.env`-tiedostoon yrityksen ympäristömuuttujat.

Lisää deploy-userin julkinen avain `/home/deploy/.ssh/authorized_keys`-tiedostoon (jos ei vielä).

## 5. Ensimmäinen deploy

```bash
git add .
git commit -m "Initial CI/CD setup"
git push origin main
gh run watch
```

Kun `gh run watch` kertoo onnistumisesta:

```bash
curl https://<company>.rk9.fi/api/health  # tai vastaava julkinen URL
```

## Rollback

GitHubissa: Actions → Deploy → "Run workflow" → action: `rollback`.

Komentoriviltä:

```bash
gh workflow run deploy.yml -f action=rollback -f environment=prod
```

Tai suoraan deploy-hostilla:

```bash
ssh deploy@paperclip-01.rk9.fi
bash /srv/<company>/prod/rollback.sh <company> prod
```

## Yleisiä ongelmia

- **Health timeout**: kasvata `health_timeout_s` deploy-workflow-kutsussa, oletus on 60 s. Esim. Rust-kontti voi tarvita 90–120 s ensimmäiseen requestiin.
- **GHCR pull failure deploy-hostilla**: tarkista `docker login ghcr.io` deploy-userina (`docker login ghcr.io -u <gh-user> -p <pat-with-read:packages>`).
- **rsync error**: deploy-userilla pitää olla kirjoitusoikeus `${deploy_path}`-kansioon. Suorita `chown -R deploy:deploy /srv/<company>`.
