# Opus : une interface intégrée, et des panneaux au geste

Date : 30/10/2026. Statut : description à valider par l'utilisateur.

## Pourquoi

L'utilisateur, en regardant la fenêtre : « on dirait qu'on les a rajoutés dans un logiciel qui n'est pas le nôtre ». Les boutons, la jauge et les onglets flottent par-dessus le terminal ou s'étalent sur toute la largeur, chacun dans son propre style. La référence qu'il donne : n'importe quelle app native Apple, où « chaque bouton a sa place » au lieu « d'essayer de se trouver une place ».

Aujourd'hui, de haut en bas :
- quatre icônes posées sur le texte du terminal, en haut à droite, de couleurs différentes (copier, artifacts, épingle bleue, bouclier orange) ;
- une ligne de contexte fine sur toute la largeur, avec un point, puis des chiffres minuscules (`36% · 357k │ 5h 2% ⟳16:50 · 7j 23% ⟳mer │ mémoire : …`) ;
- des onglets en pilules qui se partagent toute la largeur, en bas.

## Ce que l'utilisateur utilise vraiment (ses mots, résumés)

- Il lit le **pourcentage** de contexte, jamais la jauge.
- Il regarde l'usage de la **semaine** bien plus que celui de 5 h (qu'il n'atteint presque jamais). Les heures de reset l'intéressent peu : il sait que la semaine repart le mercredi.
- Boutons : **copier** sera le plus utilisé ; **épingler** et **bypass permissions** se règlent une fois en début de session, puis plus jamais ; le panneau **artifacts** sert assez souvent mais est peu pratique à ouvrir (raccourci ou viser en haut à droite) ; le **trousseau** sert tout le temps (aujourd'hui seulement au raccourci global).
- Dans les artifacts, il cherche surtout les **images générées** (pour les ouvrir) et les **documents générés** (pour les retrouver dans leur dossier), et d'abord **les plus récents**. Les fichiers de code qu'une session touche par dizaines (`.swift`…) l'encombrent : il ne les regarde jamais. Le Cmd+clic dans le terminal couvre une partie du besoin.

## Objectifs

1. **Chaque contrôle dans une barre qui lui est réservée.** Plus rien ne flotte sur le texte du terminal, plus de jauge pleine largeur.
2. **Deux dispositions à essayer en vrai, avec un réglage pour basculer** (décision de l'utilisateur : « faut tester les 2 en action ») :
   - **A** : barre d'outils en haut (onglets à gauche, boutons à droite), barre d'état en bas (mémoire à gauche, chiffres à droite). Argument de l'utilisateur : le curseur jeté vers le haut s'arrête au bord, il reste environ 1 cm à corriger (le panneau est sous la barre des menus), contre bien plus vers le bas.
   - **B** : une seule barre, en bas (onglets, chiffres, mémoire, boutons). Argument de l'utilisateur : garde le concept actuel en l'améliorant, et rien au-dessus du texte à lire.
   L'utilisateur vit avec chacune, puis on garde la gagnante (le réglage peut rester ou partir, à décider après l'essai).
3. **Les chiffres que l'utilisateur lit, rien de plus visible :** `contexte 36 %`, `semaine 23 %` mis en avant, `5h 2 %` discret, la mémoire (`mémoire : socle` ou les domaines). Les heures de reset et le détail des tokens passent dans l'infobulle.
4. **Boutons :** Copier, Artifacts, Trousseau, puis un menu « ⋯ » qui range Épingler, bypass permissions et « Ouvrir dans Terminal ». Icônes SF Symbols monochromes, même taille, qui s'éclairent au survol, comme une barre d'outils macOS.
5. **Panneaux au geste** (décisions de l'utilisateur) :
   - le panneau **Copier passe à gauche**, le panneau **Artifacts reste à droite** ;
   - balayage horizontal à deux doigts sur le terminal : **vers la droite**, Copier arrive par la gauche ; **vers la gauche**, Artifacts arrive par la droite ;
   - le panneau **suit les doigts** pendant le geste et se cale ouvert ou fermé au relâcher, comme sur iPhone ;
   - le geste inverse referme le panneau ouvert ;
   - au **clic** sur un bouton (ou au raccourci), chaque panneau arrive de son propre côté.
6. **Panneau Artifacts repensé** (décisions de l'utilisateur) :
   - **ordre chronologique**, le plus récent en haut, regroupé par moment (à l'instant, il y a 12 min, il y a 2 h, hier, puis la date) ;
   - dans chaque moment, les **images en grandes vignettes côte à côte**, puis les **documents** en lignes (nom, dossier) avec **« Afficher dans le Finder » au survol** ;
   - on **garde les onglets existants** (Tous, Fichiers, Images, Liens, Dossiers) et on ajoute **Code** ; **« Tous » n'affiche pas le code** par défaut ;
   - le panneau couvre **seulement les conversations de l'onglet actif**, comme aujourd'hui (« sinon on va s'y perdre ») : pas d'historique des autres sessions.

## Non-objectifs

- Ne pas toucher au rendu de Claude Code lui-même (son pied de page, ses règles, son « bypass permissions on »).
- Ne pas refaire le contenu du panneau Copier : seul son côté change.
- Pas de défilement au pixel, pas de Metal.
- Ne pas passer par-dessus la barre des menus de macOS.

## Ce qui serait un échec même si ça marche

- Un élément d'interface qui recouvre le texte du terminal en permanence.
- De la couleur sans signification (l'épingle bleue et le bouclier orange d'aujourd'hui). La couleur reste réservée à un état qui demande l'attention : seuils de contexte et d'usage (ambre puis rouge), points d'activité des onglets.
- Un panneau qui redimensionne le terminal (règle posée par `b427c28` : Claude Code répète du texte quand la largeur change).
- Un geste qui gêne le défilement vertical ou la sélection de texte.

## Contraintes

- AppKit, SwiftTerm 1.99 (API 2.0), cible macOS 13 : AppKit garde ses comportements d'avant macOS 14, dont `clipsToBounds = true` par défaut sur toute vue.
- Deux hôtes partagent `TerminalContainerView` : le panneau Quick Terminal (flou, sans bordure, sous la barre des menus) et `MainTerminalWindow`. Les deux reçoivent la même interface.
- Les raccourcis existants restent : Cmd+Shift+C (copier), Cmd+Shift+A (artifacts), le raccourci global du trousseau.
- Le terminal garde une taille stable : changer de disposition dans les réglages le redimensionne une fois, c'est acceptable ; ouvrir un panneau, jamais.
- Les points d'activité des onglets (cyan au travail, rouge en attente, vert terminé) gardent leur sens.
- Tests : la logique pure (classement du code, regroupement par moment, reconnaissance du geste, contenu de la barre d'état) dans les kits testables, en XCTest comme le reste. Le rendu se vérifie par capture réelle d'une fenêtre de test (`screencapture -l`, possible écran allumé), pas seulement par les tests.

## Mes choix (à vérifier par l'utilisateur)

- **Onglets** : compacts, alignés à gauche, largeur selon le titre (style Safari compact), point d'activité devant le titre, « + » pour un nouvel onglet. Avec un seul onglet, son titre reste affiché (comme un titre de fenêtre) plutôt qu'une barre vide.
- **La jauge disparaît** ; le pourcentage garde son escalade de couleur (ambre puis rouge) sur le chiffre lui-même.
- **Le bouclier disparaît de l'interface** : l'état bypass se lit dans le pied de page de Claude Code, et se change dans « ⋯ » (coche).
- **Hauteurs** : barre d'outils 32 pt, barre d'état 22 pt, en disposition A ; barre unique 32 pt en B.
- **Geste** : un défilement horizontal compte quand le déplacement horizontal dépasse deux fois le vertical après 8 pt ; ouverture validée au-delà d'un tiers de la largeur du panneau ou sur une vitesse de lancer suffisante. La Magic Mouse (un doigt) se comporte pareil.
- **Ce qui compte comme code** : les extensions de code source et de configuration (`swift`, `ts`, `tsx`, `js`, `jsx`, `mjs`, `cjs`, `py`, `rb`, `go`, `rs`, `java`, `kt`, `c`, `h`, `cpp`, `m`, `mm`, `sh`, `zsh`, `json`, `yml`, `yaml`, `toml`, `lock`, `xml`, `plist`, `css`, `scss`). Restent dans « Fichiers » : `md`, `pdf`, `html`, `txt`, `csv`, les images, les documents bureautiques. Les **dossiers** restent dans « Tous » et dans leur onglet.
- **Réglage de disposition** dans la fenêtre Réglages existante, A par défaut le temps de l'essai.
- **Fenêtre principale** (`MainTerminalWindow`) : elle garde sa barre de titre macOS ; les barres de l'une ou l'autre disposition se placent dans son contenu, comme dans le panneau. L'essai A contre B se fait dans le panneau Quick Terminal, celui que l'utilisateur utilise.
- **Un seul panneau ouvert à la fois.** Le geste inverse referme d'abord le panneau ouvert ; un second geste dans le même sens ouvre l'autre. Un clic sur le bouton de l'autre panneau, ou son raccourci, fait l'échange (l'un sort, l'autre entre). Deux panneaux par-dessus le terminal en couvriraient plus de la moitié.
- **Moments des artifacts** : des tranches fixes, prévisibles : « Dernière heure », « Aujourd'hui », « Hier », puis la date. Un artifact est daté par sa **dernière mention** dans la conversation (comportement actuel de la fusion) : un fichier que Claude cite à nouveau remonte, puisqu'il redevient d'actualité.
- **Le code n'a pas d'interrupteur** : « Tous » ne l'affiche jamais, l'onglet « Code » est l'endroit où le trouver. Le compteur de « Tous » compte donc tout sauf le code ; la règle actuelle des tests (les compteurs des onglets s'additionnent en « Tous ») s'ajuste en conséquence.

## Laissé au constructeur

- Le découpage du code (nouvelles vues pour la barre d'outils, la barre d'état, les onglets ; ce qui reste de `StatusRailView`, `OpusTabBar` et de la rangée de boutons en haut à droite).
- Les symboles SF exacts, les espacements fins, les animations, dans les jetons d'`OpusTheme`.
- La façon dont `RightDock` devient un gestionnaire des deux bords (copier à gauche, artifacts à droite) et pilote un panneau suivant le doigt.
- L'ordre de livraison, tant que chaque étape laisse Opus utilisable.
