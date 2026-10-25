# Changelog — SimpleSKP

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
