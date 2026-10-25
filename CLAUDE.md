# SimpleSKP — notes pour les agents

SimpleSKP est un visualiseur de fichiers SketchUp natif pour macOS (Swift, AppKit, SceneKit, zéro dépendance), de la famille des apps Simple de la cie Adrien M (SimpleAudio, SimplePJ, SimpleText). Adrien (spectacle vivant, maquettes de salles et de décors) est l'unique utilisateur ; il parle français et refuse Electron.

## Lire d'abord
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
Scripts/bundle.sh                             # build/SimpleSKP.app signée, release, installée dans /Applications
INSTALL=0 Scripts/bundle.sh                   # sans installer
swift Scripts/make-icon.swift                 # redessine Resources/AppIcon.icns et AppIcon.png
```

## Règles qui ont coûté cher
- **Les dylibs sœurs du framework (`@rpath`) se préchargent par chemin absolu** depuis `SketchUp.app/Contents/Frameworks` : leur `@rpath` suppose l'exécutable de SketchUp. La copie de Unity est autonome (son dossier `Libraries`).
- **`SUPoint3D` fait 24 octets** (3 `Double`) : jamais de tampon `SIMD3<Double>` (foulée 32).
- **`SUTransformation.values[15]` contient 1/échelle**, à normaliser.
- **Les `SU*Ref` sont des `struct { void* }`** : dans les `@convention(c)`, ce sont des pointeurs bruts.
- **`SUFOV` peut être une largeur ou une hauteur** : le contrat veut un FOV vertical, le Cœur convertit.
- **La signature Developer ID exige `com.apple.security.cs.disable-library-validation`** : sans lui, le runtime durci refuse de charger un framework signé par Trimble (D10).
- **`cacheDisplay` ne capture pas SceneKit** : `--snapshot` passe par `SCNView.snapshot()` (D11).
- **AppKit insère lui-même « Ouvrir l'élément récent »** (et « Plein écran ») dans l'app empaquetée : ne pas les construire à la main, vérifier le menu sur le bundle.
- **Un seul modèle lu à la fois** : l'API du SDK n'est pas sûre entre threads (verrou global).
- **Ne jamais tuer les apps d'Adrien** (eMotion, OSCScore, SimpleAudio, SketchUp tournent souvent). Lancer ses propres instances et les tuer par PID.
- `timeout` n'existe pas sur macOS : surveiller un lancement avec une boucle `kill -0`.

## Architecture en une minute
- `Sources/SimpleSKPCore/` — Foundation seulement : `SKPFileInfo` (version, vignette), `SketchUpAPI` (framework chargé par `dlopen`), `SKPReader` (fichier → `SKPModel` neutre, mètres, Z vertical), `Localization`, `SimpleUpdater`.
- `Sources/SimpleSKPViewport/` — SceneKit : `ViewportScene` (modèle → `SCNScene`, Z→Y par la racine), `ViewportView` (navigation, vues standard, caméra).
- `Sources/SimpleSKP/` — AppKit + SwiftUI : `App` (entrée et options), `AppDelegate`, `MainMenu`, `DocumentController`, `SKPDocument`, `ModelWindowController`, `DocumentModel`, `ContentView`, feuilles, `Snapshot`, `SelfTest`.
- `Resources/` — `Info.plist` (gabarit `@VERSION@`), `SimpleSKP.entitlements`, `AppIcon.icns`, `fr.lproj`, `en.lproj`.
- `Scripts/` — `bundle.sh`, `package-release.sh`, `make-icon.swift`.

## Invariants
- Un visualiseur : rien n'est modifié ni enregistré, ni dans le fichier ni ailleurs.
- Le modèle neutre est en mètres, Z vertical ; une seule rotation Z→Y, sur la racine de la scène.
- Le Cœur omet les entités masquées ; la Vue n'a rien à cacher sauf les calques.
- Aucun code ni en-tête de Trimble n'est copié ou redistribué : les prototypes sont transcrits, le framework est chargé là où il est installé.
- Rendu à la demande : pas de boucle à 60 Hz quand rien ne bouge.
- Tout nouveau comportement a un test ; un défaut corrigé a d'abord un test qui échoue.
