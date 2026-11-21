What the dashboard's electricity price code produces, recorded so the Swift ports in
`Sources/DMCore/Presentation/Energy` can be held to it. Nothing here is written by hand.

A script cut the block of `public/index.html` between the comments `// ---------- electricity
price ----------` and `// ---------- unit toggle ----------` out of the page and ran it, unchanged,
in Node behind a small fake page: elements that remember what is written to them, a parser for the
rows `renderTou` writes, and a `hubFetch` whose `PUT /api/energy/settings` is answered by
`validEnergySettings` cut out of `server.js`. Locale en-US; the time zone and `navigator.language`
are those named in each row.

| File | What |
|---|---|
| `regions.json` | `PRICE_REGIONS` and `TZ_REGIONS` entry for entry (rates also as IEEE-754 bits), the region picker's groups and the currency list as `renderPriceRow` builds them, `regionName`, and `guessRegion` for every listed zone, the prefix zones and a spread of languages |
| `price-texts.json` | `priceSettings`, `fmtPrice`, `priceSource`, the Settings hint and `dayRate` (bits) for nothing saved in 25 places, every listed region at its table rate, 56 other flat prices and 14 time-of-use ones; `direct` holds the same functions called on price objects, 150 of them with generated periods |
| `hours.json` | the options of the two hour pickers and the editor's fixed wording, read from the markup |
| `numbers.json` | `parseFloat` over what people type into a rate field |
| `hub-stored.json` | bodies and what `validEnergySettings` makes of them (null: refused) |
| `editor.json` | the editor driven action by action: 25 scripted scenarios and 30 seeded random walks. Each step has the action, the body the dashboard PUT (if any), the hub's answer (`"same"`, a rounded/sorted version, or null when it refused or nothing was sent), the saved price afterwards and what the controls then show (hint, mode, pickers, rate field, period rows with their "bad" marks, the remembered periods) |

`focus` in an editor step says where the keyboard focus was while the page re-rendered: the
dashboard does not refill a field the user is still in.

Money is compared with U+00A0 and U+202F folded to a space (Node writes "XTS 0.25" with a no-break
space, Apple's ICU sometimes with a plain one); everything else character for character.
