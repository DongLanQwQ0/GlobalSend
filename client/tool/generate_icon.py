"""Generate the GlobalSend mark and native icons; no external artwork or fonts."""
from pathlib import Path
import argparse
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--android-only', action='store_true', help='Regenerate Android launcher resources only')
args = parser.parse_args()
SVG = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
<circle cx="128" cy="128" r="84" fill="none" stroke="#176b58" stroke-width="10" opacity=".35"/>
<path d="M57 101h119l-24-24m24 24-24 24M199 155H80l24-24m-24 24 24 24" fill="none" stroke="#176b58" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
</svg>'''
assets = ROOT / 'assets'
assets.mkdir(exist_ok=True)
if not args.android_only:
    (assets / 'globalsend.svg').write_text(SVG, encoding='utf-8')

im = Image.new('RGBA', (1024, 1024))
d = ImageDraw.Draw(im)
d.ellipse((176, 176, 848, 848), outline=(23,107,88,89), width=40)
for points in [[(228,404),(704,404),(608,308)],[(704,404),(608,500)],[(796,620),(320,620),(416,524)],[(320,620),(416,716)]]:
    d.line(points, fill='#176b58', width=64, joint='curve')
    for x,y in points: d.ellipse((x-32,y-32,x+32,y+32), fill='#176b58')
if not args.android_only:
    im.resize((256,256), Image.Resampling.LANCZOS).save(assets / 'globalsend.png')
    im.save(ROOT / 'windows/runner/resources/app_icon.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
for bucket, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    path = ROOT / f'android/app/src/main/res/mipmap-{bucket}/ic_launcher.png'
    path.parent.mkdir(parents=True,exist_ok=True)
    im.resize((size,size),Image.Resampling.LANCZOS).save(path)

# Android package installers can display icons far above launcher size. Keep
# the mark as vector paths rather than enlarging a density-selected PNG.
paths = '''    <path android:pathData="M44,128a84,84 0,1 0,168 0a84,84 0,1 0,-168 0"
        android:fillColor="@android:color/transparent" android:strokeColor="#176b58"
        android:strokeWidth="10" android:strokeAlpha="0.35" />
    <path android:pathData="M57,101h119l-24,-24m24,24l-24,24M199,155H80l24,-24m-24,24l24,24"
        android:fillColor="@android:color/transparent" android:strokeColor="#176b58"
        android:strokeWidth="16" android:strokeLineCap="round" android:strokeLineJoin="round" />'''
def vector(size):
    return (f'<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="{size}dp" android:height="{size}dp"\n'
            '    android:viewportWidth="256" android:viewportHeight="256">\n' + paths + '\n</vector>\n')
resources = ROOT / 'android/app/src/main/res'
generated = {
    'mipmap-anydpi/ic_launcher.xml': vector(48),
}
for name, content in generated.items():
    target = resources / name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding='utf-8')
iconset = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
if iconset.exists() and not args.android_only:
    # Apple launcher catalogs require opaque artwork. Keep a neutral backing,
    # never reintroduce the removed green tile; other platforms retain alpha.
    opaque = Image.new('RGB', im.size, '#f5f5f6')
    opaque.paste(im, mask=im.getchannel('A'))
    for entry in json.loads((iconset / 'Contents.json').read_text())['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        opaque.resize((size, size), Image.Resampling.LANCZOS).save(iconset / entry['filename'])
print('Generated transparent Android vector launcher assets.' if args.android_only else 'Generated GlobalSend SVG, PNG, ICO, Android and iOS launcher assets.')
