# Ravensight for iOS and macOS

Official Swift SDK for [Ravensight](https://ravensight.io) player analytics.

Sessions, batched events, an offline queue (optionally persisted), rate
limit handling, a server side kill switch, player feedback and Player
Reports with screenshots, in one Swift package and no third party
dependencies.

* API base: `https://api.ravensight.io` (the SDK appends `/api/v1`)
* Docs: https://ravensight.io/docs/
* Privacy: a random per-install device id, no advertising identifier, a saved player opt-out (`Ravensight.setTrackingEnabled(false)`), a stop that covers everything (`Ravensight.stopAllTelemetry()`), a reset (`Ravensight.resetDeviceId()`), a bundled privacy manifest, no tracking permission prompt needed. What your store label can say: https://ravensight.io/docs/#privacy-label
* iOS 15 or newer, macOS 12 or newer
* Swift Package Manager only, URLSession transport, zero dependencies

## Verification status

What has been run, and what has not:

* `swift build` and `swift test` on macOS (Swift 6.4, Xcode 27.0): 127
  tests, the protocol core with a fake clock and the client with a fake
  transport, a fake clock, an isolated `UserDefaults` suite and a temporary
  queue directory.
* `xcodebuild test` on the iOS Simulator (iPhone 17, iOS 27.0, Xcode 27.0):
  130 tests, the same 127 plus three `UIImage` screenshot encoding tests
  (size limit, Retina pixels kept, scaled to fit 1600 pixels), which only
  build where UIKit exists.
* `Examples/NarrativeSample`: `swift build` and `swift test` on macOS (8
  tests), and its tests under `xcodebuild test` on the same iOS Simulator.
  The SwiftUI executable has been built on macOS, not launched against a
  live server. The queries in its `QUERIES.md` were run against a local
  ClickHouse with the events table's schema and a small hand made dataset,
  not against production data.
* Player Reports were tested against a stub transport that answers the way
  the server's report routes do (`src/routes/v1/playerReports.js`). A
  real upload to report storage has not been run from this SDK.
* The package builds in Swift 5 language mode (tools version 5.9). Its
  thread safety is by design, not proven by the compiler: the client is
  `@unchecked Sendable`, and the state added in 0.3.0 (the persisted queue,
  the delivery counters, the report steps) lives on the client's serial
  work queue and under its snapshot lock, like the rest. The 0.2.0 release
  was built from a Swift 6 language mode app with no diagnostics; that has
  not been repeated for 0.3.0. The lifecycle tests call the client's handlers
  directly; the UIKit notifications that drive them in an app, the
  background task assertion and a real swipe from the app switcher have not
  been exercised.
* It has **not** yet been verified inside a shipping app or on a physical
  device. Read the code before you ship it in a release build, and please
  open an issue with anything you hit.

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
        from: "0.3.0"
    ),
],
targets: [
    .target(name: "YourGame", dependencies: ["Ravensight"]),
]
```

## Quickstart

Call `start` once, early, from the main thread (your `App` init or
`application(_:didFinishLaunchingWithOptions:)`), with your publishable
ingest key (`gt_live_...`) from the Ravensight dashboard:

```swift
import Ravensight

