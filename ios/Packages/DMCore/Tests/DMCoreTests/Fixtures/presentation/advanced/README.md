What the dashboard's Advanced page computes and shows, recorded so
`Sources/DMCore/Presentation/Advanced` can be held to it. Nothing here is written by hand.

The same block of `public/index.html` as for `../energy` ran unchanged in Node behind a fake page
(locale en-US). Its canvas records `fillText` and `fillRect`, so the chart is read back from what
`drawAdvChart` actually drew.

## bounds.json

`advBounds()` under 22 time zones, at instants spread around every clock change of 2026 and 2027
(to the millisecond, a minute, half an hour, an hour, a day, a week, a month either side) plus
ordinary and random moments: 2208 instants, each with the bounds for 24 h, 7 d and 30 d. A list of
bounds is `[first edge, [gap in minutes, how many times], …]`. `transitions` are the clock changes
Node saw, `[instant, offset before, offset after]` in minutes; the tests skip a zone where the
machine's own time zone data disagrees, since that would compare tzdata releases, not code.
(America/Havana was dropped for that reason: Node's tzdata 2026e and macOS differ on it.)

About a fifth of the 24 h lists contain two equal edges: the dashboard steps through wall-clock
hours, and the hour a clock change skips becomes an empty bucket. The hub answers 400 to such a
list, so the dashboard's 24 h view stays empty for a day after clocks go forward. The Swift port
reproduces the list (`AdvancedRange.bounds`) and offers `requestBounds` without the repeat.

## render.json

60 scenarios: the hub payloads captured under `../../models` (`devices.json`,
`devices-after-restart.json`, the three `energy-*.json`), and generated fleets and summaries shaped
like `usageSummary`'s for what the capture does not reach (eleven devices, months, other zones and
currencies, clock changes inside the range, first data minutes or days ago, no energy, loading).
`deviceSets` and `energySets` hold the shared inputs; a scenario names one or carries its own.

Each scenario's `out` is what the page showed: the four tiles, the price line, the chart title and
legend, both tables cell by cell (with the hover titles), and for the chart, at several canvas
widths, the y labels, which buckets got an x label and what it says, and every bar segment's
colour and height. `tips` has the tooltip of every bucket; `hover` (three scenarios) the bucket the
pointer handler picks for x positions on and around every bucket edge.

Dates are where Node and Apple differ, in data rather than in code: Node joins a date and a time
with a comma where Apple writes "at" ("Nov 18 at 12:31 PM"), and orders weekday and day the other
way round ("20 Fri" / "Fri 20"). The tests compare those texts with " at " read as ", " and, for
the week range's short labels, as the same words in any order. As for the other formatters, U+202F
and U+00A0 count as a space.
