What the hub's `alerts.js` answers, recorded so `Sources/DMCore/Presentation/Alerts` can be held to
it. Nothing here is written by hand.

A script required `alerts.js` as it is and drove real `Alerts` instances with stub callbacks
(devices, cost, broadcast) and Node's mock clock, in the time zone America/Los_Angeles.

| File | What |
|---|---|
| `types.json` | `TYPES`, the rules and settings a fresh hub starts with, and how many rules it keeps |
| `urls.json` | `httpUrl`, seen through the ntfy server field: some 370 addresses and what the hub stores for each (null: refused). Ports, odd slashes, credentials, percent-encoding, international names, every spelling of an IPv4 address, IPv6, and the hosts the hub will not post to |
| `validation.json` | `PUT /api/alerts` bodies and the hub's answers. `ruleRows` are the base settings with one rule that has one field off (`field` names it; null when nothing is wrong); `channelRows` the base rule with other channels, asked of a hub that does or does not already hold a webhook URL (`prevWebhook`); `rows` are whole bodies (many rules) |
| `values.json` | `fmt()` and `temp()`: `[unit, type, value, currency, text]` |
| `texts.json` | `text()` for every kind of rule, firing and resolved, in both units, with `fmt()` of the rule's limit |
| `events.json` | four runs (notify-when-resolved × app channel) of the same story: alerts fire, hold, clear. Per step, the `alert` broadcasts with the hub's `notify` verdict and the list of firing alerts; `log` is the final event log, newest first. `clears` walks a firing alert's reading down to find where `evaluate()` lets go: `[type, limit, reading, 1 if it cleared]` |

Things the fixtures show about the hub that the Swift port follows on purpose:

- It tests `/^fe[89ab]/` (IPv6 link-local) against whatever the host is, so names like
  `feature.example.com` are refused as alert destinations.
- It takes a leading `::ffff:` off an IPv6 address as `URL` writes it. Two groups after it are an
  IPv4 address (`::ffff:7f00:1` is 127.0.0.1, and `::ffff:fe80:1` is the harmless 254.128.0.1);
  anything else gets the test above without the prefix, so `::ffff:fe80:1:2` and `::ffff:fe80`
  are refused while `::ffff:1:2:3` is not.
- It cuts a topic at 64 and an email address at 120 UTF-16 units, through a surrogate pair if that
  is where the cut falls, and judges and stores what is left: 63 letters and an emoji are no
  topic, and an address can end in half an emoji. `JSON.stringify` writes that half as an escape
  (`\ud83d`), which the tests read as the app does, as U+FFFD (`HubClient.wellFormedJSON`).
- A rule type it does not know makes it refuse the whole PUT. The app's validation leaves such a
  rule alone instead (a newer hub may have sent it); `ruleRows` with `field: "type"` pin that
  difference down.
