# TaskCtrl

A system monitor and disk analyzer for macOS, written in SwiftUI.

Tabs: Summary, Performance, Processes, Sensors, Apple Silicon, Connections,
System Info, Startup apps, Users, Services, Installed Apps, Drivers and Disk Space.

## Download

Ready-made builds are on the [Releases](https://github.com/mnem0c0der/task-ctrl/releases)
page, with what changed in each. They need macOS 15 or later on Apple Silicon.

The builds are not notarized, so macOS blocks the first launch. After moving
the app to Applications, clear the download flag once:

```bash
xattr -dr com.apple.quarantine /Applications/TaskCtrl.app
```

A downloaded build cannot install the privileged helper; for that, build
from source with your own developer team, as described below.

## Requirements

- macOS 15 or later (developed and tested on Apple Silicon)
- Xcode 26 or later, with the command line tools selected
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), only if you add, remove or rename files

There are no package dependencies.

## Before the first build: signing

The project is set up to sign with one particular Apple developer team.
You have two ways to build it on your own Mac.

**With your own team — everything works.**
Open `project.yml`, replace the value of `DEVELOPMENT_TEAM` with your team ID,
and regenerate the project:

```bash
xcodegen generate
```

You need an "Apple Development" certificate for that team in your keychain.
A free Apple ID is enough; Xcode creates the certificate under
Settings › Accounts. Your team ID is the ten-character code shown in
parentheses by:

```bash
security find-identity -v -p codesigning
```

**Without a team — everything except the privileged helper.**
Leave `project.yml` alone and pass ad-hoc signing on the command line
(see the second build command below). The app runs, but macOS refuses to
register a root helper from an ad-hoc signed app, so you will not see CPU
and memory of system processes and cannot quit them.

## Build

With a team:

```bash
xcodebuild -project TaskCtrl.xcodeproj -scheme TaskCtrl -configuration Debug -derivedDataPath build build
```

Without a team:

```bash
xcodebuild -project TaskCtrl.xcodeproj -scheme TaskCtrl -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

Or open `TaskCtrl.xcodeproj` in Xcode, pick the `TaskCtrl` scheme and press Run.

## Run

```bash
open build/Build/Products/Debug/TaskCtrl.app
```

To restart after a rebuild, quit the running copy first:

```bash
pkill -x TaskCtrl; open build/Build/Products/Debug/TaskCtrl.app
```

## Permissions the app asks for

Both are optional; the app works without them and says what is missing.

- **Privileged helper.** Shows CPU and memory of processes owned by the system
  and other users, and lets you quit them. Install it from
  TaskCtrl › Settings (⌘,) › Privileged helper, then allow TaskCtrl in
  System Settings › General › Login Items & Extensions. It needs a build
  signed with a team. Remove it from the same Settings pane.
- **Full Disk Access.** Without it a disk scan skips protected folders and
  the totals are incomplete. Grant it in System Settings › Privacy & Security ›
  Full Disk Access; the Disk Space tab has a button that opens that pane.

## Project layout

| Path | What is in it |
| --- | --- |
| `project.yml` | The project definition. `TaskCtrl.xcodeproj` is generated from it. |
| `CHANGELOG.md` | What changed in each release. |
| `scripts` | Cutting a release, and drawing the app icon. |
| `.github/workflows` | What GitHub runs to build and publish a release. |
| `TaskCtrl/App` | App entry point and the sidebar. |
| `TaskCtrl/Features` | One folder per tab: the views. |
| `TaskCtrl/Monitoring`, `Disk`, `Network`, `Startup`, … | Models and samplers behind the tabs. |
| `TaskCtrl/Helper` | The app's side of the helper: install, status, XPC client. |
| `TaskCtrl/Support/PrivateAPI.h` | Declarations of the undocumented system functions used for sensors. |
| `TaskCtrl/Resources` | The launch daemon plist that gets copied into the app bundle. |
| `Helper` | The root helper, a command line tool embedded in the app. |
| `Shared` | Code compiled into both the app and the helper. |

## Adding things

- **A new source file.** Put it anywhere under `TaskCtrl/` (or `Helper/`,
  `Shared/`), then run `xcodegen generate`. Folders are picked up whole, so
  nothing else needs editing. Commit the regenerated `TaskCtrl.xcodeproj`
  together with the file.
- **A new tab.** Add a case to the sidebar enum in `TaskCtrl/App/RootView.swift`,
  give it a symbol and a view there, and put the view in a new folder under
  `TaskCtrl/Features`.
- **A change to the app icon.** The icon is drawn in code. Edit
  `scripts/make-icon.swift` and run `swift scripts/make-icon.swift`; it rewrites
  every size in `TaskCtrl/Resources/Assets.xcassets`. Commit the images with it.
- **A build setting.** Change `project.yml` and regenerate. Do not edit the
  Xcode project by hand: the next `xcodegen generate` overwrites it.
- **A new call to the helper.** Declare it in `Shared/HelperProtocol.swift`,
  implement it in `Helper/main.swift`, call it through
  `TaskCtrl/Helper/HelperClient.swift`, and raise the helper version in
  `Shared/HelperProtocol.swift` so that installed copies are reported as outdated.

## Releasing

Versions follow `major.minor.patch`. The version number lives in `project.yml`
as `MARKETING_VERSION`.

1. Describe the release in `CHANGELOG.md` under a new `## <version>` heading
   and commit it.
2. Run the release script with the new version:

   ```bash
   scripts/release.sh 0.2.0
   ```

The script sets the version, commits, makes the tag `v0.2.0` and pushes it.
The tag starts a build on GitHub, which publishes `TaskCtrl-0.2.0.zip` and its
checksum on the Releases page, with the changelog section as the notes. The
build takes a few minutes; its progress is on the repository's Actions page.

## Notes

- The app is not sandboxed: reading other processes and scanning the whole
  disk are not possible inside the sandbox. It cannot go on the Mac App Store
  as it is.
- Sensor readings come from undocumented system interfaces and may stop
  working after a macOS update.
