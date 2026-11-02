"""Generate TF-card BMPs, OSD ROMs and a preview for the XiaoLong Plaza (小龙广场) scene.

The plaza, its shops, mascot (an original round little dragon) and floor plan are our own
artwork, drawn here with Pillow; routes and offers are illustrative content for the demo.
Usage:  python prepare_assets.py [output_dir]   (default: ../assets)
Six images, each drawn on a 1280x960 canvas and LANCZOS-resized to its card size; the
FPGA fits every one to 640x480 at boot (sizes chosen to show both scaling directions).
  PIC1 640x480  winter promotion poster       carousel
  PIC2 800x600  1F floor guide                carousel (FPGA area-average downscale)
  PIC3 640x480  fire-safety slogans           carousel
  PIC4 480x360  bookshop cafe advert          carousel (FPGA bilinear upscale)
  PIC5 640x480  crowd notice                  notice mode
  PIC6 640x480  evacuation to both exits      emergency mode
Fonts are only needed on the PC; the FPGA reads ROM hex.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import json, math, os, struct, sys, wave

P = Path(__file__).resolve().parents[1]
A = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else P / 'assets'
(A / 'sdcard').mkdir(parents=True, exist_ok=True)
# Microsoft YaHei / SimSun / Consolas are used to draw the images and font ROMs; override the
# directory with the FONT_DIR environment variable. Only needed to regenerate assets.
FONTS = Path(os.environ.get('FONT_DIR', 'C:/Windows/Fonts'))
def font(n, bold=False): return ImageFont.truetype(str(FONTS / ('msyhbd.ttc' if bold else 'msyh.ttc')), n)

W, H = 1280, 960
CREAM, YELLOW, ORANGE, NAVY, INK = '#fff6dc', '#ffc93c', '#ff8a3d', '#16233a', '#2b2b2b'
GREEN, RED, WHITE, GREY = '#18a058', '#e03a3a', '#ffffff', '#8a94a6'
BRAND = '小龙广场 · XIAOLONG PLAZA'

def text_center(d, xy, s, f, fill):
    x, y = xy; b = d.textbbox((0, 0), s, font=f)
    d.text((x - (b[2] - b[0]) / 2 - b[0], y - (b[3] - b[1]) / 2 - b[1]), s, font=f, fill=fill)

def text_width(d, s, f):
    b = d.textbbox((0, 0), s, font=f); return b[2] - b[0]

def pill(d, x, y, s, f, fill, color, h=70, pad=34):
    """Rounded label whose width follows the text; (x, y) is the top-left corner."""
    w = text_width(d, s, f) + 2 * pad
    d.rounded_rectangle((x, y, x + w, y + h), radius=h // 2, fill=fill)
    text_center(d, (x + w / 2, y + h / 2), s, f, color)
    return w

def gradient(im, top, bottom):
    d = ImageDraw.Draw(im)
    for i in range(H):
        t = i / (H - 1)
        d.line((0, i, W, i), fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)))

def mascot(d, cx, cy, r):
    """XiaoLong, the plaza's own round little-dragon mascot (original drawing)."""
    d.ellipse((cx - r * 0.45, cy - r * 1.25, cx - r * 0.15, cy - r * 0.8), fill=ORANGE)   # horns
    d.ellipse((cx + r * 0.15, cy - r * 1.25, cx + r * 0.45, cy - r * 0.8), fill=ORANGE)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=YELLOW, outline='#e0a800', width=int(r * 0.06))
    d.ellipse((cx - r * 0.62, cy - r * 0.15, cx + r * 0.62, cy + r * 0.85), fill='#fff1b8')  # belly
    for sx in (-1, 1):
        ex = cx + sx * r * 0.36
        d.ellipse((ex - r * 0.13, cy - r * 0.38, ex + r * 0.13, cy - r * 0.08), fill=INK)
        d.ellipse((ex - r * 0.05, cy - r * 0.33, ex + r * 0.03, cy - r * 0.25), fill=WHITE)
        d.ellipse((ex - r * 0.2 + sx * r * 0.12, cy + r * 0.0, ex + r * 0.08 + sx * r * 0.12, cy + r * 0.14), fill='#ffb3a7')
    d.arc((cx - r * 0.18, cy - r * 0.12, cx + r * 0.18, cy + r * 0.16), 20, 160, fill=INK, width=int(r * 0.05))
    d.ellipse((cx - r * 1.12, cy + r * 0.05, cx - r * 0.78, cy + r * 0.45), fill=YELLOW, outline='#e0a800', width=int(r * 0.04))
    d.ellipse((cx + r * 0.78, cy - r * 0.35, cx + r * 1.12, cy + r * 0.05), fill=YELLOW, outline='#e0a800', width=int(r * 0.04))

