# RxCode extensions

## Native runtime probe

Run `Fixtures/ExtensionRuntime/build-probe.sh adhoc 1.0` on a Mac with Xcode and XcodeGen. It builds an isolated Release host and one universal contributor containing a single workspace-point appex. The build verifies both architectures and their sandbox-only entitlements. Its products are under `build/extension-runtime-adhoc/1.0`. The existing two-team fixture remains available.

Open RuntimeProbe from the host's Release products. Its `--observe-combined <absolute-container-path>` mode opens the windowless contributor, observes the monitor for five seconds and prints the enabled identity count and system approval counts. Enable the contributor in Manage Extensions if required. **Test XPC callback** sends a nonce over `makeXPCSession()`. The extension must call the host back on the same session, receive the matching acknowledgment and report completion. **Inspector** and **Popover** open the same identity's scene and perform a separate scene handshake. The scene draws its border, dimensions and version. Resize the inspector and compare the displayed dimensions against the host's proposed size.

The probe ran on an Apple Silicon Mac with macOS 27.2 (26B123) and Xcode 27.2. Both arm64 and x86_64 slices compiled and passed signature verification. The extension had exactly `com.apple.security.app-sandbox` on each slice and the hardened runtime flag. The locally built container had no quarantine attribute. After opening it, the isolated host reported zero enabled matches, one unapproved contribution (up from zero) and zero disabled contributions after 5.092 seconds. Callback, scene activation, sizing and persistence require system enablement.

### Release gate

Build both versions of the distributable probe with the same compiler as the usage providers. Give each invocation a fresh output directory.

```sh
swift build --package-path Packages --product rxcode-extension
cli="$(swift build --package-path Packages --show-bin-path)/rxcode-extension"
Fixtures/ExtensionRuntime/build-probe.sh package 1.0.0 /tmp/rxcode-discovery-v1 "$cli"
Fixtures/ExtensionRuntime/build-probe.sh package 2.0.0 /tmp/rxcode-discovery-v2 "$cli"
```

Each output contains `Contributor.app`, `probe.zip` and `metadata.json`. The default Apple signing identity is ad hoc. For the fallback trial, append the rxlab Developer ID Application identity (team `T7GYB573Y6`) and a `notarytool` keychain profile to both commands. This mode verifies the container and appex against the Developer ID requirement, submits the container for notarization, staples and validates it, then packages the final release bytes. For a local packaging check, sign each final `metadata.json` with a test key. For the macOS 26 trial, run the **Extension builds** workflow manually from `main`, specify the exact three-component `probe_version`, and use the protected `extensions-release` environment. That workflow builds the fixed discovery fixture, signs its envelope, verifies the archive, and publishes it through Flowcy’s presigned upload and confirm endpoints. Run it for v1 to obtain the pinned seed bytes, then run it for v2 for the HTTPS update trial. Use fresh version numbers when repeating the trial with a different Apple signing mode so the server serves the new build.

The two ad hoc probe versions built on macOS 27.2 arm64. Both universal archives passed the distribution CLI's manifest, archive, Ed25519, entitlement, per-architecture CDHash and signed revocation checks with Debug fixture keys. Verification rejected the v2 archive paired with the v1 envelope. The candidate staging script also accepted both release versions using three disposable keys and a temporary copy of the trust configuration, preserved the four signed resource files byte for byte, and retained the last verified copy when the next archive failed verification. These checks covered the artifacts on macOS 27.2. The macOS 26 runtime observations remain open.

Build a dedicated Release gate candidate for disposable machines using `OTHER_SWIFT_FLAGS='$(inherited) -DRXCODE_EXTENSION_RELEASE_GATE'` across the app and packages. Supply the candidate with preconfigured non-Debug public pins, the provisional Apple signing mode and an offline-signed baseline. Set the Xcode build setting `RXCODE_EXTENSION_PROBE_RESOURCES` to a directory containing the v1 archive named `app.rxlab.extensions.discovery-probe.zip`, its `app.rxlab.extensions.discovery-probe.sig.json` envelope, `revocations.json` and `revocations.json.sig`. The build verifies the sealed resources. Sign and notarize the candidate, staple it, and distribute it in the Release DMG. The dedicated candidate uses the production Flowcy catalog for v2. Run the nine-provider usage migration gate separately with all nine bundled providers.

