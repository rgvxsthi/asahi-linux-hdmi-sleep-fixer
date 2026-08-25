#!/bin/bash
# =============================================================================
# asahi-fairydust-build.sh
#
# Enables USB-C DisplayPort Alt Mode (external display) on Fedora Asahi Remix
# for Apple Silicon Macs by building the Asahi Linux "fairydust" kernel branch.
#
# Tested on: MacBook Air M2 running Fedora Asahi Remix (XFCE)
# Author:    Tejas Bharambe
# License:   MIT
# Date:      April 2026
#
# WHAT THIS DOES:
#   1. Installs build dependencies (including Rust toolchain)
#   2. Clones the Asahi Linux fairydust kernel branch
#   3. Configures the kernel with full Fedora config + DP Alt Mode + GPU (Rust)
#   4. Builds and installs the kernel
#   5. Updates m1n1 bootloader and GRUB
#   6. Sets up typec module autoloading
#
# REQUIREMENTS:
#   - Fedora Asahi Remix on Apple Silicon Mac
#   - At least 15GB free disk space
#   - Internet connection
#   - sudo access
#
# USAGE:
#   chmod +x asahi-fairydust-build.sh
#   ./asahi-fairydust-build.sh
#
# NOTES:
#   - The build takes 60-90+ minutes depending on your Mac
#   - After reboot, select the kernel with "-hdmifix" in GRUB
#     (or whatever LOCALVERSION you set)
#   - Use the FRONT-MOST USB-C port for external display
#   - This script is provided as-is with no warranty
# =============================================================================

set -eo pipefail

# Resolve this script's directory ONCE, here, before anything changes
# directory. ${BASH_SOURCE[0]} is whatever path was used to invoke the script,
# so for the usual ./asahi-fairydust-build.sh it is relative. Resolving it
# later, after clone_source has cd'd into the kernel tree, silently produced
# the kernel tree instead, so patches/ was never found and the build completed
# reporting success with none of the patches applied.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- Configuration ---
# Overridable from the environment, e.g. BRANCH=my-branch ./asahi-fairydust-build.sh
REPO_URL="${REPO_URL:-https://github.com/AsahiLinux/linux.git}"
CLONE_DIR="${CLONE_DIR:-$HOME/linux-fairydust}"
BRANCH="${BRANCH:-}"
LOCALVERSION="${LOCALVERSION:--hdmifix}"
JOBS="${JOBS:-$(nproc)}"
LOG_FILE="$HOME/fairydust-build.log"

# Prefer the distro Rust toolchain over anything rustup installed.
#
# The kernel compiles the Rust core library from source, so rustc and the
# rust-src tree must be the same version. A rustup toolchain in ~/.cargo/bin
# takes precedence on PATH and is usually a different version from the
# rust-src RPM, which makes rust/core.o fail to build with errors like
# "attributes starting with `rustc` are reserved" and
# "cannot use `const` closures outside of const contexts".
#
# Fedora only. ALARM's linux-asahi PKGBUILD deliberately uses rustup with a
# pinned rust-toolchain.toml, so forcing the system toolchain there would
# override the one the package expects.
pin_fedora_rust_toolchain() {
    if [[ -x /usr/bin/rustc && -d /usr/lib/rustlib/src/rust/library ]]; then
        export PATH="/usr/bin:$PATH"
        export RUST_LIB_SRC="/usr/lib/rustlib/src/rust/library"
        info "Using the distro Rust toolchain: $(/usr/bin/rustc --version)"
    fi
}

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

log_and_run() {
    echo "$ $*" >> "$LOG_FILE"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    return "${PIPESTATUS[0]}"
}

confirm() {
    # ASSUME_YES lets the build run unattended. NO_REBOOT is handled separately
    # so that an unattended run never reboots the machine by itself.
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "$1 [auto-yes]"
        return 0
    fi
    if ! read -rp "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response; then
        error "No input available (stdin closed). Re-run attached to a terminal,
or set ASSUME_YES=1 to answer prompts automatically."
    fi
    [[ "$response" =~ ^[Yy]$ ]]
}

# Same as confirm(), but defaults to yes on an empty answer. Used for the
# patch prompts, where applying is the reason the user ran this at all.
confirm_default_yes() {
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "$1 [auto-yes]"
        return 0
    fi
    if ! read -rp "$(echo -e "${YELLOW}$1 [Y/n]:${NC} ")" response; then
        error "No input available (stdin closed). Re-run attached to a terminal,
or set ASSUME_YES=1 to answer prompts automatically."
    fi
    [[ -z "$response" || "$response" =~ ^[Yy]$ ]]
}

# --- Which distribution are we on ---
#
# Sets DISTRO to "fedora" or "alarm". Anything else is unsupported, because the
# install step has to know how the distro wires up m1n1, the bootloader and the
# initramfs, and guessing there is how people end up unbootable.
detect_distro() {
    local id id_like
    id="$(. /etc/os-release 2>/dev/null && echo "${ID:-}")"
    id_like="$(. /etc/os-release 2>/dev/null && echo "${ID_LIKE:-}")"

    case "$id" in
        fedora) DISTRO="fedora"; return ;;
        arch|archarm|asahi-alarm) DISTRO="alarm"; return ;;
    esac
    case "$id_like" in
        *fedora*) DISTRO="fedora"; return ;;
        *arch*)   DISTRO="alarm";  return ;;
    esac

    error "Unsupported distribution (ID=$id).
