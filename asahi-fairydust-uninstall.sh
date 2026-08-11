#!/bin/bash
# =============================================================================
# asahi-fairydust-uninstall.sh
#
# Removes kernels built by asahi-fairydust-build.sh and, when the last one
# goes, puts m1n1 and /usr/src/linux back on the stock Fedora Asahi kernel.
# Runs from a stock kernel or from one this repo built.
#
# Kernels are chosen from a menu, so a machine carrying several builds can
# drop the old ones and keep the current one. The script refuses to run at all
# if every kernel it can see looks like one of ours.
#
# The kernel you are running IS offered when it is one of ours, marked in red,
# and behind a stricter prompt than the rest. Removing it is survivable — a
# running kernel lives in memory, not in /boot — but any module not already
# loaded stops being loadable until you reboot onto something else.
#
# A second menu offers the older STOCK kernels, which are dnf packages and are
# removed with dnf. The running kernel and the newest stock kernel are never
# offered there, so a stock kernel always survives.
#
# USAGE:
#   chmod +x asahi-fairydust-uninstall.sh
#   ./asahi-fairydust-uninstall.sh
#
# Unattended:
#   KERNELS=all ASSUME_YES=1 ./asahi-fairydust-uninstall.sh
#   KERNELS="7.1.5-hdmifix+" CLEANUP=log ./asahi-fairydust-uninstall.sh
#   KERNELS=all ALLOW_RUNNING=1 ASSUME_YES=1 ./asahi-fairydust-uninstall.sh
#   STOCK_KERNELS=old ASSUME_YES=1 ./asahi-fairydust-uninstall.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

