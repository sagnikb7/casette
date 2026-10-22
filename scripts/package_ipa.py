"""Package an unsigned iphoneos .app for re-signing with a sideloading tool.

Usage: python3 scripts/package_ipa.py /path/to/OfflineMusicPlayer.app dist/Cassette-unsigned-1.1.4.ipa
This does not create a provisioning profile or an installable development signature.
"""
import argparse
import plistlib
import re
import shutil
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def is_macho(binary: Path) -> bool:
    if not binary.is_file():
        return False
    magic = binary.read_bytes()[:4]
    return magic in (b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')


def embed_entitlements(app: Path) -> None:
    app_entitlements = ROOT / 'OfflineMusicPlayer/OfflineMusicPlayer.entitlements'
    widget_entitlements = ROOT / 'CassetteWidget/CassetteWidget.entitlements'
    widget_appex = app / 'PlugIns/CassetteWidget.appex'
    if widget_appex.is_dir() and widget_entitlements.is_file():
        shutil.copyfile(widget_entitlements, widget_appex / 'archived-expanded-entitlements.xcent')
        with (widget_appex / 'Info.plist').open('rb') as f:
            widget_info = plistlib.load(f)
        widget_exec = widget_appex / widget_info.get('CFBundleExecutable', 'CassetteWidget')
        if is_macho(widget_exec):
            subprocess.run([
                'codesign', '--force', '--sign', '-',
                '--entitlements', str(widget_entitlements),
                '--generate-entitlement-der',
                str(widget_appex)
            ], check=True)
    if app_entitlements.is_file():
        shutil.copyfile(app_entitlements, app / 'archived-expanded-entitlements.xcent')
        with (app / 'Info.plist').open('rb') as f:
            app_info = plistlib.load(f)
        app_exec = app / app_info.get('CFBundleExecutable', 'OfflineMusicPlayer')
        if is_macho(app_exec):
            subprocess.run([
                'codesign', '--force', '--sign', '-',
                '--entitlements', str(app_entitlements),
                '--generate-entitlement-der',
                str(app)
            ], check=True)


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
app = args.app.resolve()
if not app.is_dir() or app.suffix != '.app':
    parser.error('Input must be an existing .app directory')
with (app / 'Info.plist').open('rb') as source:
    info = plistlib.load(source)
if info.get('CFBundleSupportedPlatforms') != ['iPhoneOS']:
    parser.error('Use an iphoneos device build, not a simulator or Mac Catalyst build')
if not (app / info['CFBundleExecutable']).is_file():
    parser.error('The app executable is missing')
if list(app.rglob('*.xctest')):
    parser.error('Test bundles must not be included in the IPA')
if any(file.name.lower().startswith('testtone') for file in app.rglob('*')):
    parser.error('Test audio must not be shipped in the app')
version = info.get('CFBundleShortVersionString', '')
if not re.fullmatch(r'\d+\.\d+\.\d+', version):
    parser.error('Built app must have a three-part release version')
if args.output.name != f'Cassette-unsigned-{version}.ipa':
    parser.error('IPA filename must include the built app version: Cassette-unsigned-' + version + '.ipa')
embed_entitlements(app)
args.output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(args.output, 'w', compression=zipfile.ZIP_DEFLATED) as ipa:
    for file in sorted(app.rglob('*')):
        if file.is_symlink():
            parser.error(f'Unexpected symlink: {file}')
        if file.is_file():
            ipa.write(file, Path('Payload') / app.name / file.relative_to(app))
with zipfile.ZipFile(args.output) as ipa:
    if ipa.testzip() is not None:
        raise RuntimeError('IPA archive integrity check failed')
print(args.output.resolve())
print(f"Bundle: {info['CFBundleIdentifier']}; minimum iOS: {info['MinimumOSVersion']}")
print('Unsigned package: must be signed/provisioned by Sideloadly before installation.')
