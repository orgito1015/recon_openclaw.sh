#!/usr/bin/env bash
# =============================================================================
# install_tools.sh
# Description : Installs all tools required by recon_openclaw.sh
# Tested on   : Kali Linux (2024+), Ubuntu 22.04+
# Usage       : sudo ./install_tools.sh
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[-]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
    error "Please run as root: sudo ./install_tools.sh"
    exit 1
fi

info "Updating package lists..."
apt-get update -qq

# ─── System Packages ─────────────────────────────────────────────────────────
info "Installing system packages..."
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
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

info "Installing Go-based tools..."

info "  -> subfinder"
go install -v github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest

info "  -> httpx"
go install -v github.com/projectdiscovery/httpx/cmd/httpx@latest

info "  -> katana"
go install -v github.com/projectdiscovery/katana/cmd/katana@latest

info "  -> naabu"
go install -v github.com/projectdiscovery/naabu/v2/cmd/naabu@latest

info "  -> nuclei"
go install -v github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest

info "  -> gau"
go install -v github.com/lc/gau/v2/cmd/gau@latest

info "  -> waybackurls"
go install -v github.com/tomnomnom/waybackurls@latest

info "  -> assetfinder"
go install -v github.com/tomnomnom/assetfinder@latest

info "  -> gowitness"
go install -v github.com/sensepost/gowitness@latest

# ─── SecLists ────────────────────────────────────────────────────────────────
if [[ ! -d /usr/share/seclists ]]; then
    info "Installing SecLists..."
    git clone --depth 1 https://github.com/danielmiessler/SecLists.git /usr/share/seclists
else
    warn "SecLists already installed at /usr/share/seclists — skipping."
fi

# ─── Make recon_openclaw.sh executable ───────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/recon_openclaw.sh" ]]; then
    chmod +x "$SCRIPT_DIR/recon_openclaw.sh"
    info "recon_openclaw.sh marked as executable."
fi

echo ""
info "All tools installed successfully!"
echo ""
echo "  Add Go binaries to your PATH if not already:"
echo "  export PATH=\$PATH:\$HOME/go/bin"
echo ""
echo "  Then run:"
echo "  ./recon_openclaw.sh example.com"
echo "  ./recon_openclaw.sh --with-openclaw example.com"
