#Requires -Version 5.1
<#
.SYNOPSIS
  GitHub-controlled desk agent (agenthrs / agentdesk).
  Hub: command any repo from this repo's issues via /repohrs owner/name.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ApiVersion = "2022-11-28"
$BotMarker = "<!-- agenthrs-bot -->"
$SessionMarker = "<!-- agenthrs-session:"
$ModelMarker = "<!-- agenthrs-model:"
$WorkspaceMarker = "<!-- agenthrs-workspace:"
$TargetRepoMarker = "<!-- agenthrs-repo:"
$BaseBranchMarker = "<!-- agenthrs-base:"
$WorkBranchMarker = "<!-- agenthrs-branch:"
$KeepBranchMarker = "<!-- agenthrs-keepbranch:"
$PushMarker = "<!-- agenthrs-push:"
$WindowMarker = "<!-- agenthrs-window:"
$RunMarker = "<!-- agenthrs-run:"
$QueueLabel = "agenthrs"
$StatusLabels = @("queuedhrs", "runninghrs", "donehrs", "holdhrs", "blockedhrs")
$ModelAliases = @{
  "auto"      = "auto"
  "composer"  = "composer-2.5"
  "composer2" = "composer-2.5"
  "grok"      = "cursor-grok-4.6-high"
  "sonnet"    = "claude-sonnet-5-thinking-high"
  "opus"      = "claude-opus-5-thinking-high"
  "gpt"       = "gpt-5.4-high"
}

function Get-HubRepo {
  $repo = $env:GITHUB_REPOSITORY
  if (-not $repo) { throw "GITHUB_REPOSITORY is not set." }
  $parts = $repo.Split("/")
  return @{ Owner = $parts[0]; Name = $parts[1]; Full = $repo }
}

function Parse-RepoSlug {
  param([string]$Raw)
  if (-not $Raw) { return $null }
  $slug = $Raw.Trim().TrimStart("/").Replace("https://github.com/", "").Replace("http://github.com/", "")
  $slug = $slug.TrimEnd("/").TrimEnd(".git")
  if ($slug -notmatch '^[\w.-]+/[\w.-]+$') { throw "Repo must look like owner/name. Got '$Raw'." }
  $parts = $slug.Split("/")
  return @{ Owner = $parts[0]; Name = $parts[1]; Full = $slug }
}

function Invoke-GitHub {
  param(
    [Parameter(Mandatory)][string]$Method,
    [Parameter(Mandatory)][string]$Path,
    [object]$Body
  )
  $token = $env:AGENTHRS_GITHUB_TOKEN
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  if (-not $token) { throw "GITHUB_TOKEN is not set." }
  $headers = @{
    Authorization          = "Bearer $token"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = $ApiVersion
    "User-Agent"           = "agenthrs-desk"
  }
  $uri = "https://api.github.com$Path"
  if ($null -ne $Body) {
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType "application/json" -Body $json
  }
  return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
}

function Ensure-Labels {
  param([Parameter(Mandatory)]$Repo)
  $wanted = @(
    @{ name = "agenthrs"; color = "0E8A16"; description = "Desk PC agenthrs queue" },
    @{ name = "queuedhrs"; color = "FBCA04"; description = "Waiting on agentdesk runner" },
    @{ name = "runninghrs"; color = "1D76DB"; description = "agenthrs is working on the desk PC" },
    @{ name = "donehrs"; color = "0E8A16"; description = "agenthrs finished" },
    @{ name = "holdhrs"; color = "C5DEF5"; description = "Pause follow-ups on this window" },
    @{ name = "blockedhrs"; color = "E11D48"; description = "Last agenthrs run failed" }
  )
  $existing = @()
  try { $existing = @(Invoke-GitHub -Method GET -Path "/repos/$($Repo.Full)/labels?per_page=100") } catch { $existing = @() }
  $names = @($existing | ForEach-Object { $_.name })
  foreach ($label in $wanted) {
    if ($names -notcontains $label.name) {
      try { Invoke-GitHub -Method POST -Path "/repos/$($Repo.Full)/labels" -Body $label | Out-Null } catch { }
    }
  }
}

function Get-Issue {
  param($Repo, [int]$Number)
  Invoke-GitHub -Method GET -Path "/repos/$($Repo.Full)/issues/$Number"
}

function Get-IssueComments {
  param($Repo, [int]$Number)
  Invoke-GitHub -Method GET -Path "/repos/$($Repo.Full)/issues/$Number/comments?per_page=100"
}

