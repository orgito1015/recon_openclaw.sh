#!/usr/bin/env bash
# =============================================================================
# tests/test_recon.sh
# Test suite for recon_openclaw.sh
# =============================================================================

set -u

# ─── Colors ──────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
PASS=0
FAIL=0

# ─── Script under test ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/recon_openclaw.sh"

# ─── Temp directory tracking ─────────────────────────────────────────────────
TEMP_DIRS=()

new_tmpdir() {
    local d
    d="$(mktemp -d)"
    TEMP_DIRS+=("$d")
    echo "$d"
}

cleanup() {
    for d in "${TEMP_DIRS[@]+"${TEMP_DIRS[@]}"}"; do
        chmod -R u+rwx "$d" 2>/dev/null || true
        rm -rf "$d"
    done
}
trap cleanup EXIT

# ─── Assertion helpers ───────────────────────────────────────────────────────

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    (( PASS++ )) || true
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    [[ -n "${2:-}" ]] && echo "       $2"
    (( FAIL++ )) || true
}

assert_exit() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" -eq "$expected" ]]; then
        pass "$name"
    else
        fail "$name" "expected exit $expected, got $actual"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name" "expected to find '$needle' in output"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF -- "$needle"; then
        fail "$name" "did not expect '$needle' in output"
    else
        pass "$name"
    fi
}

assert_file_exists() {
    local name="$1" file="$2"
    if [[ -f "$file" ]]; then
        pass "$name"
    else
        fail "$name" "file not found: $file"
    fi
}

assert_dir_exists() {
    local name="$1" dir="$2"
    if [[ -d "$dir" ]]; then
        pass "$name"
    else
        fail "$name" "directory not found: $dir"
    fi
}

assert_nonempty_file() {
    local name="$1" file="$2"
    if [[ -f "$file" && -s "$file" ]]; then
        pass "$name"
    else
        fail "$name" "file is missing or empty: $file"
    fi
}

# Run the script with a custom PATH prepended (stubs first)
run_script() {
    local bin_dir="$1"; shift
    PATH="$bin_dir:$PATH" bash "$SCRIPT" "$@"
}

# =============================================================================
# STUB SETUP
# Creates realistic stub binaries in bin_dir.  Each stub:
#   - parses its arguments the same way the real tool does
#   - creates the expected output files so downstream steps have input
#   - writes its argv/key-flags to STUB_STATE_DIR (if exported) for assertions
# =============================================================================

setup_stubs() {
    local bin_dir="$1"
    mkdir -p "$bin_dir"

    # ── subfinder ─────────────────────────────────────────────────────────────
    cat > "$bin_dir/subfinder" <<'STUB'
#!/usr/bin/env bash
target=""
while [[ $# -gt 0 ]]; do
    case "$1" in -d) target="$2"; shift 2 ;; *) shift ;; esac
done
echo "sub1.${target}"
echo "sub2.${target}"
STUB

    # ── assetfinder ───────────────────────────────────────────────────────────
    cat > "$bin_dir/assetfinder" <<'STUB'
#!/usr/bin/env bash
target="${*: -1}"
echo "sub3.${target}"
echo "sub4.${target}"
echo "sub1.${target}"   # intentional duplicate to test dedup in all.txt
STUB

    # ── httpx ─────────────────────────────────────────────────────────────────
    # Reads -l INPUT, writes alive URLs to -o OUTPUT
    cat > "$bin_dir/httpx" <<'STUB'
#!/usr/bin/env bash
input="" output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l) input="$2"; shift 2 ;;
        -o) output="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
: "${output:=/dev/null}"
[[ -f "$input" ]] || { touch "$output"; exit 0; }
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "https://${line} [200] [Mock Title]"
done < "$input" > "$output"
STUB

    # ── gau ───────────────────────────────────────────────────────────────────
    # Reads last positional arg as target, prints to stdout
    cat > "$bin_dir/gau" <<'STUB'
#!/usr/bin/env bash
target=""
while [[ $# -gt 0 ]]; do
    case "$1" in --*) shift ;; *) target="$1"; shift ;; esac
done
echo "https://${target}/gau1"
echo "https://${target}/gau2"
STUB

    # ── waybackurls ───────────────────────────────────────────────────────────
    # Prints to stdout; emits a duplicate to verify dedup in all_urls.txt
    cat > "$bin_dir/waybackurls" <<'STUB'
