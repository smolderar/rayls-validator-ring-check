@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0step1.ps1"
echo.
echo Finished. Results saved in step1-results.txt and step1-data.csv in this folder.
pause
