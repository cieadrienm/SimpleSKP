# SimpleSKP — design

Date : 2026-10-25. Demande d'Adrien : « une nouvelle app, simple, légère et élégante, pour ouvrir rapidement
les fichiers SketchUp », dans la lignée de SimpleAudio, SimplePJ et SimpleText (mêmes standards d'interface et
de manipulation), construite par plusieurs agents en parallèle et très optimisée.

## But

Double-cliquer un `.skp` et le voir en 3D **en moins d'une seconde** : orbiter, se déplacer, zoomer, sauter de
scène en scène, lire les dimensions, sans attendre les vingt secondes de SketchUp. Un visualiseur, pas un
éditeur : rien n'est modifié, rien n'est enregistré.

Usage réel : les maquettes de salles et de décors de la compagnie (`B-SEINE MUSICALE-GRANDE SALLE TECHNIQ V40.skp`,
97 Mo, 20 scènes, 151 calques ; `MM_Arles_3D_V003.skp`, 45 Mo ; 412 fichiers `.skp` sur ce Mac, de 11 Ko à 215 Mo,
versions SketchUp 8 à 2023).

## Ce qu'Adrien a demandé

- Une app de la famille Simple : palette sombre, composants, barre d'état, À propos, raccourcis, aide, `--snapshot`,
  `--self-test`, `Scripts/bundle.sh`, icône dessinée par script, zéro dépendance, quelques mégaoctets.
- Ouvrir **rapidement** les `.skp`.
- Beaucoup d'agents, tout très optimisé.

## Décisions prises pour lui (voir DECISIONS.md)

- **D1 — Le fichier est lu par le framework du SDK C de SketchUp, embarqué dans l'app** (`SketchUpAPI.framework`, API C,
  version 11.0), chargé dynamiquement (`dlopen`). Le format `.skp` est propriétaire et non documenté ; le réécrire est un travail
  de mois et casse à chaque version. **Adrien, 2026-10-25 : l'app doit fonctionner sans SketchUp installé, c'est son intérêt** ;
  le framework est donc livré dans `SimpleSKP.app/Contents/Frameworks` par `Scripts/bundle.sh` (aminci à l'architecture de la
  machine, sans en-têtes, ≈ 11 Mo), pris dans `SKETCHUP_SDK`, sinon `Vendor/SketchUpAPI.framework` (SDK officiel téléchargé chez
  Trimble, ignoré par git), sinon la copie du même SDK livrée avec Unity sur ce Mac (voir `.project-map/decisions.md` d2).
  Vérifié le 2026-10-25 par un essai : la copie autonome (dossier `Versions/A/Libraries` avec ses dylibs `libCommon*`) se charge
  en 48 ms et lit le fichier de 97 Mo en 3,0 s, celui de 45 Mo en 1,9 s, un petit en 5 ms. Chemins cherchés par l'app dans l'ordre :
  la variable `SIMPLESKP_SKETCHUP_SDK` (tests, développement), `Contents/Frameworks` de SimpleSKP.app, puis, sauf si
  `SIMPLESKP_BUNDLED_SDK_ONLY` est posée (preuve et auto-test), chaque `/Applications/SketchUp*.app` et `/Applications/SketchUp*/SketchUp*.app` (et sous `~/Applications`,
  le plus récent d'abord ; là, les dylibs sœurs se préchargent par chemin absolu, leur `@rpath` supposant l'exécutable de SketchUp),
  puis le framework livré dans Unity. Les en-têtes officiels du SDK sont lisibles dans la copie Unity (`Versions/A/Headers`) : les
  prototypes y sont transcrits, les fichiers ne sont pas copiés. Si le framework manque (bundle cassé), l'app montre la vignette PNG
  incluse dans le fichier et le dit.
- **D2 — SceneKit pour l'affichage.** Caméra, lumière, matériaux, tests de collision et contrôleur d'orbite
  fournis par le système ; des dizaines de milliers de lignes évitées par rapport à Metal nu. Les faces sont
  triangulées par `SUMeshHelper`, regroupées par (matériau, calque) en une seule géométrie par lot, les
  composants convertis une fois et instanciés (nœuds partageant la géométrie). Metal direct n'est envisagé que si
  SceneKit plafonne sur les maquettes de salle.
