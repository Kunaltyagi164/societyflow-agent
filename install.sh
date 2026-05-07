#!/bin/bash
# ================================================================
# SocietyFlow Agent — Universal Installer
# Tested on: Ubuntu 20.04, 22.04, 24.04, Debian 11/12,
#            Raspberry Pi OS (Bullseye / Bookworm), Armbian
# ================================================================
# Usage:
#   curl -sSL https://raw.githubusercontent.com/Kunaltyagi164/societyflow-agent/main/install.sh | sudo bash
# ================================================================

set -e

AGENT_DIR="/opt/societyflow-agent"
SERVICE_NAME="societyflow-agent"
GITHUB_RAW="https://raw.githubusercontent.com/Kunaltyagi164/societyflow-agent/main"
CONFIG_FILE="/etc/societyflow/agent.conf"
VENV_DIR="$AGENT_DIR/venv"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[SocietyFlow]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }
fail() { echo -e "${RED}  ❌ $1${NC}"; exit 1; }
hdr()  {
    echo ""
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${CYAN}  $1${NC}"
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

# ── Must be root ───────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    fail "Please run as root:  sudo bash install.sh"
fi

clear
hdr "🏘️  SocietyFlow Agent Installer"

# ── Detect OS and version ──────────────────────────────────────
log "Detecting system..."
OS_ID=""
OS_VERSION=""
IS_PI=false
IS_ARM=false

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-Linux}"
else
    OS_PRETTY="Unknown Linux"
fi

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || [ "$ARCH" = "armv7l" ] && IS_ARM=true
grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null && IS_PI=true

ok "System : $OS_PRETTY"
ok "Arch   : $ARCH"
$IS_PI && ok "Running on Raspberry Pi 🍓"
$IS_ARM && ! $IS_PI && ok "ARM device detected"

# ── Detect package manager ─────────────────────────────────────
PKG_MGR=""
if command -v apt-get &>/dev/null; then
    PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
    PKG_MGR="dnf"
elif command -v yum &>/dev/null; then
    PKG_MGR="yum"
elif command -v pacman &>/dev/null; then
    PKG_MGR="pacman"
else
    warn "Could not detect package manager — will try to continue"
fi
ok "Package manager: ${PKG_MGR:-unknown}"

# ── Install system packages ────────────────────────────────────
hdr "📦 Step 1 — Installing system packages"

install_pkg() {
    case "$PKG_MGR" in
        apt)    apt-get install -y -qq "$@" ;;
        dnf)    dnf install -y -q "$@" ;;
        yum)    yum install -y -q "$@" ;;
        pacman) pacman -S --noconfirm --quiet "$@" ;;
        *)      warn "Cannot auto-install: $*" ;;
    esac
}

# Update package index
case "$PKG_MGR" in
    apt)    apt-get update -qq ;;
    dnf|yum)dnf check-update -q 2>/dev/null || true ;;
esac

# Python 3 + venv
log "Installing Python3..."
case "$PKG_MGR" in
    apt)
        # python3-venv package name varies by distro version
        install_pkg python3 python3-pip python3-venv python3-dev build-essential 2>/dev/null || \
        install_pkg python3 python3-pip python3-dev build-essential 2>/dev/null || \
        install_pkg python3 python3-pip 2>/dev/null || true
        ;;
    dnf|yum)
        install_pkg python3 python3-pip python3-devel gcc 2>/dev/null || true ;;
    pacman)
        install_pkg python python-pip 2>/dev/null || true ;;
esac

# Find working python3
PYTHON3=""
for p in python3.12 python3.11 python3.10 python3.9 python3.8 python3; do
    if command -v "$p" &>/dev/null; then
        PYTHON3="$p"
        ok "Python: $($p --version)"
        break
    fi
done
[ -z "$PYTHON3" ] && fail "Python3 not found and could not be installed"

# nmap for device scanning
log "Installing nmap..."
install_pkg nmap 2>/dev/null || warn "nmap not installed — device auto-discovery may not work"

