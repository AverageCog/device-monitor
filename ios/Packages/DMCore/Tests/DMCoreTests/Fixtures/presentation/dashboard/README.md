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
| `grid.json` | `renderGrid`, `renderOffline`, the stream's error handler | per set of devices: summary texts, empty state, ids of the cards in order, offline rows, and the summary while reconnecting; `accented` holds orderings of names that are not plain ASCII |
| `collation.json` | `String.prototype.localeCompare` | pairs of names with the sign of `a.localeCompare(b)` in en-US: host-like names, punctuation, accented Latin, other scripts |
| `menu.json` | `openMenu`, the offline list's click handler, `versionLabel`, `platformKey`, `zeroed` | menu items, the labels of a card's controls, and per device the rename prompt, the remove confirmation and the requests a confirmed rename and remove send; `wake`: the Wake button before, while and after sending, for a wake that was sent, refused and unreachable; `versions`: version labels for platforms and versions against published ones; `zeroed`: reports and what `zeroed()` makes of them |
| `rename.json` | `cleanText(name, 60)` in security.js | names as UTF-16 code units and what the hub keeps of each (`null`: nothing, the old name stays) |
| `card-chart.json` | `drawChart` | range options, how stored ranges resolve, and per series: axis labels and lines, each line's runs of points, and for a set of pointer positions the tooltip, the marker and the dots |

The dashboard runs with `unit` C or F from `localStorage`, as a user's setting would be. `hover` in
`card-chart.json` is the pointer position as a fraction of the canvas width, as the page's
`mousemove` handler computes it.