- **D3 — Document AppKit (`NSDocument`), comme SimpleText.** La lecture de l'en-tête (version, vignette) prend
  quelques millisecondes et s'affiche avant tout ; le modèle se charge ensuite en arrière-plan. `NSDocument`
  donne Ouvrir récent, l'association Finder, la restauration des fenêtres, plusieurs fichiers ouverts. SwiftUI sert
  à l'habillage (barre latérale, barre d'état, feuilles) dans des `NSHostingView`. Le menu est construit en code,
  en français (leçon D14 de SimpleText : AppKit insère lui-même « Ouvrir l'élément récent » et « Plein écran »).
- **D4 — Paquet SwiftPM, macOS 15, outils 6.0, mode Swift 5, trois cibles** : `SimpleSKPCore` (sans AppKit :
  en-tête du fichier, chargeur du framework, lecture en modèle neutre), `SimpleSKPViewport` (SceneKit : scène,
  navigation), `SimpleSKP` (app). Trois cibles pour que trois agents compilent chacun la sienne en parallèle.
- **D5 — Unités : mètres, Z vers le haut dans le modèle neutre.** SketchUp compte en pouces (×0,0254) avec Z
  vertical ; SceneKit a Y vertical : une seule rotation de −90° autour de X sur le nœud racine, rien d'autre ne
  change de repère. Les dimensions de la barre d'état sont en mètres (une décimale).
- **D6 — Déplacement : quatre façons qui coexistent, aucune « à la SketchUp »** (Adrien, 2026-10-25 : « je n'aime pas du tout le
  moyen de se déplacer dans SketchUp » ; il a retenu les quatre propositions). Une seule caméra interne (position, lacet, tangage,
  distance à la cible ; horizon toujours droit) animée par un pas de temps à 60 Hz seulement quand quelque chose bouge (inertie,
  touches tenues, glissement vers une scène), sinon rendu à la demande.
  - *Orbite fluide (souris, défaut)* : glisser gauche = orbite autour du point visé au clic (test de collision, sinon la cible),
    inertie douce (arrêt en ~0,4 s) ; ⇧-glisser ou bouton du milieu = panoramique ; molette = zoom vers le curseur (dolly en
    perspective, échelle + translation en parallèle) ; double-clic = recentrer et cadrer le point.
  - *Éditeur de jeu (Unity, Unreal, eMotion)* : clic droit maintenu = regarder autour (lacet/tangage depuis la position) ; tant que
    le bouton est tenu ou que la vue a le focus clavier : ZQSD/WASD par touche physique (`keyCode`, donc ZQSD sur AZERTY) et
    flèches = avancer, reculer, pas latéral ; espace/E = monter, C = descendre ; ⇧ = ×4 ; molette avec clic droit tenu = change la
    vitesse. Vitesse de base proportionnelle à la diagonale du modèle (≈ diagonale / 8 par seconde, bornée à 0,5–50 m/s).
  - *Gestes trackpad (Apple)* : défilement à deux doigts (événements à phases, deltas précis) = orbite ; pincement = zoom vers le
    curseur ; ⌥ + deux doigts = panoramique ; rotation à deux doigts = lacet autour de la verticale (pas de roulis). Un réglage
    « Défilement à deux doigts : orbite / zoom » existe pour les souris Magic Mouse (défaut : orbite).
  - *Vol libre* (⌥⌘F, Échap pour sortir, item coché dans Présentation) : curseur caché et capturé, la souris oriente sans clic,
    le clavier déplace comme ci-dessus.
  - Communs : ⇧Z = zoom étendu sur les calques visibles ; ⌘1…⌘7 = vues standard ; ⌥⌘P = perspective / parallèle ; les scènes
    glissent en 0,35 s ; une touche ou un clic interrompt toute animation.
- **D7 — Rendu « réaliste doux »** (Adrien, 2026-10-25 : « metal, shading, on doit pouvoir faire bien mieux ») : SceneKit rend par
  Metal ; on en tire le maximum avant d'envisager un moteur maison. Matériaux physiques (`physicallyBased`, rugosité 0,85, métal 0,
  couleurs et textures du fichier, double face, verre par `.dualLayer`) ; soleil directionnel (azimut 135°, élévation 45° dans le
  repère du modèle, intensité 1 000 lux-équivalents) avec ombres portées douces en cascades (3 cascades, carte 2 048, `shadowRadius`
  3, projection automatique sur les calques visibles) ; environnement lumineux = ciel dégradé procédural (équirectangulaire généré en
  code : zénith bleu doux, horizon blanc chaud, sol gris) aussi utilisé en fond de la vue ; caméra HDR sans adaptation d'exposition,
  occlusion ambiante écran (intensité 1, rayon 0,4 m), anticrénelage ×4, pas de bloom ni de flou. Arêtes gardées mais discrètes
  (gris à 35 % de la face, 1 px, ⌘E), biais de profondeur comme avant. Deux interrupteurs dans Présentation : Ombres (⌥⌘O) et
  Occlusion ambiante (⌥⌘A), cochés par défaut, mémorisés. Fluidité : un appel de dessin par (ensemble de calques, matériau) grâce à
  la fusion des instances (cible ≥ 30 i/s sur la salle de 97 Mo en iso, mesuré par `SCNRenderer`) ; si une scène dépasse 33 ms,
  les ombres passent à 1 cascade / 1 024 automatiquement et le dit dans la barre d'état.
