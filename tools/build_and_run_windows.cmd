@echo off
setlocal
set "SRC=D:\crosslink_src"
set "FLUTTER=D:\dev\sdk\flutter\bin\flutter.bat"
if not exist "%SRC%" (
  echo 找不到源码目录：%SRC%
  pause
  exit /b 1
)
if not exist "%FLUTTER%" (
  echo 找不到 Flutter SDK：%FLUTTER%
  pause
  exit /b 1
)
cd /d "%SRC%"
echo 正在构建 CrossLink Windows 最新源码...
call "%FLUTTER%" build windows --release
if errorlevel 1 (
  echo 构建失败，未启动旧版本。
  pause
  exit /b 1
)
echo 构建完成，正在启动最新 EXE...
start "CrossLink 2.4.0" "%SRC%\build\windows\x64\runner\Release\crosslink.exe"
