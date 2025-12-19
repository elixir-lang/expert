@echo off

"%~dp0plain.bat" eval "System.no_halt(true); Application.ensure_all_started(:xp_expert)" --stdio

