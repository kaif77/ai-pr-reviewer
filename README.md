# AI PR Reviewer

Shell scripts that send a git diff to an AI model (Claude or Gemini), get a structured code review, and post it as a GitHub PR review with inline comments.

---

## Scripts

| Script | OS | AI Model | Requires |
|---|---|---|---|
| `review.sh` | Linux | Claude CLI | `GITHUB_TOKEN`, `claude` CLI |
| `mac_review_claude.sh` | macOS | Claude CLI | `GITHUB_TOKEN`, `claude` CLI |
| `review_gemini.sh` | Linux | Gemini CLI | `GITHUB_TOKEN`, `gemini` CLI |

All scripts share the same flow and produce the same output — only the AI backend and OS differ.

---

## Prerequisites

### System packages

```bash
sudo apt-get install -y curl jq   # Linux
brew install curl jq               # macOS
```

### Node (via nvm)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
nvm install 22.14.0
```

### AI CLI

```bash
# Claude
npm install -g @anthropic-ai/claude-code

# Gemini
npm install -g @google/gemini-cli
```

---

## Setup

Create a `.env` file in the same folder as the script:

```bash
# Required for all scripts
GITHUB_TOKEN=github_pat_xxxxxxxxxx

# Node version to use via nvm (optional, defaults to lts/system)
NODE_VERSION=v22.14.0
```

### GitHub token permissions (fine-grained PAT)

Go to **GitHub → Settings → Developer Settings → Fine-grained tokens → Generate new token** and grant:

| Permission | Level |
|---|---|
| Pull requests | Read and Write |
| Contents | Read-only |
| Metadata | Read-only |

---

## Generating a diff file

```bash
# From the repo you want to review — diff against the target branch
git diff main...HEAD > /tmp/my_pr.diff

# Or for a specific PR locally
git fetch origin pull/3/head:pr-3
git diff main...pr-3 > /tmp/pr3.diff
```

---

## Running

```bash
chmod +x review.sh
./review.sh
```

The script will ask three questions interactively:

```
📁 Path to diff file:       /tmp/pr3.diff
📦 GitHub repo (owner/repo): myorg/myrepo
🔢 PR number:                3
```

### Full example session

```
🤖 AI PR Reviewer
─────────────────────────────────────────
✅ Loading .env file
✅ GitHub token loaded (github_pat...)

📁 Path to diff file: /tmp/pr3.diff
✅ Diff file found
📦 GitHub repo (owner/repo): kaif77/student-portal
🔢 PR number: 3

🔐 Checking GitHub authentication...
✅ Repo accessible: student-portal
🔍 Checking PR #3...
✅ PR found: feat: Introduce a new student profile page
🔍 Checking token identity...
⚠️  Token belongs to PR author (kaif77). APPROVE/REQUEST_CHANGES will be changed to COMMENT.
🔍 Checking comment permissions...
✅ Permission check passed

📡 Fetching PR metadata...
✅ Latest commit verified: aadc6f8f...

🧠 Loading nvm and sending diff to Claude for review...
✅ Using node v22.14.0 via nvm
✅ Claude CLI found
✅ Review received and cached

─────────────────────────────────────────
📋 Summary: This PR introduces a student profile page allowing users to view and
            edit their personal details and change their password. It also refactors
            several layout and navigation components.
⚖️  Verdict: REQUEST_CHANGES
💬 Inline comments: 6
─────────────────────────────────────────

🚀 Post this review to PR #3? (y/n): y

📤 Posting PR review...
✅ PR review posted (COMMENT) — review ID: 2381749203
💬 Posting 6 inline comments...
  ✅ src/pages/student/ApplicationDetail.jsx:142
  ✅ src/pages/student/Dashboard.jsx:38
  ✅ src/pages/student/Profile.jsx:91
  ✅ src/layouts/StudentLayout.jsx:24
  ✅ src/layouts/AdminLayout.jsx:67
  ✅ src/pages/student/Profile.jsx:204

🎉 Done! View PR at: https://github.com/kaif77/student-portal/pull/3
```

---

## Caching

After the AI returns a review it is saved to `.pr_review_cache/` (Claude) or `.pr_review_cache_gemini/` (Gemini). On the next run for the same diff + repo + PR, the script asks:

```
♻️  Use cached Claude review? (y/n):
```

Answer `y` to re-post without calling the AI again. Answer `n` to re-run the review.

---

## Self-review handling

GitHub does not allow a PR author to `APPROVE` or `REQUEST_CHANGES` their own PR. The scripts detect this automatically — if your token belongs to the PR author, any verdict is automatically downgraded to `COMMENT` so the post succeeds.

---

## Inline comment severity

Comments are posted with a coloured label based on the AI's severity rating:

| Emoji | Severity | Meaning |
|---|---|---|
| 🔴 | high | Bugs or security issues |
| 🟡 | medium | Code quality problems |
| 🔵 | low | Style or minor suggestions |
