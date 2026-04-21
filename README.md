# 🦞⚡ recon_openclaw

Automated bug bounty reconnaissance pipeline that runs a full recon workflow and optionally launches **OpenClaw** for AI-assisted analysis of results.

---

## Features

- Subdomain enumeration (subfinder + assetfinder)
- Live host detection (httpx)
- Historical URL collection (gau + waybackurls)
- Crawling (katana)
- Port scanning (naabu + nmap)
- Technology detection (whatweb)
- Content discovery (ffuf + SecLists)
- Screenshot capture (gowitness)
- Vulnerability scanning (nuclei + nikto)
- Structured output with auto-generated markdown report
- Optional OpenClaw launch for analysis

---

## Installation

```bash
git clone https://github.com/yourname/recon_openclaw.git
cd recon_openclaw
sudo ./scripts/install_tools.sh
```

Make the main script executable:

```bash
chmod +x recon_openclaw.sh
```

---

## Usage

Basic scan:

```bash
./recon_openclaw.sh example.com
```

Scan and launch OpenClaw automatically at the end:

```bash
./recon_openclaw.sh --with-openclaw example.com
```

Log output to file:

```bash
./recon_openclaw.sh example.com | tee recon_run.log
```

---

## Output Structure

Each scan creates a timestamped folder:

```
recon_example.com_20260101_120000/
├── subdomains/
│   ├── subfinder.txt
│   ├── assetfinder.txt
│   └── all.txt
├── alive/
│   └── alive.txt
├── urls/
│   ├── gau.txt
│   ├── wayback.txt
│   ├── katana.txt
│   └── all_urls.txt
├── ports/
│   ├── naabu.txt
│   └── nmap.txt
├── technologies/
│   └── whatweb.txt
├── screenshots/
├── vulnerabilities/
│   ├── nuclei.txt
│   ├── ffuf_*.json
│   └── nikto_*.txt
└── report/
    └── report.md
```

---

## Tools Used

| Tool         | Purpose                   | Install                                          |
|--------------|---------------------------|--------------------------------------------------|
| subfinder    | Subdomain enumeration     | `go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest` |
| assetfinder  | Subdomain enumeration     | `go install github.com/tomnomnom/assetfinder@latest` |
| httpx        | Live host detection       | `go install github.com/projectdiscovery/httpx/cmd/httpx@latest` |
| gau          | Historical URLs           | `go install github.com/lc/gau/v2/cmd/gau@latest` |
| waybackurls  | Historical URLs           | `go install github.com/tomnomnom/waybackurls@latest` |
| katana       | Web crawling              | `go install github.com/projectdiscovery/katana/cmd/katana@latest` |
| naabu        | Port scanning             | `go install github.com/projectdiscovery/naabu/v2/cmd/naabu@latest` |
| nmap         | Port/service scanning     | `apt install nmap` |
| whatweb      | Technology detection      | `apt install whatweb` |
| ffuf         | Content discovery         | `apt install ffuf` |
| gowitness    | Screenshots               | `go install github.com/sensepost/gowitness@latest` |
| nuclei       | Vulnerability scanning    | `go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest` |
| nikto        | Vulnerability scanning    | `apt install nikto` |
| openclaw     | AI-assisted analysis      | Install separately |

---

## Quick Cheat Sheet

```bash
chmod +x recon_openclaw.sh
./recon_openclaw.sh example.com
./recon_openclaw.sh --with-openclaw example.com
./recon_openclaw.sh example.com | tee recon_run.log
```

---

## Disclaimer

This tool is intended for authorized security testing and bug bounty programs only. Always ensure you have explicit permission before scanning any target. Unauthorized use is illegal.

---

## Credits

Inspired by the recon workflow article by [ghostyjoe](https://medium.com/bug-bounty-hunting-a-comprehensive-guide-in).
