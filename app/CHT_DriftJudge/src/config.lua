-- CHT Drift Judge – scoring configuration (defaults). Pure Lua.
-- Every value here can be changed in the app's Settings tab; changes are stored in settings.json.

local config = {}

config.defaults = {
  -- Zone max points are weights: the zones of a layout are scaled so the total is always 100.
  normalizeTotal = true,

  -- Point split of a run (Drift Masters 2025, 1.6–1.7): Line 60, Angle 20, Style 20.
  -- The zones give (1 - styleWeight) × 100 = 80 points; inside a zone: lineWeight × Line + angleWeight × Angle
  -- (0.75 / 0.25 of the 80 = 60 / 20). The style gives styleWeight × 100 = 20 points.
  lineWeight = 0.75,
  angleWeight = 0.25,

  -- 'strict': angle only earns points on the part of a zone where the car is inside the zone
  --           (uncovered length counts as 0 angle) – "no good angle without good line".
  -- 'covered': angle is averaged only over the covered part of the zone.
  angleGating = 'strict',

  -- Angle scoring (per zone defaults, a zone can override angleTarget / angleMin)
  angleTarget = 72,      -- degrees: full angle score at or above this (CHT, 2026-11-14)
  angleMin = 13,         -- degrees: zero angle score at or below this (CHT, 2026-11-14)
  overAngle = 90,        -- degrees: over-rotation ("túldobás") flag
  spinAngle = 95,        -- degrees: above this for spinTime => spin ("beforgás") (CHT, 2026-11-14)
  spinTime = 0.25,       -- seconds
  stallSpeed = 8,        -- km/h: below this for stallTime inside judging => spin / stall
  stallTime = 0.6,       -- seconds

  -- Line only counts while the car is drifting (driving along a line without angle earns nothing)
  lineNeedsDrift = true,

  -- Drift state
  driftMinAngle = 12,    -- degrees: below this the car is "straight"
  minSpeed = 15,         -- km/h: angle is ignored below this (noise at low speed)
  straightTime = 0.6,    -- seconds below driftMinAngle inside judging => "kiegyenesedés" info

  -- Off-track. Sources (any of them can mark a wheel as off):
  offTrackAC = true,       -- AC's own track limits (car.wheelsOutside) – some drift tracks never report anything
  offTrackSurface = true,  -- wheel on grass / dirt / gravel / sand
  offTrackLimits = true,   -- "Pályahatár" lines drawn in the editor: a wheel beyond the line is off
  offTrackZones = true,    -- zone lines are track limits too (no extra drawing needed):
  limitOZ = true,          --   beyond the outer line of an OZ
  limitIZ = true,          --   beyond the inner line of an IZ (cutting inside)
  limitTNG = false,        --   beyond the touch and go line (off by default: TnG lines are often painted inside the track)
  zoneLimitTolerance = 0.15, -- m: wheel centre this far beyond the line counts as off (≈ whole tyre over)
  offTrackMinTime = 0.05,  -- seconds: shorter flickers are ignored
  offTrackEndHold = 0.20,  -- seconds all wheels back inside before an event ends
  oneWheelPenalty = 1,     -- points removed from the total per one-wheel off-track
  oneWheelZeroAt = 3,      -- this many one-wheel off-tracks => zero run
  twoWheelZero = true,     -- a single two-wheel off-track => zero run

  -- Corrections ("legyezés"): flagged; penalty optional
  correctionPenalty = 0,
  wallSavePenalty = 0,     -- "Fal utáni mentés" is its own fault category (flag only by default)
  dipDegrees = 12,         -- angle drop within dipTime that counts as a correction ...
  dipTime = 0.4,
  dipRecover = 5,          -- ... if the angle then recovers by at least this much (same direction)
  fanAmplitude = 0.05,     -- steering reversal size, fraction of full steering lock
  fanReversals = 3,        -- this many steering reversals ...
  fanWindow = 1.0,         -- ... within this many seconds (same drift direction) => correction
  correctionCooldown = 0.7,
  wallSaveWindow = 1.2,    -- correction within this time after a wall contact => "fal utáni mentés"

  -- Over-rotation penalty (default: flag only, judges decide)
  overRotationPenalty = 0,
  spinZero = true,

  -- Zone geometry defaults (meters)
  binSize = 0.25,
  ozFullDist = 0.5,  ozZeroDist = 3.0,    -- outer zone: rear bumper distance to the outer line
  izFullDist = 0.5,  izZeroDist = 3.0,    -- inner zone: front bumper distance to the inner line
  wallFullDist = 0.04, wallZeroDist = 2.0, -- wall zone: like a normal zone, max points only within 4 cm of the wall
  contactCountsAsLine = true, -- rear touching the wall/line inside an OZ/WALL zone counts as 0 cm
  tngTier1 = 0.3, tngTier2 = 0.8, tngTier3 = 1.5, -- touch and go: front wheel distance tiers
  tngMode = 'step',  -- 'step' (100/66/33/0) or 'linear'
  icFullDist = 0.5, icZeroDist = 2.5,    -- IC (inner clipping point): front bumper distance to the point
  captureMargin = 4.0,  -- extra distance beyond zeroDist where a zone still tracks the car
  -- automatic zone weights (layouts with weighting = 'auto'): weight = typeFactor × max(length, minLength)^lengthExp
  --   × (1 + curveFactor × turn / 90°)
  autoLengthExp = 0.5,
  autoMinLength = 4.0,
  autoCurveFactor = 0.25,
  autoTypeOZ = 1.0,
  autoTypeIZ = 1.0,
  autoTypeWALL = 1.0,
  autoTypeTNG = 1.8,
  autoTypeIC = 1.0,

  -- Run handling
  maxRunTime = 240,      -- seconds; longer runs are aborted
  resetZero = true,      -- car reset / teleport while judging => zero run (off: the run is aborted, no result)

  -- Style ("Stílus", measurable proxies of the DM style criteria). 0 = information only.
  styleWeight = 0.20,        -- share of the 100 points (DM: 20)
  styleInitPts = 5,          -- Initiation ("Indítás") – relative weight inside the style (DM: 5)
  styleFlowPts = 10,         -- Fluidity ("Folyamatosság") (DM: 10)
  styleCommitPts = 5,        -- Commitment ("Elkötelezettség") (DM: 5)
  -- Initiation: early (distance after the JUDGING line), rate to angle, smooth entry (no angle lost)
  styleInitLate = 15,        -- m after the JUDGING line: the drift starting this late or later = 0% "early"
  styleRateGood = 0.6,       -- s from the start of the drift to 80% of the target angle: 100%
  styleRateBad = 2.0,        -- s: 0%
  styleEntryDropBad = 15,    -- °: angle lost and built up again during the entry (first 1.5 s) that gives 0% (3° or less = 100%)
  -- Fluidity: rotation (transition time), lock to lock (angle before and after a transition), flow (wobble)
  styleTransGood = 0.5,      -- s: transition (direction change) this fast or faster = 100%
  styleTransBad = 1.6,       -- s: this slow or slower = 0%
  styleSmoothBad = 12,       -- °: average angle wobble around its smoothed value that gives 0% smoothness
  -- Commitment: throttle (no lifting while drifting) and pace (no bogging down; the layout's minimum tempo)
  styleLiftGood = 0.03,      -- share of the drifting distance with the throttle below 30%: 100% at or below this
  styleLiftBad = 0.20,       -- ... 0% at or above this
  stylePaceLow = 0.55,       -- slowest 10% of the run's speed / median speed: 0%
  stylePaceHigh = 0.90,      -- ... 100%
  tempoPenalty = 0,          -- points removed when the run is below the layout's minimum tempo (0 = flag only)
}

local function copy(t)
  local r = {}
  for k, v in pairs(t) do r[k] = v end
  return r
end

-- Returns defaults overridden by `overrides` (only known keys with matching types are taken).
function config.merge(overrides)
  local r = copy(config.defaults)
  if type(overrides) == 'table' then
    for k, v in pairs(overrides) do
      if config.defaults[k] ~= nil and type(v) == type(config.defaults[k]) then r[k] = v end
    end
  end
  return r
end

-- Human-readable descriptions (Hungarian) used by the Settings tab.
config.labels = {
  lineWeight = 'Line súlya a zónapontban',
  angleWeight = 'Angle súlya a zónapontban',
  angleTarget = 'Célszög (100% e fölött), °',
  angleMin = 'Minimális szög (0% e alatt), °',
  overAngle = 'Túldobás határa, °',
  spinAngle = 'Beforgás határa, °',
  spinTime = 'Beforgás: ennyi ideig a határ fölött, mp',
  stallSpeed = 'Megállás: sebesség e alatt, km/h',
  stallTime = 'Megállás: ennyi ideig, mp',
  driftMinAngle = 'Egyenes: szög e alatt, °',
  minSpeed = 'Szögmérés minimális sebessége, km/h',
  straightTime = 'Kiegyenesedés: ennyi ideig egyenesen, mp',
  offTrackMinTime = 'Pályaelhagyás: legrövidebb számított idő, mp',
  offTrackEndHold = 'Pályaelhagyás vége: ennyi ideig mind bent, mp',
  zoneLimitTolerance = 'Zónavonalon túl: kerékközép ennyivel kint, m',
  oneWheelPenalty = 'Egykerekes pályaelhagyás levonása, pont',
  oneWheelZeroAt = 'Ennyi egykerekes = nullás kör',
  correctionPenalty = 'Korrekció levonása, pont',
  wallSavePenalty = 'Fal utáni mentés levonása, pont',
  dipDegrees = 'Korrekció: szögesés, °',
  dipTime = 'Korrekció: szögesés ideje, mp',
  dipRecover = 'Korrekció: visszanövés, °',
  fanAmplitude = 'Legyezés: kormánymozdulat (a teljes kormányzár része)',
  fanReversals = 'Legyezés: ennyi kormányirány-váltás',
  fanWindow = 'Legyezés: ennyi mp alatt',
  correctionCooldown = 'Két korrekció közti minimum, mp',
  wallSaveWindow = 'Fal utáni mentés ablaka, mp',
  overRotationPenalty = 'Túldobás levonása, pont',
  binSize = 'Zóna felbontás, m',
  ozFullDist = 'OZ: 100% távolság, m', ozZeroDist = 'OZ: 0% távolság, m',
  izFullDist = 'IZ: 100% távolság, m', izZeroDist = 'IZ: 0% távolság, m',
  wallFullDist = 'Falas zóna: 100% távolság, m', wallZeroDist = 'Falas zóna: 0% távolság, m',
  tngTier1 = 'Touch and go: 1. vonal, m', tngTier2 = 'Touch and go: 2. vonal, m', tngTier3 = 'Touch and go: 3. vonal, m',
  icFullDist = 'IC pont: 100% távolság, m', icZeroDist = 'IC pont: 0% távolság, m',
  captureMargin = 'Zóna követési ráhagyás, m',
  maxRunTime = 'Futás maximális hossza, mp',
  styleWeight = 'Stílus súlya az összpontban (0 = csak információ)',
  styleTransGood = 'Irányváltás: 100% ennyi mp alatt',
  styleTransBad = 'Irányváltás: 0% ennyi mp felett',
  styleSmoothBad = 'Egyenletesség: 0% ennyi fok ingadozásnál',
}

-- Order in which numeric settings are shown, grouped.
config.groups = {
  { title = 'Pontozási arány', keys = { 'lineWeight', 'angleWeight' } },
  { title = 'Szög', keys = { 'angleTarget', 'angleMin', 'overAngle', 'overRotationPenalty', 'spinAngle', 'spinTime', 'stallSpeed', 'stallTime', 'driftMinAngle', 'minSpeed', 'straightTime' } },
  { title = 'Pályaelhagyás', keys = { 'zoneLimitTolerance', 'offTrackMinTime', 'offTrackEndHold', 'oneWheelPenalty', 'oneWheelZeroAt' } },
  { title = 'Korrekció (legyezés) és fal utáni mentés', keys = { 'correctionPenalty', 'wallSavePenalty', 'dipDegrees', 'dipTime', 'dipRecover', 'fanAmplitude', 'fanReversals', 'fanWindow', 'correctionCooldown', 'wallSaveWindow' } },
  { title = 'Zónák', keys = { 'ozFullDist', 'ozZeroDist', 'izFullDist', 'izZeroDist', 'wallFullDist', 'wallZeroDist', 'tngTier1', 'tngTier2', 'tngTier3', 'icFullDist', 'icZeroDist', 'binSize', 'captureMargin' } },
  { title = 'Stílus (mérhető)', keys = { 'styleWeight', 'styleInitPts', 'styleFlowPts', 'styleCommitPts', 'styleInitLate', 'styleRateGood', 'styleRateBad', 'styleEntryDropBad', 'styleTransGood', 'styleTransBad', 'styleSmoothBad', 'styleLiftGood', 'styleLiftBad', 'stylePaceLow', 'stylePaceHigh' } },
  { title = 'Futás', keys = { 'maxRunTime' } },
}

-- Slider ranges for settings UI: { min, max, format }
config.ranges = {
  lineWeight = { 0, 1, '%.2f' }, angleWeight = { 0, 1, '%.2f' },
  angleTarget = { 20, 95, '%.0f°' }, angleMin = { 0, 60, '%.0f°' }, overAngle = { 60, 130, '%.0f°' },
  spinAngle = { 90, 175, '%.0f°' }, spinTime = { 0, 2, '%.2f s' }, stallSpeed = { 0, 40, '%.0f km/h' },
  stallTime = { 0, 3, '%.1f s' }, driftMinAngle = { 2, 30, '%.0f°' }, minSpeed = { 0, 60, '%.0f km/h' },
  straightTime = { 0, 3, '%.1f s' },
  offTrackMinTime = { 0, 0.5, '%.2f s' }, zoneLimitTolerance = { 0, 1, '%.2f m' }, offTrackEndHold = { 0, 1, '%.2f s' },
  oneWheelPenalty = { 0, 10, '%.1f' }, oneWheelZeroAt = { 1, 10, '%.0f' },
  correctionPenalty = { 0, 10, '%.1f' }, wallSavePenalty = { 0, 10, '%.1f' }, dipDegrees = { 3, 40, '%.0f°' }, dipTime = { 0.1, 2, '%.2f s' },
  dipRecover = { 0, 20, '%.0f°' }, fanAmplitude = { 0.01, 0.3, '%.2f' }, fanReversals = { 2, 8, '%.0f' },
  fanWindow = { 0.3, 3, '%.1f s' }, correctionCooldown = { 0, 3, '%.1f s' }, wallSaveWindow = { 0, 3, '%.1f s' },
  overRotationPenalty = { 0, 10, '%.1f' },
  binSize = { 0.1, 1, '%.2f m' },
  ozFullDist = { 0, 3, '%.2f m' }, ozZeroDist = { 0.5, 8, '%.2f m' },
  izFullDist = { 0, 3, '%.2f m' }, izZeroDist = { 0.5, 8, '%.2f m' },
  wallFullDist = { 0, 1, '%.2f m' }, wallZeroDist = { 0.5, 8, '%.2f m' },
  tngTier1 = { 0, 3, '%.2f m' }, tngTier2 = { 0, 4, '%.2f m' }, tngTier3 = { 0, 6, '%.2f m' },
  icFullDist = { 0, 3, '%.2f m' }, icZeroDist = { 0.3, 8, '%.2f m' },
  captureMargin = { 0, 15, '%.1f m' },
  maxRunTime = { 30, 600, '%.0f s' },
  styleWeight = { 0, 0.5, '%.2f' }, styleTransGood = { 0.1, 2, '%.2f s' }, styleTransBad = { 0.5, 4, '%.2f s' },
  styleSmoothBad = { 2, 40, '%.0f°' },
}

config.integerKeys = { oneWheelZeroAt = true, fanReversals = true }

return config
