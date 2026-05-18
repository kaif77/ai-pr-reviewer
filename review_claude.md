Review this git diff1 for structural flaws, security issues, and edge cases. Group feedback by file

#!/bin/bash

# ─────────────────────────────────────────
# AI PR Reviewer - Local Diff File Mode
# ─────────────────────────────────────────

set -e

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}🤖 AI PR Reviewer${NC}"
echo "─────────────────────────────────────────"

# ── Step 1: Load .env ──
ENV_FILE="$(dirname "$0")/.env"
if [ -f "$ENV_FILE" ]; then
  echo -e "${GREEN}✅ Loading .env file${NC}"
  set -o allexport
  source <(grep -E '^\s*[A-Za-z_][A-Za-z0-9_]*\s*=' "$ENV_FILE" | grep -v '^\s*#')
  set +o allexport
else
  echo -e "${YELLOW}⚠️  No .env file found at $ENV_FILE — falling back to environment variables${NC}"
fi

# ── Step 2: Validate GITHUB_TOKEN ──
if [ -z "$GITHUB_TOKEN" ]; then
  echo -e "${RED}❌ GITHUB_TOKEN not set in .env or environment${NC}"
  echo ""
  echo "Create a .env file next to this script:"
  echo "  GITHUB_TOKEN=github_pat_xxxxxxxxxx"
  echo ""
  echo "Fine-grained token permissions needed:"
  echo "  Pull requests → Read and Write"
  echo "  Contents      → Read-only"
  echo "  Metadata      → Read-only"
  exit 1
fi
export GITHUB_TOKEN
echo -e "${GREEN}✅ GitHub token loaded${NC}"

# ── Step 3: Ask for inputs ──
echo ""
read -p "📁 Path to diff file: " DIFF_FILE
if [ ! -f "$DIFF_FILE" ]; then
  echo -e "${RED}❌ File not found: $DIFF_FILE${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Diff file found${NC}"

read -p "📦 GitHub repo (owner/repo): " REPO
read -p "🔢 PR number: " PR

# ── Step 4: Check GitHub authentication ──
echo ""
echo -e "${YELLOW}🔐 Checking GitHub authentication...${NC}"

# Try user endpoint first, fall back to repo-level for scoped PATs
GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "")

if [ -z "$GH_USER" ]; then
  # Fine-grained repo-scoped PATs can't access /user — use repo endpoint instead
  echo -e "${YELLOW}⚠️  User endpoint blocked (expected for repo-scoped PAT), trying repo-level auth...${NC}"
  REPO_CHECK=$(gh api repos/$REPO --jq '.full_name' 2>/dev/null || echo "")
  if [ -z "$REPO_CHECK" ]; then
    echo -e "${RED}❌ Token is invalid, expired, or has no access to $REPO${NC}"
    echo ""
    echo "Check your token at: github.com → Settings → Developer Settings → Fine-grained tokens"
    exit 1
  fi
  GH_USER=$(gh api repos/$REPO --jq '.owner.login' 2>/dev/null || echo "unknown")
  echo -e "${GREEN}✅ Authenticated via repo-scoped PAT${NC}"
else
  echo -e "${GREEN}✅ Authenticated as: $GH_USER${NC}"
fi

# ── Step 5: Check repo access ──
echo -e "${YELLOW}🔍 Checking repo access...${NC}"
if ! gh repo view "$REPO" &>/dev/null; then
  echo -e "${RED}❌ Cannot access repo: $REPO${NC}"
  echo "   Ensure your fine-grained token is scoped to this repo"
  exit 1
fi
echo -e "${GREEN}✅ Repo accessible${NC}"

# ── Step 6: Check PR exists ──
echo -e "${YELLOW}🔍 Checking PR #$PR...${NC}"
PR_DATA=$(gh api repos/$REPO/pulls/$PR 2>/dev/null || echo "")
if [ -z "$PR_DATA" ]; then
  echo -e "${RED}❌ PR #$PR not found in $REPO${NC}"
  exit 1
fi
echo -e "${GREEN}✅ PR #$PR found${NC}"

# ── Step 7: Check comment permissions ──
echo -e "${YELLOW}🔍 Checking comment permissions...${NC}"

PERMISSION=$(gh api repos/$REPO/collaborators/$GH_USER/permission \
  --jq '.permission' 2>/dev/null || echo "unknown")

if [[ "$PERMISSION" == "none" || "$PERMISSION" == "read" ]]; then
  echo -e "${RED}❌ Insufficient permissions (current: $PERMISSION)${NC}"
  echo "   Need: triage, write, maintain, or admin"
  exit 1
