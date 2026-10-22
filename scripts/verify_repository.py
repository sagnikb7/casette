"""Read-only repository/release checks, with optional built app and IPA validation."""
import argparse
import json
import plistlib
import re
import subprocess
import sys
import zipfile
from pathlib import Path

from release import bumped, source_hash
from mac_artifacts import validate_mac_app


def verify(root, app=None, ipa=None, platform='ipod'):
    manifest = json.loads((root / 'release/version.json').read_text())
    pending = manifest.get('pending')
    expected = bumped(manifest['version'], pending['bump']) if pending else manifest['version']
    if pending:
        assert any(pending.get(k) for k in ('added', 'changed', 'fixed')), 'Pending release needs notes'
    else:
        assert source_hash(root) == manifest['source_hash'], 'Shipping changes need release notes'
    info = plistlib.loads((root / 'OfflineMusicPlayer/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] in ('com.local.offlinemusicplayer', '$(PRODUCT_BUNDLE_IDENTIFIER)'), 'Update identity changed'
    project = (root / 'OfflineMusicPlayer.xcodeproj/project.pbxproj').read_text()
    assert project.count('PRODUCT_BUNDLE_IDENTIFIER = com.local.offlinemusicplayer;') == 2, 'App target identity changed'
    assert info['CFBundleShortVersionString'] == expected, 'Prepare the release before committing'
    expected_build = manifest['build'] + 1 if pending else manifest['build']
    state_path = root / 'dist/.release-state.json'
    if state_path.exists():
        state = json.loads(state_path.read_text())
        assert (state['base_version'], state['base_build'], state['pending']) == (manifest['version'], manifest['build'], pending), 'Staged release is stale'
        assert state['version'] == expected and state['source_hash'] == source_hash(root), 'Prepared source fingerprint mismatch'
        expected_build = state['build']
    assert info['CFBundleVersion'] == str(expected_build), 'Build number mismatch'
    assert info.get('UIFileSharingEnabled') is True and info.get('LSSupportsOpeningDocumentsInPlace') is True, 'Files/Finder sharing must stay enabled'
    assert info.get('CFBundleDisplayName') == 'Cassette', 'App display name must match Cassette branding'
    widget_source_info = root / 'CassetteWidget/Info.plist'
    if widget_source_info.exists():
        widget = plistlib.loads(widget_source_info.read_bytes())
        assert widget['CFBundleShortVersionString'] == expected and widget['CFBundleVersion'] == str(expected_build), 'Widget version/build mismatch'
        for entitlement in [root / 'OfflineMusicPlayer/OfflineMusicPlayer.entitlements', root / 'CassetteWidget/CassetteWidget.entitlements']:
            assert plistlib.loads(entitlement.read_bytes()).get('com.apple.security.application-groups') == ['group.com.local.offlinemusicplayer'], 'Widget App Groups must match'
    project_metadata = root / 'OfflineMusicPlayer/Resources/Project.json'
    if project_metadata.exists():
        url = json.loads(project_metadata.read_text())['githubURL']
        assert re.fullmatch(r'https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', url), 'Unsafe project link'
    notes = json.loads((root / 'OfflineMusicPlayer/Resources/ReleaseNotes.json').read_text())
    assert notes['version'] == expected, 'Bundled release notes mismatch'
    changelog = (root / 'docs/product/changelog.md').read_text()
    assert f"## {manifest['version']} —" in changelog, 'Finalized release missing from changelog'
    for doc in [root / 'README.md', root / 'AGENTS.md', *(root / 'docs').rglob('*.md')]:
        for link in re.findall(r'\]\(([^)]+)\)', doc.read_text()):
            if '://' in link or link.startswith('#'):
                continue
            target = link.split('#')[0]
            assert (doc.parent / target).exists(), f'Broken link: {doc.relative_to(root)} → {link}'
    if app and platform == 'mac':
        built = validate_mac_app(app)
        assert built['CFBundleVersion'] == str(expected_build) and built['CFBundleShortVersionString'] == expected, 'Mac version/build mismatch'
        resources = app / 'Contents/Resources'
        assert json.loads((resources / 'ReleaseNotes.json').read_text()) == notes
        if project_metadata.exists(): assert (resources / 'Project.json').read_bytes() == project_metadata.read_bytes()
        assert app.name == 'Cassette.app', 'Mac export must be named Cassette.app'
    if app and platform == 'ipod':
        built = plistlib.loads((app / 'Info.plist').read_bytes())
        assert built['CFBundleDisplayName'] == 'Cassette'
        assert built['CFBundleIdentifier'] == 'com.local.offlinemusicplayer', 'Built identity changed'
        for key in ['CFBundleVersion', 'CFBundleShortVersionString']:
            assert built[key] == info[key], f'Built app mismatch: {key}'
        assert built['CFBundleSupportedPlatforms'] == ['iPhoneOS']
        assert built['MinimumOSVersion'] == '15.0'
        executable = app / built['CFBundleExecutable']
        assert subprocess.check_output(['xcrun', 'lipo', '-archs', str(executable)], text=True).strip() == 'arm64'
        commands = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(executable)], text=True)
        assert re.search(r'platform\s+IOS\b', commands) and re.search(r'minos\s+15\.0\b', commands)
        assert built.get('UIFileSharingEnabled') is True and built.get('LSSupportsOpeningDocumentsInPlace') is True, 'Built app must support Files/Finder sharing'
        assert json.loads((app / 'ReleaseNotes.json').read_text()) == notes
        if project_metadata.exists(): assert (app / 'Project.json').read_bytes() == project_metadata.read_bytes()
        assert not list(app.rglob('*.xctest'))
        assert not any(p.name.lower().startswith('testtone') for p in app.rglob('*'))
        assert list(app.glob('AppIcon*.png')), 'Compiled app icon missing'
        if widget_source_info.exists():
            extension = app / 'PlugIns/CassetteWidget.appex'
            widget = plistlib.loads((extension / 'Info.plist').read_bytes())
            assert widget['NSExtension']['NSExtensionPointIdentifier'] == 'com.apple.widgetkit-extension'
            assert widget['CFBundleIdentifier'] == 'com.local.offlinemusicplayer.widget'
            assert widget['MinimumOSVersion'] == '15.0'
            for key in ['CFBundleVersion', 'CFBundleShortVersionString']: assert widget[key] == built[key]
            widget_executable = extension / widget['CFBundleExecutable']
            assert subprocess.check_output(['xcrun', 'lipo', '-archs', str(widget_executable)], text=True).strip() == 'arm64'
            widget_commands = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(widget_executable)], text=True)
            assert re.search(r'platform\s+IOS\b', widget_commands) and re.search(r'minos\s+15\.0\b', widget_commands)
            assert (extension / 'Assets.car').exists(), 'Widget brand asset missing'
            for bundle in [app, extension]:
                xcent = bundle / 'archived-expanded-entitlements.xcent'
                assert xcent.is_file(), f'Missing archived-expanded-entitlements.xcent in {bundle.name}'
                assert plistlib.loads(xcent.read_bytes()).get('com.apple.security.application-groups') == ['group.com.local.offlinemusicplayer'], f'Invalid xcent in {bundle.name}'
                signed_entitlements = subprocess.check_output(['codesign', '-d', '--entitlements', ':-', str(bundle)], stderr=subprocess.DEVNULL)
                assert plistlib.loads(signed_entitlements).get('com.apple.security.application-groups') == ['group.com.local.offlinemusicplayer'], f'Missing signed App Group entitlement in {bundle.name}'
    if ipa:
        assert ipa.name == f"Cassette-unsigned-{expected}.ipa", "IPA filename must match its version"
        with zipfile.ZipFile(ipa) as archive:
            assert archive.testzip() is None
            assert archive.read('Payload/OfflineMusicPlayer.app/Info.plist') == (app / 'Info.plist').read_bytes()
    print(f'Repository/release QA passed: {expected} ({expected_build})')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--app', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--platform', choices=['ipod', 'mac'], default='ipod')
    args = parser.parse_args()
    if args.ipa and args.platform != 'ipod': parser.error('--ipa requires --platform ipod')
    if args.ipa and not args.app:
        parser.error('--ipa requires --app')
    try:
        verify(args.root, args.app, args.ipa, args.platform)
    except (AssertionError, ValueError, OSError, KeyError) as error:
        print(f'QA failed: {error}', file=sys.stderr)
        sys.exit(1)
