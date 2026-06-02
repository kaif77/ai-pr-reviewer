# ─────────────────────────────────────────
# AI PR Reviewer - Windows (PowerShell)
# Dependencies: Node.js, claude CLI
#   winget install OpenJS.NodeJS
#   npm install -g @anthropic-ai/claude-code
# ─────────────────────────────────────────

$ErrorActionPreference = "Stop"

# ── Helpers ──
function Write-Green  { param($msg) Write-Host $msg -ForegroundColor Green }
function Write-Red    { param($msg) Write-Host $msg -ForegroundColor Red }
function Write-Yellow { param($msg) Write-Host $msg -ForegroundColor Yellow }
function Write-Blue   { param($msg) Write-Host $msg -ForegroundColor Cyan }

function Invoke-GitHubApi {
    param(
        [string]$Method,
        [string]$Endpoint,
        [hashtable]$Body = $null
    )
    $headers = @{
        "Authorization"        = "Bearer $env:GITHUB_TOKEN"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $uri = "https://api.github.com$Endpoint"
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
                -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
        } else {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        $detail = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
        return [PSCustomObject]@{ message = if ($detail.message) { $detail.message } else { $_.Exception.Message }; status = $status }
    }
}

# ── Cache directory ──
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheDir  = Join-Path $ScriptDir ".pr_review_cache"
if (-not (Test-Path $CacheDir)) { New-Item -ItemType Directory -Path $CacheDir | Out-Null }

Write-Blue "🤖 AI PR Reviewer"
Write-Host "─────────────────────────────────────────"

# ── Step 1: Load .env ──
$EnvFile = Join-Path $ScriptDir ".env"
if (Test-Path $EnvFile) {
    Write-Green "✅ Loading .env file"
    Get-Content $EnvFile | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' -and $_ -notmatch '^\s*#' } | ForEach-Object {
        $parts = $_ -split '=', 2
        [System.Environment]::SetEnvironmentVariable($parts[0].Trim(), $parts[1].Trim(), "Process")
    }
} else {
    Write-Yellow "⚠️  No .env file found — falling back to environment variables"
}

# ── Step 2: Validate GITHUB_TOKEN ──
if (-not $env:GITHUB_TOKEN) {
    Write-Red "❌ GITHUB_TOKEN not set"
    Write-Host ""
    Write-Host "Create a .env file in the same folder as this script:"
    Write-Host "  $ScriptDir\.env"
    Write-Host ""
    Write-Host "Contents:"
    Write-Host "  GITHUB_TOKEN=github_pat_xxxxxxxxxx"
    Write-Host ""
    Write-Host "Fine-grained token permissions needed:"
    Write-Host "  Pull requests -> Read and Write"
    Write-Host "  Contents      -> Read-only"
    Write-Host "  Metadata      -> Read-only"
    exit 1
}
Write-Green "✅ GitHub token loaded ($($env:GITHUB_TOKEN.Substring(0, [Math]::Min(10, $env:GITHUB_TOKEN.Length)))...)"

# ── Step 3: Ask for inputs ──
Write-Host ""
$DiffFile = Read-Host "📁 Path to diff file"
$DiffFile = $DiffFile.Trim('"').Trim("'")

if (-not (Test-Path $DiffFile)) {
    Write-Red "❌ File not found: $DiffFile"
    exit 1
}
Write-Green "✅ Diff file found"

$Repo = Read-Host "📦 GitHub repo (owner/repo)"
$PR   = Read-Host "🔢 PR number"

# ── Step 4: Check token + repo access ──
Write-Host ""
Write-Yellow "🔐 Checking GitHub authentication..."
$RepoData = Invoke-GitHubApi -Method GET -Endpoint "/repos/$Repo"

if (-not $RepoData.name) {
    Write-Red "❌ Cannot access repo: $($RepoData.message)"
    exit 1
}
Write-Green "✅ Repo accessible: $($RepoData.name)"

