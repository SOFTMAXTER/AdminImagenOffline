@echo off
:: 1. Verificar privilegios de Administrador
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"

:: Si el comando anterior fallo, no tenemos privilegios
if '%errorlevel%' NEQ '0' (
    echo Solicitando privilegios de Administrador...
    goto UACPrompt
) else (
    goto gotAdmin
)

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"

:: ============================================================================
:: == Ejecucion del Script Principal                                         ==
:: ============================================================================

echo.
echo Privilegios de Administrador obtenidos. Ejecutando AdminImagenOffline..
echo.

:: Establecer el titulo de la ventana
title AdminImagenOffline v1.4.2 by SOFTMAXTER

:: Ruta al script de PowerShell (asume que esta en una carpeta llamada SCRIPT)
set "scriptPath=%~dp0Script\AdminImagenOffline.ps1"

:: Verificar si el script existe
if not exist "%scriptPath%" (
    echo.
    echo [ERROR] No se pudo encontrar el script:
    echo %scriptPath%
    echo.
    echo Asegurate de que el archivo .bat este en la carpeta correcta y
    echo que el script de PowerShell se llame 'AdminImagenOffline.ps1' dentro de la carpeta 'Script'.
    echo.
    goto End
)

:: Ejecutar el script de PowerShell
powershell.exe -ExecutionPolicy Bypass -NoProfile -File "%scriptPath%"

:End
echo.
echo El script ha finalizado. La ventana se cerrara en 5 segundos...
timeout /t 5 /nobreak >nul
exit
