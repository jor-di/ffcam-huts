# Dernière couchette — handover

_État au 21/11/2026._

Dernière couchette est une carte des places libres dans les refuges de montagne pour le week-end en cours, en ligne sur [dernierecouchette.fr](https://dernierecouchette.fr/) et mise à jour automatiquement par GitHub Actions.

- **Couverture** : 154 refuges, venant de 4 systèmes de réservation (centrale FFCAM, Open System, Refuge Pro) ou ajoutés à la main ; détail par refuge en [annexe](#annexe--source-de-chaque-refuge).
- **Code** : Python standard sans dépendance + une page HTML Leaflet.
- **Fréquence** : toutes les heures en saison (déc.–avr., juin–sept.), une fois par jour sinon.
- **Historique** : chaque changement de places est conservé sur la branche `data`, pour de futures analyses (pas encore affiché).

## Sommaire

- [Architecture](#architecture)
- [Sources de données](#sources-de-données)
- [Récupérer les disponibilités : les requêtes](#récupérer-les-disponibilités--les-requêtes)
- [La carte](#la-carte)
- [Historique des disponibilités](#historique-des-disponibilités)
- [Mise en ligne](#mise-en-ligne)
- [Opérations courantes](#opérations-courantes)
- [Pièges connus et décisions](#pièges-connus-et-décisions)
- [Annexe : source de chaque refuge](#annexe--source-de-chaque-refuge)

## Architecture

Deux rythmes : trois scripts « de référence » lancés à la main de temps en temps, et deux scripts lancés automatiquement à chaque relevé.

```mermaid
flowchart LR
  subgraph local["De temps en temps, en local (résultats commités sur main)"]
    huts["refresh_huts.py<br/>centrale FFCAM (4 portails) + Open System + manual_huts.json<br/>→ huts.json"]
    coords["refresh_coordinates.py<br/>OpenStreetMap + corrections<br/>→ hut_coordinates.json"]
    links["refresh_links.py<br/>Camptocamp + Skitour<br/>→ hut_links.json"]
    huts --> coords --> links
  end
  subgraph auto["Automatique, GitHub Actions"]
    avail["ffcam_availability.py<br/>1 requête par refuge<br/>→ latest.csv + history.py"]
    build["build_map.py<br/>map_template.html + données<br/>→ site/index.html"]
    avail -- CSV --> build
  end
  huts -- liste des refuges --> avail
  coords -- GPS --> build
  links -- liens --> build
  avail -- commit si changement --> data[("branche data<br/>historique")]
  build -- déploiement --> pages(["GitHub Pages<br/>dernierecouchette.fr"])
```

`ffcam.py` contient le code partagé (requêtes, portails, Open System) et `history.py` l'enregistrement de l'historique.

| Fichier | Contenu | Produit par | Versionné |
| --- | --- | --- | --- |
| `huts.json` | 154 refuges : id, nom, type, portail, site | `refresh_huts.py` | oui (main) |
| `hut_coordinates.json` | GPS, altitude, id OSM, site OSM | `refresh_coordinates.py` | oui (main) |
| `coordinates_overrides.json` | 6 corrections GPS faites à la main | à la main | oui (main) |
| `manual_huts.json` | refuges ajoutés à la main : position, site, téléphone, email, et `refugepro` (slug du calendrier) s'ils en ont un | à la main | oui (main) |
| `hut_links.json` | liens Camptocamp et Skitour | `refresh_links.py` | oui (main) |
| `map_template.html` | la carte (HTML, CSS, JS Leaflet) | à la main | oui (main) |
| `history/` | historique des places + `fetch_log.json` (journal des relevés) | `ffcam_availability.py` | oui (branche `data`) |
| `log_template.html` | page de suivi des relevés | à la main | oui (main) |
| `secrets.env` | clé Skitour (et IGN éventuelle) | à la main | **jamais** |
| `ffcam_*.csv`, `map.html`, `releves/`, `data/`, `site/` | sorties générées | scripts | non (`.gitignore`) |
| `deploy/` | plan B VPS OVH + nginx + certbot | — | oui, jamais utilisé |

## Sources de données

Les places viennent de trois systèmes de réservation, lus là où les refuges les publient eux-mêmes, sans clé ; le reste (GPS, liens, fonds de carte) vient de services ouverts.

| Source | Ce qu'on en tire | Accès | Particularités |
| --- | --- | --- | --- |
| [Centrale FFCAM](https://centrale.ffcam.fr/index.php) | liste des refuges + places par nuit | sans clé | voir [les requêtes](#1-centrale-ffcam-portails-ffcam-vanoise-neouvielle-boreon) |
| Portails de la centrale (`apporigin`) | refuges hors liste FFCAM | sans clé | FFCAM (115), VANOISE (+9), NEOUVIELLE (+3), BOREON (+1). Disponibles non utilisés : ENTREPYRPYRENEES (52, Espagne/Andorre), ITFFCAM (tout + Maroc). |
| Open System (Alliance Réseaux) | 12 refuges du Parc de la Vanoise (Leisse, Fond des Fours…) | sans clé | voir [les requêtes](#2-open-system-12-refuges-du-parc-de-la-vanoise-portal--opensystem). **Pas de capacité.** |
| [Refuge Pro](https://refuge-pro.com) | 11 refuges privés (Clarée, Vallée Étroite, Galibier, Maurienne…) : places, capacité, liste d'attente | sans clé | Calendrier « embed » que chaque refuge intègre à son site ; voir [les requêtes](#3-refuge-pro-11-refuges-portal--refugepro). ~1 an de nuits. |
| OpenStreetMap (Overpass) | GPS, altitude, site web | sans clé | Souvent surchargé : le script essaie 3 serveurs et réessaie (jusqu'à plusieurs minutes). Appariement par site `*.ffcam.fr`, puis par nom, puis corrections manuelles. |
| Nominatim (OSM) | recherche ponctuelle d'un refuge introuvable | sans clé | Utilisé à la main pour remplir `coordinates_overrides.json`. |
| [Camptocamp](https://www.camptocamp.org) | lien fiche refuge | API publique | Recherche dans un rayon de 1,5 km, acceptée si < 400 m ou nom proche. 150/154 trouvés. |
| [Skitour](https://skitour.fr/api/) | lien fiche refuge | clé perso (gratuite, 1000 req/j) | `GET /api/refuges` avec en-tête `cle`. 125/154 trouvés. Les conditions demandent un lien vers skitour.fr. |
| IGN Géoplateforme | fonds Plan IGN, traces ski de rando | sans clé | Couche `TRACES.RANDO.HIVERNALE` (rouge, recolorée en bleu en CSS). SCAN 25 = clé privée : code prêt, jamais testé. |
| Esri, OpenTopoMap, OSM France | fonds de carte | sans clé | `tile.openstreetmap.org` refuse les pages sans `Referer` (fichier local) : on utilise OSM France. CARTO exige désormais une clé : abandonné. |

## Récupérer les disponibilités : les requêtes

Trois systèmes, un appel par refuge et par relevé, choisi selon le champ `portal` du refuge dans `huts.json` (code : `fetch_availability()` dans `ffcam.py`). Aucun ne demande de clé ni de cookie.

### 1. Centrale FFCAM (portails FFCAM, VANOISE, NEOUVIELLE, BOREON)

**Liste des refuges d'un portail** — GET, une fois par portail :

```
GET https://centrale.ffcam.fr/index.php?mode=FORM&_lang=FR&init=1&apporigin=FFCAM
```

La page HTML contient une ligne `structuresList = {"BK_STRUCTURE:85": {...}, ...};` (extraite par regex puis JSON) : `name`, `shortName`, `structureType`, `email` obfusqué, `maxPax`, `maxDays`, `bookingDelay`, `productsCategories`. Remplacer `apporigin` pour un autre portail ; un refuge présent dans plusieurs portails est gardé avec le premier de la liste.

**Places d'un refuge** — POST, formulaire :

```
POST https://centrale.ffcam.fr/index.php?
action=availability
apporigin=FFCAM            # un portail qui liste ce refuge
structure=BK_STRUCTURE:22
productCategory=nomatter   # tous types d'hébergement confondus
pax=1
date=2026-11-21            # aujourd'hui par défaut
```

La réponse est la page HTML du calendrier ; on en extrait trois objets JS (une ligne chacun) :

```
BK.availability      = {"2026-11-21": 24, ...}         # places libres
BK.totalAvailability = {"2026-11-21": 24, ...}         # capacité de la nuit
BK.openingCalendar   = {"2026-11-21": "OPEN", ...}     # OPEN | CLOSE | UNGUARDED | UNKNOW
```

- Couverture : le mois de `date` et le mois suivant, en entier. Pour un refuge pas encore réservable, le serveur décale souvent ces deux mois vers ses premières dates réservables.
- Demander avec un `apporigin` qui ne liste pas le refuge renvoie des données vides ou incohérentes : d'où le champ `portal`.
- Réservable = `opening == OPEN` et places > 0.

### 2. Open System (12 refuges du Parc de la Vanoise, `portal = OPENSYSTEM`)

**Découverte des refuges** (dans `refresh_huts.py`) : la page d'accueil de [refuge-leisse.vanoise.com](https://refuge-leisse.vanoise.com/) liste les autres refuges du Parc (`https://refuge-xxx.vanoise.com`). Sur chaque site, le widget de réservation porte l'id produit :

```
AllianceReseaux.Widget.Instance("Produit", { idPanier: "AGwCAAA", idIntegration: "1110", ui: "OPRF-92948" })
```

Pas d'`OPRF` sur la page = refuge qui réserve via la centrale FFCAM (Arpont, Orgère, Valette) : ignoré ici. L'id stocké dans `huts.json` est `OPRF-92948`.

**Places d'un refuge** — GET, réponse JSONP (le paramètre `callback` est facultatif) :

```
GET https://etape-rest.for-system.com/index.aspx/index.aspx?ref=json-planning-refuge&q=92948,2027-03-07

([{"id":92948,"datemini":"2026-11-24",
   "planning":[{"s":0,"f":1,"d":15}, ..., {"s":25,"f":0,"d":0}, ..., {"s":32,"f":0,"d":-14}]}])
```

- `planning` = 30 jours, **de q−15 à q+14** (q = la date demandée), du plus ancien au plus récent.
- Le jour d'une entrée = **q − d** (`d` = jours *avant* q : 15 pour le premier, 0 pour q, −14 pour le dernier).
- `s` = places libres ; `f` = 1 si fermé ; `datemini` = première date réservable. **Aucune capacité** : la carte affiche « N places » sans total.
- Le script demande q = aujourd'hui + 15, pour couvrir d'aujourd'hui à J+29 (les deux week-ends affichés y sont toujours).
- Vérifié sur la Leisse : fermé le 19/02/2027, ouvert le 20/02 avec 25 places, comme annoncé sur son site.

### Format commun en sortie

Les deux fonctions renvoient le même dictionnaire, ce qui permet au reste (CSV, historique, carte) de ne pas distinguer les systèmes :

```
{"free": {"2026-11-21": 24, ...}, "capacity": {"2026-11-21": 24 ou None, ...}, "opening": {"2026-11-21": "OPEN", ...}}
```

Pour ajouter un nouveau système : une fonction qui renvoie ce dictionnaire, un `portal` dédié dans `huts.json`, et une branche dans `fetch_availability()`.

### Mode de réservation d'une nuit (`booking`)

La centrale FFCAM dit aussi, nuit par nuit, **comment** réserver, via les classes CSS des cases du calendrier renvoyé (`<div class="day …"><a data-date="2026-12-12" …>`, lu par `booking_modes()`) :

| Classe de la case | `booking` | Signification |
| --- | --- | --- |
| `day dispo` | `online` | réservable en ligne |
| `day complet waitinglistday` | `waitlist` | complet, inscription en liste d'attente possible |
| `day completWeb completWebInfo` | `phone` | plus vendu en ligne (souvent ce soir, après le délai de réservation) : « Réserver par téléphone / mail » |

Refuge Pro fournit l'équivalent (voir plus bas). Les refuges `MANUAL` ne sont pas interrogés : toutes leurs nuits valent `request`. Open System ne fournit pas cette information.

### 3. Refuge Pro (11 refuges, `portal = REFUGEPRO`)

Refuge Pro est le logiciel de réservation que ces refuges utilisent ; il fournit un calendrier à intégrer dans le site du refuge. On lit cette page « embed » (pas la vitrine tierce refuge.camp, ni son API) :

```
GET https://refuge-pro.com/embed/calendrier/refuge-de-terre-rouge
```

C'est une page Next.js : ses données sont dans des blocs `self.__next_f.push([1,"…"])`. Une fois concaténés et décodés, on y trouve un objet JSON `"availability": {…}` (lu avec `json.JSONDecoder().raw_decode`) :

```
{"defaultCapacity":35, "bookingCutoffDays":1, "waitlistEnabled":true,
 "nextSeasonOpening":{"premiereNuit":"2027-06-12","ouvreLe":"2027-01-15"},
 "openingRanges":[{"from":"2027-01-09","to":"2027-04-10"}, …],
 "data":[{"date":"2027-01-23","capacity":35,"booked":35,"free":0,"status":"open","isFull":true}, …]}
```

- `data` couvre **environ un an** (346 nuits), avec capacité, réservé et libre par nuit.
- `booking` : complet + `waitlistEnabled` → `waitlist` ; nuit avant aujourd'hui + `bookingCutoffDays`, ou au-delà de `premiereNuit` tant que `ouvreLe` n'est pas passé → `phone` (places mises à 0) ; sinon `online`.
- Le slug est l'adresse du calendrier ; il est noté dans `manual_huts.json` (champ `refugepro`). Il n'y a pas de liste publique des refuges Refuge Pro : les 11 slugs ont été trouvés en essayant le nom du refuge (`chardonnet`, `refuge-du-clot-des-vaches`…) ; une page inexistante répond 404.
- La page donne aussi le téléphone du refuge (`telephoneRefuge`) mais **pas sa position** : position et altitude viennent d'OpenStreetMap (Nominatim), notées dans `manual_huts.json`.
- Lien principal sur la carte = ce calendrier (bouton « Réserver ») ; le site propre du refuge, quand il existe, est dans le champ `website`.
- **Pas de vitrine tierce** : ces refuges sont aussi vendus sur refuge.camp (même éditeur), qu'on n'utilise pas ; on lit le calendrier du refuge.

### 4. Refuges sans réservation en ligne lisible (`portal = MANUAL`)

Coire, Nant du Beurre, Selle : ajoutés à la main dans `manual_huts.json`, avec position (refuges.info), site, téléphone et email pris sur leur propre site. Pas de requête : toutes leurs nuits valent `request`.

## La carte

Une seule page HTML (`map_template.html` + les données injectées par `build_map.py`), Leaflet 1.9.4, sans serveur, design « Crêtes » : billets de couchette en papier crème, vert sapin, thème clair uniquement.

**Panneau de gauche** (feuille glissante en bas sur téléphone)

- En-tête : logo (lits superposés + étoile), titre, date de mise à jour, ligne de crêtes.
- Carrousel de nuits en billets : nuit choisie centrée, voisines à moitié visibles, samedi par défaut ; clic, flèches ← →, glissement au doigt.
- Chiffres clés (réservables, places, complets) : **limités au cadre de la carte**.
- Filtres : minimum de places, « Afficher les fermés » (complets + fermés), types Gardé / Non gardé / Autre (avec icônes ; clic sur un type quand tous sont actifs = ne garder que lui), recherche sans accents (un nom trouve le refuge même fermé ou hors du cadre).
- Liste des refuges **dans le cadre de la carte**, en petits billets ; clic = la carte vole au refuge.

**Carte**

- Marqueurs en talons de billet (places + pastille vert / orange / rouge), fermés = point gris.
- Fiche refuge : type, altitude, max par résa, une ligne par nuit, boutons Fiche FFCAM / Site du refuge / Réserver, Camptocamp, Skitour.
- Fonds : Topo clair Esri (défaut), OpenTopoMap, satellite Esri, Plan IGN, OSM France ; calque « Traces ski de rando (IGN) » ; SCAN 25 si clé IGN.
- Vue de départ : Alpes, du Léman aux Hautes-Alpes.

**Nuits affichées** : lundi–vendredi = vendredi, samedi, dimanche à venir ; samedi = ce soir + dimanche ; dimanche = ce soir ; bascule au week-end suivant le lundi.

**Mode caché « Avant-dernière couchette »** : clic sur le logo (ou `#avant-derniere` dans l'URL) = week-end suivant, en-tête teinté crépuscule, étoile retournée. Les données sont déjà dans la page (5 nuits par refuge le samedi).

**Téléphone** : tout le panneau défile d'un bloc avec un bandeau collant (titre + billets compacts), filtres repliés derrière « Filtres · n actifs », panneau jusqu'à 90 % de l'écran. Testé en simulation seulement, pas au doigt.

**Refuges sans capacité connue** (Open System) : affichés « 25 places » au lieu de « 25 / 32 ».

**Catégorie « Sur demande »** (violet, affichée par défaut avec les réservables) : nuits FFCAM en liste d'attente (marqueur `…`) ou à réserver par téléphone / mail (`☎`), et refuges de `manual_huts.json` (`☎`). La fiche donne le téléphone et l'email quand on les connaît. Les chiffres clés comptent « réservables / places / sur demande » ; les vrais complets et les fermés restent derrière « Afficher les fermés ».

## Suivi des relevés (`/releves/`)

Une page publique, [dernierecouchette.fr/releves/](https://dernierecouchette.fr/releves/) (lien sur la date de mise à jour de la carte), dit si la récupération des places s'est bien passée pour chaque refuge au dernier relevé.

- **Production** : à chaque relevé, `ffcam_availability.py` appelle `fetch_log.record()` (module `fetch_log.py`), qui classe chaque refuge et met à jour `history/fetch_log.json` sur la branche `data`. `build_map.py` génère ensuite la page à partir de `log_template.html`, dans `releves/index.html` à côté de la carte (`site/releves/` en ligne).
- **États** : `ok` (nuits reçues ; une remarque si aucun calendrier d'ouverture n'est publié, normal pour un refuge fermé), `warn` « à vérifier » (réponse sans aucune nuit : souvent un changement de format), `err` (requête en échec : délai, erreur HTTP, page sans données ; le message de l'exception est gardé), `skip` « non relevé » (refuges `MANUAL`).
- **`fetch_log.json`** : `last_run` (le dernier relevé, une entrée par refuge : état, nuits reçues, durée, message), `runs` (les 48 derniers relevés résumés par source, avec la liste des refuges en problème), `last_success` (dernier relevé réussi par refuge). Le déclencheur vient de `GITHUB_EVENT_NAME` (planifié, push, manuel) ou vaut « local ».
- **Page** : le dernier relevé (durée, nombre de requêtes, déclencheur, résumé), un billet par source (refuges sans erreur / total, 24 derniers relevés en barres, durée cumulée, dernier succès), puis le tableau des refuges filtrable (À traiter, Erreurs, Remarques, Non relevés, Tous) avec recherche.
- **Effet de bord** : ce fichier change à chaque relevé, donc la branche `data` reçoit un commit par relevé (et non plus seulement en cas de changement de places).
- En local, `--no-history` n'écrit pas non plus le journal ; `--log <fichier>` permet de l'écrire ailleurs pour tester.

## Historique des disponibilités

Chaque relevé ajoute une ligne par changement de places, pour toutes les nuits à venir renvoyées (pas seulement le week-end) ; rien n'est encore affiché sur la carte.

- **Où** : branche `data` du dépôt ; en local, le dossier `history/` est un worktree git de cette branche.
- **Fichiers** : `availability_AAAA-MM.csv` (un par mois de relevé) et `state.json` (dernier état connu par refuge/nuit, une ligne par clé pour des diffs git légers ; les nuits passées en sont retirées).
- **Colonnes** : `fetched_at, hut_id, date, opening, free_beds, capacity` (heure de Paris).
- **Lire** : l'état d'une nuit à un instant = la dernière ligne avant cet instant pour ce `hut_id` et cette `date`.
- **Volume** : état initial 5 084 lignes (308 Ko) le 21/11/2026 ; ensuite quelques dizaines à centaines de lignes par jour attendues en saison (à confirmer).

**Limites**

- Fenêtre suivie : d'aujourd'hui à la fin du mois suivant (FFCAM) ou 30 jours (Open System). Les réservations plus lointaines ne sont vues qu'en entrant dans la fenêtre ; une 2e requête par refuge l'élargirait mais a été écartée (charge x2).
- FFCAM décale parfois la fenêtre vers les premières dates réservables d'un refuge : des nuits lointaines (jusqu'en juillet) apparaissent pour certains.
- Une requête en erreur n'enregistre rien (pas de faux « 0 place »).
- Relancer `ffcam_availability.py` en local sans `git pull` dans `history/` fait diverger l'historique : utiliser `--no-history` pour les tests.

## Mise en ligne

Le site est publié par GitHub Actions sur GitHub Pages, derrière le domaine dernierecouchette.fr acheté chez OVH, en HTTPS.

| Élément | Réglage |
| --- | --- |
| Dépôt | `jor-di/ffcam-huts`, public, branche par défaut `main` (obligatoire pour les tâches planifiées et la publication Pages) |
| Tâche | `.github/workflows/update.yml` : `7 * * 12,1-4,6-9 *` (saison) et `7 7 * 5,10,11 *` (hors saison), heures UTC ; aussi à chaque push sur `main` et via « Run workflow » ; `TZ=Europe/Paris` |
| Étapes | checkout `main` + checkout `data` dans `history/` → `ffcam_availability.py` → `build_map.py` → commit de `history/` si changement → déploiement Pages |
| Pages | Settings → Pages → Source = GitHub Actions ; Custom domain = `dernierecouchette.fr` ; « Enforce HTTPS » à cocher une fois le certificat prêt |
| DNS (OVH) | 4 × A `@` → `185.199.108-111.153`, 4 × AAAA `@` → `2606:50c0:8000-8003::153`, CNAME `www` → `jor-di.github.io.`, TXT `_github-pages-challenge-jor-di` (domaine vérifié) ; NS, MX et SPF d'origine conservés |
| Compte | GitHub perso `jor-di` ; sur la machine, clé SSH dédiée `~/.ssh/id_ed25519_github_perso` via l'alias `github-perso` ; identité perso automatique sous `~/code/perso/` (`includeIf`) ; le compte pro reste en HTTPS via `gh` |
| Secrets | `secrets.env` (local, `chmod 600`, ignoré par git) : `SKITOUR_API_KEY`, `IGN_API_KEY` (vide). Le workflow n'en a pas besoin. |

## Opérations courantes

Au quotidien il n'y a rien à faire : la tâche planifiée relève et publie seule. Les commandes se lancent à la racine du dépôt.

| Quand | Commande | Notes |
| --- | --- | --- |
| Modifier le code ou la carte | éditer, puis `git commit` + `git push` | le push relance un relevé et republie |
| Voir le résultat en local | `./ffcam_availability.py --no-history && ./build_map.py && xdg-open map.html` | `--no-history` évite de diverger de l'historique en ligne |
| Forcer une mise à jour en ligne | onglet Actions → « Update availability » → Run workflow | |
| Rafraîchir la liste des refuges (quelques fois par an) | `./refresh_huts.py && ./refresh_coordinates.py && ./refresh_links.py`, puis commit + push des JSON | Overpass peut prendre plusieurs minutes ; la clé Skitour est lue dans `secrets.env` |
| Un refuge n'a pas de GPS | ajouter une entrée dans `coordinates_overrides.json` (via Nominatim), relancer `refresh_coordinates.py` | 6 corrections aujourd'hui |
| Ajouter un refuge Refuge Pro | trouver le slug (`https://refuge-pro.com/embed/calendrier/<nom>` doit répondre), l'ajouter dans `manual_huts.json` avec `refugepro`, position (Nominatim) et téléphone (`telephoneRefuge` de la page), puis `./refresh_huts.py && ./refresh_links.py` | voir l'annexe |
| Ajouter un refuge réservable seulement par téléphone | entrée dans `manual_huts.json` sans `refugepro` (position, site, téléphone, email) | |
| Ajouter un portail de la centrale | `./refresh_huts.py --portals FFCAM VANOISE NEOUVIELLE BOREON OPENSYSTEM ENTREPYRPYRENEES` | ou modifier `DEFAULT_PORTALS` dans `ffcam.py` |
| Récupérer l'historique | `git pull` dans `history/` | avant tout relevé local avec historique |
| Tester une autre date | `./ffcam_availability.py --date 2027-02-20 --nights 2 --no-history` | |
| Ajouter la couche IGN SCAN 25 | remplir `IGN_API_KEY` dans `secrets.env`, puis `./build_map.py` | la clé finit en clair dans la page publiée |

## Pièges connus et décisions

**Pièges**

- Un refuge peut avoir des places libres et être fermé (`CLOSE`) : « réservable » = `OPEN` **et** places > 0.
- Les « Non Gardé » sont des entrées séparées de leur refuge gardé (salle hors-sac) ; en hiver ce sont presque les seuls réservables.
- Les emails des refuges sont obfusqués (`name<a></a><ff></ff>…`) : seule la partie avant @ est fiable ; elle donne le site `name.ffcam.fr`.
- Les tâches planifiées GitHub partent avec retard (minutes, parfois plus) et sont désactivées après 60 jours sans activité (les commits de données devraient suffire).
- Le dépôt peut être modifié directement sur GitHub (ça a été le cas du README) : faire `git pull --rebase` avant de pousser.
- Le Ratou n'a ni site ni position exacte (panneau « Chalet du Ratou ») ; Averole et Orédon sont tagués autrement qu'en refuge dans OSM.

**Décisions**

- Pas de base de données : fichiers JSON/CSV versionnés ; une base hébergée seulement si on affiche l'historique de façon interactive.
- Hébergement GitHub Pages plutôt qu'un VPS (gratuit, sans maintenance) ; dépôt public accepté.
- Une seule requête par refuge et par relevé (charge FFCAM ~3 000 requêtes/jour en saison) ; pas de 2e requête pour voir plus loin.
- Clés : la clé d'exemple de la doc Skitour et les accès privés IGN n'ont pas été utilisés ; uniquement des clés personnelles.
- Les noms « FFCAM » / « CAF » sont évités dans le nom du site (marques de la fédération).

## Annexe : source de chaque refuge

Chaque refuge de `huts.json` a un champ `portal` qui dit d'où vient sa liste et comment ses places sont relevées. Les deux scripts concernés sont toujours `refresh_huts.py` (liste des refuges) puis `ffcam_availability.py` (places), qui appellent les fonctions de `ffcam.py` indiquées.

| `portal` | Refuges | Liste des refuges (dans `refresh_huts.py`) | Places (dans `ffcam_availability.py`) | Identifiant |
| --- | --- | --- | --- | --- |
| `FFCAM` | 115 | `fetch_huts()` : `structuresList` de la centrale, `apporigin=FFCAM` | `fetch_availability()` : POST `action=availability`, calendrier HTML | `BK_STRUCTURE:<n>` |
| `VANOISE` | 9 | idem, `apporigin=VANOISE` (refuges absents du portail FFCAM) | idem, `apporigin=VANOISE` | `BK_STRUCTURE:<n>` |
| `NEOUVIELLE` | 3 | idem, `apporigin=NEOUVIELLE` | idem | `BK_STRUCTURE:<n>` |
| `BOREON` | 1 | idem, `apporigin=BOREON` | idem | `BK_STRUCTURE:<n>` |
| `OPENSYSTEM` | 12 | `fetch_opensystem_huts()` : menu de refuge-leisse.vanoise.com + widget `OPRF` de chaque site | `fetch_opensystem_availability()` : JSONP `etape-rest.for-system.com` | `OPRF-<n>` |
| `REFUGEPRO` | 11 | `manual_huts.json` (entrées avec `refugepro`) | `fetch_refugepro_availability()` : page `refuge-pro.com/embed/calendrier/<slug>` | `RP-<slug>` |
| `MANUAL` | 3 | `manual_huts.json` (entrées sans `refugepro`) | aucune requête : nuits « sur demande » | `MANUAL-<nom>` |

Coordonnées : `refresh_coordinates.py` (OpenStreetMap, ou position donnée dans `manual_huts.json`, ou `coordinates_overrides.json`). Liens : `refresh_links.py` (Camptocamp, Skitour).

Les 115 refuges du portail FFCAM sont listés dans `huts.json` (nom, id, site `*.ffcam.fr`) et ne sont pas répétés ici. Tous les autres :

### Portail VANOISE de la centrale FFCAM (Parc national de la Vanoise)

| Refuge | Identifiant |
| --- | --- |
| Refuge Entre-Deux-Eaux | `BK_STRUCTURE:5h5skpilec4l` |
| Refuge de Plan Sec | `BK_STRUCTURE:5a1mymmzijik` |
| Refuge de l'Arpont | `BK_STRUCTURE:xxxld3htkpn` |
| Refuge de l'Orgère | `BK_STRUCTURE:5a1nrby5i831` |
| Refuge de la Fournache | `BK_STRUCTURE:5a1ngkc39duv` |
| Refuge de la Valette | `BK_STRUCTURE:5a1novae31ez` |
| Refuge du Roc | `BK_STRUCTURE:5a1njyztnljl` |
| Refuge du Saut | `BK_STRUCTURE:5a1nww29smum` |
| Refuge l' Auberge de Bellecombe | `BK_STRUCTURE:xxx5xjr51ovb` |

### Portails NEOUVIELLE et BOREON de la centrale FFCAM

| Refuge | Identifiant |
| --- | --- |
| Refuge d'Aygues-Cluses | `BK_STRUCTURE:xxx5ybjcpt6a` |
| Refuge d'Orédon | `BK_STRUCTURE:iyuctdomm9k` |
| Refuge de l'OULE | `BK_STRUCTURE:xxx5ylsjmuv1` |
| Gîte du Boréon | `BK_STRUCTURE:5e92vrpttey6` |

### Open System (Parc national de la Vanoise)

| Refuge | Identifiant (`ui:` du widget) |
| --- | --- |
| Refuge de Plaisance | `OPRF-93151` |
| Refuge de Plan du Lac | `OPRF-92949` |
| Refuge de Prariond | `OPRF-93152` |
| Refuge de Rosuel | `OPRF-93149` |
| Refuge de Turia | `OPRF-93145` |
| Refuge de Vallonbrun | `OPRF-92996` |
| Refuge de la Femma | `OPRF-92951` |
| Refuge de la Leisse | `OPRF-92948` |
| Refuge de la Martin | `OPRF-93146` |
| Refuge du Bois | `OPRF-93150` |
| Refuge du Col du Palet | `OPRF-93148` |
| Refuge du Fond des Fours | `OPRF-93147` |

### Refuge Pro (ajoutés dans `manual_huts.json`)

| Refuge | Calendrier |
| --- | --- |
| Refuge Buffère | [`refuge-buffere`](https://refuge-pro.com/embed/calendrier/refuge-buffere) |
| Refuge I Re Magi | [`re-magi`](https://refuge-pro.com/embed/calendrier/re-magi) |
| Refuge Laval | [`laval`](https://refuge-pro.com/embed/calendrier/laval) |
| Refuge Ricou | [`ricou`](https://refuge-pro.com/embed/calendrier/ricou) |
| Refuge Terzo Alpini | [`terzo-alpini`](https://refuge-pro.com/embed/calendrier/terzo-alpini) |
| Refuge de Terre Rouge | [`refuge-de-terre-rouge`](https://refuge-pro.com/embed/calendrier/refuge-de-terre-rouge) |
| Refuge des Marches | [`marches`](https://refuge-pro.com/embed/calendrier/marches) |
| Refuge du Chardonnet | [`chardonnet`](https://refuge-pro.com/embed/calendrier/chardonnet) |
| Refuge du Clôt des Vaches | [`refuge-du-clot-des-vaches`](https://refuge-pro.com/embed/calendrier/refuge-du-clot-des-vaches) |
| Refuge du Galibier | [`galibier`](https://refuge-pro.com/embed/calendrier/galibier) |
| Rifugio Guido Rey | [`rifugio-guido-rey`](https://refuge-pro.com/embed/calendrier/rifugio-guido-rey) |

### Sans réservation en ligne lisible (ajoutés dans `manual_huts.json`)

| Refuge | Comment réserver |
| --- | --- |
| Refuge de la Coire | bonjour@refugedelacoire.fr · [site](https://www.refugedelacoire.fr/reservations-hiver/) |
| Refuge de la Selle | tél. 09 70 02 03 83 · [site](https://www.refugedelaselle.com/contact/) |
| Refuge du Nant du Beurre | tél. 06 82 70 26 99 · refugedunantdubeurre@etik.com · [site](https://refugedunantdubeurre.fr/) |
