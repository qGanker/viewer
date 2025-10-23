@echo off
echo Building Flutter app...
flutter build windows
if %ERRORLEVEL% EQU 0 (
    echo Build successful!
) else (
    echo Build failed!
)
pause

