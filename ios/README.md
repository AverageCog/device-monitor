# Device Monitor for iOS

A native iPhone and iPad companion for Device Monitor. It pairs with a hub and shows and manages
what the web dashboard does, as a paired desktop sees it (hub role `client`). It never reports the
phone's own stats.

## What it does

Five tabs:

- **Devices.** A card for every device that is online: gauges, temperatures, and a live chart of
  the last ten minutes, hour or six hours (each card has its own range). **Details** shows GPU
  sensors and loaded AI models. A card's **…** menu has History, Rename and Remove from dashboard.
  Drag a card by its grip to reorder; the order is saved on the hub. The summary at the top opens
  the offline devices, where **Wake** sends Wake-on-LAN to a device that has reported a network
  address. **+** opens "Add a device".
- **History.** One device's readings over 1 h to 30 days, as tiles and charts; the device is chosen
  at the top. Hold a chart to read it, drag across it to zoom, double-tap or **Reset zoom** to go
  back.
- **Advanced.** Electricity use and cost per device and in total over 24 hours, 7 days or 30 days:
  what each device draws now, an energy chart, the projected monthly cost, and usage totals.
- **Alerts.** What is firing now and the hub's log. The rules and channels editor (ntfy, webhook,
  the Device Monitor apps), a test alert, and notifications on this device. The hub evaluates the
  rules (`alerts.js`); the web dashboard has no page for them.
- **Settings.** Temperature unit, appearance (System, Light or Dark), the hub this device is paired with and its TLS identity, a
  dashboard link to share with a browser, the electricity price and its editor (under Advanced
  settings), **Disconnect…**, version and license.

On every tab the top bar and the tab bar get out of the way while the page is scrolled down, and
come back as soon as it is scrolled up a little or reaches its top (iOS 26 and later; earlier
versions keep them in place). A page that scrolls only a little keeps them, and so does everything
while VoiceOver or Switch Control is on.

"Add a device" shares a single-use browser link (as text and as a QR code) and says how to add
computers and other phones on the hub.

What it deliberately does not do:

- Report this phone. It holds a dashboard credential and no reporting credential.
- Enroll anything. Computers and phones are added on the hub; the app only says how.
- What only a computer has: Host mode, firewall, start at sign-in, tray, quit, self-update.
- **Revoke browser access** (the hub's) and **Sign out of this tab** (a browser's).
- Process lists, sleep, restart or shut down. No agent implements them and the dashboard has no
  UI for them. Wake-on-LAN is in.
