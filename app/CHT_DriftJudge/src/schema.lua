-- CHT Drift Judge – settings schema: every setting with a label, a description, what it changes,
-- its default and how it is edited. Used by the Settings tab, the global search and the "changed"
-- markers. Pure Lua (testable offline).

local config = require('src/config')

local schema = {}

-- impact tags: what kind of thing a setting changes (shown as a coloured tag next to "Mit változtat")
schema.impacts = {
  score = 'pontszám',
  zero = 'nullás kör',
  flag = 'csak jelzés',
  detect = 'felismerés',
  display = 'megjelenés',
  file = 'mentés',
}

-- Defaults of the display / app options (stored in settings.ui). Scoring defaults come from config.defaults.
schema.uiDefaults = {
  depthOff = false, showBands = true,
  showCarPoint = false, autoOpenResult = true, saveAborted = false, carMode = 'auto', todoMode = 'panel',
  fillAlpha = 0.25, pointSize = 1.0, showPaintTool = false,
  broadcastHud = false, broadcastQuali = true, decelAlways = false, eventAutoNext = true,
}

schema.groups = {
  { id = 'ratio', title = 'Pontozási arány', sub = 'Line 60 / Angle 20 / Stílus 20 (DM), 100 pontos összeg' },
  { id = 'angle', title = 'Szög', sub = 'célszög, túldobás, beforgás, megállás' },
  { id = 'offtrack', title = 'Pályaelhagyás', sub = 'mi számít kint lévő keréknek, mennyit von le' },
  { id = 'corr', title = 'Korrekció és fal utáni mentés', sub = 'legyezés, szögesés, mentés falérintés után' },
  { id = 'zones', title = 'Zónák', sub = 'távolságok a 100% / 0% Line-hoz, touch and go' },
  { id = 'weights', title = 'Zónák automatikus súlyozása', sub = 'mennyit ér egy zóna a hossza, az íve és a típusa alapján' },
  { id = 'style', title = 'Stílus (mérhető)', sub = 'indítás 5, folyamatosság 10, elkötelezettség 5 (DM)' },
  { id = 'run', title = 'Futás és mentés', sub = 'futás hossza, figyelt autó, mentés' },
  { id = 'display', title = 'Megjelenítés', sub = 'Teendők panel, kitöltés erőssége, sávhatárok, takarás' },
}

