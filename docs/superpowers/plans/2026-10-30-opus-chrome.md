# Interface intégrée et panneaux au geste : plan de construction

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal :** remplacer les contrôles flottants d'Opus par des barres réservées (deux dispositions à essayer), ouvrir les panneaux au geste depuis leur bord, et réorganiser le panneau des artifacts par moment, code à part.

**Architecture :** la logique pure (classement du code, moments, lignes du panneau, reconnaissance du geste, géométrie des bords, textes de la barre d'état) vit dans `OpusArtifactsKit` ou dans de petits types sans AppKit, testés en XCTest. Les vues AppKit (`ChromeTabStrip`, `ChromeButtonBar`, `ChromeStatusView`, `ChromeBar`) sont posées par `TerminalContainerView` selon `OpusPreferences.chromeLayout`. `RightDock` devient `DrawerDock`, qui gère un bord gauche (Copier) et un bord droit (Artifacts) et sait suivre un geste.

**Tech Stack :** Swift 5.9, SwiftPM, AppKit, SwiftTerm 1.99 (API 2.0), XCTest. Cible macOS 13.

**Spec :** `docs/superpowers/specs/2026-10-30-opus-chrome-design.md` (à lire avant chaque tâche).

## Global Constraints

- Aucun tiret cadratin, dans aucun contenu : code, commentaires, textes d'interface, messages de commit.
- Textes d'interface nouveaux en français (« contexte », « semaine », « mémoire », « Afficher dans le Finder », « Dernière heure »…), code et commentaires en anglais, densité de commentaires comme le code voisin.
- Cible macOS 13 : AppKit garde `clipsToBounds = true` par défaut sur toute vue ; toute vue qui doit déborder le dit (`if #available(macOS 14, *) { clipsToBounds = false }`). Symboles SF disponibles sur macOS 13 uniquement.
- Le terminal ne change jamais de largeur à l'ouverture d'un panneau (règle de `f9e5e6c`). Changer de disposition dans les réglages peut le redimensionner une fois.
- Raccourcis inchangés : Cmd+Shift+C (Copier), Cmd+Shift+A (Artifacts), raccourci global du trousseau (`SecretsPanel.shared.toggle()`), Cmd+T (`spawnNewTab()`).
- Points d'activité des onglets : couleurs `OpusTheme.activityColor` inchangées.
- Couleur réservée aux états qui demandent l'attention (seuils ambre puis rouge, points d'activité). Icônes monochromes `OpusTheme.cream`.
- Après chaque tâche : `swift test` sans échec, puis commit ET push sur `main` avec, en fin de message :
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` et `Claude-Session: https://claude.ai/code/session_01137eg3CvWQHmchWmAYFm72`.
- Ne jamais quitter ni relancer Opus depuis la session (elle tourne dedans). `./build.sh` installe ; l'utilisateur relance lui-même.
- Toute tâche qui change l'apparence se vérifie aussi par capture réelle (sonde de rendu, Tâche 6), pas seulement par les tests.

## Review Focus

1. **Défilement vertical un peu en biais** (trackpad, doigts qui dérivent de quelques points) : ne doit jamais ouvrir de panneau ni bloquer le défilement. Test dans la Tâche 5.
2. **Inertie après un lancer** (événements `momentumPhase`) : ne rouvre pas, ne relance pas de progression, et ne fait pas défiler le terminal après un geste horizontal. Test dans la Tâche 5.
3. **Geste dans le mauvais sens avec un panneau ouvert** (Artifacts ouvert, doigts vers la gauche) : rien ne bouge, l'événement passe au contenu (la liste du panneau peut défiler). Test dans la Tâche 5.
4. **Artifact sans horodatage** : rangé dans un dernier groupe « Plus tôt », jamais dans « Dernière heure ». Test dans la Tâche 2.
5. **Beaucoup d'onglets ou titres très longs** : les onglets se serrent (largeur minimale) et tronquent leur titre, les boutons ne sont jamais poussés hors de la barre. Test dans la Tâche 6.

---

### Task 1 : le code à part dans les artifacts

**Files :**
- Create : `Sources/OpusArtifactsKit/ArtifactCode.swift`
- Modify : `Sources/OpusArtifactsKit/ArtifactKindFilter.swift`
- Modify : `Sources/Opus/ArtifactsDrawerView.swift` (`headerText` compte « Tous »)
- Test : `Tests/OpusTests/ArtifactCodeTests.swift`, `Tests/OpusTests/ArtifactKindFilterTests.swift`