Ravensight.start(ingestKey: "gt_live_your_key")
```

That is the whole setup. The SDK queues `game_started`, reads the server
kill switch, opens a session, sends the queue in batches every 5 seconds and
hooks the app lifecycle so queued events are flushed when the player leaves.

Then track from anywhere:

```swift
Ravensight.track("level_completed", data: [
    "level": 3,
    "deaths": 2,
    "seconds": 41.5,
])
```

`track` only adds the event to the queue, and its return value means
exactly that: `true` is "queued", not "delivered". Nothing is sent per
call: the queue goes out in batches of up to 50 on the flush timer, as soon
as 50 events are waiting, on `flush()`, when the app goes to the background
and when it quits. See "Queued versus delivered" for how to know what the
server has.

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
| `Ravensight.track(name, data:)` | Queues an event. `data` is optional. Returns true when the event was queued (not delivered), false when nothing was queued (tracking off, stopped, or not started). |
| `Ravensight.flush(completion:)` | Sends queued events now. The completion fires on the main queue. |
| `Ravensight.submitFeedback(message, category:, rating:, completion:)` | Posts player feedback text. Reports a `RavensightError` on failure. |
| `Ravensight.submitReport(category:, message:, screenshot:, metadata:, completion:)` | Submits a Player Report, with a screenshot only if you pass one. See "Player Reports". |
| `Ravensight.fetchSuggestions(completion)` | EXPERIMENTAL. AI generated design suggestions for your game. |
| `Ravensight.setTrackingEnabled(_:)` | The player's lasting choice. Saved, works before `start`. Does not stop a synthetic session. |
| `Ravensight.stopAllTelemetry()` / `resumeTelemetry()` | Stops everything now, synthetic sessions included, and saves nothing. |
| `Ravensight.resetDeviceId()` | Saves a new durable identity and returns it. Never returns a synthetic id. |
| `Ravensight.deviceId` | The durable device id, safe to mirror. Never a synthetic id. |
| `Ravensight.playtestDeviceId` / `isSynthetic` | The id a synthetic (playtest) run sends, and whether this run is one. |
| `Ravensight.stats` | `queued`, `delivered`, `pending`, `droppedEvents`, `restored`, `lastDelivery`. |
| `Ravensight.isOptedOut` | True when the player turned tracking off. |
| `Ravensight.statusReason` | Why the SDK is not sending, or nil when it is ready. |
| `Ravensight.sessionToken` | The current session token, nil until a session opens. |
| `Ravensight.isReady` | True once a session exists. |
| `Ravensight.feedbackCategories` | The six feedback categories the server accepts. |
| `Ravensight.shared` | The underlying `RavensightClient` for anything else (`setEnabled`, `onStatusChange`, `onFlush`, `lastDelivery`, `isPlaytest`). |

`Ravensight.setEnabled(_:)` still exists but is deprecated: it is the
runtime switch below, not saved, and it was never a safe player opt-out.
Called before `start`, its value is held for this process and applied when
`start` runs (with a console line pointing at `setTrackingEnabled`), so a
0.1 integration that called it first keeps its behaviour.

Event values can be strings, numbers, bools, nulls, nested dictionaries or
arrays (`[String: Any]`). Anything else (a `Date`, a custom struct) is
stringified rather than dropped, so a stray value cannot poison a batch.

Feedback, from anywhere. The category is one of `bug`, `suggestion`,
`complaint`, `praise`, `playtest` or `other`, and the rating is 1 to 5, or 0
to leave it out. Anything else fails locally with `invalid_category` or
`invalid_rating` and no request is made:

```swift
Ravensight.submitFeedback("The boss fight drags", category: "suggestion", rating: 3) { result in
    if case .failure(let error) = result {
        print("feedback rejected: \(error.code)")
    }
}
```

## Configuration

| Field | Default | Meaning |
| --- | --- | --- |
| `ingestKey` | none | Your publishable `gt_live_...` key. |
| `apiUrl` | `https://api.ravensight.io` | Only change this if you self host. Whitespace and trailing slashes are trimmed and `/api/v1` is appended, so both the bare host and the `/api/v1` form work. Empty means the default. |
| `enabled` | `true` | The game's runtime switch, never saved. `false` means no request of any kind until `shared?.setEnabled(true)`. A saved player opt-out wins over `true`. |
| `gameVersion` | nil | Nil uses your app bundle's version string. |
| `flushInterval` | `5` | Seconds between automatic batch sends. `0` sends only at 50 queued, on `flush()`, on background and on quit. |
| `maxQueueSize` | `500` | Offline queue cap. Oldest events are dropped first. |
| `persistQueue` | `false` | Keeps the queue in a file under Application Support so it survives a force quit. See "Persisted queue". |
| `requestTimeout` | `15` | Per request timeout in seconds. |
| `trackLifecycleEvents` | `true` | Sends `game_started` and `game_exited` automatically. |
| `trackPauseEvents` | `false` | Also sends `game_paused` and `game_resumed` (iOS background and foreground, macOS focus). |
| `sessionTimeout` | `1800` | iOS. Seconds in the background after which the session ends. |
| `playtestToken` | nil | Ravensight Playtest token. Nil reads `RAVENSIGHT_PLAYTEST_TOKEN` from the launch environment. |
| `playtestRunId` | nil | Ravensight Playtest run id. Nil reads `RAVENSIGHT_PLAYTEST_RUN_ID`. |
| `verboseLogging` | `false` | Logs SDK activity to the console. |

