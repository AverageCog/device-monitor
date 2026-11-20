# Device Monitor for iOS

A native iPhone and iPad companion for Device Monitor. It pairs with a hub and shows what the web
dashboard shows; it never reports the phone's own stats.

## Requirements

- macOS with Xcode 16 or later (the project uses file-system-synchronized groups, project format 77).
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
it builds for the simulator as is. To run on a device, select your team under
*DeviceMonitor target → Signing & Capabilities* (do the same for *DeviceMonitorUITests* to run UI tests
on a device). The bundle identifier is `com.devicemonitor.ios`.

## Layout

```
ios/
  DeviceMonitor.xcodeproj/     hand-written project; shared scheme "DeviceMonitor"
  DeviceMonitor/               app target (SwiftUI)
    Info.plist                 only the keys with no INFOPLIST_KEY_ build setting
    App/                       app entry, phases, router, tab shell
      Debug/                   DEBUG only: launch options, debug tools, component gallery
    DesignSystem/              theme and reusable views
    Features/<Feature>/        one folder per screen
    Resources/                 Assets.xcassets, PrivacyInfo.xcprivacy, make-app-icon.js
  DeviceMonitorUITests/        XCUITest bundle
  Packages/DMCore/             Swift package: everything that is not a SwiftUI view
```

`DeviceMonitor/` and `DeviceMonitorUITests/` are synchronized folders: a file added anywhere inside
them belongs to its target automatically, and Swift files, asset catalogs and other resources are
picked up by type. **The project file does not need editing when files are added, moved or removed.**
The two exceptions listed in the project (`Info.plist`, `Resources/make-app-icon.js`) are files in the
app folder that must not be copied into the app.

### Info.plist

Most keys are generated from `INFOPLIST_KEY_*` build settings of the app target (display name, usage
descriptions, orientations, dark interface style, export compliance). `DeviceMonitor/Info.plist`
holds only what has no such setting: `UILaunchScreen`, `UIBackgroundModes` and
`BGTaskSchedulerPermittedIdentifiers`. The two are merged at build time. There are no App Transport
Security exceptions.

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

## Design system and gallery

`DesignSystem/Theme.swift` has the dashboard's colours, radii and spacing; the other files in that
folder are the components (gauges, pills, cards, stat cells, tiles, the mini chart, buttons, segmented
control, chips, banners, empty states, settings rows). Every component has a `#Preview`.

Debug builds have a **component gallery** with all of them and three mock device cards: Devices tab →
Debug → Component gallery, or launch straight into it (below).

### Debug launch arguments

Debug builds understand:

| Argument | Effect |
|---|---|
| `-dm-phase <onboarding\|connecting\|live\|unreachable\|revoked>` | start in that phase |
| `-dm-tab <devices\|history\|advanced\|alerts\|settings>` | start on that tab |
| `-dm-gallery [section]` | open the component gallery, optionally scrolled to a section (`cards`, `gauges`, `pills`, `chart`, `stats`, `kv`, `tiles`, `buttons`, `selection`, `banners`, `empty`, `settings`, `colours`, `type`) |

## Tests

DMCore's unit tests run on macOS, without a simulator:

```sh
cd ios/Packages/DMCore && swift test
```

The UI tests run through the shared scheme on a simulator:

```sh
xcodebuild -project ios/DeviceMonitor.xcodeproj -scheme DeviceMonitor \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

To add a UI test, add a Swift file to `DeviceMonitorUITests/`; nothing else is needed. Test methods
that touch `XCUIApplication` are marked `@MainActor`.