function Add-IssueComment {
  param($Repo, [int]$Number, [string]$Body)
  Invoke-GitHub -Method POST -Path "/repos/$($Repo.Full)/issues/$Number/comments" -Body @{ body = "$BotMarker`n$Body" }
}

function Set-IssueLabels {
  param($Repo, $Issue, [string[]]$Add, [string[]]$Remove)
  $current = @($Issue.labels | ForEach-Object { $_.name })
  $next = @($current | Where-Object { $Remove -notcontains $_ })
  foreach ($name in $Add) {
    if ($next -notcontains $name) { $next += $name }
  }
  Invoke-GitHub -Method PUT -Path "/repos/$($Repo.Full)/issues/$($Issue.number)/labels" -Body @{ labels = @($next) } | Out-Null
}

function Set-StatusLabel {
  param($Repo, $Issue, [string]$Status)
  $statusName = if ($Status -match 'hrs$') { $Status } else { "$Status`hrs" }
  $remove = @($StatusLabels | Where-Object { $_ -ne $statusName })
  Set-IssueLabels -Repo $Repo -Issue $Issue -Add @($QueueLabel, $statusName) -Remove $remove
}

function Read-HiddenValue {
  param([string]$Text, [string]$Marker)
  if (-not $Text) { return $null }
  $pattern = [regex]::Escape($Marker) + "\s*([^\s<]+)\s*-->"
  $found = [regex]::Matches($Text, $pattern)
  if ($found.Count -eq 0) { return $null }
  return $found[$found.Count - 1].Groups[1].Value.Trim()
}

function Get-MetaFromText {
  param([string]$Text)
  return @{
    Session     = Read-HiddenValue -Text $Text -Marker $SessionMarker
    Model       = Read-HiddenValue -Text $Text -Marker $ModelMarker
    Workspace   = Read-HiddenValue -Text $Text -Marker $WorkspaceMarker
    TargetRepo  = Read-HiddenValue -Text $Text -Marker $TargetRepoMarker
    BaseBranch  = Read-HiddenValue -Text $Text -Marker $BaseBranchMarker
    WorkBranch  = Read-HiddenValue -Text $Text -Marker $WorkBranchMarker
    WindowId    = Read-HiddenValue -Text $Text -Marker $WindowMarker
    KeepBranch  = ((Read-HiddenValue -Text $Text -Marker $KeepBranchMarker) -eq "true")
    Push        = ((Read-HiddenValue -Text $Text -Marker $PushMarker) -eq "true")
    RunId       = Read-HiddenValue -Text $Text -Marker $RunMarker
  }
}

function Get-WindowMeta {
  param($Repo, $Issue, [int]$WindowId)
  try {
    $comments = @(Get-IssueComments -Repo $Repo -Number $Issue.number)
  } catch { return $null }
  $chosen = $null
  foreach ($c in $comments) {
    if ($c.body -notmatch [regex]::Escape($BotMarker)) { continue }
    $wid = Read-HiddenValue -Text $c.body -Marker $WindowMarker
    if ($wid -eq "$WindowId") { $chosen = $c.body }
  }
  if (-not $chosen) { return $null }
  return Get-MetaFromText -Text $chosen
}

function Format-WindowList {
  param($Repo, $Issue, [string]$ActiveId)
  try {
    $comments = @(Get-IssueComments -Repo $Repo -Number $Issue.number)
  } catch { $comments = @() }
  $map = @{}
  foreach ($c in $comments) {
    if ($c.body -notmatch [regex]::Escape($BotMarker)) { continue }
    $wid = Read-HiddenValue -Text $c.body -Marker $WindowMarker
    if (-not $wid) { continue }
    $map[$wid] = Get-MetaFromText -Text $c.body
  }
  if ($map.Count -eq 0) { return "No windows on this issue yet." }
  $lines = @("Windows on this issue (comment here = this card):", "")
  foreach ($wid in ($map.Keys | Sort-Object { [int]$_ })) {
    $m = $map[$wid]
    $star = if ($wid -eq "$ActiveId") { " **active**" } else { "" }
    $lines += "- **w$wid**$star | branch ``$($m.WorkBranch)`` | session ``$($m.Session)``"
  }
  $lines += ""
  $lines += "``/stophs`` or ``/continuehrs`` with no number = **active** window."
  $lines += "``/stophs w1`` or ``/continuehrs w2`` picks a window."
  return ($lines -join "`n")
}

