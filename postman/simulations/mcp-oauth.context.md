# MCP OAuth simulation

Created 2026-10-25 from the RFC 6749 refresh grant and MCP authorization contract. This is a generic synthetic fixture, so no provider-owned mock was searched or imported.

## Purpose

Exercise RxCode's real OAuth HTTP client and local relay without account credentials. The modeled behavior lives in `../mocks/mcp-oauth/default.js`; this does not emulate provider discovery or interactive authorization.

## Execution

From the repository root, run in one terminal:

```sh
postman simulation run postman/simulations/mcp-oauth.sim.yaml --port 49491 --no-history --output ndjson
```

In another terminal:

```sh
xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug -destination 'platform=macOS' -only-testing:RxCodeTests/MCPOAuthTests -only-testing:RxCodeTests/MCPConnectionRoutingTests -only-testing:RxCodeTests/MCPAppConnectionTests test
```

Stop the simulation with Ctrl-C. The HTTP integration test skips when the default local simulation is absent; an explicitly configured `MCP_OAUTH_SIMULATION_URL` makes connection failure fail the test.

## Assumptions

- The integration test resets the synthetic rotation state and must have exclusive use of this simulation. Real provider token lifetimes, Keychain persistence, and CLI runtime connections remain unverified by this fixture. (observed 2026-10-25)

## Observations

<!-- begin:observations -->
2026-10-25: The sole `oauth` member served reset, refresh, rejected and successful MCP requests, SSE, and the rewritten session POST endpoint. All 25 focused XCTest checks passed, including the HTTP integration check with no skips.
<!-- end:observations -->

## What didn't work

- 2026-10-25: CLI 1.75.0 rejected a directory member with `Mock 'file' must point to a file (.js handler or .yaml manifest), not a directory`; the member path must point to `config.yaml`.
