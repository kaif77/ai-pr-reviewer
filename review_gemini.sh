#!/bin/bash

# ─────────────────────────────────────────
# AI PR Reviewer (Gemini CLI) - Ubuntu compatible + caching
# Dependencies: curl, jq, nvm, gemini CLI
#   sudo apt-get install -y curl jq
#   https://github.com/nvm-sh/nvm
#   npm install -g @google/gemini-cli
# ─────────────────────────────────────────

set -e

# ── Colors ──
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ── Cache directory (next to script) ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="$SCRIPT_DIR/.pr_review_cache_gemini"
mkdir -p "$CACHE_DIR"

# ── GitHub API helper ──
gh_api() {
  local method=$1
  local endpoint=$2
  local data=$3

  if [ -z "$data" ]; then
    curl -s -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "https://api.github.com$endpoint"
  else
    curl -s -X "$method" \
      -H "Authorization: Bearer $GITHUB_TOKEN" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -H "Content-Type: application/json" \
      -d "$data" \
      "https://api.github.com$endpoint"
  fi
}

# ── Dependency checks ──
for dep in curl jq; do
  if ! command -v "$dep" > /dev/null 2>&1; then
    echo -e "${RED}❌ Missing dependency: $dep${NC}"
    echo "   Install with: sudo apt-get install -y $dep"
    exit 1
  fi
done

echo -e "${BLUE}🤖 AI PR Reviewer (Gemini)${NC}"
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

# ── Step 2: Validate tokens ──
if [ -z "$GITHUB_TOKEN" ]; then
  echo -e "${RED}❌ GITHUB_TOKEN not set${NC}"
  echo ""
  echo "Add to $SCRIPT_DIR/.env:"
  echo "  GITHUB_TOKEN=github_pat_xxxxxxxxxx"
  echo ""
  echo "Fine-grained token permissions needed:"
  echo "  Pull requests -> Read and Write"
  echo "  Contents      -> Read-only"
  echo "  Metadata      -> Read-only"
  exit 1
fi
echo -e "${GREEN}✅ GitHub token loaded (${GITHUB_TOKEN:0:10}...)${NC}"

# ── Step 3: Ask for inputs ──
echo ""
read -r -p "📁 Path to diff file: " DIFF_FILE
DIFF_FILE="${DIFF_FILE/#\~/$HOME}"

if [ ! -f "$DIFF_FILE" ]; then
  echo -e "${RED}❌ File not found: $DIFF_FILE${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Diff file found${NC}"

read -r -p "📦 GitHub repo (owner/repo): " REPO
read -r -p "🔢 PR number: " PR

# ── Step 4: Check token + repo access ──
echo ""
echo -e "${YELLOW}🔐 Checking GitHub authentication...${NC}"
REPO_DATA=$(gh_api GET "/repos/$REPO")

REPO_NAME=$(echo "$REPO_DATA" | jq -r '.name // empty')
if [ -z "$REPO_NAME" ]; then
  ERROR_MSG=$(echo "$REPO_DATA" | jq -r '.message // "Unknown error"')
  echo -e "${RED}❌ Cannot access repo: $ERROR_MSG${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Repo accessible: $REPO_NAME${NC}"

# ── Step 5: Check PR exists ──
echo -e "${YELLOW}🔍 Checking PR #$PR...${NC}"
PR_DATA=$(gh_api GET "/repos/$REPO/pulls/$PR")

PR_TITLE=$(echo "$PR_DATA" | jq -r '.title // empty')
if [ -z "$PR_TITLE" ]; then
  ERROR_MSG=$(echo "$PR_DATA" | jq -r '.message // "Unknown error"')
  echo -e "${RED}❌ PR #$PR not found: $ERROR_MSG${NC}"
  exit 1
fi
echo -e "${GREEN}✅ PR found: $PR_TITLE${NC}"

# ── Step 5b: Detect self-review ──
echo -e "${YELLOW}🔍 Checking token identity...${NC}"
TOKEN_USER=$(gh_api GET "/user" | jq -r '.login // empty')
PR_AUTHOR=$(echo "$PR_DATA" | jq -r '.user.login // empty')

if [ "$TOKEN_USER" = "$PR_AUTHOR" ]; then
  echo -e "${YELLOW}⚠️  Token belongs to PR author ($TOKEN_USER). APPROVE/REQUEST_CHANGES will be changed to COMMENT.${NC}"
  SELF_REVIEW=true
else
  SELF_REVIEW=false
  echo -e "${GREEN}✅ Token identity: $TOKEN_USER (not the PR author)${NC}"
fi

