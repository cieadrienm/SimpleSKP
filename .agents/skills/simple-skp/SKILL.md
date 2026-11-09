---
name: simple-skp
description: >-
  Expert 3D stage model inspection, camera framing, and video projector placement & calibration
  for SimpleSKP (macOS) via local MCP tools (simpleskp_*), HTTP API (/v1 on port 17950), and .sskp projects.
  Activate this skill whenever viewing SketchUp (.skp), AutoCAD (.dwg, .dxf), Collada (.dae), Wavefront (.obj),
  Autodesk FBX (.fbx), Khronos glTF/GLB (.glb, .gltf), 3D Gaussian Splats (.ply, .splat, .spz), or Point Clouds (.xyz, .pts, .pcd) files,
  planning video projections, calculating throw ratios or lens shifts, verifying optical coverage/occlusions,
  or calibrating stage projectors.
---

# SimpleSKP — 3D Inspection & Video Projection Skill (`cie Adrien M`)

Ce skill fournit l'expertise complète pour manipuler **SimpleSKP**, le visualiseur 3D natif macOS de la **cie Adrien M** pour maquettes SketchUp (`.skp`), plans CAD (`.dwg`, `.dxf`), modèles 3D (`.dae`, `.obj`, `.fbx`, `.glb`, `.gltf`), **3D Gaussian Splats** (`.ply`, `.splat`, `.spz`) et **nuages de points 3D** (`.ply`, `.xyz`, `.pts`, `.pcd`), et exploiter son **moteur optique intégré de simulation de vidéoprojecteurs** (placement dans l'espace scénique, réglage optique fin, calculs de couverture, décentrement lens shift, et occlusions d'ombres portées).

---

## 1. Formats 3D, CAD, Gaussian Splats & Nuages de Points Pris en Charge

