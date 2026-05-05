#!/bin/bash
# ================================================================
# SocietyFlow Agent — One-Command Installer
# Raspberry Pi OS / Ubuntu / Debian
# ================================================================
# Usage:
#   curl -sSL https://github.com/Kunaltyagi164/societyflow-agent/main/install.sh | sudo bash
# ================================================================

set -e

AGENT_DIR="/opt/societyflow-agent"
SERVICE_NAME="societyflow-agent"
GITHUB_RAW="https://github.com/Kunaltyagi164/societyflow-agent/main"
CONFIG_FILE="/etc/societyflow/agent.conf"
PYTHON="python3"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${CYAN}[SocietyFlow]${NC} $1"; }
ok()   { echo -e "${GREEN}  ✅ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠  $1${NC}"; }
fail() { echo -e "${RED}  ❌ $1${NC}"; exit 1; }
hdr()  { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${BOLD}${CYAN}  $1${NC}"; echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# ── Check root ─────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    fail "Please run as root:  sudo bash install.sh"
fi

clear
hdr "🏘️  SocietyFlow Agent Installer"
echo "  This installer will:"
echo "    1. Install required packages (Python, ffmpeg)"
echo "    2. Download and configure the agent"
echo "    3. Discover NVR/DVR devices on your network"
echo "    4. Connect to the SocietyFlow cloud"
echo ""

# ── Detect OS ──────────────────────────────────────────────────
log "Detecting system..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_NAME="$PRETTY_NAME"
else
    OS_NAME="Unknown Linux"
fi
ok "System: $OS_NAME"

if grep -q "Raspberry Pi" /proc/cpuinfo 2>/dev/null; then
    ok "Running on Raspberry Pi 🍓"
fi

# ── Install packages ───────────────────────────────────────────
hdr "📦 Step 1 — Installing packages"
apt-get update -qq
apt-get install -y -qq python3 python3-pip nmap
ok "Python3 installed"
apt-get install -y -qq ffmpeg
ok "ffmpeg installed"

# ── Download agent ─────────────────────────────────────────────
hdr "⬇  Step 2 — Downloading agent"
mkdir -p "$AGENT_DIR"
mkdir -p /etc/societyflow

if command -v curl &>/dev/null; then
    curl -sSL "$GITHUB_RAW/agent.py"          -o "$AGENT_DIR/agent.py"
    curl -sSL "$GITHUB_RAW/requirements.txt"  -o "$AGENT_DIR/requirements.txt"
    curl -sSL "$GITHUB_RAW/version.txt"       -o "$AGENT_DIR/version.txt" 2>/dev/null || echo "1.0.0" > "$AGENT_DIR/version.txt"
elif command -v wget &>/dev/null; then
    wget -q "$GITHUB_RAW/agent.py"            -O "$AGENT_DIR/agent.py"
    wget -q "$GITHUB_RAW/requirements.txt"    -O "$AGENT_DIR/requirements.txt"
else
    fail "Neither curl nor wget found."
fi

pip3 install -q --break-system-packages -r "$AGENT_DIR/requirements.txt" 2>/dev/null || \
pip3 install -q -r "$AGENT_DIR/requirements.txt"
# pyzk for ZKTeco/eSSL biometric devices
pip3 install -q --break-system-packages pyzk 2>/dev/null || pip3 install -q pyzk 2>/dev/null || true
ok "Agent downloaded and packages installed"

# ── Agent Key ──────────────────────────────────────────────────
hdr "🔑 Step 3 — Agent Key"
echo "  Get your Agent Key from the SocietyFlow portal:"
echo "  → CCTV → Agent Setup → Generate Agent Key"
echo ""
while true; do
    read -p "  Paste your Agent Key (SF-AGT-...): " AGENT_KEY
    AGENT_KEY=$(echo "$AGENT_KEY" | tr -d '[:space:]')
    if [[ "$AGENT_KEY" == SF-AGT-* ]]; then
        ok "Agent key accepted: $AGENT_KEY"
        break
    else
        warn "Key should start with SF-AGT-  — please try again"
    fi
done

# ── NVR/DVR Discovery ──────────────────────────────────────────
hdr "📡 Step 4 — Discover NVR/DVR Devices"
echo "  Scanning your local network for NVR/DVR devices..."
echo "  (This takes about 10 seconds)"
echo ""

# Get local subnet
LOCAL_IP=$(python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "")
SUBNET=$(echo "$LOCAL_IP" | cut -d. -f1-3)

DISCOVERED_IPS=()

if [ -n "$SUBNET" ]; then
    # Scan for devices with port 80 or 8080 (NVR/DVR web ports)
    SCAN_RESULT=$(nmap -p 80,8080,554 --open -oG - "${SUBNET}.0/24" 2>/dev/null | grep "Host:" | awk '{print $2}' | grep -v "$LOCAL_IP" || true)
    if [ -n "$SCAN_RESULT" ]; then
        while IFS= read -r ip; do
            DISCOVERED_IPS+=("$ip")
        done <<< "$SCAN_RESULT"
    fi
fi

if [ ${#DISCOVERED_IPS[@]} -gt 0 ]; then
    echo -e "  ${GREEN}Found ${#DISCOVERED_IPS[@]} potential device(s) on network:${NC}"
    for ip in "${DISCOVERED_IPS[@]}"; do
        echo "    → $ip"
    done
else
    echo -e "  ${YELLOW}No devices auto-discovered. You can enter IP(s) manually.${NC}"
fi

# ── Configure each device ───────────────────────────────────────
DEVICES_JSON="[]"
DEVICE_COUNT=0

add_device() {
    echo ""
    echo -e "  ${BOLD}--- Device $((DEVICE_COUNT+1)) ---${NC}"

    # ── IP Address ──────────────────────────────────────────────
    SUGGESTED_IP="${1:-}"  # passed in if from auto-discovery

    if [ -n "$SUGGESTED_IP" ]; then
        echo ""
        echo -e "  ${CYAN}Discovered device at: ${BOLD}$SUGGESTED_IP${NC}"
        read -p "  Is this the correct IP? Press Enter to confirm or type a different IP: " INPUT_IP
        INPUT_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        if [ -z "$INPUT_IP" ]; then
            DEVICE_IP="$SUGGESTED_IP"
        else
            DEVICE_IP="$INPUT_IP"
        fi
    else
        read -p "  Enter device IP address (e.g. 192.168.1.64): " INPUT_IP
        DEVICE_IP=$(echo "$INPUT_IP" | tr -d '[:space:]')
        if [ -z "$DEVICE_IP" ]; then
            warn "No IP entered — skipping this device"
            return
        fi
    fi
    ok "IP: $DEVICE_IP"

    # ── Port ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${CYAN}Common ports:${NC}  80 (default), 8080 (some Dahua), 8000 (some Hikvision)"
    read -p "  Port? Press Enter for default (80): " INPUT_PORT
    INPUT_PORT=$(echo "$INPUT_PORT" | tr -d '[:space:]')
    DEVICE_PORT="${INPUT_PORT:-80}"
    ok "Port: $DEVICE_PORT"

    # ── Username ────────────────────────────────────────────────
    echo ""
    read -p "  Username? Press Enter for default (admin): " INPUT_USER
    INPUT_USER=$(echo "$INPUT_USER" | tr -d '[:space:]')
    DEVICE_USER="${INPUT_USER:-admin}"
    ok "Username: $DEVICE_USER"

    # ── Password ────────────────────────────────────────────────
    echo ""
    read -s -p "  Password (input hidden): " DEVICE_PASS
    echo ""
    if [ -z "$DEVICE_PASS" ]; then
        warn "No password entered — using empty password"
    else
        ok "Password: set"
    fi

    # ── RTSP Port ───────────────────────────────────────────────
    echo ""
    echo -e "  ${CYAN}RTSP port is used for live video streams.${NC}"
    read -p "  RTSP port? Press Enter for default (554): " INPUT_RTSP
    INPUT_RTSP=$(echo "$INPUT_RTSP" | tr -d '[:space:]')
    DEVICE_RTSP="${INPUT_RTSP:-554}"
    ok "RTSP Port: $DEVICE_RTSP"

    # ── Build JSON for this device ──────────────────────────────
    # Escape password for JSON
    PASS_ESCAPED=$(echo "$DEVICE_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')

    NEW_DEVICE="{\"ip\":\"$DEVICE_IP\",\"port\":$DEVICE_PORT,\"rtsp_port\":$DEVICE_RTSP,\"username\":\"$DEVICE_USER\",\"password\":\"$PASS_ESCAPED\"}"

    if [ "$DEVICES_JSON" = "[]" ]; then
        DEVICES_JSON="[$NEW_DEVICE]"
    else
        DEVICES_JSON="${DEVICES_JSON%]},${NEW_DEVICE}]"
    fi

    DEVICE_COUNT=$((DEVICE_COUNT+1))
    ok "Device $DEVICE_COUNT saved"
}

# Process auto-discovered IPs
if [ ${#DISCOVERED_IPS[@]} -gt 0 ]; then
    for discovered_ip in "${DISCOVERED_IPS[@]}"; do
        echo ""
        echo -e "  ${BOLD}Configure discovered device at $discovered_ip?${NC}"
        read -p "  (y/n): " CONFIGURE_DISCOVERED
        if [[ "$CONFIGURE_DISCOVERED" =~ ^[Yy]$ ]]; then
            add_device "$discovered_ip"
        fi
    done
fi

# Ask if they want to add more devices manually
while true; do
    echo ""
    if [ $DEVICE_COUNT -eq 0 ]; then
        MSG="Add a device manually?"
    else
        MSG="Add another device?"
    fi
    read -p "  $MSG (y/n): " ADD_MORE
    if [[ "$ADD_MORE" =~ ^[Yy]$ ]]; then
        add_device ""
    else
        break
    fi
done

if [ $DEVICE_COUNT -eq 0 ]; then
    warn "No devices configured. You can add them later by editing:"
    warn "  $CONFIG_FILE"
    warn "Then run: sudo systemctl restart $SERVICE_NAME"
fi

# ── Attendance / Biometric Device Configuration ───────────────
hdr "🖐  Step 5 — Configure Biometric / RFID Attendance Devices"
echo "  These are fingerprint or RFID card scanners used for staff attendance."
echo "  Common brands: ZKTeco, eSSL, FingerTec, Realand, Granding"
echo "  Default port : 4370 (ZKTeco/eSSL standard)"
echo ""

ATT_DEVICES_JSON="[]"
ATT_COUNT=0

add_att_device() {
    echo ""
    echo -e "  ${BOLD}--- Attendance Device $((ATT_COUNT+1)) ---${NC}"

    # IP
    SUGGESTED_ATT_IP="${1:-}"
    if [ -n "$SUGGESTED_ATT_IP" ]; then
        echo -e "  ${CYAN}Found device at: ${BOLD}$SUGGESTED_ATT_IP${NC}"
        read -p "  Correct IP? Press Enter to confirm or type different IP: " INPUT_ATT_IP
        INPUT_ATT_IP=$(echo "$INPUT_ATT_IP" | tr -d "[:space:]")
        ATT_IP="${INPUT_ATT_IP:-$SUGGESTED_ATT_IP}"
    else
        read -p "  Device IP address (e.g. 192.168.1.201): " INPUT_ATT_IP
        ATT_IP=$(echo "$INPUT_ATT_IP" | tr -d "[:space:]")
        if [ -z "$ATT_IP" ]; then
            warn "No IP entered — skipping"
            return
        fi
    fi
    ok "IP: $ATT_IP"

    # Port
    read -p "  Port? Press Enter for default (4370 for ZKTeco/eSSL): " INPUT_ATT_PORT
    INPUT_ATT_PORT=$(echo "$INPUT_ATT_PORT" | tr -d "[:space:]")
    ATT_PORT="${INPUT_ATT_PORT:-4370}"
    ok "Port: $ATT_PORT"

    # Brand
    echo ""
    echo "  Common brands: ZKTeco / eSSL / FingerTec / Realand / Hikvision"
    read -p "  Brand (press Enter for ZKTeco): " INPUT_ATT_BRAND
    INPUT_ATT_BRAND=$(echo "$INPUT_ATT_BRAND" | tr -d "[:space:]")
    ATT_BRAND="${INPUT_ATT_BRAND:-ZKTeco}"
    ok "Brand: $ATT_BRAND"

    # Location
    read -p "  Location label (e.g. Main Gate, Staff Entrance): " ATT_LOC
    ATT_LOC="${ATT_LOC:-Main Entrance}"
    ok "Location: $ATT_LOC"

    # Password (ZKTeco device password, not web login — usually 0 or blank)
    echo ""
    echo "  Note: This is the device password set on the machine itself (often 0 or blank)"
    read -s -p "  Device password (Enter for blank): " ATT_PASS
    echo ""

    PASS_ESC=$(echo "$ATT_PASS" | sed "s/\\/\\\\/g; s/"/\\"/g")
    NEW_ATT="{"ip":"$ATT_IP","port":$ATT_PORT,"brand":"$ATT_BRAND","location":"$ATT_LOC","password":"$PASS_ESC","device_type":"biometric"}"

    if [ "$ATT_DEVICES_JSON" = "[]" ]; then
        ATT_DEVICES_JSON="[$NEW_ATT]"
    else
        ATT_DEVICES_JSON="${ATT_DEVICES_JSON%]},${NEW_ATT}]"
    fi

    ATT_COUNT=$((ATT_COUNT+1))
    ok "Attendance device $ATT_COUNT saved"
}

# Quick port scan for ZKTeco/eSSL devices (port 4370)
log "Scanning for biometric devices on port 4370..."
if command -v nmap &>/dev/null && [ -n "$SUBNET" ]; then
    ATT_SCAN=$(nmap -p 4370 --open -oG - "${SUBNET}.0/24" 2>/dev/null | grep "Host:" | awk "{print \$2}" || true)
    if [ -n "$ATT_SCAN" ]; then
        echo -e "  ${GREEN}Found ZKTeco/eSSL device(s):${NC}"
        while IFS= read -r ip; do
            echo "    → $ip (port 4370)"
            read -p "  Configure this device? (y/n): " DO_CONFIG
            if [[ "$DO_CONFIG" =~ ^[Yy]$ ]]; then
                add_att_device "$ip"
            fi
        done <<< "$ATT_SCAN"
    else
        echo -e "  ${YELLOW}No ZKTeco/eSSL devices found automatically.${NC}"
    fi
fi

while true; do
    echo ""
    if [ $ATT_COUNT -eq 0 ]; then
        MSG="Add a biometric/RFID device manually?"
    else
        MSG="Add another attendance device?"
    fi
    read -p "  $MSG (y/n): " ADD_ATT
    if [[ "$ADD_ATT" =~ ^[Yy]$ ]]; then
        add_att_device ""
    else
        break
    fi
done

# ── Write config file ──────────────────────────────────────────
hdr "💾 Step 6 — Saving configuration"

cat > "$CONFIG_FILE" << EOF
{
  "agent_key"          : "$AGENT_KEY",
  "devices"            : $DEVICES_JSON,
  "attendance_devices" : $ATT_DEVICES_JSON
}
EOF

chmod 600 "$CONFIG_FILE"
ok "Config saved to $CONFIG_FILE"
ok "$DEVICE_COUNT device(s) configured"

# ── Create systemd service ─────────────────────────────────────
hdr "⚙️  Step 7 — Creating system service"

cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=SocietyFlow Local Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$PYTHON $AGENT_DIR/agent.py
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
systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
ok "Service created and enabled (auto-starts on boot)"

# ── Start agent ────────────────────────────────────────────────
hdr "🚀 Step 8 — Starting agent"
systemctl start "$SERVICE_NAME"
sleep 4

STATUS=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
if [ "$STATUS" = "active" ]; then
    ok "Agent is running!"
else
    warn "Agent may not have started. Check with:"
    warn "  sudo journalctl -u $SERVICE_NAME -n 30"
fi

# ── Done ───────────────────────────────────────────────────────
hdr "✅ Installation Complete!"
echo "  The agent is now running and connecting to SocietyFlow."
echo "  Camera data will appear in your portal within 60 seconds."
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo "    View live logs  :  sudo journalctl -u $SERVICE_NAME -f"
echo "    Status          :  sudo systemctl status $SERVICE_NAME"
echo "    Restart         :  sudo systemctl restart $SERVICE_NAME"
echo "    Edit config     :  sudo nano $CONFIG_FILE"
echo ""
echo -e "  ${BOLD}What happens next:${NC}"
echo "    → Agent probes each configured device via ONVIF"
echo "    → Brand, model, channel count auto-detected"
echo "    → Cameras appear in portal under CCTV → Live View"
echo "    → Naming/labelling cameras is done in the portal"
echo ""