def exit_sign(d, x, y, w, h, arrow):
    """Green emergency-exit pictogram with a running figure and an arrow (+1 right, -1 left)."""
    d.rounded_rectangle((x, y, x + w, y + h), radius=h * 0.12, fill=GREEN)
    s = h / 100; fx = x + (w * 0.62 if arrow < 0 else w * 0.18)
    sw = max(2, int(9 * s))
    hx = 30 if arrow > 0 else 20
    d.ellipse((fx + (hx - 8) * s, y + 12 * s, fx + (hx + 8) * s, y + 28 * s), fill=WHITE)
    pts = lambda *p: [(fx + (a if arrow > 0 else 50 - a) * s, y + b * s) for a, b in p]
    d.line(pts((30, 32), (24, 58)), fill=WHITE, width=sw)
    d.line(pts((24, 58), (36, 72), (32, 90)), fill=WHITE, width=sw, joint='curve')
    d.line(pts((24, 58), (12, 72), (2, 74)), fill=WHITE, width=sw, joint='curve')
    d.line(pts((29, 38), (42, 48), (50, 44)), fill=WHITE, width=sw, joint='curve')
    d.line(pts((29, 38), (16, 44), (10, 54)), fill=WHITE, width=sw, joint='curve')
    ax0, ax1 = (x + w * 0.5, x + w * 0.9) if arrow > 0 else (x + w * 0.5, x + w * 0.1)
    ay = y + h * 0.5
    d.line((ax0, ay, ax1 - arrow * h * 0.18, ay), fill=WHITE, width=int(12 * s))
    d.polygon([(ax1, ay), (ax1 - arrow * h * 0.24, ay - h * 0.2), (ax1 - arrow * h * 0.24, ay + h * 0.2)], fill=WHITE)

def flame(d, cx, cy, r):
    d.ellipse((cx - r * 0.75, cy - r * 0.2, cx + r * 0.75, cy + r * 1.0), fill='#ff6a2a')
    d.polygon([(cx, cy - r * 1.2), (cx - r * 0.75, cy + r * 0.4), (cx + r * 0.75, cy + r * 0.4)], fill='#ff6a2a')
    d.ellipse((cx - r * 0.38, cy + r * 0.25, cx + r * 0.38, cy + r * 0.95), fill='#ffd23c')
    d.polygon([(cx, cy - r * 0.3), (cx - r * 0.38, cy + r * 0.6), (cx + r * 0.38, cy + r * 0.6)], fill='#ffd23c')

def no_entry(d, cx, cy, r):
    """Red prohibition ring over a parked-car block (fire lane must stay clear)."""
    d.rounded_rectangle((cx - r * 0.55, cy - r * 0.2, cx + r * 0.55, cy + r * 0.3), radius=r * 0.12, fill='#4a5568')
    d.rounded_rectangle((cx - r * 0.35, cy - r * 0.45, cx + r * 0.3, cy - r * 0.15), radius=r * 0.1, fill='#4a5568')
    for sx in (-0.32, 0.32): d.ellipse((cx + sx * r - r * 0.14, cy + r * 0.18, cx + sx * r + r * 0.14, cy + r * 0.46), fill=INK)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=RED, width=int(r * 0.16))
    d.line((cx - r * 0.7, cy - r * 0.7, cx + r * 0.7, cy + r * 0.7), fill=RED, width=int(r * 0.16))