- **D8 — Pas d'OSC, d'API HTTP ni de MCP** : rien à piloter dans un visualiseur (même raisonnement que SimpleText).
  Pas d'export, pas d'édition, pas de sections, pas d'ombres, pas de styles SketchUp.
- **D9 — Interface en français avec `L("fr", "en")`** et `Localization` de la famille, `fr.lproj` et `en.lproj`
  minimaux pour qu'AppKit parle français. `SimpleUpdater` repris de SimplePJ (dépôt `cieadrienm/SimpleSKP`).
- **D10 — Identifiant `net.cieadrienm.simpleskp`**, version `1.0.0` dans `Scripts/bundle.sh` seulement, rôle
  `Viewer` sur le type `com.sketchup.skp` (déclaration importée, extension `skp`, rang `Alternate` : SketchUp
  reste propriétaire). Le framework embarqué est re-signé avec l'identité de SimpleSKP par
  `Scripts/bundle.sh`, donc la validation de bibliothèque du runtime durci (Developer ID) passe sans entitlement ; l'entitlement
  `com.apple.security.cs.disable-library-validation` est gardé (inoffensif) pour le cas d'un framework laissé signé par Trimble.
  Signature Apple Development sans runtime durci sinon, comme les sœurs.
- **D11 — Vérifier sans écran** : `--snapshot sortie.png [fichier.skp]` photographie la fenêtre avec le modèle
  chargé (la vue SceneKit se capture par `SCNView.snapshot()`, `cacheDisplay` ne voyant pas Metal) ;
  `--self-test [fichier.skp]` vérifie l'en-tête, la présence du framework, la construction de scène sur un modèle
  synthétique (cube), le chargement d'un vrai fichier si donné, et un PNG non uniforme.

## La fenêtre