# ── Step 5: Check PR exists ──
Write-Yellow "🔍 Checking PR #$PR..."
$PrData = Invoke-GitHubApi -Method GET -Endpoint "/repos/$Repo/pulls/$PR"

if (-not $PrData.title) {
    Write-Red "❌ PR #$PR not found: $($PrData.message)"
    exit 1
}
Write-Green "✅ PR found: $($PrData.title)"

# ── Step 5b: Detect self-review ──
Write-Yellow "🔍 Checking token identity..."
$TokenUser = (Invoke-GitHubApi -Method GET -Endpoint "/user").login
$PrAuthor  = $PrData.user.login
$SelfReview = $TokenUser -eq $PrAuthor

if ($SelfReview) {
    Write-Yellow "⚠️  Token belongs to PR author ($TokenUser). APPROVE/REQUEST_CHANGES will be changed to COMMENT."
} else {
    Write-Green "✅ Token identity: $TokenUser (not the PR author)"
}

# ── Step 6: Check write permission ──
Write-Yellow "🔍 Checking comment permissions..."
$CommentsCheck = Invoke-GitHubApi -Method GET -Endpoint "/repos/$Repo/pulls/$PR/comments"
if ($CommentsCheck -is [System.Array] -or $CommentsCheck.GetType().Name -eq "Object[]") {
    Write-Green "✅ Permission check passed"
} else {
    Write-Red "❌ Cannot access PR comments: $($CommentsCheck.message)"
    Write-Host "   Ensure token has Pull requests: Read and Write"
    exit 1
}

# ── Step 7: Fetch PR commit SHA ──
Write-Host ""
Write-Yellow "📡 Fetching PR metadata..."
$CommitId    = $PrData.head.sha
$CommitCheck = Invoke-GitHubApi -Method GET -Endpoint "/repos/$Repo/commits/$CommitId"

if (-not $CommitCheck.sha) {
    Write-Red "❌ Commit SHA not found on GitHub: $CommitId"
    exit 1
}
Write-Green "✅ Latest commit verified: $($CommitId.Substring(0,8))..."

# ── Step 8: Check cache ──
$DiffBasename = Split-Path -Leaf $DiffFile
$CacheKey     = "$($DiffBasename)__$($Repo -replace '/', '_')__PR$PR" -replace ' ', '_'
$CacheFile    = Join-Path $CacheDir "$CacheKey.json"

Write-Host ""
$ReviewJson = $null

if (Test-Path $CacheFile) {
    Write-Yellow "💾 Cached review found for:"
    Write-Host "   Diff : $DiffBasename"
    Write-Host "   Repo : $Repo"
    Write-Host "   PR   : #$PR"
    Write-Host ""
    $UseCache = Read-Host "♻️  Use cached Claude review? (y/n)"
    if ($UseCache -eq 'y' -or $UseCache -eq 'Y') {
        $ReviewJson = Get-Content $CacheFile -Raw
        Write-Green "✅ Loaded review from cache"
    } else {
        Write-Yellow "🔄 Re-running Claude review..."
    }
}

# ── Step 9: Check Claude CLI and send diff ──
if (-not $ReviewJson) {
    Write-Yellow "🧠 Sending diff to Claude for review..."

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Red "❌ claude CLI not found"
        Write-Host "   Install: npm install -g @anthropic-ai/claude-code"
        exit 1
    }
    Write-Green "✅ Claude CLI found"

    $DiffContent = Get-Content $DiffFile -Raw

    $Prompt = @"
You are a senior software engineer doing a thorough PR review.
Analyze the following diff carefully and respond in PURE JSON only.
No markdown, no backticks, no explanation — raw JSON only.

Return this exact structure:
{
  "summary": "2-3 sentence overall summary of the changes",
  "verdict": "APPROVE or REQUEST_CHANGES",
  "comments": [
    {
      "file": "exact/path/to/file.py",
      "line": 42,
      "severity": "high or medium or low",
      "comment": "specific actionable feedback"
    }
  ]
}

