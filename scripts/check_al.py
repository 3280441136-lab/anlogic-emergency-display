"""Check that every project RTL file (rtl/**/*.v) is listed in the TD project file.

The TD GUI rewrites td_project/Emergency_Display_Baseline.al when it saves the project
and has dropped entries added from the command line before (2026-11-01). Run before
every command-line build:  python check_al.py [--fix]
--fix appends missing files (synthesis + P&R) and keeps a .al.bak copy.
Exit code 1 if files are missing and --fix was not given.
"""
from pathlib import Path
import re, shutil, sys

P = Path(__file__).resolve().parents[1]
AL = P / 'td_project' / 'Emergency_Display_Baseline.al'
text = AL.read_text(encoding='utf-8')
listed = set(re.findall(r'<File Path="([^"]+)">', text))
wanted = sorted('../' + f.relative_to(P).as_posix() for f in (P / 'rtl').rglob('*.v'))
missing = [f for f in wanted if f not in listed]
if not missing:
    print(f'check_al: all {len(wanted)} rtl files listed'); sys.exit(0)
print('check_al: missing from .al: ' + ', '.join(missing))
if '--fix' not in sys.argv: sys.exit(1)
shutil.copy(AL, AL.with_suffix('.al.bak'))
nl = '\r\n' if '\r\n' in text else '\n'
order = max([int(x) for x in re.findall(r'CompileOrder" Val="(\d+)"', text)] or [0])
entries = ''
for f in missing:
    order += 1
    entries += (f'            <File Path="{f}">{nl}                <FileInfo>{nl}'
                f'                    <Attr Name="UsedInSyn" Val="true"/>{nl}'
                f'                    <Attr Name="UsedInP&R" Val="true"/>{nl}'
                f'                    <Attr Name="BelongTo" Val="design_1"/>{nl}'
                f'                    <Attr Name="CompileOrder" Val="{order}"/>{nl}'
                f'                </FileInfo>{nl}            </File>{nl}')
anchor = '            <File Path="../rtl/ed_framebuffer.v">'
if anchor not in text: sys.exit('check_al: anchor entry not found, fix .al by hand')
AL.write_text(text.replace(anchor, entries + anchor, 1), encoding='utf-8', newline='')
print(f'check_al: added {len(missing)} entries')
