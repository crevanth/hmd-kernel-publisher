#!/usr/bin/env bash
set -euo pipefail

# =================== SCRIPT CONFIG ===================
GITHUB_ORG="Nokia3-development"
JSON_REPO="crevanth/hmd-opensource-tracker"
JSON_BRANCH="main"
# =====================================================

# --- Helper Functions (No changes needed here) ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: Missing required tool: '$1'. Please install it." >&2; exit 1; }; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
newest_iso_utc() { local p="$1" newest=0 m=0 f=; while IFS= read -r -d '' f; do if stat -c %Y "$f" >/dev/null 2>&1; then m=$(stat -c %Y "$f"); else m=$(stat -f %m "$f"); fi; [ "$m" -gt "$newest" ] && newest="$m"; done < <(find "$p" -type f -print0 2>/dev/null || true); if [ "$newest" -eq 0 ]; then date -u +"%Y-%m-%dT%H:%M:%SZ"; elif date -u -r "$newest" +"%Y-%m-%dT%H:%M:%SZ" >/dev/null 2>&1; then date -u -r "$newest" +"%Y-%m-%dT%H:%M:%SZ"; else date -u -d "@$newest" +"%Y-%m-%dT%H:%M:%SZ"; fi; }
clean_repo_root() { if [ -n "$(git ls-files -z | tr -d '\0')" ]; then git ls-files -z | xargs -0 git rm -f -r --quiet || true; fi; find "$PWD" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".gitmodules" ! -name ".cache_downloads" ! -name ".gitignore" -exec rm -rf {} + || true; find "$PWD" -name ".DS_Store" -delete || true; }
get_commit_date() { local url="$1"; local fallback_dir="$2"; local http_date_str; http_date_str=$(curl -sI "$url" | grep -i "^Last-Modified:" | sed 's/Last-Modified: //i' | tr -d '\r\n'); if [[ -n "$http_date_str" ]]; then if parsed_date=$(date -u -d "$http_date_str" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null); then echo "$parsed_date"; return; fi; fi; echo "-> Warning: Could not get valid Last-Modified header. Falling back to file modification time." >&2; newest_iso_utc "$fallback_dir"; }

# --- Script Start & Validation ---
need git; need curl; need tar; need rsync; need jq; need gh
if [ "$#" -ne 2 ]; then echo "Usage: $0 <github_token> \"<Device Name>\""; exit 1; fi
GH_TOKEN="$1"; DEVICE_HUMAN="$2"
if [ -z "$GH_TOKEN" ]; then echo "Error: GitHub token (first argument) is empty." >&2; exit 1; fi

# --- Configure Git and GitHub Authentication ---
echo "-> Configuring Git user identity..."; git config --global user.name "GitHub Actions Bot"; git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
echo "-> Authenticating with GitHub CLI..."; echo "$GH_TOKEN" | gh auth login --with-token
echo "-> Setting up Git credential helper..."; gh auth setup-git

# --- THIS IS THE FIX ---
# Verify authentication status, but redirect its output so the token is not printed to the log.
# The command will still exit with an error if authentication fails.
echo "-> Verifying authentication status silently..."
gh auth status &>/dev/null
# --- END OF FIX ---

# --- Fetch and Parse Data ---
echo "-> Fetching version data for '$DEVICE_HUMAN'..."
JSON_URL="https://raw.githubusercontent.com/${JSON_REPO}/${JSON_BRANCH}/hmd_versions.json"
JSON_DATA=$(curl -sL --fail "$JSON_URL") || { echo "Error: Failed to fetch JSON data from $JSON_URL" >&2; exit 1; }
if ! echo "$JSON_DATA" | jq -e --arg device "$DEVICE_HUMAN" '.[$device]' > /dev/null; then echo "Error: Device '$DEVICE_HUMAN' not found..." >&2; exit 1; fi
DEVICE_SLUG=$(echo "$DEVICE_HUMAN" | tr '[:upper:]' '[:lower:]' | tr -s ' .()' '_'); GITHUB_REPO_NAME="android_kernel_${DEVICE_SLUG}"; GITHUB_REPO_URL="${GITHUB_ORG}/${GITHUB_REPO_NAME}"; REPO_DIR="./${GITHUB_REPO_NAME}"; BRANCH_NAME="hmd/${DEVICE_SLUG}";
echo "=============================================="; echo "Device:          $DEVICE_HUMAN"; echo "GitHub Repo:     $GITHUB_REPO_URL"; echo "Local Directory: $REPO_DIR"; echo "Branch Name:     $BRANCH_NAME"; echo "==============================================";
echo "-> Checking for existing GitHub repository..."; if ! gh repo view "$GITHUB_REPO_URL" >/dev/null 2>&1; then echo "-> Repository does not exist. Creating it now..."; gh repo create "$GITHUB_REPO_URL" --public --description "Kernel source history for the ${DEVICE_HUMAN}"; echo "-> Repository created successfully."; else echo "-> Repository already exists."; fi;
mkdir -p "$REPO_DIR"; cd "$REPO_DIR"; if [ ! -d .git ]; then git init; fi; git checkout -B "$BRANCH_NAME"; grep -qxF ".DS_Store" .git/info/exclude 2>/dev/null || echo ".DS_Store" >> .git/info/exclude; grep -qxF ".cache_downloads/" .git/info/exclude 2>/dev/null || echo ".cache_downloads/" >> .git/info/exclude;
CACHE_DIR="$PWD/.cache_downloads"; mkdir -p "$CACHE_DIR";