This script handles Fedora Asahi Remix and Asahi ALARM (Arch). On anything
else, apply patches/*.patch to your kernel source by hand."
}

# --- Pre-flight Checks ---
preflight() {
    echo ""
    echo "============================================================"
    echo "  Asahi Linux Fairydust Kernel Builder"
    echo "  USB-C DisplayPort Alt Mode for Apple Silicon Macs"
    echo "============================================================"
    echo ""

    # Must not be root
    if [[ $EUID -eq 0 ]]; then
        error "Do not run this script as root. Run as your normal user (sudo will be used when needed)."
    fi

    # Fedora and Asahi ALARM (Arch) take completely different paths: Fedora
    # builds the tree directly, ALARM goes through its linux-asahi PKGBUILD.
    detect_distro
    info "Distribution: $DISTRO"

    if [[ "$(uname -m)" != "aarch64" ]]; then
        error "This script is for Apple Silicon (aarch64) only. Detected: $(uname -m)"
    fi

    info "Current kernel: $(uname -r)"

    # Check disk space (need at least 15GB)
    AVAIL_GB=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    info "Available disk space: ${AVAIL_GB}GB"
    if [[ "$AVAIL_GB" -lt 15 ]]; then
        error "Need at least 15GB free disk space. You have ${AVAIL_GB}GB. Free up space and try again."
    fi
    ok "Disk space check passed"

    # Check internet
    if ! ping -c 1 github.com &>/dev/null; then
        error "No internet connection. Please connect and try again."
    fi
    ok "Internet connection available"

    # Check whether we are already running a kernel this script built. Matching
    # only "fairydust" went stale when the default LOCALVERSION became
    # -hdmifix, so match the current default plus the suffixes used before.
    if uname -r | grep -qE "$(printf '%s\n' "${LOCALVERSION#-}" fairydust rgvx hdmifix | sort -u | paste -sd'|')"; then
        warn "You're already running a kernel from this script: $(uname -r)"
        if ! confirm "Continue anyway (rebuild)?"; then
            exit 0
        fi
    fi

    echo ""
    warn "This script will:"
    if [[ "$DISTRO" == "alarm" ]]; then
        echo "  - Install build dependencies (base-devel, git, pacman-contrib)"
        echo "  - Clone asahi-alarm/PKGBUILDs"
        echo "  - Add the selected patches to the linux-asahi PKGBUILD"
        echo "  - Build and install that package with makepkg -si"
        echo ""
        echo "  Bootloader and initramfs are left to Arch's packaging."
        echo "  Your current kernel package stays installed unless makepkg succeeds."
    else
        echo "  - Install build dependencies (~2GB)"
        echo "  - Clone the Asahi Linux kernel source (~3GB)"
        echo "  - Build a custom kernel (~10-15GB build artifacts)"
        echo "  - Install the kernel alongside your existing one"
        echo "  - Modify GRUB and m1n1 bootloader configuration"
    fi
    echo ""
    warn "The build will take 60-90+ minutes."
    echo ""

    if ! confirm "Do you want to proceed?"; then
        info "Aborted."
        exit 0
    fi

    echo "" > "$LOG_FILE"
    info "Logging to $LOG_FILE"
}

# --- Step 1: Install Build Dependencies ---
install_deps() {
    echo ""
    info "=== Step 1/8: Installing build dependencies ==="

    sudo dnf install -y \
        gcc gcc-c++ make bc bison flex elfutils-libelf-devel \
        ncurses-devel python3 zlib-devel libuuid-devel dwarves \
        xz zstd clang llvm lld git \
        openssl openssl-devel \
        rust rust-std-static bindgen-cli \
        2>&1 | tee -a "$LOG_FILE"

    # Install rust-src (needed for kernel Rust support - provides core library source)
    info "Installing rust-src..."
    sudo dnf install -y rust-src 2>&1 | tee -a "$LOG_FILE" || true

    # Verify the core library source exists; if not, try rustup fallback
    if [[ ! -f /usr/lib/rustlib/src/rust/library/core/src/lib.rs ]]; then
        warn "rust-src not found via dnf. Trying rustup fallback..."
        if command -v rustup &>/dev/null; then
            rustup component add rust-src 2>&1 | tee -a "$LOG_FILE"
        else
            warn "rustup not available, and the distro rust-src package is missing."
            warn "The alternative is to download https://sh.rustup.rs and pipe it"
            warn "into a shell, which is a third-party installer, not a distro package."
            if ! confirm "Download and run the rustup installer?"; then
                error "Cannot build the Rust parts of the kernel without a matching
rust-src. Install it from your distro (dnf install rust-src) and re-run."
            fi
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | tee -a "$LOG_FILE"
            source "$HOME/.cargo/env"
            rustup component add rust-src 2>&1 | tee -a "$LOG_FILE"
        fi
    fi

    # Install glx-utils for post-build GPU verification
    sudo dnf install -y glx-utils 2>&1 | tee -a "$LOG_FILE" || true

    # Verify Rust toolchain
    if ! command -v rustc &>/dev/null; then
        error "rustc not found after installation. Please install Rust manually."
    fi

    if ! command -v bindgen &>/dev/null; then
        error "bindgen not found after installation. Please install bindgen-cli manually."
    fi

    ok "Build dependencies installed"
    info "  rustc:   $(rustc --version)"
    info "  bindgen: $(bindgen --version)"
}

# --- Turn a kernel Makefile on stdin into "7.1.6" ---
#
# Prints nothing if the input is not a kernel Makefile, so callers can test for
# an empty string instead of getting a bare "..".
parse_makefile_version() {
    awk -F' *= *' '
        $1 == "VERSION"      { v = $2 }
        $1 == "PATCHLEVEL"   { p = $2 }
        $1 == "SUBLEVEL"     { s = $2 }
        $1 == "EXTRAVERSION" { e = $2 }
        END { if (v != "") print v "." p "." s e }
    '
}

# --- owner/repo for a git remote URL, or failure ---
#
# Handles the https and ssh spellings of a GitHub URL. Anything else (a local
# path, a mirror, gitlab) fails, and callers fall back to printing no version
# rather than guessing a URL scheme that does not exist.
github_repo_path() {
    local url="$1" path
    case "$url" in
        https://github.com/*)   path="${url#https://github.com/}" ;;
        http://github.com/*)    path="${url#http://github.com/}" ;;
        ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
        git@github.com:*)       path="${url#git@github.com:}" ;;
        *) return 1 ;;
    esac
    path="${path%.git}"
    path="${path%/}"
    [[ -n "$path" ]] || return 1
    printf '%s' "$path"
}

# Where a branch's file contents live ...
github_raw_base() {
    local path
    path="$(github_repo_path "$1")" || return 1
    printf 'https://raw.githubusercontent.com/%s' "$path"
}

# ... and where its commit metadata lives. Raw file serving carries no dates,
# so the "last updated" column needs the API instead.
github_api_base() {
    local path
    path="$(github_repo_path "$1")" || return 1
    printf 'https://api.github.com/repos/%s' "$path"
}

# --- Commit date of a branch tip, out of the GitHub commits API ---
#
# Reads the second "date" in the response, which is the committer date of the
# newest commit. Author date comes first and is the wrong one here: a rebase
# preserves it, so it would report these branches as older than they are.
#
# per_page=1 keeps the response to a single commit object, which is what makes
# "the second date" a fixed position rather than a guess. No jq: this script
# does not otherwise need it, and one field is not worth a dependency.
parse_commit_date() {
    grep -o '"date"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | sed -n '2s/.*"\([^"]*\)"$/\1/p'
}

# "3 days ago" from a count of seconds. Whole units only: the menu wants
# freshness at a glance, not a precise duration. A negative count (a skewed
# clock, a commit dated in the future) falls into the first branch and reads
# as recent, which is the harmless way to be wrong here.
relative_age() {
    local secs="$1" n unit
    if   (( secs < 3600 ));   then printf 'less than an hour ago'; return
    elif (( secs < 86400 ));  then n=$(( secs / 3600 ));   unit="hour"
    elif (( secs < 604800 )); then n=$(( secs / 86400 ));  unit="day"
    else                           n=$(( secs / 604800 )); unit="week"
    fi
    if (( n == 1 )); then
        printf '1 %s ago' "$unit"
    else
        printf '%d %ss ago' "$n" "$unit"
    fi
}

# --- Kernel version of each branch, without cloning any of them ---
#
# The menu used to hard-code "Currently Linux 7.1.5", which goes stale the
# moment Asahi rebases these branches, and they rebase often. Git has no way to
# read one file out of a remote repository over HTTPS: ls-remote returns commit
# ids only, and GitHub does not serve git archive --remote. So read the
# branch's Makefile from raw.githubusercontent instead, which is one small HTTP
# request per branch rather than a 2 GB clone.
#
# Results land in BRANCH_VERSIONS. A branch with no entry simply prints without
# a version: this is a nicety in a menu, and must never be what stops a build.
#
#   SKIP_VERSION_LOOKUP=1   do not go to the network at all
declare -A BRANCH_VERSIONS=()
declare -A BRANCH_UPDATED=()   # branch -> unix time of its tip commit
BRANCH_NEWEST=""               # space-padded list of the freshest branches
BRANCH_VERSION_LOOKUP=""       # "tried" or "skipped", so the menu can say which

prefetch_branch_versions() {
    local base api tmp b iso epoch newest="" pids=()

    BRANCH_VERSIONS=()
    BRANCH_UPDATED=()
    BRANCH_NEWEST=""
    BRANCH_VERSION_LOOKUP="skipped"
    [[ "${SKIP_VERSION_LOOKUP:-0}" == "1" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0
    base="$(github_raw_base "$REPO_URL")" || return 0
    api="$(github_api_base "$REPO_URL")" || return 0
    tmp="$(mktemp -d)" || return 0
    BRANCH_VERSION_LOOKUP="tried"

    # All lookups at once, so a dead network costs one timeout and not one per
    # branch. --max-time is what keeps that promise; without it a black-holed
    # connection hangs the menu until the TCP stack gives up.
    for b in "$@"; do
        ( curl -fsSL --max-time 6 "$base/$b/Makefile" 2>/dev/null \
            | parse_makefile_version > "$tmp/$b.version" ) &
        pids+=("$!")
        # The API is rate limited to 60 requests an hour for an unauthenticated
        # caller. Three per run is nowhere near that, and a run that does hit it
        # simply loses the dates: the 403 fails the curl and nothing is written.
        ( curl -fsSL --max-time 6 "$api/commits?sha=$b&per_page=1" 2>/dev/null \
            | parse_commit_date > "$tmp/$b.date" ) &
        pids+=("$!")
    done
    wait "${pids[@]}" 2>/dev/null || true

    for b in "$@"; do
        if [[ -s "$tmp/$b.version" ]]; then
            BRANCH_VERSIONS["$b"]="$(< "$tmp/$b.version")"
        fi
        [[ -s "$tmp/$b.date" ]] || continue
        iso="$(< "$tmp/$b.date")"
        # date -d on an ISO 8601 string is GNU behaviour. Everything this
        # script targets has it, and where it does not the branch just prints
        # without an age.
        epoch="$(date -d "$iso" +%s 2>/dev/null)" || continue
        [[ "$epoch" =~ ^[0-9]+$ ]] || continue
        BRANCH_UPDATED["$b"]="$epoch"
        if [[ -z "$newest" || "$epoch" -gt "$newest" ]]; then
            newest="$epoch"
        fi
    done

    # Ties are real: asahi and asahi-wip often share a tip. Marking every
    # branch that sits on the newest commit is truer than picking one.
    if [[ -n "$newest" ]]; then
        for b in "$@"; do
            [[ "${BRANCH_UPDATED[$b]:-}" == "$newest" ]] && BRANCH_NEWEST+=" $b "
        done
    fi

    rm -rf "$tmp"
    return 0
}

# "Linux 7.1.6" for the menu, or a placeholder when the lookup did not answer.
branch_version_label() {
    local b="$1"
    if [[ -n "${BRANCH_VERSIONS[$b]:-}" ]]; then
        printf 'Linux %s' "${BRANCH_VERSIONS[$b]}"
    elif [[ "$BRANCH_VERSION_LOOKUP" == "tried" ]]; then
        printf 'Linux version unavailable (could not reach GitHub)'
    else
        # No lookup was made at all: not a GitHub remote, no curl, or the
        # user turned it off. Saying "could not reach GitHub" here would send
        # someone debugging a network that was never used.
        printf 'Linux version not checked'
    fi
}

# " - updated 3 days ago (most recent)", or nothing at all when the date
# lookup came back empty. Silence is deliberate: a menu line that says
# "updated unknown" is noise next to a version that already says as much.
branch_updated_label() {
    local b="$1" age
    [[ -n "${BRANCH_UPDATED[$b]:-}" ]] || return 0
    age=$(( $(date +%s) - BRANCH_UPDATED[$b] ))
    printf ' - updated %s' "$(relative_age "$age")"
    case "$BRANCH_NEWEST" in
        *" $b "*) printf ' (most recent)' ;;
    esac
}

# --- Choose which Asahi branch to build ---
#
# Skipped entirely if BRANCH is already set in the environment.
select_branch() {
    if [[ -n "$BRANCH" ]]; then
        prefetch_branch_versions "$BRANCH"
        if [[ -n "${BRANCH_VERSIONS[$BRANCH]:-}" ]]; then
            info "BRANCH is set to '$BRANCH' (Linux ${BRANCH_VERSIONS[$BRANCH]}), not asking"
        else
            info "BRANCH is set to '$BRANCH', not asking"
        fi
        return
    fi

    info "Looking up the current kernel version on each branch ..."
    prefetch_branch_versions fairydust asahi asahi-wip

    echo ""
    echo "Which Asahi branch do you want to build?"
    echo "Versions below are read live from the branch tips, not hard-coded."
    echo ""
    echo "  1) fairydust   The main Asahi base plus experimental USB-C"
    echo "                 DisplayPort alt mode, so external displays over"
    echo "                 USB-C work."
    echo "                 $(branch_version_label fairydust)$(branch_updated_label fairydust)"
    echo ""
    echo "  2) asahi       The main Asahi branch, and what Fedora Asahi Remix"
    echo "                 builds its kernel from, without the USB-C alt mode"
    echo "                 work. Pick this if you only use the built-in HDMI"
    echo "                 port."
    echo "                 $(branch_version_label asahi)$(branch_updated_label asahi)"
    echo ""
    echo "  3) asahi-wip   Asahi's development branch. Closer to upstream, but"
    echo "                 less tested and without the USB-C alt mode work."
    echo "                 $(branch_version_label asahi-wip)$(branch_updated_label asahi-wip)"
    echo ""
    echo "  The HDMI suspend fix applies to all three: the display driver is"
    echo "  identical on each."
    echo ""

    # BORE is written against one kernel release. While the three branches sit
    # on the same version it applies to all of them; the moment one rebases
    # ahead that stops being true, and the patch is skipped rather than
    # failing the build. Say which of those two worlds we are in right now.
    # grep -c exits 1 on a count of zero, which under set -e would end the run
    # here, in a cosmetic block, on a machine that merely has no network.
    local versions_seen
    versions_seen="$(printf '%s\n' "${BRANCH_VERSIONS[@]:-}" | sort -u | grep -c . || true)"
    if [[ "$versions_seen" -gt 1 ]]; then
        warn "These branches are NOT all on the same kernel version any more."
        warn "BORE targets one release, so it may apply to some and be skipped"
        warn "on others. The patch summary at the end of the run says which."
    elif [[ "$versions_seen" == "1" ]]; then
        echo "  BORE targets a single kernel release and applies to all three"
        echo "  while they sit on the same version, as they do now."
    else
        echo "  BORE targets a single kernel release. It applies while these"
        echo "  branches share a version, and is skipped where it does not fit."
    fi
    echo ""

    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        BRANCH="fairydust"
        info "ASSUME_YES set, defaulting to: $BRANCH"
        return
    fi

    local choice
    if ! read -rp "$(echo -e "${YELLOW}Branch [1/2/3, default 1]:${NC} ")" choice; then
        error "No input available (stdin closed). Re-run attached to a terminal,
or set BRANCH=fairydust (or asahi / asahi-wip) to choose without prompting."
    fi
    case "$choice" in
        2) BRANCH="asahi" ;;
        3) BRANCH="asahi-wip" ;;
        *) BRANCH="fairydust" ;;
    esac
    ok "Building branch: $BRANCH"
}

# --- Read the kernel version out of the Makefile at some revision ---
#
# "7.1.5", from a revision that need not be checked out. A commit id on its own
# does not tell you whether an update is a handful of driver fixes or a rebase
# onto a whole new upstream release, and that difference decides whether the
# patches in patches/ still apply.
#
# Prints nothing if the revision has no readable Makefile, so callers can test
# for an empty string rather than getting a bare "..".
tree_version() {
    local rev="$1"
    git show "${rev}:Makefile" 2>/dev/null | parse_makefile_version
}

# --- Bring an existing checkout up to date ---
#
# Re-running this script on an existing tree used to rebuild the exact same
# source, which is surprising if you ran it again expecting to pick up
# upstream changes. Fetch, compare against the branch tip, and offer to move.
#
# The comparison is HEAD's commit id against the fetched tip, NOT a count of
# how many commits we are behind. Asahi rebases and force-pushes fairydust,
# asahi and asahi-wip regularly, and after a force-push that rewinds the branch
# there are zero commits in HEAD..FETCH_HEAD while the tree is still not what
# upstream is publishing. A count-based check calls that "up to date" and
# quietly builds the old source; comparing ids catches it.
#
# The tree is normally dirty at this point, because the previous run applied
# patches to it without committing them. Those are regenerated from patches/
# on every run, so discarding them is safe, but anything else the user put
# there is not, hence the prompt.
#
#   UPDATE_SOURCE=0   never touch the existing tree
update_source() {
    local local_sha remote_sha counts ahead behind local_ver remote_ver

    if [[ "${UPDATE_SOURCE:-1}" != "1" ]]; then
        info "UPDATE_SOURCE=0, leaving the existing tree alone"
        info "HEAD: $(git log --oneline -1)"
        return
    fi

    info "Checking $CLONE_DIR against origin/$BRANCH ..."
    if ! git fetch origin "$BRANCH" 2>&1 | tee -a "$LOG_FILE"; then
        # The checkout's own remote, not $REPO_URL: an existing tree may have
        # been cloned from somewhere else, and naming the wrong URL sends
        # people looking for a network problem that is not there.
        warn "Could not fetch $BRANCH from $(git remote get-url origin 2>/dev/null || echo origin). Check your network."
        warn "Building the tree as it stands, which may be out of date:"
        warn "  $(git log --oneline -1)"
        return
    fi

    local_sha="$(git rev-parse HEAD)"
    remote_sha="$(git rev-parse FETCH_HEAD)"

    if [[ "$local_sha" == "$remote_sha" ]]; then
        local_ver="$(tree_version HEAD)"
        ok "Up to date with origin/$BRANCH${local_ver:+ (Linux $local_ver)}"
        info "HEAD: $(git log --oneline -1)"
        return
    fi

    # --left-right --count on a three-dot range gives "<ahead> <behind>":
    # commits reachable from HEAD only, then from FETCH_HEAD only.
    counts="$(git rev-list --left-right --count "HEAD...FETCH_HEAD" 2>/dev/null || echo "0 0")"
    ahead="${counts%%[[:space:]]*}"
    behind="${counts##*[[:space:]]}"

    echo ""
    if [[ "$ahead" == "0" ]]; then
        info "$behind new commit(s) on origin/$BRANCH:"
    else
        # Either upstream rebased the branch out from under this checkout, or
        # someone committed locally. Both need a hard reset, not a merge.
        warn "This checkout has diverged from origin/$BRANCH:"
        warn "  $ahead commit(s) here that upstream does not have"
        warn "  $behind commit(s) upstream that this tree does not have"
        warn "Asahi force-pushes these branches, so this is usually a rebase."
    fi
    # Empty on a pure rewind, where upstream has nothing this tree lacks. Show
    # the tip instead, so the branch is always identified by something.
    if [[ "$behind" == "0" ]]; then
        info "origin/$BRANCH is now at: $(git log --oneline -1 FETCH_HEAD)"
    else
        [[ "$ahead" == "0" ]] || info "Newest upstream commits:"
        git log --oneline --max-count=10 "HEAD..FETCH_HEAD" | tee -a "$LOG_FILE"
    fi

    local_ver="$(tree_version HEAD)"
    remote_ver="$(tree_version FETCH_HEAD)"
    if [[ -n "$local_ver" && -n "$remote_ver" && "$local_ver" != "$remote_ver" ]]; then
        echo ""
        warn "Upstream moved from Linux $local_ver to $remote_ver."
        warn "Patches in patches/ that no longer apply are reported and skipped,"
        warn "so check the patch summary before trusting this build."
    fi
    echo ""

    if ! git diff --quiet || ! git diff --cached --quiet; then
        warn "Updating resets $CLONE_DIR, discarding uncommitted changes there."
        warn "Patches from patches/ are reapplied afterwards, so those are fine."
    fi

    if ! confirm "Update the source tree to origin/$BRANCH?"; then
        warn "Keeping the current source. This build will NOT include the"
        warn "commits listed above."
        return
    fi

    git reset --hard FETCH_HEAD 2>&1 | tee -a "$LOG_FILE"
    git clean -fd 2>&1 | tee -a "$LOG_FILE"
    ok "Updated to $(git log --oneline -1)"
}

# --- Step 2: Clone Fairydust Branch ---
clone_source() {
    echo ""
    info "=== Step 2/8: Cloning fairydust kernel source ==="

    if [[ -d "$CLONE_DIR/.git" ]]; then
        info "Using existing source tree at $CLONE_DIR"
        cd "$CLONE_DIR"
        # Make sure we are actually on the branch we intend to build.
        if [[ "$(git branch --show-current)" != "$BRANCH" ]]; then
            info "Switching to $BRANCH"
            # The clone is --single-branch, so a branch chosen on a later run
            # has no local ref yet and a bare checkout fails with a pathspec
            # error. Fetch it explicitly first.
            if ! git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
                info "Fetching $BRANCH (not in this checkout yet)"
                git fetch origin "$BRANCH:$BRANCH" 2>&1 | tee -a "$LOG_FILE" \
                    || error "Could not fetch branch '$BRANCH' from $REPO_URL."
            fi
            # Patches from a previous run are uncommitted, and would collide
            # with the new branch.
            git checkout -- . 2>/dev/null || true
            git checkout "$BRANCH" 2>&1 | tee -a "$LOG_FILE"
        fi
        update_source
        ok "Branch: $(git branch --show-current)"
        info "HEAD:   $(git log --oneline -1)"
        return
    fi

    # --filter=blob:none skips historical file contents but still fetches every
    # commit and tree Linux has ever had, so this is a ~2 GB download that runs
    # for several minutes with nothing else on screen. Say so before starting.
    #
    # --progress is required, not cosmetic: the pipe into tee means git's
    # stderr is not a terminal, so git silently drops its progress meter and
    # the clone looks hung for the whole run.
    info "Cloning $BRANCH. Roughly 2 GB and several minutes; ~4 GB on disk"
    info "once the working tree is checked out."
    git clone "$REPO_URL" --branch "$BRANCH" --single-branch \
        --filter=blob:none --progress "$CLONE_DIR" 2>&1 | tee -a "$LOG_FILE"

    cd "$CLONE_DIR"
    ok "Source cloned to $CLONE_DIR"
    info "Branch: $(git branch --show-current)"
    info "HEAD:   $(git log --oneline -1)"
}

# --- Read a patch's human-readable metadata ---
#
# Patches carry X-Summary and X-Who-Needs-It headers ahead of the diff, which
# patch(1) and git apply both ignore. Falls back to the git Subject, then the
# filename, so an unannotated patch dropped into patches/ still works.
patch_summary() {
    local p="$1" v
    v="$(sed -n 's/^X-Summary: //p' "$p" | head -1)"
    [[ -z "$v" ]] && v="$(sed -n 's/^Subject: \[PATCH[^]]*\] //p' "$p" | head -1)"
    [[ -z "$v" ]] && v="$(basename "$p")"
    printf '%s' "$v"
}

patch_audience() {
    sed -n 's/^X-Who-Needs-It: //p' "$1" | head -1
}

# --- Apply local patches on top of the branch ---
#
# Anything in patches/*.patch is offered in filename order, one prompt each,
# defaulting to yes. Patches already present in the tree are skipped without
# asking, so re-running against an existing checkout is safe.
#
#   SKIP_PATCHES=1        apply nothing
#   PATCHES="0001,bore"   apply only patches whose filename contains one of
#                         these, without prompting
#   ASSUME_YES=1          apply everything without prompting
apply_patches() {
    local patch_dir
    patch_dir="$SCRIPT_DIR/patches"
    APPLIED_PATCHES=()
    SKIPPED_PATCHES=()

    if [[ "${SKIP_PATCHES:-0}" == "1" ]]; then
        info "SKIP_PATCHES is set, building the branch as-is"
        return
    fi

    if [[ ! -d "$patch_dir" ]] || ! compgen -G "$patch_dir/*.patch" >/dev/null; then
        info "No patches to apply"
        return
    fi

    cd "$CLONE_DIR" || error "Source tree missing at $CLONE_DIR"

    echo ""
    info "Patches available in $patch_dir"

    local p name subject audience wanted want explicitly_requested
    for p in "$patch_dir"/*.patch; do
        name="$(basename "$p")"

        # The Subject: line of a git format-patch file is a ready-made
        # one-line description, so patches are self-describing.
        subject="$(patch_summary "$p")"
        audience="$(patch_audience "$p")"

        # Already applied, e.g. re-running against an existing checkout, or
        # building a branch that already carries the change as a commit.
        if git apply --reverse --check "$p" 2>/dev/null; then
            info "Already in $BRANCH, nothing to do: $subject"
            APPLIED_PATCHES+=("$subject (already present)")
            continue
        fi

        # Whether the user asked for this one by name changes how loud we are
        # about it not applying.
        explicitly_requested=0
        if [[ -n "${PATCHES:-}" ]]; then
            for want in ${PATCHES//,/ }; do
                [[ "${name,,}" == *"${want,,}"* ]] && explicitly_requested=1
            done
        fi

        if ! git apply --check "$p" 2>/dev/null; then
            # Not applicable to this branch is a normal, expected outcome, not
            # a problem. Only make noise if it was specifically asked for.
            if [[ "$explicitly_requested" -eq 1 ]]; then
                error "You asked for $name via PATCHES, but it does not apply to $BRANCH.
It probably targets a different kernel version. Drop it from PATCHES, or
choose a branch it fits."
            fi
            info "Not applicable to $BRANCH, skipping: $subject"
            SKIPPED_PATCHES+=("$subject (does not apply to $BRANCH)")
            continue
        fi

        # PATCHES=... selects non-interactively by filename substring.
        if [[ -n "${PATCHES:-}" ]]; then
            wanted=0
            local want
            # Case-insensitive: filenames contain things like "BORE", and
            # nobody should have to guess the capitalisation.
            for want in ${PATCHES//,/ }; do
                [[ "${name,,}" == *"${want,,}"* ]] && wanted=1
            done
            if [[ "$wanted" -eq 0 ]]; then
                info "Not selected by PATCHES, skipping: $subject"
                continue
            fi
        else
            echo ""
            [[ -n "$audience" ]] && echo "    $audience"
            if ! confirm_default_yes "Apply: $subject"; then
                info "Skipped: $name"
                SKIPPED_PATCHES+=("$subject (declined)")
                continue
            fi
        fi

        git apply --whitespace=nowarn "$p" 2>&1 | tee -a "$LOG_FILE"
        APPLIED_PATCHES+=("$subject")
        ok "Applied: $subject"
    done

    echo ""
    if [[ ${#APPLIED_PATCHES[@]} -eq 0 ]]; then
        if [[ "${SKIP_PATCHES:-0}" == "1" ]]; then
            info "SKIP_PATCHES is set: building $BRANCH unmodified."
            return
        fi
        # Two hours of compiling to produce a kernel identical to the one the
        # distro ships is never what someone wanted.
        error "No patches were applied, so this build would be identical to the
stock $BRANCH kernel. Nothing here would be fixed.
$(printf '  - %s\n' "${SKIPPED_PATCHES[@]}")
Choose a different branch, or re-run with SKIP_PATCHES=1 if you genuinely
want an unmodified build."
    fi

    info "Patches applied to this build:"
    printf '    - %s\n' "${APPLIED_PATCHES[@]}"
    if [[ ${#SKIPPED_PATCHES[@]} -gt 0 ]]; then
        info "Not applied:"
        printf '    - %s\n' "${SKIPPED_PATCHES[@]}"
    fi
}

# --- Step 3: Configure Kernel ---
configure_kernel() {
    echo ""
    info "=== Step 3/8: Configuring kernel ==="

    cd "$CLONE_DIR"

    # Start from the distro kernel config.
    #
    # The running kernel's own config is the obvious source, but `make install`
    # does not write /boot/config-<kver>, so a kernel this script built has
    # none. That made every rebuild-from-a-built-kernel dead-end here, which is
    # the normal case once someone is using the thing. Fall back to the newest
    # distro config still in /boot, which is what the first run started from.
    local suffixes
    suffixes="$(printf '%s\n' "${LOCALVERSION#-}" fairydust rgvx hdmifix \
        | sort -u | paste -sd'|')"

    CURRENT_CONFIG="/boot/config-$(uname -r)"
    if [[ ! -f "$CURRENT_CONFIG" ]]; then
        info "No config for the running kernel at $CURRENT_CONFIG"
        info "That is expected on a kernel this script built."

        # Prefer a distro config for the same kernel version as the source
        # tree. Which baseline gets picked decides which symbols exist at all:
        # a symbol absent from the baseline is never offered by olddefconfig,
        # it just silently stays off. CONFIG_MACSMC_POWER was lost exactly this
        # way, building 7.1.5 from a 7.0.13 baseline that predates the symbol.
        local srcver
        srcver="$(make -s kernelversion 2>/dev/null)"
        if [[ -n "$srcver" ]]; then
            # || true is required: under set -eo pipefail, grep finding
            # nothing (no distro config for this version) fails the pipeline
            # and set -e kills the script here with no message at all.
            CURRENT_CONFIG="$(ls -1v /boot/config-"$srcver"-* 2>/dev/null \
                | grep -Ev "$suffixes" | tail -1 || true)"
            [[ -n "$CURRENT_CONFIG" ]] \
                && info "Matched a distro config for $srcver"
        fi

        # Nothing for this version. Fall back to the newest distro config there
        # is, and say so, because it may well be missing symbols this kernel
        # has. -v sorts by version, so the tail is the newest. Our own builds
        # are excluded: those are derived configs, not a distro baseline.
        if [[ -z "$CURRENT_CONFIG" ]]; then
            CURRENT_CONFIG="$(ls -1v /boot/config-* 2>/dev/null \
                | grep -Ev "$suffixes" | tail -1 || true)"
            [[ -n "$CURRENT_CONFIG" ]] && warn \
                "No distro config for $srcver. Using $(basename "$CURRENT_CONFIG"),
which may predate options this kernel has. Symbols it does not know about
default to off."
        fi
    fi

    if [[ -z "$CURRENT_CONFIG" || ! -f "$CURRENT_CONFIG" ]]; then
        error "No distro kernel config found in /boot.
Expected /boot/config-\$(uname -r), or a distro kernel's config to fall back
to. Install a stock kernel package, or copy a config to the source tree as
$CLONE_DIR/.config and re-run."
    fi

    cp "$CURRENT_CONFIG" .config
    info "Copied config from $CURRENT_CONFIG"

    # Accept defaults for new options
    make olddefconfig 2>&1 | tee -a "$LOG_FILE"

    # Verify Rust is available to the build system
    info "Checking Rust availability..."

    # Try to find and export RUST_LIB_SRC if not already set
    if [[ -z "$RUST_LIB_SRC" ]]; then
        for candidate in \
            /usr/lib/rustlib/src/rust/library \
            "$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/lib/rustlib/src/rust/library" \
            $(find /usr/lib/rustlib -name "library" -type d 2>/dev/null | head -1); do
            if [[ -d "$candidate" ]]; then
                export RUST_LIB_SRC="$candidate"
                info "Rust library source: $RUST_LIB_SRC"
                break
            fi
        done
    fi

    if make rustavailable 2>&1 | tee -a "$LOG_FILE"; then
        ok "Rust is available"
    else
        error "Rust is not available to the kernel build system.
Please ensure rust, rust-std-static, rust-src, and bindgen-cli are installed.
Run: make rustavailable   for details.
See Documentation/rust/quick-start.rst in the kernel source."
    fi

    # Enable Rust support
    scripts/config --enable RUST

    # Enable Asahi GPU driver and dependencies
    scripts/config --module DRM_ASAHI
    scripts/config --enable RUST_FW_LOADER_ABSTRACTIONS
    scripts/config --enable RUST_DRM_SCHED
    scripts/config --enable RUST_DRM_GEM_SHMEM_HELPER
    scripts/config --enable RUST_DRM_GPUVM
    scripts/config --enable RUST_APPLE_MAILBOX
    scripts/config --enable RUST_APPLE_RTKIT

    # Enable DP Alt Mode support
    scripts/config --module TYPEC_DP_ALTMODE
    scripts/config --module TYPEC_NVIDIA_ALTMODE
    scripts/config --module TYPEC_TBT_ALTMODE

    # Ensure Apple DRM is enabled
    scripts/config --module DRM_APPLE

    # Battery and AC power supply. Fedora Asahi 7.1.5+ ships this as =m, but
    # older /boot/config-* baselines do not have the symbol at all, so
    # olddefconfig silently leaves it off and the machine boots with no
    # battery: no /sys/class/power_supply/macsmc-battery, no upower device,
    # and Plasma reporting no battery present. Set it explicitly.
    # The symbol is MACSMC_POWER (drivers/power/supply/macsmc_power.c), not
    # BATTERY_MACSMC. Depends on MFD_MACSMC, already =m.
    scripts/config --module MACSMC_POWER

    # --- Local tuning ---------------------------------------------------
    # Most of what CachyOS enables (HZ_1000, NO_HZ_FULL, PREEMPT_DYNAMIC,
    # LRU_GEN, THP, SCHED_CLASS_EXT) is already on in the Fedora Asahi config,
    # and its x86 march tuning does not apply to aarch64. These are the deltas
    # that are actually worth setting here.

    # Defer RCU callbacks while idle. Meaningful battery win on a laptop.
    # Requires RCU_NOCB_CPU, which the Fedora Asahi config already sets.
    scripts/config --enable RCU_LAZY

    # BORE comes from a source patch on the kernel branch. It defaults to y,
    # but set it explicitly so a config regression is loud rather than silent.
    # Runtime-tunable via /proc/sys/kernel/sched_bore, so it can be turned off
    # without rebuilding if it misbehaves.
    scripts/config --enable SCHED_BORE

    # Set local version tag
    sed -i "s/CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"${LOCALVERSION}\"/" .config

    # Fix known build-breakers
    scripts/config --set-str EFI_SBAT_FILE ""
    scripts/config --disable QRTR_MHI

    # Disable module signing (Fedora config enables this but signing key
    # doesn't exist in our build, causing modules_install to fail)
    scripts/config --disable MODULE_SIG
    scripts/config --disable MODULE_SIG_ALL
    scripts/config --disable MODULE_SIG_FORCE
    scripts/config --set-str MODULE_SIG_KEY ""
    scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
    scripts/config --set-str SYSTEM_REVOCATION_KEYS ""

    # Finalize config
    make olddefconfig 2>&1 | tee -a "$LOG_FILE"

    # Verify critical options
    echo ""
    info "Verifying critical config options:"
    # A symbol the baseline config never had is not offered by olddefconfig,
    # it is simply left off, so setting it above is not proof it survived.
    # Everything here has been silently lost at least once.
    for opt in CONFIG_RUST CONFIG_DRM_ASAHI CONFIG_DRM_APPLE \
               CONFIG_TYPEC_DP_ALTMODE CONFIG_RUST_APPLE_RTKIT \
               CONFIG_MACSMC_POWER CONFIG_SCHED_BORE; do
        val=$(grep "^${opt}=" .config 2>/dev/null || echo "NOT SET")
        if [[ "$val" == "NOT SET" ]]; then
            error "$opt is not set in .config. Build will be incomplete."
        else
            ok "  $val"
        fi
    done
    echo ""
}

# --- Step 4: Build Kernel ---
build_kernel() {
    echo ""
    info "=== Step 4/8: Building kernel (this will take a while) ==="
    info "Using $JOBS parallel jobs"
    info "Started at: $(date)"

    cd "$CLONE_DIR"

    log_and_run make -j$JOBS

    ok "Kernel build completed at: $(date)"
}

# --- Step 5: Install Kernel ---
install_kernel() {
    echo ""
    info "=== Step 5/8: Installing kernel ==="

    cd "$CLONE_DIR"

    KVER=$(make kernelrelease)
    info "Kernel version: $KVER"

    # Install modules, DTBs, VDSO
    info "Installing modules..."
    log_and_run sudo make INSTALL_MOD_STRIP=1 modules_install

    # The config said =m, but only the installed tree proves the module was
    # actually built and landed. Without this one the machine boots with no
    # battery at all, which is easy to miss until you unplug the charger.
    if ! compgen -G "/usr/lib/modules/$KVER/kernel/drivers/power/supply/macsmc-power.ko*" >/dev/null; then
        error "macsmc-power.ko is missing from /usr/lib/modules/$KVER.
That module provides macsmc-battery and macsmc-ac. Without it the system
reports no battery. CONFIG_MACSMC_POWER passed the config check, so this is
a build or install failure rather than a config one."
    fi
    ok "macsmc-power.ko installed (battery and AC)"

    info "Installing DTBs..."
    log_and_run sudo make dtbs_install

    info "Installing VDSO..."
    log_and_run sudo make vdso_install

    # Create DTB symlink that Fedora expects
    sudo ln -sf "/boot/dtbs/$KVER" "/usr/lib/modules/$KVER/dtb"

    # Install kernel image
    info "Installing kernel image..."
    log_and_run sudo make install

    ok "Kernel installed: $KVER"
}

# --- Step 6: Update m1n1 Bootloader ---
update_m1n1() {
    echo ""
    info "=== Step 6/8: Updating m1n1 bootloader ==="

    cd "$CLONE_DIR"

    sudo ln -sfn "$PWD" /usr/src/linux

    if sudo update-m1n1 2>&1 | tee -a "$LOG_FILE"; then
        ok "m1n1 updated"
    else
        error "Failed to update m1n1. Check $LOG_FILE for details."
    fi
}

# --- Step 7: Update GRUB ---
update_grub() {
    echo ""
    info "=== Step 7/8: Updating GRUB ==="

    sudo sed -i 's/GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' /etc/default/grub
    sudo sed -i 's/GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
    sudo grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 | tee -a "$LOG_FILE"

    ok "GRUB updated (5-second menu timeout)"

    offer_default_kernel
}

# --- Boot the kernel we just built by default? ---
#
# Asked rather than assumed, and defaulting to no. A kernel that has never been
# booted is exactly the wrong thing to make the automatic choice on a machine
# whose owner may not be in front of it next time it starts. Saying yes is a
# fair choice too, which is why it is offered at all: the GRUB menu is set to a
# 5-second timeout just above, so a kernel that does not boot is one reboot and
# one menu selection away from being escaped.
#
#   SET_DEFAULT=1   boot the new kernel by default, without asking
#   SET_DEFAULT=0   leave the default alone, without asking
offer_default_kernel() {
    local kver current

    command -v grubby >/dev/null 2>&1 || return 0
    kver="$(cd "$CLONE_DIR" && make -s kernelrelease 2>/dev/null)" || return 0
    [[ -n "$kver" && -e "/boot/vmlinuz-$kver" ]] || return 0

    current="$(sudo grubby --default-kernel 2>/dev/null || true)"
    current="${current##*/vmlinuz-}"
    [[ "$current" == /* ]] && current=""

    if [[ "$current" == "$kver" ]]; then
        info "GRUB already boots $kver by default"
        return 0
    fi

    echo ""
    echo "  GRUB currently boots ${current:-your existing kernel} by default."
    echo "  The kernel just built is $kver."
    echo ""
    echo "  If you make it the default and it does not boot, hold or press a"
    echo "  key at startup to get the GRUB menu, then pick ${current:-your previous kernel}."
    echo "  Nothing about your existing kernels has been changed, so they are"
    echo "  all still there to fall back on."
    echo ""

    case "${SET_DEFAULT:-}" in
        1) info "SET_DEFAULT=1, making $kver the boot default" ;;
        0) info "SET_DEFAULT=0, leaving the boot default alone"; return 0 ;;
        *)
            # ASSUME_YES answers this one as no. It exists so a long build can
            # run unattended, and that is the case where nobody is watching to
            # rescue a machine that does not come back up.
            if [[ "${ASSUME_YES:-0}" == "1" ]]; then
                info "Leaving the boot default alone: ASSUME_YES does not change it."
                info "Pass SET_DEFAULT=1 to boot the new kernel by default."
                return 0
            fi
            if ! confirm "Make $kver the default kernel in GRUB?"; then
                info "Boot default left at ${current:-its current setting}."
                info "Select the new kernel from the GRUB menu at boot."
                return 0
            fi
            ;;
    esac

    if ! sudo grubby --set-default="/boot/vmlinuz-$kver" >/dev/null 2>&1; then
        warn "Could not set the boot default. Pick $kver from the GRUB menu."
        return 0
    fi

    # Read it back: grubby writes through to /boot/grub2/grubenv on a
    # GRUB_DEFAULT=saved system, and a write that did not take would otherwise
    # be reported here as a success.
    local now
    now="$(sudo grubby --default-kernel 2>/dev/null || true)"
    now="${now##*/vmlinuz-}"
    if [[ "$now" == "$kver" ]]; then
        DEFAULT_KERNEL_SET="$kver"
        FALLBACK_KERNEL="$current"
        ok "GRUB will boot $kver by default"
    else
        warn "Asked GRUB to boot $kver by default, but it still reports"
        warn "${now:-nothing}. Pick the kernel from the GRUB menu instead."
    fi
}

