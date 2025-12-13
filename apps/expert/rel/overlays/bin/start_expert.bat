@echo off

cd /d "%~dp0"
.\plain.bat eval "System.no_halt(true); Application.ensure_all_started(:xp_expert)" --stdio

