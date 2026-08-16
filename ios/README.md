# Slowmail (iOS)

A letter app. You write, it waits for the next collection, it travels for as
many days as the distance deserves, and it lands in one delivery the morning it
arrives. There is no typing indicator, no read receipt, and no way to know
whether the other person has opened it.

## Layout

| Path | What it is |
| --- | --- |
| `Packages/Sources/SlowmailCore` | Models, the postal calendar, the `MailStore` seam, and an in-memory post office that enforces the same rules the server does. |
| `Packages/Sources/SlowmailUI` | Every screen. Presentational views take plain values; `AppModel` is the only thing that talks to a store. |
| `Packages/Sources/Screenshots` | Renders every screen to PNG with no simulator. |
| `Packages/Tests/SlowmailCoreTests` | 22 tests over the rules that make this app what it is. |
| `App` | A `@main` shell, thin on purpose. |

## Building without Xcode

This machine has the Command Line Tools but no Xcode, so there is no iOS SDK,
no simulator, and no `xcodebuild`. Everything below still works, because the
packages declare macOS 14 alongside iOS 17 and SwiftUI compiles against the
macOS SDK.

```sh
./Scripts/test.sh          # build + 22 tests
./Scripts/screenshots.sh   # 27 PNGs into ./Screenshots
xcodegen generate          # produces Slowmail.xcodeproj when Xcode is available
```

`Scripts/env.sh` explains the extra linker flags: swift-testing ships inside the
Command Line Tools in two directories SwiftPM does not search by default. Delete
those flags once Xcode is installed.

## What the screenshots do and do not prove

`ImageRenderer` rasterises a SwiftUI tree directly, which is enough to check
layout, spacing, colour, and wrapping by eye. Two limits are worth knowing:

- **No app lifecycle runs.** `.task` and `.onAppear` never fire, so a view that
  loads its own data renders blank. Screens are therefore built from plain
  values, with containers doing the loading. `ScrollView` and `TextEditor` are
  backed by platform views that need a real window and render empty or as a
  placeholder glyph; `\.isRasterising` in the environment tells those two spots
  to lay out flat instead.
- **Dynamic Type is not verified.** macOS ignores `dynamicTypeSize` entirely — a
  `.body` label measures 18×16pt at `.large` and at `.accessibility5` alike — so
  an accessibility-text variant would render byte-identical to the light one and
  report success no matter what the layout did. The `narrow` variant (320pt) is
  the honest substitute: it exercises the same wrapping and truncation failures.
  Real Dynamic Type layout is unverified until this runs on a simulator.

## Rules the code holds to

- **Nothing inbound is visible before it lands.** `MockMailStore` filters on the
  clock; the server enforces it with row-level security. No view can reach past
  either.
- **Collection is irreversible.** A letter can be fetched back until five
  o'clock. After that it belongs to the post.
- **Time is described in days.** The only clock time the app ever shows is the
  collection deadline, because that is the one a person can act on. Arrivals are
  "Thursday 20 August", never "2:14pm".
