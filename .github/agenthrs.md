# agenthrs (GitHub hub → agentdesk PC)

This repo is the **hub**: [hafizrs/agenthrs-hub](https://github.com/hafizrs/agenthrs-hub). Create issues here (phone is fine). `/repohrs owner/name` is the GitHub repo the desk PC should edit. Do not put app code in this hub.

## How it works (Cursor-like)

Same **issue** = same **window**.

1. First message: create a branch from the base you name, then work.
2. Next comments on **that same issue**: wait until the current run finishes, then continue. **Same branch. No second branch.**
3. A **different issue** is a different window. It does not sit in a global line behind other cards.
4. `/agenthrs new` on an issue = new window + new branch from `/basehrs`.

```text
Issue #12 comment 1  →  create branch from main  →  run
Issue #12 comment 2  →  wait for #12 run 1       →  same branch, next message
Issue #13            →  separate window (not queued behind #12's follow-ups)
```

GitHub Actions concurrency is **per issue**, `cancel-in-progress: false`, so follow-ups wait like Cursor chat. They are not a cross-task queue.

Work stays on the PC under `%USERPROFILE%\.agenthrs\work\...` so the same window keeps its files and branch.

## Commands

```text
/agenthrs start
/agenthrs continue
/agenthrs new
/agenthrs stop
/agenthrs hold
/agenthrs queue
/stophs
/continuehrs

/modelhrs auto
/repohrs hafizrs/pm
/workspacehrs pm

/basehrs main
/branchhrs feature-login
/keepbranchhrs
/pushhrs
```

## If you fill nothing

All form fields are optional. A title + label `agenthrs` is enough.

| You omit | Default |
|---|---|
| Target repo | **required** (`/repohrs owner/name`) — this hub has no app code |
| Base branch | `main` |
| Working branch | auto `agenthrs/hub-<issue>-w1` |
| Model | `auto` |
| Workspace | repo root |
| Session | new window |
| Task | the issue **title** |
| Branch behavior | **always create a new branch** from `main` |
| Push | off |

## Stop and continue (this window)

```text
/stophs
/agenthrs stop
```

Pauses this issue. Follow-up comments are ignored until you resume.

```text
/continuehrs
/agenthrs continue
```

Resumes the **same window and same branch**.

## Keep current branch and push (opt-in)

Default is still **create a new branch**. To stay on an existing branch and push:

```text
/keepbranchhrs
/branchhrs main
/pushhrs
Fix the login bug and push.
```

Same-window later comments still do not create another branch.

## Example

```text
/agenthrs start
/repohrs hafizrs/pm
/workspacehrs VibeDocx
/basehrs main
/branchhrs agenthrs/dark-mode
/modelhrs auto

Add a dark-mode toggle on settings.
```

Then on the same issue:

```text
also add a test
```

That waits for the first run, then continues on `agenthrs/dark-mode`. It does not create another branch.

New attempt:

```text
/agenthrs new
/basehrs develop
```

New window, new branch from `develop`.

## Setup (once)

```powershell
agent login
```

1. [New Windows runner on this hub](https://github.com/hafizrs/agenthrs-hub/settings/actions/runners/new)  
2. Labels: `self-hosted`, `Windows`, **`agentdesk`**  
3. `powershell -File .\scripts\start-desk-runner.ps1` — leave it open at the desk  

Other private repos: hub secret `AGENTHRS_GITHUB_TOKEN`.
