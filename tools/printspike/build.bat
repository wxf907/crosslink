@echo off
call "D:\dev\BuildTools\VC\Auxiliary\Build\vcvars64.bat" >nul
cd /d D:\crosslink_src\tools\printspike
cl /nologo /W3 /EHsc /utf-8 /D_CRT_SECURE_NO_WARNINGS printspike.cpp user32.lib gdi32.lib winspool.lib /Fe:printspike.exe
