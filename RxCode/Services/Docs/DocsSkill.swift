import Foundation

/// The docs-publishing skill, bundled as a string so the docs-setup hook can
/// inject it as a system prompt with no app-resource plumbing. Distilled from
/// argo-trading's docs CI (the `rxtech-lab/docs-publishing` skill is the
/// canonical, evolving copy — keep this in sync when that PR lands).
enum DocsSkill {
    static let systemPrompt: String = #"""
    # Skill: Set up documentation publishing

    You are setting up automatic documentation publishing for this repository so
    its docs are indexed by the docs service (https://autopilot.rxlab.app) and
    become searchable in RxCode (⌘K → Docs and the `ide__search_docs` tool).

    Follow these steps end to end. Inspect the repo first to choose the right doc
    generators for its languages, then wire up the uploader, the CI workflow, and
    the repo secret.

    ## 1. Author / collect the docs under `docs/`

    Every doc is a markdown file under `docs/` with YAML frontmatter. The `slug`
    is the contract — it becomes the remote `docId` and must be unique:

    ```markdown
    ---
    slug: architecture/overview
    title: Architecture Overview
    description: High-level design of the system
    ---

    # Architecture Overview
    ...
    ```

    Produce these doc types as applicable to the repo:
    - **Design / architecture docs** — handwritten markdown. Always include at
      least an overview.
    - **API docs** — if the repo exposes an API, generate/commit the OpenAPI or
      Swagger spec and a markdown reference under `docs/api/`.
    - **Code docs** — pick the generator for the repo's language and emit markdown
      into `docs/`:
      - Go: `go doc` / `gomarkdoc ./... > docs/code/go.md`
      - TypeScript/JavaScript: `typedoc` (or `jsdoc`) with a markdown plugin
      - Java: `javadoc` (convert to markdown or commit the HTML under `docs/`)
    Give each generated file unique `slug` frontmatter.

    ## 2. Add the uploader script `scripts/upload_docs.py`

    Stdlib-only (no pip installs). It walks `docs/`, parses frontmatter, keeps
    files with a `slug`, errors on duplicate slugs, and POSTs in batches of 50 to
    `{DOCS_ENDPOINT}/api/v1/docs/repositories/{url-encoded repo}/documents` with
    `Authorization: Bearer $DOCS_UPLOAD_TOKEN` and body
    `{"documents":[{"docId": slug, "content": body}, ...]}`. Support `--dry-run`
    and env config: `DOCS_ENDPOINT` (default https://autopilot.rxlab.app),
    `DOCS_REPOSITORY_ID` (e.g. `owner/repo`), `DOCS_UPLOAD_TOKEN`.

    ## 3. Add the GitHub Actions workflow `.github/workflows/upload-docs.yaml`

    ```yaml
    name: Upload docs to autopilot
    on:
        push:
            branches: ["main"]
            paths:
                - "docs/**"
                - "scripts/upload_docs.py"
                - ".github/workflows/upload-docs.yaml"
        workflow_dispatch:
    concurrency:
        group: upload-docs
        cancel-in-progress: false
    jobs:
        upload:
            runs-on: ubuntu-latest
            steps:
                - uses: actions/checkout@v6
                - uses: actions/setup-python@v6
                  with:
                      python-version: "3.x"
                - name: Upload docs
                  env:
                      DOCS_ENDPOINT: https://autopilot.rxlab.app
                      DOCS_REPOSITORY_ID: <owner>/<repo>
                      DOCS_UPLOAD_TOKEN: ${{ secrets.DOCS_UPLOAD_TOKEN }}
                  run: python scripts/upload_docs.py
    ```

    ## 4. Install the `DOCS_UPLOAD_TOKEN` repo secret

    Do this yourself — don't make the user run a command. Call the
    **`ide__setup_docs_secret`** MCP tool, passing `repository: "<owner>/<repo>"`.
    It mints a `DOCS_UPLOAD_TOKEN` and installs it as the repo's GitHub Actions
    secret in one step; the token never needs to be copied or pasted. If the repo
    isn't registered with the docs service yet, the tool registers it for you
    first (the RxLab GitHub App must be installed on it). If the tool reports a
    missing-permission / 403 error, tell the user to re-authorize the RxLab
    GitHub App (Actions → Secrets: read & write), then retry.

    Fallbacks when `ide__setup_docs_secret` isn't available (e.g. running this
    skill outside RxCode):
    - RxCode UI: Settings → Autopilot → Manage Docs → open the repo → "Install
      DOCS_UPLOAD_TOKEN secret".
    - Mint a token (`POST /api/v1/docs/repositories/{id}/upload-tokens`, shown
      once) and install it manually:
      ```bash
      gh secret set DOCS_UPLOAD_TOKEN --body "<dput_… or dpat_… token>" --repo <owner>/<repo>
      ```

    ## 5. Verify

    - `python scripts/upload_docs.py --dry-run` — confirms frontmatter parses and
      batches build with no network call.
    - Commit to `main` (or run the workflow via `workflow_dispatch`) and confirm
      the upload succeeds. Uploads are async: the API returns `202` + a `jobId`;
      docs become searchable once embedding finishes.

    Be concrete: read the repo, pick the right generators, write the files, run
    the dry run, and tell the user exactly what you changed and what token to set.
    """#
}