# The FPGA caption band covers the bottom 32 output lines (64 px here): keep it decorative.
CAPTION_TOP = 896

# ------------------------------------------------------------------ floor plan
SHOPS = [  # (x0, y0, x1, y1, name, colour), y relative to a plan top of 200
    (150, 250, 380, 420, '潮流服饰', '#ffd8a8'), (400, 250, 600, 420, '奶茶小站', '#ffe9a8'),
    (680, 250, 880, 420, '数码体验', '#cfe3ff'), (900, 250, 1130, 420, '运动户外', '#d3f0d0'),
    (150, 560, 380, 730, '儿童乐园', '#ffd3e0'), (400, 560, 600, 730, '书店咖啡', '#e8dcff'),
    (680, 560, 880, 730, '美妆护肤', '#ffd8d8'), (900, 560, 1130, 730, '服务台', '#fff1b8'),
]

def floor_plan(d, oy, emergency=False):
    dim = emergency
    d.rounded_rectangle((100, 200 + oy, 1180, 780 + oy), radius=28, fill='#fbfbf7', outline='#c9c2ad', width=6)
    d.rectangle((100, 440 + oy, 1180, 540 + oy), fill='#efe9d8')
    d.rectangle((610, 200 + oy, 670, 780 + oy), fill='#efe9d8')
    for x0, y0, x1, y1, name, col in SHOPS:
        d.rounded_rectangle((x0, y0 + oy, x1, y1 + oy), radius=14, fill='#e6e6e6' if dim else col, outline='#b5ad98', width=3)
        text_center(d, ((x0 + x1) / 2, (y0 + y1) / 2 + oy), name, font(34, True), '#9a9a9a' if dim else INK)
    for y in (236, 690):
        d.rounded_rectangle((616, y + oy, 664, y + 64 + oy), radius=8, fill='#9fb4c8')
        text_center(d, (640, y + 32 + oy), '梯', font(26, True), WHITE)
    for x, label in ((100, '西门'), (1180, '东门')):
        d.rectangle((x - 14, 455 + oy, x + 14, 525 + oy), fill=GREEN if dim else '#7aa58a')
        text_center(d, (x + (-55 if x < 640 else 55), 490 + oy), label, font(30, True), GREEN if dim else '#4f7a60')

def you_are_here(d, oy):
    x, y = 640, 490 + oy
    d.ellipse((x - 26, y - 26, x + 26, y + 26), fill=RED, outline=WHITE, width=6)
    d.rounded_rectangle((x - 92, y - 92, x + 92, y - 40), radius=14, fill=RED)
    text_center(d, (x, y - 66), '您在这里', font(28, True), WHITE)

def route(d, oy, direction):
    x, y = 640, 490 + oy; end = 1150 if direction > 0 else 130
    d.line((x, y, end, y), fill='#bfe8cf', width=30)
    for ax in range(x + direction * 50, end, direction * 90):
        d.polygon([(ax + direction * 34, y), (ax - direction * 6, y - 26), (ax - direction * 6, y + 26)], fill=GREEN)

