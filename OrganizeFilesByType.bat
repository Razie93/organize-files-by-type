@echo off
setlocal DisableDelayedExpansion
rem Do not inherit the old hybrid script's control flags.
set "ORG_PATH="
set "ORG_AUTO="
set "ORG_UNDO="
set "ORG_SKIPOTHER="
set "ORG_SELF="
set "ORG_NAME="
rem No CALL, argument re-evaluation, or PowerShell expression evaluation.
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0OrganizeFilesByType.ps1" %*
exit /b %ERRORLEVEL%
