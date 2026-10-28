# Changelog — SimpleSKP

## 1.4.0 — 2026-10-28
- **Ouverture native des fichiers Collada (`.dae`) et Wavefront (`.obj`)** :
  - Lecteurs directs sans dépendance externe (`Mesh3DReader`) avec prise en charge des matériaux et textures `.mtl` ainsi que des scènes et transformations Collada, conversion automatique d'unités et d'axe vertical (`Y-up` / `Z-up`).
- **Simulation optique de vidéoprojecteurs (`VP`) & Projets `.sskp` (`hiddenFeatures`)** :
  - Activation par `⌘⌥-clic` sur `Adrien Mondot` dans la fenêtre *À propos* (badge vert `hiddenFeatures`).
  - Modèle optique précis (**Optoma ZU920ST** WUXGA `1920 × 1200` `16:10`, rapport `0.65–0.75:1`, *Lens Shift* H `±25 %` et V `±55 %`, `9 800 lm`, ainsi qu'**Optoma ZU920T** et **Optoma ZU725TST**) avec calcul exact du frustum asymétrique hors-axe.
  - Occlusion géométrique réelle par passe de profondeur métrique Metal hors-écran (`r32Float`, `1024 × 1024` par VP) et *shader modifier* SceneKit : l'image projetée s'arrête sur le premier obstacle et ne traverse jamais la matière.
  - Placement et visée 3D au clic sur la géométrie, mires de calage intégrées (*Grille 16:10*, *Barres de couleur*, *Cadre blanc*, *Image personnalisée*) et sauvegarde/ouverture de projets `.sskp` (`⌘S` / `⇧⌘S`).
- **Annuler / Rétablir sur 100 niveaux (`⌘Z` / `⇧⌘Z`)** :
  - Historique à 100 niveaux avec fusion automatique des glissages continus de curseurs couvrant les vidéoprojecteurs, les calques, l'éclairage, les styles de rendu, les mesures et la caméra.
- **Ergonomie AutoCAD & Mesures (`⌘D`)** :
  - Raccourci `H` en mode AutoCAD pour masquer rapidement l'objet ou le calque sélectionné/survolé, construction visuelle didactique calque par calque au chargement, désactivation du survol sur les fichiers `.skp` pour préserver la lisibilité, et synchronisation immédiate de l'outil de mesure (`⌘D`) avec la caméra.

## 1.3.0 — 2026-10-26
- **Import AutoCAD `.dwg` / `.dxf` direct en mémoire & construction progressive** :
  - Lecture directe en mémoire des fichiers `.dwg` et `.dxf` en une seule passe (sans sérialisation `.skp` intermédiaire sur disque), mise à l'échelle automatique selon `$INSUNITS`, couleurs de calques et d'entités AutoCAD, et suivi de progression en direct (blocs, calques, arêtes, faces).
  - Construction progressive calque par calque dans le viewport avec affichage immédiat.
- **Outil de mesure interactif (`⌘D`) intégré dans la passe Metal SceneKit** :
  - Magnétisme sur les sommets, milieux et arêtes, affichage de la distance 3D et des composantes $\Delta X / \Delta Y / \Delta Z$ directement dans le graphe SceneKit (`modelRoot`) pour suivre le panoramique, le zoom et l'orbite sans aucun retard de trame.
- **Sélection et survol dans la vue 3D/2D** :
  - Surlignage au survol, clic pour sélectionner le calque correspondant dans l'arborescence, raccourci `⌫` pour masquer rapidement le calque sélectionné et inertie fluide du défilement/zoom 2D et 3D.

## 1.2.0 — 2026-10-25
- **Pilotage OSC, OSCQuery (`OSCScore`), API HTTP `/v1` & serveur MCP (`simpleskp-mcp`)** :
  - Serveur **OSC UDP** sur le port **`9150`** (`SIMPLESKP_OSC_IN_PORT`) et retour OSC en direct sur **`127.0.0.1:9151`** (`SIMPLESKP_OSC_OUT_PORT`, activable dans les Réglages).
  - Serveur **OSCQuery & API HTTP `/v1`** sur le port **`17950`** (`SIMPLESKP_API_PORT`) annoncé automatiquement en **Bonjour (`_oscjson._tcp.` et `_osc._udp.`)** pour une découverte zéro-conf dans **OSCScore** : pistes 3D `Vec3` pour `/simpleskp/camera/position`, `/simpleskp/camera/target` et `/simpleskp/light/position`, pistes 2D pour `/simpleskp/camera/orientation` et `/simpleskp/sun/angles`, piste couleur `RGBA` pour `/simpleskp/backdrop/color`, et pistes scalaires/triggers pour `/simpleskp/camera/fov`, `/simpleskp/camera/focal`, `/simpleskp/camera/exposure`, scènes, calques et styles de rendu.
  - Serveur **MCP (`simpleskp-mcp`)** livré dans `SimpleSKP.app/Contents/MacOS/simpleskp-mcp` avec 8 outils (`simpleskp_state`, `simpleskp_help`, `simpleskp_open`, `simpleskp_camera`, `simpleskp_scene`, `simpleskp_layers`, `simpleskp_rendering`, `simpleskp_snapshot`).
- **Réglages fins de la caméra & Optique (`camera.aperture` dans la barre d'outils)** :
  - Réglage continu de l'**angle d'ouverture vertical (FOV)** de `10°` à `120°` et de la **focale équivalente 24×36 (`mm`)** avec 5 objectifs rapides (`14 mm`, `24 mm`, `35 mm`, `50 mm`, `85 mm`).
  - Positionnement exact de la caméra en mètres (**X, Y, Z**) avec boutons de pas `±0,5 m`, raccourcis **`Œil 1,70 m`**, **`Au centre`** et **`Horizon 0°`**.
  - Réglage direct de l'**orientation** (**Azimut / Lacet** `-180°…180°` et **Inclinaison / Tangage** `-89°…89°`, distance à la cible) et de l'**exposition HDR** (`-3,0…+3,0 EV`).
- **Contraste adaptatif du filaire & des arêtes** : la couleur des arêtes vectorielles et du mode **Filaire** (`wireframe`) s'adapte automatiquement à la luminance du fond (**Studio sombre**, **Ciel architectural**, **Papier chaud** ou **Couleur personnalisée** quelle qu'elle soit) avec compensation HDR pour rester parfaitement contrastée en toutes circonstances.
- **Puissance lumineuse logarithmique & Lumière ambiante réglable** :
  - Échelle **logarithmique** (`0 %…300 %`, exposant `2,6`) sur les curseurs de puissance lumineuse (ponctuelle et solaire) offrant une finesse de réglage au dixième de pourcent dans les basses valeurs.
  - Nouveau curseur **Lumière ambiante** (`0 %…200 %`, également pilotable en OSC `/simpleskp/lighting/ambient` et MCP) contrôlant ce qui reste lorsque les lumières sont à `0 %` (noir complet possible à `0 %`).
- **Export en PDF vectoriel (`⌥⌘E`)** : bouton dans la barre d'outils (`doc.richtext`), entrée `Fichier ▸ Exporter en PDF vectoriel…` (`⌥⌘E`) et endpoint HTTP/MCP (`POST /v1/pdf`, `simpleskp_snapshot` avec `format: "pdf"`) projetant les faces, les arêtes non adoucies, la grille et les axes XYZ en **chemins vectoriels PDF 100 % natifs** (`CGContext` PDF, perspective ou parallèle, tri en profondeur et suppression des lignes cachées en mode ombré).
- **Transition de scène ralentie 10× avec `⇧` (`Shift`)** : maintenir `⇧` lors d'un clic sur une scène, sur les boutons `‹` / `›` ou via `⇧⌘[` / `⇧⌘]` effectue un travelling de **3,5 s** (au lieu de `0,35 s`).
- **Déplacement caméra au clavier 4× plus progressif** : vitesse nominale réduite d'un facteur 4 (`diagonale / 32`, bornée à `0,125…12,5 m/s`).
- **Masquage et affichage animés de la barre latérale (`⌥⌘S`)** : transition fluide en glissement et fondu (`0,22 s`).
- **Éclairage ponctuel calibré** : intensité nominale (`100 %`) portée à `2 600 lm` avec atténuation douce à longue portée et redessin immédiat de la vue 3D à chaque modification des curseurs.

## 1.1.0 — 2026-10-25
- **Barre d'outils complète (`TopBar`)** : accès direct à toutes les fonctions sans passer par les menus ou les raccourcis (ouverture, Finder, SketchUp, réinitialisation de la vue `Z`, zoom étendu `⇧Z`, vues standard `Iso`/`Dessus`/`Face`/`Droite`/`Arrière`/`Gauche`/`Dessous`, bascule Perspective/Parallèle, mode Vol libre, styles de rendu, arêtes, ombres, mode d'éclairage Soleil/Ponctuel, réglage du soleil/lumière/SSAO/fond, grille & axes, sélecteur de scènes, copie et export PNG).
- **Touche `Z` pour réinitialiser la vue** (et `⇧Z` pour le zoom étendu) + repère d'orientation 3D interactif (axes X rouge, Y vert, Z bleu) et barre de zoom rapide en surimpression de la vue 3D.
- **Éclairage Soleil ou Ponctuel (`⌥⌘L`)** :
  - Bascule entre l'éclairage solaire directionnel (azimut `-180°…180°`, hauteur `8°…85°`, ombres portées `⌥⌘O`) et un éclairage ponctuel omnidirectionnel.
  - Détection automatique des lumières/projecteurs présents dans la scène `.skp` (`light`, `lumière`, `spot`, `projecteur`, `fresnel`, `découpe`, `svoboda`, etc.) ou création automatique d'une lumière par défaut au milieu de la géométrie, avec réglage des coordonnées **X, Y, Z** en mètres, de l'**intensité** (`10 %…300 %`) et repère 3D filaire.
