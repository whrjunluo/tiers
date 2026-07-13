# External User Installer and Global CLI Design

Date: 2026-07-13
Status: Approved for planning
Level: L1

## Problem

Codex and Cursor users currently clone the tiers repository, enter that checkout, and run repository-local install or update scripts. This works for maintainers but exposes Git branches, paths, and cache details to ordinary plugin users. The desired experience is a one-line bootstrap followed by a global `dev-workflow` command that works from any directory.

## Goals

- Install Codex, Cursor, or both from one HTTPS bootstrap command without `sudo`.
- Store plugin source in a tool-managed location rather than a user-managed checkout.
- Provide stable and edge channels: stable follows the latest semantic `v*` tag; edge follows `origin/main`.
- Update and inspect the installation from any directory.
- Validate a candidate before activation and automatically restore the previous version if platform installation or doctor fails.
- Preserve `~/.dev-workflow/` learning and provider-health data across every install and update.

## Non-Goals

- Managing Claude Code, which continues to use its native Marketplace.
- Homebrew, npm, or another package registry in the first release.
- A manual rollback command or automatic deletion of old versions.
- Installing optional dependencies unless the user explicitly requests them.
- Editing or migrating `~/.dev-workflow/` user data.

## User Interface

Bootstrap examples:

```bash
curl -fsSL https://raw.githubusercontent.com/whrjunluo/tiers/main/install.sh \
  | bash -s -- --codex

curl -fsSL https://raw.githubusercontent.com/whrjunluo/tiers/main/install.sh \
  | bash -s -- --all --channel edge
```

The bootstrap requires exactly one of `--codex`, `--cursor`, or `--all`. The default channel is `stable`.

Installed command contract:

```bash
dev-workflow status
dev-workflow update [--channel stable|edge] [--install-deps]
dev-workflow install codex|cursor|all [--install-deps]
dev-workflow doctor [--repo <path>] [doctor arguments]
```

`status` is offline and reports install root, active channel, active ref and commit, manifest version, installed platforms, and whether a reload is required. `update` uses the recorded platforms. `install` adds a platform to the recorded set only after that platform installer succeeds.

## Filesystem Layout

Defaults:

```text
~/.local/share/dev-workflow/
  source.git/             # managed bare clone
  versions/<commit>/      # immutable Git worktrees
  current -> versions/<commit>
  install.json            # channel, platforms, active ref/commit/version
  update.lock/            # mkdir-based process lock

~/.local/bin/dev-workflow -> ~/.local/share/dev-workflow/current/bin/dev-workflow
```

Environment overrides used by tests and advanced users:

- `DEV_WORKFLOW_REPO_URL`
- `DEV_WORKFLOW_INSTALL_ROOT`
- `DEV_WORKFLOW_BIN_DIR`
- existing `CODEX_HOME`, `CURSOR_HOME`, and `DEV_WORKFLOW_DATA`

The global CLI warns when its bin directory is absent from `PATH`; it does not edit shell startup files.

## Components

### `install.sh`

The root bootstrap is intentionally small. It validates `git`, `python3`, and the requested platform/channel arguments, initializes the managed bare clone, resolves the requested revision, creates the first candidate worktree, and invokes that candidate's `bin/dev-workflow` installer. HTTPS GitHub is the default source. Tests replace it with a local repository URL.

### `bin/dev-workflow`

This is the installed management CLI. It owns revision resolution, candidate validation, atomic activation, platform refresh, rollback, status, and doctor routing. Existing `bin/install-codex`, `bin/install-cursor`, and `bin/doctor` remain the platform-specific implementation layer.

### `install.json`

State is written with Python's JSON library through a temporary file and `os.replace`. Required fields are schema version, channel, installed platforms, active ref, active commit, manifest version, and update timestamp. Unknown future fields are preserved when possible. The file contains no credentials.

## Revision Resolution

The managed clone always fetches origin before resolving a candidate.

- `stable`: select the highest semantic tag matching `v<major>.<minor>.<patch>`. A repository with no matching tag fails without changing `current` or `install.json`.
- `edge`: resolve `refs/remotes/origin/main`.

Only `stable` and `edge` are accepted channel values. The selected channel is persisted only after a successful activation. The first stable release for this feature is `v0.7.0`, with all three plugin manifests set to `0.7.0`.

## Candidate Validation

Before activation, the CLI verifies:

- `.codex-plugin/plugin.json`, `.cursor-plugin/plugin.json`, and `.claude-plugin/plugin.json` parse as JSON and have the same version.
- the checked-out commit matches the resolved revision.
- `bin/install-codex`, `bin/install-cursor`, `bin/doctor`, and all three bundled skill files exist.
- a stable tag's version equals the manifest version after removing the leading `v`.

Validation does not run the repository's full test suite on user machines.

## Atomic Activation and Rollback

Updates use a `mkdir` lock so a second process fails immediately with a clear message. A new commit receives its own `versions/<commit>` worktree. Existing worktrees are reused only when clean and at the exact commit.

Activation proceeds as follows:

1. Save the old `current` target and configuration.
2. Create a temporary symlink to the candidate and atomically rename it to `current`.
3. Invoke each recorded platform installer with `DEV_WORKFLOW_PLUGIN_ROOT=<install-root>/current` and non-interactive confirmation.
4. Run doctor from `current`; required tools and bundled skills must not be broken.
5. Atomically write `install.json` with the new channel and revision.

If a platform installer or doctor fails, restore the old `current`, rerun the old platform installers to repair links, restore the old configuration, and return a non-zero exit. The failed candidate remains inactive for diagnosis. On first install, failure removes `current` and leaves no successful installation record.

## Platform Behavior

- Codex uses the existing local marketplace, manifest-version cache, config enablement, and skill links.
- Cursor uses the existing skill links and does not install unsupported prompt hooks.
- `all` executes both installers and records both only after both succeed.
- Optional companion dependencies are installed only with `--install-deps`.
- Every successful platform operation prints the required Codex restart or Cursor Reload Window guidance.

## Security and Trust

- No command uses `sudo`, force-push, reset, or destructive cleanup of user files.
- The bootstrap and Git transport use HTTPS by default.
- Repository, install root, and bin overrides are explicit environment inputs, primarily for tests and controlled mirrors.
- The first version trusts GitHub HTTPS and repository tags; signed-release verification is deferred and documented as residual risk.
- Piping a script to shell remains an informed trust decision, so README also documents downloading and inspecting `install.sh` before execution.

## Tests

Tests run under temporary HOME, install root, bin directory, Codex home, and Cursor home with a local Git remote. They cover:

- stable first install from a semantic tag
- edge first install from main
- stable-to-edge and edge-to-stable switching
- idempotent update and unchanged revision
- invocation from outside the source repository
- Codex, Cursor, and all-platform routing
- missing stable tag
- invalid channel and missing prerequisites
- manifest mismatch and tag/version mismatch
- platform installer failure rollback
- doctor failure rollback
- preservation of pre-existing user data
- process-lock contention
- offline `status` output

The existing install, update, doctor, and full repository suites continue to run.

## Release Sequence

1. Merge implementation with manifests at `0.7.0` while stable bootstrap is not yet advertised.
2. Confirm CI and external cross-review on the merge commit.
3. Create and push annotated tag `v0.7.0`.
4. Create the GitHub Release and publish the one-line stable installation command.
5. Smoke-test stable bootstrap in a clean temporary HOME.

This order keeps `stable` unavailable rather than silently falling back to main before the first release exists.
