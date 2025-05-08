#!/bin/zsh

set -euo pipefail

# Temp file for original commits
COMMIT_MAP="$(mktemp)"
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)

# Step 1: Capture original commit metadata (in order)
git log --reverse --pretty=format:'%H|%aI|%cI|%s' > "$COMMIT_MAP"

echo "📝 Captured original commit metadata."

# Step 2: Start interactive rebase from the root with edit on every commit
GIT_EDITOR='sed -i "" "s/^pick /edit /"' git rebase -i --root

# Step 3: Loop through commits, amend with GPG and restore timestamps
while true; do
  NEW_SHA=$(git rev-parse HEAD)
  MSG=$(git log -1 --pretty=format:'%s')

  # Match by commit message, in order
  ORIGINAL_LINE=$(grep "|$MSG\$" "$COMMIT_MAP" | head -n 1)

  if [[ -z "$ORIGINAL_LINE" ]]; then
    echo "❌ Could not find original commit data for message: $MSG"
    exit 1
  fi

  AUTHOR_DATE=$(echo "$ORIGINAL_LINE" | cut -d'|' -f2)
  COMMITTER_DATE=$(echo "$ORIGINAL_LINE" | cut -d'|' -f3)

  # Amend with GPG signing and restored timestamps
  GIT_COMMITTER_DATE="$COMMITTER_DATE" git commit --amend --no-edit --gpg-sign --date="$AUTHOR_DATE"

  # Remove the used entry so future duplicates (same message) don't match it
  grep -vF "$ORIGINAL_LINE" "$COMMIT_MAP" > "$COMMIT_MAP.tmp" && mv "$COMMIT_MAP.tmp" "$COMMIT_MAP"

  # Continue or break
  git rebase --continue || break
done

# Cleanup
rm "$COMMIT_MAP"
echo "✅ Rebase complete with original dates and GPG signatures."
