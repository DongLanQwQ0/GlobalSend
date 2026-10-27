"""Build the bundled UI font from the official, publicly cached OFL source."""
from pathlib import Path
import json
import shutil
from fontTools.ttLib import TTFont
from fontTools import subset
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[1]
CACHE = Path(r"F:\Caches\Fonts\NotoSansSC")
OUT = ROOT / "assets" / "fonts"
OUT.mkdir(parents=True, exist_ok=True)
characters = set(range(0x20, 0x100)) | set(range(0x2000, 0x2070)) | set(range(0x3000, 0x3040)) | set(range(0xFF00, 0xFFF0))
for first in range(0xA1, 0xF8):
    for second in range(0xA1, 0xFF):
        try:
            characters.update(map(ord, bytes([first, second]).decode("gb2312")))
        except UnicodeDecodeError:
            pass
ui_characters = set()
for source in (ROOT / "lib").glob("*.dart"):
    ui_characters.update(map(ord, source.read_text(encoding="utf-8")))
characters |= ui_characters
outputs = []
for style, weight in [("Regular", 400), ("Semibold", 600)]:
    font = instantiateVariableFont(TTFont(CACHE / "NotoSansSC-Variable.ttf"), {"wght": weight}, inplace=True)
    cmap = font.getBestCmap()
    missing_ui_han = [cp for cp in ui_characters if 0x3400 <= cp <= 0x9FFF and cp not in cmap]
    if missing_ui_han:
        raise ValueError(f"UI Han glyphs missing from upstream font: {missing_ui_han}")
    options = subset.Options()
    options.name_IDs = [0, 1, 2, 3, 4, 5, 6, 13, 14, 16, 17]
    options.name_languages = ["*"]
    builder = subset.Subsetter(options=options)
    builder.populate(unicodes=characters.intersection(cmap))
    builder.subset(font)
    names = {1: "GlobalSend Sans", 2: style, 3: f"GlobalSendSans-{style}", 4: f"GlobalSend Sans {style}", 6: f"GlobalSendSans-{style}", 16: "GlobalSend Sans", 17: style}
    for record in font["name"].names:
        if record.nameID in names:
            record.string = names[record.nameID].encode(record.getEncoding())
    target = OUT / f"GlobalSendSans-{style}.ttf"
    font.save(target)
    outputs.append({"file": target.name, "weight": weight, "bytes": target.stat().st_size, "characters": len(font.getBestCmap())})
shutil.copyfile(CACHE / "OFL.txt", OUT / "OFL.txt")
(OUT / "SOURCE.json").write_text(json.dumps({
    "upstream": "https://github.com/google/fonts/tree/main/ofl/notosanssc",
    "license": "SIL Open Font License 1.1; reserved name Source is not used by this derivative",
    "subset": "GB2312, Latin, numbers, Chinese/fullwidth/general punctuation, and every supported UI source character; missing content glyphs use platform fallback",
    "generator": "client/tool/build_ui_fonts.py", "outputs": outputs,
}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(json.dumps(outputs, ensure_ascii=False))
