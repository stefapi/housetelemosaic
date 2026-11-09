# House Telemosaic (`housetelemosaic`)

Chaque maison nativevillages éligible (préfixes `grasslandhouse`, `deserthouse`, `savannahouse`,
`icehouse`, `junglehouse`, `cannibalhouse`, `lakehouse` ; bâtiments `*_cloudlands` exclus) reçoit,
selon une chance réglable (défaut : toutes), un sous-sol accessible par trappe et échelle,
contenant un pad telemosaic bidirectionnel pointant vers :

- une **grotte** : poche d'air naturelle scannée en profondeur, avec salle artificielle de
  secours si aucune n'est trouvée ;
- un **donjon** : salle d'un donjon natif du mapgen (celles que `dungeonsplus` décore de
  ses features et de son loot quand il est actif), donjon `randungeon` généré en secours,
  ou salle voûtée mossycobble en dernier recours ;
- un **labyrinthe** généré : recursive backtracker déterministe, avec « carotte » retirant
  environ 8 % des murs pour créer des boucles ;
- l'**île cloudlands** la plus proche : plateforme d'arrivée stabilisée (destination `sky`,
  mod `cloudlands` requis).

## Dépendances

| Mod | Statut | Rôle |
|-----|--------|------|
| `telemosaic` | obligatoire | beacons, extendeurs et API de liaison |
| `nativevillages` | obligatoire | placement des maisons (hook intercepté) |
| `cloudlands` | optionnel | active la destination `sky` (îles flottantes) |
| `randungeon` | optionnel | donjon complet généré en secours pour la destination `dungeon` |
| `dungeonsplus` | optionnel | décore les donjons natifs visés par la destination `dungeon` |
| minetest_game | attendu | nodes `default` et `doors` (trappe du puits) |

Les nodes de construction sont résolus au chargement avec des chaînes de fallback
(`default:stonebrick` vers `default:stone`, `doors:trapdoor_wood` vers les autres trappes) :
en cas d'absence, le mod se dégrade proprement (trou laissé ouvert, avertissements au log).

## Fonctionnement

### Interception du placement nativevillages

À `on_mods_loaded`, le mod encapsule `nativevillages.basements.maybe_dig_basement`
(monkey-patch) : chaque maison posée passe dans le wrapper après la pose de la schematic.
Sans point d'accroche connu (à défaut `nativevillages.dungeon.maybe_place_hidden_entrance`),
le mod reste inerte avec un log d'erreur explicite.

La chance d'équipement est tirée de façon déterministe par maison (flux `PcgRandom` :
graine du monde + coordonnées), ré-exécutable à l'identique sur un chunk régénéré.

### Sous-sol

- Chambre 9x9 sous la maison : murs stonebrick, sol cobble, torches ; plafond percé d'un
  puits 1x1 muni d'une échelle et fermé par une trappe dans le plancher ; beacon telemosaic
  ENCASTRÉ dans la dalle (affleurant), au coin diagonalement opposé au puits — jamais au
  pied de l'échelle. Les extendeurs longues distances sont encastrés dans la dalle de la
  même façon (seuls `default:cobble`/`default:stone_block` posés par le mod sont remplaçables).
- Anti-collision avec les sous-sols natifs et les entrées randungeon : sondage de 9 colonnes,
  décalage de la chambre (+4/+4 puis +8/+8), approfondissement de 4 en dernier recours ;
  abandon propre si aucune position n'est libre.
- **Patch direct du cellier natif** (prioritaire) : quand la maison possède un cellier natif,
  le beacon est encastré dans la dalle de son niveau le plus bas, dans une cellule libre à
  ≥ 3 nodes de l'échelle native, sur une dalle de stabilisation 3×3 — zéro excavation, le
  cellier devient la pièce du téléporteur.
- **Connexion par le dessous** (repli si le cellier est encombré de meubles) : la chambre
  s'installe sous la dalle basse du cellier, sans puits ni trappe propres — un trou
  d'échelle percé dans sa dalle basse descend jusqu'au pad
  (maison → trappe native → cellier → échelle → chambre du pad).

### Choix de la destination

Sélection déterministe par maison (graine du monde + coordonnées) parmi les providers
disponibles, dans l'ordre du réglage `housetelemosaic_destinations` (mode `ordered`) ou par
rotation aléatoire déterministe (mode `random`), avec chaîne de fallback entre providers :

- **cave** : scan VoxelManip en lecture seule des poches d'air habitables, dans un rayon
  `cave_radius` et une fenêtre profonde (y1-60 à y1-20, clampée) ; salle artificielle 9x9
  en secours si aucune poche n'est trouvée (désactivable) ;
- **maze** : grille de WxH cellules (emprise (2W+1)x(2H+1) nœuds), recursive backtracker
  déterministe, carotte retirant `floor(W*H*0.08)` murs séparateurs (boucles), beacon posé
  à l'entrée, enceinte ouverte au nord ;
- **dungeon** : scan des sols caractéristiques des donjons natifs (cobble, mossycobble,
  stonebrick — les mêmes salles que `dungeonsplus` décore) dans un rayon de 48 et une
  fenêtre profonde y1-200..y1-25 ; si aucune salle n'est trouvée : donjon `randungeon`
  généré via `randungeon.make_dungeon` (40x40, 3 niveaux, matériaux aléatoires), sinon
  salle voûtée 9x9 mossycobble/stonebrick ;
