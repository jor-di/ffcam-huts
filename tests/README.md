# Tests : rejouer le pipeline hors ligne

Ce dossier permet de faire tourner **tout le pipeline** (`bin/refresh-huts` → `bin/refresh-coordinates` → `bin/refresh-links` → `bin/fetch-availability --history` → `bin/build-site`) sans réseau et avec une horloge fixe, puis de comparer les fichiers produits, octet par octet, à des sorties de référence. Ces références ont été produites par la version Python d'origine (supprimée depuis) : le code Ruby doit écrire exactement les mêmes fichiers.

```
tests/check.sh            # doit afficher PASS (« tests/check.sh ruby » marche aussi)
```

GitHub Actions lance `tests/unit.sh` puis `tests/check.sh` avant chaque relevé : un échec arrête le relevé avant l'historique et la publication.

## Tests unitaires

```
tests/unit.sh                 # tous les tests de tests/unit/ (minitest), quelques secondes
tests/unit.sh -n /polite/     # seulement les tests dont le nom correspond
```

Ils couvrent ce que les deux scénarios rejoués ne voient pas : nuits du week-end pour chaque jour de la semaine et autour des fins de mois et d'année, formats des fichiers (`Py.float_repr`, `Py.round`, `Py.dumps`, CSV aller-retour, entités HTML), modes de réservation (classes du calendrier FFCAM, règles Refuge Pro : délai de réservation, liste d'attente, `nextSeasonOpening`), calendrier WP Booking System (`test_wpbs.rb`, sur `unit/fixtures/wpbs_calendar.html`, une copie réduite de la vraie page de la Coire dont les jours ont été modifiés pour couvrir chaque cas : états de la légende, places, réservable sans places, complet, fermé, jours passés, passage décembre → janvier, plusieurs calendriers ou pages, page sans calendrier), dates Open System, `FetchLog.classify` et la rotation des relevés, détection des changements et oubli des nuits passées de l'historique, limiteur de politesse (2 requêtes simultanées et 0,3 s entre deux départs par site, pas de blocage avec 8 fils et une exception), erreurs HTTP, délais et redirections (petit serveur local), essais 2 s puis 4 s, erreurs de ligne de commande, et `bin/fetch-availability` qui n'écrit ni `history/` ni le journal des relevés sans `--history` (lancé sur une copie de `bin/` et `lib/` dans un dossier temporaire, avec un seul refuge sans requête). Ils n'utilisent ni le réseau ni les fichiers de données du dépôt (l'historique et le journal des relevés sont écrits dans un dossier temporaire) ; `unit.sh` retire `COUCHETTE_NOW`, `COUCHETTE_REPLAY_DIR` et `COUCHETTE_RECORD_DIR` de l'environnement. minitest est livré avec Ruby (gem fournie avec Ruby 4.0, chargeable sans Bundler).

## Contenu

| Chemin | Contenu |
| --- | --- |
| `fixtures/run1/` | toutes les réponses HTTP d'un pipeline complet, enregistrées le 22/11/2026 avec `COUCHETTE_NOW=2026-11-22T18:00:00` |
| `fixtures/run2/` | les réponses d'un second relevé (`fetch-availability` seul) avec `COUCHETTE_NOW=2026-11-23T09:00:00`, plus 2 erreurs ajoutées à la main (voir plus bas) |
| `golden/run1/`, `golden/run2/` | les sorties de référence, produites par la version Python d'origine en rejouant ces enregistrements |
| `golden/<run>/stderr/<script>.log` | la sortie d'erreur de chaque script (lignes de résumé), le dossier de travail remplacé par `<work>` ; pour information seulement |
| `check.sh` | rejoue les deux scénarios et compare |
| `unit.sh`, `unit/` | tests unitaires (minitest) ; `unit/fixtures/` : pages réduites qu'ils lisent |

## Variables d'environnement

Lues par `lib/http.rb` et `lib/clock.rb` ; sans elles, rien ne change en production.