Use the notarized and stapled Release RxCode host installed from its DMG in /Applications. Restore clean macOS 26 snapshots on Apple Silicon and Intel. Run the bundled v1 seed and HTTPS v2 update through the catalog installer into the same install location. Capture the following observations for each of three runs per machine.

| Observation | Evidence to record |
| --- | --- |
| Container opening | Original quarantine state and any Gatekeeper dialog |
| Discovery | Time until discovery, enabled identities, pending approval count |
| Activation | Callback acknowledgment and scene handshake for the same identity |
| Sizing | Inspector resize and popover dimensions from inside the remote scene |
| Persistence | Identity, enablement and reconnection after quit, logout and reboot |
| Upgrade | Installed version, exactly one matching identity and an open surface reconnecting to v2 |

Open **Discovery Probe** in the project inspector and observe its version, dimensions and scene callback status. Add the Discovery Probe usage integration and a card. A refresh must produce its `callback` metric with value 1. Opening the card detail popover tests the second remote scene. Keep the inspector or popover open across the catalog update, resize it, then repeat the callback after restarting the host and after rebooting.

Repeat one run with quarantine present as the negative control. Record system behavior with the downloaded attributes intact. If the production-path ad hoc trial fails, rerun with the team T7GYB573Y6 Developer ID and notarized contributors. Manual enablement requires the guided enablement banner. The observed development-account run leaves the production signing choice open.

Run the read-only `scripts/extensions-upgrade-check.sh` assertions on the clean test machine. Each command checks its named artifacts. Record the fixture HTTP server's request log, macOS approval state, open-scene transitions, reboot behavior and passkey prompts separately.

```sh
scripts/extensions-upgrade-check.sh host /Applications/RxCode.app arm64
scripts/extensions-upgrade-check.sh bundles /Applications/RxCode.app Extensions/bundled.lock.json keys.json revocation-public-key.txt /path/to/rxcode-extension
scripts/extensions-upgrade-check.sh installed "$fixtureSupport" verified-release.sig.json --source bundled
scripts/extensions-upgrade-check.sh uninstalled "$fixtureSupport" app.rxlab.extensions.vercel
scripts/extensions-upgrade-check.sh policy "$fixtureSupport" test-key-a 2 revocation-public-key.txt /path/to/rxcode-extension
scripts/extensions-upgrade-check.sh dashboard offline previous-dashboard.json offline-after-event.json
scripts/extensions-upgrade-check.sh dashboard online previous-dashboard.json online-fixture-refresh.json
scripts/extensions-upgrade-check.sh mobile previous-mobile.bin candidate-mobile.bin
```

Use the actual previous release's persisted dashboard as the baseline, with all nine provider types and populated snapshots. Keep identical provider fixtures on both sides of the online comparison. Capture the offline state after a local usage event. For the mobile check, capture both payloads at the same fixture state. The installed check expects a separately verified release envelope. Run it again after the catalog update. Record the signed revocation sequence and verify a blocked release through the running host during the leaked-key drill.

## Development API

In a Debug build, pass the launch arguments `-RxCodeExtensionAPI2 YES` to opt into API 2.0. A project chat can create a development contributor with `ide__create_extension`. Edit its generated Swift source, run `ide__reload_extension`, then exercise the loaded code with `ide__test_extension`. A subsequent edit requires another reload. `ide__list_extensions` reads the enabled identities from ExtensionKit.

If a signed development probe is waiting for macOS approval, open **System Settings → General → Login Items & Extensions**. In **Extensions**, open the info button beside the probe’s name, turn on its workspace extension, and click **Done**. On macOS 27.2 the compatibility probe’s switch is labeled `app.rxlab.flowcy.code.workspace-service`. Wait for the active reload to finish before sending test input. If the reload already ended, start it again in the project chat.

The source folder contains `extension.json`, `README.md`, Swift sources and optionally `icon.png`. The distributed builder accepts `Sources/*.swift`. The editable development entry point can also live in `Extension.swift`. The build places identical copies of the manifest in the container and appex at `Contents/Resources/RxCodeExtension.json`.

