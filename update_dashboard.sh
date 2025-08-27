#!/usr/bin/env bash
set -euo pipefail

# --- Script Config ---
GITHUB_ORG="Nokia3-development"
PROFILE_REPO_NAME=".github"
PROFILE_REPO_URL="https://github.com/${GITHUB_ORG}/${PROFILE_REPO_NAME}.git"
README_PATH="profile/README.md"
TMP_DIR="./dashboard_repo"

# --- Validation ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: Missing required tool: '$1'." >&2; exit 1; }; }
need git; need gh

if [ -z "${1-}" ]; then
  echo "Usage: $0 <github_token>" >&2
  exit 1
fi
GH_TOKEN="$1"

# --- Auth ---
echo "$GH_TOKEN" | gh auth login --with-token
gh auth setup-git

# --- Clone Profile Repo ---
echo "-> Cloning the profile repository..."
rm -rf "$TMP_DIR"
git clone "$PROFILE_REPO_URL" "$TMP_DIR"
cd "$TMP_DIR"

# --- Build README Content ---
echo "-> Building new README content..."
{
  # --- START: Enhanced Disclaimer ---
  echo "# HMD/Nokia Kernel Source Archive"
  echo ""
  echo "> **Disclaimer: This is an Unofficial Community Archive**"
  echo ">"
  echo "> This organization is an independent, community-driven effort to archive kernel source code for HMD/Nokia devices. **It is not affiliated with, endorsed by, or sponsored by HMD Global or Nokia.**"
  echo ">"
  echo "> The source code is provided **\"as-is\"** without warranty of any kind. All code is subject to the licenses included within the archives (typically GPLv2). **You are solely responsible for ensuring your use of the code complies with these licenses.** The maintainers of this archive are not responsible for any misuse."
  echo ""
  echo "---"
  # --- END: Enhanced Disclaimer ---
  echo ""
  echo "## Device Kernel Repositories"
  echo ""
  # Table Header
  echo "| Device Name | Latest Kernel Version | Last Updated | Repository Link |"
  echo "|-------------|-----------------------|--------------|-----------------|"

  # Fetch repo data and generate table rows
  gh repo list "$GITHUB_ORG" --json name,description,pushedAt,url --jq '.[] | select(.name | startswith("android_kernel_"))' | while read -r line; do
    REPO_NAME=$(echo "$line" | jq -r '.name')
    REPO_URL=$(echo "$line" | jq -r '.url')
    DEVICE_NAME=$(echo "$line" | jq -r '.description' | sed 's/Kernel source for //')
    LAST_UPDATED=$(echo "$line" | jq -r '.pushedAt' | sed 's/T.*$//')

    # MODIFICATION: Use 'gh api' to reliably get the latest tag without causing SIGPIPE
    LATEST_TAG=$(gh api "repos/${GITHUB_ORG}/${REPO_NAME}/tags" --jq '.[0].name // ""')

    if [ -z "$LATEST_TAG" ]; then
      LATEST_TAG="*pending*"
    fi

    echo "| **${DEVICE_NAME}** | \`${LATEST_TAG}\` | ${LAST_UPDATED} | [${REPO_NAME}](${REPO_URL}) |"
  done
} > "$README_PATH"

echo "-> Generated README:"
cat "$README_PATH"

# --- Commit and Push ---
git config --global user.name "GitHub Actions Bot"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"

if git diff --quiet "$README_PATH"; then
  echo "-> No changes to the dashboard. Exiting."
else
  echo "-> Changes detected. Committing and pushing..."
  git add "$README_PATH"
  git commit -m "docs: Update device dashboard [skip ci]"
  git push
  echo "-> Dashboard updated successfully!"
fi
