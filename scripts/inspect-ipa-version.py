"""Read the actual main app version from a physical-device IPA, without signing."""
import json
import plistlib
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as archive:
    names = [name for name in archive.namelist() if name.startswith('Payload/') and name.endswith('.app/Info.plist') and name.count('/') == 2]
    if len(names) != 1:
        raise ValueError('Expected one main app Info.plist')
    info = plistlib.loads(archive.read(names[0]))
    if 'iPhoneOS' not in info['CFBundleSupportedPlatforms']:
        raise ValueError('Expected a physical-device IPA')
    print(json.dumps({'version': info['CFBundleShortVersionString'], 'build': int(info['CFBundleVersion'])}))
