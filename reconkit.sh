#!/usr/bin/env bash
# =============================================================================
#  ReconKit - reconnaissance automation for Kali Linux (CTF / pentest practice)
#
#  One command that wraps ~35 well-known recon tools, installs whatever is
#  missing, and saves every result in a tidy per-target folder.
#
#  LEGAL: only use against systems you own or are explicitly authorised to
#  test (CTF scope, home lab, bug-bounty scope, signed engagement).
# =============================================================================

set -o pipefail

APP="reconkit"
VERSION="1.0.0"

OUT_ROOT="${RECONKIT_OUT:-$PWD/recon-output}"
TOOL_TIMEOUT="${TOOL_TIMEOUT:-1800}"    # max seconds per tool
MASSCAN_RATE="${MASSCAN_RATE:-1000}"    # packets/sec for masscan

export PATH="$PATH:$HOME/go/bin:$HOME/.cargo/bin:$HOME/.local/bin:/usr/local/go/bin"

SUDO=""
[[ $EUID -ne 0 ]] && SUDO="sudo"

# ----------------------------------------------------------------------------
#  Output helpers
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
  CYN=$'\e[36m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; GRN=""; YEL=""; BLU=""; CYN=""; BLD=""; RST=""
fi

_log() { [[ -n ${OUT:-} && -d $OUT ]] && printf '[%s] %s\n' "$(date +%T)" "$*" >> "$OUT/reconkit.log"; return 0; }
info() { printf '%s[*]%s %s\n' "$BLU" "$RST" "$*"; _log "INFO  $*"; }
ok()   { printf '%s[+]%s %s\n' "$GRN" "$RST" "$*"; _log "OK    $*"; }
warn() { printf '%s[!]%s %s\n' "$YEL" "$RST" "$*" >&2; _log "WARN  $*"; }
err()  { printf '%s[-]%s %s\n' "$RED" "$RST" "$*" >&2; _log "ERROR $*"; }
step() { printf '\n%s==> %s%s\n' "$BLD$CYN" "$*" "$RST"; _log "STEP  $*"; }

banner() {
  printf '%s' "$CYN"
  cat <<'EOF'
  ____                      _  ___ _
 |  _ \ ___  ___ ___  _ __ | |/ (_) |_
 | |_) / _ \/ __/ _ \| '_ \| ' /| | __|
 |  _ <  __/ (_| (_) | | | | . \| | |_
 |_| \_\___|\___\___/|_| |_|_|\_\_|\__|
EOF
  printf '%s  Kali recon automation v%s - authorised targets only%s\n\n' "$RST" "$VERSION" "$RST"
}

confirm() {   # confirm "question"  -> default YES
  local a; read -rp "$1 [Y/n] " a
  [[ -z $a || $a =~ ^[Yy] ]]
}

confirm_no() {   # confirm_no "question" -> default NO
  local a; read -rp "$1 [y/N] " a
  [[ $a =~ ^[Yy] ]]
}

trap 'echo; warn "Interrupted."; exit 130' INT

# ----------------------------------------------------------------------------
#  Tool registry
# ----------------------------------------------------------------------------
# Installed automatically on first scan
CORE_TOOLS=(
  nmap rustscan masscan
  theHarvester amass dnsrecon whois sherlock recon-ng exiftool
  ffuf gobuster feroxbuster dirb whatweb wafw00f nikto wpscan sqlmap
  nuclei katana waybackurls gau
  enum4linux-ng smbclient ftp
  tshark tcpdump searchsploit
  curl jq
)
# Big / GUI tools: installed by `reconkit install` (not on first scan)
OPTIONAL_TOOLS=(wireshark maltego spiderfoot)

# command -> apt package
declare -A APT_PKG=(
  [nmap]=nmap
  [rustscan]=rustscan
  [masscan]=masscan
  [theHarvester]=theharvester
  [amass]=amass
  [dnsrecon]=dnsrecon
  [whois]=whois
  [sherlock]=sherlock
  [recon-ng]=recon-ng
  [exiftool]=libimage-exiftool-perl
  [ffuf]=ffuf
  [gobuster]=gobuster
  [feroxbuster]=feroxbuster
  [dirb]=dirb
  [whatweb]=whatweb
  [wafw00f]=wafw00f
  [nikto]=nikto
  [wpscan]=wpscan
  [sqlmap]=sqlmap
  [nuclei]=nuclei
  [katana]=katana
  [waybackurls]=waybackurls
  [gau]=getallurls
  [enum4linux-ng]=enum4linux-ng
  [smbclient]=smbclient
  [ftp]=ftp
  [tshark]=tshark
  [tcpdump]=tcpdump
  [searchsploit]=exploitdb
  [curl]=curl
  [jq]=jq
  [wireshark]=wireshark
  [maltego]=maltego
  [spiderfoot]=spiderfoot
)

# commands that can have more than one binary name
declare -A ALIAS=(
  [theHarvester]="theHarvester theharvester"
  [gau]="gau getallurls"
)

have() { command -v "$1" >/dev/null 2>&1; }

bin_of() {
  local b p
  for b in ${ALIAS[$1]:-$1}; do
    if p=$(command -v "$b" 2>/dev/null); then echo "$p"; return 0; fi
  done
  return 1
}

is_installed() { bin_of "$1" >/dev/null; }

need() {   # need <tool>  -> 0 if installed, else warn + 1
  is_installed "$1" && return 0
  warn "Skipping: $1 is not installed (run: $APP install)"
  return 1
}

apt_get() { $SUDO env DEBIAN_FRONTEND=noninteractive apt-get "$@"; }

APT_UPDATED=0
apt_update_once() {
  (( APT_UPDATED )) && return
  info "Updating apt package index..."
  apt_get update -qq || warn "apt update failed (continuing)"
  APT_UPDATED=1
}

go_install() {
  have go || apt_get install -y golang-go
  have go || { warn "Go toolchain unavailable - cannot build $1"; return 1; }
  info "go install $1"
  GOBIN="$HOME/go/bin" go install "$1"
}