Rules:
- file must match exactly as it appears in the diff (after +++ b/)
- line must be a valid added/modified line number from the diff
- severity: high = bugs/security, medium = code quality, low = style
- Only comment on lines that appear in the diff
- If no issues found, return empty comments array and APPROVE verdict

Diff to review:
$DiffContent
"@

    $ReviewJson = & claude -p $Prompt 2>$null

    try {
        $null = $ReviewJson | ConvertFrom-Json
    } catch {
        Write-Red "❌ Claude returned invalid JSON. Raw output:"
        Write-Host $ReviewJson
        exit 1
    }

    $ReviewJson | Out-File -FilePath $CacheFile -Encoding UTF8
    Write-Green "✅ Review received and cached"
}

# ── Step 10: Resolve verdict ──
$ReviewObj     = $ReviewJson | ConvertFrom-Json
$Verdict       = $ReviewObj.verdict
$Summary       = $ReviewObj.summary
$Comments      = $ReviewObj.comments
$CommentCount  = $Comments.Count

if ($SelfReview -and ($Verdict -eq "APPROVE" -or $Verdict -eq "REQUEST_CHANGES")) {
    Write-Yellow "⚠️  Overriding $Verdict -> COMMENT (self-review restriction)"
    $Verdict = "COMMENT"
}

if ($Verdict -notin @("APPROVE", "REQUEST_CHANGES", "COMMENT")) {
    Write-Yellow "⚠️  Unrecognised verdict '$Verdict' — defaulting to COMMENT"
    $Verdict = "COMMENT"
}

# ── Step 10b: Show summary ──
Write-Host ""
Write-Host "─────────────────────────────────────────"
Write-Host "📋 Summary: $Summary"
Write-Host "⚖️  Verdict: $Verdict"
Write-Host "💬 Inline comments: $CommentCount"
Write-Host "─────────────────────────────────────────"

# ── Step 11: Confirm before posting ──
Write-Host ""
$Confirm = Read-Host "🚀 Post this review to PR #$PR? (y/n)"
if ($Confirm -ne 'y' -and $Confirm -ne 'Y') {
    Write-Yellow "⚠️  Aborted. Review not posted."
    exit 0
}

# ── Step 12: Post overall PR review ──
Write-Host ""
Write-Yellow "📤 Posting PR review..."

$ReviewBody = @{
    body  = "## Code Review`n`n$Summary`n`n---`n*Reviewed locally using Claude AI*"
    event = $Verdict
}

$ReviewResponse = Invoke-GitHubApi -Method POST -Endpoint "/repos/$Repo/pulls/$PR/reviews" -Body $ReviewBody

if (-not $ReviewResponse.id) {
    Write-Red "❌ Failed to post review: $($ReviewResponse.message)"
    exit 1
}
Write-Green "✅ PR review posted ($Verdict) — review ID: $($ReviewResponse.id)"

# ── Step 13: Post inline comments ──
if ($CommentCount -gt 0) {
    Write-Yellow "💬 Posting $CommentCount inline comments..."

    foreach ($c in $Comments) {
        $Emoji = switch ($c.severity) {
            "high"   { "🔴" }
            "medium" { "🟡" }
            default  { "🔵" }
        }

        $CommentBody = @{
            body      = "$Emoji [$($c.severity)] $($c.comment)"
            path      = $c.file
            line      = $c.line
            side      = "RIGHT"
            commit_id = $CommitId
        }

        $CommentResponse = Invoke-GitHubApi -Method POST -Endpoint "/repos/$Repo/pulls/$PR/comments" -Body $CommentBody

        if ($CommentResponse.id) {
            Write-Green "  ✅ $($c.file):$($c.line)"
        } else {
            Write-Red "  ❌ Failed $($c.file):$($c.line) — $($CommentResponse.message)"
        }
    }
}

Write-Host ""
Write-Green "🎉 Done! View PR at: https://github.com/$Repo/pull/$PR"