# --- Step 8: Setup Typec Module Autoloading ---
setup_modules() {
    echo ""
    info "=== Step 8/8: Setting up typec module autoloading ==="

    echo -e "typec_displayport\ntypec_nvidia\ntypec_thunderbolt" | \
        sudo tee /etc/modules-load.d/fairydust-typec.conf > /dev/null

    ok "Typec modules will auto-load on boot"
}


# --- Summary ---
print_summary() {
    KVER=$(cd "$CLONE_DIR" && make kernelrelease)
    echo ""
    echo "============================================================"
    echo -e "  ${GREEN}BUILD COMPLETE!${NC}"
    echo "============================================================"
    echo ""
    echo "  Kernel version:   $KVER"
    echo "  Branch built:     $BRANCH"
    echo "  Source commit:    $(cd "$CLONE_DIR" && git log --oneline -1)"
    echo "  Source tree:      $CLONE_DIR"
    echo "  Build log:        $LOG_FILE"
    echo ""
    if [[ ${#APPLIED_PATCHES[@]} -gt 0 ]]; then
        echo "  Patches in this kernel:"
        printf '    - %s\n' "${APPLIED_PATCHES[@]}"
        echo ""
    fi
    echo "  NEXT STEPS:"
    if [[ -n "${DEFAULT_KERNEL_SET:-}" ]]; then
        echo "  1. Reboot:  sudo reboot"
        echo "  2. Nothing to pick: GRUB boots $DEFAULT_KERNEL_SET by default now."
        echo ""
        echo "  IF IT DOES NOT BOOT:"
        echo "    Press or hold a key at startup to get the GRUB menu, then"
        if [[ -n "${FALLBACK_KERNEL:-}" ]]; then
            echo "    select $FALLBACK_KERNEL, which is what booted before this build."
        else
            echo "    select one of your other kernels — they are all untouched."
        fi
        echo "    From there, re-run this script or the uninstaller to undo it."
    else
        echo "  1. Reboot:  sudo reboot"
        echo "  2. In the GRUB menu, select the kernel with '${LOCALVERSION}'"
        echo ""
        echo "  GRUB still boots your existing kernel by default, so a kernel"
        echo "  that misbehaves costs you nothing but the menu selection."
    fi
    echo ""
    echo "  VERIFY AFTER BOOT:"
    echo "    uname -r                                   # should contain ${LOCALVERSION}"
    echo "    glxinfo | grep 'OpenGL renderer'           # your GPU, NOT llvmpipe"
    echo "    cat /sys/class/drm/card*-HDMI-A-1/status   # before and after a suspend"
    echo ""
    echo "  The HDMI fix is the one to test: suspend with a monitor plugged"
    echo "  into the built-in HDMI port, wake, and it should return without"
    echo "  unplugging the cable."
    echo ""
    echo "  TO REVERT:"
    echo "    Reboot and select your original kernel in GRUB."
    echo "    The original kernel is untouched."
    echo ""
    echo "============================================================"
    echo ""

    # ASSUME_YES deliberately does NOT reboot. It exists so a long build can run
    # unattended, and answering "yes" to every prompt should not be the same as
    # asking for the machine to restart while nobody is watching.
    if [[ "${NO_REBOOT:-0}" == "1" || "${ASSUME_YES:-0}" == "1" ]]; then
        info "Not rebooting automatically. Reboot when ready with: sudo reboot"
    elif confirm "Reboot now?"; then
        sudo reboot
    else
        info "Reboot when ready with: sudo reboot"
    fi
}

# --- Regenerate the fairydust delta against the tag the PKGBUILD pins ---
#
# patches/0003 is a snapshot of asahi-<ver>...fairydust taken when it was
# generated. Two things make a snapshot go stale: upstream adding commits to
# fairydust, and the distro bumping its kernel tag. Both are normal, and either
# leaves users with an out-of-date or non-applying patch.
#
# So when building on ALARM, recompute the range against whatever tag the
# PKGBUILD actually pins, and fall back to the shipped snapshot if that is not
# possible (no network, GitHub unreachable, unexpected PKGBUILD layout).
#
# Sets FAIRYDUST_PATCH to the file to use.
refresh_fairydust_patch() {
    local shipped="$1" tag url tmp
    FAIRYDUST_PATCH="$shipped"

    if [[ "${FAIRYDUST_REFRESH:-1}" != "1" ]]; then
        info "FAIRYDUST_REFRESH=0, using the shipped snapshot"
        return
    fi

    # --printsrcinfo expands the PKGBUILD's own variables, so this tracks the
    # tag correctly even when the version scheme changes.
    # || true is required: under set -eo pipefail a non-matching grep makes the
    # whole assignment non-zero and aborts the script, which would make the
    # fallback immediately below this unreachable.
    tag="$(makepkg --printsrcinfo 2>/dev/null \
        | grep -oE 'archive/[^[:space:]]+\.tar\.gz' \
        | head -1 | sed 's|archive/||; s|\.tar\.gz$||' || true)"

    if [[ -z "$tag" ]]; then
        warn "Could not determine the kernel tag from the PKGBUILD."
        warn "Using the shipped snapshot, which may not apply."
        return
    fi

    info "PKGBUILD builds tag: $tag"
    url="https://github.com/AsahiLinux/linux/compare/${tag}...fairydust.diff"
    tmp="$(mktemp)"

    if ! curl -fsSL "$url" -o "$tmp" || [[ ! -s "$tmp" ]]; then
        warn "Could not fetch $url"
        warn "Using the shipped snapshot instead."
        rm -f "$tmp"
        return
    fi

    # Non-empty is not the same as usable: an error page or an empty range would
    # both pass the test above.
    if ! grep -q '^diff --git' "$tmp"; then
        warn "Response from GitHub contained no diff hunks."
        warn "Using the shipped snapshot instead."
        rm -f "$tmp"
        return
    fi

    # Written to a temp file, not into the package directory, because this runs
    # before the user has agreed to apply it.
    local out
    out="$(mktemp)"
    { sed -n '1,/^---$/p' "$shipped"; cat "$tmp"; } > "$out"
    rm -f "$tmp"

    # The user is about to consent to applying this. If it is not the file
    # shipped in patches/ then say so plainly, because someone who reviewed the
    # repo before running is otherwise consenting to bytes they never saw.
    if cmp -s "$shipped" "$out"; then
        ok "Upstream matches the snapshot in patches/ exactly ($tag)"
        rm -f "$out"
        return
    fi

    warn "Upstream fairydust has moved since the snapshot in patches/ was taken."
    echo ""
    echo "    shipped snapshot: $(grep -c '^diff --git' "$shipped") files, $(grep -c '^+[^+]' "$shipped") added lines"
    echo "    freshly fetched:  $(grep -c '^diff --git' "$out") files, $(grep -c '^+[^+]' "$out") added lines"
    echo "    source: $url"
    echo ""
    warn "The freshly fetched diff has not been reviewed by anyone here."
    if ! confirm "Use the freshly fetched version instead of the reviewed snapshot?"; then
        info "Using the reviewed snapshot from patches/ instead."
        rm -f "$out"
        return
    fi

    ok "Using the freshly fetched delta for $tag"
    FAIRYDUST_PATCH="$out"
}

# --- Asahi ALARM (Arch) path ---
#
# ALARM does not need this script to build a kernel. Its linux-asahi PKGBUILD
# already loops over source entries ending in .patch and applies them with
# patch -Np1, so the whole job is: drop the patches in, register them, rebuild.
#
# This path therefore skips branch selection, config seeding, m1n1 and GRUB
# entirely. The PKGBUILD pins its own upstream tag and Arch's packaging handles
# the install, which is more reliable than anything reimplemented here.
alarm_build() {
    local patch_dir pkgdir chosen p name subject audience want wanted staged_src

    patch_dir="$SCRIPT_DIR/patches"
    pkgdir="${ALARM_PKGBUILDS_DIR:-$HOME/PKGBUILDs}"

    echo ""
    info "=== Asahi ALARM build (via linux-asahi PKGBUILD) ==="
    warn "The patch itself is verified against ALARM's kernel tag, but the"
    warn "makepkg and install steps have not been tested on ALARM. Your"
    warn "existing kernel package stays installed until makepkg succeeds."
    echo ""

    if [[ $EUID -eq 0 ]]; then
        error "makepkg refuses to run as root. Run as your normal user."
    fi

    info "=== Step 1/5: dependencies ==="
    # pacman-contrib provides updpkgsums, which regenerates the checksum arrays
    # after adding a source entry.
    sudo pacman -S --needed --noconfirm base-devel git pacman-contrib

    info "=== Step 2/5: linux-asahi PKGBUILD ==="
    if [[ -d "$pkgdir/.git" ]]; then
        # Discard our own edits from a previous run BEFORE pulling. A previous
        # run leaves PKGBUILD modified, and a kernel bump upstream touches the
        # same file, so pull --ff-only would refuse and abort the script.
        info "Discarding local changes from any previous run in $pkgdir"
        git -C "$pkgdir" checkout -- . 2>/dev/null || true
        git -C "$pkgdir" clean -fd 2>/dev/null || true
        info "Updating $pkgdir"
        git -C "$pkgdir" pull --ff-only 2>&1 | tee -a "$LOG_FILE"
    else
        git clone https://github.com/asahi-alarm/PKGBUILDs.git "$pkgdir" 2>&1 | tee -a "$LOG_FILE"
    fi

    cd "$pkgdir/linux-asahi" || error "linux-asahi not found in $pkgdir"

    info "=== Step 3/5: choosing patches ==="
    chosen=()
    for p in "$patch_dir"/*.patch; do
        [[ -e "$p" ]] || continue
        name="$(basename "$p")"
        subject="$(patch_summary "$p")"
        audience="$(patch_audience "$p")"

        if [[ "${SKIP_PATCHES:-0}" == "1" ]]; then
            info "SKIP_PATCHES is set, skipping: $subject"
            continue
        fi

        # Resolve what would actually be applied BEFORE asking, so the user is
        # consenting to real content rather than to a filename.
        staged_src="$p"
        if [[ "$name" == *fairydust* ]]; then
            refresh_fairydust_patch "$p"
            staged_src="$FAIRYDUST_PATCH"
        fi

        if [[ -n "${PATCHES:-}" ]]; then
            wanted=0
            for want in ${PATCHES//,/ }; do
                [[ "${name,,}" == *"${want,,}"* ]] && wanted=1
            done
            if [[ "$wanted" -eq 0 ]]; then
                info "Not selected by PATCHES: $subject"
                [[ "$staged_src" != "$p" ]] && rm -f "$staged_src"
                continue
            fi
        else
            echo ""
            [[ -n "$audience" ]] && echo "    $audience"
            if ! confirm_default_yes "Apply: $subject"; then
                info "Skipped: $name"
                [[ "$staged_src" != "$p" ]] && rm -f "$staged_src"
                continue
            fi
        fi

        # BORE needs a config symbol as well as a patch, and ALARM's config has
        # no CONFIG_SCHED_BORE. Say so rather than producing a kernel where the
        # patch is in but the feature is compiled out.
        if [[ "$name" == *BORE* ]]; then
            warn "ALARM's kernel config has no CONFIG_SCHED_BORE."
            warn "The patch will apply but BORE will not be enabled unless you"
            warn "also add CONFIG_SCHED_BORE=y to the 'config' file here."
        fi

        cp "$staged_src" "./$name"
        [[ "$staged_src" != "$p" ]] && rm -f "$staged_src"
        chosen+=("$name")
        ok "Staged: $subject"
    done

    if [[ ${#chosen[@]} -eq 0 ]]; then
        if [[ "${SKIP_PATCHES:-0}" == "1" ]]; then
            info "SKIP_PATCHES is set, so there is nothing for this script to do."
            info "Build the stock package yourself with: cd $pkgdir/linux-asahi && makepkg -si"
            return
        fi
        error "No patches selected, so this would just build the stock kernel.
Nothing to do."
    fi

    info "=== Step 4/5: registering patches in PKGBUILD ==="
    for name in "${chosen[@]}"; do
        if grep -qF "$name" PKGBUILD; then
            info "Already listed: $name"
            continue
        fi
        # Insert immediately before the closing paren of source=(). Appending
        # after the 'config' entry instead would drag its trailing comment
        # onto the new line.
        sed -i "/^source=(/,/^)/ { /^)/ i\\  $name
}" PKGBUILD
        grep -qF "$name" PKGBUILD || error "Could not add $name to the source array in PKGBUILD.
The PKGBUILD layout has probably changed. Add it to source=() by hand and re-run."
        ok "Registered: $name"
    done

    info "Refreshing checksums with updpkgsums ..."
    updpkgsums 2>&1 | tee -a "$LOG_FILE"

    echo ""
    info "PKGBUILD source array now reads:"
    sed -n '/^source=(/,/^)/p' PKGBUILD | tee -a "$LOG_FILE"
    echo ""

    info "=== Step 5/5: build and install ==="
    if ! confirm_default_yes "Run makepkg -si now? (builds and installs the kernel package)"; then
        info "Stopping here. To finish manually:"
        info "  cd $pkgdir/linux-asahi && makepkg -si"
        return
    fi

    makepkg -si 2>&1 | tee -a "$LOG_FILE"

    echo ""
    ok "Done. Reboot and verify with:"
    echo "    uname -r"
    echo "    cat /sys/class/drm/card*-HDMI-A-1/status   # before and after a suspend"
}

# --- Main ---
main() {
    preflight

    # ALARM has its own pipeline; nothing below this applies to it.
    if [[ "$DISTRO" == "alarm" ]]; then
        alarm_build
        return
    fi

    pin_fedora_rust_toolchain
    select_branch
    install_deps
    clone_source
    apply_patches
    configure_kernel
    build_kernel
    install_kernel
    update_m1n1
    update_grub
    setup_modules
    print_summary
}

main "$@"
