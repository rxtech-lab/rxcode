# Cloud saved views

Cloud projects sync saved view tabs through `GET|PUT /api/v1/docs/repositories/{id}/board-views`. Views belong to the authenticated account and project, matching the personal presentation preferences previously stored on each device. The Flowcy backend implementation and migration live in `github-pm`.

The payload is `{ views: [{ view: TaskSavedView, storyRemoteIDs: [String] }], revision: Int }`. The view's `storyIds` is empty on the wire; `storyRemoteIDs` is mapped through each device's story links so a filter continues to select the same story on both devices. Names, tab order, layout, structured filters, default marker, and desktop filter-script text are preserved. Mobile does not execute Swift filter scripts.

Desktop merges local tabs against the last successful cloud base, uploads pending edits, and adopts remote changes. Independent edits and deletions merge by view UUID. Concurrent edits to the same tab favor the pending local edit. Local order changes win over remote order changes; independent remote tabs are retained. Only one default survives. A revision-checked PUT prevents silent overwrites; conflicts refetch and merge, with at most three attempts. Existing desktop tabs and legacy mobile preferences migrate on the next successful sync. Initial migration combines tabs and favors this device's version when UUIDs collide.

An older backend's GET 404 leaves local views intact. Mobile view edits require the updated endpoint and report an error if unavailable. Deploy backend migration `0044_project_board_views` and its route before releasing clients. These local changes do not deploy or migrate production.

## Verification

Shared-model coverage:

```sh
swift test --package-path Packages --filter CloudSavedViewsTests
```

Run the saved local Postman simulation, then exercise the actual mobile HTTP client on an available iOS simulator:

```sh
postman simulation run postman/simulations/board-views.sim.yaml --port 4912 --output ndjson
```

In another terminal:

```sh
TEST_RUNNER_RXCODE_VIEWS_SIMULATION_URL=http://127.0.0.1:4912/flowcy \
xcodebuild -project RxCode.xcodeproj -scheme RxCodeMobile \
  -destination 'platform=iOS Simulator,name=iPhone Duo' \
  test -testPlan MobileUnitTestPlan \
  -only-testing:RxCodeMobileTests/CloudSavedViewsHTTPTests
```

The HTTP test covers two clients reading the same account preferences, revision conflicts, and old-server fallback. It skips unless the simulation URL is supplied. Backend route tests use real in-memory SQLite to verify persistence, concurrent first writes, stale revisions, account/project isolation, validation, and access restrictions. These are local and simulated checks; live cross-device sync requires the backend deployment and updated apps.