```json
{
  "id": "app.rxlab.extensions.example",
  "name": "Project overview",
  "version": "1.0.0",
  "pluginAPI": "2.0",
  "readme": "README.md",
  "permissions": [],
  "contributes": {
    "inspector.panel": { "title": "Project overview", "symbol": "folder" },
    "settings": true
  }
}
```

Declare each remote scene in both the manifest and the activation reply. The scene names are `inspector`, `settings`, `usage-card` and `usage-detail`. Usage providers declare a stable `pluginID`, a display title, authentication and optional account/resource field labels under `usage.provider`. A provider snapshot carries the values consumed by mobile clients and widgets.

Import `RxCodeExtensionSDK` in the contributor. A direct `AppExtension` entry point can return `ExtensionService.configuration(scenes:test:)` for a headless contributor. A UI contributor uses `AppExtensionSceneConfiguration` with its native scenes and the service connection handler. Connect a scene through `ExtensionSceneConnection.accept(_:apply:)` to receive its fixed project context and an `RxCodeHost` client. Broker requests carry a request ID, operation and JSON-encoded payload. Responses return the same ID and a value or typed error.

| Permission | Scope | Host behavior |
| --- | --- | --- |
| `project.read` | Current project or worktree | Reads normal files through a bound directory descriptor. Filters sensitive names, symlinks and files with multiple links. |
| `storage` | Extension identity | Reads and writes settings in host storage. |
| `network` | Exact declared domains | Issues bounded HTTPS requests. |
| `credentials.use` | Declared slots | Adds credentials to eligible provider requests inside the host. |
| `usage.local.read` | Host usage data | Provides local usage and rate-limit summaries. |
| `disk.read` | Files outside the default scope | Requires a saved high-risk grant. |
| `contacts.read` | Contacts | Requires an extension grant and macOS Contacts authorization. |
| `vault.read`, `vault.create` | Project Secrets | Requires an extension grant. Secrets encryption and decryption use the host's passkey flow. |
| `acp.credentials.use` | Declared ACP slots | Requires an extension grant and a bound integration. |

Confirm saves a high-risk grant. Skip leaves the permission pending. Reject saves a denial. Background calls return a status without opening a prompt. A scope change gets its own decision. Development copies have separate permission records from distributed releases.

### Host calls

Supply the input below as the JSON payload in the SDK request. Foundation encodes `Data` as a base64 string. All operations use the workspace and integration bound by the host.

| Operation | Input and result |
| --- | --- |
| `files.read`, `files.list` | Pass `{"path":"src/main.swift"}` for file bytes, or `{"path":"src"}` for an array of entry names. |
| `storage.set`, `storage.get` | Set with `{"key":"theme","value":"dark"}`. Get with `{"key":"theme"}`. A missing key returns JSON null. |
| `net.fetch` | Pass an HTTPS `url` with optional `method`, `headers`, base64 `body` and `credentialSlot`. Returns `status` and base64 `body`. Both the original destination and each redirect must be allowed. Credentialed redirects must stay on the original host. |
| `contacts.query` | Pass `{"name":"Lee"}` for up to 100 matching contacts with given name, family name and first email. System Contacts access can be requested from a user-opened inspector or settings scene. |
| `vault.read` | Pass `environment` and `filename` for one decrypted file in the bound project. The host asks the user to approve that specific call before entering the passkey flow. |
| `vault.create` | Pass `environment` to create an environment, or add `filename` and `content` to create a file. The host encrypts the content and uses a conditional create to protect an existing file. |
| `usage.local.summary` | Pass optional `range` (day, week, month or year). Returns `LocalUsageSummaryDTO` with totals and provider/model breakdowns. |
| `rateLimits.read` | Pass optional `range` for an array of `RateLimitReportDTO` with current limits, historical samples, task costs and forecast. |

## Build and verify an archive

```sh
swift run --package-path Packages rxcode-extension build Extensions/example --output Contributor.app --sign -
swift run --package-path Packages rxcode-extension package Contributor.app --output example.zip > metadata.json
swift run --package-path Packages rxcode-extension sign --metadata metadata.json --key-env RXCODE_EXTENSION_PRIVATE_KEY --key-id "$RXCODE_EXTENSION_KEY_ID" --output example.sig.json
swift run --package-path Packages rxcode-extension verify --archive example.zip --envelope example.sig.json --keys public-keys.json
```

