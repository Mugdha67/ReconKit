# ReconKit

Reconnaissance automation for **Kali Linux**, built for CTFs, labs and authorised pentests.
One Bash script wraps ~35 well-known tools, installs whatever is missing, and saves every result in a tidy per-target folder with a Markdown summary.

> **Legal / ethical use only.** Run ReconKit only against systems you own or have explicit permission to test (CTF scope, home lab, bug-bounty scope, signed engagement). You are responsible for how you use it.

## Quick start

```bash
git clone https://github.com/<you>/reconkit.git
cd reconkit
chmod +x reconkit.sh

./reconkit.sh install          # installs every tool (apt first, Go/Cargo/gem fallbacks)
./reconkit.sh                  # interactive menu
./reconkit.sh scan -t 10.10.11.5 -m network
```

Optional: make it available everywhere with `sudo ln -s "$PWD/reconkit.sh" /usr/local/bin/reconkit`.

If you skip `install`, the first `scan` detects missing tools and offers to install them for you.

## Commands

| Command | What it does |
|---|---|
| `reconkit.sh` | Interactive menu |
| `install [--core] [-y]` | Install all tools (`--core` skips Wireshark, Maltego, SpiderFoot, SecLists) |
| `check` | Show which tools are installed |
| `scan -t TARGET [options]` | Run a recon scan (modes below) |
| `user USERNAME` | Username OSINT with Sherlock |
| `social "TERM"` | Social-Searcher API lookup |
| `exif PATH` | ExifTool metadata for a file or folder (flags GPS data and flag-like strings) |
| `pcap FILE [--gui]` | TShark analysis: protocols, conversations, DNS, HTTP, HTTP objects, login hints, flag-like strings |
| `capture [-i IF] [-d SEC] [-f "BPF"]` | Capture with tcpdump (auto-picks `tun0` if your VPN is up) |
| `gui maltego\|wireshark [file]\|spiderfoot\|nessus` | Launch GUI tools |

### Scan modes

| Mode | Pipeline |
|---|---|
| `quick` | whois → fast nmap → WhatWeb, wafw00f, headers, robots.txt |
| `network` | RustScan/Masscan/Nmap port discovery → `nmap -sC -sV` → Searchsploit → SMB (enum4linux-ng, smbclient) and FTP anonymous checks |
| `web` | WhatWeb, wafw00f, directory brute-force, Katana, Nuclei, WPScan (if WordPress), waybackurls + GAU |
| `osint` | whois, theHarvester, Amass (passive), DNSrecon, DNSdumpster, Recon-ng, waybackurls + GAU |
| `full` | osint + network + web (default) |

### Scan options

```
-t, --target TARGET     IP, domain or URL (http://host:port/)
-m, --mode MODE         quick | network | web | osint | full
-p, --port-engine ENG   rustscan | masscan | nmap        (default: rustscan, falls back to nmap)
-e, --dir-engine ENG    feroxbuster | ffuf | gobuster | dirb | all
-w, --wordlist FILE     custom wordlist
-o, --output DIR        output root (default: ./recon-output)
    --deep              nikto, nmap vuln scripts + top UDP, bigger wordlist, SpiderFoot
    --sqlmap            also run sqlmap on discovered web targets (explicit opt-in)
    --dry-run           print the commands, run nothing
-y, --yes               non-interactive (auto-install, skips the authorisation prompt)
```

### Examples

```bash
./reconkit.sh scan -t 10.10.11.5 -m network               # CTF box: ports, services, exploits
./reconkit.sh scan -t http://target.htb:8080 -m web -e all # every dir brute-forcer on one URL
./reconkit.sh scan -t example.com -m osint --deep          # passive OSINT incl. SpiderFoot
./reconkit.sh scan -t 10.10.11.5 --dry-run                 # preview only
./reconkit.sh pcap capture.pcapng                          # forensics challenge
./reconkit.sh exif suspicious.jpg
./reconkit.sh user johndoe
```

## Where every tool fits

| Tool | How ReconKit uses it |
|---|---|
| Nmap, RustScan, Masscan | Port discovery, then detailed `-sC -sV` scan |
| Searchsploit | Matches Nmap XML results against Exploit-DB |
| theHarvester, Amass, DNSrecon, Recon-ng, Whois | Domain / subdomain / email OSINT |
| SpiderFoot | `--deep` OSINT scan; web UI via `gui spiderfoot` |
| FFUF, Gobuster, Feroxbuster, Dirb | Directory brute-force (`-e` picks one or `all`) |
| WhatWeb, Wafw00f, Nikto, Nuclei, Katana, WPScan | Fingerprinting, WAF detection, vuln checks, crawling |
| SQLmap | Only with `--sqlmap` |
| Waybackurls, GAU | Historical URLs, with an "interesting" filter (params, backups, configs) |
| Enum4linux-ng, SMBClient, FTP | Run automatically when ports 139/445/21 are open |
| TShark, Tcpdump, Wireshark | `capture`, `pcap`, `gui wireshark` |
| ExifTool, Sherlock | `exif`, `user` |
| DNSdumpster | API lookup if `DNSDUMPSTER_API_KEY` is set, otherwise prints the web link |
| Social-Searcher | `social` command, needs `SOCIAL_SEARCHER_API_KEY` |
| Maltego | GUI launcher: `gui maltego` |
| Nessus | Commercial, not in apt. `gui nessus` starts `nessusd` or prints install steps; scans run from its web UI |

## Output layout

```
recon-output/<target>_<timestamp>/
├── REPORT.md          # ports, web services, file index
├── reconkit.log
├── ports/  nmap/  smb/  ftp/
├── web/<url>/         # whatweb, wafw00f, ferox/ffuf/..., katana, nuclei, wpscan, nikto
└── osint/             # whois, theHarvester, amass, dnsrecon, archive_urls.txt, ...
```

## Environment variables

| Variable | Purpose |
|---|---|
| `RECONKIT_OUT` | Output root |
| `TOOL_TIMEOUT` | Per-tool timeout in seconds (default 1800) |
| `MASSCAN_RATE` | Masscan packets/sec (default 1000) |
| `WORDLIST` | Default wordlist |
| `WPSCAN_API_TOKEN` | Enables WPScan vulnerability data |
| `DNSDUMPSTER_API_KEY` | Enables DNSdumpster lookups |
| `SOCIAL_SEARCHER_API_KEY` | Enables the `social` command |

## Notes

- Tested logic on Bash 5; targets Kali / Debian. Run as a normal user: ReconKit calls `sudo` only where needed (nmap SYN scans, masscan, tcpdump, apt).
- Tools missing from apt fall back to `go install` (waybackurls, gau, katana, nuclei, ffuf), `cargo` (rustscan, feroxbuster), `gem` (wpscan) or `pipx` (sherlock).
- `install` also pulls SecLists (~500 MB) for better wordlists; use `install --core` to skip it.
- Some modules are noisy. Use `--deep`, `--sqlmap` and `-p masscan` only where the rules of engagement allow it.
- Masscan works best on LAN targets; on VPN labs (HTB/THM) RustScan or Nmap is more reliable.

## License

Add a license of your choice (MIT is common for tools like this).
