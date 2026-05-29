# Git Worktrees

RxCode runs every thread inside a working directory. Git worktrees let one repository host several working directories at the same time, each on its own branch, so multiple agents can edit the same project without stepping on each other.

## Why Use a Worktree

- **Parallel threads** — run one agent on a refactor branch while another keeps your main branch ready for review.
- **Safe experiments** — let an agent try a risky change in an isolated tree; discard it by removing the worktree, no `git reset` required.
- **No stash juggling** — switch between in-progress work without committing, stashing, or shelving local edits.

Worktrees share the same `.git` storage with the main checkout, so branches, tags, refs, and reflogs all stay in sync.

## Creating a Worktree

Open a project, then use **Project Menu -> Add Worktree** in the sidebar. Provide:

- **Branch** — pick an existing branch or create a new one.
- **Base** — when creating a new branch, the ref to branch off (defaults to the current HEAD).
- **Path** — RxCode suggests a sibling directory next to the repository. Accept it or pick another empty location.

Behind the scenes, RxCode invokes:

```sh
git worktree add <path> <branch>
# or, for a new branch:
git worktree add -b <branch> <path> <base>
```

The new worktree appears in the project list with a small fork icon. Selecting it switches the agent's working directory to the worktree path.

## Working Inside a Worktree

A thread running in a worktree behaves like any other project:

- File reads, diffs, terminal commands, and run profiles all operate against the worktree path.
- Permission prompts, change tracking, and the inspector show changes scoped to that tree.
- Mobile sync mirrors the worktree's path so the device shows the right project name.

## Removing a Worktree

Right-click the worktree in the sidebar and choose **Remove**. RxCode runs:

```sh
git worktree remove <path>
```

If the working tree has uncommitted changes, RxCode warns first. Use **Force Remove** only when you intentionally want to discard the worktree's local changes — the operation cannot be undone.

After removal, the underlying branch still exists. Delete the branch separately if it is no longer needed.

## Tips

- Keep worktrees in a sibling directory tree (for example `~/code/<repo>/<branch>`) so VS Code, Xcode, and other tools open the right files.
- Avoid running two agents simultaneously on worktrees that share build artifacts in the same path (for example a shared `node_modules`). Use separate worktrees with their own dependency installs.
- `git worktree prune` cleans up stale worktree metadata if a directory was deleted outside RxCode. Open Terminal in the repository and run it manually if a worktree disappears from disk but lingers in `git worktree list`.

## Limitations

- A single branch can be checked out in only one worktree at a time. Switch worktrees or check out a different branch.
- Submodules in additional worktrees may require an extra `git submodule update --init` after creation.
- Some Git hosting providers' large-file storage (Git LFS) needs `git lfs install --worktree` inside each new worktree before LFS pointers resolve.