## Automatic events

With `trackLifecycleEvents` on (the default) the SDK sends exactly two
events of its own:

* **`game_started`**, once per session, queued at the moment `start()` runs
  so it is first in the queue and carries the real start time. It is never
  queued while the SDK is disabled or the player has opted out; if tracking
  is turned on later in the run, it is queued then, once.
* **`game_exited`**, once, when the app terminates normally. The quit is
  held for at most 1.5 seconds while the last batch leaves.

`game_paused` and `game_resumed` are only sent when you set
`trackPauseEvents = true`. On macOS, losing focus is not an exit and sends
nothing by default (the queue is flushed).

### The mobile rule (iOS)

iOS rarely tells an app it is being closed: a player swipes it away from
the app switcher, or the system ends it, while it is suspended in the
background. So on iOS a session ends by time in the background:

* **Going to the background**: the SDK records the time, flushes the queue
  inside a background task, and saves a small marker (the session token,
  its expiry, and when the player left) in `UserDefaults` under
  `ravensight_background_marker`. No event is sent.
* **Coming back within `sessionTimeout`** (30 minutes by default): the
  marker is deleted, the session carries on and nothing is sent.
* **Coming back after `sessionTimeout` or more**: the old session gets its
  `game_exited`, stamped with the time the player left, under its own
  token; then a new session opens with a fresh `game_started`.
* **A cold launch that finds a marker** (the app was swiped away or ended
  while in the background): before anything else, the SDK sends that
  session's `game_exited`, stamped with the time the player left, under
  that session's token, then deletes the marker whatever the answer. One
  attempt, no retry. It is skipped when the player has opted out or the
  session has expired.
* **A launch into the background** (background fetch, a silent push):
  `game_started`, the settings check and the session wait until the app
  first becomes active, and `game_started` is stamped at that moment. A
  scene based app can report the background state while it launches, so it
  usually takes this path for the fraction of a second before its first
  scene is active. A marker left by an earlier swipe is still reported
  first when the app becomes active.

## Opting out, stopping and resetting

There are three controls, and they do different things:

| Call | Saved? | Normal session | Synthetic (playtest) session |
| --- | --- | --- | --- |
| `setTrackingEnabled(false)` | Yes, before it returns | Queue cleared, no request of any kind, on this launch and every later one. | Ignored (one console line). The run carries on. Nothing is saved. |
| `stopAllTelemetry()` | No | Timer stopped, queue cleared (and the persisted queue file deleted), `track` returns false, feedback and reports refused with `disabled`, no request of any kind. The next launch starts normally. | The same: the run stops sending. |
| `resetDeviceId()` | Yes | A new durable id is saved and returned, the queue is cleared and the session ends; the next session opens under the new id. | A new durable id is saved for the next normal launch and returned. The run keeps sending as `pt-<runId>`, untouched. |

`resumeTelemetry()` undoes `stopAllTelemetry()` for the rest of the run. In
a normal session a saved opt-out still wins, so nothing is sent while the
player has opted out. `stopAllTelemetry` and `resumeTelemetry` are the same
switch as `RavensightConfiguration.enabled` and `setEnabled(_:)`; the new
names say what it does.

`setTrackingEnabled` is the player's choice. It is saved in `UserDefaults`
(`ravensight_tracking_opt_out`) before the call returns, works before
`start()`, and wins over `enabled = true` on every later launch. A
synthetic session is driven by an agent on a test build, not by a player,
so it ignores the player's opt-out; when a synthetic run must go quiet,
call `stopAllTelemetry()`.

### Privacy sample

