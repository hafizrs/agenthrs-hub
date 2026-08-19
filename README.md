# agenthrs-hub

Command Cursor on your desk PC **from this GitHub repo** (website or mobile). Issues here are the cards. `/repohrs owner/name` is the codebase to edit.

Full usage: [`.github/agenthrs.md`](.github/agenthrs.md)

## From GitHub

1. **Issues → New issue → agenthrs task**
2. Set **Target repo** (example `hafizrs/pm`) and the task
3. Watch comments on that issue

Same issue = same window (follow-ups wait, then continue on the same branch). A new issue = a new window.

```text
/repohrs hafizrs/pm
/basehrs main
/modelhrs auto
Add dark mode on settings.
```

Later on the same issue: `also add a test`

Stop: `/stophs`  
Continue: `/continuehrs`

## Once on the desk PC

1. `agent login`
2. Add a Windows self-hosted runner on **this** repo with labels `self-hosted`, `Windows`, `agentdesk`  
   https://github.com/hafizrs/agenthrs-hub/settings/actions/runners/new
3. `powershell -File .\scripts\start-desk-runner.ps1` (leave it open)

Secrets on this repo:

- `AGENTHRS_GITHUB_TOKEN` — PAT with `repo` so the PC can clone/push your other private repos
- `CURSOR_API_KEY` — optional if the runner is not the same user as `agent login`
