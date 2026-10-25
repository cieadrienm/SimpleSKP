# Changelog — SimpleSKP

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
