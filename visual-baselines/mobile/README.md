# Mobile screenshot regression tests

The approved baseline set covers Settings, Integrations, and Account on iPhone
(portrait), iPad (landscape), and iPhone Duo (expanded landscape). Compact layouts
show Account & General in the Settings menu. Regular layouts keep an avatar
button pinned below the sidebar list, including while navigating detail pages.

## Capture and review

Run from the repository root with Xcode and the simulator runtimes installed:

```sh
python3 scripts/mobile-visual/run.py capture --output test-results/mobile-review-001
```

The default simulator UUIDs are local fixtures. On another machine, pass
`--device iphone=UUID --device ipad=UUID --device iphone-duo=UUID`.
If a default UUID is absent, the runner locates the exact model and runtime in
the committed approval manifest. Install those runtimes on the UI test runner.
CI uses Xcode 27.0 for the iPhone and iPad iOS 27.0 baselines, as authorized by
qiweili. That toolchain exception keeps the approved model/runtime and pixel
thresholds unchanged. Duo and other toolchain changes still require the
recorded Xcode version.
Use `--profile iphone` (repeatable) for a focused run. All three profiles run by
default. Simulator status bars are fixed at 9:41 on January 1, 2026, with full Wi-Fi and battery;
tests use the existing offline cloud fixtures, English, light appearance, and
the standard text size. No live account is needed.
Captures select the lit display (including Duo's unfolded display), reject black
images, and normalize image orientation before exporting PNGs.

Review each profile's `settings.png`, `integrations.png`, and `account.png` with
the user. Capture produces candidates only. **Agents must not approve images
without explicit user approval of those exact candidates.** After approval:

```sh
python3 scripts/mobile-visual/run.py approve --output test-results/mobile-review-001 --reviewer "USER NAME"
```

Commit the three profile directories, their PNGs, and `approved.json` manifests
so later runs use the same reviewed images. Each manifest records the reviewer,
approval time, image hashes, device type, simulator runtime, and Xcode version.
The committed nine-image set was approved by qiweili on October 24, 2026.

## Compare

```sh
python3 scripts/mobile-visual/run.py compare --output test-results/mobile-comparison-001
```

Use a new output directory for each run. The command runs XCTest, exports new
screenshots, and returns a failure for missing approval, altered baseline hashes,
simulator model/runtime changes, dimension changes, or visual differences. Baselines are
never recorded or replaced by comparison runs. A failed XCTest also fails the
command; inspect the profile's `xcodebuild.log` and `result.xcresult`.

The native comparator converts images to sRGB RGBA and permits a per-channel
difference of 8/255 in at most 1% of pixels to accommodate small rasterization
variations. It does not mask any UI region. A visual failure writes a
`SCREEN-diff.png` highlighting changed pixels in magenta beside the latest
image. Inspect baseline, latest, and diff before deciding whether a change is
intentional. Simulator model/runtime updates require a new capture and user review.
The authorized Xcode 27.0 exception still runs the same strict pixel comparisons.

XCTest also asserts the account presentation and navigation behavior, so an
incorrect menu/button substitution fails even if its visual change is small.
This suite covers these three settings screens; it does not establish visual
coverage of every app screen or physical-device haptic behavior.

## Reports and failure artifacts

`review.html` includes All devices, iPhone, iPad, and iPhone Duo filters for the
profiles in the run. Each screen shows the approved baseline, latest screenshot,
and highlighted difference when available. All image and diagnostic links are
relative so the report works after downloading and extracting the artifact.

Failed comparisons and build, XCTest, approval, or environment errors produce
`mobile-visual-failure.zip`. It includes the HTML/Markdown report, baseline and
captured images, differences, comparison diagnostics, logs, and any available
`.xcresult` bundle. Missing captures are identified in the report. The command
still exits with failure. Passing runs do not create a failure ZIP.

The Tests workflow runs iPhone and iPad sequentially on a self-hosted `ui-tests`
runner using Xcode 27.0. Duo remains available locally and is excluded from CI.
On failure, the workflow rebuilds the report and uploads the ZIP as
`mobile-visual-test-results` with 14-day retention (subject to repository limits).
This configuration requires the approved simulator models and runtimes; it does
not upgrade baselines.

To regenerate a report for an existing run, or package partial results manually:

```sh
python3 scripts/mobile-visual/run.py report --output test-results/mobile-review-001
python3 scripts/mobile-visual/run.py report --failed --output test-results/mobile-review-001
python3 -B -m unittest discover -s scripts/mobile-visual -p 'test_*.py'
```
