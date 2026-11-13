@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0step0.ps1"
echo.
echo Finished. Results saved in step0-results.txt and step0-sample.csv in this folder.
pause
