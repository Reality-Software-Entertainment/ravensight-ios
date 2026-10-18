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
