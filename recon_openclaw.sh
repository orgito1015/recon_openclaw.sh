#!/usr/bin/env bash
# =============================================================================
# recon_openclaw.sh
# Description : Automated bug bounty reconnaissance pipeline with optional
#               OpenClaw analysis launch on completion.
# Usage       : ./recon_openclaw.sh [OPTIONS] <target>
# Author      : ghostyjoe
# =============================================================================

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[+]${NC} $1"; }
step()  { echo -e "${YELLOW}[*]${NC} $1"; }
error() { echo -e "${RED}[-]${NC} $1"; }

# ─── Defaults ────────────────────────────────────────────────────────────────
USE_OPENCLAW=0
THREADS=50
OUTPUT_DIR=""
SKIP_STEPS=""
TARGET=""

# ─── Usage / Help ────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: ./recon_openclaw.sh [OPTIONS] <target>

OPTIONS:
  --help              Show this help message and exit
  --with-openclaw     Launch OpenClaw for AI-assisted analysis after scan
  --threads N         Number of threads for ffuf and naabu (default: 50)
  --output-dir DIR    Override the default timestamped output folder
  --skip STEPS        Comma-separated list of steps to skip
                      Steps: subdomains,alive,urls,crawl,ports,tech,ffuf,screenshots,vulns,report

EXAMPLES:
  ./recon_openclaw.sh example.com
  ./recon_openclaw.sh --with-openclaw example.com
  ./recon_openclaw.sh --threads 100 --skip screenshots,nikto example.com
  ./recon_openclaw.sh --output-dir my_recon example.com
EOF
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help)
            usage
            exit 0
            ;;
        --with-openclaw)
            USE_OPENCLAW=1
            shift
            ;;
        --threads)
            THREADS="$2"
            if ! [[ "$THREADS" =~ ^[0-9]+$ ]] || [[ "$THREADS" -eq 0 ]]; then
                error "--threads requires a positive integer, got: '$THREADS'"
                usage
                exit 1
            fi
            shift 2
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --skip)
            SKIP_STEPS="$2"
            shift 2
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            TARGET="$1"
            shift
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    error "No target specified."
    usage
    exit 1
fi

# ─── Skip Helper ─────────────────────────────────────────────────────────────
should_skip() {
    echo "$SKIP_STEPS" | tr ',' '\n' | grep -qx "$1"
}

count_lines() {
    local file="$1"
    [[ -s "$file" ]] && wc -l < "$file" || echo 0
}

safe_name() {
    printf '%s' "$1" | sed 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#[^A-Za-z0-9._-]#_#g'
}

# ─── Tool Check ──────────────────────────────────────────────────────────────
REQUIRED_TOOLS=(subfinder assetfinder httpx gau waybackurls katana naabu nmap whatweb ffuf gowitness nuclei nikto)
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -gt 0 ]]; then
    error "The following required tools are not installed or not in PATH:"
    for t in "${MISSING_TOOLS[@]}"; do
        error "  - $t"
    done
    error "Run: sudo ./scripts/install_tools.sh"
    exit 1
fi

# ─── Output Directory Setup ──────────────────────────────────────────────────
TS=$(date +"%Y%m%d_%H%M%S")
if [[ -n "$OUTPUT_DIR" ]]; then
    OUT="$OUTPUT_DIR"
else
    OUT="recon_${TARGET}_${TS}"
fi

mkdir -p "$OUT"/{subdomains,alive,urls,ports,technologies,screenshots,vulnerabilities,report} \
    || { error "Cannot create output directory '$OUT': permission denied or invalid path"; exit 1; }

# ─── Error Log ───────────────────────────────────────────────────────────────
ERROR_LOG="$OUT/report/errors.log"

log_error() {
    local step_name="$1"
    local msg="$2"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [STEP: $step_name] $msg" >> "$ERROR_LOG"
    error "$step_name: $msg"
}

# ─── Timer Helpers ───────────────────────────────────────────────────────────
STEP_START=0

start_timer() { STEP_START=$(date +%s); }
elapsed()     { echo $(( $(date +%s) - STEP_START )); }

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo "============================================="
echo "  Bug Bounty Recon - Starting scan"
echo "  Target  : $TARGET"
echo "  Output  : $OUT"
echo "  Threads : $THREADS"
[[ -n "$SKIP_STEPS" ]] && echo "  Skipping: $SKIP_STEPS"
echo "============================================="
echo ""

SCAN_START=$(date +%s)

# ─── 1. Subdomain Enumeration ────────────────────────────────────────────────
if ! should_skip "subdomains"; then
    step "Step 1/10 - Subdomain enumeration..."
    start_timer
    subfinder -d "$TARGET" -silent > "$OUT/subdomains/subfinder.txt" 2>>"$ERROR_LOG" \
        || log_error "subfinder" "subfinder failed"
    assetfinder --subs-only "$TARGET" > "$OUT/subdomains/assetfinder.txt" 2>>"$ERROR_LOG" \
        || log_error "assetfinder" "assetfinder failed"
    LC_ALL=C sort -u "$OUT/subdomains/"*.txt > "$OUT/subdomains/all.txt"
    info "Subdomains saved to $OUT/subdomains/all.txt ($(count_lines "$OUT/subdomains/all.txt") found) [$(elapsed)s]"
