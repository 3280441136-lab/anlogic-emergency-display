"""Copy the files that belong in the public source repository into a separate folder.

Usage:  python export_repo.py <repo_dir>
Only the whitelisted sources below are copied; build outputs, logs, simulation work
libraries, the official Anlogic example sources (user_source/, td_project/al_ip/) and the
competition report are never exported. README.md and .gitignore in <repo_dir> are kept as
they are (edit them there). Files that disappear from the project are removed from the
managed folders, so re-running the script keeps the repository in step.
"""
from pathlib import Path
import re, shutil, sys

P = Path(__file__).resolve().parents[1]
DST = Path(sys.argv[1]).resolve()
MANAGED = ['rtl', 'constraints', 'scripts', 'sim', 'assets', 'td_project', 'docs']

files = []
files += sorted((P / 'rtl').rglob('*.v')) + [P / 'rtl/storage/reference_manifest.json']
files += [P / 'constraints/pin.adc', P / 'constraints/timing.sdc']
files += [P / 'scripts' / n for n in ('build.tcl', 'check_al.py', 'run_sim.py', 'make_test_fixtures.py',
                                      'scaler_model.py', 'render_osd_frames.py', 'prepare_assets.py', 'export_repo.py')]
files += sorted((P / 'sim').glob('*.sv'))
files += sorted((P / 'assets').glob('*.hex')) + [P / 'assets/manifest.json', P / 'assets/theme_preview.png']
files += sorted((P / 'assets/sdcard').glob('PIC*.BMP'))
files += [P / 'docs/设计与优化.md', P / 'docs/上板与素材验收.md', P / 'docs/2026-11-02-最终版实板验证.md']
# README pictures: rendered by the RTL in ModelSim (tb_osd_frame) and the report block diagram
images = {P / 'sim/osd/frame_menu.png': 'menu.png', P / 'sim/osd/frame_debug.png': 'debug.png',
          P / 'sim/osd/frame_notice.png': 'notice.png', P / 'sim/osd/frame_alarm.png': 'alarm.png',
          P / 'docs/report/fig/f2_1_system.png': 'system.png', P / 'docs/report/fig/f2_1_system.svg': 'system.svg'}

for d in MANAGED:
    if (DST / d).exists():
        shutil.rmtree(DST / d)
for f in files:
    out = DST / f.relative_to(P)
    out.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(f, out)
(DST / 'docs/images').mkdir(parents=True, exist_ok=True)
for src, name in images.items():
    shutil.copy2(src, DST / 'docs/images' / name)
# TD project file: drop the absolute project path (TD derives it from the file location)
al = (P / 'td_project/Emergency_Display_Baseline.al').read_text(encoding='utf-8')
al = re.sub(r'(<Project [^>]*?)\s+Path="[^"]*"', r'\1', al, count=1)
(DST / 'td_project').mkdir(exist_ok=True)
(DST / 'td_project/Emergency_Display_Baseline.al').write_text(al, encoding='utf-8', newline='')
print(f'exported {len(files) + len(images) + 1} files to {DST}')
