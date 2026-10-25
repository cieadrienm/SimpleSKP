# Changelog — SimpleSKP

## 1.0.0 — 2026-10-25
- Première version de **SimpleSKP** (**cie Adrien M**) : visualiseur SketchUp natif, sans dépendance.
- Lecture des `.skp` (SketchUp 8 à 2023) par `SketchUpAPI.framework`, trouvé dans SimpleSKP, SketchUp ou Unity ; vignette PNG du fichier affichée avant la 3D, chargement en arrière-plan.
- Affichage SceneKit : faces par lot, composants instanciés, arêtes non adoucies, textures, transparence, rendu à la demande.
- Manipulation à la SketchUp : orbite autour du point visé, panoramique, zoom vers le curseur, recentrage au double-clic, zoom étendu (⇧Z).
- Scènes (caméra animée, calques masqués), calques avec visibilité immédiate, vues standard (⌘1…⌘7), perspective / parallèle, arêtes, copie d'image, ouverture dans SketchUp.
- Barre d'état : version SketchUp, faces, arêtes, composants, dimensions en mètres, temps de chargement.
- Interface française et anglaise ; feuilles À propos, Raccourcis, Aide, Mise à jour, Réglages.
- Ligne de commande : `--version`, `--self-test`, `--snapshot`, `--lang`.
- Signature Developer ID avec `disable-library-validation` pour charger le framework de Trimble.