# ffmpeg for HLS streaming
log "Installing ffmpeg..."
install_pkg ffmpeg 2>/dev/null || warn "ffmpeg not installed — live video streaming will not work"
command -v ffmpeg &>/dev/null && ok "ffmpeg: $(ffmpeg -version 2>&1 | head -1 | cut -d' ' -f1-3)"

# ── Create directories ─────────────────────────────────────────
hdr "📁 Step 2 — Setting up directories"
mkdir -p "$AGENT_DIR"
mkdir -p /etc/societyflow
ok "Agent dir: $AGENT_DIR"

# ── Download agent files ───────────────────────────────────────
hdr "⬇  Step 3 — Downloading agent"

DL_CMD=""
if command -v curl &>/dev/null; then
    DL_CMD="curl -fsSL"
elif command -v wget &>/dev/null; then
    DL_CMD="wget -qO-"
    # wget needs different syntax for saving files
    dl_file() { wget -q "$1" -O "$2"; }
else
    install_pkg curl 2>/dev/null || install_pkg wget 2>/dev/null || fail "Neither curl nor wget available"
    command -v curl &>/dev/null && DL_CMD="curl -fsSL"
fi

dl_file() {
    if command -v curl &>/dev/null; then
        curl -fsSL "$1" -o "$2"
    else
        wget -q "$1" -O "$2"
    fi
}

dl_file "$GITHUB_RAW/agent.py"          "$AGENT_DIR/agent.py"       || fail "Failed to download agent.py"
dl_file "$GITHUB_RAW/biometric.py"      "$AGENT_DIR/biometric.py"   || warn "biometric.py not downloaded"
dl_file "$GITHUB_RAW/requirements.txt"  "$AGENT_DIR/requirements.txt" || fail "Failed to download requirements.txt"
dl_file "$GITHUB_RAW/version.txt"       "$AGENT_DIR/version.txt"    2>/dev/null || echo "1.0.0" > "$AGENT_DIR/version.txt"
ok "Agent files downloaded"

# ── Create Python virtual environment ─────────────────────────
hdr "🐍 Step 4 — Setting up Python environment"

log "Creating virtual environment..."

# Try creating venv — handle externally-managed environments
if "$PYTHON3" -m venv "$VENV_DIR" 2>/dev/null; then
    ok "Virtual environment created at $VENV_DIR"
elif "$PYTHON3" -m venv --system-site-packages "$VENV_DIR" 2>/dev/null; then
    ok "Virtual environment created (with system site-packages)"
else
    # Last resort: install python3-full which includes ensurepip
    warn "venv creation failed — trying to install python3-full / python3-venv..."
    install_pkg python3-full python3-venv 2>/dev/null || \
    install_pkg python3.11-venv 2>/dev/null || \
    install_pkg python3.10-venv 2>/dev/null || true
    "$PYTHON3" -m venv "$VENV_DIR" || fail "Cannot create virtual environment. Try: sudo apt install python3-full"
fi

VENV_PY="$VENV_DIR/bin/python"
VENV_PIP="$VENV_DIR/bin/pip"

log "Upgrading pip in venv..."
"$VENV_PY" -m pip install -q --upgrade pip

log "Installing Python packages..."
"$VENV_PIP" install -q -r "$AGENT_DIR/requirements.txt"
ok "Core packages installed"

log "Installing pyzk (ZKTeco/eSSL biometric support)..."
"$VENV_PIP" install -q pyzk 2>/dev/null && ok "pyzk installed" || warn "pyzk not installed — ZKTeco direct TCP may not work (HTTP fallback available)"

ok "Python environment ready"

# ── Agent Key ──────────────────────────────────────────────────
# Reconnect stdin to terminal (needed when script is run via curl | bash)
exec 0</dev/tty 2>/dev/null || true

