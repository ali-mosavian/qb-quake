@echo off

rem
rem Build bsp_pvs with QuickBASIC 4.5 (BC.EXE + LINK.EXE).
rem
rem The uGL headers and libraries are NOT part of this project. Point MGL at
rem the uGL tree before running this, e.g.
rem
rem     set MGL=C:\MGL
rem     mkqb
rem
rem BC finds the '$include files through INCLUDE, so the sources name them
rem bare (ugl.bi, u3d.bi, ...) with no path of their own.
rem

if not "%MGL%"=="" goto haveMgl
set MGL=C:\MGL
echo MGL not set, assuming %MGL%

:haveMgl
set INCLUDE=%MGL%\INC

bc /o /fpi /r bsp_pvs.bas bsp_pvs.obj;
if errorlevel 1 goto end

if [%DEBUG%]==[TRUE] goto deb
set UGLLIB=%MGL%\LIB\UGL.LIB
goto dolink

:deb
set UGLLIB=%MGL%\LIB\UGLD.LIB

:dolink
link /segments:800 bsp_pvs.obj,bsp_pvs.exe,nul,bcom45.lib+%UGLLIB%;
del bsp_pvs.obj

:end
set UGLLIB=
