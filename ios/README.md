# Device Monitor for iOS

A native iPhone and iPad companion for Device Monitor. It pairs with a hub and shows what the web
dashboard shows; it never reports the phone's own stats.

## Requirements

- macOS with Xcode 26 or later. The app target is built with default main-actor isolation and
  approachable concurrency (see [Concurrency settings](#concurrency-settings)), build settings that
  Xcode 26 introduced. Xcode 16 can open the project (file-system-synchronized groups, project
  format 77) but does not know those settings, and the app does not compile without them.
  Developed with Xcode 27 / Swift 6.4.
- iOS 17.0 or later on the device or simulator.
- No third-party dependencies and no package downloads: the only package is the local `Packages/DMCore`.

## Open, build, run

Open `ios/DeviceMonitor.xcodeproj`, pick the **DeviceMonitor** scheme and a simulator, and run.

From the command line:

```sh
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
```

### Signing

The project carries no development team (`CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM` empty), so
it builds for the simulator as is, signed ad hoc. To run on a device, select your team under
*DeviceMonitor target → Signing & Capabilities* (do the same for *DeviceMonitorUITests* to run UI tests
on a device). The bundle identifier is `com.devicemonitor.ios`.

The enrollment lives in the Keychain, so build with Xcode's signing step left on, which is the
default. A simulator app built with `CODE_SIGNING_ALLOWED=NO` runs but has no Keychain: it starts
unpaired, shows "The Keychain is unavailable (error -34018)." and does not spend an invitation.
(Such a build carries only the linker's ad hoc signature, without the bundle identifier or the
entitlements Xcode embeds for the simulator.) Demo mode and every `-dm-phase` session work in such
a build, because they keep nothing.

## Using it

**Pair.** On the hub (the desktop app in Host mode, or the dashboard opened on the hub itself) choose
**+ → iPhone / iPad app**. It shows an invitation as a QR code and as text,
`https://<hub>/mobile#join=<code>`, good for ten minutes and for one use. Paste it into the app and
choose **Connect**. The hub must be reachable over HTTPS with a certificate the phone trusts; the app
then pins the hub's key, and follows the hub through certificate renewals by itself.

**Demo.** **Try the demo** on the pairing screen runs the whole app on a hub that exists only in
memory (six devices that keep reporting, thirty days of history, alerts). Nothing is stored; leave
it from Settings.

**When the hub is away.** For ten seconds the app keeps showing what it last knew, with "Reconnecting
to hub…". After that it says "Can't reach the hub" and keeps retrying; it returns by itself. If the
hub's operator removes this phone, the app says so and offers to pair again; the stored enrollment
is only deleted when you choose that, or **Disconnect**.

## Layout

```
ios/
  DeviceMonitor.xcodeproj/     hand-written project; shared scheme "DeviceMonitor"
  DeviceMonitor/               app target (SwiftUI)
    Info.plist                 only the keys with no INFOPLIST_KEY_ build setting
    App/                       app entry, root phase switch, tab shell, router, environment
      Debug/                   DEBUG only: launch options, debug sessions, debug tools, gallery
    DesignSystem/              theme and reusable views
    Features/<Feature>/        one folder per feature, one entry view each (see below)
    Resources/                 Assets.xcassets, PrivacyInfo.xcprivacy, make-app-icon.js
  DeviceMonitorUITests/        XCUITest bundle
  Packages/DMCore/             Swift package: everything that is not a SwiftUI view
  Tools/e2e.sh                 end-to-end test against a real hub on a simulator
  Tools/e2e-selftest.sh        checks e2e.sh itself, without Xcode or a simulator
```

`DeviceMonitor/` and `DeviceMonitorUITests/` are synchronized folders: a file added anywhere inside
them belongs to its target automatically, and Swift files, asset catalogs and other resources are
picked up by type. **The project file does not need editing when files are added, moved or removed.**
The two exceptions listed in the project (`Info.plist`, `Resources/make-app-icon.js`) are files in the
app folder that must not be copied into the app.

### Info.plist

Most keys are generated from `INFOPLIST_KEY_*` build settings of the app target (display name, usage
descriptions, orientations, dark interface style, export compliance). `DeviceMonitor/Info.plist`
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

`Preferences` (DMCore) holds what the user chose on this device (temperature unit, chart ranges).

`AppModel` creates these once, when the app has finished launching, and `RootView` shows the screen
for the phase. The tabs exist only while the phase is `live`.

### What a screen reads

All four are in the SwiftUI environment. A feature's entry view takes no arguments and reads what
it needs:

```swift
import DMCore
import SwiftUI

struct DashboardScreen: View {
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
    NavigationStack { DashboardScreen().dmScreen() }
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

### One entry view per feature

Each feature is replaced by rewriting its own files; nothing in `App/` changes.

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
called whenever the app enters the background. The stream is closed in the background and reopened
in the foreground; a store that is not connected still answers requests.

## Design system and gallery

`DesignSystem/Theme.swift` has the dashboard's colours, radii and spacing; the other files in that
folder are the components (gauges, pills, cards, stat cells, tiles, the mini chart, buttons, segmented
control, chips, banners, empty states, settings rows). Every component has a `#Preview`.

Debug builds have a **component gallery** with all of them and three mock device cards. It opens over
the tabs from the `DebugTools` section (any screen can embed it; the interim Devices tab does), or
straight from a launch argument (below), whether or not a screen embeds that section.

The device grid's `LazyVGrid` belongs directly in the Dashboard's `ScrollView`. Nested in an eager
`VStack`, a lazy grid of tall cards is sized from an estimate of the cards it has not built yet, and
at the largest text sizes that left the page opening part-way down with its top out of reach. The
gallery is one long eager page, so it lays its three cards out with an eager layout instead.

### Debug launch arguments

Debug builds understand these; a release build has none of them.

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
| `-dm-then <disconnect\|pair-again\|retry\|outage>` | once the session has settled, do what that button does; `outage` takes a demo hub away for twenty seconds |

`-dm-tab`, `-dm-history` and `-dm-sheet` take effect when the tabs are showing: combine them with
`-dm-demo` or `-dm-phase live`, unless the app is paired. Some combinations:

```
-dm-demo -dm-tab alerts                          the Alerts tab on the demo hub
-dm-phase unreachable                            the "Can't reach the hub" screen
-dm-reset -dm-invitation <text> -dm-autoconnect  pair with a real hub from a clean state, no taps
-dm-demo -dm-then outage                         banner, then unreachable, then back, in thirty seconds
```

The interim `OnboardingScreen` reads `-dm-invitation` and `-dm-name` itself; whatever replaces it
keeps that. In demo mode and in a `-dm-phase` session the `DebugTools` section also has a **Demo hub**
menu that makes the hub unreachable, silent or revoke this app.

Debug builds also expose the session as one invisible accessibility element, `debug-session`, whose
label reads `phase=live;demo=0;connection=live;devices=7;online=5;heartbeat=…;readings=…;hub=…`.
UI tests follow the app through it instead of through how a screen happens to draw.

## Tests

### DMCore

Unit tests run on macOS, without a simulator:

```sh
cd ios/Packages/DMCore && swift test
```

Two suites talk to a real hub (`server.js` behind TLS, started through `build/test/mobile-hub.js`)
and are skipped unless `DM_HUB_E2E` names the repository root; they need Node and openssl:

```sh
cd ios/Packages/DMCore && DM_HUB_E2E="$(git rev-parse --show-toplevel)" swift test
```

### UI tests

The UI tests run through the shared scheme on a simulator:

```sh
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

- `SmokeUITests`: the wiring of the shell.
- `DemoFlowUITests`: the app end to end without a hub. Demo mode with readings that keep changing,
  every phase's screen, the way out of the failure screens, a hub that goes away and comes back, the
  shared sheets.
- `RegressionUITests`: things that broke once (state kept by a phase screen, out-of-range readings,
  VoiceOver grouping of the gauges, the gallery at the largest text size).
- `HubFlowUITests`: the app against a real hub. Skipped unless started by `Tools/e2e.sh`.

Every test names the session it wants with a launch argument, so none depends on what an earlier run
left in the simulator's Keychain. The identifiers the flow tests lean on are listed at the top of
`DeviceMonitorUITests/UITestSupport.swift`; a screen that is rebuilt keeps them, or changes them there.
To add a UI test, add a Swift file to `DeviceMonitorUITests/`; nothing else is needed. Test methods
that touch `XCUIApplication` are marked `@MainActor`. A test can ask for a text size with
`-UIPreferredContentSizeCategoryName UICTContentSizeCategoryAccessibilityXXXL`.

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

`ios/Tools/e2e-selftest.sh [--port 8581]` checks the script itself, in a few seconds and without
Xcode or a simulator (macOS or Linux): it runs `e2e.sh` against the real fixture hub with stand-ins
for `xcrun` and `xcodebuild`, and checks what the test runner is handed, that a result bundle is
replaced, and that TERM ends the script and its hub at once, also while a simulator command hangs.
Run it after changing `e2e.sh`.

To look at the app against the fixture hub by hand, start the hub
(`node build/test/mobile-hub.js --port 8571 --control 8572 --dir <dir>`), trust `<dir>/ca.pem` in the
simulator as above, and launch the app with
`-dm-reset -dm-invitation "$(curl -s http://127.0.0.1:8572/invite)" -dm-autoconnect`. The control
port rotates the TLS key, revokes the phone and takes devices offline; its commands are listed at the
top of `build/test/mobile-hub.js`.