| Variable | Effet |
| --- | --- |
| `COUCHETTE_NOW=2026-11-22T18:00:00` | heure locale (Paris) qui remplace « maintenant » partout : dates par défaut, nuits du week-end, `fetched_at`, `refreshed_at`, nuits passées oubliées par l'historique, règles Refuge Pro. Les durées mesurées (`seconds` de `fetch_log.json`) valent alors 0. |
| `COUCHETTE_RECORD_DIR=<dossier>` | vraies requêtes (limiteur de politesse actif) ; chaque réponse, ou échec, est enregistrée dans le dossier. Plusieurs scripts peuvent enregistrer dans le même dossier : l'index est complété. |
| `COUCHETTE_REPLAY_DIR=<dossier>` | aucun accès réseau : les réponses viennent du dossier ; pas de limiteur ni d'attente entre essais. Une requête absente arrête le script avec `ReplayMissing: no recorded response in <dossier> for GET <url>`. |

`check.sh` lance aussi les scripts avec `SKITOUR_API_KEY=replay-dummy-key` (sans clé, `bin/refresh-links` sauterait Skitour ; la clé n'entre pas dans l'identifiant d'une requête, donc n'importe quelle valeur convient), `TZ=Europe/Paris`, et sans `IGN_API_KEY`, `GITHUB_EVENT_NAME` ni `TRIGGER_SOURCE` (déclencheur « local », `ignKey` à `null`).

## Format des enregistrements

Un dossier par scénario, simple à relire depuis n'importe quel langage :

```
fixtures/run1/index.json         un objet JSON : identifiant -> description de la requête et de sa réponse
fixtures/run1/bodies/<id>.gz     corps de la réponse (octets tels que reçus), compressé en gzip
```

- **Identifiant** d'une requête : `sha1("<MÉTHODE>\n<URL>\n<CORPS>")` en hexadécimal, sur l'UTF-8 ; `<CORPS>` est le corps envoyé (formulaire encodé des POST de la centrale FFCAM, requête Overpass) ou une chaîne vide pour un GET. L'URL est exactement celle demandée (paramètres compris, dans le même ordre et le même encodage qu'à l'enregistrement : `Py.urlencode` reproduit celui de la version Python d'origine). **Les en-têtes n'en font pas partie** : la clé Skitour (en-tête `cle`) n'est ni dans l'identifiant ni dans les fichiers.
- **Entrée de l'index** :
  - réponse : `{"method", "url", "body" (corps envoyé ou null), "status", "final_url" (après redirections), "file": "bodies/<id>.gz"}` ;
  - échec : `{"method", "url", "body", "error": {"type": "TimeoutError", "message": "The read operation timed out"}}`. Au rejeu, la requête lève une exception de ce nom avec ce message : le texte `"<type>: <message>"` se retrouve tel quel dans le CSV et dans `fetch_log.json`. Les erreurs HTTP (404…) sont des échecs (`HTTPError`, `HTTP Error 404: Not Found`) ; ces noms et messages sont ceux de la version Python (`urllib`), gardés tels quels.
