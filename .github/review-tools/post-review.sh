#!/bin/bash
set -euo pipefail

if [[ -z "${COMMENTS_FILE:-}" || -z "${PR_NUMBER:-}" || -z "${REPO:-}" || -z "${HEAD_SHA:-}" ]]; then
  echo "Missing required environment variables" >&2
  exit 1
fi

if [[ ! -f "$COMMENTS_FILE" ]] || [[ ! -s "$COMMENTS_FILE" ]]; then
  echo "No comments to post"
  exit 0
fi

# Separate inline and general comments
inline_comments=$(jq -s '[.[] | select(.type == "inline")]' "$COMMENTS_FILE")
general_comments=$(jq -s '[.[] | select(.type == "general")]' "$COMMENTS_FILE")

# Build review body from general comments
body=$(echo "$general_comments" | jq -r '[.[].message] | join("\n\n")')

# Build inline comments array for GitHub API
review_comments=$(echo "$inline_comments" | jq '[.[] | {
  path: .path,
  line: .line,
  side: "RIGHT",
  body: (if .suggested_fix then (.message + "\n\n```suggestion\n" + .suggested_fix + "\n```") else .message end)
}]')

inline_count=$(echo "$review_comments" | jq 'length')
echo "Posting review with $inline_count inline comments"

# Build the review payload
payload=$(jq -n \
  --arg commit_id "$HEAD_SHA" \
  --arg body "$body" \
  --argjson comments "$review_comments" \
  '{
    commit_id: $commit_id,
    event: "COMMENT",
    body: (if $body == "" then null else $body end),
    comments: (if ($comments | length) == 0 then null else $comments end)
  } | with_entries(select(.value != null))')

# Check if payload has any content to post
if [[ $(echo "$payload" | jq 'has("body") or has("comments")') == "false" ]]; then
  echo "No content to post after filtering"
  exit 0
fi

echo "$payload" | gh api "repos/$REPO/pulls/$PR_NUMBER/reviews" --method POST --input -
echo "Review posted successfully"
