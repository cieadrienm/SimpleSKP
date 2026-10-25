# SimpleSKP — notes pour les agents

SimpleSKP est un visualiseur de fichiers SketchUp natif pour macOS (Swift, AppKit, SceneKit, zéro dépendance), de la famille des apps Simple de la cie Adrien M (SimpleAudio, SimplePJ, SimpleText). Adrien (spectacle vivant, maquettes de salles et de décors) est l'unique utilisateur ; il parle français et refuse Electron.

## Lire d'abord
- `~/Programmation/SimpleFamily/GUIDELINES.md` — le guide de référence de la famille **Simple** (identité, barre d'outils, raccourcis `Z` / `⇧Z`, fenêtres À propos / Guide / Raccourcis / Réglages, CLI `--snapshot` / `--self-test`).
- `DECISIONS.md` — D1…D11, le pourquoi de chaque choix, et ce qui est remis à plus tard. **Ajouter une entrée pour tout choix structurant.**
- `docs/superpowers/specs/2026-10-25-simpleskp-design.md` — le design, le contrat entre les cibles et les phases.
- `Sources/SimpleSKPCore/SKPModel.swift` — le contrat figé entre Cœur, Vue 3D et App.
- `README.md` — fonctionnalités, raccourcis, performance.

## Façon de travailler
- Répondre en français. Code, commentaires et commits en anglais, avec la ligne `Co-Authored-By` de l'harnais.
- Dépôt : GitHub `cieadrienm/SimpleSKP` ; aucun push sans Adrien. Un commit par phase, `swift build` et `swift test` verts.
- Version : `VERSION` dans `Scripts/bundle.sh`, changée là seulement (correctif : x.y.Z ; fonction : x.Y.0), avec une entrée dans `CHANGELOG.md` et un tag git `vX.Y.Z` quand Adrien déploie.
- Les décisions à prendre vont dans `.project-map/decisions.md` (question, options, défaut, date) ; sans réponse, continuer avec le défaut.

## Build et tests
```
swift build                                   # .build/debug/SimpleSKP
swift test                                    # SimpleSKPCoreTests + SimpleSKPViewportTests + SimpleSKPAppTests
.build/debug/SimpleSKP --self-test [fichier.skp]
.build/debug/SimpleSKP --snapshot /tmp/simpleskp.png [fichier.skp]
SIMPLESKP_SNAPSHOT_WINDOW=about .build/debug/SimpleSKP --snapshot /tmp/skp-about.png   # about|shortcuts|help|settings
SIMPLESKP_SNAPSHOT_MENU=Présentation .build/debug/SimpleSKP --snapshot /dev/null [fichier.skp]   # liste le menu validé
Scripts/bundle.sh                             # build/SimpleSKP.app signée avec le SDK SketchUp, release, installée dans /Applications
                                              # SDK : $SKETCHUP_SDK, sinon Vendor/SketchUpAPI.framework, sinon la copie Unity
SIMPLESKP_BUNDLED_SDK_ONLY=1 build/SimpleSKP.app/Contents/MacOS/SimpleSKP --self-test f.skp   # preuve sans SketchUp
INSTALL=0 Scripts/bundle.sh                   # sans installer
swift Scripts/make-icon.swift                 # redessine Resources/AppIcon.icns et AppIcon.png
```

## Règles qui ont coûté cher
- **SimpleSKP doit marcher sans SketchUp** (D1) : le SDK est livré dans l'app. **Ne jamais commiter `Vendor/`** (SDK Trimble, licence SDK, pas GPL).
- **Les dylibs sœurs du framework (`@rpath`) se préchargent par chemin absolu** depuis `SketchUp.app/Contents/Frameworks` : leur `@rpath` suppose l'exécutable de SketchUp. La copie de Unity est autonome (son dossier `Libraries`).
- **`SUPoint3D` fait 24 octets** (3 `Double`) : jamais de tampon `SIMD3<Double>` (foulée 32).
- **`SUTransformation.values[15]` contient 1/échelle**, à normaliser.
- **Les `SU*Ref` sont des `struct { void* }`** : dans les `@convention(c)`, ce sont des pointeurs bruts.
- **`SUFOV` peut être une largeur ou une hauteur** : le contrat veut un FOV vertical, le Cœur convertit.
- **Le framework embarqué est re-signé avec l'identité de l'app**, dylibs d'abord, avant l'app (`bundle.sh`) ; l'entitlement `disable-library-validation` reste, inoffensif (D10).
- **`cacheDisplay` ne capture pas SceneKit** : `--snapshot` passe par `SCNView.snapshot()` (D11).
- **AppKit insère lui-même « Ouvrir l'élément récent »** (et « Plein écran ») dans l'app empaquetée : ne pas les construire à la main, vérifier le menu sur le bundle.
- **Un seul modèle lu à la fois** : l'API du SDK n'est pas sûre entre threads (verrou global).
- **Ne jamais tuer les apps d'Adrien** (eMotion, OSCScore, SimpleAudio, SketchUp tournent souvent). Lancer ses propres instances et les tuer par PID.
- **Navigation (D6) : une seule caméra, `CameraRig`** (modèle, Z vertical, lacet/tangage, pas de roulis) ; jamais de `SCNTransaction` ni de `defaultCameraController` pour bouger la caméra, sinon un clic ne peut plus interrompre. Les touches de déplacement se lisent par `keyCode` (ZQSD AZERTY = WASD QWERTY). Tout chemin qui cache le curseur (clic droit, vol libre) le rend à la perte du focus : tests à l'appui.
- **`SCNView.hitTest` ne trouve rien avant la première image** : le point visé se cherche par `hitTestWithSegment` sur la racine du modèle, arêtes exclues (touchées avec une tolérance, hors surface).
- `timeout` n'existe pas sur macOS : surveiller un lancement avec une boucle `kill -0`.

## Architecture en une minute
- `Sources/SimpleSKPCore/` — Foundation seulement : `SKPModel.swift` (le contrat figé), `SKPFileInfo` (version, vignette), `SketchUpAPI` (framework chargé par `dlopen`), `SKPReader` (fichier → `SKPModel` neutre, mètres, Z vertical), `OSCAndHTTP` (encodeur/décodeur OSC 1.0, serveur UDP, arbre OSCQuery), `Localization`, `SimpleUpdater`.
- `Sources/SimpleSKPViewport/` — SceneKit : `ViewportScene` (modèle → `SCNScene`, Z→Y par la racine), `CameraRig` (la caméra unique de D6 : position, lacet, tangage, inertie, touches, 60 Hz seulement en mouvement), `ViewportView` (événements souris, clavier, trackpad, vol libre ; vues standard ; optique FOV / focale 24×36 / exposition HDR).
- `Sources/SimpleSKP/` — AppKit + SwiftUI : `App` (entrée et options), `AppDelegate`, `MainMenu`, `DocumentController`, `SKPDocument`, `ModelWindowController`, `DocumentModel`, `RemoteControlServer` (OSC `:9150`, retour `:9151`, HTTP `/v1` + OSCQuery `:17950`, Bonjour `_oscjson._tcp.`), `ContentView`, feuilles, `Snapshot`, `SelfTest`.
- `Sources/SimpleSKPMCPCore/` & `Sources/simpleskp-mcp/` — Serveur MCP stdio (`simpleskp-mcp`) relayant vers l'API HTTP `/v1`.
- `Resources/` — `Info.plist` (gabarit `@VERSION@`), `SimpleSKP.entitlements`, `AppIcon.icns`, `fr.lproj`, `en.lproj`.
- `Scripts/` — `bundle.sh`, `package-release.sh`, `make-icon.swift`.

## Invariants
- Un visualiseur : rien n'est modifié ni enregistré, ni dans le fichier ni ailleurs.
- Le modèle neutre est en mètres, Z vertical ; une seule rotation Z→Y, sur la racine de la scène.
- Le Cœur omet les entités masquées ; la Vue n'a rien à cacher sauf les calques.
- Aucun code ni en-tête de Trimble n'est copié dans les sources : les prototypes sont transcrits ; seul le framework binaire du SDK est livré dans l'app (sans en-têtes).
- Rendu à la demande : pas de boucle à 60 Hz quand rien ne bouge.
- Tout nouveau comportement a un test ; un défaut corrigé a d'abord un test qui échoue.