- **Maquettes & Modèles 3D surfaciques** :
  - `.skp` (SketchUp 3 à 2026 via SDK C embarqué)
  - `.glb` et `.gltf` (Khronos glTF 2.0 binaire et JSON : graphe de scène complet, conversion automatique $Y\text{-up} \to Z\text{-up}$ métrique, matériaux PBR, sélection `TEXCOORD_0` / `TEXCOORD_1` et `KHR_texture_transform`, textures embarquées `bufferView` / `data:` / externes, couleurs par sommet `COLOR_0`, arêtes d'architecture et caméras)
  - `.fbx` (Autodesk FBX binaire et ASCII via `ufbx` embarqué, conversion métrique et axe $Z$ vertical automatiques, instances, matériaux PBR, textures embarquées/externes, calques et caméras)
  - `.dae` (Collada) et `.obj` (Wavefront OBJ + `.mtl`)
- **Plans & Dessins CAD** :
  - `.dwg` et `.dxf` (AutoCAD, calibration métrique automatique, recentrage géodésique et cadrage 2D vue de dessus)
- **3D Gaussian Splats & Nuages de Points (Rendu GPU Metal instancié)** :
  - `.ply` : auto-détection entre **3D Gaussian Splats** (covariance 3D anisotrope + harmoniques sphériques SH0–SH3), **Nuage de points 3D** et **Maillage polygonal** (binaire Little/Big Endian et ASCII)
  - `.splat` : format 3DGS compact 32 octets/splat (`antimatter15`)
  - `.spz` : format 3DGS compressé gzip (`NGSP` v1–v3 Niantic / Scaniverse)
  - `.xyz`, `.pts`, `.pcd` : nuages de points LiDAR / scanner 3D (ASCII et binaire)
  - Tous les nuages de points et Gaussian Splats supportent le raycasting CPU rapide (blocs de Morton de 256 splats) pour le pivot d'orbite, le double-clic de recentrage, l'outil de mesure (`⌘D`) et les styles de rendu (*Texturé*, *Maquette*, *Rayons X*, *Filaire/Points*).

---

## 2. Principes de Navigation & Coordonnées Scéniques

- **Système de coordonnées** :
  - Unités : **Mètres**, convention scénographique **$Z$ vertical** (haut).
  - Le plan $(X, Y)$ correspond au sol de scène ($+X$ cour / droite, $-X$ jardin / gauche, $+Y$ lointain, $-Y$ face).
- **Navigation & Caméra unique (`CameraRig`)** :
  - Caméra à inertie fluide (ProMotion 60–120 Hz à la demande).
  - Vues standard : `'top'` (plan de sol / grill), `'front'` (vue face salle), `'left'` / `'right'`, `'iso'`.
  - Cadrage rapide : `Z` (réinitialiser), `⇧Z` ou `F` (cadrer tout le modèle).
  - Contrôle optique : FOV vertical (10°…120°), focale équivalente 24×36 (5…135 mm), exposition HDR (EV −3…+3).

---

## 2. Moteur Optique de Vidéoprojection (`VideoProjector`)

SimpleSKP intègre un modèle optique physique précis permettant de simuler l'implantation de vidéoprojecteurs réels sur la scénographie.

### A. Paramètres Fondamentaux d'un Vidéoprojecteur

| Paramètre | Type / Unités | Description & Rôle Scénographique |
|---|---|---|
| **`position`** | `SIMD3<Float>` (m) | Coordonnées $(X, Y, Z)$ du centre optique de l'objectif dans la maquette (accroche pont, perche, sol). |
| **`target`** | `SIMD3<Float>` (m) | Point $(X, Y, Z)$ visé par l'axe optique central (centre écran, sol, praticable). |
| **`specID`** | `String` | Modèle optique du catalogue (résolution native, ratio de zoom, décentrement maximal). |
| **`throwRatio`** | `Float` | Rapport d'ouverture $D / L$ (distance de projection divisée par la largeur d'image). |
| **`lensShiftH`** | `Float` (−1.0…+1.0) | Décentrement optique horizontal en fraction de la largeur d'image (sans déformation trapézoïdale). |
| **`lensShiftV`** | `Float` (−1.0…+1.0) | Décentrement optique vertical en fraction de la hauteur d'image (décalage vers le haut ou le bas). |
| **`rollDegrees`** | `Float` (degrés) | Rotation autour de l'axe optique : `0°` (table), `180°` (accroche plafond/pont inversée), `±90°` (portrait). |
| **`panDegrees`** | `Float` (−180°…+180°) | Azimut horizontal (`0°` = plein lointain $+Y$, `90°` = cour $+X$, `−90°` = jardin $-X$). |
| **`tiltDegrees`** | `Float` (−89.5°…+89.5°) | Inclinaison verticale (`0°` = horizontal, `−90°` = plongée totale vers le sol, `+90°` = zénith). |
| **`pattern`** | Enum | Mire projetée : `testGrid` (grille de calage), `colorBars`, `whiteFrame`, ou `customImage`. |
| **`intensity`** | `Float` (0.0…3.0) | Multiplicateur de puissance lumineuse. |
| **`showsFrustum`**| `Bool` | Affichage 3D du volume pyramidal de projection et du boîtier du projecteur dans la scène. |

---

### B. Catalogue des Modèles Intégrés (`ProjectorCatalog`)

SimpleSKP intègre les spécifications exactes des projecteurs professionnels utilisés par la compagnie (notamment la gamme laser DuraCore Optoma) :

1. **Optoma ZU920ST (`optoma-zu920st`)** *(Modèle de référence cie Adrien M)* :
   - WUXGA ($1920 \times 1200$, ratio 16:10), **9 800 lumens ANSI**.
   - Focale courte : **Throw Ratio 0.65 – 0.75:1** (zoom optique).
   - Lens Shift motorisé exceptionnel : **$H \pm 25\%$**, **$V \pm 55\%$**.
   - Dimensions châssis : $48.6 \times 43.3 \times 17.6\text{ cm}$.
2. **Optoma ZU920T (`optoma-zu920t`)** :
   - Focale standard : **Throw Ratio 1.25 – 2.00:1**, $H \pm 25\%$, $V \pm 55\%$, 9 800 lm.