# --- Setup Remote URL before the loop ---
REMOTE_URL="https://github.com/${GITHUB_REPO_URL}.git"
if ! git remote | grep -q '^origin$'; then
    git remote add origin "$REMOTE_URL"
else
    git remote set-url origin "$REMOTE_URL"
fi

echo "$JSON_DATA" | jq -r --arg device "$DEVICE_HUMAN" '.[$device][] | "\(.name) \(.link)"' | while read -r ARCHIVE_NAME URL; do
    TAG="${ARCHIVE_NAME%.tar.*}"; LOCAL="${CACHE_DIR}/${ARCHIVE_NAME}"; if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then echo "==> SKIP $TAG (tag exists)"; continue; fi;
    echo "==> Processing $TAG"; if [ ! -f "$LOCAL" ]; then echo "-> Downloading $URL"; curl -fL --retry 3 --retry-delay 2 -o "$LOCAL" "$URL"; else echo "-> Using cache $LOCAL"; fi;
    SUM="$(sha256 "$LOCAL")"; echo "-> SHA256 $SUM"; TMPDIR="$(mktemp -d -t kernel_extract.XXXXXX)"; trap 'rm -rf "$TMP_DIR"' EXIT; echo "-> Extracting archive..."; if [[ "$ARCHIVE_NAME" == *.bz2 ]]; then tar -xjf "$LOCAL" -C "$TMPDIR"; elif [[ "$ARCHIVE_NAME" == *.gz ]]; then tar -xzf "$LOCAL" -C "$TMPDIR"; else tar -xf "$LOCAL" -C "$TMPDIR"; fi;
    KDIR=""; while IFS= read -r -d '' d; do if [ -f "$d/Makefile" ] && [ -d "$d/arch" ] && [ -d "$d/drivers" ]; then KDIR="$d"; break; fi; done < <(find "$TMPDIR" -type d -print0);
    if [ -z "$KDIR" ]; then echo "ERROR: No valid kernel root found in $ARCHIVE_NAME" >&2; exit 1; fi;
    KFOLDER="$(basename "$KDIR")"; echo "-> Using detected kernel root: $KFOLDER"; clean_repo_root; rsync -a --exclude='.git' "$KDIR"/ "$PWD"/; rm -f ".DS_Store" || true;
    VERSION_PART=$(echo "$TAG" | sed -e "s/^${DEVICE_SLUG}_//i" -e "s/^nokia[0-9]*[a-z]*_//i"); COMMIT_DATE="$(get_commit_date "$URL" "$KDIR")"; export GIT_AUTHOR_DATE="$COMMIT_DATE"; export GIT_COMMITTER_DATE="$COMMIT_DATE";
    git add -A; git commit -m "${DEVICE_HUMAN}: Import kernel source for ${VERSION_PART}" -m "Source: ${URL}
Archive: ${ARCHIVE_NAME}
SHA256: ${SUM}
Notes:
- Imported from official open-source release archive.
- Repository root mirrors '${KFOLDER}' subdirectory from the tarball.";
    git tag -a "$TAG" -m "${DEVICE_HUMAN} ${VERSION_PART} kernel source drop";
    rm -rf "$TMPDIR"; trap - EXIT;

    echo "-> Pushing changes for $TAG to GitHub...";
    git push -u origin "$BRANCH_NAME"
    git push origin "$TAG"

    echo "==> Committed, tagged, and pushed $TAG"; echo
done;

echo "=============================="; echo "All tasks complete."; echo "View your repository at: $REMOTE_URL"; echo "=============================="