confirm() {
    # Same contract as the build script's confirm(): ASSUME_YES makes an
    # unattended run possible, and a closed stdin is an error rather than a
    # silent "no", which would otherwise look like the uninstall ran and
    # decided against everything.
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

# A stricter confirm() for the one choice here that a reboot does not undo:
# removing the kernel the machine is running on. A bare 'y' is too easy to type
# by reflex on a list that looked routine one line earlier, so this one wants
# the whole word. ALLOW_RUNNING is the unattended opt-in, and is deliberately
# separate from ASSUME_YES: an existing ASSUME_YES invocation must not start
# removing the running kernel because this script learned how to.
confirm_running() {
    local response
    if [[ "${ALLOW_RUNNING:-0}" == "1" ]]; then
        info "$1 [ALLOW_RUNNING=1]"
        return 0
    fi
    if ! read -rp "$(echo -e "${RED}$1:${NC} ")" response; then
        error "No input available (stdin closed). Re-run attached to a terminal,
or set ALLOW_RUNNING=1 to answer this prompt automatically."
    fi
    [[ "$response" == "yes" ]]
}

# Human-readable total size of whichever of these paths exist. Used to say what
# a menu entry is actually worth removing; a size that cannot be read is worth
# no more than an empty string, never a failed run.
path_size() {
    local p existing=()
    for p in "$@"; do
        [[ -e "$p" ]] && existing+=("$p")
    done
    [[ ${#existing[@]} -gt 0 ]] || return 0
    du -shc --  "${existing[@]}" 2>/dev/null | tail -1 | awk '{print $1}' || true
}

# --- Which kernels count as ours ---
#
# LOCALVERSION is what the build script tags the kernel with, and it has changed
# over time, so match the current default plus the suffixes earlier builds used.
# Anything installed by hand with a custom LOCALVERSION can be matched by
# exporting the same value here.
#
# Matching only "fairydust" was a real bug: once the default became -hdmifix,
# this script reported that there was nothing to uninstall while a custom
# kernel was plainly installed, and the safety check below never fired.
KERNEL_SUFFIXES="${LOCALVERSION:--hdmifix} -fairydust -rgvx"
# Sanitised: this pattern drives which module directories get removed, and the
# comment above invites users to export their own LOCALVERSION, so it must not
# be able to carry regex metacharacters. '+' is stripped along with the rest:
# it is legal in a kernel name but means "one or more" in an ERE, and
# LOCALVERSION=-a+ would otherwise build the pattern 'a+', which matches any
# kernel name containing an 'a'.
KVER_PATTERN="$(printf '%s\n' $KERNEL_SUFFIXES \
    | sed 's/^-//; s/[^A-Za-z0-9_]//g' \
    | grep -v '^$' | sort -u | paste -sd'|')"
[[ -z "$KVER_PATTERN" ]] && error "No usable kernel suffix to match on."

# --- Is a kernel owned by a distribution package? ---
#
# The name pattern alone is not enough to decide what we built. Asahi ships 4k
# and 16k page-size kernels side by side, so a LOCALVERSION like -16k matches
# stock kernels, and a name match would then hand the uninstaller three stock
# kernels to delete. Package ownership is the fact that actually separates
# them: a kernel from dnf is owned by kernel-core, and a kernel this repo
# installed with `make install` is owned by nothing.
#
# Where no package manager can be queried there is nothing to fall back on but
# the name, so say so rather than pretending to a certainty we do not have.
PKG_QUERY=""
if command -v rpm >/dev/null 2>&1; then
    PKG_QUERY="rpm"
elif command -v pacman >/dev/null 2>&1; then
    PKG_QUERY="pacman"
fi

kernel_is_packaged() {
    local k="$1" p
    [[ -n "$PKG_QUERY" ]] || return 1
    for p in "/boot/vmlinuz-$k" "/usr/lib/modules/$k"; do
        [[ -e "$p" ]] || continue
        case "$PKG_QUERY" in
            rpm)    rpm -qf "$p"    >/dev/null 2>&1 && return 0 ;;
            pacman) pacman -Qo "$p" >/dev/null 2>&1 && return 0 ;;
        esac
    done
    return 1
}

echo ""
echo "============================================================"
echo "  Asahi Linux Fairydust Kernel Uninstaller"
echo "============================================================"
echo ""

RUNNING_KVER="$(uname -r)"

info "Current kernel: $RUNNING_KVER"
info "Looking for kernels matching: $KVER_PATTERN"
echo ""

# --- Find every installed kernel, ours and stock alike ---
#
# Both /usr/lib/modules and /boot/vmlinuz-* are read, and the union taken. A
# kernel half-removed by an interrupted run leaves files in one and not the
# other, and those leftovers are exactly what someone re-running this script
# needs to see rather than a report of "nothing to uninstall".
declare -a CUSTOM_KVERS=() STOCK_KVERS=() KEPT_CUSTOM=() SHIELDED_KVERS=()

# A kernel is only a removal candidate when BOTH tests agree: its name matches
# a suffix we build with, AND no package owns it. Either test on its own gets
# this wrong in a way that costs someone a bootable machine.
collect_kernels() {
    local d k seen=""
    for d in /usr/lib/modules/*/ /boot/vmlinuz-*; do
        [[ -e "$d" ]] || continue
        k="$(basename "${d%/}")"
        k="${k#vmlinuz-}"
        [[ -n "$k" ]] || continue
        # Same kernel found in both places, or a duplicate for any other
        # reason. Padding both sides keeps 7.1.5 from matching 7.1.5-hdmifix+.
        case " $seen " in *" $k "*) continue ;; esac
        seen+=" $k"

        # The running kernel gets no special treatment here. It used to be
        # forced into STOCK_KVERS, which read as a safety measure and was the
        # opposite of one: a running kernel of ours then counted towards the
        # "something we did not build survives" invariant below, and towards
        # the "no custom kernel is left" test that resets m1n1. It is classified
        # like any other kernel, and protected where protection belongs — at
        # the prompt, and in what gets pointed at once it is gone.
        if [[ ! "$k" =~ $KVER_PATTERN ]]; then
            STOCK_KVERS+=("$k")
        elif kernel_is_packaged "$k"; then
            # Name says ours, the package database says otherwise. The package
            # database wins, and this is loud rather than silent because it
            # means the pattern is too broad to be trusted.
            STOCK_KVERS+=("$k")
            SHIELDED_KVERS+=("$k")
        else
            CUSTOM_KVERS+=("$k")
        fi
    done
}
collect_kernels

# Is the kernel we are running one of ours, and therefore in the removal menu?
# Everything that treats it as dangerous keys off this.
RUNNING_IS_CUSTOM=0
case " ${CUSTOM_KVERS[*]} " in
    *" $RUNNING_KVER "*) RUNNING_IS_CUSTOM=1 ;;
esac

if [[ ${#SHIELDED_KVERS[@]} -gt 0 ]]; then
    warn "These kernels match '$KVER_PATTERN' but are owned by a package, so"
    warn "they were installed by your distribution and are NOT removable here:"
    for k in "${SHIELDED_KVERS[@]}"; do
        warn "  $k"
    done
    warn "Set LOCALVERSION to something that only matches your own builds."
    echo ""
fi

# The invariant this script exists to protect: something bootable that we did
# not build must remain. Reaching zero here means every kernel on the machine
# looks like one of ours, and the safe move is to remove nothing at all.
if [[ ${#STOCK_KVERS[@]} -eq 0 ]]; then
    error "Every installed kernel matches '$KVER_PATTERN', so removing them
would leave this machine with no kernel that we did not build.
Set LOCALVERSION to something that only matches your own builds."
fi

# Belt and braces for the case the pattern cannot cover: with no package
# manager to ask, name matching is the only evidence there is, and the user
# should know the weaker test was used.
if [[ -z "$PKG_QUERY" && ${#CUSTOM_KVERS[@]} -gt 0 ]]; then
    warn "No rpm or pacman here, so kernels were identified by name alone."
    warn "Check the list below before agreeing to remove anything."
fi

if [[ "$RUNNING_IS_CUSTOM" == "1" ]]; then
    warn "You are running one of our kernels ($RUNNING_KVER)."
    warn "It is in the list below and can be removed, but it is the one"
    warn "dangerous choice there. Everything else is routine."
    echo ""
fi

if [[ ${#CUSTOM_KVERS[@]} -eq 0 ]]; then
    info "No custom kernel found. Nothing to uninstall."
    NO_KERNELS_REMOVED=1
else
    NO_KERNELS_REMOVED=0
fi

# The kernel GRUB boots by default when nobody touches the menu. Removing it is
# allowed, but the default has to be moved somewhere real first, so it is worth
# knowing about and worth showing in the menu.
DEFAULT_KVER=""
if command -v grubby >/dev/null 2>&1; then
    DEFAULT_KVER="$(sudo grubby --default-kernel 2>/dev/null || true)"
    DEFAULT_KVER="${DEFAULT_KVER##*/vmlinuz-}"
    [[ "$DEFAULT_KVER" == /* ]] && DEFAULT_KVER=""
fi

# --- When was this kernel installed ---
#
# `make install` writes /boot/vmlinuz-<ver> at install time, so its mtime is
# when that kernel landed on this machine, which is the thing worth knowing
# when deciding which of several builds to drop. The modules directory is the
# fallback for a kernel whose /boot files have already been half removed.
kernel_install_epoch() {
    local k="$1" p e
    for p in "/boot/vmlinuz-$k" "/usr/lib/modules/$k"; do
        [[ -e "$p" ]] || continue
        e="$(stat -c %Y "$p" 2>/dev/null)" || continue
        [[ "$e" =~ ^[0-9]+$ ]] && { printf '%s' "$e"; return 0; }
    done
    return 1
}

kernel_install_date() {
    local e
    e="$(kernel_install_epoch "$1")" || return 1
    date -d "@$e" '+%Y-%m-%d' 2>/dev/null || return 1
}

# Everything on disk belonging to one kernel version. One list, used both to
# size a menu entry and to remove it, so the menu can never quote a size for
# files the removal then leaves behind.
kernel_paths() {
    local k="$1"
    printf '%s\n' \
        "/boot/vmlinuz-$k" \
        "/boot/initramfs-$k.img" \
        "/boot/System.map-$k" \
        "/boot/config-$k" \
        "/boot/symvers-$k.xz" \
        "/boot/dtb-$k" \
        "/boot/dtbs/$k" \
        "/usr/lib/modules/$k"
}

# --- Choose which of our kernels to remove ---
#
# KERNELS takes a comma or space separated list of versions, or "all", and
# skips the menu. ASSUME_YES on its own means all of them, which is what this
# script did before it had a menu.
declare -a SELECTED_KVERS=()

# The newest of our kernels by install date. Marked in the menu because "the
# one I built most recently" is how people actually think about which build to
# keep, and version numbers do not answer it: a rebuild of an older branch is
# newer on disk while sorting lower.
NEWEST_CUSTOM=""
newest_custom_kernel() {
    local k e best=""
    for k in "${CUSTOM_KVERS[@]}"; do
        e="$(kernel_install_epoch "$k")" || continue
        if [[ -z "$best" || "$e" -gt "$best" ]]; then
            best="$e"
            NEWEST_CUSTOM="$k"
        fi
    done
}
newest_custom_kernel

# --- What m1n1 and /usr/src/linux get pointed back at ---
#
# This used to be the running kernel, on the reasoning that the running kernel
# was always stock and always survived. Neither holds now, and pointing
# /boot/dtb at a kernel whose DTBs were deleted moments earlier is how m1n1
# stops booting. Stock kernels are never removable, so one of them is
# guaranteed to survive this run: prefer the running kernel when it is one of
# them, and the most recently installed otherwise.
RESTORE_KVER=""
pick_restore_kernel() {
    local k e best=""
    for k in "${STOCK_KVERS[@]}"; do
        if [[ "$k" == "$RUNNING_KVER" ]]; then
            RESTORE_KVER="$k"
            return 0
        fi
        e="$(kernel_install_epoch "$k")" || continue
        if [[ -z "$best" || "$e" -gt "$best" ]]; then
            best="$e"
            RESTORE_KVER="$k"
        fi
    done
    # Every stock kernel had an unreadable mtime. One of them still beats none.
    [[ -n "$RESTORE_KVER" ]] || RESTORE_KVER="${STOCK_KVERS[0]}"
}
pick_restore_kernel

# --- Old stock kernels ---
#
# Stock kernels are RPMs, and an RPM is not uninstalled with rm. Deleting the
# files by hand leaves the rpm database describing packages whose files are
# gone, keeps the installonly slot occupied so dnf still refuses to fetch a new
# kernel, and skips the kernel-install and bootloader hooks. So every removal
# here is handed to dnf, which does all of that properly.
#
# Two kernels are never offered, and between them they are what makes "a stock
# kernel survives" true by construction rather than by a check that could be
# answered wrongly: the one running now, and RESTORE_KVER, which is what m1n1,
# /usr/src/linux and the GRUB fallback get pointed at.
declare -a STOCK_CANDIDATES=() STOCK_PKGS=() SELECTED_STOCK=() REMOVED_STOCK=()

# The package that owns a kernel's vmlinuz, as a full NEVRA. On Fedora Asahi
# that is kernel-16k-core, not kernel-core, and on a 4k install it is something
# else again — so it is read off the file rather than assumed. dnf pulls in the
# matching -modules, -modules-core and -modules-extra by dependency.
stock_kernel_package() {
    local p
    p="$(rpm -qf --qf '%{NAME}-%{EVR}.%{ARCH}\n' "/boot/vmlinuz-$1" 2>/dev/null \
        | head -1)"
    [[ -n "$p" ]] || return 1
    printf '%s' "$p"
}

collect_stock_candidates() {
    local k pkg
    # rpm identifies them and dnf removes them; without both, this whole
    # section stays out of the way. pacman has no installonly kernels to offer.
    [[ "$PKG_QUERY" == "rpm" ]] || return 0
    command -v dnf >/dev/null 2>&1 || return 0
    for k in "${STOCK_KVERS[@]}"; do
        [[ "$k" == "$RUNNING_KVER" ]] && continue
        [[ "$k" == "$RESTORE_KVER" ]] && continue
        pkg="$(stock_kernel_package "$k")" || continue
        STOCK_CANDIDATES+=("$k")
        STOCK_PKGS+=("$pkg")
    done
}
collect_stock_candidates

kernel_menu_line() {
    local i="$1" k="$2" size date notes=() running=0
    local -a paths=()
    mapfile -t paths < <(kernel_paths "$k")
    size="$(path_size "${paths[@]}")"
    date="$(kernel_install_date "$k")" || date=""
    # First in the list and worded as a consequence rather than a label: this
    # is the note that has to survive being skim-read.
    if [[ "$k" == "$RUNNING_KVER" ]]; then
        running=1
        notes+=("RUNNING NOW - removing this is dangerous")
    fi
    [[ "$k" == "$NEWEST_CUSTOM" ]] && notes+=("newest build")
    [[ "$k" == "$DEFAULT_KVER" ]] && notes+=("GRUB default")
    local note="" n
    for n in "${notes[@]}"; do
        if [[ -z "$note" ]]; then note="$n"; else note="$note, $n"; fi
    done
    [[ -n "$note" ]] && note="  <- $note"
    # Padded before it is coloured: the escape sequences are characters as far
    # as printf's field width is concerned, and colouring first pushes every
    # other column on the line out of alignment.
    local name
    name="$(printf '%-28s' "$k")"
    if [[ "$running" == 1 ]]; then
        name="${RED}${BOLD}${name}${NC}"
        note="${RED}${BOLD}${note}${NC}"
    fi
    printf '  %d) %b %6s  %-20s%b\n' "$i" "$name" "${size:-?}" \
        "${date:+installed $date}" "$note"
}

# "Every custom kernel" in an unattended run must not quietly come to include
# the kernel the machine is running on, because that is not what it meant on
# the day the invocation was written. Naming the running kernel in KERNELS is
# explicit and stands as given; a blanket 'all' needs ALLOW_RUNNING=1 as well.
drop_running_unless_allowed() {
    local k
    local -a out=()
    [[ "$RUNNING_IS_CUSTOM" == "1" ]] || return 0
    [[ "${ALLOW_RUNNING:-0}" == "1" ]] && return 0
    for k in "${SELECTED_KVERS[@]}"; do
        [[ "$k" == "$RUNNING_KVER" ]] && continue
        out+=("$k")
    done
    if [[ ${#out[@]} -ne ${#SELECTED_KVERS[@]} ]]; then
        warn "Keeping the running kernel ($RUNNING_KVER): 'all' does not mean it"
        warn "unless ALLOW_RUNNING=1 is set, or it is named in KERNELS."
    fi
    SELECTED_KVERS=("${out[@]}")
}

select_kernels() {
    local i choice tok picked=() n=${#CUSTOM_KVERS[@]}

    if [[ -n "${KERNELS:-}" ]]; then
        if [[ "$KERNELS" == "all" ]]; then
            SELECTED_KVERS=("${CUSTOM_KVERS[@]}")
            info "KERNELS=all, removing every custom kernel"
            drop_running_unless_allowed
            return 0
        fi
        for tok in ${KERNELS//,/ }; do
            local found=0
            for k in "${CUSTOM_KVERS[@]}"; do
                if [[ "$k" == "$tok" ]]; then
                    found=1
                    # Named twice is still one kernel, and one removal. The
                    # menu path dedups too; without this the removal loop runs
                    # twice and reports a second, imaginary, removal.
                    case " ${SELECTED_KVERS[*]} " in *" $k "*) break ;; esac
                    SELECTED_KVERS+=("$k")
                    break
                fi
            done
            # A typo in KERNELS must not quietly remove nothing, or worse, be
            # read as "the rest of the list was fine".
            [[ "$found" == 1 ]] || error "KERNELS names '$tok', which is not a
removable custom kernel on this machine. Candidates: ${CUSTOM_KVERS[*]}"
        done
        info "KERNELS set, removing: ${SELECTED_KVERS[*]}"
        return 0
    fi

    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        SELECTED_KVERS=("${CUSTOM_KVERS[@]}")
        drop_running_unless_allowed
        info "ASSUME_YES set, removing every custom kernel: ${SELECTED_KVERS[*]}"
        return 0
    fi

    echo "Custom kernel(s) found. This menu is the kernels this repo built;"
    echo "your stock kernels are listed under it and are not removed here:"
    echo ""
    for ((i = 0; i < n; i++)); do
        kernel_menu_line "$((i + 1))" "${CUSTOM_KVERS[$i]}"
    done
    echo ""
    if [[ "$RUNNING_IS_CUSTOM" == "1" ]]; then
        echo -e "  ${RED}${BOLD}Red is the kernel you booted into.${NC} You can remove it, and this"
        echo "  machine will still boot: $RESTORE_KVER is untouched. But the"
        echo "  running system loses its modules the moment it goes, so anything"
        echo "  not already loaded stays unloadable until you reboot."
        echo ""
    fi
    if [[ ${#STOCK_CANDIDATES[@]} -gt 0 ]]; then
        echo "  Stock kernels (not in this list - the older ones are offered"
        echo "  separately once this menu is done):"
    else
        echo "  Keeping (not removable):"
    fi
    local kdate knote
    for k in "${STOCK_KVERS[@]}"; do
        kdate="$(kernel_install_date "$k")" || kdate=""
        knote=""
        [[ "$k" == "$RUNNING_KVER" ]] && knote="  (running now)"
        [[ "$k" == "$DEFAULT_KVER" ]] && knote="$knote  (GRUB default)"
        printf '     %-34s %-20s%s\n' "$k" "${kdate:+installed $kdate}" "$knote"
    done
    echo ""

    while true; do
        if ! read -rp "$(echo -e "${YELLOW}Remove which? [numbers, e.g. 1 3 4 or 1,3,4 - 'all', or Enter to keep all]:${NC} ")" choice; then
            error "No input available (stdin closed). Re-run attached to a
terminal, or set KERNELS=all (or a version list) to choose without prompting."
        fi

        # Enter is "remove nothing". Someone who opened this script to look at
        # what is installed must be able to leave without deleting a kernel.
        if [[ -z "${choice// /}" ]]; then
            info "No kernels selected."
            return 0
        fi

        if [[ "$choice" == "all" ]]; then
            SELECTED_KVERS=("${CUSTOM_KVERS[@]}")
            return 0
        fi

        picked=()
        local bad=""
        for tok in ${choice//,/ }; do
            if [[ ! "$tok" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > n )); then
                bad="$tok"
                break
            fi
            picked+=("${CUSTOM_KVERS[$((tok - 1))]}")
        done

        if [[ -n "$bad" ]]; then
            warn "'$bad' is not one of 1-$n. Try again."
            continue
        fi

        # Input that tokenises to nothing at all, such as a lone comma. Enter
        # alone is the documented way to select nothing, and it prints a
        # message; this must not be a silent version of the same thing.
        if [[ ${#picked[@]} -eq 0 ]]; then
            warn "No numbers in that. Press Enter alone to keep everything."
            continue
        fi

        # Deduplicate, so "1 1" removes one kernel once rather than running the
        # removal twice and reporting a second, imaginary, removal.
        SELECTED_KVERS=()
        for k in "${picked[@]}"; do
            case " ${SELECTED_KVERS[*]} " in *" $k "*) continue ;; esac
            SELECTED_KVERS+=("$k")
        done
        return 0
    done
}

if [[ "$NO_KERNELS_REMOVED" == "0" ]]; then
    select_kernels
fi

stock_menu_line() {
    local i="$1" k="$2" size date note=""
    local -a paths=()
    mapfile -t paths < <(kernel_paths "$k")
    size="$(path_size "${paths[@]}")"
    date="$(kernel_install_date "$k")" || date=""
    [[ "$k" == "$DEFAULT_KVER" ]] && note="  <- GRUB default"
    # Wider name column than the custom menu: stock kernel names carry the
    # full distro suffix and overflow 28 characters, which pushes the size
    # column out of line by however long the version happens to be.
    printf '  %d) %-34s %6s  %-20s%s\n' "$i" "$k" "${size:-?}" \
        "${date:+installed $date}" "$note"
}

# STOCK_KERNELS takes 'old' for every kernel offered below, 'none' to skip the
# question, or a comma or space separated list of versions.
select_stock_kernels() {
    local n=${#STOCK_CANDIDATES[@]} i k tok choice bad
    local -a picked=()
    [[ $n -gt 0 ]] || return 0

    if [[ -n "${STOCK_KERNELS:-}" ]]; then
        if [[ "$STOCK_KERNELS" == "none" ]]; then
            info "STOCK_KERNELS=none, leaving the stock kernels alone."
            return 0
        fi
        if [[ "$STOCK_KERNELS" == "old" ]]; then
            SELECTED_STOCK=("${STOCK_CANDIDATES[@]}")
            info "STOCK_KERNELS=old, removing: ${SELECTED_STOCK[*]}"
            return 0
        fi
        for tok in ${STOCK_KERNELS//,/ }; do
            local found=0
            for k in "${STOCK_CANDIDATES[@]}"; do
                if [[ "$k" == "$tok" ]]; then
                    found=1
                    case " ${SELECTED_STOCK[*]} " in *" $k "*) break ;; esac
                    SELECTED_STOCK+=("$k")
                    break
                fi
            done
            # $RESTORE_KVER and the running kernel land here, and the message
            # has to say why: they are installed, they are stock, and they are
            # still not candidates.
            [[ "$found" == 1 ]] || error "STOCK_KERNELS names '$tok', which is not
a removable stock kernel here. The running kernel and $RESTORE_KVER are never
offered. Candidates: ${STOCK_CANDIDATES[*]}"
        done
        info "STOCK_KERNELS set, removing: ${SELECTED_STOCK[*]}"
        return 0
    fi

    # Distro packages are not this script's to remove on a blanket ASSUME_YES,
    # the same way the source tree is not: ASSUME_YES was written by people who
    # meant "remove the kernels I built", and it must keep meaning that.
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "Keeping every stock kernel: ASSUME_YES does not touch dnf packages."
        info "Pass STOCK_KERNELS=old (or a version list) to remove them unattended."
        return 0
    fi

    echo ""
    echo "Older stock kernels found. These are dnf packages, so they are removed"
    echo "with dnf rather than deleted, and dnf takes their modules with them:"
    echo ""
    for ((i = 0; i < n; i++)); do
        stock_menu_line "$((i + 1))" "${STOCK_CANDIDATES[$i]}"
    done
    echo ""
    echo "  Keeping (never offered here):"
    printf '     %-34s %s\n' "$RESTORE_KVER" "newest stock kernel"
    if [[ "$RUNNING_KVER" != "$RESTORE_KVER" ]]; then
        printf '     %-34s %s\n' "$RUNNING_KVER" "running now"
    fi
    echo ""

    while true; do
        if ! read -rp "$(echo -e "${YELLOW}Remove which? [numbers, e.g. 1 3 4 or 1,3,4 - 'all', or Enter to keep all]:${NC} ")" choice; then
            error "No input available (stdin closed). Re-run attached to a
terminal, or set STOCK_KERNELS=old / STOCK_KERNELS=none to choose without
prompting."
        fi

        if [[ -z "${choice// /}" ]]; then
            info "Keeping every stock kernel."
            return 0
        fi

        if [[ "$choice" == "all" ]]; then
            SELECTED_STOCK=("${STOCK_CANDIDATES[@]}")
            return 0
        fi

        picked=()
        bad=""
        for tok in ${choice//,/ }; do
            if [[ ! "$tok" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > n )); then
                bad="$tok"
                break
            fi
            picked+=("${STOCK_CANDIDATES[$((tok - 1))]}")
        done

        if [[ -n "$bad" ]]; then
            warn "'$bad' is not one of 1-$n. Try again."
            continue
        fi

        if [[ ${#picked[@]} -eq 0 ]]; then
            warn "No numbers in that. Press Enter alone to keep everything."
            continue
        fi

        SELECTED_STOCK=()
        for k in "${picked[@]}"; do
            case " ${SELECTED_STOCK[*]} " in *" $k "*) continue ;; esac
            SELECTED_STOCK+=("$k")
        done
        return 0
    done
}

remove_stock_kernels() {
    local k i
    local -a pkgs=()
    [[ ${#SELECTED_STOCK[@]} -gt 0 ]] || return 0

    for k in "${SELECTED_STOCK[@]}"; do
        for ((i = 0; i < ${#STOCK_CANDIDATES[@]}; i++)); do
            [[ "${STOCK_CANDIDATES[$i]}" == "$k" ]] || continue
            pkgs+=("${STOCK_PKGS[$i]}")
            break
        done
    done

    echo ""
    echo "About to remove these stock kernels with dnf:"
    for ((i = 0; i < ${#SELECTED_STOCK[@]}; i++)); do
        echo "  - ${SELECTED_STOCK[$i]}  (${pkgs[$i]})"
    done
    echo "Keeping $RESTORE_KVER, which stays bootable."
    echo ""

    if ! confirm "Remove the stock kernel(s) listed above?"; then
        info "Aborted. No stock kernel was removed."
        SELECTED_STOCK=()
        return 0
    fi

    # One transaction for all of them: one kernel-install pass, one bootloader
    # pass, and one place for dnf to refuse if a dependency says no.
    info "Running: dnf remove ${pkgs[*]}"
    if sudo dnf remove -y "${pkgs[@]}"; then
        REMOVED_STOCK=("${SELECTED_STOCK[@]}")
        for k in "${REMOVED_STOCK[@]}"; do
            ok "Removed stock kernel $k"
        done
    else
        # Nothing later in this script depends on these having gone, so a
        # failed dnf run is reported and the rest of the uninstall continues.
        warn "dnf could not remove the stock kernel(s). They are as they were."
        SELECTED_STOCK=()
    fi
}

# True when a kernel was removed by either half of this script. Used wherever
# "what is still installed" has to be answered after the fact.
kernel_was_removed() {
    case " ${SELECTED_KVERS[*]} " in *" $1 "*) return 0 ;; esac
    case " ${REMOVED_STOCK[*]} " in *" $1 "*) return 0 ;; esac
    return 1
}

# --- Remove the selected kernels ---
FULL_REMOVAL=0
RUNNING_SELECTED=0
if [[ ${#SELECTED_KVERS[@]} -gt 0 ]]; then
    echo ""
    echo "About to remove:"
    for k in "${SELECTED_KVERS[@]}"; do
        if [[ "$k" == "$RUNNING_KVER" ]]; then
            RUNNING_SELECTED=1
            echo -e "  - ${RED}${BOLD}$k${NC}  ${RED}(running now)${NC}"
        else
            echo "  - $k"
        fi
    done
    for k in "${CUSTOM_KVERS[@]}"; do
        case " ${SELECTED_KVERS[*]} " in *" $k "*) continue ;; esac
        KEPT_CUSTOM+=("$k")
    done
    if [[ ${#KEPT_CUSTOM[@]} -gt 0 ]]; then
        echo "Keeping custom kernel(s): ${KEPT_CUSTOM[*]}"
    else
        FULL_REMOVAL=1
    fi
    echo ""

    # One prompt either way, but a harder one when the running kernel is in the
    # list. Two prompts in a row train people to answer both without reading.
    if [[ "$RUNNING_SELECTED" == "1" ]]; then
        echo -e "${RED}${BOLD}$RUNNING_KVER is the kernel this machine is running right now.${NC}"
        echo "Removing it deletes /boot/vmlinuz-$RUNNING_KVER and its modules."
        echo "The running system keeps working — the kernel itself is in memory —"
        echo "but any module not already loaded (a filesystem, a USB or network"
        echo "driver) cannot be loaded until you reboot, and the reboot lands on"
        echo "a different kernel. $RESTORE_KVER stays installed and bootable."
        echo ""
        if ! confirm_running "Type 'yes' to remove it along with the rest"; then
            info "Aborted. Nothing was removed."
            SELECTED_KVERS=()
            FULL_REMOVAL=0
            RUNNING_SELECTED=0
            KEPT_CUSTOM=()
        fi
    elif ! confirm "Remove the kernel(s) listed above?"; then
        info "Aborted. Nothing was removed."
        SELECTED_KVERS=()
        FULL_REMOVAL=0
        # KEPT_CUSTOM was "what survives the removal". With no removal it would
        # otherwise make the summary list a subset of what is installed and
        # call it "still installed", which contradicts the line above it.
        KEPT_CUSTOM=()
    fi
fi

for KVER in "${SELECTED_KVERS[@]}"; do
    info "Removing kernel: $KVER"
    while read -r p; do
        [[ -e "$p" ]] || continue
        sudo rm -rf -- "$p"
    done < <(kernel_paths "$KVER")

    # grubby keeps its own record of bootable entries. Leaving one behind for a
    # kernel whose files are gone is how a machine ends up with a GRUB entry
    # that drops to an emergency prompt.
    if command -v grubby >/dev/null 2>&1; then
        sudo grubby --remove-kernel="/boot/vmlinuz-$KVER" >/dev/null 2>&1 || true
    fi
    ok "Removed $KVER"
done

# Asked after our own kernels have gone, so the sizes and the "keeping" line
# describe the machine as it is by then rather than as it was.
select_stock_kernels
remove_stock_kernels

# If the kernel GRUB booted by default was one of those removed, point the
# default at a stock kernel before regenerating anything. Not at the running
# kernel: it may be one of the kernels that just went. dnf reruns the bootloader
# hooks for the packages it removed, but it knows nothing about the kernels this
# script deleted by hand, so the fix-up is done here either way.
if [[ -n "$DEFAULT_KVER" ]] && kernel_was_removed "$DEFAULT_KVER"; then
    if command -v grubby >/dev/null 2>&1; then
        sudo grubby --set-default="/boot/vmlinuz-$RESTORE_KVER" \
            >/dev/null 2>&1 || true
        warn "The GRUB default was $DEFAULT_KVER, which has been removed."
        ok "GRUB default is now $RESTORE_KVER"
    fi
fi

# --- Configuration this repo installs alongside the kernel ---
#
# Only cleared on a full removal. A kept fairydust kernel still wants its typec
# module autoloaded, and taking that away because a *different* kernel was
# removed would break the one the user chose to keep.
if [[ "$FULL_REMOVAL" == "1" ]]; then
    if [[ -f /etc/modules-load.d/fairydust-typec.conf ]]; then
        sudo rm -f /etc/modules-load.d/fairydust-typec.conf
        ok "Removed typec module autoload config"
    fi

    # The three blocks below clean up files this script's own builder never
    # creates. They come from the upstream fork's older script, which did
    # install a display hotplug rule and an autostart entry. Anyone who ran
    # that first and this uninstaller second would otherwise be left with them,
    # so the blocks stay. They are no-ops on a machine that only ever ran the
    # current builder.
    if [[ -f /etc/udev/rules.d/95-fairydust-hotplug.rules ]]; then
        sudo rm -f /etc/udev/rules.d/95-fairydust-hotplug.rules
        sudo udevadm control --reload-rules
        ok "Removed udev hotplug rule"
    fi

    if [[ -f "$HOME/display-setup.sh" ]]; then
        rm -f "$HOME/display-setup.sh"
        ok "Removed display setup script"
    fi

    if [[ -f "$HOME/.config/autostart/fairydust-display.desktop" ]]; then
        rm -f "$HOME/.config/autostart/fairydust-display.desktop"
        ok "Removed autostart entry"
    fi
fi

# --- Bootloader ---
#
# GRUB first, and before m1n1. The kernels are already gone by this point, so
# the menu is describing kernels that no longer exist, and that is the state
# that drops someone at an emergency prompt. Nothing further in this script is
# allowed to prevent it being fixed.
if [[ ${#SELECTED_KVERS[@]} -gt 0 || ${#REMOVED_STOCK[@]} -gt 0 ]]; then
    info "Regenerating GRUB..."
    if sudo grub2-mkconfig -o /boot/grub2/grub.cfg; then
        ok "GRUB regenerated"
    else
        warn "grub2-mkconfig failed. The removed kernels may still be listed in"
        warn "the boot menu. Run 'sudo grub2-mkconfig -o /boot/grub2/grub.cfg'."
    fi
fi

# --- Which kernel boots by default ---
#
# Offered after GRUB is regenerated, because grub2-mkconfig rewrites the menu
# this default points into, and offered even when nothing was removed: picking
# the boot default is a fair reason to run this script on its own.
#
#   SET_DEFAULT=<version>   set it without asking
#   SET_DEFAULT=keep        leave it alone without asking
choose_default_kernel() {
    local -a survivors=()
    local k i n choice current

    command -v grubby >/dev/null 2>&1 || return 0

    # Whatever GRUB thinks now, which is not necessarily what it thought at
    # the start: a removed default was already moved to the running kernel.
    current="$(sudo grubby --default-kernel 2>/dev/null || true)"
    current="${current##*/vmlinuz-}"
    [[ "$current" == /* ]] && current=""

    # Every kernel still on disk, which is not the same list as KEPT_CUSTOM:
    # that one is only filled in when something was actually removed, so
    # reading it here hid every custom kernel from this menu on the run where
    # nothing was removed — including, sometimes, the current default itself.
    for k in "${STOCK_KVERS[@]}" "${CUSTOM_KVERS[@]}"; do
        kernel_was_removed "$k" && continue
        survivors+=("$k")
    done
    n=${#survivors[@]}
    # Nothing to choose between.
    [[ $n -gt 1 ]] || return 0

    if [[ -n "${SET_DEFAULT:-}" ]]; then
        if [[ "$SET_DEFAULT" == "keep" ]]; then
            info "SET_DEFAULT=keep, leaving the boot default at ${current:-unchanged}"
            return 0
        fi
        for k in "${survivors[@]}"; do
            [[ "$k" == "$SET_DEFAULT" ]] && { apply_default_kernel "$k"; return 0; }
        done
        error "SET_DEFAULT names '$SET_DEFAULT', which is not an installed
kernel. Installed: ${survivors[*]}"
    fi

    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "Leaving the boot default at ${current:-unchanged}."
        info "Pass SET_DEFAULT=<version> to change it in an unattended run."
        return 0
    fi

    echo ""
    echo "Which kernel should GRUB boot by default?"
    echo ""
    for ((i = 0; i < n; i++)); do
        k="${survivors[$i]}"
        local note=""
        [[ "$k" == "$current" ]] && note="  <- current default"
        [[ "$k" == "$RUNNING_KVER" ]] && note="$note  (running now)"
        printf '  %d) %-34s %-20s%s\n' "$((i + 1))" "$k" \
            "$(kernel_install_date "$k" | sed 's/^/installed /')" "$note"
    done
    echo ""

    while true; do
        if ! read -rp "$(echo -e "${YELLOW}Boot which by default? [number, or Enter to keep ${current:-as is}]:${NC} ")" choice; then
            # A closed stdin here is not worth failing a finished uninstall
            # over: the kernels are already gone and GRUB is already correct.
            info "No input available, leaving the boot default alone."
            return 0
        fi

        if [[ -z "${choice// /}" ]]; then
            info "Boot default left at ${current:-its current setting}."
            return 0
        fi

        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= n )); then
            apply_default_kernel "${survivors[$((choice - 1))]}"
            return 0
        fi

        warn "'$choice' is not one of 1-$n. Try again."
    done
}

# Set it, then read it back. grubby writes through to /boot/grub2/grubenv on a
# GRUB_DEFAULT=saved system, and a write that silently did not take would
# otherwise be reported here as a success.
apply_default_kernel() {
    local k="$1" now
    if ! sudo grubby --set-default="/boot/vmlinuz-$k" >/dev/null 2>&1; then
        warn "Could not set the boot default to $k."
        return 0
    fi
    now="$(sudo grubby --default-kernel 2>/dev/null || true)"
    now="${now##*/vmlinuz-}"
    if [[ "$now" == "$k" ]]; then
        ok "GRUB will boot $k by default"
    else
        warn "Asked GRUB to boot $k by default, but it still reports"
        warn "${now:-nothing}. Check /etc/default/grub and /boot/grub2/grubenv."
    fi
}

choose_default_kernel

# m1n1 is only put back on stock when the last of our kernels goes. It boots
# one set of device trees, and a partial removal means a kernel of ours is
# still installed and still expects the DTBs it was built with. Resetting m1n1
# underneath it would leave the kernel the user deliberately kept unbootable.
#
# Every step here warns rather than exits on failure. An unmounted ESP or a
# missing m1n1 package used to abort the script mid-way under set -e, with no
# error line, no summary, and the build leftovers never offered.
M1N1_RESTORED=0
if [[ "$FULL_REMOVAL" == "1" ]]; then
    info "Restoring m1n1 bootloader..."
    m1n1_ok=1

    if [[ -L /boot/dtb ]]; then
        sudo ln -sfn "dtb-$RESTORE_KVER" /boot/dtb || m1n1_ok=0
    fi

    if [[ -f /etc/sysconfig/update-m1n1 ]]; then
        # Anchored, and only non-commented lines: the previous pattern matched
        # any line containing DTBS=, including commented-out ones, and
        # activated them.
        sudo sed -i 's|^[[:space:]]*DTBS=.*|DTBS="/boot/dtb"|' \
            /etc/sysconfig/update-m1n1 || m1n1_ok=0
    fi

    sudo ln -sfn "/usr/lib/modules/$RESTORE_KVER" /usr/src/linux || m1n1_ok=0

    if sudo update-m1n1 && [[ "$m1n1_ok" == "1" ]]; then
        M1N1_RESTORED=1
        ok "m1n1 restored to stock kernel ($RESTORE_KVER)"
    else
        warn "Could not fully restore m1n1. Your stock kernel still boots"
        warn "through GRUB, but run 'sudo update-m1n1' once the cause is fixed"
        warn "(an unmounted ESP is the usual one)."
    fi
elif [[ ${#SELECTED_KVERS[@]} -gt 0 ]]; then
    info "m1n1 left as it is: ${KEPT_CUSTOM[*]} is still installed."
fi

# --- Build leftovers ---
#
# Offered separately from the kernels, and offered even when no kernel was
# removed, because a multi-gigabyte source tree and a fat log outlive the
# kernel they produced and are the whole reason someone comes back to this
# script a second time.
#
#   CLEANUP=all         remove every leftover found
#   CLEANUP=none        remove none of them
#   CLEANUP="log,source"  by key, comma or space separated
#
# REMOVE_SOURCE stays honoured for the source tree specifically, because it is
# what earlier versions of this script documented.
declare -a LEFTOVER_KEYS=() LEFTOVER_LABELS=() LEFTOVER_PATHS=()

# CLONE_DIR, LOG_FILE and ALARM_PKGBUILDS_DIR are read straight from the
# environment and then handed to rm -rf, so a value that is not what it claims
# to be has to be caught here rather than trusted. CLONE_DIR=$HOME with
# CLEANUP=all would otherwise delete a home directory without a prompt.
#
# The test is "does this path contain what its label says it contains". A
# source tree with no Makefile is not a source tree, whatever it was named, and
# is left alone.
declare -a REJECTED_LEFTOVERS=()

path_is_sane_target() {
    local p="$1" real depth
    real="$(readlink -f -- "$p" 2>/dev/null)" || return 1
    [[ -n "$real" ]] || return 1
    # Never the root of anything someone lives in, however we got here.
    case "$real" in
        / | /home | /root | /usr | /var | /etc | /boot | /tmp) return 1 ;;
    esac
    [[ "$real" == "$HOME" ]] && return 1
    # /a/b is as shallow as a legitimate target ever gets, and that is already
    # generous for something we are about to remove recursively.
    depth="$(awk -F/ '{print NF - 1}' <<< "$real")"
    [[ "$depth" -ge 2 ]] || return 1
    return 0
}

add_leftover() {
    local key="$1" label="$2" path="$3" kind="$4"
    [[ -e "$path" ]] || return 0

    local sane=1
    path_is_sane_target "$path" || sane=0
    if [[ "$sane" == 1 ]]; then
        case "$kind" in
            # A kernel tree has a Makefile, and after a build a .config too. A
            # git checkout on its own is enough for a tree that never built.
            tree) [[ -d "$path" ]] \
                && { [[ -f "$path/Makefile" || -f "$path/.config" || -d "$path/.git" ]] \
                     || sane=0; } || sane=0 ;;
            # PKGBUILDs is a git checkout of build recipes.
            pkgtree) [[ -d "$path" ]] \
                && { [[ -d "$path/.git" ]] || compgen -G "$path/*/PKGBUILD" >/dev/null \
                     || sane=0; } || sane=0 ;;
            file) [[ -f "$path" ]] || sane=0 ;;
        esac
    fi

    if [[ "$sane" == 0 ]]; then
        REJECTED_LEFTOVERS+=("$label: $path")
        return 0
    fi

    LEFTOVER_KEYS+=("$key")
    LEFTOVER_LABELS+=("$label")
    LEFTOVER_PATHS+=("$path")
}

# Honour the same overrides the build script uses, so a non-default tree or log
# is still offered for removal.
CLONE_DIR="${CLONE_DIR:-$HOME/linux-fairydust}"
LOG_FILE="${LOG_FILE:-$HOME/fairydust-build.log}"

add_leftover source    "Kernel source tree"   "$CLONE_DIR" tree
add_leftover log       "Build log"            "$LOG_FILE" file
add_leftover pkgbuilds "ALARM PKGBUILDs tree" \
    "${ALARM_PKGBUILDS_DIR:-$HOME/PKGBUILDs}" pkgtree

# The older layout, from before CLONE_DIR existed. Only offered when the
# .config in it names one of our kernels, so an unrelated ~/linux checkout is
# never proposed for deletion.
if [[ -d "$HOME/linux" && -f "$HOME/linux/.config" ]] \
    && grep -qE "$KVER_PATTERN" "$HOME/linux/.config" 2>/dev/null; then
    add_leftover legacy "Kernel source tree (old ~/linux layout)" "$HOME/linux" tree
fi

if [[ ${#REJECTED_LEFTOVERS[@]} -gt 0 ]]; then
    echo ""
    warn "These paths exist but do not hold what they are supposed to hold,"
    warn "so they are not offered for removal:"
    for _r in "${REJECTED_LEFTOVERS[@]}"; do
        warn "  $_r"
    done
    warn "Remove them by hand if you are sure. Check CLONE_DIR and LOG_FILE."
fi

remove_leftover() {
    local i="$1"
    rm -rf -- "${LEFTOVER_PATHS[$i]}"
    ok "Removed ${LEFTOVER_LABELS[$i]}: ${LEFTOVER_PATHS[$i]}"
}

cleanup_leftovers() {
    local n=${#LEFTOVER_KEYS[@]} i m key want choice tok bad
    local -a pending=() sel=()
    [[ $n -gt 0 ]] || return 0

    # A typo here must not read as "remove nothing", the same way a typo in
    # KERNELS must not. Checked before anything is deleted, so a bad key costs
    # nothing but the message.
    if [[ -n "${CLEANUP:-}" ]]; then
        for tok in ${CLEANUP//,/ }; do
            case "$tok" in
                all|none|source|log|pkgbuilds|legacy) ;;
                *) error "CLEANUP names '$tok', which is not one of:
all, none, source, log, pkgbuilds, legacy." ;;
            esac
        done
    fi

    # Decide what the environment already answered for, and leave the rest to
    # the menu. REMOVE_SOURCE predates CLEANUP and still decides the source
    # tree, in both directions, so an existing unattended invocation keeps
    # doing exactly what it did before — but it decides the source tree ONLY,
    # and never silently answers for the log or the PKGBUILDs tree.
    for ((i = 0; i < n; i++)); do
        key="${LEFTOVER_KEYS[$i]}"
        want=""

        if [[ "$key" == "source" || "$key" == "legacy" ]]; then
            case "${REMOVE_SOURCE:-}" in
                1) want=1 ;;
                0) want=0 ;;
            esac
        fi

        if [[ -z "$want" && -n "${CLEANUP:-}" ]]; then
            case "$CLEANUP" in
                all)  want=1 ;;
                none) want=0 ;;
                *)    want=0
                      case " ${CLEANUP//,/ } " in *" $key "*) want=1 ;; esac ;;
            esac
        fi

        case "$want" in
            1)  remove_leftover "$i" ;;
            0)  info "Keeping ${LEFTOVER_LABELS[$i]}: ${LEFTOVER_PATHS[$i]}" ;;
            *)  pending+=("$i") ;;
        esac
    done

    m=${#pending[@]}
    [[ $m -gt 0 ]] || return 0

    echo ""
    echo "Build leftovers found:"
    echo ""
    for ((i = 0; i < m; i++)); do
        printf '  %d) %-38s %6s  %s\n' "$((i + 1))" \
            "${LEFTOVER_LABELS[${pending[$i]}]}" \
            "$(path_size "${LEFTOVER_PATHS[${pending[$i]}]}")" \
            "${LEFTOVER_PATHS[${pending[$i]}]}"
    done
    echo ""

    # Removing a source tree is not recoverable by rebuilding: it may hold
    # uncommitted local changes. So ASSUME_YES on its own deliberately does NOT
    # delete anything here. CLEANUP and REMOVE_SOURCE are the explicit opt-ins.
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        info "Keeping all build leftovers: ASSUME_YES does not delete them."
        info "Pass CLEANUP=all (or CLEANUP=log,source) to remove them unattended."
        return 0
    fi

    while true; do
        if ! read -rp "$(echo -e "${YELLOW}Remove which? [numbers, e.g. 1 3 4 or 1,3,4 - 'all', or Enter to keep all]:${NC} ")" choice; then
            error "No input available (stdin closed). Re-run attached to a
terminal, or set CLEANUP=all / CLEANUP=none to choose without prompting."
        fi

        if [[ -z "${choice// /}" ]]; then
            info "Keeping all build leftovers."
            return 0
        fi

        if [[ "$choice" == "all" ]]; then
            for i in "${pending[@]}"; do
                remove_leftover "$i"
            done
            return 0
        fi

        sel=()
        bad=""
        for tok in ${choice//,/ }; do
            if [[ ! "$tok" =~ ^[0-9]+$ ]] || (( tok < 1 || tok > m )); then
                bad="$tok"
                break
            fi
            case " ${sel[*]} " in *" ${pending[$((tok - 1))]} "*) continue ;; esac
            sel+=("${pending[$((tok - 1))]}")
        done

        if [[ -n "$bad" ]]; then
            warn "'$bad' is not one of 1-$m. Try again."
            continue
        fi

        # Input that tokenises to nothing at all, such as a lone comma. Saying
        # so beats returning in silence, which reads as though something was
        # removed.
        if [[ ${#sel[@]} -eq 0 ]]; then
            warn "No numbers in that. Press Enter alone to keep everything."
            continue
        fi

        for i in "${sel[@]}"; do
            remove_leftover "$i"
        done
        return 0
    done
}

cleanup_leftovers

# --- Summary ---
echo ""
echo "============================================================"
if [[ ${#SELECTED_KVERS[@]} -eq 0 && ${#REMOVED_STOCK[@]} -eq 0 ]]; then
    echo -e "  ${GREEN}NO KERNELS REMOVED${NC}"
else
    echo -e "  ${GREEN}UNINSTALL COMPLETE${NC}"
fi
echo "============================================================"
echo ""
if [[ ${#SELECTED_KVERS[@]} -gt 0 ]]; then
    echo "  Removed: ${SELECTED_KVERS[*]}"
fi
if [[ ${#REMOVED_STOCK[@]} -gt 0 ]]; then
    echo "  Removed with dnf: ${REMOVED_STOCK[*]}"
fi
if [[ "$FULL_REMOVAL" == "1" && "$M1N1_RESTORED" == "1" ]]; then
    if [[ "$RUNNING_SELECTED" == "1" ]]; then
        echo "  m1n1 and GRUB are back on $RESTORE_KVER, which is where the"
        echo "  next boot lands."
    else
        echo "  Your system is back to the stock Fedora Asahi kernel."
    fi
elif [[ "$FULL_REMOVAL" == "1" ]]; then
    echo "  All of our kernels are gone and GRUB boots your stock kernel,"
    echo "  but m1n1 was not fully restored. See the warning above."
elif [[ ${#KEPT_CUSTOM[@]} -gt 0 ]]; then
    echo "  Still installed: ${KEPT_CUSTOM[*]}"
    echo "  m1n1 was left alone, so those still boot as they did before."
fi
if [[ "$RUNNING_SELECTED" == "1" ]]; then
    echo -e "  Current kernel: ${RED}${BOLD}$RUNNING_KVER (removed - reboot to leave it)${NC}"
    echo ""
    echo -e "  ${RED}${BOLD}Reboot when you can.${NC} This kernel is running from memory and its"
    echo "  files are gone, so any module not already loaded cannot be loaded."
    echo "  Plugging in something new is the usual way to find that out."
else
    echo "  Current kernel: $RUNNING_KVER"
fi
echo ""
echo "============================================================"