3. **Optoma ZU725TST (`optoma-zu725tst`)** :
   - Focale courte : **0.65 – 0.75:1**, $H \pm 25\%$, $V \pm 55\%$, 7 500 lm.
4. **Optoma ZU606TSTE (`optoma-zu606tste`)** :
   - Focale fixe courte : **0.79:1**, offset vertical natif $V \pm 60\%$, 6 300 lm.
5. **Optoma ZH450ST (`optoma-zh450st`)** :
   - Ultra-compact Full HD 1080p ($1920 \times 1080$, 16:9), focale fixe **0.496:1**, offset $V \pm 66\%$, 4 200 lm.
6. **Optoma ZH406ST (`optoma-zh406st`)** :
   - Full HD 1080p, focale fixe **0.50:1**, offset $V \pm 65\%$, 4 200 lm.

---

### C. Formules & Règles Métier de Projection

1. **Distance de projection ($D$)** :
   $$D = \|\mathbf{target} - \mathbf{position}\|$$
2. **Dimensions de l'image au point visé** :
   $$\text{Largeur } L = \frac{D}{\text{throwRatio}}$$
   $$\text{Hauteur } H = \frac{L}{\text{aspectRatio}} \quad (\text{avec } 1.6 \text{ pour WUXGA, } 1.777 \text{ pour 16:9})$$
   $$\text{Diagonale } = \sqrt{L^2 + H^2}$$
3. **Déplacement du centre de projection par Lens Shift** :
   $$\Delta X = \text{lensShiftH} \times L \quad (\text{vers la droite ou la gauche sans trapèze})$$
   $$\Delta Y = \text{lensShiftV} \times H \quad (\text{vers le haut ou le bas})$$
4. **Atténuation par incidence de surface (Loi de Lambert)** :
   $$\text{Facteur de flux} = \max(0, \cos \theta)^{1.35} \quad \text{où } \cos \theta = \mathbf{n} \cdot \mathbf{ray}$$
   SimpleSKP simule en direct l'assombrissement sur les surfaces rasantes et l'étirement des pixels.
5. **Occlusion & Ombres portées** :
   Le viewport Metal calcule en temps réel les ombres créées par les praticables, piliers ou toiles tendues : les surfaces masquées à l'axe du projecteur n'affichent pas la mire.
6. **Éclairement photométrique en Lux ($E$, Lumens / m²)** :
   $$A(D) = \frac{D^2}{\text{throwRatio}^2 \times \text{aspectRatio}}$$
   $$\Phi_{\text{effectif}} = \Phi_{\text{lumens}} \times \text{intensity} \times \eta_{\text{lentille}}$$
   $$E(D) = \frac{\Phi_{\text{effectif}}}{A(D)} = \Phi_{\text{effectif}} \times \frac{\text{throwRatio}^2 \times \text{aspectRatio}}{D^2}$$
   - $E \propto 1/D^2$ : la lumière diminue avec le carré de la distance.
   - $E \propto \text{throwRatio}^2$ : un zoom serré (téléobjectif) concentre le flux sur une zone plus petite et produit un éclairement en lux beaucoup plus fort qu'un grand angle à la même distance.
7. **Luminance réfléchie en Nits ($L$, cd/m²) & Foot-Lamberts** :
   $$L = \frac{E \times \text{gain}}{\pi} \approx \frac{E}{3.1416}\text{ cd/m}^2\text{ (Nits)}$$
   $$\text{fL} = \frac{L}{3.426} \approx \frac{E \times \text{gain}}{10.764}$$
