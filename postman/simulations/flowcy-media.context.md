# Flowcy media simulation

Exercises RxCode's native-account media HTTP transport without provider credentials or billable generation. The mock is derived from the owning `github-pm` checkout's `app/api/v1/models/route.ts`, `app/api/v1/ai/images/route.ts`, `app/api/v1/ai/videos/route.ts`, and `lib/ai/{http,request}.ts`. No external published mock was imported; the owning source contract is available locally. The installed CLI is 1.75.0 (`postman status` is unavailable in this version).

Run from the repository root:

```sh
postman simulation run postman/simulations/flowcy-media.sim.yaml --port 49494 --no-history --output ndjson
```

Then run the real HTTP integration tests:

```sh
TEST_RUNNER_RXCODE_MEDIA_SIMULATION_URL=http://127.0.0.1:49494/media/api/v1 xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug -destination 'platform=macOS' -testPlan UnitTestPlan -only-testing:RxCodeTests/FlowcyMediaTransportTests test
```

Path routing confines traffic to the local stand-in. The client's injected endpoint and token source leave its URL construction, encoding, URLSession transport, bearer handling, retry loop, response bounds, and JSON parsing intact. The observation endpoint exists only in this fixture. Unmodeled operations return 501.

Contract assumptions:

- A rejected account bearer returns 401 before media generation. The client refreshes once and preserves the idempotency key across that retry. `lib/ai/request.ts` uses this key to prevent duplicate paid work.
- The catalog may repeat a model once per capability, retaining its original labels. RxCode deduplicates these entries while keeping image/video/audio labels.
- Image results carry `images[].b64_json` and `mime_type`; video submission returns HTTP 202 with a job ID and poll URL.
- Allowance errors return HTTP 429 and a readable error. They must not trigger an automatic new generation. Non-JSON errors still retain their HTTP failure status.

This fixture cannot establish deployed model availability, pricing configuration, actual provider generation quality, live account billing, or real audio playback. Those require separate live verification. No provider generation is performed by these tests.

Observed 2026-11-17 with Postman CLI 1.75.0: both real HTTP tests passed without skips. The simulation log recorded image requests returning 401, 200, 429, and 502, catalog loading, video submission (202), and job polling (200). The rejected bearer was refreshed once with the same idempotency key; the rate-limited operation was attempted once. The broader focused run passed 11 tests, including pixel alignment of all 768 regenerated body-frame pairs. This establishes stand-in transport behavior, not live provider generation.