function Resolve-Model {
  param([string]$Raw)
  if (-not $Raw) { return "auto" }
  $key = $Raw.Trim().ToLowerInvariant()
  if ($ModelAliases.ContainsKey($key)) { return $ModelAliases[$key] }
  return $Raw.Trim()
}

function Assert-GitRef {
  param([string]$Name, [string]$Kind)
  if (-not $Name -or $Name -notmatch '^[\w][\w./-]*$') { throw "Invalid $Kind '$Name'." }
  if ($Name.Contains("..")) { throw "Invalid $Kind '$Name'." }
}

function Get-CloneUrl {
  param([string]$Slug)
  $token = $env:AGENTHRS_GITHUB_TOKEN
  if (-not $token) { $token = $env:GITHUB_TOKEN }
  return "https://x-access-token:${token}@github.com/$Slug.git"
}

function Invoke-Git {
  param([string]$Dir, [string[]]$GitArgs)
  $prev = Get-Location
  Set-Location $Dir
  try {
    & git @GitArgs
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed in $Dir" }
  } finally {
    Set-Location $prev
  }
}

function Get-WorkDir {
  param($TargetRepo, [int]$IssueNumber, [int]$WindowId)
  return Join-Path $env:USERPROFILE ".agenthrs\work\$($TargetRepo.Owner)\$($TargetRepo.Name)\hub-$IssueNumber-w$WindowId"
}

function Prepare-WindowRepo {
  param(
    $TargetRepo,
    [int]$IssueNumber,
    [int]$WindowId,
    [string]$BaseBranch,
    [string]$WorkBranch,
    [bool]$NewWindow,
    [bool]$KeepExisting
  )
  Assert-GitRef -Name $WorkBranch -Kind "branchhrs"
  if (-not $KeepExisting) { Assert-GitRef -Name $BaseBranch -Kind "basehrs" }
  $dir = Get-WorkDir -TargetRepo $TargetRepo -IssueNumber $IssueNumber -WindowId $WindowId
  $gitDir = Join-Path $dir ".git"
  $url = Get-CloneUrl -Slug $TargetRepo.Full

  if ($NewWindow -or -not (Test-Path $gitDir)) {
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path (Split-Path $dir) | Out-Null
    & git clone $url $dir
    if ($LASTEXITCODE -ne 0) { throw "Could not clone $($TargetRepo.Full). For private repos add secret AGENTHRS_GITHUB_TOKEN." }
    if ($KeepExisting) {
      Invoke-Git -Dir $dir -GitArgs @("fetch", "origin", $WorkBranch, "--update-head-ok")
      Invoke-Git -Dir $dir -GitArgs @("checkout", "-B", $WorkBranch, "origin/$WorkBranch")
      return @{ Dir = $dir; CreatedBranch = $false; BaseBranch = $WorkBranch; WorkBranch = $WorkBranch }
    }
    Invoke-Git -Dir $dir -GitArgs @("fetch", "origin", $BaseBranch, "--update-head-ok")
    Invoke-Git -Dir $dir -GitArgs @("checkout", "-B", $WorkBranch, "origin/$BaseBranch")
    return @{ Dir = $dir; CreatedBranch = $true; BaseBranch = $BaseBranch; WorkBranch = $WorkBranch }
  }

  $current = & git -C $dir rev-parse --abbrev-ref HEAD
  if ($LASTEXITCODE -ne 0) { throw "Could not read branch in $dir" }
  $current = [string]$current.Trim()
  if ($current -ne $WorkBranch) {
    Invoke-Git -Dir $dir -GitArgs @("checkout", $WorkBranch)
  }
  return @{ Dir = $dir; CreatedBranch = $false; BaseBranch = $BaseBranch; WorkBranch = $WorkBranch }
}