```swift
import Ravensight

// The "Analytics" switch in your settings screen.
func setAnalytics(_ on: Bool) {
    // Saved: holds on this launch and every later one, in a normal session.
    Ravensight.setTrackingEnabled(on)
    if !on {
        // Also stop right now, synthetic (playtest) session included. Not
        // saved; the saved opt-out above is what holds next launch.
        Ravensight.stopAllTelemetry()
    } else {
        Ravensight.resumeTelemetry()
    }
}

// A "Forget me" button.
func forgetMe() {
    // Always a durable id, never a synthetic one: safe to store yourself.
    let newId = Ravensight.resetDeviceId()
    UserDefaults.standard.set(newId, forKey: "my_analytics_id_mirror")
}

// What the app sees in each kind of session.
func describeIdentity() -> String {
    if Ravensight.isSynthetic {
        // deviceId is still the durable id (empty on an install that has
        // never run a normal session); the run sends playtestDeviceId.
        return "synthetic run \(Ravensight.playtestDeviceId ?? ""), durable id \(Ravensight.deviceId)"
    }
    return "player \(Ravensight.deviceId)"
}
```

In a normal session `setAnalytics(false)` saves the opt-out and stops; the
next launch makes no request at all. In a synthetic session the saved
opt-out is ignored, but `stopAllTelemetry()` stops the run, so the switch
still means "nothing more is sent".

## Telling players

You do not need a permission prompt, but saying what the game sends is good
manners. A paragraph your game can show, in a settings screen or on its
store page:

> This game sends anonymous gameplay events (what happens in the game, never
> who you are) to Ravensight so we can improve it. You can turn this off in
> Settings at any time.

The toggle behind "turn this off" is the `setAnalytics` example in the
privacy sample above, and "Forget me" is `resetDeviceId`.

## Levels and deaths

Ravensight reads deaths, level starts and level completions from event
names (`player_died`, `level_start`, `level_complete`). When a name would be
read wrongly, set `rs_kind` in the event data to `level_start`,
`level_complete`, `death` or `none`, and it is read before the name. `none`
opts an event out, so `checkout_started` is not counted as a level start. An
unknown value falls through to the name match. Keys that start with `rs_`
are reserved for Ravensight.

```swift
Ravensight.track("boss_phase_begin", data: ["level": "castle", "rs_kind": "none"])
Ravensight.track("run_over", data: ["level": "castle", "rs_kind": "death"])
```

## Startup outcome

`Ravensight.statusReason` (and `RavensightClient.statusReason`) says why the
SDK is not sending, or is nil when it is ready. Set
`Ravensight.shared?.onStatusChange` to be told on the main queue when it
changes.

| Reason | Meaning |
| --- | --- |
| `disabled` | `enabled` is false, or the player opted out. Nothing is sent. |
| `invalid_key` | The server refused the ingest key (`401`, or a `403` other than the ones below). Automatic sending stops for the run; events keep queueing (the cap applies) and an explicit `flush()` makes one more attempt. |
| `tracking_disabled` | The kill switch: `GET /settings` said tracking is off, or any endpoint answered `403 tracking_disabled`. The queue is cleared and nothing more is sent this run. |
| `offline` | The network failed or timed out. The SDK backs off from 10 seconds, doubling to 5 minutes, and keeps the events. |
| `rate_limited` | A `429`. The SDK waits exactly `Retry-After` and keeps the events. |
| `session_failed` | The server failed to open a session (a `5xx`), or a playtest token was refused or arrived without a run id. |
| `playtest_job_closed` | The playtest job this run belongs to has finished. Nothing more is sent this run. |

`invalid_key`, `tracking_disabled` and the playtest stops are printed once
to the console, whatever `verboseLogging` says. For a refused key the line
is: `Ravensight: ingest key refused (invalid_key), sending stopped for this
run. Check your gt_live_ key.`

## About your ingest key

The `gt_live_...` key is publishable. It is safe to ship inside a build: it
can open sessions, read the tracking kill switch and read this game's design
suggestions. It cannot read analytics, read feedback or touch your account.
Rotate it from the dashboard at any time.

## How delivery works

* **Batching.** Up to 50 events per request, the server hard limit, on the
  flush timer, at 50 queued, on `flush()`, on background and on quit. A
  flush keeps sending batches until the queue drains.
* **Offline queue.** Events accumulate up to `maxQueueSize`. Past that the
  oldest are dropped so the newest are always kept.
