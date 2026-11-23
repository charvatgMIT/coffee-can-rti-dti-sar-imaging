#!/usr/bin/env python3
"""Bundles the web app into one self-contained HTML file (dist/coffee-can-radar.html) that can be
opened from disk or put on any web server: styles, scripts, the icon and the two workers' code are
all inlined (the workers are started from blobs)."""
import base64, datetime, json, pathlib, re

root = pathlib.Path(__file__).resolve().parent.parent
src = root / 'src'
read = lambda p: (src / p).read_text(encoding='utf-8')
dsp = '\n'.join(read(f) for f in ['dsp-core.js', 'pencil.js', 'rangedoppler.js', 'processor.js', 'doppler.js', 'sar.js'])
bundle = {'dsp': dsp, 'worker': read('worker.js'), 'rdworker': read('rdworker.js'), 'sarworker': read('sarworker.js'),
          'date': datetime.date.today().isoformat()}
html = (root / 'index.html').read_text(encoding='utf-8')
icon = 'data:image/png;base64,' + base64.b64encode((root / 'icon.png').read_bytes()).decode()
html = html.replace('href="icon.png"', f'href="{icon}"').replace('src="icon.png"', f'src="{icon}"')
html = html.replace('<link rel="stylesheet" href="src/style.css">', '<style>\n' + read('style.css') + '</style>')
safe = lambda s: s.replace('</', '<\\/')
scripts = ''.join(f'<script>\n{safe(read(f))}\n</script>\n' for f in ['dsp-core.js', 'pencil.js', 'rangedoppler.js', 'processor.js', 'doppler.js', 'sar.js', 'plots.js'])
scripts = f'<script>window.CCR_BUNDLE = {safe(json.dumps(bundle))};</script>\n' + scripts + f'<script>\n{safe(read("app.js"))}\n</script>\n'
html = re.sub(r'(<script src="src/[^"]+"></script>\s*)+', lambda m: scripts, html, count=1)
assert 'src="src/' not in html
out = root / 'dist' / 'coffee-can-radar.html'
out.parent.mkdir(exist_ok=True)
out.write_text(html, encoding='utf-8')
print(f'{out} ({out.stat().st_size // 1024} KB)')
