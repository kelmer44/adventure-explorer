#!/usr/bin/env python3
"""Decode Igor screens through engine.lua and build a local, searchable gallery.

python3 scripts/igor-gallery.py --floppy /path/to/IGOR --cd /path/to/IGOR-CD
Requires Lua and Pillow. Output is build/igor-gallery/index.html by default.
"""
import argparse
import html
from pathlib import Path
import subprocess
from PIL import Image, ImageDraw


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--floppy', type=Path)
    parser.add_argument('--cd', type=Path)
    parser.add_argument('--output', type=Path, default=Path('build/igor-gallery'))
    args = parser.parse_args()
    if not (args.floppy or args.cd):
        parser.error('Provide --floppy and/or --cd')
    repo = Path(__file__).resolve().parents[1]
    output = args.output.resolve()
    sections = []
    for version, game in [('floppy', args.floppy), ('cd', args.cd)]:
        if game is None:
            continue
        folder = output / version
        folder.mkdir(parents=True, exist_ok=True)
        subprocess.run(['lua', 'scripts/tests/igor.lua', str(game.resolve()), str(folder)], cwd=repo, check=True)
        rows = [row.split('\t') for row in (folder / 'manifest.tsv').read_text().splitlines()]
        cards = []
        contact = Image.new('RGB', (1650, ((len(rows) + 4) // 5) * 225), '#1d242e')
        draw = ImageDraw.Draw(contact)
        for i, (key, name, description) in enumerate(rows):
            ppm = folder / (key + '.ppm')
            with Image.open(ppm) as image:
                image.save(folder / (key + '.png'))
                x, y = (i % 5) * 330, (i // 5) * 225
                contact.paste(image, (x, y))
                draw.text((x + 3, y + 202), name, fill='white')
            ppm.unlink()
            source = f'{version}/{key}.png'
            group = 'Intertitles' if key.startswith('ui_') and int(key[3:]) >= 5 else ('Interface' if key.startswith('ui_') else 'Screens')
            cards.append(f'<figure data-version="{version}" data-name="{html.escape(name.lower(), quote=True)}">'
                         f'<a href="{source}" target="_blank"><img loading="lazy" src="{source}" alt="{html.escape(name, quote=True)}"></a>'
                         f'<figcaption>{html.escape(name)}<small>{version.upper()} · {group}</small></figcaption>'
                         f'<details><summary>Details</summary>{html.escape(description)}</details></figure>')
        contact.save(output / (version + '-contact.png'))
        sections.extend(cards)
    (output / 'index.html').write_text('''<!doctype html><html lang="en"><meta charset="utf-8">
<title>Igor — All Screens</title><meta name="viewport" content="width=device-width, initial-scale=1">
<style>
:root{color-scheme:dark;font:16px system-ui;background:#101720;color:#edf2f7}body{margin:24px auto;max-width:1600px;padding:0 20px}
h1{margin-bottom:8px}p{color:#adbccd;max-width:850px;line-height:1.6}nav{position:sticky;top:0;background:#101720ef;padding:16px 0;display:flex;gap:12px;z-index:1;flex-wrap:wrap}
input,select{font:inherit;padding:10px;background:#1d2a39;color:white;border:1px solid #53677f;border-radius:6px}input{min-width:250px}#count{align-self:center}
main{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:18px}figure{margin:0;background:#1d2a39;border-radius:8px;overflow:hidden;align-self:start}figure[hidden]{display:none}
a{display:flex;align-items:center;justify-content:center;height:210px;background:#05090d}img{width:100%;max-height:210px;object-fit:contain;image-rendering:pixelated}
figcaption{padding:14px;font-weight:600}small{display:block;font-weight:400;color:#9fb3ca;margin-top:5px}details{padding:0 14px 14px;font-size:12px;color:#aabbcf;overflow-wrap:anywhere}
</style><h1>Igor: Objective Uikokahonia</h1>
<p>Spanish floppy and CD editions: room backgrounds, close-ups, beach ending, telescope views, startup art, credits and intertitles. Interface panels are also included. These are decoded artwork previews; characters, menu labels and other content drawn by game scripts are not added. Click any image for its original pixels.</p>
<nav><select id="version" aria-label="Version"><option value="">Both versions</option><option value="floppy">Floppy</option><option value="cd">CD</option></select>
<input id="search" type="search" placeholder="Find a room or screen…" aria-label="Find a screen"><span id="count"></span></nav><main>
''' + '\n'.join(sections) + '''</main><script>
const cards=[...document.querySelectorAll('figure')], search=document.querySelector('#search'), version=document.querySelector('#version');
function filter(){let n=0;for(const c of cards){c.hidden=!!((version.value&&c.dataset.version!==version.value)||!c.dataset.name.includes(search.value.toLowerCase()));if(!c.hidden)n++}document.querySelector('#count').textContent=n+' images'}
search.addEventListener('input',filter);version.addEventListener('change',filter);filter();</script></html>''')
    print(output / 'index.html')


if __name__ == '__main__':
    main()
