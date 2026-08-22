@echo off

rem
rem Build bsp_pvs with BASIC PDS 7.1 (BC.EXE + LINK.EXE).
rem See mkqb.bat for the MGL environment variable.
rem

if not "%MGL%"=="" goto haveMgl
set MGL=C:\MGL
echo MGL not set, assuming %MGL%

:haveMgl
set INCLUDE=%MGL%\INC

bc /o /fpi /r /g2 /fs /lr /es bsp_pvs.bas bsp_pvs.obj;
if errorlevel 1 goto end

if [%DEBUG%]==[TRUE] goto deb
set UGLLIB=%MGL%\LIB\UGLP.LIB
goto dolink

:deb
set UGLLIB=%MGL%\LIB\UGLPD.LIB

:dolink
link /seg:800 bsp_pvs.obj,bsp_pvs.exe,nul,bcl71efr.lib+%UGLLIB%;
del bsp_pvs.obj

:end
set UGLLIB=
