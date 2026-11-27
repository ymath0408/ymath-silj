@echo off
pushd "%~dp0"
start "YMATH-SILJ" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0server.ps1"
popd