# ── Step 6: Check write permission ──
echo -e "${YELLOW}🔍 Checking comment permissions...${NC}"
COMMENTS_CHECK=$(gh_api GET "/repos/$REPO/pulls/$PR/comments")
if echo "$COMMENTS_CHECK" | jq -e 'if type == "array" then true else false end' > /dev/null 2>&1; then
  echo -e "${GREEN}✅ Permission check passed${NC}"
else
  ERROR_MSG=$(echo "$COMMENTS_CHECK" | jq -r '.message // "Unknown error"')
  echo -e "${RED}❌ Cannot access PR comments: $ERROR_MSG${NC}"
  echo "   Ensure token has Pull requests: Read and Write"
  exit 1
fi

# ── Step 7: Fetch PR commit SHA ──
echo ""
echo -e "${YELLOW}📡 Fetching PR metadata...${NC}"
COMMIT_ID=$(echo "$PR_DATA" | jq -r '.head.sha')

COMMIT_CHECK=$(gh_api GET "/repos/$REPO/commits/$COMMIT_ID")
COMMIT_VERIFIED=$(echo "$COMMIT_CHECK" | jq -r '.sha // empty')
if [ -z "$COMMIT_VERIFIED" ]; then
  echo -e "${RED}❌ Commit SHA not found on GitHub: $COMMIT_ID${NC}"
  exit 1
fi
echo -e "${GREEN}✅ Latest commit verified: ${COMMIT_ID:0:8}...${NC}"

# ── Step 8: Check cache ──
DIFF_BASENAME=$(basename "$DIFF_FILE")
CACHE_KEY=$(echo "${DIFF_BASENAME}__${REPO//\//_}__PR${PR}" | tr ' ' '_')
CACHE_FILE="$CACHE_DIR/$CACHE_KEY.json"

echo ""
REVIEW_JSON=""

if [ -f "$CACHE_FILE" ]; then
  echo -e "${YELLOW}💾 Cached review found for:${NC}"
  echo -e "   Diff : $DIFF_BASENAME"
  echo -e "   Repo : $REPO"
  echo -e "   PR   : #$PR"
  echo ""
  read -r -p "♻️  Use cached Gemini review? (y/n): " USE_CACHE
  if [[ "$USE_CACHE" == "y" || "$USE_CACHE" == "Y" ]]; then
    REVIEW_JSON=$(cat "$CACHE_FILE")
    echo -e "${GREEN}✅ Loaded review from cache${NC}"
  else
    echo -e "${YELLOW}🔄 Re-running Gemini review...${NC}"
  fi
fi