8. **Atténuation d'optique et vignettage ($\eta_{\text{lentille}}$)** :
   - Les objectifs zoom subissent une perte d'ouverture relative en fond de focale ($\approx 12\%$ de perte de flux au téléobjectif max par rapport au grand angle).
   - Vignettage périphérique modélisé dans le shader Metal ($\approx 85\%$ d'uniformité ANSI du centre vers les 4 coins).
9. **Simulation photométrique réaliste 3D dans le shader Metal** :
   - Mode activable à volonté (*Rendu 3D photométrique réaliste*, toggle dans l'inspecteur VP et route `/rendering/photometric_simulation`).
   - Règle la luminosité projetée dans la scène 3D pour refléter exactement les puissances comparées (ex: 4 200 lm vs 9 800 lm vs 32 000 lm) et l'assombrissement réaliste lorsque le projecteur est reculé.
   - Étalonnage de référence sélectionnable : `150 lx` (théâtre / pénombre), `250 lx` (standard plateau), `400 lx` (salle semi-éclairée), `600 lx` (forte ambiance).

---

## 3. Workflows de Placement & d'Ajustement

### A. Inspecteur Dédié & Multi-Sélection (Règle SimpleFamily G53bis)
- **Inspecteur latéral docké (`⌥⌘I`)** :
  L'interface de réglage des vidéoprojecteurs est désormais intégrée dans un panneau inspecteur latéral dédié (largeur ~328 pt) à droite de la fenêtre, sans jamais masquer le viewport 3D ni flotter par-dessus les frustums optiques.
  - Raccourci clavier : `⌥⌘I` (Présentation › Inspecteur vidéoprojecteur).
  - Bouton TopBar : icône `sidebar.right` ("Inspecteur VP").
- **Multi-sélection de projecteurs** :
  - Sélection multiple dans la barre latérale via `⌘-clic` (sélection discontinue) ou `⇧-clic` (sélection par plage).
  - Bouton « Tout » pour sélectionner l'ensemble des vidéoprojecteurs du projet en un clic.
  - Puces interactives (chips) dans l'inspecteur pour basculer rapidement la sélection d'un projecteur individuel.
  - Dans le viewport 3D Metal, tous les vidéoprojecteurs sélectionnés affichent simultanément leur boîte d'encombrement et leur frustum en surbrillance accentuée.

### B. Déplacement Groupé & Nudge Scénique Pas à Pas
- **Déplacement groupé en translation ($\Delta X, \Delta Y, \Delta Z$)** :
  Tout déplacement appliqué déplace à la fois la position et la cible de chaque projecteur sélectionné du même vecteur delta, préservant strictement l'écartement spatial et la visée relative du groupe.
- **Boutons de Nudge directionnels** :
  - Sélecteur de pas rapide : `0.05 m` (calage fin), `0.10 m`, `0.20 m`, `0.50 m`, `1.00 m` (perche/travée), `2.00 m`.
  - Axes scéniques :
    - Jardin / Cour : boutons `◀ Jardin (-X)` et `Cour (+X) ▶`
    - Face / Lointain : boutons `▼ Face (-Y)` et `Lointain (+Y) ▲`
    - Hauteur : boutons `▼ Sol (-Z)` et `Grill (+Z) ▲`
- **Actions de groupe simultanées** :
  - Allumer / Éteindre tout le groupe sélectionné.
  - Activer / masquer le volume de projection 3D (frustum).
  - Changer la mire de calage pour tout le groupe (ex: `Grille de test`, `Mire couleurs`, `Blanc plein`).
  - Duplication ou suppression groupée.

### C. Symétrie Scénique & Miroir (Axe Médian $X = 0$)
- **Duplication symétrique** :
  Crée instantanément une copie symétrique des projecteurs sélectionnés par rapport au centre du plateau ($X = 0$).
  - Position $X$ inversée (ex: Jardin $-4.0\text{ m} \to$ Cour $+4.0\text{ m}$).
  - Cible $X$ inversée.
  - Pan inversé ($\text{pan}' = -\text{pan}$) et lens shift horizontal inversé.
- **Miroir scénique** :
  Bascule directement les projecteurs sélectionnés de l'autre côté du plateau sans créer de copie.

### D. Positionner un Vidéoprojecteur
- **Depuis la caméra actuelle** :
  Placer la vue 3D à l'endroit approximatif souhaité, puis déclencher `moveSelectedProjectorToCamera()` pour y amener le projecteur, et `aimSelectedProjectorAtCameraTarget()` pour viser la même zone.
- **Par magnétisme (Snapping)** :
  Activer le mode pick position (`startPickingProjectorPosition()`) pour cliquer sur un point précis de la charpente ou du grill (snapping aux arêtes et sommets du décor).
- **Accroche inversée (Plafond / Pont)** :
  Définir `rollDegrees = 180` pour simuler le projecteur monté à l'envers sous une perche.

### E. Régler l'Optique & la Zone de Projection
- **Zoom / Throw Ratio** :
  Régler `throwRatio` pour que la largeur $L$ corresponde au cadre scénique souhaité sans dépasser les limites optiques du modèle (`minThrowRatio`…`maxThrowRatio`).
- **Décentrement (Lens Shift)** :
  Ajuster `lensShiftH` et `lensShiftV` pour remonter l'image au-dessus du sol ou l'écarter d'un obstacle sans incliner physiquement le projecteur (évite les déformations trapézoïdales et préserve le piqué).

### F. « Vue depuis le VP » (`lookThroughSelectedProjector`)
- Aligne instantanément la caméra du viewport sur l'œil du projecteur (position et axe optique exacts).
- **Utilité scénographique** :
  - Vérifier si un comédien ou un pendrillon coupe le faisceau.
  - Déceler les zones d'ombres derrière un élément de décor.
  - Valider le cadrage d'un tulle ou d'un cyclo depuis le point de montage réel.

### G. Séparation Stricte UI « Vidéoprojecteurs » vs « Lumières » & Rendu GPU 12 Slots Analytique RGB/RGBW
- **Rendu GPU unifié en coulisses (`VideoProjectorRenderer`, 12 slots simultanés en atlas $4 \times 4$ + texture de paramètres `sskp_projData` $32 \times 16$ `.rgba32Float`)** :
  - Les vidéoprojecteurs (`isStageLight == false`) et les lumières de scène (`isStageLight == true`) partagent la même technique de coordonnées de texture projectives, shadow-maps PCF $512 \times 512$ et rebond indirect (réverbération 4-quadrants) dans le shader Metal, jusqu'à **12 projecteurs/lumières simultanés**.
  - **Zéro rastérisation CPU pour les lumières de scène (`isStageLight`)** : la forme optique du faisceau (découpe circulaire nette/floue `profileSpot` ou faisceau Wash cosinus `washPanel`), les 4 couteaux/volets (`shutterLeft/Right/Top/Bottom`), le focus (`edgeSoftness`) et le mélange colorimétrique **RGB / RGBW** (`effectiveBeamRGB` combinant les diodes `R`, `G`, `B` et la diode `W` dédiée `whiteChannel` à $4000\text{K}$) sont évalués **100 % analytiquement dans le fragment shader Metal** via les texels `18..20` de `sskp_projData` (`0` dessin `CGContext`, `0` upload de texture $640 \times 400$ lors des variations de couleur, couteaux, focus ou Art-Net à $60\text{–}120\text{ Hz}$).
  - **Mélange additif linéaire & roll-off filmique préservant la teinte** : toutes les projections (vidéo Syphon/NDI/mires + faisceaux lumineux RGB/RGBW + rebonds indirects) s'additionnent en espace linéaire (`sskp_totalProj += ... * _surface.diffuse.rgb`) avec une compression douce des hautes lumières (`sskp_peak > 1.15`) qui évite la saturation brutale des canaux lors de la superposition de plusieurs projecteurs.
- **Interface utilisateur strictement distincte (TopBar, Sidebar gauche & Inspecteur droit)** :
  - **Barre d'outils supérieure (`TopBar`)** : deux boutons séparés `VP (N)` et `Lumières (M)` ouvrant chacun directement la catégorie correspondante de l'inspecteur.
  - **Barre latérale gauche (`SidebarView`)** : deux sections distinctes `VIDÉOPROJECTEURS` et `LUMIÈRES` (avec pastille de couleur live, pourcentage de gradateur, menu d'ajout de fixtures et barre de navigation dans la conduite Millumin).
  - **Inspecteur latéral droit (`ProjectorInspectorView`)** :
    - Sélecteur de catégorie en tête (`Vidéoprojecteurs` vs `Lumières`).
    - En mode **Vidéoprojecteurs** : uniquement les modèles de vidéoprojecteurs (`ProjectorCatalog.videoProjectorSpecs`), le rapport de projection `:1`, le Lens Shift H/V, et les sources vidéo (Mires, Syphon, NDI).
    - En mode **Lumières** : uniquement les réglages d'éclairage scénique (aucun réglage Syphon/NDI ni Lens Shift) :
      1. **Conduite Lumière Millumin** (rappel des colonnes/cues importées avec boutons `◀` / `▶`).
      2. **Gradateur (Dimmer $0\dots250\%$) & Mélange Couleur RGB / RGBW** (présélections $2800\text{K}$, $3200\text{K}$, $4200\text{K}$, $5600\text{K}$, `RGB+W`, Ambre, Rouge, Vert, Bleu, Cyan, Magenta, ColorPicker et **4 curseurs indépendants `R`, `G`, `B`, `W`** $0\dots100\% / 0\dots255$ DMX + Réverbération).
      3. **Projecteur, Ouverture en degrés (`°`) & Couteaux / Volets** (`beamAngleDegrees`, Focus/Diffusion `edgeSoftness`, 4 couteaux/volets).
      4. **Position au Grill & Pointage 3D** (Nudge X/Y/Z, bouton **`Douche 90°`** pour pointer verticalement vers le sol, `Clic pos.`, `Clic cible`, `Voir axe`, Pan/Tilt/Roll).
      5. **Photométrie & Diamètre de tache (`Ø m`)**.
      6. **Patch DMX, Art-Net & Fixture OFL (`/Users/adrien/Library/Millumin/Light-fixtures`)** avec table détaillée des canaux DMX et valeurs Art-Net live (`0–255`).

### H. Simulation Photométrique Réaliste (Lux & Luminance)
- Atténuation physique réelle en $\frac{1}{d^2}$ (inverse du carré de la distance) calculée sur le GPU Metal.
- Calcul de l'éclairement en **Lux** ($\text{lx} = \frac{\text{Lumens}}{\text{Surface}}$), de la luminance en **cd/m²** (Nits) et en **Foot-Lamberts** (fL) sur surface diffusante lambertienne.
- Facteur d'obliquité de surface (loi du cosinus de Lambert).
- Étalonnage de niveau de référence commutable ($150, 250, 400, 600\text{ lx}$) pour reproduire fidèlement l'ambiance visuelle du plateau.

### I. Écoute Art-Net 4 Temps Réel (UDP 6454), Priorité Art-Net > OSC & Librairie OFL
- Récepteur Art-Net 4 natif écoutant sur le port UDP `6454` avec `SO_REUSEPORT` et `SO_REUSEADDR`, cohabitant sans conflit avec Millumin ou d'autres consoles lumières.
- **Priorité automatique Art-Net sur OSC** : dès que des paquets Art-Net sont reçus (dans les 2,5 dernières secondes), SimpleSKP ignore les messages OSC qui commandent les lumières afin d'éviter tout conflit.
- **Librairie Open Fixture Library (`OFLFixtureLibrary`)** :
  - Scan automatique de `/Users/adrien/Library/Millumin/Light-fixtures` et `/Applications/Millumin5.app/Contents/Resources/ofl_millumin`.
  - Classification sémantique automatique de chaque canal DMX (`DMXChannelRole` : `dimmer`, `red`, `green`, `blue`, `white`, `warmWhite`, `coldWhite`, `amber`, `uv`, `zoom`, `strobe`, etc.) en ignorant les canaux de fonction/courbe (`Dimmer Mod`, `Function`, `Segment Patterns`) pour ne jamais écraser le gradateur maître.

### J. Importation Directe des Lumières & de la Conduite depuis Millumin (`.millumin`)
- Parseur Swift natif (`MilluminImporter.parseProjectFull`) décodant l'archive `NSKeyedArchiver` des fichiers `.millumin` :
  - Récupère les `FCStageLight` du `controller.board` actif : nom, `fixtureIdentifier`, `modeName`, `dmxChannel`, position/rotation 3D, et ignore la couleur d'icône fluo par défaut de Millumin `(0.5501, 1.0, 0.1665)` pour préserver le blanc ou le mélange RGBW réel.
  - Résout la fixture OFL correspondante dans `/Users/adrien/Library/Millumin/Light-fixtures` (ex. `eurolite/led-ml-56-rgbw`, `varytec/hero-wash-300-fc`, `american-dj/ikon-profile`, `stairville/led-flood-panel-150`).
  - Extrait toutes les colonnes de la **Conduite Lumière (`[MilluminLightingCue]`)** depuis `FCBoardColumn` et `FCLightStateMedia` (`valuesPerLight` : `___Intensity`, `___Red`, `___Green`, `___Blue`, `___White`, `___Dimmer` et durées de transition) pour suivre la conduite pas à pas dans SimpleSKP.

### K. Enregistrement du Projet Scénique (`.sskp`)
- Un fichier `.sskp` (SimpleSKP Project) sauvegarde :
  - Le chemin relatif ou absolu vers la maquette `.skp` d'origine.
  - L'ensemble des vidéoprojecteurs et éclairages placés avec tous leurs réglages optiques fins (zoom, lens shift, couteaux, DMX).
  - Les poses de caméras, calques masqués, styles d'ombrage et réglages photométriques.
  - Raccourci : `⌘S` ou menu *Fichier › Enregistrer sous…*.

---

## 4. Outils MCP & API HTTP pour SimpleSKP

Le serveur MCP `simpleskp-mcp` et l'API HTTP locale (`http://127.0.0.1:17950/v1`) exposent l'état et le contrôle :

| Commande / Endpoint | Rôle |
|---|---|
| `simpleskp_state` (`GET /v1/state`) | État global : fichier .skp/.sskp ouvert, dimensions du modèle, caméras, calques, scènes, ports. |
| `simpleskp_camera` (`POST /v1/camera`) | Cadrer la caméra (`standardView: "top"\|"front"\|"iso"`, `position`, `target`, `fov`). |
| `simpleskp_scene` (`POST /v1/scene`) | Activer un onglet de scène de la maquette (ex: « Implantation Écran »). |
| `simpleskp_layers` (`POST /v1/layers`) | Masquer/afficher des calques (ex: isoler les praticables ou la charpente). |
| `simpleskp_snapshot` (`GET /v1/snapshot.png`) | Capture PNG haute définition du viewport 3D pour **vérifier visuellement la projection**. |

---

## 5. Exemple d'Analyse Scénographique par l'Agent

Lorsqu'Adrien demande :  
*« Est-ce qu'un ZU920ST au pont face à 6 m de hauteur peut couvrir tout le cyclo de 8 m de large situé à 5,5 m de distance ? »*

L'agent procède ainsi :
1. Calcul du throw ratio requis : $\text{Ratio} = \frac{D}{L} = \frac{5.5}{8.0} = 0.6875$.
2. Vérification dans le catalogue : l'Optoma ZU920ST couvre **0.65 à 0.75:1**. $\implies$ **Couverture possible** en milieu de plage de zoom optique.
3. Calcul du décentrement vertical : la différence de hauteur entre le pont ($6\text{ m}$) et le centre du cyclo ($2.5\text{ m}$) est de $3.5\text{ m}$.
4. Vérification du Lens Shift maximal ($V \pm 55\%$) : la hauteur d'image pour $8\text{ m}$ en 16:10 est $H = 5.0\text{ m}$. Le décentrement max possible sans inclinaison est $0.55 \times 5.0 = 2.75\text{ m}$.
5. Recommandation : le décalage physique de $3.5\text{ m}$ nécessite une légère inclinaison mécanique (tilt vers le bas de $\approx 8^\circ$) combinée au lens shift vertical max pour éviter l'ombre du nez de scène.
6. Validation visuelle : prise de vue avec `simpleskp_snapshot` en mode grille de test (`testGrid`).
