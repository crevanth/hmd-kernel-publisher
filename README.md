# HMD/Nokia Kernel Source Publisher

This repository contains a powerful automation script designed to fetch HMD Global/Nokia phone kernel source code releases, process them, and publish them to dedicated, version-controlled GitHub repositories. It creates a clean, tagged, and browsable history of kernel source releases for various devices, making it easier for developers and enthusiasts to track changes over time.

The automation relies on the [hmd-opensource-tracker](https://github.com/crevanth/hmd-opensource-tracker) project, which maintains a JSON file of direct download links for kernel source archives.

## Disclaimer

**This project is an independent, community-driven effort and is not affiliated with, endorsed by, or sponsored by HMD Global or Nokia.**

All kernel source code is downloaded directly from official, publicly accessible servers provided by HMD Global in compliance with their open-source obligations. The purpose of this tool is to provide a clean, version-controlled, and easily accessible archive of these releases for developers and researchers.

The source code is provided **"as-is"** without warranty of any kind and is subject to the licenses included within the code itself (typically the GNU General Public License, version 2). **You are solely responsible for ensuring your use of the code complies with these licenses.** The maintainers of this project are not responsible for any misuse of the source code.

## How It Works

The system's logic is primarily handled by two scripts:

First, the `import_kernel_sources.sh` script performs the following steps for each device:

1.  **Fetch Data**: It reads a list of devices and their corresponding kernel source archive URLs from the `hmd_releases.json` file.
2.  **Create Repository**: If one doesn't already exist, it creates a new public GitHub repository for the device (e.g., `Nokia3-development/android_kernel_nokia_3_1`).
3.  **Process Each Release**: It iterates through each source code archive for the device.
4.  **Download & Verify**: It downloads the source `.tar.gz` archive, retrying on failure, and verifies its integrity.
5.  **Commit Source**: It extracts the archive, identifies the kernel root directory, and commits the clean source code to the device's repository.
6.  **Tag Release**: It creates a Git tag for the commit, corresponding to the official version name of the archive (e.g., `NE1_00WW_4_14F`). This ensures a one-to-one mapping between official releases and repository tags.
7.  **Push to GitHub**: Finally, it pushes the new commit and tag to the dedicated device repository.

This process is designed to be robust, handling download failures and corrupted archives gracefully by creating an empty commit with a note and an appropriate tag (`MISSING` or `CORRUPTED`).

Second, after the scheduled builds are complete, the `update_dashboard.sh` script runs to automatically regenerate the main README on the GitHub organization's profile, providing an up-to-date summary of all repositories.

## Automation

The entire process is automated using GitHub Actions, defined in `.github/workflows/main.yml`. The workflow can be triggered in two ways:

### 1. Scheduled Run
- **When**: Automatically runs once a week (every Sunday at 02:00 UTC).
- **What**: It fetches the complete list of devices and runs the `import_kernel_sources.sh` script for every single one. After all devices are processed, it executes the `update_dashboard.sh` script to ensure the organization's dashboard is up-to-date.

### 2. Manual Trigger
- **When**: Can be triggered manually at any time from the GitHub Actions tab.
- **What**: This allows you to run the process for a single, specific device using the `import_kernel_sources.sh` script. This is useful for adding a new device or re-running the process for a device that may have failed previously.

To run the workflow manually:
1.  Navigate to the **Actions** tab of this repository.
2.  Select the **Build and Push HMD Kernel Repos** workflow from the sidebar.
3.  Click the **Run workflow** dropdown.
4.  Enter the exact device name (e.g., "Nokia 3.1") in the `device_name` input field.
5.  Click the **Run workflow** button.

## Configuration

The script and workflow can be configured as follows:

-   **`import_kernel_sources.sh`**:
    -   `GITHUB_ORG`: The target GitHub organization where the kernel repositories will be created.
    -   `JSON_REPO`: The repository that hosts the `hmd_releases.json` tracker file.
-   **GitHub Actions**:
    -   `HMD_ARCHIVE_TOKEN`: A GitHub Personal Access Token (PAT) with `repo` scope must be added as a repository secret. This token is required for creating new repositories and pushing code.

## Dependencies

The `import_kernel_sources.sh` script requires the following command-line tools to be installed:

-   `git`
-   `curl`
-   `tar`
-   `rsync`
-   `jq`
-   `gh` (GitHub CLI)
