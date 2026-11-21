What the real dashboard shows, recorded. Nothing here is written by hand.

## How it was recorded

`public/index.html` was loaded into jsdom with its inline script unchanged, apart from one appended
line that hands the script's own functions and state to the recording harness. What a browser
provides was stubbed: `session.js` (`hubFetch` answering from a table, `HubEvents` taking events
from the harness), a canvas context that writes down every call, element sizes, `Date.now`, timers,
`prompt` and `confirm`. Locale en-US, time zone America/Los_Angeles.

Devices were fed in as a `snapshot` event, so they went through the dashboard's own `connect()`,
`renderGrid()` and `updateCard()`. The recorded texts are the page's text content; positions are
the arguments the page passed to `moveTo`, `lineTo`, `arc` and `fillText`, rounded to a thousandth
of a pixel.

Every report in the inputs was passed through the hub's `normalizeReport` (security.js), so the
inputs are shapes a hub can send. They are: the captured fleet of `../../models/devices.json`,
online and switched off; rows that walk through pools of edge values (names, rounding halves, unit
steps, missing parts); device records as an old registry may hold them; and a seeded random fleet.

History points are stored as `{ "keys": [...], "rows": [[...]] }`: one list of keys and one row of
values per point.

## Files

| File | Recorded from | What |
|---|---|---|
| `cards.json` | `updateCard`, `detailHtml` | per device, in °C (`runC`) and °F with published versions (`runF`): title, status line, gauges with the stroke length of the arc and the caption under each, stats with bar width and colour, and the sections under Details |
| `grid.json` | `renderGrid`, `renderOffline`, the stream's error handler | per set of devices: summary texts, empty state, ids of the cards in order, offline rows, and the summary while reconnecting; `accented` holds orderings of names that are not plain ASCII, the last two of names apart only in width or kana type, the same names arriving in two orders |
| `collation.json` | `String.prototype.localeCompare` | pairs of names with the sign of `a.localeCompare(b)` in en-US: host-like names, punctuation, accented Latin, other scripts, and (`forms`) names apart only in width, kana type, kana size or a compatibility form; `names` and `orders`: one list of names and the place `localeCompare` gives each of them in 32 locales; `limits`: see below |
| `menu.json` | `openMenu`, the offline list's click handler, `versionLabel`, `platformKey`, `zeroed` | menu items, the labels of a card's controls, and per device the rename prompt, the remove confirmation and the requests a confirmed rename and remove send; `wake`: the Wake button before, while and after sending, for a wake that was sent, refused and unreachable; `versions`: version labels for platforms and versions against published ones; `zeroed`: reports and what `zeroed()` makes of them |
| `rename.json` | `cleanText(name, 60)` in security.js | names as UTF-16 code units and what the hub keeps of each (`null`: nothing, the old name stays) |
| `card-chart.json` | `drawChart` | range options, how stored ranges resolve, and per series: axis labels and lines, each line's runs of points, and for a set of pointer positions the tooltip, the marker and the dots |

The dashboard runs with `unit` C or F from `localStorage`, as a user's setting would be. `hover` in
`card-chart.json` is the pointer position as a fraction of the canvas width, as the page's
`mousemove` handler computes it.

## Name order in other languages

`orders` in `collation.json` gives each of `names` a place per locale. `localeCompare` orders any
list one way, so the places say what every pair would: a lower place is a name that sorts first,
the same place two names it calls equal. The generator checks every pair against its places.

`limits` holds pairs `[locale, a, b, sign]` picked because the app is known to order them
differently from a browser (`DashboardOrder.compareNames` says why). What is recorded is still the
browser's sign; NameCollationTests checks that the app's answer is another one, and that the app
differs from `orders` on these pairs only. Thai is the exception: a browser set to Thai ignores
punctuation and spaces, so there the tests compare only the names made of letters and digits.

All of it was recorded with Node, which compares names with V8 and ICU as Chrome does. Safari's
engine (JavaScriptCore on macOS 27.2) gives the same answer for every row of this file, except in
Danish: it puts lower case first there, Chrome upper case, and 18 pairs of `names` change sides.