else
    step "Step 1/10 - Subdomain enumeration... [SKIPPED]"
fi

# ─── 2. Live Host Detection ──────────────────────────────────────────────────
if ! should_skip "alive"; then
    step "Step 2/10 - Live host detection..."
    start_timer
    if [[ -s "$OUT/subdomains/all.txt" ]]; then
        httpx -l "$OUT/subdomains/all.txt" -silent -title -tech-detect -o "$OUT/alive/alive.txt" 2>>"$ERROR_LOG" \
            || log_error "httpx" "httpx failed"
        info "Live hosts saved to $OUT/alive/alive.txt ($(count_lines "$OUT/alive/alive.txt") found) [$(elapsed)s]"
    else
        : > "$OUT/alive/alive.txt"
        info "No subdomains found; skipping live host detection [$(elapsed)s]"
    fi
else
    step "Step 2/10 - Live host detection... [SKIPPED]"
fi

# ─── 3. URL Collection ───────────────────────────────────────────────────────
if ! should_skip "urls"; then
    step "Step 3/10 - URL collection..."
    start_timer
    gau --subs "$TARGET" > "$OUT/urls/gau.txt" 2>>"$ERROR_LOG" \
        || log_error "gau" "gau failed"
    waybackurls "$TARGET" > "$OUT/urls/wayback.txt" 2>>"$ERROR_LOG" \
        || log_error "waybackurls" "waybackurls failed"
    LC_ALL=C sort -u "$OUT/urls/"*.txt > "$OUT/urls/all_urls.txt"
    info "URLs saved to $OUT/urls/all_urls.txt ($(count_lines "$OUT/urls/all_urls.txt") collected) [$(elapsed)s]"
else
    step "Step 3/10 - URL collection... [SKIPPED]"
fi

# ─── 4. Crawling ─────────────────────────────────────────────────────────────
if ! should_skip "crawl"; then
    step "Step 4/10 - Crawling with Katana..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        katana -list "$OUT/alive/alive.txt" -o "$OUT/urls/katana.txt" 2>>"$ERROR_LOG" \
            || log_error "katana" "katana failed"
        info "Crawl results saved to $OUT/urls/katana.txt [$(elapsed)s]"
    else
        : > "$OUT/urls/katana.txt"
        info "No live hosts found; skipping crawling [$(elapsed)s]"
    fi
else
    step "Step 4/10 - Crawling with Katana... [SKIPPED]"
fi

# ─── 5. Port Scanning ────────────────────────────────────────────────────────
if ! should_skip "ports"; then
    step "Step 5/10 - Port scanning..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        naabu -list "$OUT/alive/alive.txt" -c "$THREADS" -o "$OUT/ports/naabu.txt" 2>>"$ERROR_LOG" \
            || log_error "naabu" "naabu failed"
        nmap -iL "$OUT/alive/alive.txt" -oN "$OUT/ports/nmap.txt" 2>>"$ERROR_LOG" \
            || log_error "nmap" "nmap failed"
        info "Port scan results saved to $OUT/ports/ [$(elapsed)s]"
    else
        : > "$OUT/ports/naabu.txt"
        : > "$OUT/ports/nmap.txt"
        info "No live hosts found; skipping port scanning [$(elapsed)s]"
    fi
else
    step "Step 5/10 - Port scanning... [SKIPPED]"
fi

# ─── 6. Technology Detection ─────────────────────────────────────────────────
if ! should_skip "tech"; then
    step "Step 6/10 - Technology detection..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        whatweb -i "$OUT/alive/alive.txt" > "$OUT/technologies/whatweb.txt" 2>>"$ERROR_LOG" \
            || log_error "whatweb" "whatweb failed"
        info "Technology info saved to $OUT/technologies/whatweb.txt [$(elapsed)s]"
    else
        : > "$OUT/technologies/whatweb.txt"
        info "No live hosts found; skipping technology detection [$(elapsed)s]"
    fi
else
    step "Step 6/10 - Technology detection... [SKIPPED]"
fi

# ─── 7. Content Discovery ────────────────────────────────────────────────────
if ! should_skip "ffuf"; then
    step "Step 7/10 - Content discovery with ffuf..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            ffuf -u "$url/FUZZ" \
                -w /usr/share/seclists/Discovery/Web-Content/directory-list-2.3-medium.txt \
                -o "$OUT/vulnerabilities/ffuf_$(safe_name "$url").json" \
                -of json \
                -mc 200,301,302,403 \
                -t "$THREADS" \
                -s 2>>"$ERROR_LOG" || log_error "ffuf" "ffuf failed for $url"
        done < <(LC_ALL=C sort -u "$OUT/alive/alive.txt")
        info "Content discovery results saved to $OUT/vulnerabilities/ [$(elapsed)s]"
    else
        info "No live hosts found; skipping content discovery [$(elapsed)s]"
    fi
