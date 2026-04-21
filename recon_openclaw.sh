#!/usr/bin/env bash
# =============================================================================
# recon_openclaw.sh
# Description : Automated bug bounty reconnaissance pipeline with optional
#               OpenClaw analysis launch on completion.
# Usage       : ./recon_openclaw.sh example.com
#               ./recon_openclaw.sh --with-openclaw example.com
# Author      : ghostyjoe
# =============================================================================

set -e

# ─── Argument Parsing ────────────────────────────────────────────────────────
USE_OPENCLAW=0

if [[ "$1" == "--with-openclaw" ]]; then
    USE_OPENCLAW=1
    TARGET=$2
else
    TARGET=$1
fi

if [[ -z "$TARGET" ]]; then
    echo "Usage:"
    echo "  ./recon_openclaw.sh example.com"
    echo "  ./recon_openclaw.sh --with-openclaw example.com"
    exit 1
fi

# ─── Output Directory Setup ──────────────────────────────────────────────────
TS=$(date +"%Y%m%d_%H%M%S")
OUT="recon_${TARGET}_${TS}"

mkdir -p "$OUT"/{subdomains,alive,urls,ports,technologies,screenshots,vulnerabilities,report}

echo "Starting recon for $TARGET"
echo ""
echo "============================================="
echo "  Bug Bounty Recon - Starting scan"
echo "  Target : $TARGET"
echo "  Output : $OUT"
echo "============================================="
echo ""

# ─── 1. Subdomain Enumeration ────────────────────────────────────────────────
echo "[*] Step 1/10 - Subdomain enumeration..."
subfinder -d "$TARGET" -silent > "$OUT/subdomains/subfinder.txt"
assetfinder --subs-only "$TARGET" > "$OUT/subdomains/assetfinder.txt"
cat "$OUT/subdomains/"*.txt | sort -u > "$OUT/subdomains/all.txt"
echo "[+] Subdomains saved to $OUT/subdomains/all.txt"

# ─── 2. Live Host Detection ──────────────────────────────────────────────────
echo "[*] Step 2/10 - Live host detection..."
httpx -l "$OUT/subdomains/all.txt" -silent -title -tech-detect -o "$OUT/alive/alive.txt"
echo "[+] Live hosts saved to $OUT/alive/alive.txt"

# ─── 3. URL Collection ───────────────────────────────────────────────────────
echo "[*] Step 3/10 - URL collection..."
gau --subs "$TARGET" > "$OUT/urls/gau.txt"
waybackurls "$TARGET" > "$OUT/urls/wayback.txt"
cat "$OUT/urls/"*.txt | sort -u > "$OUT/urls/all_urls.txt"
echo "[+] URLs saved to $OUT/urls/all_urls.txt"

# ─── 4. Crawling ─────────────────────────────────────────────────────────────
echo "[*] Step 4/10 - Crawling with Katana..."
katana -list "$OUT/alive/alive.txt" -o "$OUT/urls/katana.txt"
echo "[+] Crawl results saved to $OUT/urls/katana.txt"

# ─── 5. Port Scanning ────────────────────────────────────────────────────────
echo "[*] Step 5/10 - Port scanning..."
naabu -list "$OUT/alive/alive.txt" -o "$OUT/ports/naabu.txt"
nmap -iL "$OUT/alive/alive.txt" -oN "$OUT/ports/nmap.txt"
echo "[+] Port scan results saved to $OUT/ports/"

# ─── 6. Technology Detection ─────────────────────────────────────────────────
echo "[*] Step 6/10 - Technology detection..."
whatweb -i "$OUT/alive/alive.txt" > "$OUT/technologies/whatweb.txt"
echo "[+] Technology info saved to $OUT/technologies/whatweb.txt"

# ─── 7. Content Discovery ────────────────────────────────────────────────────
echo "[*] Step 7/10 - Content discovery with ffuf..."
while read -r url; do
    safe_name=$(echo "$url" | tr '/:' '__')
    ffuf -u "$url/FUZZ" \
        -w /usr/share/seclists/Discovery/Web-Content/directory-list-2.3-medium.txt \
        -o "$OUT/vulnerabilities/ffuf_${safe_name}.json" \
        -of json \
        -mc 200,301,302,403 \
        -t 50 \
        -s
done < "$OUT/alive/alive.txt"
echo "[+] Content discovery results saved to $OUT/vulnerabilities/"

# ─── 8. Screenshots ──────────────────────────────────────────────────────────
echo "[*] Step 8/10 - Capturing screenshots..."
gowitness file -f "$OUT/alive/alive.txt" --destination "$OUT/screenshots"
echo "[+] Screenshots saved to $OUT/screenshots/"

# ─── 9. Vulnerability Scanning ───────────────────────────────────────────────
echo "[*] Step 9/10 - Vulnerability scanning..."
nuclei -l "$OUT/alive/alive.txt" -o "$OUT/vulnerabilities/nuclei.txt"

while read -r url; do
    safe_name=$(echo "$url" | tr '/:' '__')
    nikto -h "$url" -output "$OUT/vulnerabilities/nikto_${safe_name}.txt"
done < "$OUT/alive/alive.txt"
echo "[+] Vulnerability results saved to $OUT/vulnerabilities/"

# ─── 10. Report Generation ───────────────────────────────────────────────────
echo "[*] Step 10/10 - Generating report..."
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
    echo "- Subdomains found : $(wc -l < "$OUT/subdomains/all.txt" 2>/dev/null || echo 0)"
    echo "- Live hosts       : $(wc -l < "$OUT/alive/alive.txt" 2>/dev/null || echo 0)"
    echo "- Total URLs       : $(wc -l < "$OUT/urls/all_urls.txt" 2>/dev/null || echo 0)"
} > "$OUT/report/report.md"
echo "[+] Report saved to $OUT/report/report.md"

# ─── OpenClaw Launch ─────────────────────────────────────────────────────────
if [[ $USE_OPENCLAW -eq 1 ]]; then
    echo ""
    echo "[*] Launching OpenClaw for analysis..."
    openclaw
fi

echo ""
echo "============================================="
echo "  Recon complete. Results saved in $OUT"
echo "============================================="
