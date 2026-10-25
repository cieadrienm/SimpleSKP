# SimpleSKP

Visualiseur **SketchUp** natif, léger (13 Mo dont 11 pour le SDK SketchUp, zéro dépendance) : double-cliquer un `.skp` pour le visualiser en 3D en moins d'une seconde, dans la lignée de **SimpleAudio**, **SimplePJ**, **SimpleVectorizer** et **SimpleText** (**cie Adrien M** — [adrien-m.net/software](https://adrien-m.net/software)). Le fichier est lu par le framework du SDK SketchUp (`SketchUpAPI.framework`, livré dans l'app et chargé à la demande) et affiché avec SceneKit / Metal : **SketchUp n'a pas besoin d'être installé**. Un visualiseur strict, pas un éditeur : aucun fichier `.skp` n'est jamais modifié ni enregistré.

## Fonctionnalités

- **Barre d'outils complète (`TopBar`)** : toutes les actions, vues standard, projections, styles de rendu, réglages d'éclairage, scènes et captures sont directement accessibles à la souris avec infobulles détaillées.
- **3D instantanée après la vignette** : la vignette du fichier s'affiche tout de suite, le modèle se charge en arrière-plan et apparaît en fondu.
- **Rendu architectural doux** :
  - **4 styles de rendu en direct** : **PBR** (texturé réaliste doux), **Blanc** (maquette architecturale en plâtre mat), **Rayons X** (faces semi-transparentes) et **Filaire**.
  - **Éclairage Soleil ou Ponctuel (`⌥⌘L`)** : bascule entre soleil directionnel orientable (azimut `-180°…180°`, hauteur `8°…85°`, ombres douces `⌥⌘O`) et éclairage ponctuel omnidirectionnel basé sur les lumières détectées dans la scène `.skp` ou sur une lumière créée par défaut au milieu de la géométrie (coordonnées X, Y, Z et intensité réglables).
  - **Importance de l'occlusion ambiante SSAO** réglable de `0 %` à `200 %` (`⌥⌘A`).
  - **Fond de scène personnalisable** : Ciel architectural, Studio sombre, Papier chaud ou **Couleur personnalisée** (`ColorPicker` + pastilles rapides).
  - **Grille au sol et axes XYZ** (`⌥⌘G`) + repère d'orientation 3D interactif en bas à droite de la vue.
