#!/usr/bin/env bash
set -euo pipefail

# =================== SCRIPT CONFIG ===================
GITHUB_ORG="Nokia3-development"
JSON_REPO="crevanth/hmd-oss-scraper"
JSON_BRANCH="main"
# =====================================================

# --- Helper Functions (No changes needed here) ---
need() { command -v "$1" >/dev/null 2>&1 || { echo "Error: Missing required tool: '$1'. Please install it." >&2; exit 1; }; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
clean_repo_root() { if [ -n "$(git ls-files -z | tr -d '\0')" ]; then git ls-files -z | xargs -0 git rm -f -r --quiet || true; fi; find "$PWD" -mindepth 1 -maxdepth 1 ! -name ".git" ! -name ".gitmodules" ! -name ".cache_downloads" ! -name ".gitignore" -exec rm -rf {} + || true; find "$PWD" -name ".DS_Store" -delete || true; }

# --- Script Start & Validation ---
need git; need curl; need tar; need rsync; need jq; need gh
if [ "$#" -ne 2 ]; then echo "Usage: $0 <github_token> \"<Device Name>\""; exit 1; fi
GH_TOKEN="$1"; DEVICE_HUMAN="$2"
if [ -z "$GH_TOKEN" ]; then echo "Error: GitHub token (first argument) is empty." >&2; exit 1; fi

# --- Configure Git and GitHub Authentication ---
echo "-> Configuring Git user identity..."; git config --global user.name "GitHub Actions Bot"; git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
echo "-> Authenticating with GitHub CLI..."; echo "$GH_TOKEN" | gh auth login --with-token
echo "-> Setting up Git credential helper..."; gh auth setup-git
echo "-> Verifying authentication status silently..."; gh auth status &>/dev/null

# --- Fetch and Parse Data ---
echo "-> Fetching version data for '$DEVICE_HUMAN'..."
JSON_URL="https://raw.githubusercontent.com/${JSON_REPO}/${JSON_BRANCH}/data/hmd_releases.json"
JSON_DATA=$(curl -sL --fail "$JSON_URL") || { echo "Error: Failed to fetch JSON data from $JSON_URL" >&2; exit 1; }
if ! echo "$JSON_DATA" | jq -e --arg device "$DEVICE_HUMAN" '.[$device]' > /dev/null; then echo "Error: Device '$DEVICE_HUMAN' not found..." >&2; exit 1; fi

DEVICE_SLUG=$(echo "$DEVICE_HUMAN" | tr '[:upper:]' '[:lower:]' | \
  sed 's/+/ plus/g' | \
  sed -E 's/[ ()-]+/_/g' | \
  sed 's/__+/_/g'
)
DEVICE_BRANCH=$(echo "$DEVICE_HUMAN" | sed -E 's/[()]+//g' | sed 's/ /_/' | sed 's/ /-/g')

GITHUB_REPO_NAME="android_kernel_${DEVICE_SLUG}"
GITHUB_REPO_URL="${GITHUB_ORG}/${GITHUB_REPO_NAME}"
REPO_DIR="./${GITHUB_REPO_NAME}"
BRANCH_NAME="hmd/${DEVICE_BRANCH}"
echo "=============================================="; echo "Device:          $DEVICE_HUMAN"; echo "GitHub Repo:     $GITHUB_REPO_URL"; echo "Local Directory: $REPO_DIR"; echo "Branch Name:     $BRANCH_NAME"; echo "==============================================";
echo "-> Checking for existing GitHub repository..."; if ! gh repo view "$GITHUB_REPO_URL" >/dev/null 2>&1; then echo "-> Repository does not exist. Creating it now..."; gh repo create "$GITHUB_REPO_URL" --public --description "Kernel source for ${DEVICE_HUMAN}"; echo "-> Repository created successfully."; else echo "-> Repository already exists."; fi;
mkdir -p "$REPO_DIR"; cd "$REPO_DIR"; if [ ! -d .git ]; then git init; fi; git checkout -B "$BRANCH_NAME";
grep -qxF ".DS_Store" .git/info/exclude 2>/dev/null || echo ".DS_Store" >> .git/info/exclude;
grep -qxF ".cache_downloads/" .git/info/exclude 2>/dev/null || echo ".cache_downloads/" >> .git/info/exclude;
CACHE_DIR="$PWD/.cache_downloads"; mkdir -p "$CACHE_DIR";

# --- Setup Remote URL and fetch tags ---
REMOTE_URL="https://github.com/${GITHUB_REPO_URL}.git"
if ! git remote | grep -q '^origin$'; then
    git remote add origin "$REMOTE_URL"
else
    git remote set-url origin "$REMOTE_URL"
fi
git fetch --tags origin || true

echo "-> Syncing with remote to prevent push errors..."
git pull --rebase origin "$BRANCH_NAME" || true

# Check if this is a brand new repo by checking for remote tags
IS_NEW_REPO="false"
if [ -z "$(git ls-remote --tags origin)" ]; then
    echo "-> Detected a new repository with no existing tags."
    IS_NEW_REPO="true"
fi
HAS_SUCCESSFUL_IMPORT="false"

echo "$JSON_DATA" | jq -r --arg device "$DEVICE_HUMAN" '.[$device][] | "\(.name) \(.link)"' | while read -r ARCHIVE_NAME URL; do
    TAG="${ARCHIVE_NAME%.tar.*}"; LOCAL="${CACHE_DIR}/${ARCHIVE_NAME}";
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || git ls-remote --tags origin | grep -q "refs/tags/$TAG$"; then
        echo "==> SKIP $TAG (tag exists)";
        continue;
    fi;

    echo "==> Processing $TAG";
    if [ ! -f "$LOCAL" ]; then
        echo "-> Downloading $URL";
        download_success=false
        for attempt in 1 2 3; do
            if curl -fL --retry 3 --retry-delay 2 -o "$LOCAL" "$URL"; then
                download_success=true
                break
            fi
            echo "-> Download attempt $attempt failed."
        done

        if [ "$download_success" != true ]; then
            echo "!! Download failed after retries (URL dead or 404)"
            export GIT_AUTHOR_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE";
            git commit --allow-empty -m "${DEVICE_HUMAN}: Skipping ${TAG} (download failed)" \
                -m "Source: ${URL}"
            git tag -a "$TAG" -m "${DEVICE_HUMAN} ${TAG} kernel source drop (MISSING)"
            git push -u origin "$BRANCH_NAME"
            git push origin "$TAG"
            continue
        fi
    else
        echo "-> Using cache $LOCAL";
    fi;

    SUM="$(sha256 "$LOCAL")";
    echo "-> SHA256 $SUM";

    extract_success=false
    for attempt in 1 2 3; do
        TMPDIR="$(mktemp -d -t kernel_extract.XXXXXX)"
        trap 'rm -rf "$TMPDIR"' EXIT

        echo "-> Extracting archive (attempt $attempt)..."
        if tar -xf "$LOCAL" -C "$TMPDIR"; then
            extract_success=true
            break
        fi

        echo "!! Extraction failed on attempt $attempt"
        rm -rf "$TMPDIR"
    done

    if [ "$extract_success" != true ]; then
        echo "!! Archive corrupted after 3 attempts"
        export GIT_AUTHOR_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE";
        git commit --allow-empty -m "${DEVICE_HUMAN}: Skipping ${TAG} (corrupted archive)" \
            -m "Source: ${URL}" \
            -m "Archive: ${ARCHIVE_NAME}" \
            -m "SHA256: ${SUM}"
        git tag -a "$TAG" -m "${DEVICE_HUMAN} ${TAG} kernel source drop (CORRUPTED)"
        git push -u origin "$BRANCH_NAME"
        git push origin "$TAG"
        continue
    fi

    KDIR=""; while IFS= read -r -d '' d; do if [ -f "$d/Makefile" ] && [ -d "$d/arch" ] && [ -d "$d/drivers" ]; then KDIR="$d"; break; fi; done < <(find "$TMPDIR" -type d -print0);
    
    if [ -z "$KDIR" ]; then
        echo "!! ERROR: No valid kernel root found in '$ARCHIVE_NAME'. Tagging release as corrupted."
        export GIT_AUTHOR_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE";
        git commit --allow-empty -m "${DEVICE_HUMAN}: Skipping ${TAG} (invalid content)" \
            -m "Source: ${URL}" \
            -m "Archive: ${ARCHIVE_NAME}" \
            -m "SHA256: ${SUM}" \
            -m "Error: Archive extracted successfully but contained no kernel root directory."
        git tag -a "$TAG" -m "${DEVICE_HUMAN} ${TAG} kernel source drop (CORRUPTED)"
        git push -u origin "$BRANCH_NAME"
        git push origin "$TAG"
        continue
    fi

    KFOLDER="$(basename "$KDIR")"; echo "-> Using detected kernel root: $KFOLDER"; clean_repo_root; rsync -a --exclude='.git' "$KDIR"/ "$PWD"/;
    VERSION_PART=$(echo "$TAG" | sed -e "s/^${DEVICE_SLUG}_//i" -e "s/^nokia[0-9]*[a-z]*_//i");
    export GIT_AUTHOR_DATE="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"; export GIT_COMMITTER_DATE="$GIT_AUTHOR_DATE";
    git add -A;

    if git diff --cached --quiet; then
        git commit --allow-empty -m "${DEVICE_HUMAN}: No changes in ${VERSION_PART}" \
            -m "Source: ${URL}" \
            -m "Archive: ${ARCHIVE_NAME}" \
            -m "SHA256: ${SUM}"
    else
        git commit -m "${DEVICE_HUMAN}: Import kernel source for ${VERSION_PART}" \
            -m "Source: ${URL}" \
            -m "Archive: ${ARCHIVE_NAME}" \
            -m "SHA256: ${SUM}" \
            -m "Notes:" \
            -m "- Imported from official open-source release archive." \
            -m "- Repository root mirrors '${KFOLDER}' subdirectory from the tarball.";
    fi;

    git tag -a "$TAG" -m "${DEVICE_HUMAN} ${VERSION_PART} kernel source drop";
    rm -rf "$TMPDIR"; trap - EXIT;

    echo "-> Pushing changes for $TAG to GitHub...";
    git push -u origin "$BRANCH_NAME"
    git push origin "$TAG"
    
    HAS_SUCCESSFUL_IMPORT="true"
    echo "==> Committed, tagged, and pushed $TAG"; echo
done;

# After processing all versions, check if a new repo had zero successful imports
if [ "$IS_NEW_REPO" = "true" ] && [ "$HAS_SUCCESSFUL_IMPORT" = "false" ]; then
    echo "-> All archives processed for new device, but none were valid."
    echo "-> Deleting empty repository $GITHUB_REPO_URL to prevent pollution."
    cd .. # Go up one level before deleting the directory
    gh repo delete "$GITHUB_REPO_URL" --yes
    echo "-> Repository deleted."
fi

echo "=============================="; echo "All tasks complete."; echo "View your repository at: $REMOTE_URL"; echo "=============================="
