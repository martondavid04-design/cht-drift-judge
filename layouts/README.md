# Pályatervek a szerverhez

Ide kerülnek azok a pályatervek, amelyeket a szerverről kapott (online) program letölt.

```
layouts/<pálya kulcsa>/<név>.json      – a pályaterv (a telepített app Pálya fülén „Másolás”)
layouts/<pálya kulcsa>/index.json      – opcionális: a nevek listája, pl. ["Alap", "Verseny"]
```

A pálya kulcsa a pálya mappaneve, layoutos pályánál `pálya__layout`
(pl. `trackwood_pro_reverse_2026`). Melyik terv töltődjön be: a szerver `[SCRIPT_1]` szakaszában a
`layout` kulcs; ha üres, az `index.json` első neve, ha az sincs, „Alap”.
