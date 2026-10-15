# Xcode setup: separate development and production ingest keys

This is a recipe for keeping a development key and a production key out of
your source, switching between them by build configuration, and keeping test
and preview runs out of your real data. The ingest key (`gt_live_...`) is
publishable and safe to ship in a build (see "About your ingest key" in the
README). The point here is not secrecy. It is that debug builds should write
to a development game and release builds to the production one, and that a
fresh checkout should build without a key committed to the repository.

Proven on Xcode 27.0 (build 27A266a), macOS target, by building a throwaway
project in both configurations and reading the key back out of each built
bundle. The same build settings apply to iOS targets.

## 1. Two keys in an ignored xcconfig

Create `Config/Local.xcconfig` and add it to `.gitignore`:

```
RAVENSIGHT_INGEST_KEY_DEBUG = gt_live_your_development_key
RAVENSIGHT_INGEST_KEY_RELEASE = gt_live_your_production_key
```

```
# .gitignore
Config/Local.xcconfig
```

Commit a copy with placeholders as `Config/Local.example.xcconfig`, so a
teammate knows which names to fill in:

```
RAVENSIGHT_INGEST_KEY_DEBUG = gt_live_replace_with_your_development_key
RAVENSIGHT_INGEST_KEY_RELEASE = gt_live_replace_with_your_production_key
```

Add two tracked xcconfig files that pick one of them. The `#include?` form
(with the question mark) does not fail when `Local.xcconfig` is missing, so
CI and fresh clones still build:

```
// Config/Debug.xcconfig
#include? "Local.xcconfig"
RAVENSIGHT_INGEST_KEY = $(RAVENSIGHT_INGEST_KEY_DEBUG)
```

```
// Config/Release.xcconfig
#include? "Local.xcconfig"
RAVENSIGHT_INGEST_KEY = $(RAVENSIGHT_INGEST_KEY_RELEASE)
```

In the project's Info tab, set the project-level Configurations so Debug uses
`Debug.xcconfig` and Release uses `Release.xcconfig`. A key written
with `//` anywhere in a value would be read as a comment; ingest keys contain
none, but keep that in mind for other values.

## 2. An explicit Info.plist template

Arbitrary `INFOPLIST_KEY_*` build settings do not reach the generated plist.
Xcode only maps the keys it knows about. On the probe, an
`INFOPLIST_KEY_RAVENSIGHT_TEST` setting built cleanly and never appeared in
the built `Info.plist`. Use a real plist file as a template instead.

Create `App/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>RAVENSIGHT_INGEST_KEY</key>
	<string>$(RAVENSIGHT_INGEST_KEY)</string>
</dict>
</plist>
```

Then in the target's Build Settings set `INFOPLIST_FILE` to `App/Info.plist`.
You can leave `GENERATE_INFOPLIST_FILE` on `YES`: Xcode merges your template
with the keys it generates, so you only list your own. The probe used exactly
that combination, and the built plist had both.

## 3. Read the key at startup

```swift
import Foundation
import Ravensight

enum RavensightBoot {
    /// The key baked into this build, or nil when the build has none
    /// (a clone without Local.xcconfig, or an unexpanded placeholder).
    static var ingestKey: String? {
        guard
            let key = Bundle.main.object(forInfoDictionaryKey: "RAVENSIGHT_INGEST_KEY") as? String,
            key.hasPrefix("gt_live_")
        else { return nil }
        return key
    }

    static func start() {
        let env = ProcessInfo.processInfo.environment

        // Unit and UI tests: the process is hosted by XCTest.
        if env["XCTestConfigurationFilePath"] != nil { return }
        // SwiftUI previews run your App code in a preview process.
        if env["XCODE_RUNNING_FOR_PREVIEWS"] == "1" { return }

        guard let key = ingestKey else { return }
        Ravensight.start(ingestKey: key)
    }
}
```

Call `RavensightBoot.start()` where you would have called `Ravensight.start`
(your `App` initializer). Two details from the probe: a clone without
`Local.xcconfig` builds and puts an empty string in the plist, which is why
the `gt_live_` prefix check is there, and the check also catches a literal
`$(RAVENSIGHT_INGEST_KEY)` left in a plist that was never processed. With no
key the SDK is simply never started, so no events are queued or sent.

Skipping `start` under XCTest and previews means a test run or a canvas
refresh never opens a session or writes to your development game. If a test
needs the SDK, start it in that test with a key you pass explicitly.

## 4. Check the built bundle

After a build, confirm which key a given configuration really shipped. This
prints the line with the value masked to its prefix and last four characters:

```bash
plutil -p "$APP/Contents/Info.plist" | grep RAVENSIGHT | sed -E 's/(gt_live_).*(.{4}")/\1...\2/'
```

On iOS the plist is at `$APP/Info.plist`. Plain `plutil -p <app>/Info.plist
| grep RAVENSIGHT` also works when you are alone at your own terminal.
Expect the development key from a Debug build and the production key from a
Release build, and an empty value if `Local.xcconfig` was absent.

The doctor does the same check, including that the key looks like an ingest
key and that Debug and Release differ. It needs doctor 0.4.2 or newer:

```bash
npx ravensight-doctor --bundle path/to/YourApp.app
```

To tell the doctor that the key in your source is supplied by the build and
is not a missing literal, set this in `ravensight.config.json`:

```json
{
  "ingestKey": { "source": "build" }
}
```

## Troubleshooting

* The plist value is the literal text `$(RAVENSIGHT_INGEST_KEY)`: the file is
  being copied as a resource instead of used as `INFOPLIST_FILE`, or
  "Process Info.plist" is off. Check the build setting, and that the plist is
  not also in Copy Bundle Resources.
* The value is empty: `Local.xcconfig` is missing or has the wrong variable
  names, or the project-level configuration is not set to your xcconfig.
* A change to an xcconfig is not seen: clean the build folder once.