* **Kept on failure.** An event leaves the queue when the server answers
  `202`, when the queue cap pushes it out, when tracking is turned off, or
  when the server refuses it on its own (below). By default the queue lives
  in memory, so events still queued when the process dies are lost; turn on
  `persistQueue` to keep them (see "Persisted queue").
* **Session expiry.** A `401` on a batch clears the session, opens a new one
  and resends the same batch, at most twice in a row before backing off.
* **Answers that no longer apply.** A session or batch answer that arrives
  after `resetDeviceId`, an opt-out or `setEnabled(false)` is ignored, so an
  old identity's session is never adopted and newer events are never
  removed by an older batch's `202`.
* **Rate limits.** A `429` honors `Retry-After` in seconds, on the settings
  check as on every other request, and so does a `503`. With no such header the SDK backs off exponentially from 10
  seconds to a 5 minute ceiling. The queue is held.
* **Oversize batches.** A `400` halves the batch and retries down to a single
  event. An event still rejected on its own is dropped, counted and logged
  once, so it cannot block everything behind it.
* **Kill switch.** `GET /settings` is read once at boot, and a `403
  tracking_disabled` from any endpoint has the same effect: the queue is
  cleared and nothing is sent for the rest of the run.

The background flush runs under a `UIApplication` background task
assertion on iOS. The quit flush holds the quit for at most 1.5 seconds on
both platforms. Both are best effort. The SDK deliberately does not use
`BGTaskScheduler`; flush at points you control (the end of a level) if the
last events matter to you.

## Queued versus delivered

`track` returning `true` means the event is in the queue. Delivery is a
separate fact, reported three ways:

* `Ravensight.stats` (and `client.stats`): `queued` (events accepted into
  the queue this run), `delivered` (events the server answered `202` for),
  `pending` (waiting now), `droppedEvents` (left the queue undelivered: the
  cap, a `400` on a single event, or discarded by an opt-out,
  `stopAllTelemetry`, `resetDeviceId`, the kill switch or a playtest stop),
  `restored` (loaded from the persisted queue), `flushes`, `sessions` and
  `lastDelivery`. Restored events were queued by an earlier launch, so they
  count in `restored` and, once sent, in `delivered`, but not in `queued`.
  Restored events older than 89 days, or beyond the file's 500, count in
  `droppedEvents`.
* `client.lastDelivery`: `.accepted`, `.failed(status:)` or `.offline`,
  with the time it happened.
* `client.onFlush`: called on the main queue with a
  `RavensightFlushOutcome` (`sent`, `status`, `error`, `pending`) after
  every request that carried events, and after a failed session open that
  held queued events back.

```swift
Ravensight.shared?.onFlush = { outcome in
    if outcome.succeeded {
        print("delivered \(outcome.sent), \(outcome.pending) still queued")
    } else {
        print("not delivered (status \(outcome.status), \(outcome.error ?? "")), will retry")
    }
}
```

## Persisted queue

With `persistQueue = true` the queue is mirrored to one JSON file under
Application Support (`Ravensight/queue-<key hash>.json`, excluded from
backups):

* at most 500 events, the newest, whatever `maxQueueSize` says;
* every write is atomic (a temporary file renamed over the old one);
* because writes are coalesced, events tracked in the last quarter of a
  second before a crash or a force quit may not be in the file yet;
* the file is read on the SDK's work queue right after the client is
  created, and each write is coalesced over a quarter of a second (a
  background, a quit and anything that empties the queue write at once);
  events from it go out under
  the session they were queued in while that session is still valid, and
  otherwise under the next session, with their original timestamps;
* it is deleted when the player opts out (also at launch, when a saved
  opt-out is found), on `stopAllTelemetry`, on `resetDeviceId` (before
  `start()` too, where every queue file is removed), on the kill switch,
  when the queue drains, and at launch when `persistQueue` is off. A client
  built with `enabled = false` leaves the file until it is enabled (then
  loads it) or stopped or opted out (then deletes it), so a stop before
  `start()` never lets `resumeTelemetry()` send an earlier launch's events;
* a synthetic (playtest) session never reads or writes it;
* events older than 89 days are not restored (the server ignores events
  older than 90 days).