hdr "🔑 Step 5 — Agent Key"
echo "  Get your Agent Key from the SocietyFlow portal:"
echo "  → CCTV → 🤖 Agent Setup → Generate Agent Key"
echo ""
while true; do
    read -p "  Paste your Agent Key (SF-AGT-...): " AGENT_KEY </dev/tty
    AGENT_KEY=$(echo "$AGENT_KEY" | tr -d '[:space:]')
    if [[ "$AGENT_KEY" == SF-AGT-* ]]; then
        ok "Agent key accepted"
        break
    else
        warn "Key should start with SF-AGT-  — try again"
    fi
done

# ── NVR/DVR Discovery ──────────────────────────────────────────
hdr "📡 Step 6 — Discover NVR/DVR Devices"
echo "  Scanning local network for NVR/DVR devices..."
echo "  (Takes ~10 seconds)"
echo ""

LOCAL_IP=$("$VENV_PY" -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "")
SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)
ok "Local IP: ${LOCAL_IP:-not detected}"

DISCOVERED_IPS=()
if [ -n "$SUBNET" ] && command -v nmap &>/dev/null; then
    SCAN_RESULT=$(nmap -p 80,8080,554 --open -oG - "${SUBNET}.0/24" 2>/dev/null | grep "Host:" | awk '{print $2}' | grep -v "^${LOCAL_IP}$" || true)
    if [ -n "$SCAN_RESULT" ]; then
        while IFS= read -r ip; do
            [ -n "$ip" ] && DISCOVERED_IPS+=("$ip")
        done <<< "$SCAN_RESULT"
        echo -e "  ${GREEN}Found ${#DISCOVERED_IPS[@]} potential device(s):${NC}"
        for ip in "${DISCOVERED_IPS[@]}"; do echo "    → $ip"; done
    else
        echo -e "  ${YELLOW}No devices auto-discovered.${NC}"
    fi
else
    echo -e "  ${YELLOW}Skipping scan (nmap not available or IP not detected).${NC}"
fi

DEVICES_JSON="[]"
DEVICE_COUNT=0

add_device() {
    local SUGGESTED_IP="$1"
    echo ""
    echo -e "  ${BOLD}--- NVR/DVR Device $((DEVICE_COUNT+1)) ---${NC}"

    # IP
    if [ -n "$SUGGESTED_IP" ]; then
        echo -e "  ${CYAN}Discovered: ${BOLD}$SUGGESTED_IP${NC}"
        read -p "  Correct IP? Press Enter to confirm or type a different IP: " INPUT_IP </dev/tty
        INPUT_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        DEVICE_IP="${INPUT_IP:-$SUGGESTED_IP}"
    else
        read -p "  IP address (e.g. 192.168.1.64): " INPUT_IP </dev/tty
        DEVICE_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        [ -z "$DEVICE_IP" ] && warn "No IP entered — skipping" && return
    fi
    ok "IP: $DEVICE_IP"

    # Port
    echo -e "  ${CYAN}Common ports: 80 (default), 8080 (some Dahua), 8000 (some Hikvision)${NC}"
    read -p "  Port? [80]: " INPUT_PORT </dev/tty
    INPUT_PORT=$(echo "$INPUT_PORT" | tr -d '[:space:]')
    DEVICE_PORT="${INPUT_PORT:-80}"
    ok "Port: $DEVICE_PORT"

    # Username
    read -p "  Username? [admin]: " INPUT_USER </dev/tty
    INPUT_USER=$(echo "$INPUT_USER" | tr -d '[:space:]')
    DEVICE_USER="${INPUT_USER:-admin}"
    ok "Username: $DEVICE_USER"

    # Password
    read -s -p "  Password (hidden): " DEVICE_PASS </dev/tty </dev/tty
    echo ""
    [ -z "$DEVICE_PASS" ] && warn "Empty password" || ok "Password: set"

    # RTSP Port
    read -p "  RTSP port? [554]: " INPUT_RTSP </dev/tty
    INPUT_RTSP=$(echo "$INPUT_RTSP" | tr -d '[:space:]')
    DEVICE_RTSP="${INPUT_RTSP:-554}"
    ok "RTSP Port: $DEVICE_RTSP"

    PASS_ESC=$(printf '%s' "$DEVICE_PASS" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))" 2>/dev/null | tr -d '"' || echo "$DEVICE_PASS")
    NEW_DEVICE="{\"ip\":\"$DEVICE_IP\",\"port\":$DEVICE_PORT,\"rtsp_port\":$DEVICE_RTSP,\"username\":\"$DEVICE_USER\",\"password\":\"$DEVICE_PASS\"}"

    if [ "$DEVICES_JSON" = "[]" ]; then
        DEVICES_JSON="[$NEW_DEVICE]"
    else
        DEVICES_JSON="${DEVICES_JSON%]},${NEW_DEVICE}]"
    fi
    DEVICE_COUNT=$((DEVICE_COUNT+1))
    ok "Device $DEVICE_COUNT saved"
}

