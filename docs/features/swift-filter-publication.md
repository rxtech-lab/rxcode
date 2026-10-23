# Mac Swift filter publication

Cloud-linked project views now publish their Swift filters during normal board sync. Local-only projects continue to use the native evaluator.

1. Save the view in its existing editor sheet. The source and standard settings sync through the saved-view revision API.
2. The Mac checks the server results endpoint for an artifact matching the exact source hash. Successful checks are cached for ten minutes within the current account/session.
3. Missing artifacts compile with a detected compatible Swift toolchain or the app-managed Swift 6.4.1 compiler and matching full WASI SDK. Direct compiler invocation avoids requiring Xcode or a host SDK to build a package manifest. The existing `TaskFilterScript` JSON stdin/stdout ABI is preserved. Valid core WASM binaries are cached by managed toolchain version and harness source. Custom toolchains continue to use SwiftPM.
4. The app obtains a presigned S3 upload, uploads without the account bearer or shared cookies, then finalizes against the saved revision. Redirects are rejected. Publication receipts must match source hash, module hash, ABI and revision.
5. Concurrent saved-view conflicts trigger the existing bounded refetch/merge flow. Source changes, unlinking or account changes stop pending publication before the next write. Genuine compiler/storage failures stay visible in cloud sync status with retry and setup actions.

## Compiler download and removal

The Mac app does not bundle a compiler or SDK. Automatic detection first checks the app-managed installation, then Swiftly, the system Swift command, and user/system Swift.org toolchains. A full, non-Embedded WASM SDK must match the compiler version. Custom executable/SDK settings remain available in the compiler setup sheet.

When a cloud filter needs a missing compiler, the board opens the compiler setup sheet with **Download Compiler and WASM SDK**. Downloading starts only after that action. A dedicated progress sheet displays download percentage, verification and extraction status, and retry on failure. Cancel Download stops the transfer or extraction, cleans partial files, and returns to a state where downloading can be retried. Successful installation selects the managed toolchain and retries cloud sync for the open project.

**Settings → Tasks → Manage Swift Compiler** opens a dedicated sheet. It allows downloading the compiler, editing advanced paths, or removing the app-managed installation after native confirmation. Removal is disabled during installation and active compilation; it does not remove custom or system toolchains.

The installer downloads checksum-pinned Swift 6.4.1 and WASM SDK archives directly from Swift.org, verifies them before extraction, and stages the selected compiler/linker, host libraries, license and full SDK under `Application Support/RxCode/Toolchains/SwiftFilter-6.4.1`. It does not run the package installer or change global Swift settings. Installation is promoted only after validation. Temporary downloads and staging are cleaned up on success or failure. Removing the managed installation also removes its compiled-filter cache.

The download is approximately 1.6 GB; the installed toolchain is approximately 2 GB. Extraction temporarily requires additional space. Foundation-based modules are approximately 51 MiB with symbols stripped, so both Mac and server enforce a 64 MiB artifact limit. Deploy the matching server limit before publication.

The macOS build phase only removes compiler folders left by older incremental builds. It does not download, copy or sign a compiler into the app.

## Verification

- `swift test --package-path Packages --filter CloudFilterArtifactTests` validates binary headers, upload size and exact source hashing.
- `xcodebuild -project RxCode.xcodeproj -scheme RxCode -configuration Debug build` verifies the Mac target.
- Start `postman simulation run postman/simulations/board-filter-publication.sim.yaml --port 4914 --output ndjson`.
- Run the Mac `TaskFilterPublicationTests` with `TEST_RUNNER_RXCODE_FILTER_SIMULATION_URL=http://127.0.0.1:4914/flowcy`. The HTTP fixture checks the prepare/upload/finalize sequence, source/module integrity, credentials, revision handling and cancelled publication.
- Set `TEST_RUNNER_RXCODE_TEST_SWIFT_ARCHIVES` to a directory containing the official `compiler.pkg` and `sdk.tar.gz` to run `testManagedToolchainInstallCompileAndRemove`. Set this variable to `download` instead to test the real Swift.org downloads and progress callbacks. The test verifies checksums, stages the real compiler, compiles a Foundation filter, removes the installation, and checks that the app contains no bundled compiler. `testCorruptDownloadIsRejected` covers checksum failure.
- Set `TEST_RUNNER_RXCODE_TEST_SWIFT_WASM_EXECUTABLE` and `TEST_RUNNER_RXCODE_TEST_SWIFT_WASM_SDK` to run the real compiler test. It is explicitly skipped when those prerequisites are absent.

The simulated upload uses a minimal WASM fixture, not a Swift-compiled executable. Live S3 publication and server execution of the compiled Swift harness require separate verification. Mobile consumption of server-evaluated results is separate from this Mac publishing path.

Verified locally: the final signed Debug app is approximately 216 MB and contains no Swift toolchain. Tests passed for matching-SDK detection, corrupt-download rejection, live Swift.org downloads with intermediate progress callbacks, installation, Foundation-based WASM compilation, and removal. UI appearance and production publication were not exercised by these tests.