function Resolve-Workspace {
  param([string]$Raw, [string]$Root)
  if (-not $Raw -or $Raw -match '^(root|repo|repo root|\.)$') { return $Root }
  $candidate = Join-Path $Root $Raw.Trim().TrimStart("/", "\")
  $full = [System.IO.Path]::GetFullPath($candidate)
  $rootFull = [System.IO.Path]::GetFullPath($Root)
  if (-not $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Workspace '$Raw' is outside the target repo."
  }
  if (-not (Test-Path $full)) { throw "Workspace folder '$Raw' does not exist in the target repo." }
  return $full
}

function Parse-SlashCommands {
  param([string]$Text)
  $result = @{
    Command      = $null
    Model        = $null
    Workspace    = $null
    Mode         = $null
    TargetRepo   = $null
    BaseBranch   = $null
    WorkBranch   = $null
    KeepBranch   = $false
    Push         = $false
    WindowId     = $null
    Prompt       = $null
    Expect       = $null
  }
  if (-not $Text) { return $result }

  $lines = $Text -split "`r?`n"
  $promptLines = New-Object System.Collections.Generic.List[string]
  foreach ($line in $lines) {
    $trim = $line.Trim()
    if ($trim -match '^(?:\/)?(?:stophs|agenthrs\s+stop)(?:\s+w?(\d+))?\s*$') {
      $result.Command = "stop"
      if ($Matches[1]) { $result.WindowId = [int]$Matches[1] }
      continue
    }
    if ($trim -match '^(?:\/)?(?:continuehrs|agenthrs\s+continue)(?:\s+w?(\d+))?\s*$') {
      $result.Command = "continue"
      if ($Matches[1]) { $result.WindowId = [int]$Matches[1] }
      continue
    }
    if ($trim -match '^(?:\/)?keepbranchhrs\b') {
      $result.KeepBranch = $true
      continue
    }
    if ($trim -match '^(?:\/)?pushhrs\b') {
      $result.Push = $true
      continue
    }
    if ($trim -match '^(?:\/)?agenthrs\s+(start|continue|new|stop|hold|queue|resume)(?:\s+w?(\d+))?\b') {
      $result.Command = $Matches[1].ToLowerInvariant()
      if ($result.Command -eq "resume") { $result.Command = "continue" }
      if ($Matches[2]) { $result.WindowId = [int]$Matches[2] }
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+model|modelhrs)\s+(\S+)') {
      $result.Model = Resolve-Model $Matches[1]
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+workspace|workspacehrs)\s+(\S+)') {
      $result.Workspace = $Matches[1]
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+repo|repohrs)\s+(\S+)') {
      $result.TargetRepo = $Matches[1]
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+mode|modehrs)\s+(agent|plan|ask)\b') {
      $result.Mode = $Matches[1].ToLowerInvariant()
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+base|basehrs)\s+(\S+)') {
      $result.BaseBranch = $Matches[1]
      continue
    }
    if ($trim -match '^(?:\/)?(?:agenthrs\s+branch|branchhrs)\s+(\S+)') {
      $result.WorkBranch = $Matches[1]
      continue
    }
    if ($trim -match '^###\s*Model\s*$') { $result.Expect = "model"; continue }
    if ($trim -match '^###\s*Workspace\s*$') { $result.Expect = "workspace"; continue }
    if ($trim -match '^###\s*Target repo\s*$') { $result.Expect = "repo"; continue }
    if ($trim -match '^###\s*Base branch\s*$') { $result.Expect = "base"; continue }
    if ($trim -match '^###\s*Working branch\s*$') { $result.Expect = "branch"; continue }
    if ($trim -match '^###\s*Session\s*$') { $result.Expect = "session"; continue }
    if ($trim -match '^###\s*Options\s*$') { $result.Expect = "options"; continue }
    if ($trim -match '^###\s*Task\s*$') { $result.Expect = "task"; continue }
    if ($trim -eq "_No response_") { $result.Expect = $null; continue }
    if ($trim -match '^- \[[xX]\]\s*Keep existing branch') { $result.KeepBranch = $true; continue }
    if ($trim -match '^- \[[xX]\]\s*Allow git push') { $result.Push = $true; continue }
    if ($result.Expect -eq "model" -and $trim) { $result.Model = Resolve-Model $trim; $result.Expect = $null; continue }
    if ($result.Expect -eq "workspace" -and $trim) { $result.Workspace = $trim; $result.Expect = $null; continue }
    if ($result.Expect -eq "repo" -and $trim) { $result.TargetRepo = $trim; $result.Expect = $null; continue }
    if ($result.Expect -eq "base" -and $trim) { $result.BaseBranch = $trim; $result.Expect = $null; continue }
    if ($result.Expect -eq "branch" -and $trim) { $result.WorkBranch = $trim; $result.Expect = $null; continue }
    if ($result.Expect -eq "session" -and $trim) {
      if ($trim -match 'continue|same') { $result.Command = "continue" }
      elseif ($trim -match 'new') { $result.Command = "new" }
      $result.Expect = $null
      continue
    }
    $promptLines.Add($line) | Out-Null
  }
  $result.Prompt = ($promptLines -join "`n").Trim()
  return $result
}