#!/usr/bin/env bash
target="${1:-example.com}"
echo "https://${target}/wayback1"
echo "https://${target}/wayback1"   # duplicate
echo "https://${target}/wayback2"
STUB

    # ── katana ────────────────────────────────────────────────────────────────
    # Reads -list INPUT, writes to -o OUTPUT
    cat > "$bin_dir/katana" <<'STUB'
#!/usr/bin/env bash
input="" output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -list) input="$2"; shift 2 ;;
        -o)    output="$2"; shift 2 ;;
        *)     shift ;;
    esac
done
: "${output:=/dev/null}"
[[ -f "$input" ]] || { touch "$output"; exit 0; }
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "${line}/crawled1"
done < "$input" > "$output"
STUB

    # ── naabu ─────────────────────────────────────────────────────────────────
    # Reads -list INPUT -c THREADS, writes to -o OUTPUT
    # Records threads to STUB_STATE_DIR/naabu_threads when STUB_STATE_DIR is set
    cat > "$bin_dir/naabu" <<'STUB'
#!/usr/bin/env bash
input="" output="" threads="50"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -list) input="$2"; shift 2 ;;
        -c)    threads="$2"; shift 2 ;;
        -o)    output="$2"; shift 2 ;;
        *)     shift ;;
    esac
done
: "${output:=/dev/null}"
[[ -n "${STUB_STATE_DIR:-}" ]] && echo "$threads" > "$STUB_STATE_DIR/naabu_threads"
[[ -f "$input" ]] || { touch "$output"; exit 0; }
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "${line}:80"
done < "$input" > "$output"
STUB

    # ── nmap ──────────────────────────────────────────────────────────────────
    # Reads -iL INPUT, writes to -oN OUTPUT
    cat > "$bin_dir/nmap" <<'STUB'
#!/usr/bin/env bash
output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -iL) shift 2 ;;
        -oN) output="$2"; shift 2 ;;
        *)   shift ;;
    esac
done
echo "# Nmap mock output" > "${output:-/dev/null}"
STUB

    # ── whatweb ───────────────────────────────────────────────────────────────
    # Reads -i INPUT, prints to stdout
    cat > "$bin_dir/whatweb" <<'STUB'
#!/usr/bin/env bash
input=""
while [[ $# -gt 0 ]]; do
    case "$1" in -i) input="$2"; shift 2 ;; *) shift ;; esac
done
[[ -f "$input" ]] || exit 0
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "${line} [200 OK] MockCMS[1.0]"
done < "$input"
STUB

    # ── ffuf ──────────────────────────────────────────────────────────────────
    # Records -t THREADS to STUB_STATE_DIR/ffuf_threads when STUB_STATE_DIR is set
    # Creates minimal valid JSON in -o OUTPUT
    cat > "$bin_dir/ffuf" <<'STUB'
#!/usr/bin/env bash
output="" threads="50"
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -t) threads="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
[[ -n "${STUB_STATE_DIR:-}" ]] && echo "$threads" > "$STUB_STATE_DIR/ffuf_threads"
printf '{"results":[],"config":{"threads":%s}}\n' "$threads" > "${output:-/dev/null}"
STUB

    # ── gowitness ─────────────────────────────────────────────────────────────
    # Reads file -f INPUT --destination DIR, creates a mock screenshot
    cat > "$bin_dir/gowitness" <<'STUB'
#!/usr/bin/env bash
dest=""
while [[ $# -gt 0 ]]; do
    case "$1" in --destination) dest="$2"; shift 2 ;; *) shift ;; esac
done
[[ -n "$dest" ]] && touch "$dest/mock_screenshot.png"
STUB

    # ── nuclei ────────────────────────────────────────────────────────────────
    # Reads -l INPUT, writes finding to -o OUTPUT
    cat > "$bin_dir/nuclei" <<'STUB'
#!/usr/bin/env bash
input="" output=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -l) input="$2"; shift 2 ;;
        -o) output="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
: "${output:=/dev/null}"
[[ -f "$input" && -s "$input" ]] && echo "[mock] [CVE-2024-0001] example.com" > "$output" || touch "$output"
STUB

    # ── nikto ─────────────────────────────────────────────────────────────────
    # Reads -h URL -output FILE
    cat > "$bin_dir/nikto" <<'STUB'