# Auto-discovered
for ip in "${DISCOVERED_IPS[@]}"; do
    echo ""
    read -p "  Configure device at $ip? (y/n): " DO_CFG </dev/tty
    [[ "$DO_CFG" =~ ^[Yy]$ ]] && add_device "$ip"
done

# Manual
while true; do
    echo ""
    [ $DEVICE_COUNT -eq 0 ] && MSG="Add a device manually?" || MSG="Add another device?"
    read -p "  $MSG (y/n): " ADD_MORE </dev/tty
    [[ "$ADD_MORE" =~ ^[Yy]$ ]] && add_device "" || break
done

# ── Biometric / Attendance Devices ────────────────────────────
hdr "🖐  Step 7 — Biometric / Attendance Devices"
echo "  ZKTeco, eSSL, FingerTec, Realand — default port 4370"
echo ""

ATT_DEVICES_JSON="[]"
ATT_COUNT=0

add_att_device() {
    local SUGGESTED_IP="$1"
    echo ""
    echo -e "  ${BOLD}--- Attendance Device $((ATT_COUNT+1)) ---${NC}"

    if [ -n "$SUGGESTED_IP" ]; then
        echo -e "  ${CYAN}Found at: ${BOLD}$SUGGESTED_IP${NC}"
        read -p "  Correct IP? Press Enter to confirm or type different: " INPUT_IP </dev/tty
        INPUT_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        ATT_IP="${INPUT_IP:-$SUGGESTED_IP}"
    else
        read -p "  Device IP (e.g. 192.168.1.201): " INPUT_IP </dev/tty
        ATT_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        [ -z "$ATT_IP" ] && warn "No IP — skipping" && return
    fi
    ok "IP: $ATT_IP"

    read -p "  Port? [4370]: " INPUT_PORT </dev/tty
    INPUT_PORT=$(echo "$INPUT_PORT" | tr -d '[:space:]')
    ATT_PORT="${INPUT_PORT:-4370}"
    ok "Port: $ATT_PORT"

    echo "  Brands: ZKTeco / eSSL / FingerTec / Realand / Hikvision"
    read -p "  Brand? [ZKTeco]: " INPUT_BRAND </dev/tty
    INPUT_BRAND=$(echo "$INPUT_BRAND" | tr -d '[:space:]')
    ATT_BRAND="${INPUT_BRAND:-ZKTeco}"
    ok "Brand: $ATT_BRAND"

    read -p "  Location (e.g. Main Gate): " ATT_LOC </dev/tty
    ATT_LOC="${ATT_LOC:-Main Entrance}"
    ok "Location: $ATT_LOC"

    echo "  Device password (set on the machine itself — often blank or 0)"
    read -s -p "  Device password [blank]: " ATT_PASS </dev/tty </dev/tty
    echo ""

    NEW_ATT="{\"ip\":\"$ATT_IP\",\"port\":$ATT_PORT,\"brand\":\"$ATT_BRAND\",\"location\":\"$ATT_LOC\",\"password\":\"$ATT_PASS\",\"device_type\":\"biometric\"}"
    if [ "$ATT_DEVICES_JSON" = "[]" ]; then
        ATT_DEVICES_JSON="[$NEW_ATT]"
    else
        ATT_DEVICES_JSON="${ATT_DEVICES_JSON%]},${NEW_ATT}]"
    fi
    ATT_COUNT=$((ATT_COUNT+1))
    ok "Attendance device $ATT_COUNT saved"
}

