# DECISIONS

Journal des choix structurants : contexte, décision, ce qu'on a écarté. Toutes les décisions ont été prises en autonomie le 25 octobre 2026, à partir de la demande d'Adrien (« une app simple, légère et élégante pour ouvrir rapidement les fichiers SketchUp ») ; elles sont réversibles.

## Lecture et affichage

- **D1 — Le fichier est lu par le framework du SDK C de SketchUp, embarqué dans l'app.**
  - Contexte : le format `.skp` est propriétaire et non documenté ; 412 fichiers sur ce Mac, de 11 Ko à 215 Mo, de SketchUp 8 à 2023. Adrien, le 25 octobre 2026 : « SimpleSKP doit fonctionner même si on n'a pas SketchUp, c'est son intérêt ».
  - Décision : `SketchUpAPI.framework` (API C 11.0), chargé par `dlopen`, livré dans `SimpleSKP.app/Contents/Frameworks` par `Scripts/bundle.sh` : pris dans `$SKETCHUP_SDK`, sinon `Vendor/SketchUpAPI.framework` (SDK officiel de Trimble, ignoré par git), sinon la copie autonome du même SDK livrée avec Unity (la plus récente) ; aminci à l'architecture de la machine, sans en-têtes, re-signé avec l'identité de l'app. Chemins cherchés par l'app dans l'ordre : `$SIMPLESKP_SKETCHUP_SDK` (tests, développement), `Contents/Frameworks` de l'app, puis — sauf si `SIMPLESKP_BUNDLED_SDK_ONLY` est posée, preuve qu'aucun SketchUp n'est requis — chaque `/Applications/SketchUp*.app` et `~/Applications/SketchUp*.app` (le plus récent d'abord ; les dylibs sœurs `libCommon*.dylib` se préchargent par chemin absolu), puis Unity. Les prototypes sont transcrits des en-têtes lus dans la copie Unity (`Versions/A/Headers`), les en-têtes ne sont pas copiés. Framework absent (app incomplète) : vignette PNG et message « réinstallez l'app ». « Ouvrir dans SketchUp » n'apparaît que si SketchUp est installé. Le framework reste sous la licence du SDK SketchUp, pas la GPL.
  - Écarté : réécrire le format (des mois de travail, cassé à chaque version) ; exiger SketchUp installé (refusé par Adrien) ; n'afficher que la vignette.
- **D2 — SceneKit pour l'affichage.** Caméra, lumière, matériaux, collisions et contrôleur d'orbite fournis par le système. Faces triangulées par `SUMeshHelper`, une géométrie par lot (matériau, calque), composants convertis une fois et instanciés par géométrie partagée. Écarté : Metal nu (des dizaines de milliers de lignes), à reconsidérer si SceneKit plafonne sur les maquettes de salle.
- **D5 — Mètres, Z vers le haut dans le modèle neutre.** SketchUp compte en pouces (× 0,0254), Z vertical ; SceneKit a Y vertical : une seule rotation de −90° autour de X sur le nœud racine. Dimensions de la barre d'état en mètres, une décimale.
- **D7 — Rendu « style SketchUp » sur fond sombre.** Faces blanches par défaut, double face, arêtes sauf les adoucies, phare attaché à la caméra + ambiant, pas d'ombres, antialiasing ×4, rendu à la demande (batterie). Textures écrites par `SUTextureWriteToFile` dans un dossier temporaire supprimé à la fermeture.

## Architecture

- **D3 — Document AppKit (`NSDocument`), comme SimpleText.** L'en-tête (version, vignette) se lit en quelques millisecondes et s'affiche avant tout ; le modèle se charge ensuite en arrière-plan. `NSDocument` donne Ouvrir récent, l'association Finder, la restauration, plusieurs fichiers. SwiftUI pour l'habillage dans des `NSHostingView`. Menu construit en code (AppKit insère lui-même « Ouvrir l'élément récent » et « Plein écran », D14 de SimpleText). Écarté : `DocumentGroup`.
- **D4 — Paquet SwiftPM, macOS 15, outils 6.0, mode Swift 5, trois cibles** : `SimpleSKPCore` (sans AppKit), `SimpleSKPViewport` (SceneKit), `SimpleSKP` (app), pour que trois agents compilent chacun la leur en parallèle. Pas de projet Xcode.
- **D6 — Manipulation à la SketchUp sur le contrôleur de caméra de SceneKit** (`.orbitTurntable`) : glisser = orbite autour du point visé ; ⇧-glisser, clic droit ou bouton du milieu = panoramique ; molette ou pincement = zoom vers le curseur ; double-clic = recentrer ; ⇧Z = zoom étendu. Vues ⌘1…⌘7, ⌥⌘P perspective / parallèle, ⌘E arêtes, ⌘[ ⌘] scènes, ⌥⌘S barre latérale. Inertie coupée.
- **D8 — Pas d'OSC, d'API HTTP ni de MCP** : rien à piloter dans un visualiseur (même raisonnement que SimpleText). Pas d'export, d'édition, de sections, d'ombres ni de styles SketchUp.

## Interface et livraison

- **D9 — Interface en français avec `L("fr", "en")`**, `Localization` de la famille, `fr.lproj` et `en.lproj` minimaux pour qu'AppKit parle français. `SimpleUpdater` repris de SimplePJ (dépôt `cieadrienm/SimpleSKP`).
- **D10 — Identifiant `net.cieadrienm.simpleskp`, version `1.0.0` dans `Scripts/bundle.sh` seulement.** Rôle `Viewer` sur `com.sketchup.skp` (déclaration importée, extension `skp`, rang `Alternate` : SketchUp reste propriétaire). Signature Developer ID avec l'entitlement `com.apple.security.cs.disable-library-validation` (sans lui, le runtime durci refuse de charger un framework signé par Trimble) ; signature Apple Development sans runtime durci sinon, comme les sœurs. `bundle.sh` : architecture de l'hôte seulement, `Info.plist` gabarit estampillé (échec si non estampillé), `NOTARIZE=1` possible. L'icône est dessinée par script : tuile sombre de la famille, cube isométrique aux arêtes ambre `FFB454`, une arête cachée en pointillé cyan `5CE1E6`.
- **D11 — Vérifier sans écran.** `--snapshot sortie.png [fichier.skp]` photographie la fenêtre avec le modèle chargé (`SCNView.snapshot()` : `cacheDisplay` ne voit pas Metal) ; `--self-test [fichier.skp]` vérifie l'en-tête, le framework, une scène synthétique (cube), un vrai fichier si donné, et un PNG non uniforme.

## Remis à plus tard

- Export (OBJ, USDZ), ombres et styles SketchUp, plans de section, mesure à la souris.
- Thème clair.
- Pilotage OSC / MCP.
- Parseur maison (sans le SDK de Trimble).
- Quick Look.

## Constaté

- Essai du 25 octobre 2026 : le framework se charge en **116 ms** une fois ses dylibs sœurs préchargées par chemin absolu ; il lit le fichier de **97 Mo** (`B-SEINE MUSICALE-GRANDE SALLE TECHNIQ V40.skp`, 20 scènes, 151 calques) en **2,9 s**, celui de **45 Mo** (`MM_Arles_3D_V003.skp`) en **1,9 s**, un petit fichier en 0 ms.
- Avec le SDK embarqué (copie Unity, 25 octobre 2026) : un seul `dlopen` de `Versions/A/SketchUpAPI` en **48 ms** (son `LC_RPATH @loader_path/Libraries` trouve les dylibs, rien à précharger), le fichier de 97 Mo lu en **3,0 s** à l'essai (4,9 s dans le `--self-test` du bundle debug avec `SIMPLESKP_BUNDLED_SDK_ONLY=1`). App debug : **13 Mo**, dont 11 Mo de framework aminci à arm64 sans en-têtes (22 Mo universel avec en-têtes).
- Les en-têtes officiels du SDK se lisent dans la copie Unity (`SketchUpAPI.framework/Versions/A/Headers`) ; les prototypes en sont transcrits.