elif [[ "$PERMISSION" == "unknown" ]]; then
  # Repo-scoped PAT can't access collaborator endpoint — verify via PR access
  PR_CHECK=$(echo "$PR_DATA" | jq -r '.number' 2>/dev/null || echo "")
  if [ -z "$PR_CHECK" ]; then
    echo -e "${RED}❌ Cannot access PR — check token permissions${NC}"
    exit 1
  fi
  echo -e "${GREEN}✅ Permission check passed (repo-scoped PAT)${NC}"
else
  echo -e "${GREEN}✅ Permission granted ($PERMISSION)${NC}"
fi

# ── Step 8: Fetch PR commit SHA ──
echo ""
echo -e "${YELLOW}📡 Fetching PR metadata...${NC}"
COMMIT_ID=$(echo "$PR_DATA" | jq -r '.head.sha')
echo -e "${GREEN}✅ Latest commit: ${COMMIT_ID:0:8}...${NC}"

# ── Step 9: Send diff to Claude ──
echo ""
echo -e "${YELLOW}🧠 Sending diff to Claude for review...${NC}"
DIFF_CONTENT=$(cat "$DIFF_FILE")

REVIEW_JSON=$(claude -p "You are a senior software engineer doing a thorough PR review.
Analyze the following diff carefully and respond in PURE JSON only.
No markdown, no backticks, no explanation — raw JSON only.

Return this exact structure:
{
  \"summary\": \"2-3 sentence overall summary of the changes\",
  \"verdict\": \"APPROVE or REQUEST_CHANGES\",
  \"comments\": [
    {
      \"file\": \"exact/path/to/file.py\",
      \"line\": 42,
      \"severity\": \"high or medium or low\",
      \"comment\": \"specific actionable feedback\"
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
$DIFF_CONTENT" 2>/dev/null)

# ── Step 10: Validate JSON ──
if ! echo "$REVIEW_JSON" | jq . &>/dev/null; then
  echo -e "${RED}❌ Claude returned invalid JSON. Raw output:${NC}"
  echo "$REVIEW_JSON"
  exit 1
fi
echo -e "${GREEN}✅ Review received${NC}"

# ── Step 11: Show summary ──
SUMMARY=$(echo "$REVIEW_JSON" | jq -r '.summary')
VERDICT=$(echo "$REVIEW_JSON" | jq -r '.verdict')
COMMENT_COUNT=$(echo "$REVIEW_JSON" | jq '.comments | length')

echo ""
echo "─────────────────────────────────────────"
echo -e "📋 ${BLUE}Summary:${NC} $SUMMARY"
echo -e "⚖️  ${BLUE}Verdict:${NC} $VERDICT"
echo -e "💬 ${BLUE}Inline comments:${NC} $COMMENT_COUNT"
echo "─────────────────────────────────────────"

# ── Step 12: Confirm before posting ──
echo ""
read -p "🚀 Post this review to PR #$PR? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo -e "${YELLOW}⚠️  Aborted. Review not posted.${NC}"
  exit 0
fi

# ── Step 13: Post overall PR review ──
echo ""
echo -e "${YELLOW}📤 Posting PR review...${NC}"
gh api repos/$REPO/pulls/$PR/reviews \
  --method POST \
  --field commit_id="$COMMIT_ID" \
  --field body="## 🤖 AI Code Review

$SUMMARY

---
*Reviewed locally using Claude AI*" \
  --field event="$VERDICT" > /dev/null
echo -e "${GREEN}✅ PR review posted ($VERDICT)${NC}"

# ── Step 14: Post inline comments ──
if [ "$COMMENT_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}💬 Posting $COMMENT_COUNT inline comments...${NC}"

  echo "$REVIEW_JSON" | jq -c '.comments[]' | while read comment; do
    FILE=$(echo "$comment" | jq -r '.file')
    LINE=$(echo "$comment" | jq -r '.line')
    BODY=$(echo "$comment" | jq -r '.comment')
    SEVERITY=$(echo "$comment" | jq -r '.severity')

    EMOJI="🔵"
    [[ "$SEVERITY" == "high" ]] && EMOJI="🔴"
    [[ "$SEVERITY" == "medium" ]] && EMOJI="🟡"

    if gh api repos/$REPO/pulls/$PR/comments \
      --method POST \
      --field body="$EMOJI **[$SEVERITY]** $BODY" \
      --field path="$FILE" \
      --field line="$LINE" \
      --field side="RIGHT" \
      --field commit_id="$COMMIT_ID" &>/dev/null; then
      echo -e "  ${GREEN}✅ $FILE:$LINE${NC}"
    else
      echo -e "  ${RED}❌ Failed: $FILE:$LINE (line may not exist in diff)${NC}"
    fi
  done
fi

echo ""
echo -e "${GREEN}🎉 Done! View PR at: https://github.com/$REPO/pull/$PR${NC}"