- **sky** : île la plus proche via `cloudlands.find_nearest_island` (rayon
  `sky_search_radius`) ; plateforme d'arrivée stabilisée : 3x3 sur le sol réel de l'île,
  ou plateforme artificielle 7x7 si le terrain n'y est pas.

### Liaison telemosaic

Les destinations sont programmées dans les deux sens via `telemosaic.set_destination`
(lien retour désactivable par `housetelemosaic_return_enabled`), et des extendeurs sont
posés automatiquement en spirale autour de chaque pad selon la distance (palier three,
two puis one ; plafonné par `housetelemosaic_max_extenders`).

### File de liaison persistante

Les liaisons en attente sont persistées en mod storage (`{pad, job, plan, provider, tries}`)
et reprises automatiquement :

- LBM sur les beacons encore `pending` au chargement de leur chunk ;
- re-traitement sur `on_generated` (au plus toutes les 10 s) et au démarrage du serveur ;
- 3 essais par provider, puis bascule déterministe vers le provider suivant avant l'abandon
  définitif (état `unlinked`).

## Réglages

Tous les réglages sont clampés à leurs bornes documentées ; une valeur invalide retombe sur
le défaut.

| Réglage | Défaut | Description |
|---------|--------|-------------|
| `housetelemosaic_chance` | `1.0` | Chance qu'une maison éligible reçoive le sous-sol (0.0 à 1.0) |
| `housetelemosaic_destinations` | `cave,dungeon,maze,sky` | Liste ordonnée des destinations (`cave`, `dungeon`, `maze`, `sky`) |
| `housetelemosaic_dest_mode` | `ordered` | `ordered` : première de la liste ; `random` : tirage parmi les disponibles |
| `housetelemosaic_return_enabled` | `true` | Poser aussi un lien retour sur le pad de destination vers la maison |
| `housetelemosaic_cave_artificial_fallback` | `true` | Grotte artificielle de secours sans grotte naturelle trouvée |
| `housetelemosaic_cave_depth` | `30` | Profondeur cible du pad de grotte sous la surface (nœuds) |
| `housetelemosaic_cave_radius` | `48` | Rayon de recherche horizontal d'une grotte naturelle (nœuds) |
| `housetelemosaic_maze_depth` | `25` | Profondeur du pad de labyrinthe sous la surface (nœuds) |
| `housetelemosaic_maze_width` | `21` | Largeur du labyrinthe en cellules (emprise 2W+1 nœuds, carré) |
| `housetelemosaic_maze_height` | `5` | Hauteur des couloirs du labyrinthe (nœuds) |
| `housetelemosaic_basement_depth` | `5` | Profondeur du sous-sol sous le plancher de la maison (nœuds) |
| `housetelemosaic_sky_search_radius` | `512` | Rayon de recherche d'une île cloudlands (nœuds, 0 = désactivé) |
| `housetelemosaic_max_extenders` | `12` | Extendeurs maximum par pad (0 = illimité) |
| `housetelemosaic_debug` | `false` | Journalisation de debug détaillée dans le log du serveur |

## Commandes

| Commande | Privilège | Description |
|----------|-----------|-------------|
| `/htstats` | — | État de la file : entrées par provider, abandons cumulés, dernier pad, hook |
| `/htcheck` | — | Diagnostic d'installation : hook, source nativevillages, compteurs de session étape par étape |
| `/htrelink` | `server` | Relance le traitement de toutes les entrées de la file |
| `/htforce` | `server` | Test complet du pipeline : sous-sol + pad forcés sous la position du joueur |
| `/htdebug` | `server` | Bascule la journalisation de debug en cours d'exécution |
| `/htscanarea [<rayon>]` | `server` | Équipe rétroactivement les maisons déjà posées autour du joueur (déf. 64 nodes, 30 maisons/passage) |
| `/htaudit [<rayon>] [fix\|report]` | `server` | Audite et répare les sous-sols déjà construits (échelles, puits, trappe, passage cellier, beacon encastré) |
| `/htmaze <x> <y> <z> [<w> [<h>]]` | `server` | Labyrinthe de test de `w`x`h` cellules (déf. 15x15) en (x, y, z) |

## Notes techniques

- **Déterminisme** : chaque tirage est un flux `PcgRandom` mélangé à la graine du monde et
  aux coordonnées de la maison ; un chunk régénéré reconstruit le même sous-sol, un même
  plan re-materialize exactement le même labyrinthe.
- **Aucune écriture dans un chunk non généré** : toutes les constructions hors de l'emprise
  déjà émergée de la maison (sous-sol, grotte, labyrinthe, plateforme) passent d'abord par
  `emerge_area` ; le callback ne s'exécute que si 100 % des blocs émergent avec succès
  (actions `EMERGE_FROM_MEMORY`, `EMERGE_FROM_DISK` ou `EMERGE_GENERATED` — la constante
  `EMERGE_OK` n'existe pas dans l'API Luanti).
- **Séparation verticale** des structures (F = plancher de la maison) : chambre du sous-sol
  à F - basement_depth - 1 (sol à F-6 par défaut), labyrinthe à F - maze_depth (F-25 par
  défaut), grotte artificielle à y1 - cave_depth (au moins 26 nœuds sous la base de la
  maison) — profondeurs distinctes par défaut, jamais superposées.

## Licence

MIT (voir `mod.conf`).