**Interfaces :**
- Produces : `public enum ArtifactCode { public static let extensions: Set<String>; public static func isCode(_ artifact: Artifact) -> Bool }`. `ArtifactKindFilter` gagne `case code` (dernier de `allCases` : `all, files, images, links, folders, code`), titre `"Code"`.

- [ ] **Step 1 : tests qui échouent**

```swift
// ArtifactCodeTests
func testSourceAndConfigFilesAreCode() {
    for ext in ["swift", "ts", "tsx", "json", "yml", "lock", "SWIFT"] {
        XCTAssertTrue(ArtifactCode.isCode(file("/r/a.\(ext)")), ext)
    }
}
func testDocumentsImagesAndFoldersAreNotCode() {
    for ext in ["md", "pdf", "html", "txt", "csv"] { XCTAssertFalse(ArtifactCode.isCode(file("/r/a.\(ext)")), ext) }
    XCTAssertFalse(ArtifactCode.isCode(Artifact(key: "i", kind: .image, resolvedPath: "/r/a.png", urlString: nil)))
    XCTAssertFalse(ArtifactCode.isCode(Artifact(key: "d", kind: .folder, resolvedPath: "/r/x.swift", urlString: nil)))
    XCTAssertFalse(ArtifactCode.isCode(file("/r/Makefile")))
}
// ArtifactKindFilterTests (remplace testAllKeepsEverythingInOrder et le test de partition)
func testAllLeavesCodeOut()            // [doc.md, main.swift, shot.png] -> All = [doc.md, shot.png]
func testFilesLeavesCodeOut()          // Files = [doc.md]
func testCodeKeepsOnlyCode()           // Code = [main.swift]
func testEveryArtifactFallsInExactlyOneOfFilesImagesLinksFoldersCode()
func testTitlesAreStableAndEnglish()   // ajoute "Code"
```
`file(_:)` est une aide locale qui crée un `Artifact` de type `.file`.

- [ ] **Step 2 : `swift test --filter "ArtifactCodeTests|ArtifactKindFilterTests"`** : échec de compilation (`ArtifactCode` inconnu).
- [ ] **Step 3 : `ArtifactCode`** avec exactement les extensions de la spec (`swift ts tsx js jsx mjs cjs py rb go rs java kt c h cpp m mm sh zsh json yml yaml toml lock xml plist css scss`), comparées en minuscules sur `pathExtension` de `resolvedPath`, pour le type `.file` seulement. Dans `ArtifactKindFilter.matches` : `.all` = `!isCode`, `.files` = `.file && !isCode`, `.code` = `isCode` ; `apply` filtre aussi pour `.all`. Les tests existants de `step(from:direction:keeping:)` doivent rester verts. `ArtifactsDrawerView.headerText` compte les artifacts de « Tous ».
- [ ] **Step 4 : la même commande** : PASS, puis `swift test` complet sans échec.
- [ ] **Step 5 : commit** `Artifacts: code files get their own tab, and All leaves them out`.

### Task 2 : les moments des artifacts

**Files :**
- Create : `Sources/OpusArtifactsKit/ArtifactMoment.swift`
- Test : `Tests/OpusTests/ArtifactMomentTests.swift`

**Interfaces :**
- Produces :
  - `public enum ArtifactMoment: Hashable, Sendable { case lastHour, today, yesterday, day(Date), undated }` avec `public static func of(_ timestamp: Date?, now: Date, calendar: Calendar) -> ArtifactMoment` et `public func title(calendar: Calendar) -> String`.
  - `public struct ArtifactSection: Equatable { public let moment: ArtifactMoment; public let images: [Artifact]; public let others: [Artifact] }`
  - `public enum ArtifactSections { public static func build(_ artifacts: [Artifact], now: Date, calendar: Calendar) -> [ArtifactSection] }`

- [ ] **Step 1 : tests qui échouent** (calendrier grégorien, fuseau `Europe/Paris`, `now` = 30/10/2026 14:00)

