@echo off
rem stage MAPS\%1\ beside the exe: the bsp and its four asset files
if not exist MAPS\%1\ASSETS.ZIP goto nomap
copy MAPS\%1\*.* . > nul
goto done
:nomap
echo no map %1 >> run.out
:done
