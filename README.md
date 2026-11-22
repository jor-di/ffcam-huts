# Refuges FFCAM — disponibilités

Carte des places libres dans une partie des refuges CAF pour le
prochain week-end, mise à jour automatiquement.

Carte : https://dernierecouchette.fr/

## Fonctionnement

| Script | Rôle | Quand |
|---|---|---|
| `rb/refresh_huts.rb` | liste des refuges et leur site → `huts.json` | de temps en temps |
| `rb/refresh_coordinates.rb` | GPS (OpenStreetMap) → `hut_coordinates.json` | après `rb/refresh_huts.rb` |
| `rb/refresh_links.rb` | liens Camptocamp / Skitour → `hut_links.json` (clé Skitour dans `secrets.env`) | après `rb/refresh_coordinates.rb` |
| `rb/ffcam_availability.rb` | places libres ; historique (`history/`) seulement avec `--history` | automatique (GitHub Actions) |
| `rb/build_map.rb` | génère la carte (`map_template.html` → HTML) et la page `/releves/` | automatique |

Scripts Ruby (bibliothèque standard, version dans `.ruby-version`, Ruby 3.1 ou plus suffit),
à lancer depuis la racine : `rb/ffcam_availability.rb && rb/build_map.rb` (sans `--history`,
rien n'est écrit dans `history/`). Tests hors ligne : `tests/unit.sh && tests/check.sh`.
Détails : [HANDOVER.md](HANDOVER.md).

GitHub Actions (`.github/workflows/update.yml`) lance les tests puis la mise à jour toutes les
heures en saison (déc.–avr., juin–sept.), trois fois par jour sinon, et publie la carte sur GitHub Pages.

## Historique

Branche `data` (en local : `history/`, un worktree git). Une ligne par changement :
`fetched_at, hut_id, date, opening, free_beds, capacity` dans `availability_AAAA-MM.csv`.
L'état d'une nuit à un instant donné = la dernière ligne avant cet instant. Voir `rb/history.rb`.

Sources : FFCAM (centrale.ffcam.fr), OpenStreetMap, IGN, Camptocamp, Skitour.
