#!/usr/bin/env python3
"""
SocietyFlow Local Agent
========================
Runs on Raspberry Pi / Linux inside the society network.
Discovers NVR/DVR via ONVIF, syncs camera data to cloud,
forwards motion/offline alerts, serves HLS streams via ffmpeg.

Usage:
    python3 agent.py --key SF-AGT-XXXXXX
    python3 agent.py  (reads key from /etc/societyflow/agent.conf)
"""

import os, sys, json, time, socket, logging, threading, subprocess
import requests
from datetime import datetime, timedelta
from pathlib import Path
try:
    from biometric import poll_attendance_device, scan_biometric_devices
    BIOMETRIC_AVAILABLE = True
except ImportError:
    BIOMETRIC_AVAILABLE = False

# ── Config ─────────────────────────────────────────────────────
CLOUD_URL      = os.environ.get('SF_CLOUD_URL', 'https://app.societyflow.in/api')
CONFIG_FILE    = Path('/etc/societyflow/agent.conf')
HLS_PORT       = int(os.environ.get('SF_HLS_PORT', 8888))
HEARTBEAT_SEC  = 30
SYNC_SEC       = 60
STREAM_DIR     = Path('/tmp/sf_streams')

logging.basicConfig(
    level   = logging.INFO,
    format  = '[%(asctime)s] %(levelname)s — %(message)s',
    datefmt = '%H:%M:%S',
)
log = logging.getLogger('sf-agent')

# ── Load / Save config ─────────────────────────────────────────
def load_config():
    if CONFIG_FILE.exists():
        try:
            return json.loads(CONFIG_FILE.read_text())
        except Exception:
            pass
    return {}

def save_config(cfg):
    CONFIG_FILE.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_FILE.write_text(json.dumps(cfg, indent=2))

# ── Cloud API calls ────────────────────────────────────────────
def cloud_post(path, data, timeout=15):
    try:
        r = requests.post(CLOUD_URL + path, json=data, timeout=timeout)
        return r.json()
    except Exception as e:
        log.warning('Cloud POST ' + path + ' failed: ' + str(e))
        return None

