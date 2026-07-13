# External User Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a one-line, no-sudo installer and global `dev-workflow` command that manage stable or edge Codex/Cursor installations from any directory, with candidate validation and automatic rollback.

**Architecture:** A small root `install.sh` bootstraps a managed bare Git clone and delegates activation to a Python standard-library manager. `bin/dev-workflow` is a thin executable entry point. Immutable commit worktrees, an atomic `current` symlink, and an atomic JSON state file separate candidate preparation from activation; existing platform installers and doctor remain the implementation layer for Codex and Cursor integration.

**Tech Stack:** Python 3 standard library, Bash, Git, `unittest`, shell integration tests

## Global Constraints

- Do not modify or migrate `~/.dev-workflow/` user data.
- Do not manage Claude Code installation; Claude continues to use Marketplace.
- Do not use `sudo`, edit shell startup files, delete old versions, or silently fall back from stable to edge.
- Preserve existing source-checkout workflows in `bin/install-codex`, `bin/install-cursor`, `bin/update`, and `bin/doctor`.
- Treat platform installer and doctor failures as activation failures and restore the previous active version and state.
- Use `DEV_WORKFLOW_REPO_URL`, `DEV_WORKFLOW_INSTALL_ROOT`, and `DEV_WORKFLOW_BIN_DIR` in tests so no real user installation is touched.

---

### Task 1: Managed repository, revision, and state primitives

**Files:**
- Create: `scripts/managed_install.py`
- Create: `tests/test_managed_install.py`

- [x] Add unit tests for semantic-tag filtering and ordering (`v0.7.0` beats `v0.6.9`; prerelease and malformed tags are ignored), stable/edge revision selection, default install paths, and atomic JSON state round-tripping with unknown fields preserved.
- [x] Run `python3 -m unittest tests.test_managed_install -v` and confirm it fails because the manager module does not exist.
- [x] Implement `InstallPaths`, command execution helpers, repository initialization/fetching, `resolve_revision(channel)`, state loading, and atomic state writing using only the Python standard library.
- [x] Run `python3 -m unittest tests.test_managed_install -v` and confirm the new primitive tests pass.
- [x] Commit with `git add scripts/managed_install.py tests/test_managed_install.py && git commit -m "feat: add managed install primitives"`.

### Task 2: Candidate validation, activation, and rollback

**Files:**
- Modify: `scripts/managed_install.py`
- Modify: `tests/test_managed_install.py`

- [x] Add unit tests for matching plugin manifest versions, required scripts and bundled skill files, checked-out commit equality, stable tag/version equality, atomic `current` replacement, first-install failure cleanup, and restoration of the previous symlink and state after a simulated platform or doctor failure.
- [x] Run `python3 -m unittest tests.test_managed_install -v` and confirm the new tests fail at the missing validation and activation interfaces.
- [x] Implement candidate worktree creation/reuse, `validate_candidate`, mkdir-based update locking, temporary-symlink activation, platform command construction, doctor execution, state commit, and rollback/relink behavior.
- [x] Ensure successful state contains schema version, channel, sorted installed platforms, active ref, active commit, manifest version, and UTC update time.
- [x] Run `python3 -m unittest tests.test_managed_install -v` and confirm all unit tests pass.
- [x] Commit with `git add scripts/managed_install.py tests/test_managed_install.py && git commit -m "feat: validate and atomically activate managed versions"`.

### Task 3: Global CLI and platform routing

**Files:**
- Create: `bin/dev-workflow`
- Create: `tests/managed-install.sh`
- Modify: `scripts/managed_install.py`

- [ ] Build a temporary local Git remote in `tests/managed-install.sh` and add failing integration cases for `status`, `update --channel stable|edge`, `install codex|cursor|all`, `doctor` argument forwarding, platform recording only after success, lock contention, and invocation outside the repository checkout.
- [ ] Use test-only stub platform installers and doctor scripts in fixture commits so routing and rollback are deterministic without touching real Codex or Cursor homes.
- [ ] Run `bash tests/managed-install.sh` and confirm it fails because the global entry point and command parser are absent.
- [ ] Add the executable Python entry point and implement public command parsing, offline status output, channel persistence, recorded-platform updates, explicit dependency forwarding, reload guidance, and actionable PATH warnings.
- [ ] Run `bash tests/managed-install.sh` and `python3 -m unittest tests.test_managed_install -v`; confirm both pass.
- [ ] Commit with `git add bin/dev-workflow scripts/managed_install.py tests/managed-install.sh && git commit -m "feat: add global dev-workflow CLI"`.