else
    step "Step 7/10 - Content discovery with ffuf... [SKIPPED]"
fi

# ─── 8. Screenshots ──────────────────────────────────────────────────────────
if ! should_skip "screenshots"; then
    step "Step 8/10 - Capturing screenshots..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        gowitness file -f "$OUT/alive/alive.txt" --destination "$OUT/screenshots" 2>>"$ERROR_LOG" \
            || log_error "gowitness" "gowitness failed"
        info "Screenshots saved to $OUT/screenshots/ [$(elapsed)s]"
    else
        info "No live hosts found; skipping screenshots [$(elapsed)s]"
    fi
else
    step "Step 8/10 - Capturing screenshots... [SKIPPED]"
fi

# ─── 9. Vulnerability Scanning ───────────────────────────────────────────────
if ! should_skip "vulns"; then
    step "Step 9/10 - Vulnerability scanning..."
    start_timer
    if [[ -s "$OUT/alive/alive.txt" ]]; then
        nuclei -l "$OUT/alive/alive.txt" -o "$OUT/vulnerabilities/nuclei.txt" 2>>"$ERROR_LOG" \
            || log_error "nuclei" "nuclei failed"
        while IFS= read -r url; do
            [[ -z "$url" ]] && continue
            nikto -h "$url" -output "$OUT/vulnerabilities/nikto_$(safe_name "$url").txt" 2>>"$ERROR_LOG" \
                || log_error "nikto" "nikto failed for $url"
        done < <(LC_ALL=C sort -u "$OUT/alive/alive.txt")
        info "Vulnerability results saved to $OUT/vulnerabilities/ [$(elapsed)s]"
    else
        : > "$OUT/vulnerabilities/nuclei.txt"
        info "No live hosts found; skipping vulnerability scans [$(elapsed)s]"
    fi
else
    step "Step 9/10 - Vulnerability scanning... [SKIPPED]"
fi

# ─── 10. Report Generation ───────────────────────────────────────────────────
if ! should_skip "report"; then
    step "Step 10/10 - Generating report..."
    start_timer

    SUBDOMAIN_COUNT=$(count_lines "$OUT/subdomains/all.txt")
    ALIVE_COUNT=$(count_lines "$OUT/alive/alive.txt")
    URL_COUNT=$(count_lines "$OUT/urls/all_urls.txt")
    NUCLEI_COUNT=$(count_lines "$OUT/vulnerabilities/nuclei.txt")

    {
        echo "# Bug Bounty Recon Report"
        echo ""
        echo "**Target:** $TARGET"
        echo "**Date:** $TS"
        echo ""
        echo "## Summary"
        echo ""
        echo "| Category       | File                                |"
        echo "|----------------|-------------------------------------|"
        echo "| Subdomains     | subdomains/all.txt                  |"
        echo "| Live Hosts     | alive/alive.txt                     |"
        echo "| URLs           | urls/all_urls.txt                   |"
        echo "| Ports (naabu)  | ports/naabu.txt                     |"
        echo "| Ports (nmap)   | ports/nmap.txt                      |"
        echo "| Technologies   | technologies/whatweb.txt            |"
        echo "| Screenshots    | screenshots/                        |"
        echo "| Nuclei         | vulnerabilities/nuclei.txt          |"
        echo ""
        echo "## Stats"
        echo ""
        echo "- Subdomains found : $SUBDOMAIN_COUNT"
        echo "- Live hosts       : $ALIVE_COUNT"
        echo "- Total URLs       : $URL_COUNT"
        echo "- Nuclei findings  : $NUCLEI_COUNT"
    } > "$OUT/report/report.md"

    # JSON summary
    cat > "$OUT/report/summary.json" <<JSON
{
  "target": "$TARGET",
  "timestamp": "$TS",
  "subdomain_count": ${SUBDOMAIN_COUNT:-0},
  "live_host_count": ${ALIVE_COUNT:-0},
  "url_count": ${URL_COUNT:-0},
  "nuclei_finding_count": ${NUCLEI_COUNT:-0}
}
JSON

    info "Report saved to $OUT/report/report.md [$(elapsed)s]"
    info "Summary saved to $OUT/report/summary.json"
else
    step "Step 10/10 - Generating report... [SKIPPED]"
fi

# ─── OpenClaw Launch ─────────────────────────────────────────────────────────
if [[ $USE_OPENCLAW -eq 1 ]]; then
    echo ""
    step "Launching OpenClaw for analysis..."
    openclaw 2>>"$ERROR_LOG" || log_error "openclaw" "openclaw failed"
fi

SCAN_END=$(date +%s)
TOTAL_ELAPSED=$(( SCAN_END - SCAN_START ))

echo ""
echo "============================================="
info "Recon complete. Results saved in $OUT"
printf "  Total time : %dm %ds\n" $(( TOTAL_ELAPSED / 60 )) $(( TOTAL_ELAPSED % 60 ))
echo "============================================="