function Get-StoredMeta {
  param($Repo, $Issue)
  $blob = "$($Issue.body)`n"
  try {
    $comments = @(Get-IssueComments -Repo $Repo -Number $Issue.number)
    foreach ($c in $comments) { $blob += "$($c.body)`n" }
  } catch { }
  return Get-MetaFromText -Text $blob
}

function Write-MetaComment {
  param($Repo, [int]$Number, [string]$Session, [string]$Model, [string]$Workspace, [string]$TargetRepo, [string]$BaseBranch, [string]$WorkBranch, [string]$WindowId, [bool]$KeepBranch, [bool]$Push)
  $parts = @($BotMarker)
  if ($Session) { $parts += "$SessionMarker $Session -->" }
  if ($Model) { $parts += "$ModelMarker $Model -->" }
  if ($Workspace) { $parts += "$WorkspaceMarker $Workspace -->" }
  if ($TargetRepo) { $parts += "$TargetRepoMarker $TargetRepo -->" }
  if ($BaseBranch) { $parts += "$BaseBranchMarker $BaseBranch -->" }
  if ($WorkBranch) { $parts += "$WorkBranchMarker $WorkBranch -->" }
  if ($WindowId) { $parts += "$WindowMarker $WindowId -->" }
  if ($KeepBranch) { $parts += "$KeepBranchMarker true -->" }
  if ($Push) { $parts += "$PushMarker true -->" }
  if ($env:GITHUB_RUN_ID) { $parts += "$RunMarker $($env:GITHUB_RUN_ID) -->" }
  $branchLine = if ($KeepBranch) { "Same-window follow-ups stay on existing ``$WorkBranch``. No extra branch is created." } else { "Same-window follow-ups stay on ``$WorkBranch`` (created from ``$BaseBranch``). ``/agenthrs new`` makes a new window and a new branch." }
  $parts += $branchLine
  Add-IssueComment -Repo $Repo -Number $Number -Body ($parts -join "`n")
}

function Get-AgentPath {
  $cmd = Get-Command agent -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $ps1 = Join-Path $env:LOCALAPPDATA "cursor-agent\agent.ps1"
  if (Test-Path $ps1) { return $ps1 }
  throw "Cursor CLI ``agent`` not found. Install it and run ``agent login`` as the same Windows user that runs the agentdesk runner."
}

function Invoke-AgentCli {
  param([Parameter(Mandatory)][string[]]$AgentArgs)
  $agent = Get-AgentPath
  if ($agent -like "*.ps1") {
    $output = & powershell.exe -NoProfile -File $agent @AgentArgs 2>&1 | Out-String
  } else {
    $output = & $agent @AgentArgs 2>&1 | Out-String
  }
  return @{ Output = $output; ExitCode = $LASTEXITCODE }
}

function Invoke-LocalAgent {
  param(
    [string]$Prompt,
    [string]$Model,
    [string]$Workspace,
    [string]$SessionId,
    [bool]$NewSession,
    [string]$Mode
  )
  if ($NewSession -or -not $SessionId) {
    $created = Invoke-AgentCli -AgentArgs @("create-chat")
    $SessionId = ($created.Output.Trim() -split "\s+")[-1]
    if (-not $SessionId) { throw "Could not create a Cursor chat session. $($created.Output)" }
  }
  $agentArgs = @(
    "-p", $Prompt,
    "--resume", $SessionId,
    "--model", $Model,
    "--trust",
    "--force",
    "--approve-mcps",
    "--workspace", $Workspace,
    "--output-format", "text"
  )
  if ($Mode -and $Mode -ne "agent") {
    $agentArgs += @("--mode", $Mode)
  }
  $result = Invoke-AgentCli -AgentArgs $agentArgs
  return @{ SessionId = $SessionId; Output = $result.Output; ExitCode = $result.ExitCode }
}

function Truncate {
  param([string]$Text, [int]$Max = 3500)
  if (-not $Text) { return "" }
  if ($Text.Length -le $Max) { return $Text }
  return $Text.Substring(0, $Max) + "`n`n_(truncated)_"
}

# --- main ---
$eventPath = $env:GITHUB_EVENT_PATH
if (-not $eventPath -or -not (Test-Path $eventPath)) { throw "GITHUB_EVENT_PATH missing." }
$event = Get-Content -Raw -Path $eventPath | ConvertFrom-Json
$hub = Get-HubRepo
Ensure-Labels -Repo $hub

$eventName = $env:GITHUB_EVENT_NAME
$issueNumber = $null
$commentBody = $null
$labelName = $null
$sender = $event.sender.login

