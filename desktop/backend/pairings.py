"""Pairing-file parsing and destination selection without device access."""
from __future__ import annotations

import hashlib
import hmac
import os
from pathlib import Path
import plistlib
import re
import tempfile

MAX_RECORD_SIZE = 1024 * 1024
DESTINATIONS = (
    'pairingFile.plist',
    'ALTPairingFile.mobiledevicepairing',
    'rpPairingFile.plist',
    'SideStore/Documents/ALTPairingFile.mobiledevicepairing',
    'waypoint-setup-pairing.plist',
)
# Destination conventions are public app integration contracts, as documented by
# jkcoxson/idevice_pair (MIT). No pairing material is included here.
KNOWN_APPS = {
    'lockdown': {
        name: 'pairingFile.plist' for name in
        ('Antrag', 'EnsWilde', 'Feather', 'Ksign', 'Protokolle', 'SparseBox',
         'StikDebug', 'StikDebug (Sideloaded)', 'StikStore')
    },
    'remote': {
        name: 'pairingFile.plist' for name in
        ('Antrag', 'Feather', 'Ksign', 'Protokolle', 'Reynard',
         'StikDebug (Sideloaded)', 'StosDebug')
    },
}
for table in KNOWN_APPS.values():
    table['SideStore'] = 'ALTPairingFile.mobiledevicepairing'
    table['LiveContainer'] = 'SideStore/Documents/ALTPairingFile.mobiledevicepairing'
KNOWN_APPS['remote']['Auto Capture'] = 'rpPairingFile.plist'
KNOWN_APPS['remote']['Waypoint'] = 'waypoint-setup-pairing.plist'


def device_id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9-]{1,128}', value):
        raise ValueError('Select a device with a valid identifier.')
    return value


def _text(record, key):
    value = record.get(key)
    if not isinstance(value, str) or not value.strip() or len(value) > 512:
        raise ValueError('The pairing record has a missing or invalid ' + key + '.')
    return value


def _bytes(record, key, length=None):
    value = record.get(key)
    if not isinstance(value, bytes) or not value or (length is not None and len(value) != length):
        raise ValueError('The pairing record has a missing or invalid ' + key + '.')
    return value


def inspect_bytes(data):
    if not data or len(data) > MAX_RECORD_SIZE:
        raise ValueError('Choose a non-empty pairing record smaller than 1 MB.')
    try:
        record = plistlib.loads(data)
    except Exception:
        raise ValueError('This file is not a valid XML or binary pairing plist.') from None
    if not isinstance(record, dict):
        raise ValueError('A pairing record must be a plist dictionary.')
    remote = any(key in record for key in ('private_key', 'public_key', 'identifier'))
    lockdown = any(key in record for key in ('HostCertificate', 'HostPrivateKey', 'HostID'))
    if remote and lockdown:
        raise ValueError('This plist mixes remote and Lockdown pairing formats.')
    if remote:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
        private = _bytes(record, 'private_key', 32)
        public = _bytes(record, 'public_key', 32)
        _text(record, 'identifier')
        expected = Ed25519PrivateKey.from_private_bytes(private).public_key().public_bytes_raw()
        if not hmac.compare_digest(expected, public):
            raise ValueError('The remote pairing public key does not match its private key.')
        if 'alt_irk' in record:
            _bytes(record, 'alt_irk', 16)
        context = public + record['identifier'].encode() + record.get('alt_irk', b'')
        return {'kind': 'remote', 'fingerprint': hashlib.sha256(context).hexdigest(),
                'embeddedDeviceId': None, 'hasWirelessIdentity': 'alt_irk' in record}
    if lockdown:
        from cryptography import x509
        from cryptography.hazmat.primitives import serialization
        _text(record, 'HostID')
        _text(record, 'SystemBUID')
        certificates = {}
        try:
            for key in ('HostCertificate', 'RootCertificate', 'DeviceCertificate'):
                raw = _bytes(record, key)
                loader = x509.load_pem_x509_certificate if raw.lstrip().startswith(b'-----BEGIN') else x509.load_der_x509_certificate
                certificates[key] = loader(raw)
            for prefix in ('Host', 'Root'):
                raw = _bytes(record, prefix + 'PrivateKey')
                loader = serialization.load_pem_private_key if raw.lstrip().startswith(b'-----BEGIN') else serialization.load_der_private_key
                private = loader(raw, password=None)
                actual = private.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
                expected = certificates[prefix+'Certificate'].public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
                if not hmac.compare_digest(actual, expected):
                    raise ValueError('key mismatch')
        except Exception:
            raise ValueError('The Lockdown certificates or matching private keys are invalid.') from None
        embedded = record.get('UDID')
        if embedded is not None:
            device_id(embedded)
        public = certificates['HostCertificate'].public_bytes(serialization.Encoding.DER)
        context = public + certificates['DeviceCertificate'].public_bytes(serialization.Encoding.DER) + record['HostID'].encode() + (embedded or '').encode()
        return {'kind': 'lockdown', 'fingerprint': hashlib.sha256(context).hexdigest(),
                'embeddedDeviceId': embedded, 'hasWirelessIdentity': bool(record.get('WiFiMACAddress'))}
    raise ValueError('This plist is not a supported remote or Lockdown pairing record.')


def read_record(path):
    path = Path(path)
    with path.open('rb') as stream:
        data = stream.read(MAX_RECORD_SIZE + 1)
    return data, inspect_bytes(data)


def save_private(directory, filename, data):
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        if os.name != 'nt':
            temporary.chmod(0o600)
        destination = directory / filename
        os.replace(temporary, destination)
        return destination
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def destination_path(filename):
    if filename not in DESTINATIONS:
        raise ValueError('Choose a supported pairing destination.')
    return '/Documents/' + filename


def destinations(kind, apps):
    if kind not in KNOWN_APPS:
        raise ValueError('Unknown pairing format.')
    return [
        {'bundleId': app['bundleId'], 'name': app['name'],
         'recommendedPath': KNOWN_APPS[kind].get(app['name']),
         'supportedPaths': list(DESTINATIONS)}
        for app in apps if app.get('fileSharing')
    ]
