@echo off
setlocal
set "SRC=D:\Workspace\crosslink_src"
set "FLUTTER=D:\dev\sdk\flutter\bin\flutter.bat"
cd /d "%SRC%"
call "%FLUTTER%" build windows --release
if errorlevel 1 (
  echo 构建失败。
  pause
  exit /b 1
)
start "CrossLink 2.4.0" "%SRC%\build\windows\x64\runner\Release\crosslink.exe"