if ($eventName -eq "issue_comment") {
  if ($event.issue.pull_request) { Write-Output "Ignoring pull request comment."; exit 0 }
  if ($event.comment.body -match [regex]::Escape($BotMarker)) { Write-Output "Ignoring bot comment."; exit 0 }
  if ($sender -match '\[bot\]$') { Write-Output "Ignoring bot user."; exit 0 }
  $issueNumber = [int]$event.issue.number
  $commentBody = [string]$event.comment.body
} elseif ($eventName -eq "issues") {
  if ($event.issue.pull_request) { Write-Output "Ignoring pull request."; exit 0 }
  $issueNumber = [int]$event.issue.number
  if ($event.PSObject.Properties["label"] -and $event.label) {
    $labelName = [string]$event.label.name
  }
  if ($event.action -eq "labeled" -and $StatusLabels -contains $labelName) {
    Write-Output "Ignoring status label '$labelName'."
    exit 0
  }
} elseif ($eventName -eq "workflow_dispatch") {
  $issueNumber = [int]$event.inputs.issue_number
  $commentBody = "/agenthrs $($event.inputs.command)"
} else {
  Write-Output "Unsupported event $eventName"
  exit 0
}

$issue = Get-Issue -Repo $hub -Number $issueNumber
$labelNames = @($issue.labels | ForEach-Object { $_.name })
if ($eventName -eq "issues" -and $event.action -eq "opened" -and $labelNames -notcontains $QueueLabel) {
  Write-Output "Opened issue #$issueNumber without agenthrs label; ignoring."
  exit 0
}
$parsedIssue = Parse-SlashCommands -Text ([string]$issue.body)
$parsedComment = Parse-SlashCommands -Text $commentBody
$stored = Get-StoredMeta -Repo $hub -Issue $issue
$activeWindow = if ($stored.WindowId) { $stored.WindowId } else { "1" }
if ($parsedComment.WindowId) {
  $picked = Get-WindowMeta -Repo $hub -Issue $issue -WindowId $parsedComment.WindowId
  if (-not $picked -or -not $picked.Session) {
    $list = Format-WindowList -Repo $hub -Issue $issue -ActiveId $activeWindow
    Add-IssueComment -Repo $hub -Number $issueNumber -Body "No **w$($parsedComment.WindowId)** on this issue yet.`n`n$list"
    exit 0
  }
  $stored = $picked
}

if ($eventName -eq "issues" -and $labelName -eq $QueueLabel) {
  try {
    $recent = @(Get-IssueComments -Repo $hub -Number $issueNumber | Where-Object {
      $_.body -match [regex]::Escape($BotMarker) -and
      ((Get-Date).ToUniversalTime() - ([datetime]$_.created_at).ToUniversalTime()).TotalMinutes -lt 8
    })
    if ($recent.Count -gt 0) {
      Write-Output "Skipping duplicate agenthrs label; a run already started for this card."
      exit 0
    }
  } catch { }
}

$command = $parsedComment.Command
if (-not $command -and $eventName -eq "issue_comment" -and $commentBody) { $command = "continue" }
if (-not $command -and $eventName -eq "issues" -and ($labelName -eq $QueueLabel -or $event.action -eq "opened") -and ($labelNames -contains $QueueLabel -or $labelName -eq $QueueLabel)) {
  $command = if ($stored.Session) { "continue" } else { "start" }
}
if (-not $command -and $parsedIssue.Command) { $command = $parsedIssue.Command }
if (-not $command) { $command = "start" }

$model = $parsedComment.Model
if (-not $model) { $model = $parsedIssue.Model }
if (-not $model) { $model = $stored.Model }
if (-not $model) { $model = "auto" }

$targetRaw = $parsedComment.TargetRepo
if (-not $targetRaw) { $targetRaw = $parsedIssue.TargetRepo }
if (-not $targetRaw) { $targetRaw = $stored.TargetRepo }
$targetRepo = $null
if ($targetRaw) { $targetRepo = Parse-RepoSlug $targetRaw }

$workspaceRaw = $parsedComment.Workspace
if (-not $workspaceRaw) { $workspaceRaw = $parsedIssue.Workspace }
if (-not $workspaceRaw) { $workspaceRaw = $stored.Workspace }

$mode = $parsedComment.Mode
if (-not $mode) { $mode = $parsedIssue.Mode }

$prompt = $parsedComment.Prompt
if (-not $prompt) { $prompt = $parsedIssue.Prompt }
if (-not $prompt) { $prompt = $issue.body }
if (-not $prompt) { $prompt = $issue.title }