# ------------------------------------------------------------------ scenes
def poster():
    im = Image.new('RGB', (W, H)); gradient(im, (255, 246, 220), (255, 206, 100)); d = ImageDraw.Draw(im)
    for cx, cy, r, c in ((1080, 140, 210, '#ffe08a'), (150, 760, 220, '#ffd166'), (1180, 720, 140, '#ffb347')):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=c)
    pill(d, 60, 50, BRAND, font(30, True), NAVY, YELLOW)
    d.text((70, 160), '冬季焕新季', font=font(120, True), fill=NAVY)
    d.text((76, 320), '全场满 200 减 50', font=font(64, True), fill=RED)
    d.rounded_rectangle((70, 420, 560, 490), radius=20, fill=WHITE); d.text((96, 432), '活动时间 12.01 — 12.31', font=font(36), fill=INK)
    d.text((76, 520), '会员积分双倍 · 新店开业 · 周末亲子市集', font=font(34), fill='#5b4a2a')
    art = A / 'art' / 'poster.png'   # optional externally drawn illustration (any size)
    if art.exists():
        pic = Image.open(art).convert('RGB'); pic.thumbnail((520, 560), Image.Resampling.LANCZOS)
        im.paste(pic, (960 - pic.width // 2, 420 - pic.height // 2))
    else:
        mascot(d, 960, 450, 210)
    text_center(d, (960, 730), '小龙陪你逛商场', font(40, True), NAVY)
    d.rectangle((0, 790, W, H), fill=NAVY)
    text_center(d, (W / 2, 840), 'B1 生鲜超市   1F 潮流服饰   2F 数码家电   3F 美食街   5F 影城', font(32), WHITE)
    return im

def guide():
    im = Image.new('RGB', (W, H), '#f4f1e8'); d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W, 140), fill=NAVY)
    d.text((60, 28), '1F 楼层导览', font=font(64, True), fill=YELLOW)
    d.text((470, 50), 'FLOOR GUIDE', font=font(34), fill=WHITE)
    mascot(d, 1215, 78, 42)
    oy = -40; floor_plan(d, oy); you_are_here(d, oy)
    d.line((640, 395 + oy, 640, 300 + oy), fill=ORANGE, width=10)
    d.polygon([(640, 288 + oy), (620, 318 + oy), (660, 318 + oy)], fill=ORANGE)
    d.rounded_rectangle((720, 42, 1090, 102), radius=30, fill=ORANGE)
    text_center(d, (905, 72), '乘扶梯到 3F 美食街', font(30, True), WHITE)
    d.rectangle((0, 770, W, H), fill='#e9e3d0')
    for i, (c, s) in enumerate(((RED, '当前位置'), ('#9fb4c8', '扶梯 / 电梯'), (GREEN, '出入口'), (ORANGE, '推荐路线'))):
        x = 80 + i * 300; d.rounded_rectangle((x, 800, x + 44, 844), radius=10, fill=c); d.text((x + 60, 800), s, font=font(32), fill=INK)
    return im

def safety():
    im = Image.new('RGB', (W, H)); gradient(im, (14, 110, 70), (24, 160, 88)); d = ImageDraw.Draw(im)
    pill(d, 60, 44, BRAND, font(30, True), WHITE, '#0e6e46')
    text_center(d, (W / 2, 210), '消防安全  人人有责', font(96, True), WHITE)
    text_center(d, (W / 2, 305), 'FIRE SAFETY', font(40, True), '#c8f0d8')
    cards = (('安全出口', '保持畅通'), ('消防通道', '严禁占用'), ('发现火情', '拨打 119'))
    for i, (a, b) in enumerate(cards):
        x0 = 70 + i * 390; d.rounded_rectangle((x0, 380, x0 + 360, 820), radius=30, fill=WHITE)
        cx, cy = x0 + 180, 520
        if i == 0: exit_sign(d, cx - 130, cy - 55, 260, 110, +1)
        elif i == 1: no_entry(d, cx, cy, 90)
        else: flame(d, cx, cy - 10, 80)
        text_center(d, (cx, 680), a, font(54, True), '#0e6e46')
        text_center(d, (cx, 760), b, font(54, True), RED if i == 2 else INK)
    mascot(d, 1190, 870, 60)
    return im

