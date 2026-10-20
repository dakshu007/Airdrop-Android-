"""Renders the soft "drop" played when a transfer is verified (res/raw/cd_done.wav).

Usage: python3 scripts/make_sounds.py android/android/app/src/main/res/raw/cd_done.wav
"""
import sys, numpy as np, wave
sr=22050; dur=0.42
t=np.arange(int(sr*dur))/sr
f=880*np.exp(-t*5.5)+520
phase=2*np.pi*np.cumsum(f)/sr
env=np.minimum(t/0.006,1)*np.exp(-t*9)
sig=0.75*np.sin(phase)+0.18*np.sin(2*phase+0.4)
t2=np.clip(t-0.09,0,None)
f2=1180*np.exp(-t2*6)+780
ph2=2*np.pi*np.cumsum(f2)/sr
env2=(t>0.09)*np.minimum(t2/0.006,1)*np.exp(-t2*11)
sig=sig*env+0.45*np.sin(ph2)*env2
sig=sig/np.max(np.abs(sig))*0.8
w=wave.open(sys.argv[1],'wb')
w.setnchannels(1);w.setsampwidth(2);w.setframerate(sr);w.writeframes((sig*32767).astype('<i2').tobytes());w.close()
