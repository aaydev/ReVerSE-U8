@echo off
set rootdir=%cd%
set sjasm=%cd%\tools\sjasmplus.exe
set binhex=%cd%\tools\bin2hex.exe
cls

echo 1) BUILD LOADER
cd boards\reverse_u9\firmwares\loader
del *.bin
del *.hex
%sjasm% loader.asm
%binhex% loader.bin loader.hex
del *.bin
echo .

echo 2) BUILD POST
cd %rootdir%
cd boards\reverse_u9\firmwares\osd
del *.bin
del *.hex
%sjasm% rom.asm
%binhex% rom.bin rom.hex
del *.bin
echo .

echo 3) BUILD ROMS
cd %rootdir%
cd boards\reverse_u9\firmwares\loader\rom
del *.hex
%binhex% 82.rom 82.hex
%binhex% 86.rom 86.hex
%binhex% esxmmc.rom esxmmc.hex
%binhex% gs105a.rom gs105a.hex
%binhex% hegluk_19.rom hegluk_19.hex
%binhex% trdos_605e.rom trdos_605e.hex
echo .

@echo on
@pause