def cafe():
    """Bookshop-cafe advert; delivered at 480x360, so only large type and shapes."""
    im = Image.new('RGB', (W, H)); gradient(im, (74, 44, 29), (128, 76, 44)); d = ImageDraw.Draw(im)
    for cx, cy, r in ((1100, 160, 260), (180, 860, 220)):
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill='#8a5634')
    pill(d, 60, 50, '2F 书店咖啡', font(44, True), '#ffe2b8', '#4a2c1d', h=84)
    d.text((70, 190), '冬日暖饮', font=font(150, True), fill='#fff4e0')
    d.text((76, 390), '第二杯半价', font=font(110, True), fill=YELLOW)
    d.rounded_rectangle((76, 560, 640, 650), radius=24, fill='#fff4e0')
    text_center(d, (358, 605), '每日 10:00 — 22:00', font(50, True), '#4a2c1d')
    # cup with steam
    cx, cy = 960, 560
    for k in (-60, 0, 60):
        d.arc((cx + k - 40, cy - 330, cx + k + 40, cy - 230), 200, 340, fill='#f3dcc0', width=14)
        d.arc((cx + k - 40, cy - 250, cx + k + 40, cy - 150), 20, 160, fill='#f3dcc0', width=14)
    d.ellipse((cx + 120, cy - 70, cx + 260, cy + 90), outline='#fff4e0', width=30)
    d.rounded_rectangle((cx - 180, cy - 120, cx + 180, cy + 180), radius=60, fill='#fff4e0')
    d.rectangle((cx - 180, cy - 120, cx + 180, cy - 40), fill='#fff4e0')
    d.ellipse((cx - 180, cy - 160, cx + 180, cy - 80), fill='#6b3b20')
    d.ellipse((cx - 250, cy + 170, cx + 250, cy + 240), fill='#d9b48a')
    text_center(d, (cx, cy + 60), '小龙', font(60, True), '#8a5634')
    return im

def notice():
    im = Image.new('RGB', (W, H), '#fff8ee'); d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W, 150), fill='#f08a24')
    d.text((60, 26), '温馨提示', font=font(80, True), fill=WHITE)
    d.text((440, 50), 'NOTICE', font=font(44, True), fill='#ffe6c8')
    text_center(d, (W / 2, 260), '今日客流较大', font(100, True), '#c25b00')
    text_center(d, (W / 2, 380), '请有序乘梯 · 靠右站稳 · 握好扶手', font(52, True), INK)
    # escalator pictogram
    x0, y0 = 170, 720
    d.polygon([(x0, y0), (x0 + 120, y0), (x0 + 400, y0 - 220), (x0 + 520, y0 - 220), (x0 + 520, y0 - 170),
               (x0 + 420, y0 - 170), (x0 + 140, y0 + 50), (x0, y0 + 50)], fill='#9fb4c8')
    for k in range(5):
        sx = x0 + 150 + k * 52; sy = y0 - 25 - k * 41
        d.rectangle((sx, sy, sx + 40, sy + 12), fill=WHITE)
    d.ellipse((x0 + 255, y0 - 300, x0 + 305, y0 - 250), fill=NAVY)
    d.line((x0 + 280, y0 - 250, x0 + 270, y0 - 160), fill=NAVY, width=18)
    d.line((x0 + 275, y0 - 225, x0 + 330, y0 - 205), fill=NAVY, width=14)
    for i, s in enumerate(('照看好老人和儿童', '保管好随身物品', '如需帮助请联系服务台')):
        y = 520 + i * 100
        d.ellipse((760, y - 18, 796, y + 18), fill='#f08a24')
        d.text((816, y - 30), s, font=font(42, True), fill=INK)
    mascot(d, 1180, 830, 60)
    return im

