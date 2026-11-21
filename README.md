# Refuges FFCAM — disponibilités

Carte des places libres dans une partie des refuges CAF pour le
prochain week-end, mise à jour automatiquement.

Carte : https://dernierecouchette.fr/

## Fonctionnement

| Script | Rôle | Quand |
|---|---|---|
| `refresh_huts.py` | liste des refuges et leur site → `huts.json` | de temps en temps |
| `refresh_coordinates.py` | GPS (OpenStreetMap) → `hut_coordinates.json` | après `refresh_huts.py` |
| `refresh_links.py` | liens Camptocamp / Skitour → `hut_links.json` (clé Skitour dans `secrets.env`) | après `refresh_coordinates.py` |
| `ffcam_availability.py` | places libres + historique (`history/`) | automatique (GitHub Actions) |
| `build_map.py` | génère la carte (`map_template.html` → HTML) | automatique |

GitHub Actions (`.github/workflows/update.yml`) lance la mise à jour toutes les heures en
saison (déc.–avr., juin–sept.), une fois par jour sinon, et publie la carte sur GitHub Pages.

## Historique

Branche `data` (en local : `history/`, un worktree git). Une ligne par changement :
`fetched_at, hut_id, date, opening, free_beds, capacity` dans `availability_AAAA-MM.csv`.
L'état d'une nuit à un instant donné = la dernière ligne avant cet instant. Voir `history.py`.

Sources : FFCAM (centrale.ffcam.fr), OpenStreetMap, IGN, Camptocamp, Skitour.