### Task 4: One-line bootstrap and end-to-end rollback

**Files:**
- Create: `install.sh`
- Modify: `tests/managed-install.sh`

- [ ] Add failing integration cases for bootstrap argument exclusivity, missing prerequisites, stable first install, edge first install, stable/edge switching, idempotent update, missing stable tags, manifest/tag mismatch, platform failure rollback, doctor failure rollback, preservation of pre-existing `DEV_WORKFLOW_DATA`, and global command symlink creation.
- [ ] Run `bash tests/managed-install.sh` and confirm bootstrap cases fail because `install.sh` does not exist.
- [ ] Implement a compact POSIX-compatible bootstrap that validates arguments and prerequisites, initializes/fetches the managed bare clone, resolves the first revision, creates its immutable worktree, and invokes that candidate's internal bootstrap command.
- [ ] Keep bootstrap source URL and filesystem roots overridable, never request `sudo`, and print an inspect-before-run alternative plus Codex/Cursor reload guidance.
- [ ] Run `bash tests/managed-install.sh`, `bash tests/install-codex.sh`, `bash tests/install-cursor.sh`, `bash tests/update.sh`, and `bash tests/doctor.sh`; confirm all pass.
- [ ] Commit with `git add install.sh tests/managed-install.sh && git commit -m "feat: add one-line managed installer"`.

### Task 5: Release metadata, documentation, and completion gates

**Files:**
- Modify: `.codex-plugin/plugin.json`
- Modify: `.cursor-plugin/plugin.json`
- Modify: `.claude-plugin/plugin.json`
- Modify: `README.md`
- Modify: `tests/all.sh`
- Modify: `tests/managed-install.sh`

- [ ] Add a failing assertion that all three manifests report `0.7.0` and that a stable `v0.7.0` fixture activates only when its tag and manifests agree.
- [ ] Run `bash tests/managed-install.sh` and confirm the release-version assertion fails against `0.6.0`.
- [ ] Set all plugin manifests to `0.7.0`, register managed installer unit/integration tests in `tests/all.sh`, and document stable/edge curl installation, global updates, status/doctor, PATH behavior, inspect-before-run, source-checkout maintenance, Claude Marketplace scope, and the first-tag release sequence.
- [ ] Run `bash tests/all.sh` and confirm the full repository suite passes.
- [ ] Scan changed files with `rg -n "TO""DO|TB""D|FIX""ME|place""holder" install.sh bin/dev-workflow scripts/managed_install.py tests/managed-install.sh tests/test_managed_install.py README.md` and resolve any unfinished markers.
- [ ] Run `git diff --check` and `bash -n install.sh tests/managed-install.sh bin/dev-workflow` (where applicable), then inspect `git diff --stat` and `git status --short`.
- [ ] Record fresh codegraph evidence or an explicit unavailable reason, run the required external cross-review on the complete diff, address blocking findings, and rerun `bash tests/all.sh` after review changes.
- [ ] Record final workflow-compliance evidence and pass the L1 completion gate before claiming completion.
- [ ] Commit with `git add .codex-plugin/plugin.json .cursor-plugin/plugin.json .claude-plugin/plugin.json README.md tests/all.sh tests/managed-install.sh && git commit -m "docs: publish managed installer workflow"`.

## Post-Merge Release Runbook

1. Confirm the merge commit passes CI and all three manifests contain `0.7.0`.
2. Create and push annotated tag `v0.7.0` on that merge commit.
3. Create the GitHub Release and publish the stable one-line command.
4. Run the stable bootstrap against GitHub in a clean temporary HOME, verify `dev-workflow status`, then remove only that temporary HOME.
