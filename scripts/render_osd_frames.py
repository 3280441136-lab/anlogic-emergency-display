"""OSD frame review helper for tb_osd_frame.

  python render_osd_frames.py prepare <assets_dir> <run_dir>
      writes pic1..6.hex (640x480, 24-bit RGB per line, fitted exactly like the FPGA
      loader) for the testbench to $readmemh.
  python render_osd_frames.py render <run_dir>
      converts every frame_*.hex written by the testbench into frame_*.png.
"""
from pathlib import Path
import sys
from PIL import Image

def prepare(assets, run):
    # The FPGA's own fit (scaler_model is bit-exact with image_fit_scaler), any card size.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from scaler_model import fit_frame, read_bmp_rows
    run.mkdir(parents=True, exist_ok=True)
    for i in range(1, 7):
        rows, w, h, td = read_bmp_rows(str(assets / 'sdcard' / f'PIC{i}.BMP'))
        frame = fit_frame(rows, w, h, td)
        (run / f'pic{i}.hex').write_text('\n'.join(f'{r:02x}{g:02x}{b:02x}' for row in frame for r, g, b in row) + '\n')
def render(run):
    for f in sorted(run.glob('frame_*.hex')):
        values = [int(v, 16) for v in f.read_text().split()]
        im = Image.new('RGB', (640, 480))
        im.putdata([((v >> 16) & 255, (v >> 8) & 255, v & 255) for v in values[:640 * 480]])
        im.save(f.with_suffix('.png'))
        print(f.with_suffix('.png'))

if __name__ == '__main__':
    if sys.argv[1] == 'prepare': prepare(Path(sys.argv[2]), Path(sys.argv[3]))
    else: render(Path(sys.argv[2]))
