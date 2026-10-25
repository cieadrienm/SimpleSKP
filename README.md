# SimpleSKP

Visualiseur **SketchUp** natif, léger (13 Mo dont 11 pour le SDK SketchUp, zéro dépendance) : double-cliquez un `.skp` et voyez-le en 3D en moins d'une seconde, dans la lignée de **SimpleAudio**, **SimplePJ** et **SimpleText** (**cie Adrien M**). Le fichier est lu par le framework du SDK SketchUp (`SketchUpAPI.framework`, livré dans l'app et chargé à la demande) et affiché avec SceneKit : **SketchUp n'a pas besoin d'être installé** : un visualiseur, pas un éditeur, rien n'est modifié ni enregistré.

## Fonctionnalités

- **3D instantanée après la vignette** : la vignette du fichier s'affiche tout de suite, le modèle se charge en arrière-plan et apparaît en fondu.
- **Scènes** : la caméra glisse vers la scène choisie (⌘[ et ⌘] pour passer de l'une à l'autre), ses calques masqués s'appliquent.
- **Calques** : liste avec cases, visibilité immédiate.
- **Dimensions en mètres** dans la barre d'état, avec version SketchUp du fichier, faces, arêtes et composants.
- **Vues standard** : iso, dessus, face, droite, arrière, gauche, dessous (⌘1…⌘7).
- **Perspective / parallèle** (⌥⌘P) et **arêtes** affichables ou masquées (⌘E).
- **Copie d'image** de la vue (⌘C) et **ouverture dans SketchUp** (⇧⌘O).
- Glisser-déposer d'un `.skp` sur la fenêtre ou l'icône, plusieurs fichiers ouverts, Ouvrir récent, restauration des fenêtres.

## Manipulation

Quatre façons coexistent ; un clic ou une touche arrête tout mouvement en cours.

| Geste | Effet |
|---|---|
| Glisser | Orbite autour du point visé, avec inertie |
| ⇧-glisser ou bouton du milieu | Panoramique |
| Molette | Zoom vers le curseur |
| Double-clic | Recentrer et approcher le point |
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
| ⇧Z | Zoom étendu |

## Raccourcis

| Raccourci | Action |
|---|---|
| ⌘O | Ouvrir… |
| ⌘W | Fermer |
| ⇧⌘O | Ouvrir dans SketchUp |
| ⌘C | Copier l'image |
| ⌥⌘S | Afficher / masquer la barre latérale |
| ⌘E | Arêtes |
| ⌥⌘P | Perspective / parallèle |
| ⌥⌘O | Ombres |
| ⌥⌘A | Occlusion ambiante |
| ⇧Z | Zoom étendu |
| ⌥⌘F | Mode vol libre (Échap pour sortir) |
| ⌘[ / ⌘] | Scène précédente / suivante |
| ⌘1 … ⌘7 | Iso, dessus, face, droite, arrière, gauche, dessous |
| ⌘? | Aide |
| ⌘/ | Raccourcis |

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
| `MM_Arles_3D_V003.skp` (45 Mo, 35 textures) → 3D | < 4 s (lecture API 1,9 s) | lecture 2,3 s + scène 0,13 s ; lancement → capture 3,2 s |
| `B-SEINE MUSICALE…V40.skp` (97 Mo, 14 758 composants, 641 572 arêtes, 151 calques) → 3D | < 7 s (lecture API 2,9 s) | lecture 3,7 s + scène 0,6 s (2,95 s avant les calques masqués construits à la demande) ; lancement → capture 6,0 s |
| Orbite sur la salle | 60 i/s sur Apple Silicon | M2 Max, 2760 × 1640, MSAA ×4, `SCNRenderer` : caméra du fichier (dessus, parallèle) 54 i/s ; iso, calques du fichier (49 700 nœuds) 13 i/s ; scène « VUE DESSUS COUPE » (82 500 nœuds, 19,6 M triangles, 9 M segments) 8–9 i/s ; Arles > 400 i/s |
| Mémoire | ≤ 3 × la taille du fichier | pic pendant la lecture par le framework SketchUp : 0,95 Go (salle), 1,1 Go (Arles, textures décodées par SketchUp) ; empreinte une fois la scène affichée ≈ 0,7 Go pour la salle |
| Binaire | ≈ 3 Mo | 1,4 Mo en release, 2,7 Mo empaqueté avec l'icône ; 13 Mo avec le SDK SketchUp (11 Mo, aminci à arm64, sans en-têtes) |

Mesuré le 25 octobre 2026 sur Apple Silicon, build release, cache disque chaud (`.build/release/SimpleSKP --snapshot` et `--self-test`, deux passes identiques).
La salle reste sous les 60 i/s dès que beaucoup de calques sont visibles : une passe de fusion des instances (moins de nœuds, moins d'appels de dessin) est le prochain jalon.

## Crédits & Licence

**Adrien Mondot · cie Adrien M** (Compagnie Adrien M) — Bundle ID : `net.cieadrienm.simpleskp`.
SketchUp est une marque de Trimble Inc. ; SimpleSKP n'en est ni affilié ni approuvé.
Le framework du SDK C de SketchUp (Trimble) est embarqué dans l'app sous la licence du SDK SketchUp ; le code de SimpleSKP est GPL v3 (voir [`LICENSE`](LICENSE)).
