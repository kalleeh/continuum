#!/usr/bin/env bash
#
# Continuum installer (bootstrap)
# https://kalleeh.github.io/continuum/setup
#
# Usage:
#     /bin/bash -c "$(curl -fsSL https://kalleeh.github.io/continuum/install.sh)"
#
# Behaviour:
#   1. Downloads deploy.sh + cloud-init.yaml from the latest continuum-relay
#      release into a temp directory.
#   2. Verifies their sha256 against the release's checksums.txt.
#   3. Exec's deploy.sh, which handles the actual server provisioning
#      (Lightsail / EC2 / DigitalOcean / Hetzner / local). deploy.sh prompts
#      interactively via gum.
#
# Override hooks (mostly for development / testing):
#   CONTINUUM_RELEASE_BASE   — default https://github.com/kalleeh/continuum-relay/releases/latest/download
#   CONTINUUM_INSTALL_NO_RUN — set to 1 to download + verify without exec'ing deploy.sh

set -euo pipefail

readonly RELEASE_BASE="${CONTINUUM_RELEASE_BASE:-https://github.com/kalleeh/continuum-relay/releases/latest/download}"
readonly DEPLOY_URL="$RELEASE_BASE/deploy.sh"
readonly CLOUDINIT_URL="$RELEASE_BASE/cloud-init.yaml"
readonly CHECKSUMS_URL="$RELEASE_BASE/checksums.txt"

# ── Pretty output ────────────────────────────────────────────────────────────

if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
    BOLD=$(tput bold) RESET=$(tput sgr0)
    GREEN=$(tput setaf 2) RED=$(tput setaf 1) YELLOW=$(tput setaf 3) CYAN=$(tput setaf 6)
else
    BOLD="" RESET="" GREEN="" RED="" YELLOW="" CYAN=""
fi

step() { printf '%s==>%s %s%s%s\n' "$CYAN" "$RESET" "$BOLD" "$*" "$RESET"; }
ok()   { printf '%s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die()  { printf '%sError:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ── Pre-flight ───────────────────────────────────────────────────────────────

require() {
    command -v "$1" >/dev/null 2>&1 \
        || die "$1 is required but was not found on \$PATH"
}

# Pick whichever sha256 tool is available (sha256sum on Linux, shasum on macOS).
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        die "Neither sha256sum nor shasum is available; cannot verify download integrity"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    printf '\n%sContinuum installer%s\n' "$BOLD" "$RESET"
    printf '%s%s%s\n\n' "$CYAN" "https://kalleeh.github.io/continuum" "$RESET"

    require curl
    require bash
    require mktemp
    # awk is used below to extract the expected sha256 from checksums.txt.
    # macOS and the major Linuxes ship it; minimal Alpine and a few
    # embedded distros don't, so check explicitly rather than failing
    # confusingly later.
    require awk

    step "Creating workspace"
    local tmp
    tmp=$(mktemp -d -t continuum-install.XXXXXX)
    trap 'rm -rf "$tmp"' EXIT
    ok "$tmp"

    step "Fetching latest release"
    curl -fsSL "$DEPLOY_URL"     -o "$tmp/deploy.sh"        || die "could not download deploy.sh"
    curl -fsSL "$CLOUDINIT_URL"  -o "$tmp/cloud-init.yaml"  || die "could not download cloud-init.yaml"
    curl -fsSL "$CHECKSUMS_URL"  -o "$tmp/checksums.txt"    || die "could not download checksums.txt"
    ok "downloaded deploy.sh, cloud-init.yaml, checksums.txt"

    step "Verifying checksums"
    local expected actual
    for f in deploy.sh cloud-init.yaml; do
        expected=$(awk -v file="$f" '$2 == file {print $1}' "$tmp/checksums.txt")
        if [ -z "$expected" ]; then
            die "$f is not listed in checksums.txt — refusing to run an unverified script"
        fi
        actual=$(sha256_of "$tmp/$f")
        if [ "$expected" != "$actual" ]; then
            die "$f checksum mismatch (expected $expected, got $actual). Refusing to run."
        fi
        ok "$f $actual"
    done

    chmod +x "$tmp/deploy.sh"

    if [ "${CONTINUUM_INSTALL_NO_RUN:-0}" = "1" ]; then
        warn "CONTINUUM_INSTALL_NO_RUN=1 set; stopping before running deploy.sh."
        printf '\nDownloaded files are in: %s\n' "$tmp"
        trap - EXIT
        return 0
    fi

    step "Launching deploy.sh"
    cd "$tmp"
    # Run as a child process (not exec) so the EXIT trap fires when deploy.sh
    # finishes and the temp dir gets cleaned up. signal forwarding still works:
    # Ctrl-C reaches the foreground process group containing both bash and the
    # child, so deploy.sh sees SIGINT either way.
    ./deploy.sh create
}

main "$@"
