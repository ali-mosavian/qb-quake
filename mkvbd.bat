@echo off

rem
rem Build bsp_pvs with Visual Basic for DOS 1.0.
rem
rem VBDOS is not optional. QB 4.5 cannot compile this module at all, and
rem PDS 7.1 rejects the underscore line continuations in bsp_pvs.bi -- that
rem syntax only exists in VBDOS. See README.md.
rem
rem The uGL headers and libraries are NOT part of this project. Point MGL at
rem the uGL tree and VBD at the VBDOS install, e.g.
rem
rem     set MGL=C:\MGL
rem     set VBD=C:\VBDOS
rem     mkvbd
rem
rem BC finds the '$include files through INCLUDE, so the sources name them
rem bare (ugl.bi, u3d.bi, ...) with no path of their own.
rem

if not "%MGL%"=="" goto haveMgl
set MGL=C:\MGL
echo MGL not set, assuming %MGL%
:haveMgl

if not "%VBD%"=="" goto haveVbd
set VBD=C:\VBDOS
echo VBD not set, assuming %VBD%
:haveVbd

set INCLUDE=%MGL%\INC

%VBD%\BIN\BC.EXE /O /FPi /R /G3 /E bsp_pvs.bas, bsp_pvs.obj; > bc.out
if not exist bsp_pvs.obj goto bcfail

if [%DEBUG%]==[TRUE] goto deb
set UGLLIB=%MGL%\LIB\RELEASE\VBD\UGLV.LIB
goto dolink

:deb
set UGLLIB=%MGL%\LIB\DEBUG\VBD\UGLVD.LIB

:dolink
rem u3d is a uGL addon and is not inside uglv.lib -- it must be linked in.
%VBD%\BIN\LINK.EXE /NOE /SEG:800 bsp_pvs.obj+%MGL%\LIB\ADDONS\U3D.OBJ, bsp_pvs.exe, bsp_pvs.map, %VBD%\LIB\VBDCL10E.LIB+%UGLLIB%; > link.out
if not exist bsp_pvs.exe goto linkfail

del bsp_pvs.obj
echo Built bsp_pvs.exe
goto end

:bcfail
echo COMPILE FAILED -- see bc.out
goto end

:linkfail
echo LINK FAILED -- see link.out

:end
set UGLLIB=
