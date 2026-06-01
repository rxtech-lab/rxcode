enum ReleaseSkill {
    static let systemPrompt: String = #"""
    # Skill: Set up release publishing

    You are setting up automated releases for this repository using
    semantic-release, so the project can cut GitHub releases (computed versions,
    changelog, git tag) from CI — triggered manually from RxCode's "Create
    Release" button or on a branch push.

    Set this up end to end. **Both files below are required** — without a
    `.releaserc` semantic-release errors out, so always create it.

    ## 1. Create `.releaserc`

    semantic-release's config. A good default:

    ```json
    {
        "plugins": [
            "@semantic-release/commit-analyzer",
            "@semantic-release/release-notes-generator",
            "@semantic-release/github"
        ]
    }
    ```

    Add `@semantic-release/exec` (and a `prepare`/`verifyConditions` step) only if
    the repo needs to stamp a version into a manifest (e.g. `package.json`,
    `Info.plist`). Inspect the repo first and adapt the plugins to its language.

    ## 2. Create the CI workflow `.github/workflows/create-release.yaml`

    **Ask the user how releases should trigger** before writing the `on:` block:
    - **Manual only** — `on: { workflow_dispatch: }`. Releases happen only when
      the user clicks "Create Release" (or runs the workflow). Safest default.
    - **On branch push** — add `push: { branches: [main] }` so every push to the
      release branch cuts a release. Offer to also keep `workflow_dispatch`.

    A workflow that supports both (push does a dry run, manual dispatch does the
    real release):

    ```yaml
    name: Create Release
    on:
        workflow_dispatch:
        push:

    jobs:
        create-release:
            runs-on: ubuntu-latest
            permissions:
                contents: write
            steps:
                - name: Checkout
                  uses: actions/checkout@v6
                - uses: actions/setup-node@v6
                  with:
                      node-version: "22"
                - name: Setup Git
                  run: |
                      git config user.name "github-actions[bot]"
                      git config user.email "github-actions[bot]@users.noreply.github.com"
                - name: Dry Run Release
                  uses: cycjimmy/semantic-release-action@v6
                  if: github.event_name == 'push'
                  env:
                      GITHUB_TOKEN: ${{ secrets.RELEASE_TOKEN }}
                  with:
                      dry_run: true
                      extra_plugins: |
                          @semantic-release/exec
                - name: Create Release
                  uses: cycjimmy/semantic-release-action@v6
                  if: github.event_name == 'workflow_dispatch'
                  env:
                      GITHUB_TOKEN: ${{ secrets.RELEASE_TOKEN }}
                  with:
                      branch: main
                      extra_plugins: |
                          @semantic-release/exec
    ```

    If the user chose manual-only, drop the `push` trigger and the "Dry Run"
    step. The workflow authenticates to GitHub with the `RELEASE_TOKEN` secret
    (installed in step 3).

    ## 3. Register the repo and install the RELEASE_TOKEN secret

    The workflow reads `secrets.RELEASE_TOKEN` to push tags and create releases.
    semantic-release needs a real GitHub token with `contents: write` — the
    built-in `GITHUB_TOKEN` works but won't re-trigger downstream workflows, so
    most projects use a Personal Access Token.

    Do this:
    1. **Ask the user to provide a GitHub token** (a fine-grained or classic PAT
       with `contents: write` on this repo; if they want releases to trigger
       other workflows, it must be a PAT, not the default token).
    2. Call the **`ide__setup_release`** MCP tool with `repository: "<owner>/<repo>"`
       and `release_token: "<the token they gave you>"`. This registers the repo
       with the release service (scanning its workflows so "Create Release" can
       dispatch them) and installs the token as the repo's `RELEASE_TOKEN` GitHub
       Actions secret in one step. If the repo isn't registered yet, the tool
       registers it for you (the RxLab GitHub App must be installed on it).

    If the user prefers not to share a token, instruct them to either use the
    built-in token (`GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}` in the workflow,
    then call `ide__setup_release` without `release_token` just to register the
    repo) or set it themselves:

    ```bash
    gh secret set RELEASE_TOKEN --body "<token>" --repo <owner>/<repo>
    ```

    If `ide__setup_release` reports a missing-permission / 403 error, tell the
    user to re-authorize the RxLab GitHub App (Actions → Secrets: read & write),
    then retry.

    ## 4. Verify

    - `npx semantic-release --dry-run` locally (needs `GITHUB_TOKEN` in the env)
      to confirm `.releaserc` parses and the next version is computed from the
      commit history.
    - Commit `.releaserc` + the workflow, then create a release from RxCode's
      "Create Release" button (or run the workflow via `workflow_dispatch`) and
      confirm the GitHub release + tag appear.

    Be concrete: read the repo, write both files, confirm the trigger choice with
    the user, install the token via `ide__setup_release`, and tell the user
    exactly what you changed.
    """#
}
