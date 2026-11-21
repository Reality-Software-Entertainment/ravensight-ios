# Held combined release, October 17, 2026

Public-build support and typed events have been combined locally. This record
is verification evidence, not a publication or deployment record.

Validated: 176 Swift tests on macOS.

The merge preserves public-key consent and inert-without-key behavior,
stable event IDs, typed event helpers and opt-in performance sampling.
JavaScript now defers performance listeners until consent; Android health
summaries carry the same deduplication IDs as other events.

Physical-device and live-service validation is not implied by these checks.
Publishing, tags, marketplace submission and deployments remain held pending
owner approval. Older README test counts describe their earlier branch runs;
this file records the combined candidate.

Remote config wave: full Swift package suite passed, 179 tests with zero failures. New tests cover strict numeric/boolean fallback, ETags, exposure labels, cache restoration, reset/opt-out response races and request deduplication. Version 0.4.1 remains held. Physical-device and live API checks are not implied.

Config identifier compatibility audit: 4 focused Swift config tests passed.
Config property keys reject constructor/prototype, including nested JSON properties.
Experiment keys and variant labels may use those words as string values, matching
the server contract. Regression coverage distinguishes those cases. Publishing remains held.

Player Reports identity audit: full `swift test` passes 181 tests, including 12 report tests. A new regression resets identity during screenshot storage upload and verifies no finalization using the old session. Report async boundaries now stop when the session changes. macOS Swift validation does not exercise UIKit capture on an iOS device or live object storage. Publishing remains held.

## 0.7.0: identify players who sign in, and campaign links (November 21, 2026)

- Identify (`identify`, `resetIdentity`, `isIdentified`) and `setCampaignLink`
  together on main at 5ba1c6c, built to the platform's identify contract
  version 2 and the campaign link rules of the JavaScript SDK 0.12.0.
- `swift build` and `swift test` on macOS (Swift 6.4.2): **310 tests**, 0
  failures. `Examples/NarrativeSample`: 8 tests, 0 failures.
- The identify tests read the contract's binding vectors from
  `Tests/RavensightTests/Fixtures/identify-vectors.json`, byte for byte the
  platform's copy.
- Requests went through a fake transport: no live service, simulator or
  device was used.