def evacuation():
    im = Image.new('RGB', (W, H), '#fff7f5'); d = ImageDraw.Draw(im)
    d.rectangle((0, 0, W, 150), fill=RED)
    d.text((60, 22), '紧急疏散', font=font(80, True), fill=WHITE)
    d.text((470, 30), 'EMERGENCY EVACUATION', font=font(38, True), fill='#ffe0e0')
    d.text((472, 86), '请保持冷静 · 沿绿色箭头就近撤离', font=font(34), fill=WHITE)
    oy = -40; floor_plan(d, oy, emergency=True); route(d, oy, +1); route(d, oy, -1); you_are_here(d, oy)
    exit_sign(d, 50, 768, 280, 110, -1); exit_sign(d, 950, 768, 280, 110, +1)
    text_center(d, (640, 795), '东西两侧安全出口', font(50, True), GREEN)
    text_center(d, (640, 857), '请勿乘坐电梯 · 照顾老人儿童', font(32, True), '#a33')
    return im

SCENES = [(poster, (640, 480)), (guide, (800, 600)), (safety, (640, 480)),
          (cafe, (480, 360)), (notice, (640, 480)), (evacuation, (640, 480))]
images = [fn() for fn, _ in SCENES]
manifest = []
for old in (A / 'sdcard').glob('PIC*.BMP'): old.unlink()
for i, (im, (_, size)) in enumerate(zip(images, SCENES)):
    out = im.resize(size, Image.Resampling.LANCZOS)
    path = A / 'sdcard' / f'PIC{i + 1}.BMP'; out.save(path, format='BMP')
    manifest.append({'file': path.name, 'width': out.width, 'height': out.height,
                     'format': '24-bit uncompressed bottom-up BMP', 'bytes': path.stat().st_size})