```swift
func testFiftyNineMinutesAgoIsTheLastHour()      // of(now - 59 min) == .lastHour
func testAFutureTimestampCountsAsTheLastHour()   // of(now + 30 s) == .lastHour (horloges décalées)
func testEarlierTodayIsToday()                   // of(30/10 08:00) == .today
func testYesterdayIsYesterday()                  // of(29/10 23:30) == .yesterday
func testOlderIsItsDay()                         // of(27/10 10:00) == .day(startOfDay 27/10)
func testNoTimestampIsUndated()                  // of(nil) == .undated
func testTitles()  // "Dernière heure", "Aujourd'hui", "Hier", "mardi 27 octobre", "Plus tôt"
func testSectionsAreNewestFirstWithUndatedLast()
func testImagesAndOthersAreSplitInsideASectionNewestFirst()
```
- [ ] **Step 2 : `swift test --filter ArtifactMomentTests`** : échec de compilation.
- [ ] **Step 3 : implémenter.** Dernière heure = moins de 3 600 s avant `now` (ou dans le futur) ; ensuite même jour civil, veille, puis début du jour. Titre d'un jour : `DateFormatter` en `fr_FR`, format `"EEEE d MMMM"`. Sections triées du plus récent au plus ancien, `.undated` en dernier ; dans une section, tri décroissant par horodatage, `images` = type `.image`, `others` = le reste, ordre conservé à égalité.
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : commit** `Artifacts: group by moment, newest first`.

### Task 3 : le panneau des artifacts par moment

