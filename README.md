# Refuges FFCAM — disponibilités

Carte des places libres dans une partie des refuges CAF pour le
prochain week-end, mise à jour automatiquement.

Carte : https://dernierecouchette.fr/

## Fonctionnement

| Script | Rôle | Quand |
|---|---|---|
| `bin/refresh-huts` | liste des refuges et leur site → `catalog/huts.json` | de temps en temps |
| `bin/refresh-coordinates` | GPS (OpenStreetMap) → `catalog/hut_coordinates.json` | après `bin/refresh-huts` |
| `bin/refresh-links` | liens Camptocamp / Skitour → `catalog/hut_links.json` (clé Skitour dans `secrets.env`) | après `bin/refresh-coordinates` |
| `bin/fetch-availability` | places libres ; historique (`history/`) seulement avec `--history` | automatique (GitHub Actions) |
| `bin/build-site` | génère la carte (`templates/map.html` → HTML), la page `/releves/` et la page `/a-propos/` | automatique |
| `bin/check-links` | vérifie les liens « Site du refuge » / « ⚡ Résa » des fiches ; issue GitHub (mail) si un lien casse | chaque semaine (GitHub Actions) |
| `bin/check-fetch-alerts` | issue GitHub (mail) quand un refuge échoue 10 relevés de suite | après chaque relevé |
| `bin/protect-site` | chiffre les pages publiées : accès par prénom + mot de passe (secret `SITE_USERS`) | automatique |

Scripts Ruby (bibliothèque standard, version dans `.ruby-version`, Ruby 3.1 ou plus suffit),
à lancer depuis la racine : `bin/fetch-availability && bin/build-site` (sans `--history`,
rien n'est écrit dans `history/`). Tests hors ligne : `tests/unit.sh && tests/check.sh`.
Détails : [HANDOVER.md](HANDOVER.md).

GitHub Actions (`.github/workflows/update.yml`), lancé par cron-job.org, fait passer les tests puis la mise à jour
toutes les heures de décembre à avril (sauf la nuit), une fois par jour (7h07) de mai à novembre, et publie la carte sur GitHub Pages. L'accès demande un prénom et un mot de passe (voir
[HANDOVER.md](HANDOVER.md#accès-prénom--mot-de-passe)).

## Historique

Branche `data` (en local : `history/`, un worktree git). Une ligne par changement :
`fetched_at, hut_id, date, opening, free_beds, capacity` dans `availability_AAAA-MM.csv`.
L'état d'une nuit à un instant donné = la dernière ligne avant cet instant. Voir `lib/history.rb`.

Sources : FFCAM (centrale.ffcam.fr), OpenStreetMap, IGN, Camptocamp, Skitour.