- Push notifications through Apple (APNs). See
  [Notifications and background refresh](#notifications-and-background-refresh).

## Requirements

- macOS with Xcode 26 or later. The app target is built with default main-actor isolation and
  approachable concurrency (see [Concurrency settings](#concurrency-settings)), build settings that
  Xcode 26 introduced. Xcode 16 can open the project (file-system-synchronized groups, project
  format 77) but does not know those settings, and the app does not compile without them.
  Developed with Xcode 27 / Swift 6.4.
- iOS 17.0 or later on the device or simulator.
- No third-party dependencies and no package downloads: the only package is the local `Packages/DMCore`.
- Node and openssl, for the end-to-end tests only.

**The UI tests have never been run.** The Mac this app was built on has macOS 27.2.1 and the
Xcode 27.0 beta (27A5194q). That Xcode cannot start the simulator's test service on that macOS:
`xcodebuild test` stops with "failed to bless service hub" before the first test, also after
Xcode's first-launch setup and a restart. It needs a newer Xcode. So every class in
`DeviceMonitorUITests/` compiles (`build-for-testing`) but none of its tests has been executed,
and neither has `Tools/e2e.sh`, which runs `HubFlowUITests`. What did run there: the app and the
UI tests build for the simulator, all DMCore tests pass (the end-to-end suites too), and the
screens were looked at in a simulator, started in each state through the
[debug launch arguments](#debug-launch-arguments).
Once a working Xcode is installed, run the UI tests on an iPhone and an iPad simulator, then the
end-to-end test (commands under [UI tests](#ui-tests)). Expect some tests to need fixing on that
first run.

## Build and run

Open `ios/DeviceMonitor.xcodeproj`, pick the **DeviceMonitor** scheme and a simulator, and run.

From the command line:

```sh
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath ios/.build/dd build
xcrun simctl install booted ios/.build/dd/Build/Products/Debug-iphonesimulator/DeviceMonitor.app
xcrun simctl launch booted com.devicemonitor.ios -dm-demo
```

`ios/.build` is ignored by git. The launch arguments (`-dm-demo` here) work in Debug builds only;
see [Debug launch arguments](#debug-launch-arguments).

A simulator has no camera: paste the invitation instead of scanning it. It only trusts a hub with
a private CA after `xcrun simctl keychain <udid> add-root-cert <ca.pem>`. It refuses background
refresh.

### Signing

The project carries no development team (`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM` empty), so
it builds for the simulator as is, signed ad hoc. To run on a device, select your team under
*DeviceMonitor target → Signing & Capabilities* (do the same for *DeviceMonitorUITests* to run UI tests
on a device). The bundle identifier is `com.devicemonitor.ios`; if Xcode reports that your team
cannot use it, change `PRODUCT_BUNDLE_IDENTIFIER` of both targets to one of yours. The device needs
Developer Mode on (*Settings → Privacy & Security → Developer Mode*).

The enrollment lives in the Keychain, so build with Xcode's signing step left on, which is the
default. A simulator app built with `CODE_SIGNING_ALLOWED=NO` runs but has no Keychain: it starts
unpaired, shows "The Keychain is unavailable (error -34018)." and does not spend an invitation.
(Such a build carries only the linker's ad hoc signature, without the bundle identifier or the
entitlements Xcode embeds for the simulator.) Demo mode and every `-dm-phase` session work in such
a build, because they keep nothing.

## Pairing with a hub

1. On the hub (the desktop app in Host mode, or the dashboard of the headless hub's local
   operator) choose **+ → iPhone / iPad app**. It shows an invitation as a QR code and as text,
   `https://<hub>/mobile#join=<code>`. Each invitation works once, for ten minutes.
2. In the app choose **Scan invitation** and point the camera at the code, or copy the text and
   paste it into the invitation field. Either way the invitation only fills the field, and the app
   names the hub it is for.
3. Check **Name of this device**: the hub lists the phone under that name, and it cannot be changed
   later. Choose **Connect**.

The hub needs an HTTPS address: Tailscale HTTPS, or `DM_HTTPS_ORIGIN` with a certificate (see
Security in the [repository README](../README.md#security)). Without one the hub's iPhone / iPad tab
says what to enable instead of showing a code, and a loopback address cannot pair a phone. The
phone has to reach that address (the same LAN or the same tailnet) and trust its certificate.
Tailscale's certificates are trusted as they are. A private CA has to be installed on the phone
and switched on under *Settings → General → About → Certificate Trust Settings*. iOS also expects
the certificate to name the host in its Subject Alternative Name and to allow server
authentication. The app has no App Transport Security exceptions and no way to accept a
certificate the phone does not trust. The first time the app connects to a hub on the LAN, iOS
asks for Local Network access; without it the app cannot reach the hub there.

When pairing succeeds the app pins the hub's key. When the hub's certificate is renewed with a new
key, the app checks the certificate chain and host name, then has the hub prove the new key with a
key both sides derive from the pairing secrets, as a paired desktop does, and carries on by itself.
No credential is sent over a connection before its key is verified.

A QR code scanned with the Camera app opens the hub's `/mobile` page, which only says to use the
app.

**Removing a phone.** The hub's iPhone / iPad tab lists the paired phones and tablets with when
each was last active. **Remove** signs that app out at once; it then shows "Pairing no longer valid"
and offers **Pair again**, which needs a fresh invitation. In the app, *Settings → Disconnect…*
has the hub forget the phone and then forgets the hub. If the hub does not answer within four
seconds the phone forgets it anyway, and the hub keeps listing the phone until it is removed there.

## Demo mode

**Try the demo** on the pairing screen runs the whole app on a hub that exists only in memory:
six devices that report every two seconds, thirty days of history, energy totals, alert rules
that are evaluated and fire. Every action works against that hub. Nothing is stored, the demo's
alerts never become notifications, and its browser link opens nothing. Leave it with **Exit demo**
in Settings. The same hub (`DemoHubAPI` in DMCore) backs the SwiftUI previews and most UI tests.

## When the hub is away

For ten seconds the app keeps showing what it last knew, with "Reconnecting to hub…". After that
it says "Can't reach the hub" and keeps retrying; it returns by itself. **Try again** retries now.
**Change setup** disconnects after asking. If the hub's operator removes this phone, the app says
so and offers to pair again; the stored enrollment is only deleted when you choose that, or
**Disconnect**.

## Notifications and background refresh

Notifications are off until you turn them on: **Turn on** in the banner at the top of the Alerts
tab, or **Notify on this iPhone** (or iPad) in Alert settings. The first time, iOS asks for
permission. The hub's "Device Monitor apps" channel must be on too; as for the desktop apps, the
hub decides which alerts are announced (every alert that fires, and "back to normal" only if it is
set to send that).

- While the app is open and connected, an alert becomes a notification as soon as the hub sends it.
- Each time the live stream comes back (the app is opened, the hub is back), the app reads the
  hub's log and announces what it missed: at most four notifications (older ones are counted in
  one summary), nothing older than a day, and never the same alert twice.
- In the background the stream is closed. The app asks iOS for a background refresh
  (`com.devicemonitor.ios.refresh`) no sooner than fifteen minutes after it leaves the foreground,
  and then reads the log the same way. iOS decides when that runs, from how the app is used. It can
  be hours late, and it does not run when Background App Refresh is off, in Low Power Mode, or after
  the app was swiped away.

There is no push through Apple: APNs needs a server holding Apple credentials, and the hub has
none. For instant alerts on a phone, switch on the hub's ntfy channel and subscribe to its topic in
the ntfy app. Alert settings say the same.

## Known limitations

- The UI tests and `Tools/e2e.sh` have never been executed (see [Requirements](#requirements)).
- Notifications only arrive at once while the app is open; in the background they can be late or
  not come at all (see above). Use ntfy for instant alerts.
- Pairing needs the hub's trusted HTTPS address. There is no plain-HTTP or loopback pairing.
- One hub at a time. Pairing with another hub means disconnecting first.
- The name the hub shows for a phone is set when it pairs and cannot be changed afterwards.
- **Disconnect** while the hub is unreachable leaves the phone in the hub's list; remove it there.
- One window. On iPad the app does not open a second window of itself (see [Info.plist](#infoplist)).
- English only.

## Layout

```
ios/
  DeviceMonitor.xcodeproj/     hand-written project; shared scheme "DeviceMonitor"
  DeviceMonitor/               app target (SwiftUI)
    Info.plist                 only the keys with no INFOPLIST_KEY_ build setting
    App/                       app entry, root phase switch, tab shell, router, environment
      Debug/                   DEBUG only: launch options, debug sessions, debug tools, gallery, probes
    DesignSystem/              theme and reusable views
    Features/<Feature>/        one folder per feature: Dashboard, History, Advanced, Alerts,
                               Settings, AddDevice, Onboarding
    Resources/                 Assets.xcassets, PrivacyInfo.xcprivacy, make-app-icon.js
  DeviceMonitorUITests/        XCUITest bundle
  Packages/DMCore/             Swift package: everything that is not a SwiftUI view
  Tools/e2e.sh                 end-to-end test against a real hub on a simulator
  Tools/e2e-selftest.sh        checks e2e.sh itself, without Xcode or a simulator
```

A feature folder holds its entry view (below), the views and controllers behind it,
`<Feature>Support.swift` (its strings, identifiers and layout constants) where it has one, and
`<Feature>DebugOptions.swift` (its launch arguments; AddDevice shares Settings'). What a screen
shows is worked out in DMCore, under `Presentation/`.

`DeviceMonitor/` and `DeviceMonitorUITests/` are synchronized folders: a file added anywhere inside
them belongs to its target automatically, and Swift files, asset catalogs and other resources are
picked up by type. **The project file does not need editing when files are added, moved or removed.**
The two exceptions listed in the project (`Info.plist`, `Resources/make-app-icon.js`) are files in the
app folder that must not be copied into the app.

### DMCore

```
Packages/DMCore/
  Sources/DMCore/
    Models/          Codable wire types and the live stream's events, as server.js sends them
    Formatting/      the dashboard's formatters, ported one for one, and JavaScript's number rules
    Security/        SPKI pin, the TLS-rotation proof (desktop-identity.js), Keychain store, enrollment
    Transport/       invitation and origin parsing, pairing, the pinned HTTPS client, the SSE reader
    API/             HubAPI (every request the app makes) and LiveHubAPI, its real-hub implementation
    Store/           SessionController, HubStore and its event reducer, Preferences, HubClock
    Presentation/    per feature (Dashboard, History, Advanced, Alerts, Energy, Settings): what a
                     screen shows, worked out as public/index.html (or alerts.js) does; no SwiftUI
    Demo/            DemoHubAPI: the in-memory hub of demo mode, previews and UI tests
  Tests/DMCoreTests/ one folder of tests per source folder (Presentation<Feature>/ for Presentation/)
    Fixtures/
      models/        JSON captured from a real hub (startHub({ fixture: true }))
      presentation/  what public/index.html and alerts.js produce for given inputs, recorded by
                     running them
      transport/     certificates, pins and HMAC vectors made by the hub's own JavaScript,
                     and e2e-hub.cjs, the helper of TransportE2ETests
```

Each fixture folder has a README that says how its files were made; the data in them is captured,
recorded or generated, never written by hand. DMCore builds for macOS 14 too, which is how its
tests run without a simulator, so it does not import UIKit or SwiftUI.

### Info.plist

Most keys are generated from `INFOPLIST_KEY_*` build settings of the app target (display name, usage
descriptions, orientations, export compliance). `DeviceMonitor/Info.plist`
holds only what has no such setting: `UILaunchScreen`, `UIBackgroundModes`,
`BGTaskSchedulerPermittedIdentifiers` and `UIApplicationSceneManifest`. The two are merged at build
time. There are no App Transport Security exceptions.

The app has **one window**. The scene manifest is written out with
`UIApplicationSupportsMultipleScenes` off (the generated manifest always allows several windows on
iPad) because `AppRouter` and the hub session are app-wide state: two windows would mirror each
other's tab and present every sheet twice. Supporting several windows means giving each window its
own router first.

### Concurrency settings

Both targets use the Swift 6 language mode with complete strict concurrency, approachable concurrency
(`SWIFT_APPROACHABLE_CONCURRENCY = YES`) and member import visibility. The app target also sets
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: every declaration in the app is main-actor isolated unless
it says `nonisolated`. Plain value types that should be usable off the main actor are declared
`nonisolated struct` / `nonisolated enum`. The UI test target and DMCore keep the default
(nonisolated).

### App icon

`Resources/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png` is the desktop app's gauge redrawn
full-bleed without an alpha channel. Regenerate it with:

```sh
node ios/DeviceMonitor/Resources/make-app-icon.js
```

## How the app is put together

Everything that is not a view is in DMCore. Three objects carry the app:

- **`SessionController`** (DMCore) owns the phase: `onboarding`, `connecting`, `live`,
  `unreachable(message:)`, `revoked`. It restores the enrollment from the Keychain at launch, pairs
  (`pair(invitationText:name:)`), runs demo mode (`startDemo()` / `stopDemo()`), and ends a pairing
  (`disconnect()`, `pairAgain()`). `retryNow()` is the "Try again" of the failure screens.
- **`HubStore`** (DMCore) is the hub's state, kept current by the live stream: devices, chart series,
  alerts, the saved electricity price, and every action on the hub. The session creates one per
  pairing (`session.store`), and one for the demo. "Try again" after a revocation starts over with a
  new, empty one, so nothing from before the hub refused the phone can come back on screen.
  Disconnecting is not an action of the store: `session.disconnect()` tells the hub and removes the
  enrollment from the Keychain.
- **`AppRouter`** (App/) is navigation that crosses features: the selected tab,
  `openHistory(deviceID:)`, `showAlerts()`, and the two shared sheets, `showAddDevice()` and
  `showElectricityPrice()`. The tab shell presents those sheets, so any screen can ask for one.

`Preferences` (DMCore) holds what the user chose on this device (temperature unit, chart ranges,
notifications, appearance), in `UserDefaults` under the dashboard's own key names with a `dm.` prefix.

`AppModel` creates these once, when the app has finished launching, and `RootView` shows the screen
for the phase. The tabs exist only while the phase is `live`.

### What a screen reads

All four are in the SwiftUI environment. A feature's entry view takes no arguments and reads what
it needs:

```swift
import DMCore
import SwiftUI

struct ExampleScreen: View {
    @Environment(HubStore.self) private var store               // the hub's state and actions (under the tabs)
    @Environment(Preferences.self) private var preferences      // @Bindable var preferences = preferences to bind
    @Environment(AppRouter.self) private var router             // tabs and shared sheets
    @Environment(SessionController.self) private var session    // phase, isDemo, hub, disconnect()

    var body: some View {
        List(store.onlineDevices) { device in
            Button(device.displayName) { router.openHistory(deviceID: device.id) }
        }
    }
}

#Preview {
    NavigationStack { ExampleScreen().dmScreen() }
        .demoEnvironment()          // the same four objects, backed by the demo hub
}
```

- `SessionController`, `Preferences` and `AppRouter` are there in every phase. `HubStore` is there
  under the tabs and in the two shared sheets, which is everywhere a hub exists to talk to; the
  phase screens read `session.store` (optional) instead.
- Demo mode is not a special case: it is the same `HubStore` on a `DemoHubAPI`. `session.isDemo`
  tells where it matters (no real hub to share a link from, "Exit demo" instead of "Disconnect").
- Redraw time-dependent things (chart windows, "last seen 5 min ago") from `store.clock.now` and on
  `store.lastStatusAt`, not from `Date()`, so previews and tests on a clock of their own agree.
- "Reconnecting to hub…" is shown by the tab shell on every tab while `store.connection` is
  `.reconnecting`; a screen does not need its own.
- `.demoEnvironment(.onboarding)` previews a screen of an app that is not paired.

### Entry views

`App/` places each feature's entry view and knows nothing else about the feature.

| File | Shown |
|---|---|
| `Features/Dashboard/DashboardScreen.swift` | Devices tab |
| `Features/History/HistoryScreen.swift` | History tab; the device comes from `router.historyDeviceID` |
| `Features/Advanced/AdvancedScreen.swift` | Advanced tab |
| `Features/Alerts/AlertsScreen.swift` | Alerts tab; its badge (alerts firing) is drawn by the tab shell |
| `Features/Alerts/AlertsIntegration.swift` | not a view: the notifier for alerts and the background refresh, called by `App/` |
| `Features/Settings/SettingsScreen.swift` | Settings tab |
| `Features/Settings/ElectricityPriceSheet.swift` | sheet for `router.showElectricityPrice()` |
| `Features/AddDevice/AddDeviceSheet.swift` | sheet for `router.showAddDevice()` |
| `Features/Onboarding/OnboardingScreen.swift` | phase `onboarding` |
| `Features/Onboarding/ConnectingScreen.swift` | phase `connecting` |
| `Features/Onboarding/UnreachableScreen.swift` | phase `unreachable` |
| `Features/Onboarding/RevokedScreen.swift` | phase `revoked` |

Each tab's screen is placed in a `NavigationStack` by the shell and sets its own title.

### Background refresh

`Info.plist` permits one background task, `com.devicemonitor.ios.refresh`. The scene registers
`AlertsIntegration.handleRefresh(session:)` for it, and `AlertsIntegration.scheduleRefresh()` is
called whenever the app enters the background; it asks for nothing while notifications are off or
in demo mode. The stream is closed in the background and reopened in the foreground; a store that
is not connected still answers requests.

## Design system and gallery

`DesignSystem/Theme.swift` has the dashboard's colours, radii and spacing; the other files in that
folder are the components (gauges, pills, cards, stat cells, tiles, the mini chart, buttons, segmented
control, chips, banners, empty states, settings rows). Every component has a `#Preview`.

Every colour comes in a light and a dark value and follows the colour scheme of the view it is drawn
in. The dark values are the dashboard's; the light ones are the app's own (the dashboard has no light
theme), and every one used as text keeps 4.5:1 on the page and on every surface. Settings' choice is
applied at the root by `AppAppearance` (`DesignSystem/Appearance.swift`), and each sheet or popover
applies it to itself with `dmAppearance()`. The scanner stays dark while it shows the camera, whatever
the choice. The launch screen follows the system's setting, because it shows before the app can read
the choice.

Debug builds have a **component gallery** with all of them and three mock device cards. It opens over
the tabs from the Debug section at the end of the Devices tab (`DebugTools`), or straight from a
launch argument (below).

The Devices grid (`DashboardGridLayout`) and the gallery's three cards (`EagerCardGrid`) are laid
out eagerly, with a `Layout` of their own: as many equal columns of at least 290 points as fit,
each row as tall as its tallest card. On the Devices tab a dragged card has to outlive being
scrolled away and a row needs all its cards measured. In the gallery a lazy grid sized the page from
an estimate of the cards it had not built yet, and at the largest text sizes the page opened
part-way down with its top out of reach. A hub's devices are few.

## Tests

### DMCore

Unit tests run on macOS, without a simulator:

```sh
cd ios/Packages/DMCore && swift test
```

Two suites talk to a real hub and are skipped unless `DM_HUB_E2E` names the repository root; they
need Node and openssl:

- `TransportE2ETests`: pairing, pinning, TLS key rotation and the proof, and what the transport
  refuses, against `server.js` behind a TLS front (`Tests/DMCoreTests/Fixtures/transport/e2e-hub.cjs`).
- `StoreE2ETests`: `LiveHubAPI` and `HubStore` against the fixture hub, `build/test/mobile-hub.js`.

```sh
cd ios/Packages/DMCore && DM_HUB_E2E="$(git rev-parse --show-toplevel)" swift test
cd ios/Packages/DMCore && DM_HUB_E2E="$(git rev-parse --show-toplevel)" swift test --filter E2ETests
```

The hub's side (the mobile routes, the QR encoder `public/qr.js`, the fixture hub itself) is tested
by `npm test` in the repository root.

### The fixture hub

`build/test/mobile-hub.js` is the real hub (`server.js`, fixture mode) serving TLS on localhost with
a throwaway CA: seven devices (five that keep reporting, one that stops after three reports, one
offline since before the hub started), a week of history, an electricity price and firing alerts.

```sh
node build/test/mobile-hub.js --port 8571 --control 8572 --dir <dir>
```

It prints one JSON line when it is ready (origin, CA path, an invitation, the pin). `--dir` keeps
`ca.pem` and `ca.key` there, so one CA stays trusted across runs. A plain-HTTP control endpoint on
127.0.0.1 hands out invitations (`curl -s http://127.0.0.1:8572/invite`), rotates the TLS key,
revokes the phone, takes devices offline and raises an alert; its commands are listed at the top of
the file.

To look at the app against it by hand: start it, trust `<dir>/ca.pem` in the simulator
(`xcrun simctl keychain <udid> add-root-cert <dir>/ca.pem`), and launch the app with
`-dm-reset -dm-invitation "$(curl -s http://127.0.0.1:8572/invite)" -dm-autoconnect`.

### UI tests

They have never been run (see [Requirements](#requirements)). With a working Xcode, run them through
the shared scheme on an iPhone and on an iPad simulator:

```sh
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
```

Use any simulator you have; `xcrun simctl list devices available` lists them. To only compile them,
replace `test` with `build-for-testing`. Many tests attach screenshots; with `-resultBundlePath
<path>.xcresult`, `xcrun xcresulttool export attachments --path <path>.xcresult --output-path <dir>`
saves them.

| Class | What it covers |
|---|---|
| `SmokeUITests` | the wiring of the shell: onboarding when unpaired, the five tabs, the router, launch arguments, the gallery |
| `DemoFlowUITests` | the app end to end without a hub: demo mode with readings that keep changing, every phase's screen, the way out of the failure screens, a hub that goes away and comes back, a demo hub that refuses the app, the shared sheets |
| `RegressionUITests` | things that broke once: state kept by a phase screen, out-of-range readings, VoiceOver grouping of the gauges, the gallery at the largest text size |
| `OnboardingUITests` | pairing (the invitation's hub, refused invitations, the keyboard, every scanner state without a camera), connecting, unreachable, revoked |
| `DashboardUITests` | the Devices tab: cards, the menu, rename, remove, a card's range, Details, the chart into History, reordering by drag and by Move up, the offline list and Wake, the pinned header, no devices, all offline, large text |
| `HistoryUITests` | the History tab: device and range, zoom and Reset zoom, inspecting without zooming, empty, failed, loading and no-device states, no requests while another tab shows, large text |
| `AdvancedUITests` | the Advanced tab: totals, the range and keeping it, the price editor, a bar's figures, a device's power breakdown, loading, failed and empty states, the largest text size |
| `AlertsUITests` | the Alerts tab: what is firing, the log, links to History and to the rule, a live alert, clearing the log, editing, adding and validating rules, channels, the test alert, a failed save, notification permission, the demo's notifications, a draft kept through an outage, large text |
| `SettingsUITests` | the Settings tab, the price editor (one rate, region, time of use, a hub that cannot be asked or told) and the add-device sheet, on the demo hub and on a `-dm-phase live` session |
| `HubFlowUITests` | the app against a real hub; skipped unless started by `Tools/e2e.sh` |

Every test names the session it wants with a launch argument, so none depends on what an earlier run
left in the simulator's Keychain. The identifiers the flow tests lean on are listed at the top of
`DeviceMonitorUITests/UITestSupport.swift`; a screen that is rebuilt keeps them, or changes them there.
To add a UI test, add a Swift file to `DeviceMonitorUITests/`; nothing else is needed. Test methods
that touch `XCUIApplication` are marked `@MainActor`. A test can ask for a text size with
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.

Four tests use the Debug section at the end of the Devices tab: two in `DemoFlowUITests` open its
**Demo hub** menu (`debug-hub-menu`), which makes the hub unreachable, silent or revoke this app,
and two in `SmokeUITests` tap its gallery and History routing rows. They scroll there from the
cards.

### End to end against a real hub

```sh
ios/Tools/e2e.sh                       # the first booted simulator, ports 8543 and 8544
ios/Tools/e2e.sh --sim <udid> --port 8571 --control 8572 --result /tmp/e2e.xcresult
```

The script starts the fixture hub, trusts its CA in the simulator
(`xcrun simctl keychain <udid> add-root-cert`), builds the app and the tests, asks the hub's control
port for a fresh invitation and runs `HubFlowUITests`, handing it the invitation and the control
port's address (`TEST_RUNNER_DM_E2E_INVITATION`, `TEST_RUNNER_DM_E2E_CONTROL`). The hub, and
whatever command is still running (`xcodebuild`, or `simctl` waiting for a simulator), are stopped
when the script ends, also when it is interrupted or terminated. The result bundle an earlier run
left at `--result` is replaced; a `--result` that exists and is not an `.xcresult` bundle is refused
before anything is started. The test:

1. starts from a reset app, types the invitation and connects;
2. sees the fixture's seven devices, with readings that keep changing, and the phone in the hub's list;
3. relaunches: still paired, live again, nothing paired twice;
4. has the hub change its TLS key twice (RSA, then EC): the app proves each new key and carries on;
5. has the hub remove the phone: the app shows the revoked screen, and still does after a relaunch;
6. pairs again with a second invitation and disconnects: the hub's list is empty again.

`--skip-build` reuses the last build; arguments after `--` go to `xcodebuild`. The fixture's CA is
kept in `ios/.build/e2e-hub` so one CA stays trusted across runs; the hub's data is new every run.
Do not pass `CODE_SIGNING_ALLOWED=NO` here: the test relaunches the app and expects the enrollment
to still be in the Keychain (see [Signing](#signing)).

`ios/Tools/e2e-selftest.sh [--port 8581]` checks the script itself, in under a minute and without
Xcode or a simulator (macOS or Linux): it runs `e2e.sh` against the real fixture hub with stand-ins
for `xcrun` and `xcodebuild`, and checks what the test runner is handed, that a result bundle is
replaced, and that TERM ends the script and its hub at once, also while a simulator command hangs.
Run it after changing `e2e.sh`.

## Debug launch arguments

Debug builds understand these, so UI tests and screenshots can start in any state without a tap;
a release build has none of them. The app's own arguments are in
`App/Debug/DebugLaunchOptions.swift`. Each feature reads its own, documented at the top of its
`Features/<Feature>/<Feature>DebugOptions.swift`. Most of them only decide what is drawn. Those
that act (their entries say so) do what the control would, on the hub the app is on: use them with
the demo hub, which keeps nothing.

### App

| Argument | Effect |
|---|---|
| `-dm-demo` | start in demo mode; implies an in-memory credential store |
| `-dm-reset` | first forget the stored enrollment and every preference, as on a fresh install |
| `-dm-memory-credentials` | keep the enrollment in memory instead of the Keychain |
| `-dm-invitation <text>` | pre-fill the invitation on the pairing screen (or the environment variable `DM_INVITATION`) |
| `-dm-name <label>` | pre-fill the name this device gets on the hub |
| `-dm-autoconnect` | pair with the pre-filled invitation at launch, without a tap |
| `-dm-phase <onboarding\|connecting\|live\|unreachable\|revoked>` | show that phase, "paired" with a demo hub made to behave that way; nothing is stored |
| `-dm-tab <devices\|history\|advanced\|alerts\|settings>` | start on that tab |
| `-dm-history <device id>` | open the History tab for that device, through the router |
| `-dm-sheet <addDevice\|electricityPrice>` | present that shared sheet |
| `-dm-gallery [section]` | open the component gallery, optionally scrolled to a section (`cards`, `gauges`, `pills`, `chart`, `stats`, `kv`, `tiles`, `buttons`, `selection`, `banners`, `empty`, `settings`, `colours`, `type`, `extremes`); implies `-dm-demo` |
| `-dm-probe phase-container` | open the check that a phase screen keeps its state when it starts scrolling; implies `-dm-demo` |
| `-dm-then <disconnect\|pair-again\|retry\|outage>` | once the session has settled (live, unreachable or revoked), do what that button does; `outage` takes a demo hub away for twenty seconds |

`-dm-tab`, `-dm-history` and `-dm-sheet` take effect when the tabs are showing: combine them with
`-dm-demo` or `-dm-phase live`, unless the app is paired. The pairing screen fills its fields from
`-dm-invitation` and `-dm-name`. In demo mode and in a `-dm-phase` session the Debug section at the
end of the Devices tab also has a **Demo hub** menu that makes the hub unreachable, silent or revoke
this app, or fires a disk alert.

### Preferences for one launch

A preference can be given for one launch under its `UserDefaults` key (`Preferences.Key` in DMCore).
It is read instead of the stored value; what the app saves during that launch is stored as usual.

| Argument | Effect |
|---|---|
| `-dm.unit <C\|F>` | temperature unit |
| `-dm.appearance <system\|light\|dark>` | appearance; `system` follows the simulator's own setting |
| `-dm.range <10m\|1h\|6h>` | the range of a card that has none of its own |
| `-dm.cardRanges {}` | no card has a range of its own |
| `-dm.notifications YES` | the choice behind "Notify on this iPhone" is on; the switch shows it only where iOS allows notifications |
| `-dm.hvRange`, `-dm.advRange`, `-dm.setAdvOpen` | History's range, Advanced's range, Settings' "Advanced settings" open (`1`) |

### Devices tab

`Features/Dashboard/DashboardDebugOptions.swift`. Combine with `-dm-demo`.

| Argument | Effect |
|---|---|
| `-dm-dashboard-scroll <device id\|debug>[:top\|center\|bottom]` | scroll so that this edge of the card (or of the Debug section) meets the same edge of the screen |
| `-dm-dashboard-details <id,id…\|all>` | open Details on those cards |
| `-dm-dashboard-offline` | open the offline list |
| `-dm-dashboard-wake <sending\|sent\|failed>` | show the offline list's Wake buttons in that state |
| `-dm-dashboard-wake press` | press Wake on the first device that has one (acts) |
| `-dm-dashboard-rename <device id>` | open the rename question for that device |
| `-dm-dashboard-rename-text <text>` | with it, this typed instead of the current name (`_` stands for a space) |
| `-dm-dashboard-remove <device id>` | open the remove confirmation for that device |
| `-dm-dashboard-commit` | answer the open rename or remove question with its Rename or Remove button (acts) |
| `-dm-dashboard-error <text>` | show the failure alert with this explanation (`_` stands for a space) |
| `-dm-dashboard-scrub <0…1>` | every chart starts scrubbed at that fraction of its width, with its tooltip |
| `-dm-dashboard-card-width <points>` | the narrowest a grid column may be (290), to see several columns on a phone |
| `-dm-dashboard-header <page\|bar>` | the logo, name and summary in a row pinned above the page (as on an iPad) or in the navigation bar, whatever the window's size |
| `-dm-dashboard-state loading` | the state before the first snapshot |
| `-dm-dashboard-state empty` | remove every device (demo hub only) |
| `-dm-dashboard-state all-offline` | stop every device reporting (demo hub only; the hub calls them offline 30 s later) |
| `-dm-dashboard-state offline-and-back` | the same, and eight seconds after the last has gone they all report again (demo hub only) |
| `-dm-dashboard-range <device id>:<10m\|1h\|6h>` | choose that range in the card's range menu (acts: it is remembered, like any choice made there) |
| `-dm-dashboard-move <device id>:<-1\|1>` | the card's Move up or Move down action (acts) |
| `-dm-dashboard-drag <device id>:<over id\|bottom>[:hold]` | drag the card by its grip onto another card and drop it (acts); `hold` keeps it in the air there; `bottom` rests the finger at the lower edge of the screen for two seconds, so the page scrolls |

### History tab

`Features/History/HistoryDebugOptions.swift`. Combine with `-dm-demo -dm-tab history` or
`-dm-demo -dm-history <device id>`. The range and the unit apply to this launch only, and the hub is
told nothing.

| Argument | Effect |
|---|---|
| `-dm-history-range <1h\|6h\|24h\|7d\|30d>` | open with that range |
| `-dm-history-unit <C\|F>` | show temperatures in that unit |
| `-dm-history-scroll <tiles\|utilization\|temperature\|gpuPower\|network\|diskIO\|hint>` | scroll that part of the page to the top once loaded |
| `-dm-history-inspect <0…1>` | a finger resting at that fraction of the plot's width: crosshair and tooltip on every chart |
| `-dm-history-select <a,b>` | a drag in progress between those fractions |
| `-dm-history-zoom <a,b>` | zoomed into that part of the window, through the same code as a real drag |
| `-dm-history-state loading` | the hub never answers |
| `-dm-history-state empty` | it answers with no points |
| `-dm-history-state error` | the first request fails, later ones work ("Try again") |
| `-dm-history-state no-devices` | as if the hub knew no device |
| `-dm-history-state reloading` | the first answer arrives, a reload never does: the charts stay, the header shows progress |
| `-dm-history-state switching` | the same, with the next device selected: its name over the faded charts of the first |
| `-dm-history-away` | once the first answer is on screen, show the Devices tab, take the demo hub away for a moment and come back; the probe `history-debug` then reports, e.g. `away=done;reconnected=1;loads=0;since=1`. Needs `-dm-demo` |

### Advanced tab

`Features/Advanced/AdvancedDebugOptions.swift`. Combine with `-dm-demo -dm-tab advanced`.

| Argument | Effect |
|---|---|
| `-dm-advanced-range <24h\|7d\|30d>` | open on this range; the saved choice is left alone |
| `-dm-advanced-state loading` | the hub never answers |
| `-dm-advanced-state late` | the hub's answers take two seconds; `-dm-advanced-then price` then saves the price while the first is still on its way |
| `-dm-advanced-state failed` | every request for totals fails |
| `-dm-advanced-state stale` | one answer reaches the page, then every request fails |
| `-dm-advanced-state empty` | the hub has no totals for the range |
| `-dm-advanced-state no-devices` | no totals and no devices either |
| `-dm-advanced-price <guessed\|tou>` | work the page out as if no price were saved, or as if time-of-use rates were; nothing is sent to the hub |
| `-dm-advanced-then <24h\|7d\|30d>` | once the totals are in, choose that range (acts: it is saved, as the control saves it) |
| `-dm-advanced-then price` | once the totals are in, save a flat price of $0.10/kWh on the demo hub, as the price sheet would (acts; demo only) |
| `-dm-advanced-section <electricity\|chart\|power\|usage\|note>` | scroll there once the totals are in |
| `-dm-advanced-bucket <index\|last>` | select that bar of the chart, as a touch would |
| `-dm-advanced-expand <device id\|all>` | open that device's power breakdown |
| `-dm-advanced-width <points>` | lay the page out this wide and let it scroll sideways, to look at the iPad layouts on a phone |
| `-dm-advanced-pan <0…1>` | with `-dm-advanced-width`: how far along to start |

### Alerts tab

`Features/Alerts/AlertsDebugOptions.swift`. Combine with `-dm-demo` or `-dm-phase live`, and
`-dm-tab alerts`. `save` and `test` in a script go through the store like the buttons do, so on a
demo hub they change that hub, which lives in memory for this launch only.

| Argument | Effect |
|---|---|
| `-dm-alerts-list <loading\|error\|empty\|all-clear\|no-rules\|kinds>` | the tab as if the hub had answered that way: not yet, not at all, with nothing, with nothing firing, with every rule off, or with the kinds of log entry a demo never has (a test alert, an unknown state, no device, a device that is gone) |
| `-dm-alerts-open settings` | the editor ("Alert settings") is pushed |
| `-dm-alerts-rule <n\|kind\|new:kind>` | a rule's screen, opened the way "Edit rule" on an alert opens it: the n-th rule (from 0), the first of that kind (`cpuTemp`, `offline`, `dailyCost`…), or a rule of that kind added as "Add rule" adds it |
| `-dm-alerts-scroll <history\|iphone\|rules\|channels\|messages\|test>` | scrolled to that part (`history` on the tab, the others in the editor) |
| `-dm-alerts-notify <undecided\|off\|asking\|on\|blocked>` | "Notify on this iPhone" drawn in that state, whatever the preference and the permission say. The invitation (`undecided`, `asking`) is not shown in a demo: use `-dm-phase live`. The blocked banner needs `-dm.notifications YES` |
| `-dm-alerts-confirm <clear\|discard\|delete>` | that confirmation is up: clear the log, discard the edits (needs an edit from the script), delete the rule on screen |
| `-dm-alerts-confirm-after <seconds>` | with `-dm-alerts-confirm`: the confirmation comes up that long after its button appears, as after a tap, instead of being up from the start. For reading identifiers: the system only gets a dialog's button identifiers for a dialog made after something asked for the accessibility tree |
| `-dm-alerts-script <step,step,…>` | steps done in order once the editor has the hub's settings, as taps and typing would do them (below; `save` and `test` act) |
| `-dm-alerts-fail <save\|test>` | the hub cannot be reached for that request (a stand-in: the demo hub is left alone) |
| `-dm-alerts-price none` | as if the hub had no electricity price |
| `-dm-alerts-unit <C\|F>` | limits shown in that unit; the stored preference is not touched |
| `-dm-alerts-width <points>` | lay these screens out at that width and shrink the picture to fit, for an iPad's or a sideways phone's arrangement |
| `-dm-alerts-probe` | the probe `debug-alerts-notifier` on the Alerts tab: what the notifier did, e.g. `stream: up; log: 6 entries; notify: [] …`. In a demo its last entry ends "kept back, a demo"; with `-dm-phase live -dm.notifications YES` it ends "posted" |

Script steps. Edits of the draft: `apps=on|off`, `ntfy=on|off`, `webhook=on|off`, `resolved=on|off`,
`topic=<text>`, `server=<text>`, `email=<text>`, `url=<text>`, `msgunit=C|F`, `replace=on`,
`remove=on`, `rules=none`, and for the rule on screen `kind=<kind>`, `device=<id>`,
`limit=<text>`, `minutes=<n>`, `enabled=on|off`. Actions: `save`, `test` (Send test alert),
`test-failed` (a test result with a failed delivery), `back` (from the rule's screen to the editor),
`disk-alert` (the demo hub raises a disk alert and clears it eight seconds later), `price` (the
shared price sheet), `elsewhere` (the hub's settings change behind the draft: offline after 45 min,
"resolved" flipped). For example `webhook=on,url=https://chat.example/hook,save,replace=on`.

### Settings tab and the add-device sheet

`Features/Settings/SettingsDebugOptions.swift`. Combine with `-dm-demo` or `-dm-phase live`, and
with `-dm-tab settings`, `-dm-sheet electricityPrice` or `-dm-sheet addDevice`. `loading`, `error`,
`load-error` and `save-error` stand in for the hub's answer; the demo hub itself is left alone.

| Argument | Effect |
|---|---|
| `-dm-settings-scroll <device\|hub\|advanced\|about\|link>` | the Settings tab scrolled to that section; `link` is the add-device sheet scrolled to "View from another device" |
| `-dm-settings-advanced <open\|closed>` | "Advanced settings" expanded or collapsed for this run; the remembered choice is neither read nor changed |
| `-dm-settings-confirm disconnect` | the "Disconnect this iPhone and change setup?" confirmation is up |
| `-dm-settings-identity full` | the hub's TLS identity shown whole |
| `-dm-settings-show license` | the license screen is pushed |
| `-dm-settings-link <ready\|loading\|error\|expired\|noshare>` | the "Dashboard link" row of Settings in that state |
| `-dm-settings-invite <loading\|error\|expired\|noshare>` | the add-device sheet's browser link in that state |
| `-dm-settings-price <state>` | the price editor, wherever it is shown, in that state (below) |
| `-dm-settings-width <points>` | lay the Settings tab, the price sheet and the add-device sheet out at that width and shrink the picture to fit, for an iPad's or a sideways phone's arrangement; nothing can be tapped accurately in that picture |

Price editor states: `tou` (switched to "Time of use"; acts: saved on the hub as a tap would),
`invalid` (time of use with a rate that is not one in the first period), `full` (the twelve periods
the hub allows), `loading` (the hub has not answered), `load-error` (the hub could not be asked),
`save-error` (a change the hub could not be told about), `save-lost` (the hub made a change after
all, and its news of the new price arrives first), `save-late` (the same, with that news a second
after the failure), `regions` (the "Where you live" list is open), and `remembered` (for both
editors at once, with `-dm-tab settings -dm-settings-advanced open -dm-sheet electricityPrice`: the
one in Settings sets two periods and goes back to "One rate"; then the sheet's chooses "Time of
use", which brings the two back).

### Onboarding and the phase screens

`Features/Onboarding/OnboardingDebugOptions.swift`. Combine with
`-dm-phase onboarding|connecting|unreachable|revoked` and the pairing arguments of the app. They
only decide what these screens draw first, not what the session does.

| Argument | Effect |
|---|---|
| `-dm-onboarding-scanner <state>` | open the scanner sheet without the camera, as if it were `preparing`, `scanning`, `interrupted`, `denied`, `restricted`, `unavailable` or `failed`; or scanning and just shown a `desktop`, `browser` or `other` code (with the transport's message for it); or `accept`: a good invitation was scanned, the sheet closes and the invitation waits in its field for Connect |
| `-dm-onboarding-camera <0\|1>` | whether the Scan button believes the device has a camera |
| `-dm-onboarding-focus <invitation\|name>` | put the keyboard focus in that field at launch |
| `-dm-onboarding-scroll <fields\|end>` | scroll the pairing screen so that its fields and Connect, or its last line, are at the bottom of what is on show |
| `-dm-onboarding-busy` | the pairing form as while "Verifying the hub…" |
| `-dm-onboarding-slow <0\|1>` | Connecting: the "taking long" note at once, or never |
| `-dm-onboarding-confirm` | Unreachable: the "Change setup" confirmation open |
| `-dm-onboarding-retrying` | Unreachable: as while "Try again" is under way |
| `-dm-onboarding-as-demo` | Unreachable and Revoked: the wording of a demo session |
| `-dm-onboarding-metrics` | print what the layout measured in a corner: the screen without the keyboard, and the height on show with it |
| `-dm-onboarding-canvas <W>x<H>` | lay the screen out in a canvas of that many points, scaled to fit and turned a quarter when it is wider than tall (`874x402` is an iPhone 17 Pro in landscape, `1194x834` an iPad) |

### Probes

Debug builds also have invisible accessibility elements that UI tests read to follow the app
instead of how a screen happens to draw:

- `debug-session`, always: `phase=live;demo=0;connection=live;devices=7;online=5;heartbeat=…;readings=…;hub=…`
  (`App/Debug/SessionProbe.swift`).
- `history-debug`, with `-dm-history-away`.
- `debug-alerts-notifier`, with `-dm-alerts-probe`.

### Some combinations

```
-dm-demo -dm-tab alerts                                      the Alerts tab on the demo hub
-dm-phase unreachable                                        the "Can't reach the hub" screen
-dm-reset -dm-invitation <text> -dm-autoconnect              pair with a real hub from a clean state, no taps
-dm-demo -dm-then outage                                     banner, then unreachable, then back, in thirty seconds
-dm-demo -dm-dashboard-offline -dm-dashboard-wake sent       the offline list after Wake
-dm-demo -dm-history gaming -dm-history-zoom 0.4,0.7         the Gaming PC's history, zoomed
-dm-demo -dm-tab advanced -dm-advanced-bucket last           the newest bar of the energy chart selected
-dm-demo -dm-tab alerts -dm-alerts-rule new:cpuTemp          a new CPU temperature rule
-dm-phase live -dm-tab settings -dm-settings-confirm disconnect   the Disconnect question
-dm-phase onboarding -dm-onboarding-scanner denied           the scanner without camera access
```