```
┌ ● ● ●                        🧊 B-SEINE MUSICALE-GRANDE SALLE TECHNIQ V40.skp                               ┐
│ SCÈNES              20 │                                                                                    │
│ ▸ Vue régie            │                                                                                    │
│   Plan plateau         │                                                                                    │
│   Coupe longitudinale  │                        (vue 3D SceneKit, fond Theme.background,                    │
│   …                    │                         faces blanches, arêtes sombres, orbite au glisser)         │
│ CALQUES            151 │                                                                                    │
│ ☑ Décor                │                                                                                    │
│ ☑ Lumière              │                                                                                    │
│ ☐ Cotes                │                                                                                    │
│ ☑ …                    │                                                                                    │
├────────────────────────┴────────────────────────────────────────────────────────────────────────────────────┤
│ SketchUp 2018 · 184 320 faces · 61 002 arêtes · 383 composants · 48,0 × 31,5 × 22,0 m │ 4,1 s · ? aide  ⌘/ raccourcis  v1.0.0 │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

- Barre de titre native (icône du document, nom). Pas de barre d'outils : tout est au clavier, au menu et dans la
  barre d'état.
- Barre latérale de 220 points, masquable (⌥⌘S), masquée d'elle-même quand le fichier n'a ni scène ni plus d'un
  calque : liste des scènes (clic → la caméra glisse vers la scène en 0,35 s et ses calques masqués s'appliquent),
  liste des calques avec cases (visibilité immédiate). `SectionHeader` de la famille.
- Pendant le chargement : la vignette PNG du fichier remplit la vue, estompée, avec « Chargement… 12 400 faces »
  dans la barre d'état ; elle disparaît en fondu quand la 3D arrive.
- Sans SketchUp installé : la vignette nette et un bandeau « SketchUp introuvable — installez SketchUp (ou déposez
  SketchUpAPI.framework dans SimpleSKP.app/Contents/Frameworks) pour voir le modèle en 3D ».
- Barre d'état de 26 points (celle de SimplePJ) : version SketchUp du fichier, faces, arêtes, composants,
  dimensions L × l × H en mètres ; à droite le temps de chargement, `? aide`, `⌘/ raccourcis`, la version
  (clic → À propos).
- Feuilles de la famille : À propos (avec le chemin du framework trouvé et sa version), Raccourcis, Aide
  (manuel court), Mise à jour, Réglages (langue).
- Glisser-déposer d'un `.skp` sur la fenêtre ou l'icône : l'ouvre.

## Les parties

1. **Cœur** (`Sources/SimpleSKPCore`, Foundation seulement)
   - `SKPFileInfo` : lit le premier mégaoctet : version (`{17.3.116}` en UTF-16 après « SketchUp Model »),
     vignette PNG (signature `‰PNG` … `IEND`), taille. Libellé « SketchUp 2017 » depuis le numéro majeur
     (8 → 8, 13 → 2013, 14 → 2014 … 23 → 2023 ; 2021+ partagent le format).
   - `SketchUpAPI` : localisation du framework, préchargement des dylibs sœurs, `dlsym` de chaque fonction en
     table de pointeurs `@convention(c)` (les `SU*Ref` sont des `struct { void* }`, passés comme
     `UnsafeMutableRawPointer?`), `SUInitialize` une fois, verrou global : un seul modèle lu à la fois (l'API
     n'est pas sûre entre threads).
   - `SKPModel` : modèle neutre (ci-dessous), `Sendable`, en mètres, Z vertical.
   - `SKPReader.load(url, progress:, isCancelled:)` : prototypes transcrits des en-têtes du SDK (copie Unity) ;
     tableaux C reçus dans des `struct` Swift de même disposition (`SUPoint3D` = 3 `Double`, 24 octets : jamais
     `SIMD3<Double>`, dont la foulée est 32) ; `SUTransformation.values[15]` normalisé (SketchUp y range 1/échelle) ;
     parcourt récursivement entités, groupes et instances ;
     chaque définition de composant est convertie **une seule fois** ; faces triangulées par `SUMeshHelper`
     (sommets, normales, UV avant) et fusionnées par (matériau, calque) en un lot ; arêtes non adoucies en
     paires de points par calque ; matériaux (couleur, opacité, texture écrite en fichier) ; calques ; scènes
     (nom, caméra, calques masqués) ; caméra active ; boîte englobante ; statistiques et durée. Les tableaux sont
     réservés à la bonne taille (`reserveCapacity` d'après `SUMeshHelperGetNumVertices`), pas de `Double` en
     sortie, pas de classe par sommet.
   - `Localization`, `SimpleUpdater` : copiés de SimplePJ, identifiant changé.
2. **Vue 3D** (`Sources/SimpleSKPViewport`, SceneKit + AppKit)
   - `ViewportScene(model:)` : construit la `SCNScene` : racine tournée Z→Y, un `SCNNode` par définition
     (géométries par lot, `SCNGeometrySource(data:)` sur des `Float`, indices `UInt32`, éléments triangles ;
     arêtes en élément `.line`), instances par `clone()` (géométrie partagée), matériaux `lambert`,
     `isDoubleSided`, transparence par opacité, textures `NSImage` depuis le fichier écrit ; visibilité par
     calque (`setLayer(_:visible:)` parcourt les nœuds marqués) ; lumières (phare sur la caméra + ambiante).
   - `ViewportView: SCNView` : navigation D6 par surcharge des événements et `defaultCameraController`
     (`rotateBy`, `translateInCameraSpaceBy`, `dolly(by:onScreenPoint:viewport:)`), `zoomExtents`,
     `look(_ standard: StandardView)`, `apply(camera:animated:)` (position, cible, haut, perspective ou
     hauteur orthographique), `showsEdges`, `isPerspective`, `rendersContinuously = false`.
3. **App** (`Sources/SimpleSKP`, AppKit + SwiftUI)
   - `App` (entrée : `--version`, `--self-test`, `--snapshot`, sinon `NSApplicationMain`), `AppDelegate`,
     `MainMenu` (Fichier, Édition minimale, Présentation, Caméra, Fenêtre, Aide), `DocumentController`
     (type `.skp`, panneau d'ouverture), `SKPDocument: NSDocument` (lecture de l'en-tête, lancement du
     chargement en arrière-plan sur `DispatchQueue.global(qos: .userInitiated)`, annulation à la fermeture),
     `ModelWindowController`, `DocumentModel` (`@Observable` : info, vignette, état `loading(progress)` /
     `ready(model)` / `failed(error)`, scène courante, visibilité des calques, options de vue),
     `ContentView` (barre latérale + `ViewportRepresentable` + `StatusBar`), `Theme`, `Components` (copiés),
     `AboutSheet`, `ShortcutsSheet`, `HelpManualSheet`, `UpdateSheet`, `PreferencesView`, `Snapshot`,
     `SelfTest`, `AppVersion`.
4. **Livraison** (`Scripts/`, `Resources/`, docs) : `bundle.sh` (de SimplePJ, adapté D10, entitlements),
   `package-release.sh`, `make-icon.swift` (tuile sombre de la famille, cube isométrique aux arêtes ambre
   `FFB454` et cyan `5CE1E6`), `Info.plist` gabarit, `*.lproj`, `LICENSE` GPL v3, `README.md`, `CHANGELOG.md`,
   `CLAUDE.md`, `DECISIONS.md`, `.gitignore`.

## Contrat entre les parties (Swift, figé avant le travail en parallèle)

```swift
// SimpleSKPCore
public struct SKPFileInfo: Sendable {
    public let url: URL; public let fileSize: Int
    public let version: String?          // "17.3.116"
    public let versionLabel: String?     // "SketchUp 2017"
    public let thumbnailPNG: Data?
    public static func read(_ url: URL) throws -> SKPFileInfo
}