The build compiles both architectures and signs the completed app and appex. Packaging measures those final code directories and the archive. A separate digest identifies the build inputs, including the SDK sources. For a Developer ID distribution, notarize and staple the signed container before packaging it.

The detached Ed25519 signature covers the key ID, extension ID, version, API version, archive SHA-256 and both architecture CDHashes. Flowcy independently hashes the private staging object and verifies its manifests and signature before publishing. Its verification badge identifies the publisher in Flowcy's trusted configuration. RxCode checks the actual archive against its own trusted keys, staged bundle contents, entitlements and code signatures.

## Production key custody and bundling

1. Run `rxcode-extension keygen` in the intended custody environments for three separate keys. Use the active key for publishing, reserve the unused backup for rotation, and keep the revocation signer offline. The command emits private material to standard output. Record the public fingerprints separately. Production keys must be distinct from Sparkle and other rxlab credentials.
2. Pin the active and backup public halves in the release app and the independent revocation public half in its revocation verifier. Record the IDs and compare full fingerprints on both clients. The production ceremony is pending.
3. Configure the protected, main-only GitHub environment `extensions-release` with the active signing key, its ID and a publisher token. Configure Flowcy's `RXCODE_EXTENSION_PUBLIC_KEYS`, `RXCODE_EXTENSION_REVOCATION_PUBLIC_KEY`, `EXTENSION_PUBLISHER_USER_IDS` and private `EXTENSIONS_S3_*` bucket. Use an explicit `extensions:write:all` token owned by an allowed admin. Configure the staging lifecycle to expire after 24 hours.
4. On the offline machine, sign an empty sequence 1 document using `sign-revocation --document revocations.json --key-env OFFLINE_REVOCATION_KEY --output revocations.json.sig`. Upload the exact bytes and detached signature through the Flowcy admin dashboard. Verify the bytes served by the public revocation endpoint before publishing.
5. After the signing-mode trial, publish each provider, pin its version and SHA-256, and bundle its verified archive and envelope with the signed revocation baseline in the candidate. Exercise the bundled seed and its subsequent Flowcy update on the clean test machines before enabling the production migration.

## Leaked signing key

Retire the compromised key in Flowcy, rotate the publisher token and replace the signing secret in the protected GitHub environment. Revoke any known harmful release immediately by ID, version and SHA-256 in a higher-sequence, offline-signed document.

Activate the pinned backup key, bump the first-party provider versions and publish replacements. Then revoke the old key ID in a new document. Ship a new unused backup public key and updated bundle pins in the next RxCode release. Clients keep their latest authenticated revocations offline. Replacing a compromised revocation key itself requires an app update.

## Building the bundled usage providers

Run `swift test --package-path Extensions` to check provider snapshots and parser fixtures. A Debug app build invokes the same universal compiler used by publishing CI. It writes nine zipped contributors, their detached signature envelopes, a lock and a signed sequence 1 policy under `Contents/Resources/BundledExtensions`. Enable the preview with the Debug launch argument `-RxCodeExtensionAPI2 YES`. Debug test keys are public fixtures.

The protected publishing job reads `active`, `backup`, `keys`, `revocationKey` and `appleSigning` from `Packages/Sources/RxCodeExtensionDistribution/Resources/production-trust.json`. Set the provisional `adHoc` or `developerID` mode for the discovery-probe candidate. Confirm the production choice on both release machines before publishing the usage providers. Under the Developer ID fallback, set the protected environment’s `DEVELOPER_ID_IDENTITY`, `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD`, `NOTARY_APPLE_ID` and `NOTARY_PASSWORD`. CI staples each contributor before measuring its final archive and code hashes.

After publishing, record the nine exact IDs, versions and SHA-256 values in the array in `Extensions/bundled.lock.json`. The Release app build downloads the pinned bytes and signed revocation baseline from Flowcy and verifies every archive before code signing the app. Until the production ceremony and rollout gate finish, the production pins stay empty and Release uses its existing providers.
