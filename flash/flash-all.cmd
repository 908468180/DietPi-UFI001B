@echo off
REM flash-all.cmd - flash the dietpi-ufi001b image to an UFI001B (Windows).
REM Requires: edl.exe (https://github.com/bkerler/edl), fastboot.exe in PATH
REM Usage:     flash-all.cmd [--backup]
REM Put the image files next to this script (files\ subfolder or same dir).

setlocal enabledelayedexpansion
set "FILES_DIR=files"
if not exist "%FILES_DIR%" set "FILES_DIR=."

where edl >nul 2>nul || (echo missing: edl & exit /b 1)
where fastboot >nul 2>nul || (echo missing: fastboot & exit /b 1)

for %%F in (aboot hyp rpm sbl1 tz) do (
    if not exist "%FILES_DIR%\%%F.mbn" (echo missing image: %%F.mbn & exit /b 1)
)
if not exist "%FILES_DIR%\gpt_both0.bin" (echo missing image: gpt_both0.bin & exit /b 1)
if not exist "%FILES_DIR%\boot.bin" (echo missing image: boot.bin & exit /b 1)
if not exist "%FILES_DIR%\rootfs.bin" (echo missing image: rootfs.bin & exit /b 1)

if /i "%1"=="--backup" goto backup
if exist "%FILES_DIR%\modem.bin" goto skipbackup
:backup
echo === Backing up original partitions (fsc fsg modem modemst1 modemst2 persist sec)
for %%N in (fsc fsg modem modemst1 modemst2 persist sec) do edl r %%N "%FILES_DIR%\%%N.bin"
if errorlevel 1 exit /b 1
goto install
:skipbackup
echo === Backup found, skipping
:install

echo === Installing custom bootloader
edl w aboot "%FILES_DIR%\aboot.mbn"
if errorlevel 1 exit /b 1
edl e boot
edl reset
echo === Rebooting into fastboot, waiting...
ping -n 4 127.0.0.1 >nul

echo === Flashing partition table + firmware
fastboot flash partition "%FILES_DIR%\gpt_both0.bin"
fastboot flash aboot "%FILES_DIR%\aboot.mbn"
fastboot flash hyp "%FILES_DIR%\hyp.mbn"
fastboot flash rpm "%FILES_DIR%\rpm.mbn"
fastboot flash sbl1 "%FILES_DIR%\sbl1.mbn"
fastboot flash tz "%FILES_DIR%\tz.mbn"
fastboot flash boot "%FILES_DIR%\boot.bin"
fastboot flash rootfs "%FILES_DIR%\rootfs.bin"

echo === Restoring original partitions
for %%N in (fsc fsg modem modemst1 modemst2 persist sec) do fastboot flash %%N "%FILES_DIR%\%%N.bin"

fastboot reboot
echo Done. SSH to 192.168.68.1 (RNDIS) after DietPi first-run.
endlocal