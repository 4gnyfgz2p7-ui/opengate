@echo off
setlocal enabledelayedexpansion
set "TOOL=%~dp0opengate_log2.py"
set "PYTHONIOENCODING=gbk"

rem ---- 找 Python：优先 WorkBuddy 内置，其次系统 PATH ----
set "PY="
if exist "C:\Users\amazi\.workbuddy\binaries\python\versions\3.13.12\python.exe" (
  set "PY=C:\Users\amazi\.workbuddy\binaries\python\versions\3.13.12\python.exe"
)
if not defined PY (
  for /f "delims=" %%i in ('where python 2^>nul') do (
    if not defined PY set "PY=%%i"
  )
)
if not defined PY (
  echo.
  echo   找不到 Python。请装 Python 3.10 以上，或改用命令行跑。
  echo.
  pause
  exit /b 1
)

if "%~1"=="" (
  echo.
  echo   ProRes RAW 转 Apple Log 2
  echo   ---------------------------------------------
  echo   把 .mov 文件拖到本文件图标上即可（可一次拖多个）
  echo   输出在源文件旁边，文件名加 _AppleLog2 后缀
  echo.
  pause
  exit /b
)

:loop
if "%~1"=="" goto done
echo.
echo   ============================================
echo   处理：%~nx1
echo   ============================================
"%PY%" "%TOOL%" "%~1" --bitrate 45M --maxrate 90M
shift
goto loop

:done
echo.
echo   全部完成。
pause