It narrows the window in which events can be lost; it does not close it.
An event tracked a moment before a crash may not have been written yet.

## Player Reports

A Player Report is what a player writes about a problem, with optional
detail fields, developer chosen metadata and, only if you pass one, a
screenshot. It uses the server's report routes and shows up in the
dashboard's report inbox.

```swift
// A screenshot is sent only when you pass one. The SDK never captures
// the screen; capture it yourself, after the player chose to attach it,
// with anything private hidden.
// The session this attempt runs under, taken before submitting. A retry is
// only the same submission while the session is unchanged; nil (no session
// had opened yet) means do not retry.
let sessionAtSubmit = Ravensight.sessionToken
let report = Ravensight.submitReport(
    category: "bug",
    message: "The ferry never arrives",
    screenshot: capturedImage,          // UIImage? (iOS); nil for text only
    metadata: ["zone": "harbour", "attempt": 3, "hard_mode": true]
) { result in
    switch result {
    case .success(let receipt):
        print("report \(receipt.reportId ?? receipt.id) saved")
    case .failure(let error)
        where ["upload_failed", "report_processing"].contains(error.code) || error.status == 0:
        // Retry later, but only under the session it was submitted in.
        pendingReport = (report, sessionAtSubmit)
    case .failure(let error):
        print("report refused: \(error.code)")
    }
}

// Later, for example from a "Try again" button:
if let pending = pendingReport, let session = pending.1, session == Ravensight.sessionToken {
    Ravensight.submitReport(pending.0) { _ in }   // the same submission
} else {
    pendingReport = nil   // the session changed: a resubmission would be a new, separately charged report
}
```

On macOS (no UIKit) pass `screenshotData:` with JPEG, PNG or WebP bytes,
or leave it out for a text report.

What is sent: `POST /api/v1/reports` with the session token and a JSON body
(`clientId`, `message`, `category`, `context` from your metadata,
`capturedAt`, the optional `level`, `expected`, `steps` and `frequency`,
and for a screenshot `image`, `bytes` and `sha256`). A text report is
complete on that one request. A screenshot report then asks
`POST /reports/:id/upload` for a one-time upload form, uploads the bytes to
report storage as `multipart/form-data` (no key, session token or playtest
header goes to storage), calls `POST /reports/:id/finalize`, and checks
`GET /reports/:id` every 2 seconds until the server has processed the image.
The checks are bounded: at most 35 (about 70 seconds), then the report
fails with `report_processing`. Only `stopAllTelemetry`, an opt-out or the
kill switch ends them sooner, with `disabled`.

Limits, checked on the device before any request (the server checks them
again): a message of 1 to 500 characters; a category from
`feedbackCategories` (default `other`); metadata keys that start with a
letter and use letters, digits and underscores (at most 40 characters),
scalar values of at most 500 characters, at most 8 KB in all; a capture
time within the last day; a screenshot of at most 1,000,000 bytes and
4,000,000 pixels, a still JPEG, PNG or WebP. A `UIImage` is scaled to fit
1600 by 1600 and encoded as JPEG once, when the report is built.

Usage: a text report draws one shared usage event. A screenshot adds
20,000, reserved when the report is accepted.

Retries: the SDK makes one attempt per step and never retries a report on
its own, because a screenshot reserves usage. The `RavensightReport` value
fixes the `clientId`, the capture time and the screenshot bytes. The server
deduplicates a submission by `clientId` **within one session only**:

* Same value, same session token: the same submission. The server returns
  it and the SDK carries on from where it stopped. This is the only safe
  retry, and what the example above checks.
* Same value after the session changed (a `401`, the session timing out,
  `resetDeviceId`, a relaunch): the server sees a new submission. It is
  stored again, and a screenshot reserves another 20,001 usage events.

The server allows two upload attempts per submission and releases an
unfinished screenshot submission's reservation after 15 minutes. A
different message under the same `clientId` in the same session is refused
with `submission_conflict`.