if ($eventName -eq "issue_comment") {
  $hasAgent = $labelNames -contains $QueueLabel
  $explicit = $parsedComment.Command
  if (-not $hasAgent -and -not $explicit) {
    Write-Output "Issue #$issueNumber has no agenthrs label; ignoring freeform comment."
    exit 0
  }
}

if ($labelNames -contains "holdhrs" -and $command -notin @("start", "continue", "new", "stop", "hold", "queue")) {
  Write-Output "Window is holdhrs; ignoring until /agenthrs continue or /agenthrs start."
  exit 0
}

if ($command -eq "queue") {
  $list = Format-WindowList -Repo $hub -Issue $issue -ActiveId $activeWindow
  Add-IssueComment -Repo $hub -Number $issueNumber -Body $list
  exit 0
}

if ($command -eq "hold" -or $labelName -eq "holdhrs") {
  Set-StatusLabel -Repo $hub -Issue $issue -Status "holdhrs"
  Add-IssueComment -Repo $hub -Number $issueNumber -Body "This window is **holdhrs**. Follow-ups on this issue are paused. ``/agenthrs start`` resumes."
  exit 0
}

if ($command -eq "stop") {
  $stopId = if ($stored.WindowId) { $stored.WindowId } else { $activeWindow }
  $stoppingActive = ("$stopId" -eq "$activeWindow")
  if ($stoppingActive) {
    Set-StatusLabel -Repo $hub -Issue $issue -Status "holdhrs"
  }
  if ($stored.RunId) {
    try { Invoke-GitHub -Method POST -Path "/repos/$($hub.Full)/actions/runs/$($stored.RunId)/cancel" | Out-Null } catch { }
  }
  Add-IssueComment -Repo $hub -Number $issueNumber -Body "Stopped **w$stopId**$(if ($stoppingActive) { ' (active window on this issue)' } else { '' }). Same branch is kept. Resume with ``/continuehrs w$stopId`` or ``/continuehrs`` for the active window."
  exit 0
}

if ($parsedComment.Model -and -not $parsedComment.Command -and -not $parsedComment.Prompt) {
  Add-IssueComment -Repo $hub -Number $issueNumber -Body "$ModelMarker $model -->`nModel for this card is now **$model**. ``/agenthrs start`` or ``/agenthrs continue`` to run."
  exit 0
}

if ($labelNames -notcontains $QueueLabel) {
  Set-IssueLabels -Repo $hub -Issue $issue -Add @($QueueLabel) -Remove @()
  $issue = Get-Issue -Repo $hub -Number $issueNumber
}

if (-not $targetRepo) {
  Add-IssueComment -Repo $hub -Number $issueNumber -Body @"
This is the **agenthrs-hub**. Command from here, work in another repo.

Add a target, then start again:

``````
/repohrs owner/name
/agenthrs start
``````

Example: ``/repohrs hafizrs/pm``
"@
  exit 0
}

$keepBranch = [bool]($parsedComment.KeepBranch -or $parsedIssue.KeepBranch -or $stored.KeepBranch)
$allowPush = [bool]($parsedComment.Push -or $parsedIssue.Push -or $stored.Push)

$newWindow = ($command -eq "new") -or ($command -eq "start" -and -not $stored.Session)
$sessionId = $stored.Session
if ($command -eq "new") { $sessionId = $null }

$windowId = 1
if ($stored.WindowId) { $windowId = [int]$stored.WindowId }
if ($command -eq "new") { $windowId = $windowId + 1 }

$baseBranch = "main"
if ($newWindow) {
  if ($parsedComment.BaseBranch) { $baseBranch = $parsedComment.BaseBranch }
  elseif ($parsedIssue.BaseBranch) { $baseBranch = $parsedIssue.BaseBranch }
  elseif ($stored.BaseBranch) { $baseBranch = $stored.BaseBranch }
} else {
  if ($stored.BaseBranch) { $baseBranch = $stored.BaseBranch }
  elseif ($parsedIssue.BaseBranch) { $baseBranch = $parsedIssue.BaseBranch }
}

$workBranch = $null
if (-not $newWindow -and $stored.WorkBranch) {
  $workBranch = $stored.WorkBranch
  $keepBranch = $true
} elseif ($keepBranch) {
  if ($parsedComment.WorkBranch) { $workBranch = $parsedComment.WorkBranch }
  elseif ($parsedIssue.WorkBranch) { $workBranch = $parsedIssue.WorkBranch }
  elseif ($stored.WorkBranch) { $workBranch = $stored.WorkBranch }
  else { $workBranch = $baseBranch }
} else {
  if ($parsedComment.WorkBranch) { $workBranch = $parsedComment.WorkBranch }
  elseif ($parsedIssue.WorkBranch) { $workBranch = $parsedIssue.WorkBranch }
  else { $workBranch = "agenthrs/hub-$issueNumber-w$windowId" }
}

