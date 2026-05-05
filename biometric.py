"""
biometric.py — Biometric / RFID device handler for SocietyFlow Agent

Supported brands/protocols:
  - ZKTeco   (ZKLib TCP, port 4370) — ZKTeco, eSSL, FingerTec, Realand
  - Hikvision (ISAPI HTTP)
  - Generic HTTP (for custom firmware devices)

The ZKLib protocol is the most common — eSSL uses the same protocol.
"""

import socket
import logging
import requests
from datetime import datetime, timedelta

log = logging.getLogger('sf-agent')

# ══════════════════════════════════════════════════════════════
#  ZKTeco / eSSL Protocol Handler
#  Used by: ZKTeco, eSSL, FingerTec, Realand, Granding
# ══════════════════════════════════════════════════════════════

class ZKDevice:
    """
    Connects to ZKTeco / eSSL devices via the ZKLib TCP protocol.
    Port 4370 is the default for all these brands.

    Uses the 'zk' Python library (zklib / pyzk).
    Falls back to HTTP SOAP if ZK TCP is not available.
    """

    def __init__(self, ip, port=4370, timeout=10):
        self.ip      = ip
        self.port    = port
        self.timeout = timeout
        self._conn   = None

    def connect(self):
        try:
            from zk import ZK
            zk = ZK(self.ip, port=self.port, timeout=self.timeout,
                    password=0, force_udp=False, verbose=False)
            self._conn = zk.connect()
            return True
        except ImportError:
            log.warning('pyzk not installed — trying HTTP fallback for ' + self.ip)
            return False
        except Exception as e:
            log.warning('ZK connect failed for ' + self.ip + ': ' + str(e))
            return False

    def get_device_info(self):
        if not self._conn:
            return {}
        try:
            return {
                'serial_number': self._conn.get_serialnumber(),
                'model'        : self._conn.get_device_name(),
                'firmware'     : self._conn.get_firmware_version(),
                'brand'        : 'ZKTeco',
                'device_type'  : 'biometric',
            }
        except Exception:
            return {'brand': 'ZKTeco', 'device_type': 'biometric'}

    def get_attendance_records(self, since=None):
        """
        Fetch attendance records from the device.
        Returns list of dicts: {user_id, punch_time, method}
        """
        records = []
        if not self._conn:
            return records
        try:
            attendances = self._conn.get_attendance()
            for att in attendances:
                punch_time = att.timestamp
                if since and punch_time < since:
                    continue
                records.append({
                    'user_id'   : str(att.user_id),
                    'punch_time': punch_time.isoformat(),
                    'method'    : 'finger',
                    'punch_state': att.punch,   # 0=check_in, 1=check_out, etc.
                })
        except Exception as e:
            log.warning('ZK get_attendance failed: ' + str(e))
        return records

    def disconnect(self):
        if self._conn:
            try:
                self._conn.disconnect()
            except Exception:
                pass
            self._conn = None


# ══════════════════════════════════════════════════════════════
#  HTTP Fallback (SOAP / CGI for older devices)
# ══════════════════════════════════════════════════════════════