public enum SketchUpAPI {
    public struct Location: Sendable { public let frameworkURL: URL; public let appVersion: String? }
    public static func locate() -> Location?
    public static var isAvailable: Bool { get }
}

public struct SKPModel: Sendable {
    public struct Material: Sendable { public var name: String; public var color: SIMD4<Float>; public var opacity: Float; public var textureURL: URL?; public var textureScale: SIMD2<Float> }
    public struct Layer: Sendable { public var name: String; public var isVisible: Bool }
    public struct Mesh: Sendable { public var material: Int?; public var layer: Int; public var positions: [SIMD3<Float>]; public var normals: [SIMD3<Float>]; public var uvs: [SIMD2<Float>]?; public var indices: [UInt32] }
    public struct EdgeSet: Sendable { public var layer: Int; public var positions: [SIMD3<Float>] }   // paires
    public struct Instance: Sendable { public var definition: Int; public var transform: simd_float4x4; public var layer: Int; public var isGroup: Bool; public var material: Int?; public var name: String }
    // Chaque groupe a sa propre entrée dans `definitions` (jamais partagée) ; les composants partagent la leur.
    // Les entités masquées (faces, arêtes, groupes, instances) sont omises par le Cœur : rien à cacher dans la Vue.
    public struct Definition: Sendable { public var name: String; public var meshes: [Mesh]; public var edges: [EdgeSet]; public var children: [Instance] }
    public struct Camera: Sendable { public var position: SIMD3<Float>; public var target: SIMD3<Float>; public var up: SIMD3<Float>; public var isPerspective: Bool; public var fovDegrees: Float; public var orthoHeight: Float }
    // Caméra en mètres, Z vertical, `fovDegrees` toujours VERTICAL (le Cœur convertit si SketchUp donne la largeur,
    // via l'aspect de la caméra) ; la Vue place le nœud caméra sous la racine tournée et prend ces valeurs telles quelles.
    public struct Scene: Sendable { public var name: String; public var camera: Camera?; public var hiddenLayers: [Int]? }   // nil : la scène n'enregistre pas la visibilité des calques
    public struct Stats: Sendable { public var faces, triangles, edges, instances, definitions: Int; public var loadSeconds: Double }
    public var root: Definition; public var definitions: [Definition]   // root.children → definitions[i]
    public var materials: [Material]; public var layers: [Layer]; public var scenes: [Scene]
    public var camera: Camera?; public var boundsMin: SIMD3<Float>; public var boundsMax: SIMD3<Float>
    public var stats: Stats; public var fileInfo: SKPFileInfo
    public var loadWarning: String?   // ex. fichier enregistré par un SketchUp plus récent (statut 1) : chargé quand même
}

