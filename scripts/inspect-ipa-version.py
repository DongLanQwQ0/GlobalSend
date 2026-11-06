"""Read the version from a physical-device IPA, without signing."""
import argparse
import json
import plistlib
import zipfile


def bundle_version(info):
    return {'version': info['CFBundleShortVersionString'], 'build': int(info['CFBundleVersion'])}


def inspect(path, verify_share_package):
    with zipfile.ZipFile(path) as archive:
        def plist(name):
            return plistlib.loads(archive.read(name))

        names = [name for name in archive.namelist() if name.startswith('Payload/') and name.endswith('.app/Info.plist') and name.count('/') == 2]
        if len(names) != 1:
            raise ValueError('Expected one main app Info.plist')
        info = plist(names[0])
        if 'iPhoneOS' not in info['CFBundleSupportedPlatforms']:
            raise ValueError('Expected a physical-device IPA')
        version = bundle_version(info)
        if verify_share_package:
            app = names[0].removesuffix('/Info.plist')
            extension = app + '/PlugIns/ShareExtension.appex'
            share_info = plist(extension + '/Info.plist')
            if 'iPhoneOS' not in share_info.get('CFBundleSupportedPlatforms', []):
                raise ValueError('Share extension must target physical devices')
            if bundle_version(share_info) != version:
                raise ValueError('Share extension version does not match the main app')
            if not {1, 2}.issubset(info.get('UIDeviceFamily', [])):
                raise ValueError('Main app must support both iPhone and iPad')
            group = info.get('GLOBALSEND_APP_GROUP_ID')
            if not group or share_info.get('GLOBALSEND_APP_GROUP_ID') != group:
                raise ValueError('App Group differs between the app and share extension')
            for bundle in (app, extension):
                groups = plist(bundle + '/GlobalSend.entitlements').get('com.apple.security.application-groups', [])
                if group not in groups:
                    raise ValueError('Manual signing template does not include the shared App Group')
        return version


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa')
    parser.add_argument('--verify-share-package', action='store_true')
    args = parser.parse_args()
    print(json.dumps(inspect(args.ipa, args.verify_share_package)))
