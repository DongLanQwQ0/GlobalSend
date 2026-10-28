"""Generate the GlobalSend mark and native icons; no external artwork or fonts."""
from pathlib import Path
import json
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
SVG = '''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
<circle cx="128" cy="128" r="84" fill="none" stroke="#176b58" stroke-width="10" opacity=".35"/>
<path d="M57 101h119l-24-24m24 24-24 24M199 155H80l24-24m-24 24 24 24" fill="none" stroke="#176b58" stroke-width="16" stroke-linecap="round" stroke-linejoin="round"/>
</svg>'''
assets = ROOT / 'assets'
assets.mkdir(exist_ok=True)
(assets / 'globalsend.svg').write_text(SVG, encoding='utf-8')

im = Image.new('RGBA', (1024, 1024))
d = ImageDraw.Draw(im)
d.ellipse((176, 176, 848, 848), outline=(23,107,88,89), width=40)
for points in [[(228,404),(704,404),(608,308)],[(704,404),(608,500)],[(796,620),(320,620),(416,524)],[(320,620),(416,716)]]:
    d.line(points, fill='#176b58', width=64, joint='curve')
    for x,y in points: d.ellipse((x-32,y-32,x+32,y+32), fill='#176b58')
im.resize((256,256), Image.Resampling.LANCZOS).save(assets / 'globalsend.png')
im.save(ROOT / 'windows/runner/resources/app_icon.ico', sizes=[(16,16),(24,24),(32,32),(48,48),(64,64),(128,128),(256,256)])
for bucket, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    path = ROOT / f'android/app/src/main/res/mipmap-{bucket}/ic_launcher.png'
    path.parent.mkdir(parents=True,exist_ok=True)
    im.resize((size,size),Image.Resampling.LANCZOS).save(path)
iconset = ROOT / 'ios/Runner/Assets.xcassets/AppIcon.appiconset'
if iconset.exists():
    # Apple launcher catalogs require opaque artwork. Keep a neutral backing,
    # never reintroduce the removed green tile; other platforms retain alpha.
    opaque = Image.new('RGB', im.size, '#f5f5f6')
    opaque.paste(im, mask=im.getchannel('A'))
    for entry in json.loads((iconset / 'Contents.json').read_text())['images']:
        if 'filename' not in entry:
            continue
        size = round(float(entry['size'].split('x')[0]) * float(entry['scale'].rstrip('x')))
        opaque.resize((size, size), Image.Resampling.LANCZOS).save(iconset / entry['filename'])
print('Generated GlobalSend SVG, PNG, ICO, Android and iOS launcher assets.')