preview = Image.new('RGB', (1920, 960))
for i, im in enumerate(images): preview.paste(im.resize((640, 480), Image.Resampling.LANCZOS), ((i % 3) * 640, (i // 3) * 480))
preview.save(A / 'theme_preview.png')
(A / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')

# ------------------------------------------------------------------ OSD ROMs
# Messages: 8 rows x 64 cells. Rows 0-4 scroll in the caption band; row 5 holds the
# caption tags; rows 6-7 are centred in a 20-cell window. Each cell is one 16x16 glyph.
MESSAGES = [
    '欢迎光临小龙广场  冬季焕新季全场满200减50  美食街位于三层  请照看好随行儿童',
    '温馨提示  今日客流较大  请有序乘梯靠右站稳  照看好老人儿童  保管好随身物品  如需帮助请联系服务台',
    '紧急疏散  请保持冷静  沿绿色箭头就近从东西两侧安全出口撤离  请勿乘坐电梯',
    '',                                       # spare (modes are normal / notice / emergency)
    '素材读取异常  请检查TF卡后按K1复位  当前为安全默认画面',
    '公告提示紧急故障',                       # tags, two cells each: normal/notice/alarm/fault
    '素材读取异常  请检查TF卡',             # centre text (20 cells), fault
    '系统启动中  正在读取TF卡内容',           # centre text (20 cells), loading
]
CENTRED = {6, 7}
# Menu: 11 rows x 32 cells (20 used) x 4 value variants. Row 0 title, 1-8 items, 9 key hint,
# 10 save note.
MENU_ROWS = ['画面与声音设置', '亮度', '对比度', '音量', '转场效果', '界面透明度', '自动轮播', '节能模式', '调试信息', 'K3 选择  K2 调整  K4 关闭', '关闭菜单即保存设置']
MENU_VALUES = {4: ['淡入淡出', '滑动揭示', '直接切换', '交叉混合'],
               5: ['不透明', '半透明', '高透明', '高透明'],
               6: ['关闭', '开启', '开启', '开启'], 7: ['关闭', '开启 屏幕调暗', '开启', '开启'], 8: ['关闭', '开启', '开启', '开启']}
VALUE_COL = 12

def tokens(s):
    """Split into 16x16 cells: one CJK character per cell; an ASCII run of n characters
    is drawn centred across ceil(n/2) cells and sliced, so digits stay contiguous."""
    out, i = [], 0
    while i < len(s):
        if ord(s[i]) < 128 and s[i] != ' ':
            j = i
            while j < len(s) and ord(s[j]) < 128 and s[j] != ' ': j += 1
            run = s[i:j]; cells_n = (len(run) + 1) // 2
            out += [f'{run}#{k}' for k in range(cells_n)]; i = j
        elif s[i] == ' ':
            out.append(' '); i += 1
        else:
            out.append(s[i]); i += 1
    return out

cells = [' ']
def cid(t):
    if t == ' ': return 0
    if t not in cells: cells.append(t)
    return cells.index(t)
msg_rom = []
for n, s in enumerate(MESSAGES):
    row = [cid(t) for t in tokens(s)]
    if n in CENTRED: row = [0] * ((20 - len(row)) // 2) + row
    if len(row) > 64: raise SystemExit(f'message too long: {s}')
    msg_rom += row + [0] * (64 - len(row))
menu_rom = [0] * 2048
for r, label in enumerate(MENU_ROWS):
    for v in range(4):
        row = [0] * 32
        for c, t in enumerate(tokens(label)): row[1 + c] = cid(t)
        if r in MENU_VALUES:
            for c, t in enumerate(tokens(MENU_VALUES[r][v])): row[VALUE_COL + c] = cid(t)
        for c in range(32): menu_rom[(r << 7) | (v << 5) | c] = row[c]
if len(cells) > 256: raise SystemExit(f'{len(cells)} glyph cells exceed 256')

cjk_font = ImageFont.truetype(str(FONTS / 'simsun.ttc'), 16)     # embedded 16px bitmap strike
ascii_font = ImageFont.truetype(str(FONTS / 'consolab.ttf'), 14)
def glyph(t):
    im = Image.new('1', (16, 16)); d = ImageDraw.Draw(im)
    if '#' in t:
        run, k = t.rsplit('#', 1); k = int(k); width = ((len(run) + 1) // 2) * 16
        strip = Image.new('1', (width, 16)); sd = ImageDraw.Draw(strip)
        sd.text(((width - 8 * len(run)) // 2, 0), run, font=ascii_font, fill=1)
        im.paste(strip.crop((k * 16, 0, k * 16 + 16, 16)), (0, 0))
    elif t != ' ':
        d.text((0, 0), t, font=cjk_font, fill=1)
    return [sum(int(im.getpixel((x, y)) != 0) << (15 - x) for x in range(16)) for y in range(16)]
glyph_rom = []
for t in cells: glyph_rom += glyph(t)
glyph_rom += [0] * (4096 - len(glyph_rom))
(A / 'osd_glyphs.hex').write_text('\n'.join(f'{x:04x}' for x in glyph_rom) + '\n')
(A / 'osd_messages.hex').write_text('\n'.join(f'{x:02x}' for x in msg_rom) + '\n')
(A / 'osd_menu.hex').write_text('\n'.join(f'{x:02x}' for x in menu_rom) + '\n')
rom = []
for c in range(128):
    im = Image.new('1', (8, 16)); ImageDraw.Draw(im).text((0, -1), chr(c) if c >= 32 else ' ', font=ImageFont.truetype(str(FONTS / 'consola.ttf'), 13), fill=1)
    for y in range(16): rom.append(sum(int(im.getpixel((x, y)) != 0) << (7 - x) for x in range(8)))
(A / 'ascii.hex').write_text('\n'.join(f'{x:02x}' for x in rom) + '\n')

# Audible reference only (PC listening); the FPGA synthesizes its own PCM.
with wave.open(str(A / 'alarm_reference.wav'), 'wb') as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
    frames, phase = [], 0.0
    for n in range(96000):
        f = 600 + 600 * (1 - abs((n % 48000) / 24000 - 1))
        phase += 2 * math.pi * f / 48000
        frames.append(struct.pack('<h', int(6000 * math.sin(phase))))
    w.writeframes(b''.join(frames))
print(f'Prepared PIC1..6.BMP, {len(cells)} glyph cells, menu/message ROMs, preview in {A}')
