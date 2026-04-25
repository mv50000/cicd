# Migration from systemd-deployed companies

Käytä tätä jos yritys nykyisin pyörii natiivina binäärinä systemd-yksikön takana (alli-audit, bk/ololla, quantimodo).

## Vaiheet

1. **Lue [onboarding.md](./onboarding.md)** ja seuraa vaiheita 1–3 (repo + Dockerfile + workflow). Älä push:aa vielä.

2. **Build + run lokaalisti** ennen pushia:
   ```bash
   docker build -t local-test .
   docker run --rm -p 3000:3000 --env-file .env.local local-test
   curl http://localhost:3000/api/health
   ```

3. **Server-puoli — luo /srv-rakenne RINNAKKAIN systemd-yksikön kanssa:**
   ```bash
   ssh paperclip-01.rk9.fi
   sudo bash server-bootstrap.sh <company> prod
   ```
   Käytä **eri portteja** kuin nykyinen systemd-prosessi (esim. systemd 3000, Docker 13000) `deploy/docker-compose.yml`:ssä.

4. **Vie ympäristömuuttujat:**
   ```bash
   sudo systemctl cat <company>.service | grep -E '^(Environment|EnvironmentFile)'
   # Kopioi arvot /srv/<company>/prod/.env -tiedostoon
   ```

5. **Push & deploy** — uusi compose-stack käynnistyy eri portissa, ei häiritse systemd:tä:
   ```bash
   git push origin main
   gh run watch
   ```

6. **Smoke-testi** uutta porttia vasten:
   ```bash
   curl http://paperclip-01.rk9.fi:13000/api/health
   ```

7. **Cutover** (DNS / reverse proxy / portti):
   - Päivitä nginx (nginx.rk9.fi) reitittämään uuteen porttiin
   - **TAI** vaihda compose-tiedostossa porttia 3000:ksi ja restart, samalla `systemctl stop <company>.service`
   - Validoi `curl https://<company>.rk9.fi/api/health`

8. **Vanha systemd talteen 2 viikoksi:**
   ```bash
   sudo systemctl disable <company>.service
   # ÄLÄ poista .service-tiedostoa! Voi tarvita rollbackiin.
   ```

9. **Datan migrointi**: jos nykyinen yksikkö käyttää bind-mounttia (esim. `/var/lib/<company>`), siirrä `/srv/<company>/prod/data/`:hen ja päivitä `docker-compose.yml`:n `volumes:`-osio.

10. **2 vk seuranta**: jos ei rollback-tarpeita, poista vanha systemd-yksikkö (`sudo rm /etc/systemd/system/<company>.service && sudo systemctl daemon-reload`).

## Rollback-polku

Jos uusi compose-stack on rikki:
```bash
ssh deploy@paperclip-01.rk9.fi
docker compose -f /srv/<company>/prod/docker-compose.yml down
sudo systemctl start <company>.service
```
Vanha yksikkö pysyy disabloituna mutta käynnistettävissä.

## Yritysspesifejä huomioita

- **alli-audit**: LUKS-mount `/mnt/a11y-data` säilyy host-tasolla, `volumes:` viittaa siihen
- **bk/ololla**: kaksi kontainer-imagea (backend + frontend), erilliset workflow-jobit
- **quantimodo**: treidisignaalit pois päältä → vapaa restart-ikkuna
