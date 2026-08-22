@echo off

rem
rem Build bsp_pvs with Visual Basic for DOS 1.0.
rem
rem VBDOS is not optional. QB 4.5 cannot compile this at all, and PDS 7.1
rem rejects the underscore line continuations. See README.md.
rem
rem The uGL headers and libraries are NOT part of this project, and the
rem library must be the PATCHED one in ugl-patch\ -- see ugl-patch\README.md.
rem
rem     set MGL=C:\MGL
rem     set VBD=C:\VBDOS
rem     mkvbd
rem
rem Sources live in src\, runtime data in data\. Build here, then run the exe
rem from a directory holding stuff.ini, base.dat and a map.
rem

if not "%MGL%"=="" goto haveMgl
set MGL=C:\MGL
echo MGL not set, assuming %MGL%
:haveMgl

if not "%VBD%"=="" goto haveVbd
set VBD=C:\VBDOS
echo VBD not set, assuming %VBD%
:haveVbd

set INCLUDE=%MGL%\INC;src

rem one BC per module; bsp_pvs carries the module-level main code
%VBD%\BIN\BC.EXE /O /FPi /R /G3 /E src\bsp_pvs.bas, bsp_pvs.obj; > bc.out
if not exist bsp_pvs.obj goto bcfail
%VBD%\BIN\BC.EXE /O /FPi /R /G3 /E src\qini.bas, qini.obj; >> bc.out
if not exist qini.obj goto bcfail

if [%DEBUG%]==[TRUE] goto deb
set UGLLIB=ugl-patch\uglv.lib
goto dolink

:deb
set UGLLIB=%MGL%\LIB\DEBUG\VBD\UGLVD.LIB

:dolink
rem LINK's command line would exceed the DOS 127-char limit once there are
rem several modules, and truncation eats the ';' that suppresses its prompts.
echo /NOE /SEG:800 bsp_pvs.obj+qini.obj+%MGL%\LIB\ADDONS\U3D.OBJ > link.rsp
echo bsp_pvs.exe >> link.rsp
echo bsp_pvs.map >> link.rsp
echo %VBD%\LIB\VBDCL10E.LIB+%UGLLIB% >> link.rsp
echo ; >> link.rsp
%VBD%\BIN\LINK.EXE @link.rsp > link.out
if not exist bsp_pvs.exe goto linkfail

del *.obj
echo Built bsp_pvs.exe
goto end

:bcfail
echo COMPILE FAILED -- see bc.out
goto end

:linkfail
echo LINK FAILED -- see link.out

:end
set UGLLIB=
