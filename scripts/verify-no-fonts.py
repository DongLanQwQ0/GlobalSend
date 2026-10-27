"""Inspect a built Windows bundle or APK/IPA/ZIP and reject bundled fonts."""
import argparse
import json
import pathlib
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('artifacts', nargs='+')
args = parser.parse_args()
extensions = {'.ttf', '.otf', '.ttc', '.woff', '.woff2'}
results = []
for argument in args.artifacts:
    target = pathlib.Path(argument)
    if target.is_dir():
        entries = [(str(path.relative_to(target)), path.read_bytes)
                   for path in target.rglob('*') if path.is_file()]
        archive = None
    else:
        archive = zipfile.ZipFile(target)
        entries = [(entry.filename, lambda entry=entry: archive.read(entry))
                   for entry in archive.infolist() if not entry.is_dir()]
    try:
        fonts = [name for name, _ in entries if pathlib.PurePosixPath(name.replace('\\', '/')).suffix.lower() in extensions]
        manifests = [json.loads(read()) for name, read in entries if name.endswith('FontManifest.json')]
        if fonts or any(manifests):
            raise SystemExit(json.dumps({'artifact': str(target), 'fontFiles': fonts, 'fontManifests': manifests}, ensure_ascii=False))
        results.append({'artifact': str(target.resolve()), 'fontFiles': 0, 'fontManifests': len(manifests)})
    finally:
        if archive:
            archive.close()
print(json.dumps(results, ensure_ascii=False, indent=2))
