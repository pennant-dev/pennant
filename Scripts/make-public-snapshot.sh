#!/bin/zsh
# Makes a fresh repository from the current commit (no history) with one commit under the identity you give, ready
# to push to a public remote. It stops if the tree holds a private key, something that looks like a live token,
# your home folder's path, or anything matching PUBLISH_DENY (an extended regex you keep out of the repo).
#
# Usage: PUBLISH_DENY='mycompany|myhost' Scripts/make-public-snapshot.sh <new folder> "<Author Name>" <author@email>
set -euo pipefail
cd "$(dirname "$0")/.."
[[ $# -eq 3 ]] || { echo "usage: $0 <new folder> \"<Author Name>\" <author@email>"; exit 2; }
TARGET=$1 NAME=$2 EMAIL=$3
if [[ -e $TARGET ]] && [[ -n "$(ls -A "$TARGET")" ]]; then echo "$TARGET is not empty"; exit 1; fi
mkdir -p "$TARGET"
git archive HEAD | tar -x -C "$TARGET"

checks=(
  'BEGIN [A-Z ]*PRIVATE KEY-----'
  '(ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{20,}'
  'sk-(proj|live|ant)-[A-Za-z0-9_-]{20,}'
  'AKIA[0-9A-Z]{16}'
  'xox[bap]-[0-9A-Za-z-]{10,}'
  "/Users/$(whoami)"
)
[[ -n ${PUBLISH_DENY:-} ]] && checks+=("$PUBLISH_DENY")
found=0
for pattern in $checks; do
  if grep -rInEi -- "$pattern" "$TARGET" >/dev/null 2>&1; then
    echo "Stopped: the tree matches \"$pattern\":"; grep -rInEi -- "$pattern" "$TARGET" | head -5; found=1
  fi
done
[[ $found -eq 0 ]] || { rm -rf "$TARGET"; exit 1; }

cd "$TARGET"
git init -q -b main
git add -A
GIT_AUTHOR_NAME=$NAME GIT_AUTHOR_EMAIL=$EMAIL GIT_COMMITTER_NAME=$NAME GIT_COMMITTER_EMAIL=$EMAIL \
  git commit -q -m "Pennant: first public release"
echo "Snapshot ready in $TARGET ($(git rev-parse --short HEAD), $(git ls-files | wc -l | tr -d ' ') files)."
echo "Push it when you're ready, for example: git -C \"$TARGET\" remote add origin git@github.com:pennant-dev/pennant.git && git -C \"$TARGET\" push -u origin main"
