# SimpleSKP

Visualiseur **SketchUp** natif, ultra-léger (~3 Mo, zéro dépendance) : double-cliquez un `.skp` et voyez-le en 3D en moins d'une seconde, dans la lignée de **SimpleAudio**, **SimplePJ** et **SimpleText** (**cie Adrien M**). Le fichier est lu par le framework de SketchUp lui-même (`SketchUpAPI.framework`, chargé à la demande) et affiché avec SceneKit : un visualiseur, pas un éditeur, rien n'est modifié ni enregistré.

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

| Geste | Effet |
|---|---|
| Glisser | Orbite autour du point visé |
| ⇧-glisser, clic droit ou bouton du milieu | Panoramique |
| Molette ou pincement | Zoom vers le curseur |
| Double-clic | Recentrer sur le point |
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
| ⇧Z | Zoom étendu |
| ⌘[ / ⌘] | Scène précédente / suivante |
| ⌘1 … ⌘7 | Iso, dessus, face, droite, arrière, gauche, dessous |
| ⌘? | Aide |
| ⌘/ | Raccourcis |

## Prérequis

- **macOS 15** ou plus.
- **SketchUp installé** : SimpleSKP cherche `SketchUpAPI.framework` dans `SimpleSKP.app/Contents/Frameworks`, puis dans `/Applications/SketchUp*.app` et `~/Applications/SketchUp*.app` (le plus récent d'abord), puis dans la copie autonome livrée avec Unity (`/Applications/Unity/Hub/Editor/*/Unity.app/Contents/Frameworks`). Sans framework, l'app montre la vignette du fichier et explique où trouver SketchUp. Aucun code Trimble n'est redistribué.

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
| Orbite sur la salle | 60 i/s sur Apple Silicon | non mesuré |
| Mémoire | ≤ 3 × la taille du fichier | pic pendant la lecture par le framework SketchUp : 0,95 Go (salle), 1,1 Go (Arles, textures décodées par SketchUp) ; empreinte une fois la scène affichée ≈ 0,7 Go pour la salle |
| Binaire | ≈ 3 Mo | 1,4 Mo en release, 2,7 Mo empaqueté avec l'icône |

Mesuré le 25 octobre 2026 sur Apple Silicon, build release, cache disque chaud (`.build/release/SimpleSKP --snapshot` et `--self-test`, deux passes identiques).

## Crédits & Licence

**Adrien Mondot · cie Adrien M** (Compagnie Adrien M) — Bundle ID : `net.cieadrienm.simpleskp`.
SketchUp est une marque de Trimble Inc. ; SimpleSKP n'en est ni affilié ni approuvé.
Distribué sous licence publique générale GNU (GPL v3+). Voir [`LICENSE`](LICENSE).
