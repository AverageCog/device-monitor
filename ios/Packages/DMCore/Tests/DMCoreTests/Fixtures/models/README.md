Payloads of a real hub and outputs of the real dashboard code. Nothing here is written by hand.

## Hub payloads

Captured from this repository's `server.js`, started with `startHub({ fixture: true, port: 0,
publicUrl: 'https://hub.test' })` in the time zone America/Los_Angeles. Reports were fed through
`seedReport`, minute history was pre-seeded as `data/history/<id>.ndjson`, and the clock was virtual
(Node's mock timers), so five minutes of alerts took seconds. Requests from 127.0.0.1 with the hub's
local key act as `root`; a desktop paired through the `hub.test` proxy headers gave the `client`
role a paired app has.

The fleet: a Windows desktop with one GPU, sensors, fans and measured CPU power; a Linux
workstation with five GPUs and loaded AI models; a Mac laptop; a NAS that reports almost nothing;
a renamed Windows PC with an estimated GPU and a full disk; an HTPC that reported once and went
offline; and a box that was removed.

| File | What |
|---|---|
| `info.json` | `GET /api/info` as `root`, `client`, `browser` and without a credential (`locked`) |
| `devices.json` | `GET /api/devices`, five devices online and one offline |
| `devices-after-restart.json` | the same after a hub restart: no latest report, no samples |
| `device-patch.json` | answer to `PATCH /api/devices/<id>` (rename) |
| `history-raw.json` | raw two-second samples only |
| `history-10m.json` | `range=10m`: stored minute points (with `n` and peaks) followed by raw samples |
| `history-24h.json` | `range=24h&points=24`: one-hour buckets, three hours missing while the device was off |
| `history-6h-no-gpu.json` | `range=6h&points=12`: buckets full of nulls |
| `energy-7d-no-price.json` | `GET /api/energy` over seven local days, no price saved |
| `energy-7d-flat.json` | the same with a flat rate |
| `energy-24h-tou.json` | 24 hourly buckets with time-of-use rates |
| `energy-settings.json` | `GET` before saving (null), answers to the flat and time-of-use `PUT`, `GET` after |
| `alerts-default.json` | `GET /api/alerts` with the hub's default rules |
| `alerts-put.json` | answer to `PUT /api/alerts` |
| `alerts.json` | `GET /api/alerts` after alerts fired and resolved: CPU load, power, offline, disk, daily cost |
| `alerts-after-clear.json` | the same after `DELETE /api/alerts/log` |
| `alerts-test.json` | answer to `POST /api/alerts/test` (a fixture hub delivers nowhere, hence `{}`) |
| `alerts-test-delivery.json` | what `post()` in alerts.js returns per channel when delivery is tried |
| `remote.json` | `GET /api/remote` (no Tailscale on a fixture hub) |
| `update.json` | `GET /api/update/windows` before and after a signed manifest was published; `mac` stays 404 |
| `invite-browser.json` | answer to `POST /api/invites` for `kind: browser`, asked by a paired desktop |
| `sse-frames.json` | payloads of `GET /api/stream` frames, each the text after `data: `; every event type the hub emits, with repeats of `report` and `status` thinned out |
| `requests.json` | request bodies with the status and answer the hub gave: the accepted ones are the shapes the Swift encoders must produce, the refused ones show its error bodies |

Two values were replaced after capture: the hub PC's hostname in `info.json` (now `hub-pc`) and the
invitation code (now a placeholder of the same shape). The update manifest is signed with a
throwaway key.

## formatting-vectors.json

Inputs and outputs of the formatters in `public/index.html`. A script cut each function's source
text out of that file, ran it in Node (locale en-US; the time rows in three time zones) and
recorded what it returned, so every expected value is JavaScript's own.

Node writes a plain space before AM/PM and Apple's ICU a narrow no-break space; the tests compare
the rows whose text comes from ICU with those spaces folded. Everything else is compared character
for character.

## formatting-locales.json

The same for the clock, money and energy formatters in eight other locales (de-DE, en-GB, fr-FR,
es-ES, sv-SE, pt-BR, nl-NL, pl-PL), to hold the `locale:` parameter to what a browser in that locale
shows.

Weekday and date patterns are left out on purpose. Apple ships its own locale data, and for some
locales it differs from Node's: German writes "Fr. 20. Nov." where Node has "Fr., 20. Nov.",
Japanese puts the weekday first and uses the half-width yen sign, Indian English has "PM" for "pm",
Chinese and Arabic differ in spacing and weekday form. Those are differences in data, not in the
port, and the app shows what iOS shows everywhere else.