- **Rendu architectural enrichi, importance SSAO & couleur du fond personnalisée** :
  - Contre-jour céleste directionnel (`skyFill`) éliminant les faces bouchées à contre-jour, exposition HDR et contraste affinés.
  - 4 styles de rendu en direct (**PBR texturé**, **Maquette blanche**, **Rayons X**, **Filaire**).
  - Réglage continu de l'**importance de l'occlusion ambiante SSAO** (`0 %` à `200 %`, défaut `70 %`, `⌥⌘A`).
  - Choix du **fond de scène** parmi **Ciel architectural**, **Studio sombre**, **Papier chaud** ou **Couleur personnalisée** (`ColorPicker` natif + 6 pastilles rapides).
  - **Grille au sol avec axes XYZ** (`⌥⌘G`).
- **Barre latérale enrichie** : recherche/filtrage instantané des calques, boutons **Tout / Aucun**, mode **Solo** au survol d'un calque, navigation rapide entre scènes (`‹` / `›`) et inspecteur **Modèle & Matériaux** (dimensions, statistiques, nuancier des matériaux).
- **Export PNG (`⇧⌘E`)** et retour visuel lors de la copie d'image (`⌘C`).
- **Fenêtres À propos, Guide d'utilisation, Raccourcis et Réglages harmonisées (`SimpleFamily`)** : icône vectorielle `SKPHeroGraphic`, pastille de version copiable, grille `POINTS FORTS`, lien cliquable vers **`https://adrien-m.net`** (`Adrien Mondot · cie Adrien M`), manuel interactif à 2 colonnes et section Confidentialité.

