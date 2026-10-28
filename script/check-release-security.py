#!/usr/bin/env python3
"""Verify local Release hardening without launching or collecting user data."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = 'dev.fomalhaut16.Levistica'
REQUIRED = {'com.apple.security.app-sandbox', 'com.apple.security.network.client',
            'com.apple.security.files.user-selected.read-write'}
FORBIDDEN = {'com.apple.security.get-task-allow', 'com.apple.security.cs.allow-jit',
             'com.apple.security.cs.allow-unsigned-executable-memory',
             'com.apple.security.cs.disable-executable-page-protection',
             'com.apple.security.cs.disable-library-validation',
             'com.apple.security.cs.allow-dyld-environment-variables'}
METADATA = {'com.apple.application-identifier', 'com.apple.developer.team-identifier'}


def validate(info, entitlements, signature):
    if not isinstance(info, dict) or not isinstance(entitlements, dict) or not isinstance(signature, str):
        raise ValueError('Invalid Release metadata shape')
    if (info.get('CFBundleIdentifier') != BUNDLE_ID or info.get('CFBundleExecutable') != 'Levistica'
            or info.get('LevisticaSourceState') != 'clean'
            or re.fullmatch(r'[0-9a-f]{40}', str(info.get('LevisticaSourceRevision'))) is None):
        raise ValueError('A clean normal Release identity is required')
    if any(entitlements.get(k) is not True for k in REQUIRED):
        raise ValueError('Required sandbox and narrow resource permissions are missing')
    if any(k in entitlements and entitlements[k] is not False for k in FORBIDDEN):
        raise ValueError('Debug access or a runtime exception is enabled')
    if set(entitlements) - REQUIRED - FORBIDDEN - METADATA:
        raise ValueError('An unreviewed entitlement is present')
    ats = info.get('NSAppTransportSecurity', {})
    if not isinstance(ats, dict) or set(ats) - {'NSAllowsArbitraryLoadsInWebContent'}:
        raise ValueError('Unreviewed App Transport Security settings are present')
    if 'NSAllowsArbitraryLoadsInWebContent' in ats and type(ats['NSAllowsArbitraryLoadsInWebContent']) is not bool:
        raise ValueError('Invalid web-content transport setting')
    matches = re.findall(r'^CodeDirectory[^\n]*\bflags=(0x[0-9a-fA-F]+)\b', signature, re.M)
    match = matches[0] if len(matches) == 1 else None
    identifiers = re.findall(r'^Identifier=(.*)$', signature, re.M)
    if not match or len(identifiers) != 1 or identifiers[0] != BUNDLE_ID:
        raise ValueError('Cannot verify code-signing identity or flags')
    flags = int(match, 16)
    if not flags & 0x10000:
        raise ValueError('Hardened Runtime is not enabled')
    return {'source': info['LevisticaSourceRevision'], 'sandbox': True, 'hardenedRuntime': True,
            'debugAccess': False, 'runtimeExceptions': False, 'adHocSignature': bool(flags & 2),
            'webHTTPPermitted': ats.get('NSAllowsArbitraryLoadsInWebContent') is True,
            'notarizationVerified': False, 'chromeEquivalent': False}


def checked_app(value):
    value = Path(value).absolute()
    ordinary = ROOT / '.local/DerivedData/Build/Products/Release/Levistica.app'
    if value != ordinary:
        parts = value.relative_to(ROOT / '.local/archives').parts
        if (len(parts) != 5 or re.fullmatch(r'local-[A-Za-z0-9]{6,32}', parts[0]) is None
                or parts[1:] != ('Levistica.xcarchive', 'Products', 'Applications', 'Levistica.app')):
            raise ValueError('Only project-local normal Release or archive bundles are accepted')
    current = ROOT
    for part in value.relative_to(ROOT).parts:
        current /= part
        if current.is_symlink():
            raise ValueError('Linked bundle paths are not accepted')
    return value


def check(value):
    app = checked_app(value)
    info_path = app / 'Contents/Info.plist'
    binary = app / 'Contents/MacOS/Levistica'
    if (any(p.is_symlink() for p in (app / 'Contents', app / 'Contents/MacOS', info_path, binary))
            or not info_path.is_file() or not binary.is_file()):
        raise ValueError('Missing or linked Release metadata/executable')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)],
                   check=True, capture_output=True, timeout=15)
    signature = subprocess.run(['/usr/bin/codesign', '-dvv', str(app)],
                               check=True, capture_output=True, text=True, timeout=10).stderr
    result = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', ':-', str(app)],
                            check=True, capture_output=True, timeout=10)
    info = plistlib.loads(info_path.read_bytes())
    entitlements = plistlib.loads(result.stdout)
    return validate(info, entitlements, signature)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=ROOT / '.local/DerivedData/Build/Products/Release/Levistica.app')
    args = parser.parse_args()
    try:
        print(json.dumps({'success': True, **check(args.app)}))
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.SubprocessError):
        print('Release security baseline could not be verified; no raw metadata exported.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