- Une même requête n'a qu'une réponse : à l'enregistrement, le dernier essai l'emporte (un échec suivi d'un succès donne le succès) ; au rejeu, chaque essai reçoit cette réponse (un échec est donc rejoué à chaque essai).
- Les corps sont stockés compressés (gzip niveau 9, sans date dans l'en-tête, donc un même corps donne le même fichier) : 81,7 Mo en clair, 13,7 Mo compressés. Pour en lire un : `zcat tests/fixtures/run1/bodies/<id>.gz`. Un corps sans `.gz` dans `file` est lu tel quel.
- Les scripts décodent ensuite les corps comme en production (UTF-8, caractères invalides remplacés, ou JSON).

## Les deux scénarios

| Scénario | Requêtes enregistrées | Taille |
| --- | --- | --- |
| run1 | 441 (439 réponses + 2 échecs Overpass : `overpass.kumi.systems` délai dépassé, `overpass.private.coffee` 504) | 7,8 Mo (45 Mo décompressés) |
| run2 | 172 (171 réponses dont 1 modifiée à la main, 1 échec ajouté à la main) | 5,9 Mo (36 Mo décompressés) |

À l'enregistrement de run1, `overpass-api.de` a d'abord répondu 502, puis a réussi au 2e tour : seul le succès est gardé, donc au rejeu le premier serveur répond tout de suite et les deux échecs enregistrés ne servent pas.

**run1** — pipeline complet, `COUCHETTE_NOW=2026-11-22T18:00:00` (un dimanche : nuit de ce soir + week-end suivant), dossier vide au départ sauf `catalog/manual/manual_huts.json`, `catalog/manual/coordinates_overrides.json` et les deux modèles HTML ; `history/` vide, donc l'historique écrit un état initial complet.

**run2** — `bin/fetch-availability --history` puis `bin/build-site`, `COUCHETTE_NOW=2026-11-23T09:00:00` (lundi), en partant des sorties de run1 (`catalog/huts.json`, `catalog/hut_coordinates.json`, `catalog/hut_links.json`, `history/`) : l'historique n'ajoute que les changements et oublie les nuits passées, `fetch_log.json` contient 2 relevés.

### Erreurs ajoutées à la main dans `fixtures/run2/`

Pour couvrir les chemins d'erreur de façon reproductible, deux réponses enregistrées ont été modifiées après l'enregistrement :

1. **Open System, Refuge de la Leisse** (`OPRF-92948`), entrée `38f0474d2cc3316bbceb442a92d9681a4568c17c` (`GET https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=92948,2026-12-08`) : la réponse a été remplacée par un échec `{"type": "TimeoutError", "message": "The read operation timed out"}` (champs `status`, `final_url`, `file` retirés, fichier du corps supprimé). Résultat : `err` « TimeoutError: The read operation timed out ».
2. **Refuge Pro, Refuge du Galibier** (`RP-galibier`), entrée `0b908d7b921d297b04e0a5fed1254d2bc73a7b13` (`GET https://refuge-pro.com/embed/calendrier/galibier`) : dans le corps (décompressé, modifié, recompressé), `\"availability\":{` a été renommé `\"noAvailability\":{` (une seule occurrence) ; la page ne contient plus de données de places. Résultat : `err` « RuntimeError: no availability in the Refuge Pro calendar of galibier ».

Les deux refuges apparaissent donc en erreur dans le CSV (colonne `error`), dans `fetch_log.json` (`problems`, `last_success` inchangé pour eux) et sur `releves/index.html`, et l'historique n'enregistre rien pour eux.

Toute nouvelle réception de run2 doit refaire ces deux modifications.

### Réponse ajoutée après coup : le calendrier de la Coire

La page `GET https://www.refugedelacoire.fr/reservations-hiver/` (refuge `WPBS-coire`, entrée `c3721d0fc365cc4d11329c0a8e538d0e4a70c065`) a été enregistrée seule le 22/11/2026 au soir, puis copiée telle quelle dans les deux scénarios (même entrée d'index, même corps). Son calendrier montre novembre et décembre 2026 avec le 22/11 comme aujourd'hui : cohérent avec les horloges des deux scénarios (run2, le 23/11, ignore simplement le 22).

### Réponses ajoutées après coup : les refuges Open System hors Vanoise

Le Refuge du Goléon (`OPRF-130844`, Open System, ajouté dans `catalog/manual/manual_huts.json`) a trois réponses enregistrées seules le 24/11/2026 avec `Couchette.get_url` : son planning dans chaque scénario (`q=130844,2026-12-07` pour run1, entrée `95a190482a8e1715d56b2eb0bdb36ea25e15c8ef` ; `q=130844,2026-12-08` pour run2, entrée `1f65644dd685e295992a435d6d744b5e8beee640`) et la recherche Camptocamp autour du refuge pour `bin/refresh-links` (run1, entrée `af2d79220b34228cd7eaa2fd0903e9dbf58bf172`). Le refuge est fermé sur toute la fenêtre.

De la même façon, le 25/11/2026, pour les 19 autres refuges Open System ajoutés à la main (Fonts, Grenairon, Alfred Wills, Requin, Bostan, Ruitor, Glière, Pic du Mas de la Grave, Agnel, Furfande, Fonts de Cervières, la Cime, Basse Rua, la Blanche, Loge à Ponard, Rulhe, En Beys, Camporells, Sant Guillem) : 38 réponses dans run1 (planning `q=<n>,2026-12-07` et recherche Camptocamp de chacun), 19 dans run2 (planning `q=<n>,2026-12-08`). Seule la Glière est ouverte (12 places) ; les autres sont fermés sur la fenêtre.

Pour ajouter ainsi **une seule réponse** sans tout réenregistrer : l'enregistrer dans un dossier vide avec `COUCHETTE_RECORD_DIR` (dans une copie du projet, en appelant directement la méthode concernée), par exemple

```sh
W=/tmp/ffcam-one && rm -rf $W && mkdir -p $W && cp -r bin lib $W/
COUCHETTE_RECORD_DIR=$W/rec ruby -e 'require ARGV[0]; Couchette.fetch_wpbs_availability([{"url" => ARGV[1]}])' $W/lib/couchette.rb https://www.refugedelacoire.fr/reservations-hiver/
```

puis fusionner son `index.json` dans celui de chaque scénario (en le réécrivant avec le même format : `Py.dumps(index, ensure_ascii: false, indent: 1, sort_keys: true)` + saut de ligne) et copier `bodies/<id>.gz` ; enfin `tests/check.sh --update`, relire le diff de `golden/`, et `tests/check.sh`.

## Ce que compare `check.sh`

Pour chaque scénario, dans un dossier temporaire neuf : copie de `bin/`, `lib/`, de `.ruby-version` et des fichiers d'entrée, lancement des scripts dans l'ordre en mode rejeu (`fetch-availability` avec `--history`, qui écrit donc dans le `history/` du dossier temporaire), puis comparaison `diff -u` de **chaque fichier de `golden/<run>/`** (hors `stderr/`) avec le fichier du même nom produit : `PASS` / `FAIL` par fichier, code de sortie non nul à la moindre différence. Un fichier créé ou modifié par les scripts qui n'est pas dans `golden/` est aussi un échec. Fichiers comparés :

- run1 : `catalog/huts.json`, `catalog/hut_coordinates.json`, `catalog/hut_links.json`, `availability_2026-11-27.csv`, `history/state.json`, `history/availability_2026-11.csv`, `history/fetch_log.json`, `map.html`, `releves/index.html` ;
- run2 : `availability_2026-11-27.csv`, les trois fichiers de `history/`, `map.html`, `releves/index.html`.

La sortie d'erreur de chaque script est seulement signalée (`info … same` / `differs`), jamais en échec.

Les commandes sont en tête du script (`RUN`, `CODE`, `RUN1_STEPS`, `RUN2_STEPS`) : `bin/<script>`, lancé depuis le dossier de travail, où les scripts lisent et écrivent leurs fichiers (le parent de `bin/` et `lib/`). Options : `--keep` garde les dossiers de travail, `--update` réécrit `golden/` à partir du code Ruby (après un nouvel enregistrement, ou un changement voulu des sorties : relire alors le diff de `golden/`).

## Réenregistrer

À faire seulement si les sources changent de format ou si le code change ce qu'il demande. Toujours dans une **copie** du projet (pour ne pas écraser les JSON du dépôt ni toucher `history/`, worktree de la branche `data`) :

```sh
W=/tmp/ffcam-rec && rm -rf $W && mkdir -p $W
cp -r --parents bin lib .ruby-version templates catalog/manual $W/
ln -s "$PWD/secrets.env" $W/secrets.env          # pour la clé Skitour (refresh-links)
cd $W
export COUCHETTE_RECORD_DIR=$OLDPWD/tests/fixtures/run1 COUCHETTE_NOW=2026-11-22T18:00:00
rm -rf $COUCHETTE_RECORD_DIR
bin/refresh-huts && bin/refresh-coordinates && bin/refresh-links
rm secrets.env
bin/fetch-availability --history && bin/build-site   # history/ de $W (bin/ et lib/ sont copiés : jamais l'history/ du dépôt)
export COUCHETTE_RECORD_DIR=$OLDPWD/tests/fixtures/run2 COUCHETTE_NOW=2026-11-23T09:00:00
rm -rf $COUCHETTE_RECORD_DIR
bin/fetch-availability --history               # repart de l'history/ laissé par run1
cd - && tests/check.sh --update && tests/check.sh
```

Puis refaire les modifications à la main de run2 (avant `--update` ; pour un corps : `zcat`, modifier, `gzip -n -9`), et vérifier que la clé Skitour n'apparaît nulle part : `K=$(sed -n 's/^SKITOUR_API_KEY=//p' secrets.env); grep -rlF "$K" tests/; zgrep -lF "$K" tests/fixtures/*/bodies/*.gz` ne doit rien afficher. Overpass est souvent surchargé : `bin/refresh-coordinates` réessaie seul, parfois plusieurs minutes.
