What the real history page shows, recorded the same way as `../dashboard` (see its README): the
dashboard's own script in jsdom, en-US, America/Los_Angeles, with a canvas that writes down what is
drawn on it.

The page was opened with `openHistory`, its window set, and `loadHistory` answered with the points
of the case; hovering sets `hv.hoverT` and redraws; zooming dispatches the pointer events on a
chart's canvas. Points are captured hub answers (`../../models/history-*.json`) and constructed
ones: raw samples, minute and wider averages with peaks, gaps, nulls, single points, points out of
order, single series, values around the steps of the axis scale.

| File | Recorded from | What |
|---|---|---|
| `pages.json` | `renderTiles`, `buildHvCharts`, `drawHvChart` | per window of points: tiles; the empty text; time labels and grid lines (the same on every chart); per chart its title, legend, value labels, line runs and peak-band polygons by series colour; and for a set of pointer times the tooltip, marker and dots on each chart (`charts: null` when nothing was drawn) |
| `ticks.json` | `drawHvChart`, `timeLabel` | time labels for windows from a minute to thirty days, across both daylight-saving changes, on charts 58 to 2400 wide |
| `windows.json` | `setHvWindow`, `attachHvEvents`, `loadHistory` | the window each stored range opens with; a session of drags, double-clicks, range buttons, the reset button and the 30-second timer, with the window before and after each step and the request it caused; the `points` parameter by column width |
| `headers.json` | `renderHvDevices`, the History button | device chips, title and subtitle for several fleets and selections; which device the History button opens |

In `windows.json` a drag step carries the two pointer positions (`x1`, `x2`) and the times `hvT`
gave for them (`a`, `b`).
