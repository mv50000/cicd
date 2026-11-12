# Prod-jäädytyksen alkuperätarkistus (QUA-1509)

## Mitä tämä tekee

`actions/docker-build-push` ja `actions/ssh-deploy` ajavat ensimmäisenä askeleenaan skriptin `scripts/prod-freeze-provenance.sh`.

- Tarkistus on opt-in. Mukana on vain lista `COVERED_REPOS` skriptissä, nyt pelkkä `rk9-ai/quantimodo-rust` (repository id `1122181777`).
- Muissa repoissa askel tulostaa `skipped` ja päättyy. Se ei kutsu API:a eikä muuta mitään.
- Mukana olevassa repossa dev-kohde ohitetaan samoin. docker-build-pushissa kohde on `inputs.environment`. ssh-deployssa se päätellään `deploy_path`ista: viimeinen polun osa `dev` on dev, kaikki muu on prod (fail closed).
- Prod-kohteessa skripti lukee tämän ajon workflow-tiedoston (`github.workflow_ref` commitissa `github.workflow_sha`) contents API:sta. Tiedoston pitää kutsua repon omaa porttia `uses: ./.github/actions/prod-freeze-gate`. Muuten ajo kaatuu ennen buildia tai ennen kuin deploy-avain kirjoitetaan.
- Kaikki virheet prod-kohteessa kaatavat ajon: API ei vastaa (3 yritystä), token puuttuu, sha tai polku on virheellinen.

## Miksi

GitHub ajaa workflow'n siitä refistä, jolta ajo käynnistyy. Quantimodo vei jäädytysportin omiin workflow'ihinsa (QUA-1508, QUA-1510). Mikä tahansa ref, jonka workflow on porttia vanhempi, ajaa silti ilman porttia: vanha haara, vanhaan shahan pushattu v*-tagi tai ennen porttia tehdyn ajon uudelleenajo. Nämä vanhat workflowt kutsuvat `mv50000/cicd/actions/*@v1`-actioneita, ja action-tagi resolvoidaan vasta jobin alkaessa. Siksi tämä on ainoa paikka, jota vanha workflow ei voi ohittaa.

## Miksi ei lueta muuttujaa PROD_FREEZE_UNTIL

- Composite actionissa ei ole `vars`-kontekstia. Runnerin `action_yaml.json` sallii askelissa vain kontekstit `github`, `inputs`, `strategy`, `matrix`, `steps`, `job`, `runner` ja `env`.
- GITHUB_TOKENilla ei ole Variables-oikeutta, joten muuttujaa ei voi lukea myöskään API:sta.
- Vanhat workflowt kutsuvat actionia ilman uusia inputteja, joten arvoa ei voi välittää inputtina.

Tarkistus valvoo siksi alkuperää: vain porttia kutsuva workflow saa rakentaa tai deployata prodin. Portti on jo päättänyt jäädytyksestä samassa ajossa (se lukee muuttujan). Tämä on tiukempi kuin pelkkä jäädytys: porttia vanhempi ref ei pääse prodiin koskaan, ei myöskään jäädytyksen ulkopuolella.

## Mitä v1-tagin siirto vaikuttaa muihin repoihin

Tilanne 12.11.2026, oletushaarojen workflowt:

| Repo | Käyttää @v1 | Vaikutus |
|------|-------------|----------|
| rk9-ai/quantimodo-rust | suoraan: `setup-toolchain`, `docker-build-push`, `wait-for-health` | Prod-build vaatii portin. Nykyinen master (`fd041b62`) ja `release/prod-hotfix-20261106` (`30fd1854`) läpäisevät, tarkistettu oikeaa API:a vasten. Dev ohitetaan. |
| rk9-ai/bk, rk9-ai/alli-audit, rk9-ai/uutisvertailu | sisäkkäin: `build-and-deploy.yml@v2` kutsuu `actions/*@v1` | Yksi uusi askel, joka tulostaa `skipped`. Ei API-kutsua. |
| rk9-ai/saatavilla, rk9-ai/sunspot | `@v4` tai pinnattu sha | Ei vaikutusta. `@v4` kutsuu sisäkkäin `@v4`:ää. |
| rk9-ai/liigaveikkaus, rk9-ai/onni-ja-alma, mv50000/paperclip | vain `secret-scan.yml@main` | Ei vaikutusta. |

Saman repon vanhat haarat käyttävät samoja actioneita, ja niissäkin muut repot ohitetaan.

## Julkaisu (orkestroija tai operaattori)

`v1` ei ole mainissa. Se on oma linjansa (`599d717` = d75cdbe + RK9-503). Tämä muutos tehdään haaraan `release/v1`, joka alkaa nykyisestä v1-commitista. Mergen jälkeen:

```bash
git fetch origin release/v1
git tag -fa v1 origin/release/v1 -m "v1 + QUA-1509 prod freeze provenance (prev 599d717)"
git push -f origin v1
```

Paluu: `git tag -fa v1 599d7173ca78b4371ac9d170e1938f0725276a2b -m "revert QUA-1509"` ja force-push.

Testit: `bash scripts/test-prod-freeze-provenance.sh` (curl on stubattu, ei verkkoa).

## Rajoitukset

- Tarkistus katsoo, että workflow-tiedosto kutsuu porttia. Se ei todista, että portti on kytketty oikein. Kytkennän testaa quantimodon oma `scripts/test_prod_freeze_check.sh`.
- Uudelleenajo, joka ajaa vain jobin ilman cicd-actionia ennen hostiin koskemista, ohittaa tarkistuksen. Quantimodossa tällainen on porttia vanhempi `deploy`-job (`238d1569`–`62e1a853`), joka käyttää repon omaa `app-deploy`-actionia. Sen voi uudelleenajaa 30 päivän ajan alkuperäisestä ajosta.
- `setup-toolchain` ja `wait-for-health` eivät tarkista mitään. setup-toolchainilla ei ole kohdetietoa, ja wait-for-health ajetaan vasta deployn jälkeen.
- Workflowt, jotka eivät käytä cicd-actioneita (quantimodon server-ops, server-admin ja yöajot), eivät ole tämän piirissä.
