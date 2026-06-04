#!/usr/bin/env bash
# =============================================================================
# install_tools.sh
# Description : Installs all tools required by recon_openclaw.sh
# Tested on   : Kali Linux (2024+), Ubuntu 22.04+
# Usage       : sudo ./install_tools.sh [--check] [--force]
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; }

CHECK_ONLY=0
FORCE_REINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1
            shift
            ;;
        --force)
            FORCE_REINSTALL=1
            shift
            ;;
        *)
            error "Unknown option: $1"
            echo "Usage: sudo ./install_tools.sh [--check] [--force]"
            exit 1
            ;;
    esac
done

# Prefer installing Go tools for the invoking user (when using sudo)
INSTALL_USER="${SUDO_USER:-$USER}"
INSTALL_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6 2>/dev/null || true)"
if [[ -z "$INSTALL_HOME" ]]; then
    INSTALL_HOME="$HOME"
fi
GO_BIN_DIR="$INSTALL_HOME/go/bin"

has_tool() {
    local tool="$1"
    command -v "$tool" &>/dev/null || [[ -x "$GO_BIN_DIR/$tool" ]]
}

# ─── Tool Verification ───────────────────────────────────────────────────────
REQUIRED_TOOLS=(subfinder assetfinder httpx gau waybackurls katana naabu nmap whatweb ffuf gowitness nuclei nikto)

if [[ $CHECK_ONLY -eq 1 ]]; then
    info "Checking installed tools..."
    ALL_OK=1
    for tool in "${REQUIRED_TOOLS[@]}"; do
        if has_tool "$tool"; then
            info "  [OK] $tool"
        else
            error "  [MISSING] $tool"
            ALL_OK=0
        fi
    done
    if [[ $ALL_OK -eq 1 ]]; then
        info "All tools are installed."
    else
        error "Some tools are missing. Run: sudo ./install_tools.sh"
        exit 1
    fi
    exit 0
fi

if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo ./install_tools.sh"
    exit 1
fi

# ─── Distro Detection ────────────────────────────────────────────────────────
DISTRO="unknown"
if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "$ID" in
        kali)   DISTRO="kali"   ;;
        ubuntu) DISTRO="ubuntu" ;;
        debian) DISTRO="debian" ;;
        *)      DISTRO="$ID"    ;;
    esac
fi

info "Detected distro: $DISTRO"
info "Updating package lists..."
apt-get update -qq

# ─── System Packages ─────────────────────────────────────────────────────────
info "Installing system packages..."

if [[ "$DISTRO" == "ubuntu" || "$DISTRO" == "debian" ]]; then
    # Ensure universe repository is available on Ubuntu
    add-apt-repository -y universe &>/dev/null || true
    apt-get update -qq
fi

# Package names are consistent across Kali, Ubuntu, and Debian
apt-get install -y -qq \
    curl \
    wget \
    git \
    nmap \
    nikto \
    ffuf \
    golang-go \
    python3 \
    python3-pip \
    whatweb

# ─── Go Tools ────────────────────────────────────────────────────────────────
export GOPATH="$INSTALL_HOME/go"
export GOBIN="$GO_BIN_DIR"
export PATH="$PATH:$GO_BIN_DIR"

GO_WORK_BASE="${GO_WORK_BASE:-/var/tmp/recon_openclaw-go}"
mkdir -p "$GO_WORK_BASE/tmp" "$GO_WORK_BASE/cache"
export TMPDIR="$GO_WORK_BASE/tmp"
export GOTMPDIR="$GO_WORK_BASE/tmp"
export GOCACHE="$GO_WORK_BASE/cache"

info "Using Go install user: $INSTALL_USER ($INSTALL_HOME)"
info "Go temp/cache directory: $GO_WORK_BASE"
info "Installing Go-based tools..."

run_go_install() {
    local pkg="$1"
    if [[ "$INSTALL_USER" == "root" ]]; then
        env GOPATH="$GOPATH" GOBIN="$GOBIN" PATH="$PATH" TMPDIR="$TMPDIR" GOTMPDIR="$GOTMPDIR" GOCACHE="$GOCACHE" \
            go install -v "$pkg"
    else
        sudo -u "$INSTALL_USER" -H env GOPATH="$GOPATH" GOBIN="$GOBIN" PATH="$PATH" TMPDIR="$TMPDIR" GOTMPDIR="$GOTMPDIR" GOCACHE="$GOCACHE" \
            go install -v "$pkg"
    fi
}

install_go_tool() {
    local tool_name="$1"
    local package_ref="$2"

    if [[ $FORCE_REINSTALL -eq 0 ]] && has_tool "$tool_name"; then
        warn "  -> $tool_name already installed — skipping."
        return 0
    fi

    info "  -> $tool_name"
    run_go_install "$package_ref"
}

install_go_tool "subfinder" "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"      # tested: v2.6.6

install_go_tool "httpx" "github.com/projectdiscovery/httpx/cmd/httpx@latest"                  # tested: v1.6.10

install_go_tool "katana" "github.com/projectdiscovery/katana/cmd/katana@latest"                # tested: v1.1.2

install_go_tool "naabu" "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"               # tested: v2.3.3

install_go_tool "nuclei" "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"             # tested: v3.3.9

install_go_tool "gau" "github.com/lc/gau/v2/cmd/gau@latest"                                 # tested: v2.2.3

install_go_tool "waybackurls" "github.com/tomnomnom/waybackurls@latest"                             # tested: v0.1.0

install_go_tool "assetfinder" "github.com/tomnomnom/assetfinder@latest"                             # tested: v0.1.1

install_go_tool "gowitness" "github.com/sensepost/gowitness@latest"                               # tested: v3.0.7

# ─── SecLists ────────────────────────────────────────────────────────────────
if [[ ! -d /usr/share/seclists ]]; then
    info "Installing SecLists..."
    git clone --depth 1 https://github.com/danielmiessler/SecLists.git /usr/share/seclists
else
    warn "SecLists already installed at /usr/share/seclists — skipping."
fi

# ─── PATH Export ─────────────────────────────────────────────────────────────
GOBIN_EXPORT='export PATH=$PATH:$HOME/go/bin'
for rc in "$INSTALL_HOME/.bashrc" "$INSTALL_HOME/.zshrc"; do
    if [[ -f "$rc" ]]; then
        if grep -q 'go/bin' "$rc"; then
            warn "Go PATH already present in $rc — skipping."
        else
            {
                echo ""
                echo "# Go binaries (added by install_tools.sh)"
                echo "$GOBIN_EXPORT"
            } >> "$rc"
            info "Added Go PATH export to $rc"
        fi
    fi
done

# ─── Make recon_openclaw.sh executable ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAIN_SCRIPT="$SCRIPT_DIR/../recon_openclaw.sh"
if [[ -f "$MAIN_SCRIPT" ]]; then
    chmod +x "$MAIN_SCRIPT"
    info "recon_openclaw.sh marked as executable."
fi

echo ""
info "All tools installed successfully!"
echo ""
echo "  Reload your shell or run:"
echo "  source ~/.bashrc"
echo ""
echo "  Then run:"
echo "  ./recon_openclaw.sh example.com"
echo "  ./recon_openclaw.sh --with-openclaw example.com"