## 1.0.0 — 2026-10-25
- Première version de **SimpleSKP** (**cie Adrien M**) : visualiseur SketchUp natif, sans dépendance.
- Lecture des `.skp` (SketchUp 8 à 2023) par `SketchUpAPI.framework` ; vignette PNG du fichier affichée avant la 3D, chargement en arrière-plan.
- Affichage SceneKit : faces par lot, composants instanciés, arêtes non adoucies, textures, transparence, rendu à la demande.
- Déplacement : quatre façons qui coexistent — orbite fluide avec inertie autour du point visé, éditeur de jeu (clic droit + ZQSD/WASD), gestes trackpad, vol libre (⌥⌘F) ; zoom vers le curseur, recentrage au double-clic, zoom étendu (⇧Z).
- Rendu « réaliste doux » : matériaux physiques, soleil avec ombres douces en cascades, ciel dégradé, occlusion ambiante, HDR ; interrupteurs Ombres (⌥⌘O) et Occlusion ambiante (⌥⌘A).
- Instances fusionnées par ensemble de calques et matériau : salle de 97 Mo en iso 17 → 180 i/s (118 i/s ombrée), « VUE DESSUS COUPE » 10 → 128 i/s (52 ombrée), « FOH » 208 i/s ombrée, scène construite en 0,15 s ; géométrie en une seule copie mémoire (empreinte 1,2 Go au lieu de 1,8 Go en vue du fichier).
- Scènes (caméra animée, calques masqués), calques avec visibilité immédiate, vues standard (⌘1…⌘7), perspective / parallèle, arêtes, copie d'image, ouverture dans SketchUp.
- Barre d'état : version SketchUp, faces, arêtes, composants, dimensions en mètres, temps de chargement.
- Interface française et anglaise ; feuilles À propos, Raccourcis, Aide, Mise à jour, Réglages.
- Ligne de commande : `--version`, `--self-test`, `--snapshot`, `--lang`.
- Le SDK SketchUp est embarqué : `Scripts/bundle.sh` livre `SketchUpAPI.framework` dans `SimpleSKP.app/Contents/Frameworks` (aminci, sans en-têtes, re-signé avec l'identité de l'app) ; SketchUp n'a pas besoin d'être installé.
- Calques masqués construits à la demande : leurs instances restent vides jusqu'au premier affichage (scène de la salle en 0,6 s au lieu de 2,95 s).
- Le framework du SDK C de SketchUp (Trimble) est embarqué dans l'app sous la licence du SDK SketchUp ; le code de SimpleSKP est GPL v3.