Set-StatusLabel -Repo $hub -Issue $issue -Status "runninghrs"

$prepared = Prepare-WindowRepo -TargetRepo $targetRepo -IssueNumber $issueNumber -WindowId $windowId -BaseBranch $baseBranch -WorkBranch $workBranch -NewWindow $newWindow -KeepExisting $keepBranch
$workspace = Resolve-Workspace -Raw $workspaceRaw -Root $prepared.Dir
$targetDisplay = $targetRepo.Full
$workspaceDisplay = if ($workspaceRaw) { $workspaceRaw } else { "root" }
if ($prepared.CreatedBranch) {
  $branchAction = "created ``$workBranch`` from ``$baseBranch`` (default)"
} elseif ($keepBranch) {
  $branchAction = "kept existing ``$workBranch`` (no new branch)"
} else {
  $branchAction = "reused ``$workBranch`` (same window, branch not changed)"
}

$pushRule = if ($allowPush) { "- Push to origin on this same branch when the work is ready." } else { "- Do not push unless a later comment includes /pushhrs." }

$fullPrompt = @"
You are agenthrs working from hub issue #$($issue.number): $($issue.title)

Hub repo: $($hub.Full)
Target repo: $targetDisplay
Workspace: $workspace
Git branch: $workBranch
Window: $windowId

Rules:
- Stay on branch $workBranch. Do not switch branches and do not create another branch.
- Follow the issue and the latest GitHub comment.
- After you finish, summarize what you changed and any tests you ran.
$pushRule

Issue / instruction:
$prompt
"@

Add-IssueComment -Repo $hub -Number $issueNumber -Body @"
Starting on **agentdesk**.

- Window: **w$windowId** (this issue's $(if ($newWindow) { 'new' } else { 'active' }) window)
- Session: **$(if ($newWindow) { 'new window' } else { 'same window' })**
- Git: $branchAction
- Push: **$(if ($allowPush) { 'allowed' } else { 'off' })**
- Model: **$model**
- Target repo: ``$targetDisplay``
- Workspace: ``$workspaceDisplay``
- Command: ``/agenthrs $command``

Stop this window: ``/stophs w$windowId`` (or ``/stophs`` if it stays the active one).
Continue: ``/continuehrs w$windowId``.
Other issues are other windows.
"@

$run = $null
$failed = $false
try {
  $run = Invoke-LocalAgent -Prompt $fullPrompt -Model $model -Workspace $workspace -SessionId $sessionId -NewSession $newWindow -Mode $mode
  if ($run.ExitCode -ne 0) { $failed = $true }
} catch {
  $failed = $true
  $run = @{ SessionId = $sessionId; Output = $_.Exception.Message; ExitCode = 1 }
}

$issue = Get-Issue -Repo $hub -Number $issueNumber
if ($failed) {
  Set-StatusLabel -Repo $hub -Issue $issue -Status "blockedhrs"
} else {
  Set-StatusLabel -Repo $hub -Issue $issue -Status "donehrs"
}

Write-MetaComment -Repo $hub -Number $issueNumber -Session $run.SessionId -Model $model -Workspace $workspaceDisplay -TargetRepo $targetDisplay -BaseBranch $baseBranch -WorkBranch $workBranch -WindowId "$windowId" -KeepBranch $keepBranch -Push $allowPush

$state = if ($failed) { "failed" } else { "finished" }
Add-IssueComment -Repo $hub -Number $issueNumber -Body @"
agenthrs **$state** (exit $($run.ExitCode)).

``$($run.SessionId)`` | model **$model** | repo ``$targetDisplay`` | branch ``$workBranch``

<details><summary>Agent output</summary>

``````
$(Truncate $run.Output)
``````

</details>

Next:
- Comment on this issue: **active window** (latest), same branch
- ``/stophs`` / ``/continuehrs``: active window on **this issue**
- ``/stophs w1`` / ``/continuehrs w2``: that numbered window
- ``/agenthrs queue``: list windows on this issue
- ``/agenthrs new``: new window **w(n+1)** on this issue
"@

if ($failed) { exit 1 }
exit 0