class HTTPBiometricDevice:
    """
    Fallback for devices that expose an HTTP/SOAP interface.
    Works with: older eSSL, some Hikvision access control devices.
    """

    def __init__(self, ip, port=80, username='admin', password=''):
        self.ip       = ip
        self.port     = port
        self.username = username
        self.password = password
        self.base     = 'http://' + ip + ':' + str(port)

    def get_device_info(self):
        # Try Hikvision ISAPI access control endpoint
        try:
            r = requests.get(
                self.base + '/ISAPI/System/deviceInfo',
                auth=(self.username, self.password),
                timeout=5
            )
            if r.status_code == 200:
                return {
                    'brand'      : 'Hikvision',
                    'device_type': 'rfid',
                    'model'      : 'Hikvision Access Control',
                }
        except Exception:
            pass

        # Try eSSL HTTP CGI
        try:
            r = requests.get(
                self.base + '/cgi-bin/ISAPI/System/deviceInfo',
                auth=(self.username, self.password),
                timeout=5
            )
            if r.status_code == 200:
                return {'brand': 'eSSL', 'device_type': 'biometric'}
        except Exception:
            pass

        return {}

    def get_attendance_records(self, since=None):
        records = []
        # Try Hikvision ACS attendance log
        try:
            payload = '''<AcsEventCond>
                <searchID>1</searchID>
                <searchResultPosition>0</searchResultPosition>
                <maxResults>500</maxResults>
                <major>0</major>
                <minor>0</minor>
            </AcsEventCond>'''
            r = requests.post(
                self.base + '/ISAPI/AccessControl/AcsEvent?format=json',
                data=payload,
                auth=(self.username, self.password),
                headers={'Content-Type': 'application/xml'},
                timeout=10
            )
            if r.status_code == 200:
                data   = r.json()
                events = data.get('AcsEvent', {}).get('InfoList', [])
                for ev in events:
                    t = ev.get('time', '')
                    if not t:
                        continue
                    try:
                        punch_time = datetime.fromisoformat(t.replace('Z', '+00:00'))
                    except Exception:
                        continue
                    if since and punch_time.replace(tzinfo=None) < since:
                        continue
                    records.append({
                        'user_id'   : str(ev.get('employeeNoString', ev.get('cardNo', '0'))),
                        'punch_time': punch_time.replace(tzinfo=None).isoformat(),
                        'method'    : 'rfid',
                    })
        except Exception as e:
            log.debug('HTTP attendance fetch failed for ' + self.ip + ': ' + str(e))
        return records


# ══════════════════════════════════════════════════════════════
#  Device Scanner — discovers biometric devices on LAN
# ══════════════════════════════════════════════════════════════

def scan_biometric_devices(subnet=None, timeout=3):
    """
    Scan local network for biometric/RFID attendance devices.
    Checks port 4370 (ZKTeco/eSSL default).
    Returns list of discovered IPs.
    """
    if not subnet:
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(('8.8.8.8', 80))
            local_ip = s.getsockname()[0]
            s.close()
            subnet = '.'.join(local_ip.split('.')[:3])
        except Exception:
            return []

    discovered = []
    PORTS      = [4370, 4000, 8080]  # ZKTeco, older eSSL, HTTP

    import concurrent.futures

    def check_host(ip):
        for p in PORTS:
            try:
                s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
                s.settimeout(timeout)
                result = s.connect_ex((ip, p))
                s.close()
                if result == 0:
                    return {'ip': ip, 'port': p}
            except Exception:
                pass
        return None

    ips = [subnet + '.' + str(i) for i in range(1, 255)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=50) as ex:
        results = ex.map(check_host, ips)

    for r in results:
        if r:
            discovered.append(r)
            log.info('Biometric device found: ' + r['ip'] + ':' + str(r['port']))

    return discovered


# ══════════════════════════════════════════════════════════════
#  Main Attendance Poller — called by agent
# ══════════════════════════════════════════════════════════════

def poll_attendance_device(ip, port, username, password, since=None):
    """
    Connect to a biometric/RFID device and return all records since `since`.
    Tries ZK protocol first (ZKTeco/eSSL), falls back to HTTP.

    Returns:
        {
          'device_info': {...},
          'records'    : [ {user_id, punch_time, method}, ... ],
          'is_online'  : True/False,
        }
    """
    result = {'device_info': {}, 'records': [], 'is_online': False}

    # Try ZK Protocol (ZKTeco/eSSL, port 4370)
    if port == 4370 or port == 4000:
        zk = ZKDevice(ip, port)
        if zk.connect():
            result['device_info'] = zk.get_device_info()
            result['records']     = zk.get_attendance_records(since=since)
            result['is_online']   = True
            zk.disconnect()
            return result

    # Try HTTP fallback
    http_dev = HTTPBiometricDevice(ip, port, username, password)
    info     = http_dev.get_device_info()
    if info:
        result['device_info'] = info
        result['records']     = http_dev.get_attendance_records(since=since)
        result['is_online']   = True

    return result
