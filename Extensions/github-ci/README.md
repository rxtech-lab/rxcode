# GitHub CI

Track how long pull requests wait for their first GitHub Actions workflow to start. Enter up to 30 repositories as comma-separated `owner/name` values. The card shows a 30-day average, weighting each pull request equally, plus repository and pull-request breakdowns. Reruns are excluded.

RxCode sends requests to `api.github.com` using the token stored for this integration. Private repositories require Actions read access.