Refusals: `disabled` while tracking is off (opted out, stopped, disabled or
switched off by the server), with no request. Local: `empty_message`,
`message_too_long`, `invalid_category`, `invalid_metadata`,
`invalid_report`, `invalid_capture_time`, `invalid_image`,
`image_too_large`. `no_session` when no session opened within 10 seconds.
From the server: `report_limit`, `event_limit`, `attachments_unavailable`
(send text instead), `feature_disabled`, `submission_conflict`,
`upload_limit`, `upload_closed`. `upload_failed` when the upload to storage
failed, `report_canceled`, and `report_processing` when the image was
still being checked after the last status check (submit the same value
again later to see the result). A `403 tracking_disabled` or
`playtest_job_closed` stops the SDK like any other endpoint.

`submitFeedback` stays as the lighter text only call (`POST /feedback`, a
message, a category and a rating).

## Session hand-off

`Ravensight.sessionToken` is the current session token, nil until a session
opens. If your game server also sends events for this player, pass the token
to it and have it open its session with `joinToken`, so server events land
in the player's session. The SDK never computes a session id itself.

## Playtest

A Ravensight Playtest run identifies itself with a token and a run id, from
`RavensightConfiguration.playtestToken` and `playtestRunId`, or else from
the `RAVENSIGHT_PLAYTEST_TOKEN` and `RAVENSIGHT_PLAYTEST_RUN_ID` launch
environment variables. On the Simulator, `xcrun simctl launch` passes a
variable through when you prefix it with `SIMCTL_CHILD_`; an automation
server can set it in the app's launch environment. With a token:

* the run sends the device id `pt-<runId>`, in memory only, exposed as
  `playtestDeviceId`. It is never saved and the saved id is never
  overwritten by it. `deviceId` keeps returning the durable id (empty on an
  install that has never run a normal session), so an app that mirrors
  `deviceId` never stores a synthetic id;
* every request carries `X-Ravensight-Playtest: <token>`;
* the saved player opt-out is ignored and `setTrackingEnabled` only logs a
  line. `resetDeviceId` saves a new durable id for the next normal launch
  and returns it; the run keeps its `pt-<runId>`. `stopAllTelemetry` stops
  the run;
* the persisted queue is not used;
* a token without a run id never runs as a real player: nothing is sent and
  the reason is `session_failed`;
* `403 playtest_job_closed` (reason `playtest_job_closed`) or `403
  invalid_playtest_token` (reason `session_failed`) stops the run and
  clears the queue.

`RavensightClient.isPlaytest` (also `isSynthetic`) says whether a token was
found. Leave both unset in a build for real players.

## What this SDK supports

| Platform surface | In this SDK |
| --- | --- |
| Events, sessions, batching, kill switch | Yes. |
| Feedback text (`POST /feedback`) | Yes: `submitFeedback`. |
| Player Reports with a screenshot | Yes, since 0.3.0: `submitReport`. A screenshot is sent only when you pass one; the SDK has no screen capture and no report form UI. |
| Playtest tagging | Yes: token and run id from the configuration or the launch environment, the `X-Ravensight-Playtest` header, `pt-<runId>` in memory. Not from command line arguments. |
| Player opt-out | Yes: `setTrackingEnabled`, saved. Plus `stopAllTelemetry` for a stop that also covers synthetic sessions. |
| Persisted queue | Yes, opt-in: `persistQueue`. |
| Journeys | Not in this SDK. There is no journey API here; when your Ravensight project has journeys enabled, the server builds them from the level events you track (see "Levels and deaths"). |
| Design suggestions | Experimental: `fetchSuggestions`. |
| Screen capture, a report form, crash reporting, push, purchases | Not in this SDK. |

## Narrative sample

`Examples/NarrativeSample` is a small Swift package for a narrative game:
persisted run and encounter ids, a monotonic foreground clock with an
explicit idle estimate, save and resume keeping the run id, a reroll as a
separate attempt that rolls the story back, and earned versus loaded
progression (one snapshot event on load, an unlock event only for a new
earning). Its `QUERIES.md` has the matching queries: time per run as the
MAX of a cumulative total, never a SUM, and choices grouped by game version
and a stable key.

```bash
cd Examples/NarrativeSample
swift test                                   # the rules, no network
RAVENSIGHT_INGEST_KEY=gt_live_your_key swift run   # the SwiftUI front end on macOS
```

## Concurrency contract