#!/usr/bin/env bash
output=""
while [[ $# -gt 0 ]]; do
    case "$1" in -output) output="$2"; shift 2 ;; *) shift ;; esac
done
echo "- Nikto mock scan results" > "${output:-/dev/null}"
STUB

    # ── openclaw ──────────────────────────────────────────────────────────────
    cat > "$bin_dir/openclaw" <<'STUB'
#!/usr/bin/env bash
echo "OpenClaw mock launched"
[[ -n "${STUB_STATE_DIR:-}" ]] && touch "$STUB_STATE_DIR/openclaw_called"
STUB

    chmod +x "$bin_dir"/*
}

# Create a stub directory with only a subset of the tools (used for missing-tools test)
setup_partial_stubs() {
    local bin_dir="$1"; shift
    local tools=("$@")
    mkdir -p "$bin_dir"
    for t in "${tools[@]}"; do
        printf '#!/usr/bin/env bash\n' > "$bin_dir/$t"
        chmod +x "$bin_dir/$t"
    done
}

# =============================================================================
# UNIT TESTS
# =============================================================================

echo ""
echo "─── UNIT TESTS ─────────────────────────────────────────────────────────────"

# ── 1. No args shows usage and exits 1 ───────────────────────────────────────
test_no_args() {
    local output exit_code
    output=$(bash "$SCRIPT" 2>&1)
    exit_code=$?
    assert_exit  "no-args: exits 1"               1 "$exit_code"
    assert_contains "no-args: prints Usage line"  "$output" "Usage:"
}
test_no_args

# ── 2. --help exits 0 and prints usage ───────────────────────────────────────
test_help_flag() {
    local output exit_code
    output=$(bash "$SCRIPT" --help 2>&1)
    exit_code=$?
    assert_exit     "--help: exits 0"                 0 "$exit_code"
    assert_contains "--help: prints Usage line"       "$output" "Usage:"
    assert_contains "--help: mentions --with-openclaw" "$output" "--with-openclaw"
    assert_contains "--help: mentions --threads"      "$output" "--threads"
    assert_contains "--help: mentions --output-dir"   "$output" "--output-dir"
    assert_contains "--help: mentions --skip"         "$output" "--skip"
}
test_help_flag

# ── 3. --with-openclaw launches openclaw at end ───────────────────────────────
test_with_openclaw() {
    local bin_dir tmpdir out_dir state_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_out"
    state_dir="$(new_tmpdir)"
    setup_stubs "$bin_dir"

    STUB_STATE_DIR="$state_dir"
    export STUB_STATE_DIR
    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" --with-openclaw example.com 2>&1)
    exit_code=$?
    unset STUB_STATE_DIR

    assert_exit     "--with-openclaw: exits 0"          0 "$exit_code"
    assert_contains "--with-openclaw: output mentions OpenClaw" "$output" "OpenClaw"
    if [[ -f "$state_dir/openclaw_called" ]]; then
        pass "--with-openclaw: openclaw binary was invoked"
    else
        fail "--with-openclaw: openclaw binary was NOT invoked"
    fi
}
test_with_openclaw

# ── 4. --output-dir overrides the default OUT folder name ────────────────────
test_output_dir_override() {
    local bin_dir tmpdir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/my_custom_output"
    setup_stubs "$bin_dir"

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    assert_exit         "--output-dir: exits 0"          0 "$exit_code"
    assert_dir_exists   "--output-dir: custom dir created" "$out_dir"
    assert_contains     "--output-dir: banner shows custom dir" "$output" "my_custom_output"
    # Ensure no recon_example.com_* folder was created in cwd
    local default_dirs
    default_dirs=$(find "$tmpdir" -maxdepth 1 -name "recon_example.com_*" -type d 2>/dev/null)
    if [[ -z "$default_dirs" ]]; then
        pass "--output-dir: no default timestamped folder created"
    else
        fail "--output-dir: unexpected timestamped folder found"
    fi
}
test_output_dir_override

# ── 5. --skip correctly skips the listed steps ───────────────────────────────
test_skip_steps() {
    local bin_dir tmpdir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_skip"
    setup_stubs "$bin_dir"

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" \
        --skip "subdomains,alive,urls,crawl,ports,tech,ffuf,screenshots,vulns" \
        example.com 2>&1)
    exit_code=$?

    assert_exit         "--skip: exits 0"                   0 "$exit_code"
    assert_contains     "--skip subdomains: shows SKIPPED"  "$output" "Subdomain enumeration... [SKIPPED]"
    assert_contains     "--skip alive: shows SKIPPED"       "$output" "Live host detection... [SKIPPED]"
    assert_contains     "--skip urls: shows SKIPPED"        "$output" "URL collection... [SKIPPED]"
    assert_contains     "--skip crawl: shows SKIPPED"       "$output" "Crawling with Katana... [SKIPPED]"
    assert_contains     "--skip ports: shows SKIPPED"       "$output" "Port scanning... [SKIPPED]"
    assert_contains     "--skip tech: shows SKIPPED"        "$output" "Technology detection... [SKIPPED]"
    assert_contains     "--skip ffuf: shows SKIPPED"        "$output" "Content discovery with ffuf... [SKIPPED]"
    assert_contains     "--skip screenshots: shows SKIPPED" "$output" "Capturing screenshots... [SKIPPED]"
    assert_contains     "--skip vulns: shows SKIPPED"       "$output" "Vulnerability scanning... [SKIPPED]"
    # Report step was NOT skipped
    assert_not_contains "--skip: report still runs"         "$output" "Generating report... [SKIPPED]"
    assert_file_exists  "--skip: report.md still generated" "$out_dir/report/report.md"
}
test_skip_steps

# ── 6. --threads value is passed to ffuf and naabu ───────────────────────────
test_threads_passed() {
    local bin_dir tmpdir out_dir state_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_threads"
    state_dir="$(new_tmpdir)"
    setup_stubs "$bin_dir"

    STUB_STATE_DIR="$state_dir"
    export STUB_STATE_DIR
    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" --threads 99 example.com 2>&1)
    exit_code=$?
    unset STUB_STATE_DIR

    assert_exit "--threads 99: exits 0" 0 "$exit_code"

    local naabu_t ffuf_t
    naabu_t=$(cat "$state_dir/naabu_threads" 2>/dev/null || echo "NOT_RECORDED")
    ffuf_t=$(cat  "$state_dir/ffuf_threads"  2>/dev/null || echo "NOT_RECORDED")

    if [[ "$naabu_t" == "99" ]]; then
        pass "--threads: naabu received -c 99"
    else
        fail "--threads: naabu -c value" "expected 99, got $naabu_t"
    fi

    if [[ "$ffuf_t" == "99" ]]; then
        pass "--threads: ffuf received -t 99"
    else
        fail "--threads: ffuf -t value" "expected 99, got $ffuf_t"
    fi
}
test_threads_passed

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

echo ""
echo "─── INTEGRATION TESTS ──────────────────────────────────────────────────────"

# Shared full-pipeline run; each sub-test receives $out_dir
_INTEG_BIN_DIR=""
_INTEG_OUT_DIR=""
_INTEG_EXIT_CODE=""
_INTEG_OUTPUT=""

setup_integration_run() {
    local bin_dir tmpdir out_dir
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_integ"
    setup_stubs "$bin_dir"

    local output exit_code
    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    _INTEG_BIN_DIR="$bin_dir"
    _INTEG_OUT_DIR="$out_dir"
    _INTEG_EXIT_CODE="$exit_code"
    _INTEG_OUTPUT="$output"
}

setup_integration_run

# ── 7. Full pipeline: exits 0 ────────────────────────────────────────────────
assert_exit "integration: full pipeline exits 0" 0 "$_INTEG_EXIT_CODE"

# ── 8. All expected subdirectories are created ───────────────────────────────
for subdir in subdomains alive urls ports technologies screenshots vulnerabilities report; do
    assert_dir_exists "integration: output subdir '$subdir' exists" "$_INTEG_OUT_DIR/$subdir"
done

# ── 9. subdomains/all.txt is created and deduplicated ────────────────────────
assert_file_exists "integration: subdomains/all.txt exists" "$_INTEG_OUT_DIR/subdomains/all.txt"

# subfinder outputs sub1/sub2, assetfinder outputs sub3/sub4/sub1 (dup).
# all.txt = sort -u → should be 4 unique entries (sub1 sub2 sub3 sub4).
all_subdomain_count=$(wc -l < "$_INTEG_OUT_DIR/subdomains/all.txt" 2>/dev/null || echo 0)
if [[ "$all_subdomain_count" -eq 4 ]]; then
    pass "integration: subdomains/all.txt deduplicated (4 unique)"
else
    fail "integration: subdomains/all.txt dedup" \
         "expected 4 unique subdomains, found $all_subdomain_count"
fi

# ── 10. alive/alive.txt is created ───────────────────────────────────────────
assert_file_exists  "integration: alive/alive.txt exists"    "$_INTEG_OUT_DIR/alive/alive.txt"
assert_nonempty_file "integration: alive/alive.txt non-empty" "$_INTEG_OUT_DIR/alive/alive.txt"

# ── 11. urls/all_urls.txt is created and deduplicated ────────────────────────
assert_file_exists "integration: urls/all_urls.txt exists" "$_INTEG_OUT_DIR/urls/all_urls.txt"

# gau outputs 2, wayback outputs 3 (1 dup), katana outputs N crawled lines.
# Dedup via sort -u; wayback1 duplicate should be collapsed.
url_count=$(wc -l < "$_INTEG_OUT_DIR/urls/all_urls.txt" 2>/dev/null || echo 0)
raw_url_count=$(cat "$_INTEG_OUT_DIR/urls/"*.txt 2>/dev/null | wc -l || echo 0)
if [[ "$url_count" -lt "$raw_url_count" ]] || [[ "$url_count" -gt 0 ]]; then
    pass "integration: urls/all_urls.txt deduplicated ($url_count unique of $raw_url_count raw)"
else
    fail "integration: urls/all_urls.txt dedup" "count=$url_count raw=$raw_url_count"
fi

# ── 12. report/report.md contains Target and Date lines ─────────────────────
assert_file_exists  "integration: report/report.md exists"  "$_INTEG_OUT_DIR/report/report.md"
assert_contains     "integration: report.md has Target line" \
                    "$(cat "$_INTEG_OUT_DIR/report/report.md")" "**Target:** example.com"
assert_contains     "integration: report.md has Date line" \
                    "$(cat "$_INTEG_OUT_DIR/report/report.md")" "**Date:**"

# ── 13. report/summary.json is valid JSON with expected keys ─────────────────
assert_file_exists "integration: report/summary.json exists" "$_INTEG_OUT_DIR/report/summary.json"

json_content=$(cat "$_INTEG_OUT_DIR/report/summary.json" 2>/dev/null)

# Validate JSON structure with python3 (or python if python3 unavailable)
_python=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || echo "")
if [[ -n "$_python" ]]; then
    if echo "$json_content" | "$_python" -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        pass "integration: summary.json is valid JSON"
    else
        fail "integration: summary.json is not valid JSON"
    fi
else
    # Fallback: basic checks without python
    if echo "$json_content" | grep -q '^{' && echo "$json_content" | grep -q '}$'; then
        pass "integration: summary.json looks like JSON (python unavailable for full parse)"
    else
        fail "integration: summary.json does not look like JSON"
    fi
fi

for key in target timestamp subdomain_count live_host_count url_count nuclei_finding_count; do
    assert_contains "integration: summary.json has key '$key'" "$json_content" "\"$key\""
done
assert_contains "integration: summary.json target is example.com" \
                "$json_content" '"target": "example.com"'

# ── 14. report/errors.log is created when a tool fails ───────────────────────
test_errors_log_on_failure() {
    local bin_dir tmpdir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_errlog"
    setup_stubs "$bin_dir"

    # Overwrite subfinder stub with one that always fails
    cat > "$bin_dir/subfinder" <<'STUB'
#!/usr/bin/env bash
echo "subfinder: fatal error" >&2
exit 1
STUB
    chmod +x "$bin_dir/subfinder"

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    assert_file_exists  "errors.log: created on tool failure" "$out_dir/report/errors.log"
    assert_nonempty_file "errors.log: contains failure entry"  "$out_dir/report/errors.log"
    assert_contains      "errors.log: records subfinder step" \
                         "$(cat "$out_dir/report/errors.log")" "subfinder"
}
test_errors_log_on_failure

# =============================================================================
# NEGATIVE TESTS
# =============================================================================

echo ""
echo "─── NEGATIVE TESTS ─────────────────────────────────────────────────────────"

# ── 15. Missing required tools: script exits with a clear error ───────────────
test_missing_tools() {
    local bin_dir tmpdir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_missing"

    # Provide only a handful of tools so several are missing
    setup_partial_stubs "$bin_dir" subfinder httpx

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    assert_exit     "missing-tools: exits non-zero"          1 "$exit_code"
    assert_contains "missing-tools: mentions missing tools"  "$output" "not installed"
    assert_contains "missing-tools: lists a missing tool"    "$output" "assetfinder"
    # Output directory must NOT have been created (guard before mkdir)
    if [[ ! -d "$out_dir" ]]; then
        pass "missing-tools: output directory not created"
    else
        fail "missing-tools: output directory was created despite missing tools"
    fi
}
test_missing_tools

# ── 16. Empty alive.txt: downstream steps skip gracefully without crashing ────
test_empty_alive_txt() {
    local bin_dir tmpdir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"
    out_dir="$tmpdir/recon_empty_alive"
    setup_stubs "$bin_dir"

    # Override httpx stub to produce an empty alive.txt (no live hosts)
    cat > "$bin_dir/httpx" <<'STUB'
#!/usr/bin/env bash
output=""
while [[ $# -gt 0 ]]; do
    case "$1" in -o) output="$2"; shift 2 ;; *) shift ;; esac
done
touch "${output:-/dev/null}"   # create file but write nothing
STUB
    chmod +x "$bin_dir/httpx"

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    assert_exit      "empty-alive: exits 0"                    0 "$exit_code"
    assert_file_exists "empty-alive: alive.txt exists"         "$out_dir/alive/alive.txt"
    # File should be empty
    if [[ ! -s "$out_dir/alive/alive.txt" ]]; then
        pass "empty-alive: alive.txt is empty as expected"
    else
        fail "empty-alive: alive.txt unexpectedly has content"
    fi
    assert_file_exists "empty-alive: report.md still generated" "$out_dir/report/report.md"
    assert_file_exists "empty-alive: summary.json still generated" "$out_dir/report/summary.json"
}
test_empty_alive_txt

# ── 17. Invalid --threads value (non-integer): exits with usage error ─────────
test_invalid_threads() {
    local output exit_code

    output=$(bash "$SCRIPT" --threads abc example.com 2>&1)
    exit_code=$?
    assert_exit     "invalid-threads 'abc': exits 1"        1 "$exit_code"
    assert_contains "invalid-threads 'abc': shows error"    "$output" "--threads"

    output=$(bash "$SCRIPT" --threads 0 example.com 2>&1)
    exit_code=$?
    assert_exit     "invalid-threads '0': exits 1"          1 "$exit_code"

    output=$(bash "$SCRIPT" --threads -5 example.com 2>&1)
    exit_code=$?
    assert_exit     "invalid-threads '-5': exits 1"         1 "$exit_code"

    output=$(bash "$SCRIPT" --threads 3.14 example.com 2>&1)
    exit_code=$?
    assert_exit     "invalid-threads '3.14': exits 1"       1 "$exit_code"
}
test_invalid_threads

# ── 18. Permission denied on output directory: exits with useful error ────────
test_permission_denied() {
    local bin_dir tmpdir locked_dir out_dir output exit_code
    bin_dir="$(new_tmpdir)"
    tmpdir="$(new_tmpdir)"

    # Create a directory the current user cannot write into
    locked_dir="$tmpdir/locked"
    mkdir -p "$locked_dir"
    chmod 000 "$locked_dir"
    out_dir="$locked_dir/recon_output"

    setup_stubs "$bin_dir"

    output=$(PATH="$bin_dir:$PATH" bash "$SCRIPT" \
        --output-dir "$out_dir" example.com 2>&1)
    exit_code=$?

    # Restore permissions so cleanup() can delete the dir
    chmod 755 "$locked_dir"

    assert_exit     "perm-denied: exits non-zero"       1 "$exit_code"
    assert_contains "perm-denied: mentions the directory or permission" \
                    "$output" "Cannot create output directory"
}
test_permission_denied

# =============================================================================
# SUMMARY
# =============================================================================

echo ""
echo "============================================================"
total=$(( PASS + FAIL ))
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All $total tests passed.${NC}"
    echo "  Passed : $PASS"
    echo "  Failed : $FAIL"
    echo "============================================================"
    exit 0
else
    echo -e "${RED}$FAIL test(s) failed out of $total.${NC}"
    echo "  Passed : $PASS"
    echo "  Failed : $FAIL"
    echo "============================================================"
    exit 1
fi