- **Scènes** : la caméra glisse vers la scène choisie (`⌘[` et `⌘]` ou sélecteur de la barre d'outils), ses calques masqués s'appliquent.
- **Calques & Inspecteur** : recherche/filtrage instantané des calques par nom, boutons **Tout / Aucun**, bouton **Solo** au survol d'un calque, et résumé **Modèle & Matériaux** (dimensions, statistiques, nuancier des matériaux).
- **Dimensions en mètres** dans la barre d'état, avec version SketchUp du fichier, faces, arêtes et composants.
- **Vues standard** : Iso, Dessus, Face, Droite, Arrière, Gauche, Dessous (`⌘1…⌘7`), **Réinitialiser la vue** (`Z`) et **Zoom étendu** (`⇧Z`).
- **Perspective / parallèle** (`⌥⌘P`) et **arêtes** affichables ou masquées (`⌘E`).
- **Copie d'image** (`⌘C`), **export PNG** (`⇧⌘E`) et **ouverture dans SketchUp** (`⇧⌘O`).
- Glisser-déposer d'un `.skp` sur la fenêtre ou l'icône, plusieurs fichiers ouverts, Ouvrir récent, restauration des fenêtres.

## Manipulation

Quatre façons coexistent ; un clic ou une touche arrête tout mouvement en cours.

| Geste | Effet |
|---|---|
| Glisser | Orbite autour du point visé, avec inertie |
| ⇧-glisser ou bouton du milieu | Panoramique |
| Molette | Zoom vers le curseur |
| Double-clic | Recentrer et approcher le point |
| `Z` | Réinitialiser la caméra à la vue initiale |
| `⇧Z` | Zoom étendu sur l'ensemble des objets visibles |
| Clic droit tenu | Regarder autour (éditeur de jeu) |
| ZQSD (WASD en QWERTY) ou flèches | Avancer, reculer, pas de côté (touches physiques) |
| Espace ou E / C | Monter / descendre |
| ⇧ avec les touches | Quatre fois plus vite |
| Molette avec clic droit tenu | Vitesse de déplacement |
| Deux doigts (trackpad) | Orbite, ou zoom (Réglages, pour la Magic Mouse) |
| ⌥ + deux doigts | Panoramique |
| Pincer | Zoom vers le curseur |
| Rotation à deux doigts | Tourner autour de la verticale |
| ⌥⌘F | Vol libre : la souris oriente sans clic, le clavier déplace, Échap pour sortir |

## Raccourcis

| Raccourci | Action |
|---|---|
| ⌘O | Ouvrir… |
| ⌘W | Fermer |
| ⇧⌘O | Ouvrir dans SketchUp |
| ⌘C | Copier l'image dans le presse-papiers |
| ⇧⌘E | Exporter l'image en PNG… |
| ⌥⌘S | Afficher / masquer la barre latérale |
| ⌘E | Arêtes |
| ⌥⌘G | Grille au sol et axes XYZ |
| ⌥⌘P | Perspective / parallèle |
| ⌥⌘O | Ombres portées |
| ⌥⌘L | Éclairage Soleil / Ponctuel |
| ⌥⌘A | Occlusion ambiante SSAO |
| Z | Réinitialiser la vue initiale |
| ⇧Z | Zoom étendu |
| ⌥⌘F | Mode vol libre (Échap pour sortir) |
| ⌘[ / ⌘] | Scène précédente / suivante |
| ⌘1 … ⌘7 | Iso, dessus, face, droite, arrière, gauche, dessous |
| ⌘, | Réglages |
| ⌘? | Guide d'utilisation |
| ⌘/ | Raccourcis clavier |

## Prérequis

- **macOS 15** ou plus.
- C'est tout : le SDK SketchUp est dans `SimpleSKP.app/Contents/Frameworks`. **SketchUp est facultatif** ; installé, il sert à « Ouvrir dans SketchUp » (⇧⌘O), sinon la commande est masquée.
- Pour compiler : `Scripts/bundle.sh` embarque le framework pris dans `$SKETCHUP_SDK`, sinon `Vendor/SketchUpAPI.framework` (SDK C officiel téléchargé chez Trimble, jamais commité), sinon la copie du même SDK livrée avec Unity (`/Applications/Unity/Hub/Editor/*/Unity.app/Contents/Frameworks`, la plus récente). Il échoue sans SDK.

## Compilation & Installation

```bash
# Assembler build/SimpleSKP.app et l'installer dans /Applications (INSTALL=0 pour ne pas installer)
Scripts/bundle.sh

# Suite de tests
swift test

# Auto-test et capture PNG hors écran
.build/debug/SimpleSKP --self-test [fichier.skp]
.build/debug/SimpleSKP --snapshot /tmp/simpleskp.png [fichier.skp]
```

## Ligne de commande

```bash
SimpleSKP --version
SimpleSKP --self-test [fichier.skp]            # en-tête, framework, scène synthétique, fichier réel, PNG
SimpleSKP --snapshot sortie.png [fichier.skp]  # photographie la fenêtre avec le modèle chargé
SimpleSKP --lang fr|en                         # langue de l'interface
```

## Performance

| Mesure | Cible | Mesuré |
|---|---|---|
| Lancement du binaire → capture PNG du petit modèle affiché | < 0,3 s pour la vignette | 0,9 s au total (vignette d'abord, lecture 0,18 s comprise) |
| `04-Monticule.skp` (157 Ko) → 3D visible | < 0,5 s | lecture 0,18 s |
| `MM_Arles_3D_V003.skp` (45 Mo, 35 textures) → 3D | < 4 s (lecture API 1,9 s) | lecture 2,3 s + scène 0,13 s ; lancement de l'app empaquetée (SDK embarqué seul) → capture 3,9 s |
| `B-SEINE MUSICALE…V40.skp` (97 Mo, 14 758 composants, 641 572 arêtes, 151 calques) → 3D | < 7 s (lecture API 2,9 s) | lecture 3,7 s + scène 0,15 s (2,95 s avant les calques à la demande et la fusion des instances) ; lancement de l'app empaquetée (SDK embarqué seul) → capture 4,9 s |
| Orbite sur la salle | 60 i/s sur Apple Silicon | M2 Max, 2760 × 1640, MSAA ×4, `SCNRenderer`, instances fusionnées, rendu ombré (ombres + occlusion) : caméra du fichier 142 i/s ; iso 118 i/s (17 avant la fusion) ; « VUE DESSUS COUPE » 53 i/s (10 avant, 128 sans ombrage) ; « FOH » 207 i/s ; Arles > 400 i/s ; scène construite en 0,15 s |
| Mémoire | ≤ 3 × la taille du fichier | salle : empreinte 1,2 Go une fois la vue du fichier affichée, 1,5 Go en iso, 2,5 Go après « VUE DESSUS COUPE » (calques en plus) ; `--snapshot` de la salle avec le rendu final : pic d'empreinte 1,28 Go, RSS max 1,78 Go ; Arles : pic 0,47 Go |
| Binaire | ≈ 3 Mo | 1,4 Mo en release, 2,7 Mo empaqueté avec l'icône ; 13 Mo avec le SDK SketchUp (11 Mo, aminci à arm64, sans en-têtes) |

Mesuré le 25 octobre 2026 sur Apple Silicon, build release, cache disque chaud (`.build/release/SimpleSKP --snapshot` et `--self-test`, deux passes identiques).

## Crédits & Licence

**Adrien Mondot · cie Adrien M** (Compagnie Adrien M — [adrien-m.net](https://adrien-m.net)) — Bundle ID : `net.cieadrienm.simpleskp`.
SketchUp est une marque de Trimble Inc. ; SimpleSKP n'en est ni affilié ni approuvé.
Le framework du SDK C de SketchUp (Trimble) est embarqué dans l'app sous la licence du SDK SketchUp ; le code de SimpleSKP est GPL v3 (voir [`LICENSE`](LICENSE)).