Every public call is non blocking and safe from any thread. All SDK state is
owned by one private serial dispatch queue; public methods forward onto it
and return immediately. The read only properties (`isReady`,
`isTrackingEnabled`, `isEnabled`, `isOptedOut`, `statusReason`,
`sessionToken`, `deviceId`, `queuedEventCount`) read a lock protected
snapshot and never wait on network work. Completion handlers and
`onStatusChange` are always delivered on the main queue. This is a design
contract, not a compiler proof: the package is built in Swift 5 language
mode and the client is `@unchecked Sendable`. The SDK never
throws into game code. The one place it blocks is the quit path, for at most
1.5 seconds.

## Architecture

```
Sources/Ravensight/
  Core/                              no URLSession dependency
    RavensightCore.swift             the whole protocol as a pure state machine
    RavensightTransport.swift        transport protocol plus request and response
  RavensightClient.swift             serial queue driver, timers, lifecycle handlers
  RavensightReports.swift            Player Reports: the report value and its requests
  RavensightQueueStore.swift         the opt-in persisted queue file
  RavensightStats.swift              stats, delivery status and flush outcome types
  Ravensight.swift                   the static facade
  RavensightConfiguration.swift      configuration and error types
  RavensightLifecycle.swift          UIKit and AppKit notifications to the handlers
  RavensightURLSessionTransport.swift  the production transport
  PrivacyInfo.xcprivacy              the privacy manifest
```

`RavensightCore` is a pure, clock injected state machine: it never performs
I/O and never reads a clock. A driver asks it what to do next, performs the
request it was handed and feeds the response back, passing the current time
into every call. The lifecycle handlers live on `RavensightClient`, so the
tests call them directly without UIKit or AppKit notifications.

## Running the tests

```bash
swift build
swift test
```

The suite needs no network and no app: `RavensightCoreTests` drives the
state machine with a fake clock and hand built responses, and
`RavensightClientTests` drives the client over a fake transport, a fake
clock and a throwaway `UserDefaults` suite (opt-out in every order, reset,
key refusal, kill switch, batching, feedback, the 30 minute rule, the cold
launch marker, background launches and playtest runs),
`RavensightControlTests` covers the stop-all control, synthetic identity,
the persisted queue in a temporary directory and the delivery counters, and
`RavensightReportTests` checks every Player Reports request shape and
refusal against a stub transport. To run the same suite on the iOS
Simulator:

```bash
xcodebuild test -scheme Ravensight -destination 'platform=iOS Simulator,name=iPhone 17,OS=27.0'
```

Pick any simulator `xcodebuild -showdestinations -scheme Ravensight` lists.

## Device id and privacy

The SDK generates a random device id on first run (`dev_` plus 32 hex
characters, from 16 bytes of the system's secure random generator) and
stores it in `UserDefaults` under `ravensight_device_id`. An id saved by an
earlier version is kept as it is. No hardware identifier, advertising id,
IP based fingerprint or personal data is collected by the SDK itself. Only
the events you choose to send leave the device. See "Opting out and
resetting" for the player's controls.

### Privacy manifest

The package ships `PrivacyInfo.xcprivacy`, which Xcode merges into your
app's privacy report. It declares:

* `NSPrivacyTracking`: false, with no tracking domains.
* `NSPrivacyAccessedAPITypes`: `NSPrivacyAccessedAPICategoryUserDefaults`
  with reason `CA92.1`. The SDK reads and writes its own keys (device id,
  opt-out, background marker) and nothing else. The persisted queue file is
  written and read without any API that needs a declared reason.
* `NSPrivacyCollectedDataTypes`: Device ID and Product Interaction, each not
  linked to the player, not used for tracking, purpose Analytics.

A game that sends gameplay events and nothing else can declare Device ID and
Product Interaction as not linked to the player and not used for tracking,
and needs no tracking permission prompt. If your events carry anything more
(a player name, purchases), declare that yourself. The same goes for
Player Reports: if your game sends them, declare the player's text and any
screenshot as the data types your store form asks for. The row by row answers
for the App Store and Google Play forms are at
https://ravensight.io/docs/#privacy-label.

## License

MIT. Copyright 2026 Reality Software Entertainment.