public enum SKPError: Error, LocalizedError { case sketchUpNotFound(searched: [URL]); case api(function: String, code: Int32); case unreadable(URL); case cancelled }

public enum SKPReader {
    public struct Progress: Sendable { public var phase: String; public var faces: Int }
    public static func load(_ url: URL, progress: (@Sendable (Progress) -> Void)? = nil, isCancelled: @Sendable () -> Bool = { false }) throws -> SKPModel
}

// SimpleSKPViewport
public enum StandardView: CaseIterable { case iso, top, bottom, front, back, left, right }
public final class ViewportScene {        // construisible HORS du thread principal, juste après SKPReader.load
    public init(model: SKPModel); public let model: SKPModel; public let scene: SCNScene
    public func setLayer(_ index: Int, visible: Bool); public var showsEdges: Bool
}
public final class ViewportView: SCNView {
    public func present(_ scene: ViewportScene)     // sur le thread principal : affiche, caméra du fichier sinon zoom étendu
    public private(set) var viewportScene: ViewportScene?
    public func zoomExtents(animated: Bool)
    public func look(_ view: StandardView, animated: Bool)
    public func apply(camera: SKPModel.Camera, animated: Bool)
    public var isPerspective: Bool
}
```

## Performance visée (mesurée dans le README)

| Mesure | Cible |
|---|---|
| Lancement de l'app empaquetée → vignette visible | < 0,3 s |
| `04-Monticule.skp` (157 Ko) → 3D visible | < 0,5 s |
| `MM_Arles_3D_V003.skp` (45 Mo) → 3D | < 4 s (lecture API 1,9 s) |
| `B-SEINE MUSICALE…V40.skp` (97 Mo) → 3D | < 7 s (lecture API 2,9 s) |
| Orbite sur la salle | 60 i/s sur Apple Silicon |
| Mémoire | ≤ 3 × la taille du fichier |
| Binaire | ≈ 3 Mo |

Moyens : vignette d'abord ; lecture sur un thread ; une géométrie par lot ; instances par géométrie partagée ;
`Float` partout ; rendu à la demande ; aucun service réseau au lancement ; pas de `print` dans les boucles.

## Vérification

- `swift build`, `swift test` : Cœur (en-tête, vignette, libellé de version, conversion pouces→mètres et
  `SUTransformation`→`simd_float4x4`, lecture de `Tests/Fixtures/VerreMirroir.skp` : 18 faces, 36 arêtes,
  2 matériaux — `XCTSkip` sans SketchUp), Vue 3D (scène d'un cube synthétique : un nœud par définition, Z→Y,
  calque masqué, caméra appliquée), App (document ouvert, PNG d'instantané non uniforme dans la vue).
- `.build/debug/SimpleSKP --self-test [fichier.skp]`, `--snapshot /tmp/simpleskp.png [fichier.skp]`.
- `Scripts/bundle.sh` puis ouverture des trois fichiers de référence, temps relevés dans le README.

## Phases (chaque phase = un agent, 1 à 4 en parallèle après le squelette)

0. **Squelette** (agent principal) : `Package.swift`, contrat ci-dessus en code compilable (corps `fatalError`
   où il faut), fixture, ce design, `DECISIONS.md`, `.project-map/decisions.md`.
1. **Cœur** : `SketchUpAPI`, `SKPFileInfo`, `SKPReader`, tests.
2. **Vue 3D** : `ViewportScene`, `ViewportView`, tests.
3. **App** : document, fenêtre, menu, habillage, feuilles, instantané, auto-test, tests.
4. **Livraison** : scripts, icône, plist, strings, README, CHANGELOG, CLAUDE.md, DECISIONS.md.
5. **Intégration et revue** (agent principal puis agent de revue) : build, tests, instantanés des trois
   fichiers, mesures, revue de performance, carte du projet, commit.

## Remis à plus tard

Export (OBJ, USDZ), ombres et styles SketchUp, plans de section, mesure à la souris, thème clair, pilotage
OSC / MCP, lecture sans SketchUp (parseur maison), Quick Look.

## Laissé au constructeur

Le détail des feuilles (textes de l'aide), la forme exacte de l'icône, l'organisation interne des fichiers de
chaque cible, le choix entre `SCNView.snapshot()` composé et `CGWindowListCreateImage` pour l'instantané, tant
que le PNG montre la 3D.