# Scan port 4370
if [ -n "$SUBNET" ] && command -v nmap &>/dev/null; then
    log "Scanning for ZKTeco/eSSL devices (port 4370)..."
    ATT_SCAN=$(nmap -p 4370 --open -oG - "${SUBNET}.0/24" 2>/dev/null | grep "Host:" | awk '{print $2}' || true)
    if [ -n "$ATT_SCAN" ]; then
        echo -e "  ${GREEN}Found ZKTeco/eSSL device(s):${NC}"
        while IFS= read -r ip; do
            [ -z "$ip" ] && continue
            echo "    → $ip (port 4370)"
            read -p "  Configure this device? (y/n): " DO_ATT </dev/tty
            [[ "$DO_ATT" =~ ^[Yy]$ ]] && add_att_device "$ip"
        done <<< "$ATT_SCAN"
    fi
fi

while true; do
    echo ""
    [ $ATT_COUNT -eq 0 ] && MSG="Add a biometric/RFID attendance device?" || MSG="Add another attendance device?"
    read -p "  $MSG (y/n): " ADD_ATT </dev/tty
    [[ "$ADD_ATT" =~ ^[Yy]$ ]] && add_att_device "" || break
done

# ── Save config ────────────────────────────────────────────────
hdr "💾 Step 8 — Saving configuration"

cat > "$CONFIG_FILE" << EOF
{
  "agent_key"          : "$AGENT_KEY",
  "devices"            : $DEVICES_JSON,
  "attendance_devices" : $ATT_DEVICES_JSON
}
EOF

chmod 600 "$CONFIG_FILE"
ok "Config saved: $CONFIG_FILE"
ok "$DEVICE_COUNT NVR/DVR device(s) configured"
ok "$ATT_COUNT attendance device(s) configured"

# ── Systemd service ────────────────────────────────────────────
hdr "⚙️  Step 9 — Creating system service"

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=SocietyFlow Local Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$VENV_DIR/bin/python $AGENT_DIR/agent.py
WorkingDirectory=$AGENT_DIR
Restart=always
RestartSec=15
StandardOutput=journal
StandardError=journal
User=root
Environment=SF_CLOUD_URL=https://app.societyflow.in/api

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
ok "Service created and enabled (auto-starts on boot)"

# ── Start ──────────────────────────────────────────────────────
hdr "🚀 Step 10 — Starting agent"
systemctl start "$SERVICE_NAME"
sleep 4

STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null || echo "unknown")
if [ "$STATUS" = "active" ]; then
    ok "Agent is running!"
else
    warn "Agent may not have started. Check with:"
    warn "  sudo journalctl -u $SERVICE_NAME -n 40"
fi

# ── Done ───────────────────────────────────────────────────────
hdr "✅ Installation Complete!"
echo "  The agent is running and connecting to SocietyFlow."
echo "  Cameras and attendance data appear in your portal within 60 seconds."
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    Live logs  :  sudo journalctl -u $SERVICE_NAME -f"
echo "    Status     :  sudo systemctl status $SERVICE_NAME"
echo "    Restart    :  sudo systemctl restart $SERVICE_NAME"
echo "    Edit config:  sudo nano $CONFIG_FILE"
echo ""
echo -e "  ${BOLD}Python environment:${NC}  $VENV_DIR"
echo -e "  ${BOLD}Agent files:${NC}          $AGENT_DIR"
echo ""