# ── Step 9: Load nvm and send diff to Gemini CLI (if not cached) ──
if [ -z "$REVIEW_JSON" ]; then
  echo -e "${YELLOW}🧠 Loading nvm and sending diff to Gemini for review...${NC}"

  export NVM_DIR="$HOME/.nvm"
  if [ -s "$NVM_DIR/nvm.sh" ]; then
    # shellcheck disable=SC1091
    source "$NVM_DIR/nvm.sh"
    nvm use "${NODE_VERSION:-lts}" > /dev/null 2>&1 || nvm use --lts > /dev/null 2>&1 || true
    echo -e "${GREEN}✅ Using node $(node --version) via nvm${NC}"
  else
    echo -e "${YELLOW}⚠️  nvm not found — using system node${NC}"
    if ! command -v node > /dev/null 2>&1; then
      echo -e "${RED}❌ node not found. Install nvm: https://github.com/nvm-sh/nvm${NC}"
      echo "   Or: sudo apt-get install -y nodejs"
      exit 1
    fi
    echo -e "${GREEN}✅ Using system node $(node --version)${NC}"
  fi

  if ! command -v gemini > /dev/null 2>&1; then
    echo -e "${RED}❌ gemini CLI not found${NC}"
    echo "   Install: npm install -g @google/gemini-cli"
    exit 1
  fi
  echo -e "${GREEN}✅ Gemini CLI found${NC}"

  DIFF_CONTENT=$(cat "$DIFF_FILE")

  REVIEW_JSON=$(gemini --skip-trust -p "You are a senior software engineer doing a thorough PR review.
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

  # ── Validate JSON ──
  if ! echo "$REVIEW_JSON" | jq . > /dev/null 2>&1; then
    echo -e "${RED}❌ Gemini returned invalid JSON. Raw output:${NC}"
    echo "$REVIEW_JSON"
    exit 1
  fi

  # ── Save to cache ──
  echo "$REVIEW_JSON" > "$CACHE_FILE"
  echo -e "${GREEN}✅ Review received and cached${NC}"
fi

# ── Step 10: Resolve verdict ──
VERDICT=$(echo "$REVIEW_JSON" | jq -r '.verdict')

# GitHub blocks both APPROVE and REQUEST_CHANGES on your own PR
if [ "$SELF_REVIEW" = true ]; then
  if [[ "$VERDICT" == "APPROVE" || "$VERDICT" == "REQUEST_CHANGES" ]]; then
    echo -e "${YELLOW}⚠️  Overriding $VERDICT -> COMMENT (self-review restriction)${NC}"
    VERDICT="COMMENT"
  fi
fi

if [[ "$VERDICT" != "APPROVE" && "$VERDICT" != "REQUEST_CHANGES" && "$VERDICT" != "COMMENT" ]]; then
  echo -e "${YELLOW}⚠️  Unrecognised verdict '$VERDICT' — defaulting to COMMENT${NC}"
  VERDICT="COMMENT"
fi

# ── Step 10b: Show summary ──
SUMMARY=$(echo "$REVIEW_JSON" | jq -r '.summary')
COMMENT_COUNT=$(echo "$REVIEW_JSON" | jq '.comments | length')

echo ""
echo "─────────────────────────────────────────"
echo -e "📋 ${BLUE}Summary:${NC} $SUMMARY"
echo -e "⚖️  ${BLUE}Verdict:${NC} $VERDICT"
echo -e "💬 ${BLUE}Inline comments:${NC} $COMMENT_COUNT"
echo "─────────────────────────────────────────"

# ── Step 11: Confirm before posting ──
echo ""
read -r -p "🚀 Post this review to PR #$PR? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
  echo -e "${YELLOW}⚠️  Aborted. Review not posted.${NC}"
  exit 0
fi

# ── Step 12: Post overall PR review ──
echo ""
echo -e "${YELLOW}📤 Posting PR review...${NC}"

REVIEW_BODY=$(jq -n \
  --arg body "$(printf '## Code Review\n\n%s\n\n---\n*Reviewed locally using Gemini AI*' "$SUMMARY")" \
  --arg event "$VERDICT" \
  '{body: $body, event: $event}')

REVIEW_RESPONSE=$(gh_api POST "/repos/$REPO/pulls/$PR/reviews" "$REVIEW_BODY")
REVIEW_ID=$(echo "$REVIEW_RESPONSE" | jq -r '.id // empty')

if [ -z "$REVIEW_ID" ]; then
  ERROR_MSG=$(echo "$REVIEW_RESPONSE" | jq -r '.message // "Unknown error"')
  echo -e "${RED}❌ Failed to post review: $ERROR_MSG${NC}"
  echo -e "${YELLOW}Raw response:${NC}"
  echo "$REVIEW_RESPONSE" | jq .
  exit 1
fi
echo -e "${GREEN}✅ PR review posted ($VERDICT) — review ID: $REVIEW_ID${NC}"

# ── Step 13: Post inline comments ──
if [ "$COMMENT_COUNT" -gt 0 ]; then
  echo -e "${YELLOW}💬 Posting $COMMENT_COUNT inline comments...${NC}"

  while IFS= read -r comment; do
    FILE=$(echo "$comment" | jq -r '.file')
    LINE=$(echo "$comment" | jq -r '.line')
    BODY=$(echo "$comment" | jq -r '.comment')
    SEVERITY=$(echo "$comment" | jq -r '.severity')

    EMOJI="🔵"
    [[ "$SEVERITY" == "high" ]]   && EMOJI="🔴"
    [[ "$SEVERITY" == "medium" ]] && EMOJI="🟡"

    COMMENT_PAYLOAD=$(jq -n \
      --arg body "$EMOJI [$SEVERITY] $BODY" \
      --arg path "$FILE" \
      --argjson line "$LINE" \
      --arg commit_id "$COMMIT_ID" \
      '{body: $body, path: $path, line: $line, side: "RIGHT", commit_id: $commit_id}')

    COMMENT_RESPONSE=$(gh_api POST "/repos/$REPO/pulls/$PR/comments" "$COMMENT_PAYLOAD")
    COMMENT_ID=$(echo "$COMMENT_RESPONSE" | jq -r '.id // empty')

    if [ -n "$COMMENT_ID" ]; then
      echo -e "  ${GREEN}✅ $FILE:$LINE${NC}"
    else
      ERROR_MSG=$(echo "$COMMENT_RESPONSE" | jq -r '.message // "Unknown error"')
      echo -e "  ${RED}❌ Failed $FILE:$LINE — $ERROR_MSG${NC}"
    fi
  done < <(echo "$REVIEW_JSON" | jq -c '.comments[]')
fi

echo ""
echo -e "${GREEN}🎉 Done! View PR at: https://github.com/$REPO/pull/$PR${NC}"
