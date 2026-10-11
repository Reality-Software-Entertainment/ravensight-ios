# Changelog

All notable changes to this package are documented here.

## [0.2.0] - 2026-10-10

### Breaking

* `game_paused` and `game_resumed` are no longer sent by default. Set
  `trackPauseEvents = true` to keep them. On macOS a focus change sends
  nothing by default.
* `Ravensight.setEnabled(_:)` is deprecated in favour of
  `Ravensight.setTrackingEnabled(_:)`, which saves the player's choice. The
  old call still works as an unsaved runtime switch.
* `start()` makes no request while the SDK is disabled or the player has
  opted out, and an iOS launch into the background waits for the first
  foreground before `game_started`, the settings check and the session.
* `track()` no longer sends a request per call: the queue goes out on the
  flush timer, at 50 queued, on `flush()`, on background and on quit.
* The default `apiUrl` is the bare host `https://api.ravensight.io`; the SDK
  appends `/api/v1` and strips a trailing one.
* A `401`, or a `403` other than `tracking_disabled` or a playtest refusal,
  now stops automatic sending for the run (`invalid_key`) instead of being
  retried forever; a settings `401` no longer means "assume tracking on".
* Feedback with a category outside `feedbackCategories` or a rating outside
  1 to 5 fails locally (`invalid_category`, `invalid_rating`), and feedback
  while tracking is off fails with `disabled` (was `tracking_disabled`).
* The package now ships a `PrivacyInfo.xcprivacy` resource.

### Added

* `RavensightConfiguration.enabled` (default true, never saved),
  `trackPauseEvents`, `sessionTimeout` (1800 seconds), `playtestToken` and
  `playtestRunId`.
* `setTrackingEnabled(_:)`, saved in `UserDefaults` before it returns and
  callable before `start()`; `isOptedOut`; `resetDeviceId()`, which returns
  the new id. On the client and the facade.
* The iOS session rule: a marker on background, `game_exited` stamped at
  the background time after `sessionTimeout` and a new session, the cold
  launch marker reported once for an app swiped away in the background.
* `statusReason` and `onStatusChange` with the reasons `disabled`,
  `invalid_key`, `tracking_disabled`, `offline`, `rate_limited`,
  `session_failed` and `playtest_job_closed`.
* Ravensight Playtest support: token and run id from the configuration or
  the launch environment, `pt-<runId>` device id in memory only, the
  `X-Ravensight-Playtest` header on every request, `isPlaytest`.
* Public `sessionToken` for handing the session to a game server, and
  `feedbackCategories` and `sdkVersion`.
* `Sendable` on `RavensightClient` (checked by design: one serial queue and
  a lock), `RavensightConfiguration`, `RavensightRequest`,
  `RavensightResponse`, `RavensightError` and the URLSession transport, so a
  Swift 6 app builds against the package without diagnostics.
* `PrivacyInfo.xcprivacy`: `UserDefaults` with reason `CA92.1`, Device ID and
  Product Interaction (not linked, not tracking, Analytics), no tracking.
* Client tests over a fake transport, clock and storage for every opt-out
  order, reset, key refusal, the kill switch, batching, feedback, the 30
  minute rule, the cold launch marker, background launches and playtest.

### Fixed

* `Ravensight.setEnabled(false)` called before `start()` was silently
  ignored, so a player who opted out was still tracked. It is now held for
  the process and applied at `start()` (never saved, with a console line
  pointing at `setTrackingEnabled`).
* A session or batch answer that arrives after `resetDeviceId()`, an
  opt-out or `setEnabled(false)` is ignored, so the old identity's session
  is not adopted and a stale `202` cannot remove newer events.
* `game_exited` was only sent on `willTerminate`, which iOS rarely delivers,
  and a session survived any length of time in the background.
* A `403 tracking_disabled` from the session or batch endpoint is now the
  kill switch instead of a retry.
* `Retry-After` is honoured on `503` as well as `429`, and on the settings
  check.
* A batch `401` re-opens the session twice in a row before backing off.
* Fetching suggestions while tracking is off no longer makes a request.
* New device ids take 16 bytes from the system's secure random generator.

## [0.1.0] - 2026-08-29

First public beta.

### Added

* `Ravensight` static facade with `start`, `track`, `flush`, `submitFeedback`,
  `fetchSuggestions`, `setEnabled`, `isReady` and `shared`.
* `RavensightCore`, the complete protocol implementation as a pure, clock
  injected state machine with no URLSession dependency: sessions, batching at
  the 50 event server limit, the offline queue with a drop oldest cap of 500,
  re authentication on 401, `Retry-After` on 429, exponential backoff from 10
  seconds to 5 minutes, and oversize batch splitting on 400.
* `RavensightTransport` with a `RavensightURLSessionTransport` implementation
  over URLSession.
* Server side kill switch honored at boot via `GET /settings`.
* Device id persisted in `UserDefaults`.
* Automatic flush on a 5 second interval, on resign active, on entering the
  background (under a `UIApplication` background task assertion on iOS, a
  `ProcessInfo` activity on macOS) and on termination.
* XCTest suite driving the state machine with a fake clock and a fake
  transport; GitHub Actions CI running `swift test` on macOS.

### Known limitations

* Not yet verified inside a shipping app. See the beta notice in the README.
* The final flush on termination is best effort. A process that exits
  immediately can lose the last batch, since the queue lives in memory only.