-- kind: 'slider' | 'bool' | 'combo'. store: 'scoring' (settings.scoring) | 'ui' (settings.ui)
-- parent: shown only while that bool setting is on. keywords: extra search words.
schema.items = {
  -- Pontozási arány ---------------------------------------------------------------------------------
  { key = 'normalizeTotal', group = 'ratio', kind = 'bool', impact = 'score',
    label = 'Összpont mindig 100',
    desc = 'A zónák súlyát arányosítja, így a zónák összesen pontosan 80 pontot érnek (a stílussal együtt 100), akárhány zóna van. Stílus súly nélkül a zónák adják a 100-at.',
    effect = 'minden zóna max pontja (pl. 30 + 20 + 30 súly → 30 + 20 + 30 pont a 80-ból)', keywords = 'normalizálás arányosítás súly max pont' },
  { key = 'lineWeight', group = 'ratio', kind = 'slider', min = 0, max = 1, fmt = '%.2f', impact = 'score',
    label = 'Line súlya a zónapontban',
    desc = 'A zónapont = Line súlya × Line + Angle súlya × Angle. A két súly összege legyen 1. Alap: 0,75 – a zónák 80 pontjából így lesz Line 60 és Angle 20 (Drift Masters 2025, 1.6).',
    effect = 'minden zóna pontja – nagyobb érték = a vonal (távolság) többet számít', keywords = 'arány 60 20 75 25 vonal dm drift masters' },
  { key = 'angleWeight', group = 'ratio', kind = 'slider', min = 0, max = 1, fmt = '%.2f', impact = 'score',
    label = 'Angle súlya a zónapontban',
    desc = 'A szög aránya a zónapontban. A Line súlyával együtt adja ki az 1-et. Alap: 0,25 (Angle 20 a 100-ból).',
    effect = 'minden zóna pontja – nagyobb érték = a szög többet számít', keywords = 'arány szög' },
  { key = 'styleWeight', group = 'ratio', kind = 'slider', min = 0, max = 0.5, fmt = '%.2f', impact = 'score',
    label = 'Stílus súlya az összpontban',
    desc = 'Ennyi része a 100 pontnak jön a mérhető stílusból (alap: 0,20 = 20 pont, a DM-szabálykönyv szerint); a zónák a maradékot (80) adják. 0 = a stílus csak információ.',
    effect = 'Végső pontszám: zónák (1 − súly) × 100 pontból + stílus súly × 100 pontból', keywords = 'style 20 dm' },
  { key = 'angleGating', group = 'ratio', kind = 'combo', impact = 'score',
    label = 'Szög csak a zónán belül számít',
    desc = 'Szigorú: ahol a zóna nincs lefedve (az autó nincs a zóna sávjában), ott a szög 0-nak számít – „jó vonal nélkül nincs jó szög”.',
    effect = 'a zónák Angle értéke, ha a zóna egy része kimaradt',
    options = { { 'strict', 'Igen – a lefedetlen rész 0 szög (szigorú)' }, { 'covered', 'Csak a lefedett részen átlagolva' } },
    keywords = 'gating lefedés' },
  { key = 'lineNeedsDrift', group = 'ratio', kind = 'bool', impact = 'score',
    label = 'Line csak drift közben számít',
    desc = 'Ha be van kapcsolva, a zónában szög nélkül (egyenesen) haladva nem jár Line pont.',
    effect = 'a zónák Line értéke lassú / egyenes áthaladásnál', keywords = 'egyenes lassú' },

  -- Szög ----------------------------------------------------------------------------------------------
  { key = 'angleTarget', group = 'angle', kind = 'slider', min = 20, max = 95, fmt = '%.0f°', impact = 'score',
    label = 'Célszög',
    desc = 'E fölött jár a teljes (100%) szögpont. A minimális szög és a célszög között egyenletesen nő. Zónánként felülírható.',
    effect = 'a zónák Angle értéke – alacsonyabb célszög = könnyebb 100%', keywords = 'angle target 72 75' },
  { key = 'angleMin', group = 'angle', kind = 'slider', min = 0, max = 60, fmt = '%.0f°', impact = 'score',
    label = 'Minimális szög',
    desc = 'E alatt 0 a szögpont. Zónánként felülírható.', effect = 'a zónák Angle értéke', keywords = 'angle min' },
  { key = 'overAngle', group = 'angle', kind = 'slider', min = 60, max = 130, fmt = '%.0f°', impact = 'flag',
    label = 'Túldobás határa',
    desc = 'E fölött a „Túldobás” bekerül a hibagyűjtőbe. Önmagában nem von le pontot (lásd: Túldobás levonása).',
    effect = 'Túldobás jelzés a hibagyűjtőben', keywords = 'over rotation túlforgás' },
  { key = 'overRotationPenalty', group = 'angle', kind = 'slider', min = 0, max = 10, fmt = '%.1f', impact = 'score',
    label = 'Túldobás levonása',
    desc = 'Ennyi pont jön le túldobásonként. 0 = csak jelzés, a bírók döntenek.', effect = 'Végső pontszám', keywords = 'over rotation levonás' },
  { key = 'spinAngle', group = 'angle', kind = 'slider', min = 90, max = 175, fmt = '%.0f°', impact = 'zero',
    label = 'Beforgás határa',
    desc = 'Ha a szög ennél nagyobb a lent megadott ideig, az beforgás (spin).', effect = 'NULLÁS KÖR, ha a „Beforgás = nullás kör” be van kapcsolva', keywords = 'spin' },
  { key = 'spinTime', group = 'angle', kind = 'slider', min = 0, max = 2, fmt = '%.2f s', impact = 'zero',
    label = 'Beforgás: ennyi ideig a határ fölött',
    desc = 'Ennyi ideig kell a beforgás határa fölött lenni, hogy beforgásnak számítson.', effect = 'mikor nullás a kör beforgás miatt', keywords = 'spin idő' },
  { key = 'spinZero', group = 'angle', kind = 'bool', impact = 'zero',
    label = 'Beforgás / megállás = nullás kör',
    desc = 'Beforgás vagy a bírálat alatti megállás nullás kört jelent.', effect = 'NULLÁS KÖR', keywords = 'spin stall' },
  { key = 'stallSpeed', group = 'angle', kind = 'slider', min = 0, max = 40, fmt = '%.0f km/h', impact = 'zero',
    label = 'Megállás: sebesség e alatt',
    desc = 'Ha az autó a bírálat alatt ennél lassabb a lent megadott ideig, az megállásnak számít.', effect = 'NULLÁS KÖR megállásnál', keywords = 'stall lefulladás' },
  { key = 'stallTime', group = 'angle', kind = 'slider', min = 0, max = 3, fmt = '%.1f s', impact = 'zero',
    label = 'Megállás: ennyi ideig', desc = 'Ennyi ideig kell lassúnak lennie a megálláshoz.', effect = 'mikor nullás a kör megállás miatt', keywords = 'stall' },
  { key = 'driftMinAngle', group = 'angle', kind = 'slider', min = 2, max = 30, fmt = '%.0f°', impact = 'detect',
    label = 'Egyenes: szög e alatt',
    desc = 'E alatt az autó nem driftel (egyenesen halad). Ehhez mérjük az indítást, a kiegyenesedést és a „Line csak drift közben” szabályt.',
    effect = 'drift felismerése', keywords = 'drift min straight' },
  { key = 'minSpeed', group = 'angle', kind = 'slider', min = 0, max = 60, fmt = '%.0f km/h', impact = 'detect',
    label = 'Szögmérés minimális sebessége',
    desc = 'E alatt a szöget nem mérjük (nagyon lassan a szög értelmetlen és zajos).', effect = 'szögmérés lassú tempónál', keywords = 'sebesség' },
  { key = 'straightTime', group = 'angle', kind = 'slider', min = 0, max = 3, fmt = '%.1f s', impact = 'flag',
    label = 'Kiegyenesedés: ennyi ideig egyenesen',
    desc = 'Ha a bírálat alatt ennyi ideig egyenesen megy, „Kiegyenesedés” jelzést kap.', effect = 'Kiegyenesedés jelzés', keywords = 'straight' },

  -- Pályaelhagyás -----------------------------------------------------------------------------------
  { key = 'offTrackAC', group = 'offtrack', kind = 'bool', impact = 'detect',
    label = 'Forrás: AC saját pályahatára',
    desc = 'Az Assetto Corsa saját „kerék kint” jelzése. Sok drift pályán ez soha nem jelez semmit, ezért vannak a többi források is.',
    effect = 'mikor számít kint lévőnek egy kerék', keywords = 'wheels outside forrás' },
  { key = 'offTrackSurface', group = 'offtrack', kind = 'bool', impact = 'detect',
    label = 'Forrás: fű / föld / murva / homok',
    desc = 'Ha a kerék alatt nem aszfalt van (a pálya felület-adatai szerint), az kint lévő kerék.',
    effect = 'mikor számít kint lévőnek egy kerék', keywords = 'surface fű grass gravel forrás' },
  { key = 'offTrackZones', group = 'offtrack', kind = 'bool', impact = 'detect',
    label = 'Forrás: a zónák vonalai is pályahatárok',
    desc = 'Nem kell külön határt rajzolni: ha a kerék az OZ külső vagy az IZ belső vonalán túl van, az pályaelhagyás. Ha egy vonalon az autó közepe is áthalad, azt a rendszer hibás vonalnak veszi, és ott nem figyeli.',
    effect = 'mikor számít kint lévőnek egy kerék', keywords = 'zóna vonal határ forrás' },
  { key = 'limitOZ', group = 'offtrack', kind = 'bool', parent = 'offTrackZones', impact = 'detect',
    label = 'OZ külső vonalán túl', desc = 'Az OZ vonalán túl lévő kerék kint van.', effect = 'pályaelhagyás az OZ-oknál', keywords = 'outer' },
  { key = 'limitIZ', group = 'offtrack', kind = 'bool', parent = 'offTrackZones', impact = 'detect',
    label = 'IZ belső vonalán túl (belső levágás)', desc = 'Az IZ vonalán belülre kerülő kerék kint van.', effect = 'pályaelhagyás az IZ-knél', keywords = 'inner levágás' },
  { key = 'limitTNG', group = 'offtrack', kind = 'bool', parent = 'offTrackZones', impact = 'detect',
    label = 'Touch and go vonalán túl',
    desc = 'Csak akkor kapcsold be, ha a TNG vonal tényleg a pálya széle (sokszor a pályán belül van felfestve).',
    effect = 'pályaelhagyás a TNG zónáknál', keywords = 'tng' },
  { key = 'offTrackLimits', group = 'offtrack', kind = 'bool', impact = 'detect',
    label = 'Forrás: külön rajzolt HATÁR vonalak',
    desc = 'A szerkesztőben „+ HATÁR” típussal rajzolt vonalak. Opcionális: akkor kell, ha a pálya széle nem zóna.',
    effect = 'mikor számít kint lévőnek egy kerék', keywords = 'limit határ' },
  { key = 'zoneLimitTolerance', group = 'offtrack', kind = 'slider', min = 0, max = 1, fmt = '%.2f m', impact = 'detect',
    label = 'Zónavonalon túl – tűrés',
    desc = 'Ennyivel kell a kerék közepének a vonalon túl lennie (0,15 m ≈ az egész gumi kint van).',
    effect = 'mikor számít pályaelhagyásnak a kerék a zónavonalaknál', keywords = 'tolerance' },
  { key = 'offTrackMinTime', group = 'offtrack', kind = 'slider', min = 0, max = 0.5, fmt = '%.2f s', impact = 'detect',
    label = 'Legrövidebb számított pályaelhagyás',
    desc = 'Az ennél rövidebb villanásokat figyelmen kívül hagyja.', effect = 'pályaelhagyások száma', keywords = 'idő' },
  { key = 'offTrackEndHold', group = 'offtrack', kind = 'slider', min = 0, max = 1, fmt = '%.2f s', impact = 'detect',
    label = 'Pályaelhagyás vége',
    desc = 'Ennyi ideig kell minden keréknek bent lennie, hogy egy pályaelhagyás véget érjen (így egy kicsúszás egynek számít).',
    effect = 'pályaelhagyások száma', keywords = 'idő' },
  { key = 'oneWheelPenalty', group = 'offtrack', kind = 'slider', min = 0, max = 10, fmt = '%.1f', impact = 'score',
    label = 'Egykerekes pályaelhagyás levonása',
    desc = 'Ennyi pont jön le darabonként a végső pontszámból.', effect = 'Végső pontszám', keywords = 'one wheel egy kerék levonás' },
  { key = 'oneWheelZeroAt', group = 'offtrack', kind = 'slider', min = 1, max = 10, fmt = '%.0f db', int = true, impact = 'zero',
    label = 'Ennyi egykerekes = nullás kör',
    desc = 'Ennyi egykerekes pályaelhagyás után a kör nullás.', effect = 'NULLÁS KÖR', keywords = 'one wheel egy kerék' },
  { key = 'twoWheelZero', group = 'offtrack', kind = 'bool', impact = 'zero',
    label = 'Kétkerekes pályaelhagyás = nullás kör',
    desc = 'Ha egyszerre legalább 2 kerék kint van, a kör nullás.', effect = 'NULLÁS KÖR', keywords = 'two wheel két kerék' },

  -- Korrekció -----------------------------------------------------------------------------------------
  { key = 'correctionPenalty', group = 'corr', kind = 'slider', min = 0, max = 10, fmt = '%.1f', impact = 'score',
    label = 'Korrekció levonása',
    desc = 'Ennyi pont jön le korrekciónként. 0 = csak jelzés (megbeszélt szabály).', effect = 'Végső pontszám', keywords = 'correction legyezés levonás' },
  { key = 'wallSavePenalty', group = 'corr', kind = 'slider', min = 0, max = 10, fmt = '%.1f', impact = 'score',
    label = 'Fal utáni mentés levonása',
    desc = 'Ennyi pont jön le, ha falérintés után korrigálni kellett. 0 = csak jelzés.', effect = 'Végső pontszám', keywords = 'wall save fal' },
  { key = 'dipDegrees', group = 'corr', kind = 'slider', min = 3, max = 40, fmt = '%.0f°', impact = 'flag',
    label = 'Korrekció: szögesés',
    desc = 'Ekkora gyors szögesés (a lenti időn belül), majd visszanövés számít korrekciónak.', effect = 'korrekciók száma – kisebb érték = érzékenyebb', keywords = 'correction dip' },
  { key = 'dipTime', group = 'corr', kind = 'slider', min = 0.1, max = 2, fmt = '%.2f s', impact = 'flag',
    label = 'Korrekció: szögesés ideje',
    desc = 'Ennyi idő alatt kell a szögnek esnie. A lassú, egyenletes szögváltozás nem korrekció.', effect = 'korrekciók száma', keywords = 'correction dip idő' },
  { key = 'dipRecover', group = 'corr', kind = 'slider', min = 0, max = 20, fmt = '%.0f°', impact = 'flag',
    label = 'Korrekció: visszanövés',
    desc = 'A szögesés után ennyit kell visszanőnie (ugyanabba az irányba), hogy korrekció legyen.', effect = 'korrekciók száma', keywords = 'correction' },
  { key = 'fanAmplitude', group = 'corr', kind = 'slider', min = 0.01, max = 0.3, fmt = '%.2f', impact = 'flag',
    label = 'Legyezés: kormánymozdulat mérete',
    desc = 'A teljes kormányzár ekkora része számít egy kormány-irányváltásnak.', effect = 'legyezés felismerése', keywords = 'fan legyezés kormány' },
  { key = 'fanReversals', group = 'corr', kind = 'slider', min = 2, max = 8, fmt = '%.0f db', int = true, impact = 'flag',
    label = 'Legyezés: kormány-irányváltások száma',
    desc = 'Ennyi kormány-irányváltás a lenti időn belül (ugyanabban a driftirányban) = korrekció.', effect = 'legyezés felismerése', keywords = 'fan legyezés' },
  { key = 'fanWindow', group = 'corr', kind = 'slider', min = 0.3, max = 3, fmt = '%.1f s', impact = 'flag',
    label = 'Legyezés: időablak', desc = 'Ennyi idő alatt kell az irányváltásoknak megtörténniük.', effect = 'legyezés felismerése', keywords = 'fan legyezés' },
  { key = 'correctionCooldown', group = 'corr', kind = 'slider', min = 0, max = 3, fmt = '%.1f s', impact = 'flag',
    label = 'Két korrekció közti minimum',
    desc = 'Ennyi időn belül egy újabb korrekció nem számít külön (így egy javítás egynek számít).', effect = 'korrekciók száma', keywords = 'correction' },
  { key = 'wallSaveWindow', group = 'corr', kind = 'slider', min = 0, max = 3, fmt = '%.1f s', impact = 'flag',
    label = 'Fal utáni mentés ablaka',
    desc = 'Ha falérintés után ennyi időn belül korrekció jön, az „Fal utáni mentés” (külön kategória, nem korrekció).', effect = 'Fal utáni mentés / Korrekció besorolás', keywords = 'wall save fal mentés' },

  -- Zónák ---------------------------------------------------------------------------------------------
  { key = 'ozFullDist', group = 'zones', kind = 'slider', min = 0, max = 3, fmt = '%.2f m', impact = 'score',
    label = 'OZ: 100% távolság', desc = 'A hátsó lökhárító legfeljebb ennyire legyen a külső vonaltól a teljes Line ponthoz.', effect = 'az OZ zónák Line értéke', keywords = 'outer zone távolság' },
  { key = 'ozZeroDist', group = 'zones', kind = 'slider', min = 0.5, max = 8, fmt = '%.2f m', impact = 'score',
    label = 'OZ: 0% távolság', desc = 'Ennél messzebb a külső vonaltól a Line 0. A kettő között egyenletesen csökken.', effect = 'az OZ zónák Line értéke', keywords = 'outer zone távolság' },
  { key = 'izFullDist', group = 'zones', kind = 'slider', min = 0, max = 3, fmt = '%.2f m', impact = 'score',
    label = 'IZ: 100% távolság', desc = 'Az első lökhárító legfeljebb ennyire legyen a belső vonaltól a teljes Line ponthoz.', effect = 'az IZ zónák Line értéke', keywords = 'inner zone távolság' },
  { key = 'izZeroDist', group = 'zones', kind = 'slider', min = 0.5, max = 8, fmt = '%.2f m', impact = 'score',
    label = 'IZ: 0% távolság', desc = 'Ennél messzebb a belső vonaltól a Line 0.', effect = 'az IZ zónák Line értéke', keywords = 'inner zone távolság' },
  { key = 'wallFullDist', group = 'zones', kind = 'slider', min = 0, max = 1, fmt = '%.2f m', impact = 'score',
    label = 'Falas zóna: 100% távolság', desc = 'A max pont csak ennyire közel a falhoz jár (megbeszélt: 4 cm).', effect = 'a falas zónák Line értéke', keywords = 'wall fal 4 cm' },
  { key = 'wallZeroDist', group = 'zones', kind = 'slider', min = 0.5, max = 8, fmt = '%.2f m', impact = 'score',
    label = 'Falas zóna: 0% távolság', desc = 'Ennél messzebb a faltól a Line 0.', effect = 'a falas zónák Line értéke', keywords = 'wall fal' },
  { key = 'contactCountsAsLine', group = 'zones', kind = 'bool', impact = 'score',
    label = 'Érintés = 0 cm', desc = 'Ha a hátulja érinti a falat / vonalat egy OZ-ban vagy falas zónában, az 0 cm-nek (teljes Line) számít.', effect = 'OZ és falas zónák Line értéke érintésnél', keywords = 'contact érintés fal' },
  { key = 'tngMode', group = 'zones', kind = 'combo', impact = 'score',
    label = 'Touch and go pontozás', desc = 'Lépcsős: az első kerék közelsége szerint 100 / 66 / 33 / 0 %. Folyamatos: a vonalak között egyenletesen.',
    effect = 'a TNG zónák Line értéke', options = { { 'step', 'Lépcsős (100 / 66 / 33 / 0)' }, { 'linear', 'Folyamatos' } }, keywords = 'tng touch and go' },
  { key = 'tngTier1', group = 'zones', kind = 'slider', min = 0, max = 3, fmt = '%.2f m', impact = 'score',
    label = 'Touch and go: 1. vonal (100%)', desc = 'Az első kerék ennyire közel a TNG vonalhoz = 100%.', effect = 'a TNG zónák Line értéke', keywords = 'tng' },
  { key = 'tngTier2', group = 'zones', kind = 'slider', min = 0, max = 4, fmt = '%.2f m', impact = 'score',
    label = 'Touch and go: 2. vonal (66%)', desc = 'Ennyire közel = 66%.', effect = 'a TNG zónák Line értéke', keywords = 'tng' },
  { key = 'tngTier3', group = 'zones', kind = 'slider', min = 0, max = 6, fmt = '%.2f m', impact = 'score',
    label = 'Touch and go: 3. vonal (33%)', desc = 'Ennyire közel = 33%, ennél messzebb 0%.', effect = 'a TNG zónák Line értéke', keywords = 'tng' },
  { key = 'icFullDist', group = 'zones', kind = 'slider', min = 0, max = 3, fmt = '%.2f m', impact = 'score',
    label = 'IC pont: 100% távolság', desc = 'Az első lökhárító ennyire közel az IC (belső érintési) ponthoz = teljes Line pont.', effect = 'az IC pontok Line értéke', keywords = 'ic clip clipping pont érintési belső inner' },
  { key = 'icZeroDist', group = 'zones', kind = 'slider', min = 0.3, max = 8, fmt = '%.2f m', impact = 'score',
    label = 'IC pont: 0% távolság', desc = 'Ennél messzebb az IC ponttól a Line 0 (a kettő között egyenletesen csökken).', effect = 'az IC pontok Line értéke', keywords = 'ic clip clipping pont érintési belső inner' },
  { key = 'binSize', group = 'zones', kind = 'slider', min = 0.1, max = 1, fmt = '%.2f m', impact = 'score',
    label = 'Zóna felbontása', desc = 'A zóna ilyen hosszú szeletekre van osztva; szeletenként mérjük a távolságot és a szöget.', effect = 'pontosság (kisebb = részletesebb)', keywords = 'bin felbontás' },
  { key = 'captureMargin', group = 'zones', kind = 'slider', min = 0, max = 15, fmt = '%.1f m', impact = 'score',
    label = 'Zóna követési ráhagyás', desc = 'A 0% távolságon túl még ennyi méterig követi a zóna az autót (ide eső rész 0 Line).', effect = 'lefedettség és mélység számítása', keywords = 'capture' },

  -- Zónák automatikus súlyozása -----------------------------------------------------------------------
  { key = 'autoLengthExp', group = 'weights', kind = 'slider', min = 0, max = 1, fmt = '%.2f', impact = 'score',
    label = 'A hossz hatása',
    desc = '0 = minden zóna egyformán ér (a hossz nem számít); 1 = a pont a hosszal egyenes arányban nő (kétszer olyan hosszú zóna kétszer annyit ér); 0,5 = a hosszabb zóna többet ér, de nem arányosan (négyszer olyan hosszú = kétszer annyi).',
    effect = 'az automatikusan súlyozott zónák pontja (csak ahol a pályaterv súlyozása „Automatikus”)', keywords = 'súly súlyozás hossz automatikus hosszabb zóna többet ér' },
  { key = 'autoMinLength', group = 'weights', kind = 'slider', min = 1, max = 20, fmt = '%.1f m', impact = 'score',
    label = 'Legkisebb számított hossz',
    desc = 'Az ennél rövidebb zónák (pl. egy rövid TNG vonal) ennyi hosszúnak számítanak, hogy ne érjenek túl keveset.',
    effect = 'a rövid zónák automatikus súlya', keywords = 'súly rövid tng minimum hossz' },
  { key = 'autoCurveFactor', group = 'weights', kind = 'slider', min = 0, max = 1, fmt = '%.2f', impact = 'score',
    label = 'Az ív hatása',
    desc = 'Mennyivel érjen többet egy kanyarodó zóna: 0,25 = egy 90°-ban forduló zóna 25%-kal többet ér, mint egy ugyanolyan hosszú egyenes; 0 = az ív nem számít.',
    effect = 'az automatikusan súlyozott zónák pontja', keywords = 'súly ív kanyar fordulás nehézség' },
  { key = 'autoTypeOZ', group = 'weights', kind = 'slider', min = 0, max = 3, fmt = '%.2f×', impact = 'score',
    label = 'OZ szorzó', desc = 'Az OZ zónák automatikus súlyának szorzója a többi típushoz képest.', effect = 'az OZ zónák automatikus súlya', keywords = 'súly oz típus szorzó' },
  { key = 'autoTypeIZ', group = 'weights', kind = 'slider', min = 0, max = 3, fmt = '%.2f×', impact = 'score',
    label = 'IZ szorzó', desc = 'Az IZ (clip) zónák automatikus súlyának szorzója.', effect = 'az IZ zónák automatikus súlya', keywords = 'súly iz clip típus szorzó' },
  { key = 'autoTypeWALL', group = 'weights', kind = 'slider', min = 0, max = 3, fmt = '%.2f×', impact = 'score',
    label = 'Falas zóna szorzó', desc = 'A falas zónák automatikus súlyának szorzója.', effect = 'a falas zónák automatikus súlya', keywords = 'súly fal típus szorzó' },
  { key = 'autoTypeTNG', group = 'weights', kind = 'slider', min = 0, max = 3, fmt = '%.2f×', impact = 'score',
    label = 'Touch and go szorzó', desc = 'A TNG zónák általában rövidek, de fontosak: ezzel a szorzóval érnek többet a hosszukhoz képest (alap: 1,8×).', effect = 'a TNG zónák automatikus súlya', keywords = 'súly tng touch and go típus szorzó' },
  { key = 'autoTypeIC', group = 'weights', kind = 'slider', min = 0, max = 3, fmt = '%.2f×', impact = 'score',
    label = 'IC pont szorzó', desc = 'Az IC (belső érintési) pontok automatikus súlyának szorzója. Egy pont a „Legkisebb számított hossz”-nak megfelelő zónaként számít.', effect = 'az IC pontok automatikus súlya', keywords = 'súly ic clip clipping pont típus szorzó' },

  -- Stílus --------------------------------------------------------------------------------------------
  { key = 'styleInitPts', group = 'style', kind = 'slider', min = 0, max = 20, fmt = '%.0f', impact = 'score',
    label = 'Indítás súlya', desc = 'Az indítás része a stílusból (DM: 5 a 20-ból). A három rész súlyának aránya számít.',
    effect = 'Stílus pontja', keywords = 'initiation indítás dm' },
  { key = 'styleFlowPts', group = 'style', kind = 'slider', min = 0, max = 20, fmt = '%.0f', impact = 'score',
    label = 'Folyamatosság súlya', desc = 'A folyamatosság része a stílusból (DM: 10 a 20-ból).',
    effect = 'Stílus pontja', keywords = 'fluidity flow folyamatosság dm' },
  { key = 'styleCommitPts', group = 'style', kind = 'slider', min = 0, max = 20, fmt = '%.0f', impact = 'score',
    label = 'Elkötelezettség súlya', desc = 'Az elkötelezettség része a stílusból (DM: 5 a 20-ból).',
    effect = 'Stílus pontja', keywords = 'commitment elkötelezettség dm tempó' },
  { key = 'styleInitLate', group = 'style', kind = 'slider', min = 2, max = 60, fmt = '%.0f m', impact = 'score',
    label = 'Indítás: késői indítás',
    desc = 'Ha a drift a JUDGING vonal után ennyi méterrel (vagy később) kezdődik, a „korai indítás” 0%. Ha már a vonalon driftel, 100%.',
    effect = 'Stílus / Indítás', keywords = 'early korai initiation' },
  { key = 'styleRateGood', group = 'style', kind = 'slider', min = 0.1, max = 2, fmt = '%.2f s', impact = 'score',
    label = 'Indítás: gyors szögfelvétel (100%)', desc = 'A drift kezdetétől a célszög 80%-áig ennyi idő vagy kevesebb = 100%.',
    effect = 'Stílus / Indítás', keywords = 'rate to angle szög felvétel' },
  { key = 'styleRateBad', group = 'style', kind = 'slider', min = 0.5, max = 5, fmt = '%.2f s', impact = 'score',
    label = 'Indítás: lassú szögfelvétel (0%)', desc = 'Ennyi idő vagy több a célszög 80%-áig = 0%.',
    effect = 'Stílus / Indítás', keywords = 'rate to angle' },
  { key = 'styleEntryDropBad', group = 'style', kind = 'slider', min = 4, max = 40, fmt = '%.0f°', impact = 'score',
    label = 'Indítás: szögvesztés (0%)',
    desc = 'Ha az indítás első 1,5 mp-ében a szög ennyi fokot esik, majd ugyanabba az irányba újra fel kell építeni (korrekció, kettős indítás), az 0% (3° vagy kevesebb = 100%). A DM szerint az indításnál nem csökkenhet a szög. Ellenkező irányba lendülés (fake, irányváltás) nem számít szögvesztésnek.',
    effect = 'Stílus / Indítás', keywords = 'smooth double initiation kettős' },
  { key = 'styleTransGood', group = 'style', kind = 'slider', min = 0.1, max = 2, fmt = '%.2f s', impact = 'score',
    label = 'Irányváltás: 100%', desc = 'Ilyen gyors (vagy gyorsabb) irányváltás = 100%.', effect = 'Stílus / Folyamatosság', keywords = 'transition rotation forgás' },
  { key = 'styleTransBad', group = 'style', kind = 'slider', min = 0.5, max = 4, fmt = '%.2f s', impact = 'score',
    label = 'Irányváltás: 0%', desc = 'Ilyen lassú (vagy lassabb) irányváltás = 0%.', effect = 'Stílus / Folyamatosság', keywords = 'transition' },
  { key = 'styleSmoothBad', group = 'style', kind = 'slider', min = 2, max = 40, fmt = '%.0f°', impact = 'score',
    label = 'Egyenletesség: 0%', desc = 'Ekkora átlagos szög-ingadozásnál 0% az egyenletesség (flow).', effect = 'Stílus / Folyamatosság', keywords = 'smooth flow' },
  { key = 'styleLiftGood', group = 'style', kind = 'slider', min = 0, max = 0.3, fmt = '%.2f', impact = 'score',
    label = 'Gázadás: 100%',
    desc = 'A drift közbeni út ekkora része (vagy kevesebb) mehet 30% alatti gázzal, hogy a gázadás 100% legyen (0,03 = 3%).',
    effect = 'Stílus / Elkötelezettség', keywords = 'throttle gáz elvétel lift' },
  { key = 'styleLiftBad', group = 'style', kind = 'slider', min = 0.05, max = 0.6, fmt = '%.2f', impact = 'score',
    label = 'Gázadás: 0%', desc = 'Ha a drift közbeni út ekkora része 30% alatti gázzal megy, a gázadás 0%.',
    effect = 'Stílus / Elkötelezettség', keywords = 'throttle gáz' },
  { key = 'stylePaceLow', group = 'style', kind = 'slider', min = 0.2, max = 0.95, fmt = '%.2f', impact = 'score',
    label = 'Tempótartás: 0%',
    desc = 'A futás leglassabb 10%-a / a középső sebesség. Ha a futás közben nagyon lelassul (beragad), ez az arány kicsi. Ennyinél 0%.',
    effect = 'Stílus / Elkötelezettség', keywords = 'pace tempó lendület momentum' },
  { key = 'stylePaceHigh', group = 'style', kind = 'slider', min = 0.5, max = 1, fmt = '%.2f', impact = 'score',
    label = 'Tempótartás: 100%', desc = 'Ennyinél (vagy fölötte) 100% a tempótartás.',
    effect = 'Stílus / Elkötelezettség', keywords = 'pace tempó' },
  { key = 'tempoPenalty', group = 'style', kind = 'slider', min = 0, max = 20, fmt = '%.1f', impact = 'score',
    label = 'Minimális tempó alatt: levonás',
    desc = 'Ennyi pont jön le, ha a futás átlagsebessége a pályaterv minimális tempója alatt van (Pálya fül → 5. Minimális tempó). 0 = csak jelzés, a bírók döntenek.',
    effect = 'Végső pontszám', keywords = 'tempó sebesség lassú levonás minimum' },

  -- Futás ---------------------------------------------------------------------------------------------
  { key = 'maxRunTime', group = 'run', kind = 'slider', min = 30, max = 600, fmt = '%.0f s', impact = 'detect',
    label = 'Futás maximális hossza', desc = 'Ennél hosszabb futás megszakad (pl. ha valaki elfelejtette a FINISH-t).', effect = 'mikor szakad meg egy futás', keywords = 'idő' },
  { key = 'resetZero', group = 'run', kind = 'bool', impact = 'zero',
    label = 'Visszarakás a bírálat alatt = nullás kör',
    desc = 'Ha az autót a bírálat alatt visszarakják (reset, boxba ugrás, teleport), a futás nullás kör lesz és elmentődik. Kikapcsolva a futás megszakad, eredmény nélkül. A JUDGING vonal előtt a visszarakás mindig csak megszakítás.',
    effect = 'NULLÁS KÖR visszarakásnál', keywords = 'reset teleport box visszarakás' },
  { key = 'carMode', store = 'ui', group = 'run', kind = 'combo', impact = 'detect',
    label = 'Figyelt autó', desc = 'Kit pontoz és mutat a program (HUD, Élő, Eredmény). Automatikus: amelyik autót a kamera mutatja – vezetés közben a sajátod, nézőként (spectator) vagy bíróként az, akit követsz. A más gépéről nézett autó eredménye tájékoztató: a hivatalos pontot a pilóta saját programja küldi (Versenyzők fül).',
    effect = 'melyik autó futását pontozza', options = { { 'auto', 'Automatikus (amit a kamera mutat)' }, { 'own', 'Mindig a saját autó' }, { 'focused', 'A kamerával követett autó' } }, keywords = 'kamera focused bíró néző spectator követés' },
  { key = 'autoOpenResult', store = 'ui', group = 'run', kind = 'bool', impact = 'display',
    label = 'Eredmény fül automatikus megnyitása', desc = 'Futás után magától átvált az Eredmény fülre.', effect = 'melyik fül látszik futás után', keywords = 'eredmény' },
  { key = 'saveAborted', store = 'ui', group = 'run', kind = 'bool', impact = 'file',
    label = 'Megszakított futások mentése is', desc = 'Hibakereséshez: a félbehagyott futások telemetriája is elmentődik.', effect = 'mentett futásfájlok', keywords = 'mentés abort' },

  -- Megjelenítés --------------------------------------------------------------------------------------
  { key = 'todoMode', store = 'ui', group = 'display', kind = 'combo', impact = 'display',
    label = 'Teendők panel', desc = 'Mikor látszódjon a fő ablak tetején a Teendők panel. Elrejtve a felső sorban akkor is látszik, hány teendő van, és onnan megnyitható.',
    effect = 'a fő ablak teteje (a teendők nem vesznek el, csak a panel rejtve)',
    options = { { 'panel', 'Mindig látszik' }, { 'errors', 'Csak ha HIBA van' }, { 'hidden', 'Elrejtve (csak a szám a felső sorban)' } },
    keywords = 'teendők elrejtés eltüntetés panel' },
  { key = 'fillAlpha', store = 'ui', group = 'display', kind = 'slider', min = 0.05, max = 0.8, fmt = '%.2f', impact = 'display',
    label = 'Kitöltés erőssége', desc = 'Mennyire legyen átlátszó a színes kitöltés (kisebb = átlátszóbb, jobban látszik alatta a pálya).',
    effect = 'a pályán látható rajz', keywords = 'átlátszóság szín kitöltés' },
  { key = 'pointSize', store = 'ui', group = 'display', kind = 'slider', min = 0.5, max = 3, fmt = '%.1f×', impact = 'display',
    label = 'Zónapontok mérete (szerkesztő)', desc = 'A lerakott zónapontok jelölőjének mérete a pályán: talpkorong fekete kerettel, egy oszlop és a pont sorszáma. Az első pont zöld, az utolsó lila, a többi fehér – így minden zónaszín és az aszfalt mellett is jól látszik.',
    effect = 'a pályán látható rajz (szerkesztés közben)', keywords = 'pont méret nagyobb jelölő szerkesztő kontraszt' },
  { key = 'broadcastHud', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Közvetítői HUD (teljes képernyő)', desc = 'A közvetítéshez (Streamlabs, 1920×1080): tandemben a párosítás, a két autó adatai egymás mellett (szög, sebesség, fordulatszám, fokozat, pedálok, hajtás), a közelség és a győztes; kvalifikációban a követett autó, az utolsó futása és a kvali-táblázat. Online ezzel kapcsol be, a telepített appban a „CHT Közvetítő HUD” ablakkal.',
    effect = 'a képernyő (közvetítés)', keywords = 'stream közvetítés streamer broadcast obs streamlabs overlay' },
  { key = 'broadcastQuali', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Kvali-táblázat a közvetítői HUD-on', desc = 'Kvalifikáció alatt a jobb oldalon a rangsor (az első 16). Tandem csata alatt nem látszik.',
    effect = 'a közvetítői HUD', keywords = 'stream rangsor tabella' },
  { key = 'decelAlways', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Gyorsítási / lassítási térkép mindig látszik', desc = 'A pályaterv tandem-térképe (zöld / narancs / piros vonal) nemcsak a Pálya fülön látszik, hanem mindig (pl. a bíróknak tandem alatt).',
    effect = 'a pályán látható rajz', keywords = 'accel decel map tandem térkép' },
  { key = 'showPaintTool', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Zóna a festésből eszköz (kísérleti)', desc = 'A Pálya fülön megjelenik a „Zóna a festésből” eszköz, ami a festett vonalakból rak le zónát. A CHT szerint nincs rá szükség (D20), ezért alapból rejtve van.',
    effect = 'a Pálya fül zóna listája', keywords = 'festés paint felismerés automatikus' },
  { key = 'depthOff', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Mindig látszódjanak (falon át is)', desc = 'A rajz akkor is látszik, ha valami (fal, autó) eltakarná.', effect = 'a pályán látható rajz', keywords = 'depth' },
  { key = 'showBands', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Zónasávok', desc = 'A zóna sávját (100% és 0% távolság) halvány vonalakkal mutatja.', effect = 'a pályán látható rajz', keywords = 'sáv' },
  { key = 'showCarPoint', store = 'ui', group = 'display', kind = 'bool', impact = 'display',
    label = 'Autópont mutatása a szerkesztőben', desc = 'Megmutatja, az autó melyik pontjából kerül le az „Pont az autóhoz” pont.', effect = 'a pályán látható rajz', keywords = 'szerkesztő' },
}

schema.byKey = {}
schema.byGroup = {}
for _, g in ipairs(schema.groups) do schema.byGroup[g.id] = {} end
for i, it in ipairs(schema.items) do
  it.store = it.store or 'scoring'
  it.order = i
  schema.byKey[it.key] = it
  local list = schema.byGroup[it.group]
  list[#list + 1] = it
end
schema.groupById = {}
for _, g in ipairs(schema.groups) do schema.groupById[g.id] = g end

-- Text normalisation for searching: lower case, Hungarian accents removed.
local fold = {
  ['á'] = 'a', ['é'] = 'e', ['í'] = 'i', ['ó'] = 'o', ['ö'] = 'o', ['ő'] = 'o', ['ú'] = 'u', ['ü'] = 'u', ['ű'] = 'u',
  ['Á'] = 'a', ['É'] = 'e', ['Í'] = 'i', ['Ó'] = 'o', ['Ö'] = 'o', ['Ő'] = 'o', ['Ú'] = 'u', ['Ü'] = 'u', ['Ű'] = 'u',
}
function schema.norm(s)
  s = tostring(s or '')
  s = s:gsub('[\195\197][\128-\191]', function(c) return fold[c] or c end)
  return s:lower()
end

-- True if every word of the query is found in the text (both normalised).
function schema.textMatches(text, query)
  local q = schema.norm(query)
  if q:match('^%s*$') then return true end
  local hay = schema.norm(text)
  for w in q:gmatch('%S+') do
    if not hay:find(w, 1, true) then return false end
  end
  return true
end

function schema.haystack(it)
  if not it._hay then
    local g = schema.groupById[it.group]
    local opts = ''
    for _, o in ipairs(it.options or {}) do opts = opts .. ' ' .. o[2] end
    it._hay = table.concat({ it.label, it.desc, it.effect, g and g.title or '', it.keywords or '', it.key, opts }, ' ')
  end
  return it._hay
end

function schema.matches(it, query) return schema.textMatches(schema.haystack(it), query) end

function schema.default(it)
  if it.store == 'ui' then return schema.uiDefaults[it.key] end
  return config.defaults[it.key]
end

local function storeOf(settings, it)
  if it.store == 'ui' then
    settings.ui = settings.ui or {}
    return settings.ui
  end
  settings.scoring = settings.scoring or {}
  return settings.scoring
end

local function same(a, b)
  if type(a) == 'number' and type(b) == 'number' then return math.abs(a - b) < 1e-6 end
  return a == b
end

function schema.get(settings, it)
  local v = storeOf(settings, it)[it.key]
  local d = schema.default(it)
  if v == nil or type(v) ~= type(d) then return d end
  return v
end

function schema.isChanged(settings, it)
  return not same(schema.get(settings, it), schema.default(it))
end

-- Stores a value (an override equal to the default is removed). Returns old value, new value.
function schema.set(settings, it, v)
  if it.int and type(v) == 'number' then v = math.floor(v + 0.5) end
  local old = schema.get(settings, it)
  local st = storeOf(settings, it)
  if same(v, schema.default(it)) then st[it.key] = nil else st[it.key] = v end
  return old, schema.get(settings, it)
end

function schema.reset(settings, it) return schema.set(settings, it, schema.default(it)) end

function schema.changedList(settings)
  local r = {}
  for _, it in ipairs(schema.items) do
    if schema.isChanged(settings, it) then r[#r + 1] = it end
  end
  return r
end

function schema.resetAll(settings)
  for _, it in ipairs(schema.items) do schema.reset(settings, it) end
end

-- Hidden while its parent switch is off.
function schema.visible(settings, it)
  if not it.parent then return true end
  local p = schema.byKey[it.parent]
  return p == nil or schema.get(settings, p) == true
end

function schema.format(it, v)
  if v == nil then return '–' end
  if it.kind == 'bool' then return v and 'Be' or 'Ki' end
  if it.kind == 'combo' then
    for _, o in ipairs(it.options or {}) do if o[1] == v then return o[2] end end
    return tostring(v)
  end
  if type(v) == 'number' then
    local s = string.format(it.fmt or '%.2f', v)
    return (s:gsub('(%d)%.(%d)', '%1,%2'))
  end
  return tostring(v)
end

-- "Célszög: 75° → 65°. Mit változtat: …" – shown after a change.
function schema.changeMessage(it, old, new)
  return string.format('%s: %s → %s. Mit változtat: %s.', it.label, schema.format(it, old), schema.format(it, new), it.effect)
end

-- Every scoring key in config.defaults must be described here (checked by the offline tests).
function schema.missingKeys()
  local r = {}
  for k in pairs(config.defaults) do
    if not schema.byKey[k] then r[#r + 1] = k end
  end
  table.sort(r)
  return r
end

return schema