**Files :**
- Create : `Sources/OpusArtifactsKit/ArtifactRows.swift`
- Modify : `Sources/Opus/ArtifactsDrawerView.swift`
- Modify : `Sources/Opus/TerminalContainerView.swift` (appelants de `artifact(at:)` / `selectedArtifact`, s'il le faut)
- Test : `Tests/OpusTests/ArtifactRowsTests.swift`, `Tests/OpusTests/ArtifactsDrawerViewTests.swift`, `Tests/OpusTests/RenderProbeTests.swift` (nouveau)

**Interfaces :**
- Consumes : `ArtifactSections.build` et `ArtifactMoment.title` (Tâche 2), `ArtifactKindFilter` (Tâche 1).
- Produces (tests) : `enum RenderProbe { static func capture(_ view: NSView, size: NSSize, to path: String) throws }`. Elle pose la vue dans une fenêtre sans bordure, la montre, puis lance `/usr/sbin/screencapture -x -o -l <windowNumber> <path>`. Les tests de `RenderProbeTests` sont sautés sans la variable d'environnement `OPUS_RENDER_PROBE` (dossier de sortie). Les Tâches 6 à 8 y ajoutent leurs captures.
- Produces :
  - `public enum ArtifactRow: Equatable { case header(String), images([Artifact]), item(Artifact) }`
  - `public enum ArtifactRows { public static let imagesPerRow = 3; public static func make(_ sections: [ArtifactSection], calendar: Calendar) -> [ArtifactRow] }`
  - `ArtifactsDrawerView` : `var displayedRows: [ArtifactRow] { get }` (lecture pour les tests), `selectedArtifact` garde son nom et son type.

- [ ] **Step 1 : tests qui échouent**

```swift
// ArtifactRowsTests
func testEachSectionIsAHeaderThenImageStripsThenItems()
// 4 images + 1 pdf dans « Dernière heure » ->
// [.header("Dernière heure"), .images([i1, i2, i3]), .images([i4]), .item(pdf)]
func testASectionWithoutImagesHasNoStrip()
// ArtifactsDrawerViewTests
func testTheDrawerShowsRowsForTheSelectedChipOnly()
// update(...) avec un .swift et un .png récents, puce « Tous » : aucun .item(swift) dans displayedRows ;
// puce « Code » : displayedRows contient .item(swift) et aucune bande d'images.
```
- [ ] **Step 2 : `swift test --filter "ArtifactRowsTests|ArtifactsDrawerViewTests"`** : échec.
- [ ] **Step 3 : implémenter.**
  - La table affiche `ArtifactRows.make(ArtifactSections.build(visible, now: Date(), calendar: .current), calendar: .current)`. `visible` reste « puce ET filtre texte ».
  - Trois vues de cellule :
    - en-tête : petites capitales, 10,5 pt, `cream(0.45)`, non sélectionnable ;
    - bande d'images : trois carrés côte à côte qui se partagent la largeur, vignette QuickLook comme aujourd'hui (icône par défaut), nom en surimpression en bas ;
    - ligne : l'actuelle `ArtifactCellView`, plus un bouton « Afficher dans le Finder » visible au survol pour les types `.file` et `.folder` (`NSWorkspace.shared.activateFileViewerSelecting`).
  - La sélection devient une clé (`selectedKey: String?`) : un clic sur une vignette ou une ligne la pose, les flèches parcourent les artifacts dans l'ordre affiché, Espace garde l'aperçu QuickLook, le double-clic ouvre (`NSWorkspace.shared.open`). Le menu contextuel et le glisser-déposer existants suivent l'artifact sous le pointeur. `reloadData()` seulement quand les lignes changent, comme aujourd'hui.
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : rendu.** `testRenderArtifactsDrawer` dans `RenderProbeTests` : panneau de 300x600 avec deux moments, quatre images et deux documents. Lancer `OPUS_RENDER_PROBE=<scratchpad> swift test --filter RenderProbeTests`, puis lire `artifacts.png` : vignettes carrées, en-têtes discrets, lignes lisibles.
- [ ] **Step 6 : commit** `Artifacts drawer: by moment, images as thumbnails, documents with a Finder button`.

### Task 4 : deux bords de panneaux, et le suivi d'un geste

**Files :**
- Rename : `Sources/Opus/RightDock.swift` -> `Sources/Opus/DrawerDock.swift` (classe `DrawerDock`)
- Rename : `Sources/OpusArtifactsKit/RightDockGeometry.swift` -> `DrawerGeometry.swift` (`enum DrawerGeometry`, `Occupant` inchangé)
- Modify : `Sources/Opus/DrawerResizeHandle.swift`, `Sources/Opus/ReplyDrawerView.swift`, `Sources/Opus/TerminalContainerView.swift`, `Sources/Opus/OpusPreferences.swift` (renommage seulement)
- Rename/Modify tests : `RightDockGeometryTests` -> `DrawerGeometryTests`, `RightDockWidthTests` -> `DrawerWidthTests`, `RightDockResizeTests` -> `DrawerDockTests`

**Interfaces :**
- Produces :
  - `public enum DrawerSide: Sendable { case leading, trailing }`
  - `DrawerGeometry.side(for: Occupant) -> DrawerSide` (`.reply` -> `.leading`, `.artifacts` et `.none` -> `.trailing`)
  - `DrawerGeometry.offset(width: CGFloat, side: DrawerSide, progress: CGFloat) -> CGFloat` : `+width` (trailing) ou `-width` (leading) multiplié par `1 - clamp(progress, 0, 1)`
  - `DrawerDock.Panel(view:offset:width:side:)` : `offset` est la contrainte du bord du panneau sur le bord du conteneur de son côté
  - `func show(_ occupant: Occupant)` et `toggle(_:)` : signatures inchangées
  - `func beginInteractive(_ occupant: Occupant)`, `func setInteractiveProgress(_ progress: CGFloat)`, `func endInteractive(open: Bool)`
  - `DrawerResizeHandle(side: DrawerSide, proposeWidth:commit:)`

- [ ] **Step 1 : tests qui échouent** (dans `DrawerDockTests`, même montage que l'actuel `RightDockResizeTests` avec un second panneau à gauche)

```swift
func testTheCopyDrawerOpensFromTheLeft()        // show(.reply) : drawerL.frame.minX == 0 ; garé : == -300
func testTheArtifactsDrawerStillOpensFromTheRight()
func testOneDrawerAtATimeSwaps()                // show(.reply) puis show(.artifacts) : reply garé et caché après la fin, artifacts dedans
func testInteractiveProgressPlacesTheDrawerPartWay()
// beginInteractive(.reply) ; setInteractiveProgress(0.5) -> drawerL.frame.minX == -150, sans animation
func testEndingInteractiveOpenSettlesItOpen()   // endInteractive(open: true) -> occupant == .reply, minX == 0
func testEndingInteractiveClosedParksAndHidesIt()
func testNoDrawerEverResizesTheTerminal()       // terminal.widths == [] dans tous les cas ci-dessus
// DrawerGeometryTests
func testSides()   // side(for: .reply) == .leading ; side(for: .artifacts) == .trailing
func testOffsets() // offset(width: 300, side: .leading, progress: 0.25) == -225 ; trailing, progress 1 == 0
```
- [ ] **Step 2 : `swift test --filter "DrawerDockTests|DrawerGeometryTests|DrawerWidthTests"`** : échec.
- [ ] **Step 3 : implémenter.**
  - Renommage mécanique, puis le panneau Copier passe à gauche : contrainte `leading` sur le bord gauche du conteneur, coins arrondis à droite (`layerMaxX…`), poignée sur son bord droit ; pour `.leading`, la poignée propose `point.x - container.bounds.minX`.
  - `show` anime avec l'`Animator` injecté, comme aujourd'hui.
  - `endInteractive` anime de la progression courante vers 1 ou 0 avec le même animateur, puis cache le panneau garé dans la complétion (même garde sur l'occupant qu'aujourd'hui).
  - La contrainte `edge` ne suit plus que les panneaux de droite (elle disparaît à la Tâche 6).
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : commit** `Drawers on both edges: Copy on the left, Artifacts on the right, and a progress a gesture can drive`.

### Task 5 : ouvrir et fermer au balayage

**Files :**
- Create : `Sources/OpusArtifactsKit/DrawerSwipeTracker.swift`
- Modify : `Sources/Opus/TerminalContainerView.swift` (moniteur local `.scrollWheel`)
- Test : `Tests/OpusTests/DrawerSwipeTrackerTests.swift`

**Interfaces :**
- Consumes : `DrawerDock.beginInteractive / setInteractiveProgress / endInteractive` (Tâche 4).
- Produces :

```swift
public struct DrawerSwipeTracker {
    public enum Phase: Sendable { case began, changed, ended, cancelled, momentum }
    public enum Output: Equatable, Sendable {
        case passThrough, consume
        case progress(DrawerGeometry.Occupant, CGFloat)
        case finish(DrawerGeometry.Occupant, open: Bool)
    }
    public static let axisLockDistance: CGFloat = 8
    public static let horizontalRatio: CGFloat = 2
    public static let commitFraction: CGFloat = 1.0 / 3.0
    public static let flingVelocity: CGFloat = 500      // pt/s, in the finger's direction
    public init()
    public mutating func feed(phase: Phase, fingerDX: CGFloat, dy: CGFloat, time: TimeInterval,
                              open: DrawerGeometry.Occupant, width: CGFloat) -> Output
    public static func fingerDX(scrollingDeltaX: CGFloat, invertedFromDevice: Bool) -> CGFloat
}
```
Règles :
- **Axe.** Il se décide quand le cumul atteint `axisLockDistance` sur l'un des deux axes : horizontal si `|ΣdX| >= 2 · |ΣdY|`, sinon vertical. Avant la décision et en vertical, la sortie est `.passThrough`.
- **Cible.** Rien d'ouvert : doigts vers la droite, `.reply` s'ouvre ; vers la gauche, `.artifacts` s'ouvre. `.reply` ouvert : doigts vers la gauche, il se ferme ; vers la droite, `.passThrough`. `.artifacts` ouvert : l'inverse.
- **Progression.** Pour une ouverture, `p = clamp(|ΣdX| / width)` ; pour une fermeture, `p = 1 - clamp(|ΣdX| / width)`.
- **Fin.** La vitesse se calcule sur les deux derniers échantillons. Pour une ouverture, `open = p >= 1/3 || vitesse >= 500` dans le sens d'ouverture ; pour une fermeture, `open = !(trajet >= 1/3 · width || vitesse >= 500)` dans le sens de fermeture.
- **Après la fin.** `.cancelled` rend `finish(cible, open: état de départ)`. Les phases `.momentum` qui suivent un geste horizontal rendent `.consume`, et `.passThrough` après un geste vertical.
- **Sens des doigts.** `fingerDX` vaut `invertedFromDevice ? scrollingDeltaX : -scrollingDeltaX` (défilement naturel ou non).

- [ ] **Step 1 : tests qui échouent**

```swift
func testAClearlyHorizontalSwipeRightOpensCopyAndFollowsTheFingers()  // dx 30 sur width 300 -> .progress(.reply, 0.1)
func testASwipeLeftOpensArtifacts()
func testADiagonalScrollStaysVertical()       // Review Focus 1 : (dx 10, dy 8) puis 40 en vertical -> toujours .passThrough
func testReleasingPastAThirdOpens()           // ΣdX 110 sur 300 puis .ended -> .finish(.reply, open: true)
func testReleasingShortOfAThirdWithoutAFlingCloses()
func testAFastFlingOpensEvenWhenShort()       // 40 pt en 0,05 s -> .finish(.reply, open: true)
func testTheReverseSwipeClosesTheOpenDrawer() // open .artifacts, doigts vers la droite 150 -> .finish(.artifacts, open: false)
func testTheWrongWayOverAnOpenDrawerPassesThrough() // Review Focus 3 : open .artifacts, doigts vers la gauche -> .passThrough
func testMomentumAfterAHorizontalSwipeIsConsumedAndChangesNothing() // Review Focus 2
func testMomentumAfterAVerticalScrollPassesThrough()
func testCancelledRestoresTheStartingState()
func testFingerDirectionFollowsNaturalScrolling() // fingerDX(5, true) == 5 ; fingerDX(5, false) == -5
```
- [ ] **Step 2 : `swift test --filter DrawerSwipeTrackerTests`** : échec.
- [ ] **Step 3 : implémenter le traqueur**, puis le moniteur local `.scrollWheel` dans `TerminalContainerView`.
  - Il ne traite que les événements de sa fenêtre, au-dessus du terminal actif ou d'un panneau ouvert.
  - Il ne traite que ceux qui ont une phase (trackpad, Magic Mouse) ; une molette sans phase passe telle quelle.
  - Correspondance : `phase` `.began / .changed / .ended / .cancelled`, `momentumPhase` non vide donne `.momentum`.
  - Sorties : `.passThrough` rend l'événement ; `.consume` rend `nil` ; `.progress` appelle `beginInteractive` au premier passage puis `setInteractiveProgress` et rend `nil` ; `.finish` appelle `endInteractive(open:)` et rend `nil`.
  - `width` = largeur courante du panneau visé (`DrawerDock.currentWidth(for:)`).
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : commit** `Open and close the drawers with a two-finger swipe that the drawer follows`.

### Task 6 : la barre d'outils (onglets, boutons, menu « ⋯ ») et la sonde de rendu

**Files :**
- Create : `Sources/Opus/ChromeBar.swift`, `Sources/Opus/ChromeTabStrip.swift`, `Sources/Opus/ChromeButtonBar.swift`
- Modify : `Sources/Opus/TerminalContainerView.swift`. Retirer `OpusTabBar` (son usage), `TopRightButtonRow`, `pinToTopRightRow`, `updateTopRightRow`, `uncoveredArea`, les boutons bouclier, artifacts et réponse. Le `edge` de `DrawerDock` disparaît.
- Modify : `Sources/Opus/main.swift`. Retirer la classe `OpusTabBar`, les boutons ↗ et épingle du panneau, `refreshPinButton` ; implémenter `chromeMenuItems()`.
- Modify : `Sources/Opus/MainTerminalWindow.swift` (`chromeMenuItems()` vide), `Sources/Opus/DrawerDock.swift`
- Delete : `Tests/OpusTests/TopRightRowTests.swift`
- Test : `Tests/OpusTests/ChromeTabStripTests.swift`, `Tests/OpusTests/RenderProbeTests.swift` (étendre)

**Interfaces :**
- Consumes : `DrawerDock.occupant`, `toggleReplyDrawer()`, `toggleArtifactsDrawer()`, `spawnNewTab()`, `switchTab(to:)`, `SecretsPanel.shared.toggle()`, `ClaudeBackend.shared.toggleSkipPermissions()`, `ClaudeBackend.shared.skipPermissionsActive`, `OpusPermissionMode.allCases`, l'action existante `permissionModePicked(_:)`.
- Produces :
  - `final class ChromeBar: NSView` : fond `cream(0.025)`, filet d'1 pt `cream(0.06)` du côté du terminal (`init(edge: NSRectEdge)`).
  - `final class ChromeTabStrip: NSView` : `titles: [String]`, `states: [PaneActivity]`, `activeIndex: Int`, `onSwitch: ((Int) -> Void)?`, `onNewTab: (() -> Void)?`, `static func tabWidths(titles: [String], font: NSFont, available: CGFloat) -> [CGFloat]`.
  - `final class ChromeButtonBar: NSView` : `activeDrawer: DrawerGeometry.Occupant`, `onCopy`, `onArtifacts`, `onKeychain: (() -> Void)?`, `moreMenu: (() -> NSMenu)?`.
  - `protocol TerminalContainerHost` gagne `func chromeMenuItems() -> [NSMenuItem]`.

- [ ] **Step 1 : tests qui échouent**

```swift
// ChromeTabStripTests (Review Focus 5)
func testTabsFitTheirTitleBetween80And220() // titres courts -> chaque largeur dans 80...220
func testManyTabsShrinkToTheMinimum()
// 12 titres de 60 caractères sur 600 pt -> toutes les largeurs == 80 (titres tronqués). La bande
// reçoit la largeur de la barre MOINS celle des boutons : ce qui ne tient pas est coupé dans la
// bande, jamais les boutons.
func testASingleTabStillShowsItsTitle()     // tabWidths(["Fonctionnalité des mods"], …, 600).count == 1
// RenderProbeTests
func testRenderToolbarWithTwoTabs()         // ChromeBar + ChromeTabStrip + ChromeButtonBar, 900x32 -> toolbar.png
```
- [ ] **Step 2 : `swift test --filter ChromeTabStripTests`** : échec.
- [ ] **Step 3 : implémenter.**
  - **Disposition A, la seule pour l'instant.** Une `ChromeBar(edge: .minY)` de 32 pt en haut du conteneur porte les onglets à gauche et les boutons à droite. Le terminal et les panneaux commencent sous elle. En bas, le rail actuel reste seul, tant que la Tâche 7 n'est pas faite.
  - **Onglets.**
    - Compacts, alignés à gauche, point d'activité devant un titre de 11,5 pt.
    - Onglet actif : fond `cream(0.09)` et texte `cream(0.95)` ; inactifs : texte `cream(0.55)`.
    - « + » appelle `spawnNewTab()`.
    - La bande s'affiche aussi avec un seul onglet.
  - **Boutons.**
    - Symboles `doc.on.clipboard` (Copier), `sidebar.trailing` (Artifacts), `key` (Trousseau), `ellipsis.circle` (« ⋯ »), 15 pt, `cream(0.55)`.
    - Au survol, fond arrondi `cream(0.08)` ; le bouton du panneau ouvert passe en `cream(0.95)`.
    - Infobulles avec le raccourci.
  - **Menu « ⋯ ».**
    - En tête, les entrées de l'hôte : « Épingler le panneau » avec coche, et « Ouvrir dans Terminal » si `displayMode.includesNativeTerminal`.
    - Puis un séparateur, et deux entrées si `useSharedTab0` : « Passer les permissions (bypass) » avec coche, et le sous-menu « Mode de permission ».
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : rendu.** `OPUS_RENDER_PROBE=<scratchpad> swift test --filter RenderProbeTests`, puis lire `toolbar.png` : onglets compacts, icônes alignées et de même taille, rien de coupé.
- [ ] **Step 6 : commit** `Toolbar: tabs and buttons get a bar of their own, pin and bypass move to the ⋯ menu`.

### Task 7 : la barre d'état

**Files :**
- Create : `Sources/Opus/ChromeStatus.swift`, `Sources/Opus/ChromeStatusView.swift`
- Modify : `Sources/Opus/TerminalContainerView.swift` (remplace `StatusRailView` ; `refreshContextMeter`, `refreshUsage`, `refreshMemory`, l'infobulle)
- Delete : `Sources/Opus/StatusRailView.swift` et ses tests devenus sans objet (`StatusRailTests` : déplacer ce qui reste utile vers `ChromeStatusTests`)
- Test : `Tests/OpusTests/ChromeStatusTests.swift`, `Tests/OpusTests/MemoryStatusTests.swift` (le test de `trailingText` disparaît avec `StatusRailView`), `RenderProbeTests` (étendre)

**Interfaces :**
- Consumes : `UsageWindow`, `UsageLimits.level / tooltip`, `MemoryStatus.read`, `ContextMeter`, `OpusTheme.contextColor`.
- Produces :
  - `enum ChromeStatus` :
    - `static func context(fraction: CGFloat?) -> String?`, qui donne `"contexte 36\u{00A0}%"` ;
    - `static func week(_ windows: [UsageWindow]) -> String?`, qui donne `"semaine 23\u{00A0}%"` ;
    - `static func fiveHour(_ windows: [UsageWindow]) -> String?`, qui donne `"5h 2\u{00A0}%"` ;
    - `static func tooltip(tokens: Int?, limit: Int?, windows: [UsageWindow]) -> String`, qui contient les tokens et les heures de reset.
  - `final class ChromeStatusView: NSView` : `memory: String?`, `contextFraction: CGFloat?`, `usage: [UsageWindow]`, `showsMemory: Bool` (vrai en disposition A).

- [ ] **Step 1 : tests qui échouent**

```swift
func testContextIsAPercentInFrench()           // context(fraction: 0.357) == "contexte 36\u{00A0}%" ; nil -> nil
func testWeekAndFiveHourAreSeparateSegments()  // windows 5h 2 %, 7j 23 % -> "semaine 23\u{00A0}%", "5h 2\u{00A0}%"
func testAnExpiredWindowShowsNothing()         // week([]) == nil
func testTheTooltipCarriesTokensAndResets()    // contient "357k" et le texte de UsageLimits.tooltip pour chaque fenêtre
```
- [ ] **Step 2 : `swift test --filter ChromeStatusTests`** : échec.
- [ ] **Step 3 : implémenter.**
  - Une `ChromeBar(edge: .maxY)` de 22 pt en bas. La mémoire est à gauche, en `cream(0.45)`.
  - À droite, dans l'ordre : contexte · semaine · 5h. Les mots sont en `cream(0.55)`, les chiffres en `cream(0.95)` de poids moyen, le segment 5h entier en `cream(0.35)`.
  - Couleurs des chiffres :
    - contexte : `OpusTheme.contextColor` au-delà de 70 % ;
    - semaine et 5h : `UsageLimits.level`, ambre puis rouge.
  - Police : système 10,5 pt, chiffres `monospacedDigit`.
  - Plus de jauge ni de point d'activité dans cette barre : les points vivent dans les onglets.
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : rendu.** `testRenderStatusBar` (900x22, contexte 36 %, semaine 23 %, 5h 2 %, mémoire) -> `status.png`, puis lire l'image.
- [ ] **Step 6 : commit** `Status bar: context, week and memory as words and numbers, no gauge`.

### Task 8 : la disposition B et le réglage

**Files :**
- Modify : `Sources/Opus/OpusPreferences.swift` (`enum ChromeLayout: String, CaseIterable { case toolbarAndStatus, singleBottomBar }`, `var chromeLayout: ChromeLayout`, clé `chromeLayout`, défaut `.toolbarAndStatus`)
- Modify : `Sources/Opus/SettingsWindowController.swift` : onglet Appearance, menu « Disposition » avec « Barre d'outils en haut, état en bas » et « Une seule barre en bas ».
- Modify : `Sources/Opus/TerminalContainerView.swift`. Elle observe `opusPreferencesDidChange` et repose les barres quand `chromeLayout` change.
- Test : `Tests/OpusTests/ChromeLayoutTests.swift`, `RenderProbeTests` (étendre)

**Interfaces :**
- Produces : `OpusPreferences.chromeLayout`, et `static func chromeFrames(layout: ChromeLayout, bounds: NSRect) -> (top: NSRect?, bottom: NSRect, terminal: NSRect)` sur `TerminalContainerView`, fonction pure qui pose les barres.

- [ ] **Step 1 : tests qui échouent**

```swift
func testTheDefaultLayoutIsToolbarAndStatus()  // UserDefaults vierge -> .toolbarAndStatus
func testLayoutAReservesATopAndABottomBar()    // bounds 900x500 -> top 32 pt en haut, bottom 22 pt, terminal entre les deux
func testLayoutBReservesOneBottomBar()         // top == nil, bottom 32 pt, terminal du haut jusqu'à la barre
```
- [ ] **Step 2 : `swift test --filter ChromeLayoutTests`** : échec.
- [ ] **Step 3 : implémenter.**
  - En B, une seule `ChromeBar(edge: .maxY)` de 32 pt porte, de gauche à droite : onglets, espace, statut (contexte · semaine · mémoire), séparateur, boutons.
  - Les mêmes vues sont réutilisées, déplacées d'une barre à l'autre. `showsMemory` passe la mémoire dans le statut droit.
  - Les panneaux suivent le terminal en hauteur.
  - Changer de réglage repose les barres une seule fois.
- [ ] **Step 4 : PASS**, puis `swift test` complet.
- [ ] **Step 5 : rendu.** `testRenderLayoutAAndB` : fenêtre complète 900x500, terminal factice (`TerminalView` nourri d'un texte d'exemple par `feed(text:)`), barres posées par `chromeFrames` -> `layout-a.png` et `layout-b.png`. Lire les deux images.
- [ ] **Step 6 : commit** `Settings: choose between a top toolbar with a status bar, and one bottom bar`.

### Task 9 : finition et livraison

**Files :**
- Modify : `README.md` (fonctionnalités et entrée du 30/10)

- [ ] **Step 1 :** `swift test 2>&1 | grep "Executed .* tests"` : 0 échec.
- [ ] **Step 2 :** `./build.sh` : « Opus installed ».
- [ ] **Step 3 : README.** Mettre à jour les lignes de fonctionnalités concernées : barres, gestes, panneau Copier à gauche, artifacts par moment, onglet Code, réglage Disposition.
- [ ] **Step 4 : commit** `README: the integrated chrome and drawer gestures`, puis rendre compte à l'utilisateur : ce qui a été vu à la sonde, ce qui reste à voir après sa relance (gestes réels sur son trackpad, sens du défilement naturel).
