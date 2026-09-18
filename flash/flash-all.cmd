@echo off
setlocal enabledelayedexpansion
title DietPi UFI001B Flasher

set "FILES_DIR=files"
if not exist "%FILES_DIR%" set "FILES_DIR=."

where edl >nul 2>nul || (echo [ERROR] missing: edl & goto :fail)
where fastboot >nul 2>nul || (echo [ERROR] missing: fastboot & goto :fail)

for %%F in (aboot hyp rpm sbl1 tz) do (
    if not exist "%FILES_DIR%\%%F.mbn" (echo [ERROR] missing: %%F.mbn & goto :fail)
)
if not exist "%FILES_DIR%\gpt_both0.bin" (echo [ERROR] missing: gpt_both0.bin & goto :fail)
if not exist "%FILES_DIR%\boot.bin" (echo [ERROR] missing: boot.bin & goto :fail)
if not exist "%FILES_DIR%\rootfs.bin" (echo [ERROR] missing: rootfs.bin & goto :fail)

if /i "%1"=="--backup" goto backup
if exist "%FILES_DIR%\modem.bin" goto skipbackup
:backup
echo [1/5] Backing up original partitions...
for %%N in (fsc fsg modem modemst1 modemst2 persist sec) do (
    echo   - %%N
    edl r %%N "%FILES_DIR%\%%N.bin" >nul 2>nul
)
:skipbackup

echo [2/5] Installing custom bootloader (lk1st)...
edl w aboot "%FILES_DIR%\aboot.mbn" >nul 2>nul
if errorlevel 1 (echo [ERROR] edl write aboot failed & goto :fail)
edl e boot >nul 2>nul
edl reset >nul 2>nul
echo   Waiting for device to enter fastboot...
ping -n 5 127.0.0.1 >nul

echo [3/5] Flashing partition table + firmware...
fastboot flash partition "%FILES_DIR%\gpt_both0.bin"
fastboot flash aboot "%FILES_DIR%\aboot.mbn"
fastboot flash hyp "%FILES_DIR%\hyp.mbn"
fastboot flash rpm "%FILES_DIR%\rpm.mbn"
fastboot flash sbl1 "%FILES_DIR%\sbl1.mbn"
fastboot flash tz "%FILES_DIR%\tz.mbn"
fastboot flash boot "%FILES_DIR%\boot.bin"
echo   Firmware done.

echo [4/5] Flashing rootfs...
fastboot flash rootfs "%FILES_DIR%\rootfs.bin"
if errorlevel 1 (echo [ERROR] rootfs flash failed & goto :fail)
echo   Rootfs done.

echo [5/5] Restoring modem partitions...
for %%N in (fsc fsg modem modemst1 modemst2 persist sec) do (
    echo   - %%N
    fastboot flash %%N "%FILES_DIR%\%%N.bin" >nul 2>nul
)

echo.
echo ==============================
echo   Flash complete! Rebooting...
echo ==============================
fastboot reboot >nul 2>nul

echo.
echo Device will boot DietPi. SSH in via 192.168.68.1 (RNDIS).
echo Closing in 3 seconds...
ping -n 4 127.0.0.1 >nul
exit /b 0

:fail
echo.
echo Press any key to exit...
pause >nul
exit /b 1
