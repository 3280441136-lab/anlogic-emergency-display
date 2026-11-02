"""Deterministic FAT32 fixture and independent deliverable-image golden checks."""
from pathlib import Path
import struct,json
from PIL import Image
import numpy as np
P=Path(__file__).resolve().parents[1]
def w16(b,o,x):struct.pack_into('<H',b,o,x)
def w32(b,o,x):struct.pack_into('<I',b,o,x)
disk=bytearray(512*128)
boot=bytearray(512);boot[0]=0xeb;w16(boot,11,512);boot[13]=1;w16(boot,14,1);boot[16]=1
w32(boot,32,128);w32(boot,36,1);w32(boot,44,2);boot[510:512]=b'\x55\xaa';disk[:512]=boot
fat=bytearray(512);w32(fat,8,3);w32(fat,12,0x0fffffff);root=bytearray(512)
for i in range(6):
 width,height=(2,2) if i%2==0 else (4,4);top_down=i in (3,4);stride=(width*3+3)&~3
 data=bytearray(54+stride*height);data[:2]=b'BM';w32(data,2,len(data));w32(data,10,54);w32(data,14,40)
 w32(data,18,width);struct.pack_into('<i',data,22,-height if top_down else height);w16(data,26,1);w16(data,28,24)
 for fy in range(height):
  sy=fy if top_down else height-1-fy
  for x in range(width):
   yy=sy//(2 if width==4 else 1);xx=x//(2 if width==4 else 1);value=(i+1)*20+yy*4+xx
   data[54+fy*stride+x*3:54+fy*stride+x*3+3]=bytes([value,2,3])
 cluster=4+i;w32(fat,cluster*4,0x0fffffff);disk[cluster*512:cluster*512+len(data)]=data
 o=i*32;root[o:o+11]=f'PIC{i+1}    BMP'.encode();root[o+11]=0x21;w16(root,o+26,cluster);w32(root,o+28,len(data))
disk[512:1024]=fat;disk[1536:2048]=root
(P/'sim/fat_fixture.hex').write_text('\n'.join(f'{x:02x}' for x in disk)+'\n')
# Golden frames for tb_assets: the six deliverables plus scaling cases covering the
# accepted range (16..2048 per side), both BMP row orders, letterbox and pillarbox.
import sys; sys.path.insert(0,str(P/'scripts'))
from scaler_model import fit_frame,read_bmp_rows,write_bmp,checksums
from PIL import ImageDraw
scale_dir=P/'sim/scale';scale_dir.mkdir(exist_ok=True)
base=Image.open(P/'assets/theme_preview.png').convert('RGB')
def pattern(w,h):
 im=base.resize((w,h),Image.Resampling.LANCZOS) if w>=32 and h>=32 else Image.new('RGB',(w,h))
 d=ImageDraw.Draw(im)
 if w<32 or h<32:
  for y in range(h):
   for x in range(w): im.putpixel((x,y),(255*(x%2),255*(y%2),(x*255)//max(w-1,1)))
 d.rectangle((0,0,w-1,h-1),outline=(255,0,0))          # edges must survive scaling
 d.line((0,0,min(w,h)-1,min(w,h)-1),fill=(0,255,0))    # orientation marker, top-left
 return [[im.getpixel((x,y)) for x in range(w)] for y in range(h)]
cases=[(1920,1080,False),(800,600,False),(320,240,True),(100,300,False),(2048,16,False),(16,16,True)]
files=[str(P/'assets/sdcard'/f'PIC{i+1}.BMP') for i in range(6)]
for w,h,td in cases:
 path=scale_dir/f'S{w}x{h}{"_TD" if td else ""}.BMP'
 if not path.exists(): write_bmp(path,pattern(w,h),top_down=td)
 files.append(str(path))
expected=[]
for path in files:
 rows,W,H,td=read_bmp_rows(path);frame=fit_frame(rows,W,H,td);s,wsum=checksums(frame)
 expected.append({'file':Path(path).name,'width':W,'height':H,'sum':s,'weighted':wsum})
 Image.frombytes('RGB',(640,480),bytes(c for row in frame for p in row for c in p)).save(scale_dir/(Path(path).stem+'_expected.png'))
lines=[f'asset_count={len(files)};']
for i,(path,r) in enumerate(zip(files,expected)):
 rel='../'+Path(path).relative_to(P).as_posix()
 lines.append(f'files[{i}]="{rel}";expected_sum[{i}]=32\'h{r["sum"]:08x};expected_weighted[{i}]=32\'h{r["weighted"]:08x};')
(P/'sim/asset_checks.vh').write_text('\n'.join(lines)+'\n')
(P/'assets/pixel_checks.json').write_text(json.dumps(expected,indent=2))