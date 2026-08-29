# Changelog

All notable changes to this package are documented here.

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