fallback_install() {   # used when apt has no package for a tool
  local t=$1
  info "No apt package for $t - trying a fallback method"
  case $t in
    rustscan|feroxbuster)
      have cargo || apt_get install -y cargo
      if have cargo; then cargo install "$t"; else warn "cargo missing, install $t manually"; fi ;;
    waybackurls) go_install github.com/tomnomnom/waybackurls@latest ;;
    gau)         go_install github.com/lc/gau/v2/cmd/gau@latest ;;
    katana)      go_install github.com/projectdiscovery/katana/cmd/katana@latest ;;
    nuclei)      go_install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest ;;
    ffuf)        go_install github.com/ffuf/ffuf/v2@latest ;;
    wpscan)
      apt_get install -y ruby-dev build-essential libcurl4-openssl-dev libxml2-dev libxslt1-dev zlib1g-dev
      $SUDO gem install wpscan ;;
    sherlock)
      apt_get install -y pipx && pipx install sherlock-project ;;
    *) warn "No automatic fallback for $t - please install it manually." ;;
  esac
}

install_tools() {   # install_tools tool1 tool2 ...
  local t pkgs=() leftovers=()
  for t in "$@"; do
    is_installed "$t" && continue
    local pkg=${APT_PKG[$t]:-}
    if [[ -n $pkg ]] && apt-cache show "$pkg" >/dev/null 2>&1; then
      pkgs+=("$pkg")
    else
      leftovers+=("$t")
    fi
  done

  if (( ${#pkgs[@]} )); then
    apt_update_once
    # re-filter after update (package lists may have changed)
    info "apt install: ${pkgs[*]}"
    if ! apt_get install -y "${pkgs[@]}"; then
      warn "Batch install failed - retrying package by package"
      local p
      for p in "${pkgs[@]}"; do apt_get install -y "$p" || warn "Could not install $p via apt"; done
    fi
  fi

  for t in "${leftovers[@]}"; do fallback_install "$t"; done
  # anything that still isn't there after apt (e.g. package exists but binary name differs)
  for t in "$@"; do is_installed "$t" || { [[ " ${leftovers[*]} " == *" $t "* ]] || fallback_install "$t"; }; done
}

install_wordlists() {
  if [[ -d /usr/share/seclists ]]; then return 0; fi
  info "Installing SecLists wordlists (large download, ~500 MB)"
  apt_update_once
  apt_get install -y seclists || warn "Could not install seclists - dirb's common.txt will be used instead"
}

post_install() {
  if is_installed nuclei; then
    info "Updating nuclei templates..."
    nuclei -update-templates >/dev/null 2>&1 || warn "nuclei template update failed (it will retry on first scan)"
  fi
}

ensure() {   # strict: ensure <tool...>  (for sub-commands)
  local t missing=()
  for t in "$@"; do is_installed "$t" || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) && return 0
  warn "Missing tools: ${missing[*]}"
  if (( ASSUME_YES )) || confirm "Install them now?"; then
    install_tools "${missing[@]}"
  fi
  for t in "$@"; do is_installed "$t" || { err "$t is still missing"; return 1; }; done
}

preflight() {   # soft: runs before every scan, installs core tools if missing
  local t missing=()
  for t in "${CORE_TOOLS[@]}"; do is_installed "$t" || missing+=("$t"); done
  (( ${#missing[@]} == 0 )) && return 0
  warn "Missing tools: ${missing[*]}"
  if (( DRY_RUN )); then info "(dry-run) not installing"; return 0; fi
  if (( ASSUME_YES )) || confirm "Install the missing tools now?"; then
    [[ -n $SUDO ]] && $SUDO -v
    install_tools "${missing[@]}"
    post_install
  else
    warn "Continuing - modules for missing tools will be skipped."
  fi
}

# ----------------------------------------------------------------------------
#  Nessus (commercial, not in apt) - helper only
# ----------------------------------------------------------------------------
cmd_nessus() {
  if [[ -x /opt/nessus/sbin/nessuscli ]]; then
    info "Starting nessusd..."
    $SUDO systemctl start nessusd
    ok "Nessus UI: https://127.0.0.1:8834  (create/run the scan from the web UI)"
  else
    warn "Nessus is commercial software and is not in the Kali repositories."
    info "1) Download the Debian .deb: https://www.tenable.com/downloads/nessus"
    info "2) sudo dpkg -i Nessus-*.deb && sudo systemctl start nessusd"
    info "3) Open https://127.0.0.1:8834 and activate it (Essentials license is free for personal use)."
  fi
}

# ----------------------------------------------------------------------------
#  Generic helpers
# ----------------------------------------------------------------------------
slugify() { printf '%s' "$1" | sed -E 's#^[a-zA-Z]+://##; s#[^A-Za-z0-9._-]+#_#g; s#_+$##'; }

resolve_ip() { getent ahostsv4 "$1" 2>/dev/null | awk 'NR==1{print $1}'; }

mkurl() {   # mkurl scheme host port
  if [[ ( $1 == http && $3 == 80 ) || ( $1 == https && $3 == 443 ) ]]; then
    echo "$1://$2"
  else
    echo "$1://$2:$3"
  fi
}

norm_ports() { tr ',' '\n' | grep -E '^[0-9]+$' | sort -nu | paste -sd, -; }

ports_from_nmap() {
  [[ -f $1 ]] || return 0
  grep -oP '^\d+(?=/tcp\s+open)' "$1" | sort -nu | paste -sd, -
}

pick_wordlist() {
  local c list
  if [[ -n ${WORDLIST:-} && -f $WORDLIST ]]; then echo "$WORDLIST"; return; fi
  if (( DEEP )); then
    list=(/usr/share/seclists/Discovery/Web-Content/raft-medium-directories.txt
          /usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt
          /usr/share/seclists/Discovery/Web-Content/raft-small-directories.txt
          /usr/share/wordlists/dirb/common.txt)
  else
    list=(/usr/share/seclists/Discovery/Web-Content/raft-small-directories.txt
          /usr/share/wordlists/dirb/common.txt
          /usr/share/seclists/Discovery/Web-Content/raft-medium-directories.txt
          /usr/share/wordlists/dirbuster/directory-list-2.3-medium.txt)
  fi
  for c in "${list[@]}"; do [[ -f $c ]] && { echo "$c"; return; }; done
}

# run <label> <outfile> <command...>   (live output + saved to file + timeout)
run() {
  local label=$1 out=$2; shift 2
  if [[ -n ${RUN_HIDE:-} ]]; then info "$label: <command hidden - contains a secret>"; else info "$label: $*"; fi
  (( DRY_RUN )) && return 0
  timeout "$TOOL_TIMEOUT" "$@" </dev/null 2>&1 | tee "$out"
  local rc=${PIPESTATUS[0]}
  (( rc == 124 )) && warn "$label hit the ${TOOL_TIMEOUT}s timeout (partial output saved)"
  return 0
}

# ----------------------------------------------------------------------------
#  Scan state / target handling
# ----------------------------------------------------------------------------
reset_state() {
  TARGET_RAW=""; TARGET_HOST=""; TARGET_URL=""; TARGET_IP=""; TARGET_IS_IP=0
  MODE="full"; DEEP=0; USE_SQLMAP=0; DRY_RUN=0; ASSUME_YES=0
  DIR_ENGINE="feroxbuster"; PORT_ENGINE="rustscan"; WORDLIST="${WORDLIST:-}"
  OPEN_PORTS=""; WEB_URLS=(); ARCHIVES_DONE=0; WEB_LIGHT=0; NMAP_FILE=""; OUT=""
}
reset_state

parse_target() {
  local raw=$1 host
  if [[ $raw =~ ^https?:// ]]; then
    TARGET_URL=${raw%/}
    host=${raw#*://}; host=${host%%/*}; host=${host%%:*}
  else
    if [[ $raw == */* ]]; then err "CIDR ranges are not supported - give a single host, domain or URL."; return 1; fi
    host=${raw%%:*}
  fi
  TARGET_HOST=$host
  if [[ $host =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    TARGET_IS_IP=1; TARGET_IP=$host
  else
    TARGET_IS_IP=0; TARGET_IP=$(resolve_ip "$host")
  fi
  return 0
}

setup_out() {
  OUT="$OUT_ROOT/$(slugify "$TARGET_HOST")_$(date +%Y%m%d_%H%M%S)"
  mkdir -p "$OUT"/{osint,nmap,ports,web,smb,ftp}
  ok "Output folder: $OUT"
}

authorize() {
  warn "Only test targets you own or are explicitly authorised to test."
  (( ASSUME_YES )) && return 0
  confirm_no "Confirm you are authorised to test '$TARGET_RAW'" || { err "Aborted."; return 1; }
}

# ----------------------------------------------------------------------------
#  Phase: port discovery + service scan
# ----------------------------------------------------------------------------
discover_ports() {
  step "Port discovery on $TARGET_IP (engine: $PORT_ENGINE)"
  local d="$OUT/ports" engine=$PORT_ENGINE raw=""
  if [[ $engine != nmap ]] && ! is_installed "$engine"; then
    warn "$engine is not installed - falling back to nmap"; engine=nmap
  fi
  if [[ $engine == nmap ]] && ! is_installed nmap; then err "nmap is required for port discovery"; return 1; fi

  case $engine in
    rustscan)
      run rustscan "$d/rustscan.txt" "$(bin_of rustscan)" -a "$TARGET_IP" -b 1000 --ulimit 5000 -g
      raw=$(grep -oP '\[\K[0-9,]+(?=\])' "$d/rustscan.txt" 2>/dev/null | head -n1) ;;
    masscan)
      run masscan "$d/masscan.log" $SUDO masscan "$TARGET_IP" -p1-65535 --rate "$MASSCAN_RATE" -oL "$d/masscan.lst"
      raw=$(awk '$1=="open"{print $3}' "$d/masscan.lst" 2>/dev/null | paste -sd,) ;;
    nmap)
      run nmap "$d/nmap_allports.txt" $SUDO nmap -p- --min-rate 3000 -T4 -Pn -n "$TARGET_IP"
      raw=$(ports_from_nmap "$d/nmap_allports.txt") ;;
  esac
  OPEN_PORTS=$(printf '%s' "$raw" | norm_ports)
  (( DRY_RUN )) && OPEN_PORTS="80,443"
  return 0
}

ftp_check() {
  step "FTP anonymous login check"
  need ftp || return 0
  info "ftp anonymous login test on $TARGET_IP:21"
  (( DRY_RUN )) && return 0
  timeout 30 ftp -inv "$TARGET_IP" 21 <<'EOF' 2>&1 | tee "$OUT/ftp/anonymous.txt"
user anonymous anonymous@example.com
ls -la
bye
EOF
}

service_enum() {
  [[ -z $OPEN_PORTS ]] && return 0
  local p=",$OPEN_PORTS,"
  if [[ $p == *,445,* || $p == *,139,* ]]; then
    step "SMB enumeration"
    need enum4linux-ng && run enum4linux-ng "$OUT/smb/enum4linux-ng.txt" enum4linux-ng -A "$TARGET_IP" -oA "$OUT/smb/enum4linux-ng"
    need smbclient && run smbclient "$OUT/smb/smbclient_shares.txt" smbclient -L "//$TARGET_IP" -N
  fi
  [[ $p == *,21,* ]] && ftp_check
  return 0
}

network_phase() {
  discover_ports || return 0
  if [[ -z $OPEN_PORTS ]]; then warn "No open TCP ports found."; return 0; fi
  ok "Open ports: $OPEN_PORTS"
  need nmap || return 0

  step "Detailed nmap scan (default scripts + version detection)"
  run nmap "$OUT/nmap/detailed_stdout.txt" $SUDO nmap -sC -sV -Pn -p "$OPEN_PORTS" -oA "$OUT/nmap/detailed" "$TARGET_IP"
  NMAP_FILE="$OUT/nmap/detailed.nmap"

  if (( DEEP )); then
    step "Deep: nmap 'vuln' scripts + top UDP ports"
    run nmap "$OUT/nmap/vuln.txt" $SUDO nmap -Pn -sV --script vuln -p "$OPEN_PORTS" "$TARGET_IP"
    run nmap "$OUT/nmap/udp_top25.txt" $SUDO nmap -Pn -sU --top-ports 25 -T4 "$TARGET_IP"
  fi

  step "Exploit-DB lookup (searchsploit)"
  if need searchsploit && [[ -f $OUT/nmap/detailed.xml || $DRY_RUN -eq 1 ]]; then
    run searchsploit "$OUT/nmap/searchsploit.txt" searchsploit --nmap "$OUT/nmap/detailed.xml"
  fi
  service_enum
}

# ----------------------------------------------------------------------------
#  Phase: web
# ----------------------------------------------------------------------------
probe_url() {
  (( DRY_RUN )) && return 0
  local code
  code=$(curl -sk -o /dev/null -m 6 -w '%{http_code}' "$1" 2>/dev/null)
  [[ -n $code && $code != 000 ]]
}

discover_web() {
  local -a cands=(); local -A seen=()
  local port scheme url
  [[ -n $TARGET_URL ]] && cands+=("$TARGET_URL")

  if [[ -n $NMAP_FILE && -f $NMAP_FILE ]]; then
    while read -r port scheme; do
      [[ -n $port ]] && cands+=("$(mkurl "$scheme" "$TARGET_HOST" "$port")")
    done < <(awk '$2=="open" && $3 ~ /http/ { split($1,a,"/"); print a[1], (($3 ~ /ssl|https/) ? "https" : "http") }' "$NMAP_FILE")
  elif [[ -z $TARGET_URL ]]; then
    for port in 80 443 8000 8080 8443 8888; do
      scheme=http; [[ $port == 443 || $port == 8443 ]] && scheme=https
      cands+=("$(mkurl "$scheme" "$TARGET_HOST" "$port")")
    done
  fi

  : > "$OUT/web_urls.txt"
  for url in "${cands[@]}"; do
    [[ -n ${seen[$url]:-} ]] && continue
    seen[$url]=1
    if probe_url "$url"; then
      WEB_URLS+=("$url"); echo "$url" >> "$OUT/web_urls.txt"; ok "Live web service: $url"
    fi
  done
}

dir_bruteforce() {   # dir_bruteforce <url> <dir>
  local url=$1 d=$2 wl e engines=()
  wl=$(pick_wordlist)
  if [[ -z $wl ]]; then warn "No wordlist found (run: $APP install, or pass -w FILE)"; return 0; fi
  info "Wordlist: $wl"
  if [[ $DIR_ENGINE == all ]]; then engines=(feroxbuster ffuf gobuster dirb); else engines=("$DIR_ENGINE"); fi
  for e in "${engines[@]}"; do
    case $e in
      feroxbuster) need feroxbuster && run feroxbuster "$d/feroxbuster.txt" feroxbuster -u "$url" -w "$wl" -t 50 -k -C 404 -q --no-state ;;
      ffuf)        need ffuf && run ffuf "$d/ffuf.txt" ffuf -u "$url/FUZZ" -w "$wl" -mc 200,204,301,302,307,401,403 -ac -t 50 -s -of json -o "$d/ffuf.json" ;;
      gobuster)    need gobuster && run gobuster "$d/gobuster.txt" gobuster dir -u "$url" -w "$wl" -t 40 -k --no-error -q ;;
      dirb)        need dirb && run dirb "$d/dirb.txt" dirb "$url" "$wl" -S -r ;;
    esac
  done
}

is_wordpress() {   # is_wordpress <url> <dir>
  (( DRY_RUN )) && return 1
  grep -qi 'wordpress' "$2/whatweb.txt" 2>/dev/null && return 0
  local code
  code=$(curl -sk -o /dev/null -m 8 -w '%{http_code}' "$1/wp-login.php" 2>/dev/null)
  [[ $code == 200 || $code == 302 ]]
}

sqlmap_scan() {   # sqlmap_scan <url> <dir>
  need sqlmap || return 0
  local url=$1 d=$2 extra=()
  [[ $url == *\?*=* ]] || extra=(--forms --crawl=2)
  step "sqlmap (explicit opt-in)"
  run sqlmap "$d/sqlmap.txt" sqlmap -u "$url" --batch --random-agent --level 2 --risk 1 --output-dir "$d/sqlmap" "${extra[@]}"
}

web_enum() {   # web_enum <url>
  local url=$1 d
  d="$OUT/web/$(slugify "$url")"; mkdir -p "$d"
  step "Web recon: $url"

  need whatweb && run whatweb "$d/whatweb.txt" whatweb -a 3 --color=never "$url"
  need wafw00f && run wafw00f "$d/wafw00f.txt" wafw00f -a "$url"
  if need curl; then
    run headers "$d/headers.txt" curl -skIL -m 10 "$url"
    run robots  "$d/robots.txt"  curl -sk -m 10 "$url/robots.txt"
    run sitemap "$d/sitemap.xml" curl -sk -m 10 "$url/sitemap.xml"
  fi
  (( WEB_LIGHT )) && return 0

  dir_bruteforce "$url" "$d"
  need katana && run katana "$d/katana.txt" katana -u "$url" -d 3 -jc -silent
  need nuclei && run nuclei "$d/nuclei.txt" nuclei -u "$url" -severity low,medium,high,critical -silent -nc

  if is_wordpress "$url" "$d"; then
    ok "WordPress detected"
    need wpscan && run wpscan "$d/wpscan.txt" wpscan --url "$url" --enumerate vp,vt,u --random-user-agent \
      --disable-tls-checks --no-banner ${WPSCAN_API_TOKEN:+--api-token "$WPSCAN_API_TOKEN"}
  fi

  (( DEEP )) && need nikto && run nikto "$d/nikto.txt" nikto -h "$url" -maxtime 900s -nointeractive
  (( USE_SQLMAP )) && sqlmap_scan "$url" "$d"
  return 0
}

url_archives() {
  (( ARCHIVES_DONE )) && return 0
  ARCHIVES_DONE=1
  (( TARGET_IS_IP )) && return 0
  step "Historical URLs (waybackurls + gau)"
  local d="$OUT/osint" tmp="$OUT/osint/.urls.tmp" g
  : > "$tmp"
  if need waybackurls; then
    info "waybackurls $TARGET_HOST"
    (( DRY_RUN )) || printf '%s\n' "$TARGET_HOST" | timeout 600 waybackurls >> "$tmp"
  fi
  g=$(bin_of gau)
  if [[ -n $g ]]; then
    info "gau $TARGET_HOST"
    (( DRY_RUN )) || printf '%s\n' "$TARGET_HOST" | timeout 600 "$g" >> "$tmp"
  else
    warn "Skipping: gau is not installed (run: $APP install)"
  fi
  sort -u "$tmp" > "$d/archive_urls.txt"; rm -f "$tmp"
  grep -Ei '\.(php|aspx?|jsp|json|bak|old|sql|zip|tar|gz|env|git|conf|config|log|txt|xml|ya?ml)(\?|$)|[?&][a-zA-Z0-9_]+=' \
    "$d/archive_urls.txt" | sort -u > "$d/archive_interesting.txt"
  ok "$(wc -l < "$d/archive_urls.txt") archived URLs, $(wc -l < "$d/archive_interesting.txt") look interesting (params / backups / configs)"
}

web_phase() {
  discover_web
  if (( ${#WEB_URLS[@]} == 0 )); then warn "No live web services found."; url_archives; return 0; fi
  local u
  for u in "${WEB_URLS[@]}"; do web_enum "$u"; done
  url_archives
}

# ----------------------------------------------------------------------------
#  Phase: OSINT / DNS
# ----------------------------------------------------------------------------
dnsdumpster_lookup() {
  step "DNSdumpster"
  if [[ -n ${DNSDUMPSTER_API_KEY:-} ]]; then
    RUN_HIDE=1 run dnsdumpster "$OUT/osint/dnsdumpster.json" \
      curl -s -H "X-API-Key: $DNSDUMPSTER_API_KEY" "https://api.dnsdumpster.com/domain/$TARGET_HOST"
  else
    warn "DNSdumpster has no free CLI. Export DNSDUMPSTER_API_KEY (https://dnsdumpster.com) or look it up in a browser:"
    info "https://dnsdumpster.com/  (search: $TARGET_HOST)"
  fi
}

recon_ng_phase() {
  need recon-ng || return 0
  step "Recon-ng (hackertarget + certificate_transparency)"
  local rc="$OUT/osint/recon-ng.rc" ws
  ws=$(slugify "$TARGET_HOST"); ws=${ws//[^A-Za-z0-9]/_}
  cat > "$rc" <<EOF
marketplace refresh
marketplace install recon/domains-hosts/hackertarget
marketplace install recon/domains-hosts/certificate_transparency
modules load recon/domains-hosts/hackertarget
options set SOURCE $TARGET_HOST
run
modules load recon/domains-hosts/certificate_transparency
options set SOURCE $TARGET_HOST
run
show hosts
exit
EOF
  run recon-ng "$OUT/osint/recon-ng.txt" recon-ng -w "$ws" -r "$rc"
}

osint_phase() {
  step "WHOIS"
  need whois && run whois "$OUT/osint/whois.txt" whois "$TARGET_HOST"
  if (( TARGET_IS_IP )); then warn "Target is an IP - skipping domain OSINT modules."; return 0; fi

  step "theHarvester (emails, hosts, subdomains)"
  need theHarvester && run theHarvester "$OUT/osint/theharvester.txt" \
    "$(bin_of theHarvester)" -d "$TARGET_HOST" -b all -l 200 -f "$OUT/osint/theharvester"

  step "Amass (passive subdomain enumeration)"
  need amass && run amass "$OUT/osint/amass_log.txt" amass enum -passive -d "$TARGET_HOST" -o "$OUT/osint/amass_subdomains.txt"

  step "DNSrecon (standard records + zone transfer attempt)"
  need dnsrecon && run dnsrecon "$OUT/osint/dnsrecon.txt" dnsrecon -d "$TARGET_HOST" -t std,axfr -j "$OUT/osint/dnsrecon.json"

  dnsdumpster_lookup
  recon_ng_phase

  if (( DEEP )); then
    step "SpiderFoot (passive use-case)"
    local sf; sf=$(bin_of spiderfoot)
    if [[ -n $sf ]]; then
      run spiderfoot "$OUT/osint/spiderfoot.csv" "$sf" -s "$TARGET_HOST" -u passive -o csv -q
    else
      warn "Skipping: spiderfoot is not installed (run: $APP install)"
    fi
  fi
  url_archives
}

# ----------------------------------------------------------------------------
#  Modes
# ----------------------------------------------------------------------------
mode_quick() {
  (( TARGET_IS_IP )) || { need whois && run whois "$OUT/osint/whois.txt" whois "$TARGET_HOST"; }
  step "Quick nmap (top 100 ports + versions)"
  need nmap || return 0
  run nmap "$OUT/nmap/quick_stdout.txt" $SUDO nmap -F -T4 -Pn -sV -oA "$OUT/nmap/quick" "$TARGET_IP"
  NMAP_FILE="$OUT/nmap/quick.nmap"
  OPEN_PORTS=$(ports_from_nmap "$NMAP_FILE")
  WEB_LIGHT=1
  web_phase
}

mode_network() { network_phase; }
mode_web()     { web_phase; }

mode_osint() { osint_phase; }

mode_full() {
  (( TARGET_IS_IP )) || osint_phase
  network_phase
  web_phase
}

write_report() {
  local r="$OUT/REPORT.md"
  {
    echo "# ReconKit report - $TARGET_RAW"
    echo
    echo "- Date: $(date -Is)"
    echo "- Mode: $MODE$( (( DEEP )) && echo ' (deep)')"
    echo "- Host: $TARGET_HOST  (IP: ${TARGET_IP:-unresolved})"
    echo
    echo "## Open ports"
    if [[ -n $OPEN_PORTS ]]; then echo "\`$OPEN_PORTS\`"; else echo "_none recorded_"; fi
    if [[ -f $NMAP_FILE ]]; then
      echo; echo '```'; grep -E '^[0-9]+/(tcp|udp) +open' "$NMAP_FILE"; echo '```'
    fi
    echo
    echo "## Web services"
    if (( ${#WEB_URLS[@]} )); then printf -- '- %s\n' "${WEB_URLS[@]}"; else echo "_none_"; fi
    echo
    echo "## Files"
    (cd "$OUT" && find . -type f -size +0 ! -name REPORT.md | sort | sed 's/^\.\//- /')
  } > "$r"
}

finalize() {
  if (( ! DRY_RUN )); then
    [[ -n $SUDO ]] && $SUDO chown -R "$(id -u):$(id -g)" "$OUT" 2>/dev/null
    find "$OUT" -mindepth 1 -type d -empty -delete 2>/dev/null
  fi
  write_report
  step "Finished"
  ok "Results: $OUT"
  ok "Summary: $OUT/REPORT.md"
}

# ----------------------------------------------------------------------------
#  Commands
# ----------------------------------------------------------------------------
usage() {
  cat <<EOF
${APP} v${VERSION} - recon automation for Kali Linux

USAGE
  ${APP}.sh                       interactive menu
  ${APP}.sh install [--core] [-y] install every tool (--core = skip Wireshark/Maltego/SpiderFoot)
  ${APP}.sh check                 show which tools are installed
  ${APP}.sh scan -t TARGET [opts] run a recon scan
  ${APP}.sh user USERNAME         username OSINT (Sherlock)
  ${APP}.sh social "TERM"         Social-Searcher API lookup (needs SOCIAL_SEARCHER_API_KEY)
  ${APP}.sh exif PATH             metadata with ExifTool (file or folder)
  ${APP}.sh pcap FILE [--gui]     analyse a capture with TShark (CTF-friendly)
  ${APP}.sh capture [-i IF] [-d SEC] [-f "BPF"] [--gui]   capture with tcpdump
  ${APP}.sh gui maltego|wireshark [file]|spiderfoot|nessus

SCAN OPTIONS
  -t, --target TARGET      IP, domain or URL (http://host:port/)
  -m, --mode MODE          quick | network | web | osint | full   (default: full)
  -p, --port-engine ENG    rustscan | masscan | nmap              (default: rustscan)
  -e, --dir-engine ENG     feroxbuster | ffuf | gobuster | dirb | all (default: feroxbuster)
  -w, --wordlist FILE      wordlist for directory brute-forcing
  -o, --output DIR         output root (default: ./recon-output)
      --deep               slower & noisier: nikto, nmap vuln scripts + UDP, bigger wordlist, SpiderFoot
      --sqlmap             also run sqlmap against discovered web targets (explicit opt-in)
      --dry-run            print what would run, execute nothing
  -y, --yes                non-interactive: auto-install tools, skip the authorisation prompt

MODES
  quick    whois, fast nmap, WhatWeb, wafw00f, headers, robots.txt
  network  port discovery -> nmap -sC -sV -> searchsploit -> SMB/FTP checks
  web      WhatWeb, wafw00f, dir brute-force, katana, nuclei, WPScan, wayback/gau
  osint    whois, theHarvester, Amass, DNSrecon, DNSdumpster, Recon-ng, wayback/gau
  full     osint + network + web

ENV VARS
  RECONKIT_OUT  TOOL_TIMEOUT  MASSCAN_RATE  WORDLIST
  WPSCAN_API_TOKEN  DNSDUMPSTER_API_KEY  SOCIAL_SEARCHER_API_KEY

EXAMPLES
  ${APP}.sh scan -t 10.10.11.5 -m network
  ${APP}.sh scan -t http://target.htb:8080 -m web -e all
  ${APP}.sh scan -t example.com -m osint --deep
  ${APP}.sh pcap capture.pcap

Only scan systems you own or have written permission to test.
EOF
}

cmd_check() {
  step "Tool status"
  local t missing=0
  for t in "${CORE_TOOLS[@]}" "${OPTIONAL_TOOLS[@]}"; do
    if is_installed "$t"; then
      printf '  %s✔%s %-15s %s\n' "$GRN" "$RST" "$t" "$(bin_of "$t")"
    else
      printf '  %s✘%s %-15s missing\n' "$RED" "$RST" "$t"; missing=$((missing+1))
    fi
  done
  if [[ -x /opt/nessus/sbin/nessuscli ]]; then
    printf '  %s✔%s %-15s %s\n' "$GRN" "$RST" "nessus" "/opt/nessus/sbin/nessuscli"
  else
    printf '  %s-%s %-15s manual install (see: %s gui nessus)\n' "$YEL" "$RST" "nessus" "$APP"
  fi
  [[ -d /usr/share/seclists ]] && printf '  %s✔%s %-15s\n' "$GRN" "$RST" "seclists" || printf '  %s✘%s %-15s missing\n' "$RED" "$RST" "seclists"
  echo
  if (( missing )); then info "$missing tool(s) missing - run: $APP install"; else ok "Everything is installed."; fi
}

cmd_install() {
  local core_only=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -y|--yes) ASSUME_YES=1 ;;
      --core)   core_only=1 ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac; shift
  done
  have apt-get || { err "apt-get not found - ReconKit targets Kali / Debian."; return 1; }
  grep -qi kali /etc/os-release 2>/dev/null || warn "Not Kali: should work on Debian/Ubuntu, but some package names may differ."
  [[ -n $SUDO ]] && $SUDO -v
  step "Installing tools"
  local list=("${CORE_TOOLS[@]}")
  (( core_only )) || list+=("${OPTIONAL_TOOLS[@]}")
  install_tools "${list[@]}"
  (( core_only )) || install_wordlists
  post_install
  echo
  cmd_check
  [[ -x /opt/nessus/sbin/nessuscli ]] || info "Nessus must be installed manually: $APP gui nessus"
}

cmd_scan() {
  reset_state
  while [[ $# -gt 0 ]]; do
    case $1 in
      -t|--target)      TARGET_RAW=${2:-}; shift 2 ;;
      -m|--mode)        MODE=${2:-}; shift 2 ;;
      -p|--port-engine) PORT_ENGINE=${2:-}; shift 2 ;;
      -e|--dir-engine)  DIR_ENGINE=${2:-}; shift 2 ;;
      -w|--wordlist)    WORDLIST=${2:-}; shift 2 ;;
      -o|--output)      OUT_ROOT=${2:-}; shift 2 ;;
      --deep)           DEEP=1; shift ;;
      --sqlmap)         USE_SQLMAP=1; shift ;;
      --dry-run)        DRY_RUN=1; shift ;;
      -y|--yes)         ASSUME_YES=1; shift ;;
      -h|--help)        usage; return 0 ;;
      *) err "Unknown option: $1"; usage; return 1 ;;
    esac
  done

  [[ -z $TARGET_RAW ]] && { err "No target. Use: $APP scan -t TARGET"; return 1; }
  case $MODE in quick|network|web|osint|full) ;; *) err "Invalid mode: $MODE"; return 1 ;; esac
  case $PORT_ENGINE in rustscan|masscan|nmap) ;; *) err "Invalid port engine: $PORT_ENGINE"; return 1 ;; esac
  case $DIR_ENGINE in feroxbuster|ffuf|gobuster|dirb|all) ;; *) err "Invalid dir engine: $DIR_ENGINE"; return 1 ;; esac

  parse_target "$TARGET_RAW" || return 1
  if [[ -z $TARGET_IP && $MODE != osint ]]; then err "Cannot resolve '$TARGET_HOST'."; return 1; fi

  banner
  authorize || return 1
  preflight
  setup_out
  [[ -n $SUDO ]] && (( ! DRY_RUN )) && $SUDO -v

  info "Target: $TARGET_HOST  (IP: ${TARGET_IP:-n/a})  mode: $MODE  deep: $DEEP"
  case $MODE in
    quick)   mode_quick ;;
    network) mode_network ;;
    web)     mode_web ;;
    osint)   mode_osint ;;
    full)    mode_full ;;
  esac
  finalize
}

cmd_user() {
  local u=${1:-}
  [[ -z $u ]] && { err "Usage: $APP user <username>"; return 1; }
  ensure sherlock || return 1
  OUT="$OUT_ROOT/username_$(slugify "$u")"; mkdir -p "$OUT"
  step "Sherlock: $u"
  run sherlock "$OUT/sherlock_stdout.txt" "$(bin_of sherlock)" "$u" --timeout 10 --print-found --folderoutput "$OUT"
  ok "Saved in $OUT"
  info "Tip: pivot the results in Maltego ($APP gui maltego) or Social-Searcher ($APP social \"$u\")."
}

cmd_social() {
  local q=${1:-}
  [[ -z $q ]] && { err "Usage: $APP social \"search term\""; return 1; }
  ensure curl || return 1
  OUT="$OUT_ROOT/social_$(slugify "$q")"; mkdir -p "$OUT"
  step "Social-Searcher: $q"
  if [[ -z ${SOCIAL_SEARCHER_API_KEY:-} ]]; then
    warn "Set SOCIAL_SEARCHER_API_KEY to use the API (https://www.social-searcher.com/api-v2/)."
    info "Manual search: https://www.social-searcher.com/search-users/?q=$q"
    return 0
  fi
  RUN_HIDE=1 run social-searcher "$OUT/social_searcher.json" \
    curl -sG "https://api.social-searcher.com/v2/search" \
    --data-urlencode "q=$q" --data-urlencode "limit=20" --data-urlencode "key=$SOCIAL_SEARCHER_API_KEY"
}

cmd_exif() {
  local p=${1:-}
  [[ -z $p || ! -e $p ]] && { err "Usage: $APP exif <file|folder>"; return 1; }
  ensure exiftool || return 1
  OUT="$OUT_ROOT/exif_$(slugify "$(basename "$p")")"; mkdir -p "$OUT"
  step "ExifTool: $p"
  run exiftool "$OUT/exiftool.txt" exiftool -a -u -g1 -r "$p"
  if [[ -f $OUT/exiftool.txt ]]; then
    echo
    if grep -qi 'gps' "$OUT/exiftool.txt"; then ok "GPS data found:"; grep -i 'gps' "$OUT/exiftool.txt" | head -n 10; fi
    local f; f=$(grep -Eoi '[a-z0-9_]*\{[^}]{4,}\}' "$OUT/exiftool.txt" | sort -u)
    [[ -n $f ]] && { ok "Flag-like strings in metadata:"; echo "$f"; }
  fi
  ok "Saved in $OUT"
}

cmd_pcap() {
  local f=${1:-} gui=0
  [[ -z $f || ! -f $f ]] && { err "Usage: $APP pcap <file.pcap> [--gui]"; return 1; }
  [[ ${2:-} == --gui ]] && gui=1
  ensure tshark || return 1
  OUT="$OUT_ROOT/pcap_$(slugify "$(basename "$f")")"; mkdir -p "$OUT/http_objects"
  step "TShark analysis: $f"
  run tshark "$OUT/protocol_hierarchy.txt" tshark -r "$f" -q -z io,phs
  run tshark "$OUT/ip_conversations.txt"   tshark -r "$f" -q -z conv,ip
  run tshark "$OUT/tcp_conversations.txt"  tshark -r "$f" -q -z conv,tcp
  run tshark "$OUT/dns_queries.txt"        tshark -r "$f" -Y 'dns.flags.response == 0' -T fields -e frame.time_relative -e ip.src -e dns.qry.name
  run tshark "$OUT/http_requests.txt"      tshark -r "$f" -Y http.request -T fields -e ip.src -e http.host -e http.request.method -e http.request.uri
  run tshark "$OUT/login_hints.txt"        tshark -r "$f" -Y 'ftp.request.command == "USER" || ftp.request.command == "PASS" || http.authbasic || http.request.method == "POST"' \
                                           -T fields -e ip.src -e ip.dst -e ftp.request.command -e ftp.request.arg -e http.authbasic -e http.request.uri -e urlencoded-form.key -e urlencoded-form.value
  run tshark "$OUT/http_export.log"        tshark -r "$f" -q --export-objects "http,$OUT/http_objects"
  if have strings; then
    strings -n 6 "$f" | grep -Eoi '[a-z0-9_]*\{[^}]{4,}\}' | sort -u > "$OUT/flag_like_strings.txt"
    [[ -s $OUT/flag_like_strings.txt ]] && { ok "Flag-like strings:"; cat "$OUT/flag_like_strings.txt"; }
  fi
  ok "Saved in $OUT"
  (( gui )) && cmd_gui wireshark "$f"
}

cmd_capture() {
  local iface="" dur=60 filter="" gui=0
  while [[ $# -gt 0 ]]; do
    case $1 in
      -i) iface=${2:-}; shift 2 ;;
      -d) dur=${2:-60}; shift 2 ;;
      -f) filter=${2:-}; shift 2 ;;
      --gui) gui=1; shift ;;
      *) err "Unknown option: $1"; return 1 ;;
    esac
  done
  ensure tcpdump || return 1
  if [[ -z $iface ]]; then
    if [[ -d /sys/class/net/tun0 ]]; then iface=tun0
    else iface=$(ip -o link show up 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}'); fi
    iface=${iface:-any}
  fi
  mkdir -p "$OUT_ROOT/captures"
  local pcap="$OUT_ROOT/captures/capture_$(date +%Y%m%d_%H%M%S).pcap"
  [[ -n $SUDO ]] && $SUDO -v
  step "tcpdump on $iface for ${dur}s ${filter:+(filter: $filter)}"
  info "Writing $pcap  (Ctrl+C stops early)"
  timeout "$dur" $SUDO tcpdump -i "$iface" -nn -U -w "$pcap" ${filter:+$filter}
  [[ -n $SUDO ]] && $SUDO chown "$(id -u):$(id -g)" "$pcap" 2>/dev/null
  ok "Capture saved: $pcap"
  if have tshark; then tshark -r "$pcap" -q -z io,phs 2>/dev/null | head -n 25; fi
  (( gui )) && cmd_gui wireshark "$pcap"
  return 0
}

cmd_gui() {
  case ${1:-} in
    maltego)
      ensure maltego || return 1
      nohup maltego >/dev/null 2>&1 &
      ok "Maltego started" ;;
    wireshark)
      ensure wireshark || return 1
      nohup wireshark ${2:+"$2"} >/dev/null 2>&1 &
      ok "Wireshark started" ;;
    spiderfoot)
      ensure spiderfoot || return 1
      info "SpiderFoot web UI -> http://127.0.0.1:5001   (Ctrl+C to stop)"
      "$(bin_of spiderfoot)" -l 127.0.0.1:5001 ;;
    nessus) cmd_nessus ;;
    *) err "Usage: $APP gui maltego | wireshark [file.pcap] | spiderfoot | nessus"; return 1 ;;
  esac
}

cmd_menu() {
  local c t
  while true; do
    banner
    cat <<'EOF'
   1) Install / update all tools        7) Full recon
   2) Check tool status                 8) Username OSINT (Sherlock)
   3) Quick scan                        9) File metadata (ExifTool)
   4) Network scan (ports/services)    10) PCAP analysis (TShark)
   5) Web scan                         11) Packet capture (tcpdump)
   6) OSINT (domain)                   12) GUI tools (Maltego/Wireshark/SpiderFoot/Nessus)
   0) Quit
EOF
    echo
    read -rp "Select: " c
    case $c in
      1) cmd_install ;;
      2) cmd_check ;;
      3) read -rp "Target (IP/domain/URL): " t; cmd_scan -t "$t" -m quick ;;
      4) read -rp "Target (IP/domain): "     t; cmd_scan -t "$t" -m network ;;
      5) read -rp "Target (domain/URL): "    t; cmd_scan -t "$t" -m web ;;
      6) read -rp "Domain: "                 t; cmd_scan -t "$t" -m osint ;;
      7) read -rp "Target (IP/domain/URL): " t; cmd_scan -t "$t" -m full ;;
      8) read -rp "Username: "               t; cmd_user "$t" ;;
      9) read -rp "File or folder: "         t; cmd_exif "$t" ;;
     10) read -rp "Path to .pcap/.pcapng: "  t; cmd_pcap "$t" ;;
     11) read -rp "Interface (blank = auto): " t; cmd_capture ${t:+-i "$t"} ;;
     12) read -rp "maltego / wireshark / spiderfoot / nessus: " t; cmd_gui $t ;;
      0|q|Q) exit 0 ;;
      *) warn "Invalid choice" ;;
    esac
    echo; read -rp "Press Enter to continue..." _
  done
}

# ----------------------------------------------------------------------------
main() {
  local cmd=${1:-menu}
  [[ $# -gt 0 ]] && shift
  case $cmd in
    install)  cmd_install "$@" ;;
    check)    cmd_check ;;
    scan)     cmd_scan "$@" ;;
    user)     cmd_user "$@" ;;
    social)   cmd_social "$@" ;;
    exif)     cmd_exif "$@" ;;
    pcap)     cmd_pcap "$@" ;;
    capture)  cmd_capture "$@" ;;
    gui)      cmd_gui "$@" ;;
    menu)     if [[ -t 0 ]]; then cmd_menu; else usage; fi ;;
    -t|--target) cmd_scan "$cmd" "$@" ;;
    -h|--help|help) usage ;;
    -V|--version|version) echo "$APP $VERSION" ;;
    *) err "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
