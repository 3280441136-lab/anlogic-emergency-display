from pathlib import Path
import os,subprocess,sys
P=Path(__file__).resolve().parents[1]
# ModelSim binaries (vlib/vlog/vsim); override with the MODELSIM_BIN environment variable.
SIM=Path(os.environ.get('MODELSIM_BIN','D:/00_Software/ModuleSim/modelsim_ase/win32aloem'))
# Official example sources (lab_ex5_i2s src/user_source) are expected in user_source/.
OFF=P/'user_source/hdl_source'
subprocess.run([sys.executable,str(P/'scripts/make_test_fixtures.py')],check=True)
# tb_osd_frame reads 640x480 pixel hex files and writes rendered frames to sim/osd.
subprocess.run([sys.executable,str(P/'scripts/render_osd_frames.py'),'prepare',str(P/'assets'),str(P/'sim/osd')],check=True)
# Optional: bench names to run a subset; --work=<dir> compiles into another library (so a
# subset can run beside a full regression). Log: sim/results.log or <dir>/results.log.
only=[a for a in sys.argv[1:] if not a.startswith('--work=')]
alt=[a[7:] for a in sys.argv[1:] if a.startswith('--work=')]
work=Path(alt[0]).resolve() if alt else P/'sim/work';log=work/'results.log' if alt else P/'sim/results.log'
work.mkdir(parents=True,exist_ok=True);LIB='altwork' if alt else 'work'   # vmap must not remap 'work' under a running regression
sources=[P/'rtl/ed_framebuffer.v',OFF/'IP/afifo_32_16_256.v',OFF/'SD/frame_fifo_read.v',OFF/'IP/afifo_16_32_256.v',*sorted((P/'rtl/storage').glob('*.v')),P/'rtl/media_frame_loader.v',P/'rtl/ed_product.v',P/'rtl/ed_video.v',*sorted((P/'sim').glob('tb_*.sv'))]
# Encrypted official SDRAM controller (ModelSim can decrypt it) for tb_sdram_refresh; the
# embedded SDRAM is the behavioral sim/sdram_model.sv (vendor sim shell never drives dq). -permissive only for these vendor files (unsized-constant
# concatenations); project sources keep the strict compile.
INC=OFF/'include'
vendor=[INC/'sdr_init_ref.enc.v',INC/'sdr_wrrd.enc.v',INC/'sdr_as_ram.enc.v']
sources.insert(0,P/'sim/sdram_model.sv');sources.insert(0,P/'sim/w25q64_model.sv')
sources[1:1]=sorted((P/'rtl/flash').glob('*.v'))
commands=[['vlib.exe',str(work)],['vmap.exe',LIB,str(work)],['vlog.exe','-permissive','-work',LIB,'+incdir+'+str(INC),*[str(p) for p in vendor]],['vlog.exe','-sv','-work',LIB,*[str(p) for p in sources]]]
with log.open('w',encoding='utf-8') as out:
 for args in commands:
  r=subprocess.run([str(SIM/args[0]),*args[1:]],cwd=P/'td_project',stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  text=r.stdout.decode('utf-8',errors='replace');out.write(text);out.flush()
  if r.returncode:print(text[-5000:]);sys.exit(r.returncode)
 for bench in sorted((P/'sim').glob('tb_*.sv')):
  if only and bench.stem not in only:continue
  args=[str(SIM/'vsim.exe'),'-c','-onfinish','stop',LIB+'.'+bench.stem,'-do','onbreak {quit -code 1 -force}; onerror {quit -code 1 -force}; run -all; quit -code 0 -force']
  r=subprocess.run(args,cwd=P/'td_project',stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
  text=r.stdout.decode('utf-8',errors='replace');out.write(text);out.flush()
  print('\n'.join(line for line in text.splitlines() if 'PASS ' in line or '** Error' in line or '** Fatal' in line))
  if r.returncode or 'PASS '+bench.stem not in text:sys.exit(r.returncode or 1)
if any((P/'sim/osd').glob('frame_*.hex')):
 subprocess.run([sys.executable,str(P/'scripts/render_osd_frames.py'),'render',str(P/'sim/osd')],check=True,stdout=subprocess.DEVNULL)
print('All ModelSim benches passed')