# ── System info ────────────────────────────────────────────────
def get_local_ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(('8.8.8.8', 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return '127.0.0.1'

def get_os_info():
    try:
        with open('/etc/os-release') as f:
            lines = dict(l.strip().split('=', 1) for l in f if '=' in l)
        return lines.get('PRETTY_NAME', 'Linux').strip('"')
    except Exception:
        return 'Linux'

def get_hostname():
    try:
        return socket.gethostname()
    except Exception:
        return 'unknown'

def get_agent_version():
    ver_file = Path(__file__).parent / 'version.txt'
    if ver_file.exists():
        return ver_file.read_text().strip()
    return '1.0.0'

# ── ONVIF Device Discovery ─────────────────────────────────────
def discover_onvif_devices(timeout=5):
    """
    Sends WS-Discovery probe on local network.
    Returns list of discovered device URIs.
    """
    discovered = []
    WS_DISCOVERY_MSG = b'''<?xml version="1.0" encoding="UTF-8"?>
<e:Envelope xmlns:e="http://www.w3.org/2003/05/soap-envelope"
  xmlns:w="http://schemas.xmlsoap.org/ws/2004/08/addressing"
  xmlns:d="http://schemas.xmlsoap.org/ws/2005/04/discovery"
  xmlns:dn="http://www.onvif.org/ver10/network/wsdl">
  <e:Header>
    <w:MessageID>uuid:84ede3de-7dec-11d0-c360-F01234567890</w:MessageID>
    <w:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</w:To>
    <w:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</w:Action>
  </e:Header>
  <e:Body>
    <d:Probe><d:Types>dn:NetworkVideoTransmitter</d:Types></d:Probe>
  </e:Body>
</e:Envelope>'''

    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.settimeout(timeout)
        sock.sendto(WS_DISCOVERY_MSG, ('239.255.255.250', 3702))
        while True:
            try:
                data, addr = sock.recvfrom(4096)
                ip = addr[0]
                if ip not in [d['ip'] for d in discovered]:
                    discovered.append({'ip': ip, 'raw': data.decode('utf-8', errors='ignore')})
                    log.info('WS-Discovery found device at ' + ip)
            except socket.timeout:
                break
    except Exception as e:
        log.warning('WS-Discovery error: ' + str(e))
    finally:
        try: sock.close()
        except Exception: pass
    return discovered

def probe_onvif_device(ip, port=80, username='admin', password=''):
    """
    Connect to a specific device via ONVIF and get device info + stream URLs.
    Works with Hikvision, Dahua, CP Plus, Bosch, Axis, Uniview, TVT and more.
    """
    result = {
        'ip': ip, 'port': port,
        'username': username, 'password': password,
        'name': 'Device ' + ip,
        'brand': 'Generic',
        'is_online': False,
        'channel_count': 0,
        'cameras': [],
        'device_type': 'unknown',  # nvr / dvr / ipcamera
    }

    # Try ONVIF device info via zeep (if installed)
    try:
        from onvif import ONVIFCamera
        cam = ONVIFCamera(ip, port, username, password,
                          '/usr/local/lib/python3/dist-packages/onvif/wsdl/')
        info = cam.devicemgmt.GetDeviceInformation()
        result['name']      = info.get('Model', 'Device ' + ip)
        result['brand']     = info.get('Manufacturer', 'Generic')
        result['is_online'] = True

        # Get media profiles (= channels/cameras)
        media   = cam.create_media_service()
        profiles= media.GetProfiles()
        result['channel_count'] = len(profiles)

        cameras = []
        for i, profile in enumerate(profiles):
            try:
                uri_req = media.create_type('GetStreamUri')
                uri_req.ProfileToken = profile.token
                uri_req.StreamSetup  = {
                    'Stream'   : 'RTP-Unicast',
                    'Transport': {'Protocol': 'RTSP'},
                }
                uri  = media.GetStreamUri(uri_req)
                rtsp = uri.Uri
                # Embed credentials in RTSP URL
                if '@' not in rtsp:
                    rtsp = rtsp.replace('rtsp://', 'rtsp://' + username + ':' + password + '@')
                cameras.append({
                    'channel_no' : i + 1,
                    'name'       : getattr(profile, 'Name', 'Camera ' + str(i+1)),
                    'rtsp_url'   : rtsp,
                    'stream_type': 'RTSP',
                    'ip'         : ip,
                    'is_online'  : True,
                })
            except Exception:
                pass

        result['cameras'] = cameras
        # Heuristic: many channels = NVR, few = DVR, 1 = IP camera
        ch = len(profiles)
        result['device_type'] = 'nvr' if ch >= 4 else ('dvr' if ch >= 2 else 'ipcamera')

    except ImportError:
        # onvif-zeep not installed — try basic HTTP probe
        result = _probe_http_fallback(result)
    except Exception as e:
        log.warning('ONVIF probe failed for ' + ip + ': ' + str(e))
        result = _probe_http_fallback(result)

    return result

def _probe_http_fallback(result):
    """
    Fallback: try common HTTP endpoints to detect device type and build RTSP URLs.
    Supports Hikvision ISAPI, Dahua HTTP API, generic RTSP construction.
    """
    ip       = result['ip']
    port     = result['port']
    username = result['username']
    password = result['password']

    # Try Hikvision ISAPI
    try:
        r = requests.get(
            'http://' + ip + ':' + str(port) + '/ISAPI/System/deviceInfo',
            auth=(username, password), timeout=5
        )
        if r.status_code == 200 and '<deviceInfo>' in r.text:
            import xml.etree.ElementTree as ET
            root  = ET.fromstring(r.text)
            ns    = {'h': 'http://www.hikvision.com/ver20/XMLSchema'}
            model = root.findtext('h:model', default='Hikvision Device', namespaces=ns)
            result['name']       = model
            result['brand']      = 'Hikvision'
            result['is_online']  = True
            # Build standard Hikvision RTSP URLs
            channels = []
            for ch in range(1, 9):
                rtsp = ('rtsp://' + username + ':' + password + '@' + ip
                        + ':554/Streaming/Channels/' + str(ch) + '01')
                channels.append({
                    'channel_no' : ch, 'name': 'Camera ' + str(ch),
                    'rtsp_url'   : rtsp, 'stream_type': 'RTSP',
                    'ip': ip, 'is_online': True,
                })
            result['cameras']       = channels
            result['channel_count'] = 8
            result['device_type']   = 'nvr'
            return result
    except Exception:
        pass

    # Try Dahua HTTP API
    try:
        r = requests.get(
            'http://' + ip + ':' + str(port) + '/cgi-bin/magicBox.cgi?action=getSystemInfo',
            auth=(username, password), timeout=5
        )
        if r.status_code == 200 and 'serialNo' in r.text.lower():
            result['brand']     = 'Dahua'
            result['name']      = 'Dahua Device ' + ip
            result['is_online'] = True
            channels = []
            for ch in range(1, 5):
                rtsp = ('rtsp://' + username + ':' + password + '@' + ip
                        + ':554/cam/realmonitor?channel=' + str(ch) + '&subtype=0')
                channels.append({
                    'channel_no': ch, 'name': 'Camera ' + str(ch),
                    'rtsp_url': rtsp, 'stream_type': 'RTSP',
                    'ip': ip, 'is_online': True,
                })
            result['cameras']       = channels
            result['channel_count'] = 4
            result['device_type']   = 'dvr'
            return result
    except Exception:
        pass

    # Generic RTSP probe — just mark online and build standard URL
    try:
        s = socket.socket()
        s.settimeout(3)
        s.connect((ip, 554))
        s.close()
        result['is_online'] = True
        result['device_type'] = 'ipcamera'
        result['cameras'] = [{
            'channel_no': 1, 'name': 'Camera ' + ip,
            'rtsp_url': 'rtsp://' + username + ':' + password + '@' + ip + ':554/stream1',
            'stream_type': 'RTSP', 'ip': ip, 'is_online': True,
        }]
        result['channel_count'] = 1
    except Exception:
        result['is_online'] = False

    return result

# ── HLS Stream Server (ffmpeg) ─────────────────────────────────
class StreamServer:
    """
    Uses ffmpeg to convert RTSP → HLS segments.
    Portal embeds the .m3u8 URL in a video player.
    Streams are lazy — only started when someone requests them.
    """

    def __init__(self):
        self.processes = {}  # camera_id → subprocess
        STREAM_DIR.mkdir(parents=True, exist_ok=True)

    def _ffmpeg_path(self):
        for p in ['/usr/bin/ffmpeg', '/usr/local/bin/ffmpeg']:
            if Path(p).exists():
                return p
        return 'ffmpeg'

    def start_stream(self, camera_id, rtsp_url):
        if camera_id in self.processes:
            proc = self.processes[camera_id]
            if proc.poll() is None:
                return  # already running

        out_dir = STREAM_DIR / ('camera' + str(camera_id))
        out_dir.mkdir(parents=True, exist_ok=True)

        cmd = [
            self._ffmpeg_path(),
            '-rtsp_transport', 'tcp',
            '-i', rtsp_url,
            '-c:v', 'copy',
            '-c:a', 'aac',
            '-f', 'hls',
            '-hls_time', '2',
            '-hls_list_size', '5',
            '-hls_flags', 'delete_segments',
            str(out_dir / 'index.m3u8'),
        ]
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self.processes[camera_id] = proc
            log.info('HLS stream started: camera ' + str(camera_id))
        except Exception as e:
            log.warning('Stream start failed: ' + str(e))

    def stop_stream(self, camera_id):
        if camera_id in self.processes:
            try:
                self.processes[camera_id].terminate()
            except Exception:
                pass
            del self.processes[camera_id]

    def stop_all(self):
        for cam_id in list(self.processes.keys()):
            self.stop_stream(cam_id)

    def serve(self):
        """Serve HLS files over HTTP on HLS_PORT."""
        import http.server
        import functools

        handler = functools.partial(
            http.server.SimpleHTTPRequestHandler,
            directory=str(STREAM_DIR),
        )
        server = http.server.HTTPServer(('0.0.0.0', HLS_PORT), handler)
        log.info('HLS server listening on port ' + str(HLS_PORT))
        server.serve_forever()

# ── Main Agent ─────────────────────────────────────────────────
class SocietyFlowAgent:

    def __init__(self, agent_key):
        self.agent_key    = agent_key
        self.society_id   = None
        self.society_name = ''
        self.devices      = []  # discovered NVR/DVR/cameras
        self.stream_srv   = StreamServer()

    def _payload_base(self):
        return {'agent_key': self.agent_key}

    def register(self):
        log.info('Registering with SocietyFlow cloud...')
        resp = cloud_post('/agent/register', {
            **self._payload_base(),
            'hostname'  : get_hostname(),
            'local_ip'  : get_local_ip(),
            'os_info'   : get_os_info(),
            'version'   : get_agent_version(),
        })
        if not resp or not resp.get('success'):
            log.error('Registration failed: ' + str(resp))
            return False
        self.society_id   = resp['society_id']
        self.society_name = resp.get('society_name', '')
        log.info('✅ Connected to: ' + self.society_name)
        return True

    def heartbeat(self):
        nvr_count = sum(1 for d in self.devices if d.get('device_type') == 'nvr')
        dvr_count = sum(1 for d in self.devices if d.get('device_type') == 'dvr')
        cam_count = sum(len(d.get('cameras', [])) for d in self.devices)
        local_ip  = get_local_ip()
        cloud_post('/agent/heartbeat', {
            **self._payload_base(),
            'nvr_count'      : nvr_count,
            'dvr_count'      : dvr_count,
            'camera_count'   : cam_count,
            'stream_base_url': 'http://' + local_ip + ':' + str(HLS_PORT),
        })

    def discover_and_sync(self):
        log.info('Scanning local network for NVR/DVR devices...')
        cfg      = load_config()
        manual   = cfg.get('devices', [])  # manually configured devices
        found    = discover_onvif_devices(timeout=5)

        nvr_devices  = []
        dvr_devices  = []
        cameras      = []
        seen_ips     = set()

        # Process WS-Discovery results
        for dev in found:
            ip = dev['ip']
            if ip in seen_ips:
                continue
            seen_ips.add(ip)
            info = probe_onvif_device(ip)
            self._classify_device(info, nvr_devices, dvr_devices, cameras)

        # Process manually configured devices
        for dev in manual:
            ip = dev.get('ip')
            if not ip or ip in seen_ips:
                continue
            seen_ips.add(ip)
            info = probe_onvif_device(
                ip,
                port     = dev.get('port', 80),
                username = dev.get('username', 'admin'),
                password = dev.get('password', ''),
            )
            # Override name/brand if specified manually
            if dev.get('name'):     info['name']  = dev['name']
            if dev.get('brand'):    info['brand'] = dev['brand']
            if dev.get('location'): info['location'] = dev['location']
            self._classify_device(info, nvr_devices, dvr_devices, cameras)

        self.devices = nvr_devices + dvr_devices + [{'device_type':'ipcamera', 'cameras':cameras}]

        # Push to cloud
        resp = cloud_post('/agent/sync', {
            **self._payload_base(),
            'nvr_devices': nvr_devices,
            'dvr_devices': dvr_devices,
            'cameras'    : cameras,
        })
        if resp and resp.get('success'):
            synced = resp.get('synced', {})
            log.info('Sync complete — NVR:' + str(synced.get('nvr', 0))
                     + ' DVR:' + str(synced.get('dvr', 0))
                     + ' Cameras:' + str(synced.get('cameras', 0)))

        # Start HLS streams for all online cameras
        for cam in cameras:
            if cam.get('is_online') and cam.get('rtsp_url'):
                self.stream_srv.start_stream(
                    str(cam.get('channel_no', 1)) + '_' + cam.get('ip', ''),
                    cam['rtsp_url'],
                )

    def _classify_device(self, info, nvr_list, dvr_list, cam_list):
        dtype = info.get('device_type', 'unknown')
        cams  = info.get('cameras', [])
        if dtype == 'nvr':
            nvr_list.append(info)
        elif dtype == 'dvr':
            dvr_list.append(info)
        else:
            cam_list.extend(cams)

    def send_alert(self, camera_id, location, alert_type, severity, description):
        cloud_post('/agent/alert', {
            **self._payload_base(),
            'camera_id'  : str(camera_id),
            'location'   : location,
            'alert_type' : alert_type,   # motion / offline / tamper
            'severity'   : severity,     # low / medium / high / critical
            'description': description,
        })

    def sync_attendance(self):
        """Poll all configured biometric/RFID devices and push records to cloud."""
        if not BIOMETRIC_AVAILABLE:
            return

        cfg             = load_config()
        att_devices     = cfg.get('attendance_devices', [])
        if not att_devices:
            return

        all_device_info = []
        for dev_cfg in att_devices:
            ip       = dev_cfg.get('ip', '')
            port     = int(dev_cfg.get('port', 4370))
            username = dev_cfg.get('username', 'admin')
            password = dev_cfg.get('password', '')

            if not ip:
                continue

            log.info('Polling biometric device: ' + ip + ':' + str(port))
            # Only fetch last 24 hours to avoid huge initial sync
            since = datetime.utcnow() - timedelta(hours=24)

            result = poll_attendance_device(ip, port, username, password, since=since)
            dev_info = result.get('device_info', {})

            all_device_info.append({
                'ip'           : ip,
                'port'         : port,
                'is_online'    : result.get('is_online', False),
                'brand'        : dev_info.get('brand', dev_cfg.get('brand', 'ZKTeco')),
                'model'        : dev_info.get('model', ''),
                'serial_number': dev_info.get('serial_number', ''),
                'device_type'  : dev_info.get('device_type', 'biometric'),
                'location'     : dev_cfg.get('location', 'Main Entrance'),
            })

            records = result.get('records', [])
            if records:
                resp = cloud_post('/agent/attendance', {
                    'agent_key'  : self.agent_key,
                    'device_ip'  : ip,
                    'device_port': port,
                    'records'    : records,
                })
                if resp and resp.get('success'):
                    log.info('Attendance sync: ' + str(resp.get('inserted', 0))
                             + ' records pushed for ' + ip)

        # Push device info to cloud
        if all_device_info:
            cloud_post('/agent/attendance-devices', {
                'agent_key': self.agent_key,
                'devices'  : all_device_info,
            })

    def run(self):
        # Register first
        retries = 0
        while not self.register():
            retries += 1
            wait = min(60, retries * 10)
            log.info('Retrying in ' + str(wait) + 's...')
            time.sleep(wait)

        # Start HLS HTTP server in background thread
        t = threading.Thread(target=self.stream_srv.serve, daemon=True)
        t.start()

        # Initial scan
        self.discover_and_sync()
        self.sync_attendance()

        # Main loop
        last_sync = time.time()
        log.info('Agent running. Heartbeat every ' + str(HEARTBEAT_SEC)
                 + 's, sync every ' + str(SYNC_SEC) + 's')
        while True:
            time.sleep(HEARTBEAT_SEC)
            self.heartbeat()
            if time.time() - last_sync >= SYNC_SEC:
                self.discover_and_sync()
                self.sync_attendance()
                last_sync = time.time()

# ── Entry point ────────────────────────────────────────────────
if __name__ == '__main__':
    import argparse

    parser = argparse.ArgumentParser(description='SocietyFlow Local Agent')
    parser.add_argument('--key',      help='Agent key (SF-AGT-XXXXXX)')
    parser.add_argument('--cloud',    help='Cloud URL override')
    args = parser.parse_args()

    cfg = load_config()

    # Key resolution: arg > config file > prompt
    key = args.key or cfg.get('agent_key') or ''
    if not key:
        print('\n🏘️  SocietyFlow Agent Setup')
        print('━' * 40)
        print('Get your Agent Key from the portal:')
        print('  Settings → CCTV → Generate Agent Key')
        print()
        key = input('Enter your Agent Key: ').strip()
        if not key:
            print('❌ No key provided. Exiting.')
            sys.exit(1)

    if args.cloud:
        CLOUD_URL = args.cloud.rstrip('/')

    cfg['agent_key'] = key
    save_config(cfg)

    agent = SocietyFlowAgent(key)
    try:
        agent.run()
    except KeyboardInterrupt:
        log.info('Agent stopped')
        agent.stream_srv.stop_all()
