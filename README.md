# Ravensight for iOS and macOS

Official Swift SDK for [Ravensight](https://ravensight.io) player analytics.

Sessions, batched events, an offline queue, rate limit handling and a server
side kill switch, in one Swift package and no third party dependencies.

* API base: `https://api.ravensight.io/api/v1`
* Docs: https://ravensight.io/docs/
* iOS 15 or newer, macOS 12 or newer
* Swift Package Manager only, URLSession transport, zero dependencies

## Verification status

The protocol logic in `Sources/Ravensight/Core` is
written and reviewed against the live API contract, and it is deliberately
free of any URLSession dependency so it can be tested on its own. It has
**not** yet been verified inside a shipping app.

Treat it as pending on device verification: read the code before you ship it
in a release build, and please open an issue with anything you hit. The
JavaScript, Godot and Unity SDKs speak the same protocol.

## Install

Swift Package Manager, add by URL:

```
https://github.com/Reality-Software-Entertainment/ravensight-ios.git
```

In Xcode: File > Add Package Dependencies, paste the URL above, add the
`Ravensight` library to your app target.

Or add it to your `Package.swift` yourself:

```swift
dependencies: [
    .package(
        url: "https://github.com/Reality-Software-Entertainment/ravensight-ios.git",
        from: "0.1.0"
    ),
],
targets: [
    .target(name: "YourGame", dependencies: ["Ravensight"]),
]
```

## Quickstart

Call `start` once, early (your `App` init or
`application(_:didFinishLaunchingWithOptions:)`), with your publishable
ingest key (`gt_live_...`) from the Ravensight dashboard:

```swift
import Ravensight

Ravensight.start(ingestKey: "gt_live_your_key")
```

That is the whole setup. The SDK reads the server kill switch, opens a
session, starts flushing on a timer and hooks the app lifecycle so queued
events are flushed when the player leaves.

Then track from anywhere:

```swift
Ravensight.track("level_completed", data: [
    "level": 3,
    "deaths": 2,
    "seconds": 41.5,
])
```

Prefer full control? Build a configuration instead:

```swift
var configuration = RavensightConfiguration(ingestKey: "gt_live_your_key")
configuration.gameVersion = "1.2.0"
configuration.flushInterval = 5
Ravensight.start(configuration)
```

## API

Everything game code needs is static on `Ravensight`:

| Call | What it does |
| --- | --- |
| `Ravensight.start(ingestKey:)` | Boots the SDK. Also takes a full `RavensightConfiguration`. |
| `Ravensight.track(name, data:)` | Queues an event. `data` is optional. Returns false when tracking is off. |
| `Ravensight.flush(completion:)` | Sends queued events now. The completion fires on the main queue. |
| `Ravensight.submitFeedback(message, category:, rating:, completion:)` | Posts player feedback. Reports a `RavensightError` on failure. |
| `Ravensight.fetchSuggestions(completion)` | EXPERIMENTAL. AI generated design suggestions for your game. |
| `Ravensight.setEnabled(_:)` | Local opt in and opt out for a privacy toggle. |
| `Ravensight.isReady` | True once a session exists. |
| `Ravensight.shared` | The underlying `RavensightClient` for anything else. |

Event values can be strings, numbers, bools, nulls, nested dictionaries or
arrays (`[String: Any]`). Anything else (a `Date`, a custom struct) is
stringified rather than dropped, so a stray value cannot poison a batch.

Feedback, from anywhere:

```swift
Ravensight.submitFeedback("The boss fight drags", category: "balance", rating: 3) { result in
    if case .failure(let error) = result {
        print("feedback rejected: \(error.code)")
    }
}
```

## Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `apiUrl` | `https://api.ravensight.io/api/v1` | Only change this if you self host. `/api/v1` is appended when omitted. |
| `ingestKey` | none | Your publishable `gt_live_...` key. |
| `gameVersion` | nil | Nil uses your app bundle's version string. |
| `flushInterval` | `5` | Seconds between automatic flushes. `0` flushes only on demand. |
| `maxQueueSize` | `500` | Offline queue cap. Oldest events are dropped first. |
| `requestTimeout` | `15` | Per request timeout in seconds. |
| `trackLifecycleEvents` | on | Sends `game_started`, `game_paused`, `game_resumed`, `game_exited`. |
| `verboseLogging` | off | Logs SDK activity to the console. |

## About your ingest key

The `gt_live_...` key is publishable. It is safe to ship inside a build: it
can only open sessions and read the tracking kill switch. It cannot read
analytics, read feedback or touch your account. Rotate it from the dashboard
at any time.

## How delivery works

* **Batching.** Up to 50 events per request, the server hard limit. A flush
  keeps sending batches until the queue drains.
* **Offline queue.** Events accumulate up to `maxQueueSize`. Past that the
  oldest are dropped so the newest are always kept.
* **Never dropped on failure.** Events leave the queue only after the server
  answers `202`.
* **Session expiry.** A `401` clears the session, opens a new one and re
  sends the same batch.
* **Rate limits.** A `429` honors `Retry-After` in seconds. With no such
  header the SDK backs off exponentially from 10 seconds to a 5 minute
  ceiling. The queue is held, never discarded.
* **Oversize batches.** A `400` halves the batch and retries down to a single
  event. An event still rejected on its own is dropped so it cannot block
  everything behind it.
* **Kill switch.** `GET /settings` is read once at boot. If the server has
  tracking off for your game, the queue is cleared and nothing is sent.

Flushes happen on the timer, when the app resigns active, when it enters the
background and on termination. The background flush runs under a
`UIApplication` background task assertion on iOS, and under a `ProcessInfo`
activity that defers sudden termination on macOS. Both are best effort: a
process that exits immediately can still lose the last batch, since the queue
lives in memory only. The SDK deliberately does not use `BGTaskScheduler`;
flush at points you control (the end of a level) if the last events matter to
you.

## Concurrency contract

Every public call is non blocking and safe from any thread. All SDK state is
owned by one private serial dispatch queue; public methods forward onto it
and return immediately. The read only properties (`isReady`,
`isTrackingEnabled`, `isEnabled`, `queuedEventCount`) read a lock protected
snapshot and never wait on network work. Completion handlers are always
delivered on the main queue. The SDK never blocks the main thread and never
throws into game code; tracking failures are retried quietly and surfaced
only through the optional verbose log.

## Architecture

```
Sources/Ravensight/
  Core/                              no URLSession dependency
    RavensightCore.swift             the whole protocol as a pure state machine
    RavensightTransport.swift        transport protocol plus request and response
  RavensightClient.swift             serial queue driver, timers, lifecycle
  Ravensight.swift                   the static facade
  RavensightConfiguration.swift      configuration and error types
  RavensightLifecycle.swift          UIKit and AppKit lifecycle hooks
  RavensightURLSessionTransport.swift  the production transport
```

`RavensightCore` is a pure, clock injected state machine: it never performs
I/O and never reads a clock. A driver asks it what to do next, performs the
request it was handed and feeds the response back, passing the current time
into every call. That is what makes the protocol testable without a network:
hand it fake responses and a fake clock and you can drive every retry path in
a plain XCTest.

```bash
swift test
```

## Device id and privacy

The SDK generates a random device id on first run and stores it in
`UserDefaults` under `ravensight_device_id`. No hardware identifier,
advertising id, IP based fingerprint or personal data is collected by the SDK
itself. Only the events you choose to send leave the device.

`Ravensight.setEnabled(false)` stops all sending and discards anything still
queued, so an opt out does not leave player data sitting in memory.

## License

MIT. Copyright 2026 Reality Software Entertainment.
