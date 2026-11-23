<#
.SYNOPSIS
    Administra imagenes de Windows (.wim, .vhd/vhdx) sin conexion.
.DESCRIPTION
    Permite montar, desmontar, guardar cambios, editar indices, convertir formatos (ESD/VHD a WIM),
    cambiar ediciones de Windows y realizar tareas de limpieza y reparacion en imagenes offline.
    Utiliza DISM y otras herramientas del sistema. Requiere ejecucion como Administrador.
.AUTHOR
    SOFTMAXTER
.VERSION
    1.5.16

# ==============================================================================
# Copyright (C) 2026 SOFTMAXTER
#
# DUAL LICENSING NOTICE:
# This software is dual-licensed. By default, AdminImagenOffline is 
# distributed under the GNU General Public License v3.0 (GPLv3).
# 
# 1. OPEN SOURCE (GPLv3):
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details: <https://www.gnu.org/licenses/>.
#
# 2. COMMERCIAL LICENSE:
# If you wish to integrate this software into a proprietary/commercial product, 
# distribute it without revealing your source code, or require commercial 
# support, you must obtain a commercial license from the original author.
#
# Please contact softmaxter@hotmail.com for commercial licensing inquiries.
# ==============================================================================

#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.5.16"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Cargar motor de idiomas (i18n) antes de mensajes de arranque y updater
$script:I18nBaseDir = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
$script:I18nModulePath = Join-Path -Path $script:I18nBaseDir -ChildPath 'I18n.ps1'
$script:EarlyPreferredLanguage = 'auto'
try {
    $earlyRoot = Split-Path -Path $script:I18nBaseDir -Parent
    if ($earlyRoot) {
        $earlyCfgPath = Join-Path -Path $earlyRoot -ChildPath 'config.json'
        if (Test-Path -LiteralPath $earlyCfgPath -PathType Leaf) {
            $earlyCfg = [System.IO.File]::ReadAllText($earlyCfgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -ne $earlyCfg.PSObject.Properties['Language'] -and -not [string]::IsNullOrWhiteSpace([string]$earlyCfg.Language)) {
                $script:EarlyPreferredLanguage = [string]$earlyCfg.Language
            }
        }
    }
} catch {}

if (Test-Path -LiteralPath $script:I18nModulePath -PathType Leaf) {
    . $script:I18nModulePath
    [void](Initialize-AIOI18n -PreferredLanguage $script:EarlyPreferredLanguage)
}

if (-not (Get-Command -Name Get-AIOString -ErrorAction SilentlyContinue)) {
    function Get-AIOString {
        param([Parameter(Mandatory = $true, Position = 0)][string]$Key, [Parameter(ValueFromRemainingArguments = $true)][object[]]$FormatArgs)
        if ($FormatArgs -and $FormatArgs.Count -gt 0) {
            return ("[$Key] " + ($FormatArgs -join ' '))
        }
        return "[$Key]"
    }
    Set-Alias -Name T -Value Get-AIOString -Scope Script
    function Test-AIOYesResponse { param([string]$InputText) return ([string]$InputText).Trim().ToUpperInvariant() -in @('S','SI','SÍ','Y','YES') }
    function Test-AIONoResponse { param([string]$InputText) return ([string]$InputText).Trim().ToUpperInvariant() -in @('N','NO') }
    function Get-AIOLanguageDisplaySummary { return 'es (fallback)' }
    function Show-AIOLanguageSelector { return $false }
    function Invoke-AIOWithBaseLanguage { param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock) return (& $ScriptBlock) }
}

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$LogLevel,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    
    # Si falló la inicialización y la variable es nula, salimos silenciosamente
    if (-not $script:logFile) { return }
    
    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $script:logFile -Append -Encoding utf8
    }
    catch {
        Write-Warning (Get-AIOString 'core.log_write_warn' $_)
    }
}

function Release-SingleInstanceMutex {
    $mutex = $Script:SingleInstanceMutex
    try {
        if ($null -ne $mutex -and $Script:SingleInstanceMutexOwned) {
            $mutex.ReleaseMutex()
        }
    } catch {
        Write-Warning (Get-AIOString 'core.mutex_release_warn' $_.Exception.Message)
    } finally {
        try {
            if ($null -ne $mutex) { $mutex.Dispose() }
        } catch {
            Write-Warning (Get-AIOString 'core.mutex_close_warn' $_.Exception.Message)
        } finally {
            $Script:SingleInstanceMutex = $null
            $Script:SingleInstanceMutexOwned = $false
        }
    }
}

# --- INICIO DEL MODULO DE AUTO-ACTUALIZACION ---
function Invoke-FullRepoUpdater {
    $repoUser = "SOFTMAXTER"
    $repoName = "AdminImagenOffline"
    $repoBranch = "main"
    $versionUrl = "https://raw.githubusercontent.com/$repoUser/$repoName/$repoBranch/version.txt"
    $zipUrl = "https://github.com/$repoUser/$repoName/archive/refs/heads/$repoBranch.zip"

    $updateAvailable = $false
    $remoteVersionStr = ""
    $changelog = @()

    try {
        $response = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 5 -ErrorAction Stop
        $lines = $response.Content -split "`r?`n" | ForEach-Object { $_.Trim() }

        if ($lines.Count -gt 0) {
            $remoteVersionStr = $lines[0] -replace '(?i)^v', ''

            $inChangelog = $false
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match "^====+") {
                    if (-not $inChangelog) {
                        $inChangelog = $true
                        continue
                    }
                    break
                }

                if ($inChangelog -and -not [string]::IsNullOrWhiteSpace($lines[$i])) {
                    $changelog += $lines[$i]
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($remoteVersionStr)) {
            throw "El servidor devolvio un archivo de version vacio o no valido."
        }

        try {
            if ([System.Version]$remoteVersionStr -gt [System.Version]$script:Version) {
                $updateAvailable = $true
            }
        }
        catch {
            Write-Log -LogLevel WARN -Message "UPDATER: No fue posible comparar las versiones como System.Version. Se usara comparacion de texto. Detalle: $($_.Exception.Message)"
            if ($remoteVersionStr -ne $script:Version) {
                $updateAvailable = $true
            }
        }
    }
    catch {
        $errorLine = $_.InvocationInfo.ScriptLineNumber
        Write-Log -LogLevel ERROR -Message "UPDATER: Fallo la comprobacion de actualizaciones. Error: $($_.Exception.Message). Linea: $errorLine."
        return
    }

    # Si no existe una version superior, el updater permanece silencioso en el log.
    if (-not $updateAvailable) { return }

    Write-Log -LogLevel INFO -Message "UPDATER: Version remota detectada: v$remoteVersionStr. Version local: v$($script:Version)."
    Write-Log -LogLevel INFO -Message "UPDATER: Nueva version disponible: v$remoteVersionStr."

    Write-Host ""
    Write-Host "  =======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'updater.title') -ForegroundColor Green
    Write-Host "  =======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'updater.local_version' $script:Version) -ForegroundColor Gray
    Write-Host (Get-AIOString 'updater.remote_version' $remoteVersionStr) -ForegroundColor Yellow

    if ($changelog.Count -gt 0) {
        Write-Host "  -------------------------------------------------------" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'updater.changelog_header') -ForegroundColor Magenta
        
        # 1. Obtener el ancho dinámico de la ventana para adaptar el texto 
        $consoleWidth = if ($Host.UI.RawUI.WindowSize.Width -gt 20) { $Host.UI.RawUI.WindowSize.Width - 4 } else { 80 }

        foreach ($line in $changelog) {
            # 2. Utilizar tu función nativa Format-WrappedText para envolver por palabras completas
            $wrappedLines = Format-WrappedText -Text $line -Indent 6 -MaxWidth $consoleWidth
            
            for ($i = 0; $i -lt $wrappedLines.Count; $i++) {
                # 3. Sangría francesa: Si la línea envuelta es la continuación de una viñeta (-),
                # le añadimos 2 espacios extra para que quede perfectamente alineada bajo el texto.
                if ($i -gt 0 -and $line.StartsWith("-")) {
                    Write-Host "  $($wrappedLines[$i])" -ForegroundColor White
                } else {
                    Write-Host $wrappedLines[$i] -ForegroundColor White
                }
            }
        }
    }

    Write-Host "  =======================================================" -ForegroundColor Cyan

    $updateChoice = (Read-Host (Get-AIOString 'updater.prompt_install')).Trim()
    if (-not (Test-AIOYesResponse $updateChoice)) {
        Write-Host (Get-AIOString 'updater.postponed') -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "UPDATER: Actualizacion a v$remoteVersionStr pospuesta por el usuario. Respuesta: '$updateChoice'."
        Start-Sleep -Seconds 1
        return
    }

    Write-Log -LogLevel ACTION -Message "UPDATER: El usuario acepto instalar la version v$remoteVersionStr."
    Write-Host (Get-AIOString 'updater.preparing') -ForegroundColor Magenta

    $installPath = $null
    $tempZip = $null
    $tempExtract = $null
    $batPath = $null

    try {
        $updaterScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
            $PSScriptRoot
        }
        elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
            Split-Path -Path $PSCommandPath -Parent
        }
        else {
            $PWD.Path
        }

        # AdminImagenOffline.ps1 y sus modulos viven en \Script; la instalacion es su carpeta padre.
        $installPath = Split-Path -Path $updaterScriptRoot -Parent
        if ([string]::IsNullOrWhiteSpace($installPath) -or -not (Test-Path -LiteralPath $installPath -PathType Container)) {
            throw "No se pudo determinar una ruta de instalacion valida. ScriptRoot: '$updaterScriptRoot'"
        }

        $tempZip = Join-Path -Path $installPath -ChildPath "update.zip"
        $tempExtract = Join-Path -Path $installPath -ChildPath "update_extracted"
        $batPath = Join-Path -Path $installPath -ChildPath "ApplyUpdate.cmd"
        $exePath = Join-Path -Path $installPath -ChildPath "AdminImagenOffline.exe"

        Write-Log -LogLevel INFO -Message "UPDATER: Ruta de instalacion resuelta: '$installPath'."

        if (Test-Path -LiteralPath $tempExtract) {
            Write-Log -LogLevel ACTION -Message "UPDATER: Eliminando carpeta temporal anterior '$tempExtract'."
            Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $tempZip) {
            Write-Log -LogLevel ACTION -Message "UPDATER: Eliminando paquete temporal anterior '$tempZip'."
            Remove-Item -LiteralPath $tempZip -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $batPath) {
            Write-Log -LogLevel ACTION -Message "UPDATER: Eliminando instalador temporal anterior '$batPath'."
            Remove-Item -LiteralPath $batPath -Force -ErrorAction Stop
        }

        Write-Host (Get-AIOString 'updater.downloading' $remoteVersionStr) -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "UPDATER: Descargando paquete v$remoteVersionStr."
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $tempZip -PathType Leaf)) {
            throw "La descarga finalizo sin crear el archivo '$tempZip'."
        }
        $downloadSize = (Get-Item -LiteralPath $tempZip -ErrorAction Stop).Length
        if ($downloadSize -le 0) { throw "El paquete descargado esta vacio." }
        Write-Log -LogLevel INFO -Message "UPDATER: Descarga completada. Tamano: $downloadSize bytes."

        Write-Host (Get-AIOString 'updater.extracting') -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "UPDATER: Extrayendo paquete en '$tempExtract'."
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop

        $repoExtractedPath = Join-Path -Path $tempExtract -ChildPath "AdminImagenOffline-main"
        if (-not (Test-Path -LiteralPath $repoExtractedPath -PathType Container)) {
            throw "La estructura esperada del paquete no existe: '$repoExtractedPath'."
        }
        Write-Log -LogLevel INFO -Message "UPDATER: Extraccion completada correctamente."

        Write-Host (Get-AIOString 'updater.generating_installer') -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "UPDATER: Generando instalador diferido '$batPath'."

        # ApplyUpdate.cmd continuara despues de que PowerShell termine. Se le pasa
        # el PID actual para esperar solo el tiempo necesario hasta liberar archivos.
        $updaterParentPid = $PID

        $batContent = @"
@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Instalando Actualizacion...
color 0B

set "LOGDIR=%~dp0Logs"
set "LOGFILE=%LOGDIR%\Registro.log"
if not exist "%LOGDIR%" mkdir "%LOGDIR%" >NUL 2>&1

echo [%date% %time:~0,8%] [ACTION] - UPDATER CMD: Proceso de instalacion iniciado. Version destino: v$remoteVersionStr.>>"%LOGFILE%"

echo.
echo =========================================================
echo    APLICANDO ACTUALIZACION A LA VERSION $remoteVersionStr
echo =========================================================
echo.
echo Esperando a que el sistema libere los archivos...
echo [%date% %time:~0,8%] [ACTION] - UPDATER CMD: Esperando cierre del proceso origen PID $updaterParentPid.>>"%LOGFILE%"

set /a "WAIT_COUNT=0"
:WAIT_PARENT_PROCESS
tasklist /FI "PID eq $updaterParentPid" /NH 2^>NUL | findstr /R /C:"[ ]$updaterParentPid[ ]" >NUL
if errorlevel 1 goto PARENT_RELEASED

set /a "WAIT_COUNT+=1"
if !WAIT_COUNT! GEQ 30 (
    echo [%date% %time:~0,8%] [WARN] - UPDATER CMD: El proceso PID $updaterParentPid sigue activo tras 30 segundos. Se continuara con la actualizacion.>>"%LOGFILE%"
    goto PARENT_RELEASED
)

ping 127.0.0.1 -n 2 >NUL
goto WAIT_PARENT_PROCESS

:PARENT_RELEASED
echo [%date% %time:~0,8%] [INFO] - UPDATER CMD: Archivos liberados tras !WAIT_COUNT! segundo(s) de espera.>>"%LOGFILE%"

echo Instalando nuevos archivos...
echo [%date% %time:~0,8%] [ACTION] - UPDATER CMD: Copiando archivos nuevos sobre la instalacion.>>"%LOGFILE%"
xcopy /Y /E /H /C /I "%~dp0update_extracted\AdminImagenOffline-main\*" "%~dp0" >NUL 2>&1
set "XCOPY_EXIT=!ERRORLEVEL!"

if not "!XCOPY_EXIT!"=="0" (
    echo [%date% %time:~0,8%] [ERROR] - UPDATER CMD: XCOPY fallo. Codigo de salida: !XCOPY_EXIT!. Los temporales se conservaran para diagnostico.>>"%LOGFILE%"
    echo.
    echo [ERROR] No se pudo aplicar la actualizacion. Codigo XCOPY: !XCOPY_EXIT!
    echo Revisa Logs\Registro.log para mas detalles.
    timeout /t 8 /nobreak >NUL
    exit /b !XCOPY_EXIT!
)

echo [%date% %time:~0,8%] [INFO] - UPDATER CMD: Archivos de la nueva version copiados correctamente.>>"%LOGFILE%"

echo Limpiando temporales...
echo [%date% %time:~0,8%] [ACTION] - UPDATER CMD: Eliminando archivos temporales de actualizacion.>>"%LOGFILE%"
rmdir /S /Q "%~dp0update_extracted" 2>NUL
if errorlevel 1 echo [%date% %time:~0,8%] [WARN] - UPDATER CMD: No se pudo eliminar completamente update_extracted.>>"%LOGFILE%"

del /F /Q "%~dp0update.zip" 2>NUL
if errorlevel 1 echo [%date% %time:~0,8%] [WARN] - UPDATER CMD: No se pudo eliminar update.zip.>>"%LOGFILE%"

echo Reiniciando aplicacion...
if not exist "$exePath" (
    echo [%date% %time:~0,8%] [ERROR] - UPDATER CMD: No se encontro '$exePath' despues de aplicar la actualizacion.>>"%LOGFILE%"
    echo [ERROR] No se encontro AdminImagenOffline.exe.
    timeout /t 8 /nobreak >NUL
    exit /b 10
)

echo [%date% %time:~0,8%] [ACTION] - UPDATER CMD: Reiniciando AdminImagenOffline.exe.>>"%LOGFILE%"
start "" "$exePath"
set "START_EXIT=!ERRORLEVEL!"
if not "!START_EXIT!"=="0" (
    echo [%date% %time:~0,8%] [ERROR] - UPDATER CMD: No se pudo reiniciar la aplicacion. Codigo: !START_EXIT!.>>"%LOGFILE%"
    exit /b !START_EXIT!
)

echo [%date% %time:~0,8%] [INFO] - UPDATER CMD: Actualizacion a v$remoteVersionStr aplicada correctamente.>>"%LOGFILE%"
del "%~f0"
"@

        [System.IO.File]::WriteAllText($batPath, $batContent, [System.Text.Encoding]::ASCII)
        if (-not (Test-Path -LiteralPath $batPath -PathType Leaf)) {
            throw "No se pudo generar '$batPath'."
        }
        Write-Log -LogLevel INFO -Message "UPDATER: Instalador diferido generado correctamente."

        Write-Host (Get-AIOString 'updater.closing_to_apply') -ForegroundColor Red
        Write-Log -LogLevel ACTION -Message "UPDATER: Lanzando ApplyUpdate.cmd y cerrando la sesion actual para liberar archivos."
        Start-Sleep -Seconds 2

        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$batPath`"" -ErrorAction Stop | Out-Null
        Write-Log -LogLevel INFO -Message "UPDATER: ApplyUpdate.cmd iniciado correctamente. El registro continuara desde CMD."
        Release-SingleInstanceMutex
        exit
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        $errorLine = $_.InvocationInfo.ScriptLineNumber

        Write-Host (Get-AIOString 'core.updater_failed' $errorMessage) -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "UPDATER: Fallo durante la preparacion de la actualizacion. Error: $errorMessage. Tipo: $errorType. Linea: $errorLine."

        if ($tempZip -and (Test-Path -LiteralPath $tempZip)) {
            try { Remove-Item -LiteralPath $tempZip -Force -ErrorAction Stop }
            catch { Write-Log -LogLevel WARN -Message "UPDATER: No se pudo eliminar '$tempZip' despues del error. Motivo: $($_.Exception.Message)" }
        }

        if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
            try { Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction Stop }
            catch { Write-Log -LogLevel WARN -Message "UPDATER: No se pudo eliminar '$tempExtract' despues del error. Motivo: $($_.Exception.Message)" }
        }

        Start-Sleep -Seconds 3
    }
}

function Format-WrappedText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Text,

        [Parameter(Mandatory=$true)]
        [int]$Indent,

        [Parameter(Mandatory=$true)]
        [int]$MaxWidth
    )

    # Calculamos el ancho real disponible para el texto, restando la sangria.
    $wrapWidth = $MaxWidth - $Indent
    if ($wrapWidth -le 0) { $wrapWidth = 1 } # Evitar un ancho negativo o cero

    $words = $Text -split '\s+'
    $lines = [System.Collections.Generic.List[string]]::new()
    $currentLine = ""

    foreach ($word in $words) {
        # Si la linea actual esta vacia, simplemente añadimos la palabra.
        if ($currentLine.Length -eq 0) {
            $currentLine = $word
        }
        # Si añadir la siguiente palabra (con un espacio) excede el limite...
        elseif (($currentLine.Length + $word.Length + 1) -gt $wrapWidth) {
            # ...guardamos la linea actual y empezamos una nueva con la palabra actual.
            $lines.Add($currentLine)
            $currentLine = $word
        }
        # Si no excede el limite, añadimos la palabra a la linea actual.
        else {
            $currentLine += " " + $word
        }
    }
    # Añadimos la ultima linea que se estaba construyendo.
    if ($currentLine) {
        $lines.Add($currentLine)
    }

    # Creamos el bloque de texto final con la sangria aplicada a cada linea.
    $indentation = " " * $Indent
    return $lines | ForEach-Object { "$indentation$_" }
}

# --- HELPER: Obtener letra de unidad libre (Z -> A) ---
function Get-UnusedDriveLetter {
    param(
        # Array opcional para letras que el script ha reservado en memoria 
        # pero que Windows aún no ha registrado completamente.
        [string[]]$AlreadyReserved = @()
    )

    # Usamos un HashSet para rendimiento y para evitar duplicados automáticamente
    $usedLetters = New-Object System.Collections.Generic.HashSet[string]

    # 1. .NET Nativo: Detecta discos locales y de red en el token de Administrador actual.
    [System.IO.DriveInfo]::GetDrives() | ForEach-Object { 
        $null = $usedLetters.Add($_.Name[0].ToString().ToUpper()) 
    }

    # 2. WMI/CIM: Detecta volúmenes lógicos a nivel de sistema profundo.
    Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.DeviceID) { $null = $usedLetters.Add($_.DeviceID[0].ToString().ToUpper()) }
    }

    # 3. PSDrive: Detecta mapeos temporales exclusivos de la sesión de PowerShell.
    Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.Name.Length -eq 1) { $null = $usedLetters.Add($_.Name.ToUpper()) }
    }

    # 4. El "Cazafantasmas" del Registro: Detecta unidades de red mapeadas por el 
    # usuario estándar que el token de Administrador no puede ver por culpa de UAC.
    $regNetwork = "HKCU:\Network"
    if (Test-Path -LiteralPath $regNetwork) {
        Get-ChildItem -Path $regNetwork -ErrorAction SilentlyContinue | ForEach-Object {
            $null = $usedLetters.Add($_.PSChildName.ToUpper())
        }
    }

    # 5. Reservas dinámicas del script (Parámetro fantasma corregido).
    if ($AlreadyReserved) {
        $AlreadyReserved | ForEach-Object { 
            $null = $usedLetters.Add($_[0].ToString().ToUpper()) 
        }
    }

    $alphabet = [char[]](90..70) 

    foreach ($letterChar in $alphabet) {
        $letter = $letterChar.ToString()
        
        # Si la letra no está en nuestra lista negra, es segura para usar.
        if (-not $usedLetters.Contains($letter)) {
            return $letter
        }
    }

    throw "Excepcion de Montaje: No hay letras de unidad disponibles (rango Z: a F:) para adjuntar particiones temporales."
}

# --- Carga la configuracion desde el archivo JSON ---
function Load-Config {
    if (Test-Path $script:configFile) {
        Write-Host (Get-AIOString 'config.loading' $script:configFile) -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "Cargando configuracion desde $script:configFile"
        try {
            $config = [System.IO.File]::ReadAllText($script:configFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            
            if ($config.MountDir) {
                $Script:MOUNT_DIR = $config.MountDir
                Write-Log -LogLevel INFO -Message "Config: MOUNT_DIR cargado como '$($Script:MOUNT_DIR)'"
            }
            if ($config.ScratchDir) {
                $Script:Scratch_DIR = $config.ScratchDir
                Write-Log -LogLevel INFO -Message "Config: Scratch_DIR cargado como '$($Script:Scratch_DIR)'"
            }
            if ($null -ne $config.PSObject.Properties['Language'] -and -not [string]::IsNullOrWhiteSpace([string]$config.Language)) {
                $Script:UI_LANGUAGE = [string]$config.Language
                Write-Log -LogLevel INFO -Message "Config: UI_LANGUAGE cargado como '$($Script:UI_LANGUAGE)'"
                if (Get-Command -Name Initialize-AIOI18n -ErrorAction SilentlyContinue) {
                    [void](Initialize-AIOI18n -PreferredLanguage $Script:UI_LANGUAGE)
                }
            }
        } catch {
            Write-Warning (Get-AIOString 'config.load_warn')
            Write-Log -LogLevel WARN -Message "Fallo al leer/parsear config.json. Error: $($_.Exception.Message)"
        }
    } else {
        Write-Log -LogLevel INFO -Message "No se encontro archivo de configuracion. Usando valores por defecto."
        # Si el archivo no existe, no hacemos nada, se usan los defaults.
    }
}

# --- Guarda la configuracion actual en el archivo JSON ---
function Save-Config {
    Write-Log -LogLevel INFO -Message "Guardando configuracion..."
    try {
        $configToSave = @{
            MountDir   = $Script:MOUNT_DIR
            ScratchDir = $Script:Scratch_DIR
            Language   = if ([string]::IsNullOrWhiteSpace($Script:UI_LANGUAGE)) { 'auto' } else { $Script:UI_LANGUAGE }
        }
        $configToSave | ConvertTo-Json | Set-Content -Path $script:configFile -Encoding utf8
        Write-Host (Get-AIOString 'config.saved_ok') -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Configuracion guardada en $script:configFile"
    } catch {
        Write-Host (Get-AIOString 'config.save_error' $script:configFile)
        Write-Log -LogLevel ERROR -Message "Fallo al guardar config.json. Error: $($_.Exception.Message)"
        Pause
    }
}

# --- Verifica que los directorios de trabajo existan antes de iniciar ---
function Ensure-WorkingDirectories {
    Write-Log -LogLevel INFO -Message "Verificando directorios de trabajo..."
    Clear-Host
    
    # --- 1. Verificar MOUNT_DIR ---
    if (-not (Test-Path $Script:MOUNT_DIR)) {
        Write-Warning (Get-AIOString 'core.mount_dir_missing')
        Write-Host $Script:MOUNT_DIR -ForegroundColor Yellow
        Write-Host ""
        Write-Host (Get-AIOString 'core.dir_opt_create')
        Write-Host (Get-AIOString 'core.dir_opt_select')
        Write-Host (Get-AIOString 'core.dir_opt_exit')
        $choice = Read-Host ("`n" + (Get-AIOString 'common.select_option'))
        
        switch ($choice.ToUpper()) {
            'C' {
                Write-Host (Get-AIOString 'core.dir_creating' $Script:MOUNT_DIR) -ForegroundColor Yellow
                try {
                    New-Item -Path $Script:MOUNT_DIR -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Write-Host (Get-AIOString 'core.dir_created_ok') -ForegroundColor Green
                    Write-Log -LogLevel ACTION -Message "Directorio MOUNT_DIR '$($Script:MOUNT_DIR)' creado automaticamente."
                } catch {
                    Write-Host (Get-AIOString 'core.dir_create_err' $_.Exception.Message)
                    Write-Log -LogLevel ERROR -Message "Fallo al auto-crear MOUNT_DIR. Error: $($_.Exception.Message)"
                    Read-Host (Get-AIOString 'core.press_enter_exit'); Release-SingleInstanceMutex; exit
                }
            }
            'S' {
                Write-Host (Get-AIOString 'config.select_new_mount') -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title (Get-AIOString 'config.dialog_mount_title')
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:MOUNT_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: MOUNT_DIR cambiado a '$newPath' (en el inicio)."
                    Save-Config # Guardar la nueva seleccion
                } else {
                    Write-Warning (Get-AIOString 'core.dir_no_path_exit')
                    Read-Host (Get-AIOString 'core.press_enter_exit'); Release-SingleInstanceMutex; exit
                }
            }
            default {
                Write-Host (Get-AIOString 'core.dir_cancelled_exit')
                Write-Log -LogLevel INFO -Message "Usuario cancelo en la verificacion de directorios."
                Release-SingleInstanceMutex
                exit
            }
        }
    }

    # --- 2. Verificar Scratch_DIR ---
    if (-not (Test-Path $Script:Scratch_DIR)) {
        Write-Warning (Get-AIOString 'core.scratch_dir_missing')
        Write-Host $Script:Scratch_DIR -ForegroundColor Yellow
        Write-Host ""
        Write-Host (Get-AIOString 'core.dir_opt_create')
        Write-Host (Get-AIOString 'core.dir_opt_select_perm')
        Write-Host (Get-AIOString 'core.dir_opt_exit')
        $choice = Read-Host ("`n" + (Get-AIOString 'common.select_option'))
        
        switch ($choice.ToUpper()) {
            'C' {
                Write-Host (Get-AIOString 'core.dir_creating' $Script:Scratch_DIR) -ForegroundColor Yellow
                try {
                    New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Write-Host (Get-AIOString 'core.dir_created_ok') -ForegroundColor Green
                    Write-Log -LogLevel ACTION -Message "Directorio Scratch_DIR '$($Script:Scratch_DIR)' creado automaticamente."
                } catch {
                    Write-Host (Get-AIOString 'core.dir_create_err' $_.Exception.Message)
                    Write-Log -LogLevel ERROR -Message "Fallo al auto-crear Scratch_DIR. Error: $($_.Exception.Message)"
                    Read-Host (Get-AIOString 'core.press_enter_exit'); Release-SingleInstanceMutex; exit
                }
            }
            'S' {
                Write-Host (Get-AIOString 'config.select_new_scratch') -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title (Get-AIOString 'config.dialog_scratch_title')
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:Scratch_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: Scratch_DIR cambiado a '$newPath' (en el inicio)."
                    Save-Config # Guardar la nueva seleccion
                } else {
                    Write-Warning (Get-AIOString 'core.dir_no_path_exit')
                    Read-Host (Get-AIOString 'core.press_enter_exit'); Release-SingleInstanceMutex; exit
                }
            }
            default {
                Write-Host (Get-AIOString 'core.dir_cancelled_exit')
                Write-Log -LogLevel INFO -Message "Usuario cancelo en la verificacion de directorios."
                Release-SingleInstanceMutex
                exit
            }
        }
    }
    
    Write-Log -LogLevel INFO -Message "Verificacion de directorios de trabajo completada."
    Start-Sleep -Seconds 1
}

function Initialize-ScratchSpace {
    # Crear el espacio si falta. Nunca recorrer ni borrar su contenido al iniciar:
    # puede albergar montajes pendientes que DISM omite por ser invalidos.
    try {
        if (-not (Test-Path -LiteralPath $Script:Scratch_DIR -PathType Container)) {
            New-Item -Path $Script:Scratch_DIR -ItemType Directory -ErrorAction Stop | Out-Null
        }
        Write-Log -LogLevel INFO -Message "Scratch_DIR disponible. Se conserva el contenido existente: '$Script:Scratch_DIR'."
    } catch {
        Write-Warning (Get-AIOString 'core.scratch_prep_warn' $_.Exception.Message)
        Write-Log -LogLevel ERROR -Message "Fallo al preparar Scratch_DIR: $($_.Exception.Message)"
    }
}

# =================================================================
#  Verificacion de Permisos de Administrador
# =================================================================
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning (Get-AIOString 'core.admin_req_warn')
    Write-Host (Get-AIOString 'core.admin_req_hint')
    Read-Host (Get-AIOString 'core.press_enter_exit')
    exit
}

# =================================================================
#  Control de Instancia Unica (Mutex Global)
# =================================================================
$Script:SingleInstanceMutexName  = "Global\SOFTMAXTER_AdminImagenOffline_SingleInstance"
$Script:SingleInstanceMutex      = $null
$Script:SingleInstanceMutexOwned = $false

try {
    $Script:SingleInstanceMutex = New-Object -TypeName System.Threading.Mutex -ArgumentList @($false, $Script:SingleInstanceMutexName) -ErrorAction Stop
    try {
        $Script:SingleInstanceMutexOwned = $Script:SingleInstanceMutex.WaitOne(0, $false)
    }
    catch [System.Threading.AbandonedMutexException] {
        # Si la sesion previa se cerro forzosamente, el sistema nos transfiere el bloqueo
        $Script:SingleInstanceMutexOwned = $true
    }
}
catch {
    $mutexError = $_.Exception.Message
    Release-SingleInstanceMutex
    # No cambiar a Local ni continuar sin bloqueo: seria una instancia sin
    # coordinacion con las que ya adquirieron el mutex global.
    Write-Host (Get-AIOString 'core.mutex_acquire_err') -ForegroundColor Red
    Write-Host (Get-AIOString 'core.mutex_protect_hint') -ForegroundColor Yellow
    Write-Host (Get-AIOString 'core.detail_fmt' $mutexError) -ForegroundColor Gray
    Read-Host (Get-AIOString 'core.press_enter_exit')
    exit 1
}

if (-not $Script:SingleInstanceMutexOwned) {
    # Esta copia no es propietaria; cerrar su handle antes de mostrar el aviso.
    Release-SingleInstanceMutex
    try { [System.Console]::Beep(400, 250) } catch {}
    Write-Host ""
    Write-Host "  =======================================================" -ForegroundColor Red
    Write-Host (Get-AIOString 'startup.single_instance_title') -ForegroundColor Yellow
    Write-Host "  =======================================================" -ForegroundColor Red
    Write-Host (Get-AIOString 'startup.single_instance_line1') -ForegroundColor White
    Write-Host (Get-AIOString 'startup.single_instance_line2') -ForegroundColor Gray
    Write-Host (Get-AIOString 'startup.single_instance_line3') -ForegroundColor Gray
    Write-Host ""

    for ($sec = 3; $sec -ge 1; $sec--) {
        Write-Host (Get-AIOString 'startup.single_instance_countdown' $sec) -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    Write-Host ""

    # Restaurar y traer al frente la ventana activa de AdminImagenOffline al cerrar esta copia
    try {
        $winFocusDef = @'
using System;
using System.Runtime.InteropServices;
public static class WinFocusHelper {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
}
'@
        if (-not ([System.Management.Automation.PSTypeName]'WinFocusHelper').Type) {
            Add-Type -TypeDefinition $winFocusDef -ErrorAction SilentlyContinue | Out-Null
        }
        $existingProc = Get-Process -Name "powershell", "pwsh", "WindowsTerminal" -ErrorAction SilentlyContinue |
            Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -like "*AdminImagenOffline*" } |
            Select-Object -First 1
        if (-not $existingProc) {
            # Fallback: si la instancia activa tiene abierto un dialogo modal WinForms, su MainWindowTitle cambia al del modulo
            $cimMatch = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*AdminImagenOffline.ps1*" } |
                Select-Object -First 1
            if ($cimMatch) {
                $existingProc = Get-Process -Id $cimMatch.ProcessId -ErrorAction SilentlyContinue |
                    Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero }
            }
        }
        if ($existingProc) {
            if ([WinFocusHelper]::IsIconic($existingProc.MainWindowHandle)) {
                [WinFocusHelper]::ShowWindowAsync($existingProc.MainWindowHandle, 9) | Out-Null
            }
            [WinFocusHelper]::SetForegroundWindow($existingProc.MainWindowHandle) | Out-Null
        }
    } catch {}

    exit 1
}

# Cubrir tambien las salidas y errores de inicializacion anteriores al menu.
# El bloque try no crea otro scope: las funciones siguen viendo $Script:.
try {
try { $Host.UI.RawUI.WindowTitle = "AdminImagenOffline v$($script:Version) by SOFTMAXTER" } catch {}

try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    $name = "LongPathsEnabled"
    
    # Obtenemos la propiedad; si no existe, no arrojara error gracias a SilentlyContinue
    $regItem = Get-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
    
    if ($null -ne $regItem -and $regItem.$name -eq 1) {
        # Write-Host " -> [OK] El soporte para rutas largas ya esta habilitado en el sistema." -ForegroundColor Green
        # Si ya tienes declarada la funcion Write-Log en este punto, puedes descomentar la siguiente linea:
        # Write-Log -LogLevel INFO -Message "Soporte para rutas largas (Long Paths) preexistente y verificado."
    } else {
        Write-Host (Get-AIOString 'startup.longpaths_enabling') -ForegroundColor Yellow
        Set-ItemProperty -Path $regPath -Name $name -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Host (Get-AIOString 'startup.longpaths_enabled') -ForegroundColor Green
        # Write-Log -LogLevel ACTION -Message "Soporte para rutas largas (Long Paths) habilitado dinamicamente."
    }
} catch {
    Write-Warning (Get-AIOString 'startup.longpaths_warn')
    Write-Host (Get-AIOString 'startup.longpaths_hint') -ForegroundColor Yellow
    # Write-Log -LogLevel ERROR -Message "Fallo al comprobar/habilitar LongPathsEnabled: $($_.Exception.Message)"
}

# =================================================================
#  Registro Inicial y Rotación de Logs
# =================================================================
try {
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    $parentDir = Split-Path -Parent $scriptRoot
    $script:logDir = Join-Path -Path $parentDir -ChildPath "Logs"
    
    if (-not (Test-Path $script:logDir)) {
        New-Item -Path $script:logDir -ItemType Directory -Force | Out-Null
    }
    
    $script:logFile = Join-Path -Path $script:logDir -ChildPath "Registro.log"

    # --- LÓGICA DE ROTACIÓN (Se ejecuta SOLO al abrir AdminImagenOffline) ---
    $maxLogSizeMB = 5
    
    if (Test-Path -LiteralPath $script:logFile) {
        $logItem = Get-Item -LiteralPath $script:logFile
        
        # Si supera el límite, rotamos el archivo antes de iniciar la sesión
        if ($logItem.Length -gt ($maxLogSizeMB * 1MB)) {
            Write-Host (Get-AIOString 'startup.log_maintenance') -ForegroundColor Gray
            $oldLogFile = Join-Path -Path $script:logDir -ChildPath "Registro_old.log"
            
            # Sobrescribe el backup viejo con el log gigante actual y empieza uno nuevo
            Move-Item -LiteralPath $script:logFile -Destination $oldLogFile -Force
        }
    }
} catch {
    Write-Warning (Get-AIOString 'startup.log_dir_warn' $_)
    $script:logFile = $null
}

Write-Log -LogLevel INFO -Message "================================================="
Write-Log -LogLevel INFO -Message "AdminImagenOffline v$($script:Version) iniciado en modo Administrador."

# Ejecutar el actualizador despues de inicializar Registro.log
Invoke-FullRepoUpdater

# =================================================================
#  Variables Globales y Rutas
# =================================================================
# --- Rutas por Defecto ---
$defaultMountDir = "C:\TEMP"
$defaultScratchDir = "C:\TEMP1"

# --- Ruta del Archivo de Configuracion ---
# ($scriptRoot se define en la seccion "Registro Inicial")
$parentDir = Split-Path -Parent $scriptRoot
$script:configFile = Join-Path $parentDir "config.json"

# --- Inicializar variables globales con los valores por defecto ---
$Script:WIM_FILE_PATH = $null
$Script:MOUNT_DIR = $defaultMountDir
$Script:Scratch_DIR = $defaultScratchDir
$Script:UI_LANGUAGE = 'auto'
$Script:IMAGE_MOUNTED = 0
$Script:MOUNTED_INDEX = $null
$Script:CachedControlSet = $null
$Script:OfflineUserClassesPresent = $null
$Script:AIODashboardCache = $null
$Script:ForceMenuRefresh = $false
$Script:GlobalPrivilegesEnabled = $false
$Script:AIOEnabledPrivileges = @{}

$script:ModulosFallidos = New-Object System.Collections.Generic.List[string]
$modulosDisponibles = @(Get-ChildItem -Path $PSScriptRoot -Filter "Modulo-*.ps1" -File -ErrorAction SilentlyContinue | Sort-Object Name)

if ($modulosDisponibles.Count -eq 0) {
    Write-Log -LogLevel WARN -Message "No se encontraron archivos Modulo-*.ps1 en '$PSScriptRoot'."
}

# --- Deteccion de posibles duplicados ---
$nombresBase = @($modulosDisponibles | ForEach-Object { $_.BaseName })
$modulosOmitidos = New-Object System.Collections.Generic.List[string]
$modulosACargar = New-Object System.Collections.Generic.List[System.IO.FileInfo]

foreach ($modulo in $modulosDisponibles) {
    $esDuplicadoConParentesis = $modulo.BaseName -match '^(?<base>Modulo-.+?)\s*\(\d+\)$'
    $esDuplicadoConSufijo = $false
    if (-not $esDuplicadoConParentesis -and $modulo.BaseName -match '^(?<base>Modulo-.+?)[_\-\s]*(?<num>\d+)$') {
        $baseSinSufijo = $matches['base']
        if ($baseSinSufijo -in $nombresBase) { $esDuplicadoConSufijo = $true }
    }

    if ($esDuplicadoConParentesis -or $esDuplicadoConSufijo) {
        Write-Log -LogLevel WARN -Message "Posible duplicado omitido: '$($modulo.Name)' (coincide con otro modulo base)."
        [void]$modulosOmitidos.Add($modulo.Name)
        continue
    }
    [void]$modulosACargar.Add($modulo)
}

$modulosCargados = 0

foreach ($modulo in $modulosACargar) {
    try {
        . $modulo.FullName
        $modulosCargados++
    }
    catch {
        Write-Log -LogLevel ERROR -Message "Fallo al cargar '$($modulo.Name)': $($_.Exception.Message) (Linea $($_.InvocationInfo.ScriptLineNumber))"
        [void]$script:ModulosFallidos.Add($modulo.Name)
    }
}

Write-Log -LogLevel INFO -Message "Modulos funcionales: $modulosCargados cargados | $($script:ModulosFallidos.Count) fallidos | $($modulosOmitidos.Count) omitidos."

if ($modulosOmitidos.Count -gt 0) {
    Write-Host (Get-AIOString 'startup.modules_duplicates_warn' $modulosOmitidos.Count) -ForegroundColor Yellow
    foreach ($nombreOmitido in $modulosOmitidos) { Write-Host "  - $nombreOmitido" -ForegroundColor Yellow }
    Write-Host (Get-AIOString 'startup.modules_duplicates_hint') -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

if ($script:ModulosFallidos.Count -gt 0) {
    Write-Host (Get-AIOString 'startup.modules_failed_warn' $script:ModulosFallidos.Count) -ForegroundColor Yellow
    foreach ($nombreModulo in $script:ModulosFallidos) { Write-Host "  - $nombreModulo" -ForegroundColor Yellow }
    Write-Host (Get-AIOString 'startup.modules_failed_hint') -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

# --- Cargar Configuracion Guardada ---
# Sobrescribe $Script:MOUNT_DIR y $Script:Scratch_DIR si el archivo config.json existe
Load-Config

# =================================================================
#  Modulos de Dialogo GUI
# =================================================================
# --- Funcion para ABRIR archivos o carpetas ---
function Select-PathDialog {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('Folder', 'File')]
        [string]$DialogType,

        [string]$Title,

        [string]$Filter = "Todos los archivos (*.*)|*.*"
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        if ($DialogType -eq 'Folder') {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = $Title
            if ($dialog.ShowDialog() -eq 'OK') {
                return $dialog.SelectedPath
            }
        } elseif ($DialogType -eq 'File') {
            $dialog = New-Object System.Windows.Forms.OpenFileDialog
            $dialog.Title = $Title
            $dialog.Filter = $Filter
            $dialog.CheckFileExists = $true
            $dialog.CheckPathExists = $true
            $dialog.Multiselect = $false # El script espera un solo archivo
            if ($dialog.ShowDialog() -eq 'OK') {
                return $dialog.FileName # Devolvemos un solo nombre de archivo
            }
        }
    } catch {
        Write-Host (Get-AIOString 'core.dialog_open_err' $_.Exception.Message)
        Write-Log -LogLevel ERROR -Message "Fallo al mostrar dialogo ABRIR: $($_.Exception.Message)"
    }

    return $null # Devuelve nulo si el usuario cancela
}

# --- Funcion para GUARDAR archivos ---
function Select-SavePathDialog {
    param(
        [string]$Title = "Guardar archivo como...",
        [string]$Filter = "Todos los archivos (*.*)|*.*",
        [string]$DefaultFileName = ""
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Title = $Title
        $dialog.Filter = $Filter
        $dialog.FileName = $DefaultFileName
        $dialog.CheckPathExists = $true
        $dialog.OverwritePrompt = $true # Advertir si el archivo ya existe

        if ($dialog.ShowDialog() -eq 'OK') {
            return $dialog.FileName
        }
    } catch {
        Write-Host (Get-AIOString 'core.dialog_save_err' $_.Exception.Message)
        Write-Log -LogLevel ERROR -Message "Fallo al mostrar dialogo GUARDAR: $($_.Exception.Message)"
    }

    return $null # Devuelve nulo si el usuario cancela
}

# =============================================
#  FUNCIONES DE MENU (Interfaz de Usuario)
# =============================================
# --- Lee una opcion de menu; presionar "V" regresa de inmediato (sin Enter) ---
function Read-MenuOption {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt
    )

    try {
        Write-Host -NoNewline "${Prompt}: "
        $buffer = ""

        while ($true) {
            $key = [Console]::ReadKey($true)

            # Atajo de "Volver": si V es la primera tecla presionada, regresa sin esperar Enter
            if ($buffer.Length -eq 0 -and ($key.KeyChar -eq 'v' -or $key.KeyChar -eq 'V')) {
                Write-Host "V"
                return "V"
            }

            switch ($key.Key) {
                'Enter' { Write-Host ""; return $buffer }
                'Backspace' {
                    if ($buffer.Length -gt 0) {
                        $buffer = $buffer.Substring(0, $buffer.Length - 1)
                        Write-Host -NoNewline "`b `b"
                    }
                }
                default {
                    if (-not [char]::IsControl($key.KeyChar)) {
                        $buffer += $key.KeyChar
                        Write-Host -NoNewline $key.KeyChar
                    }
                }
            }
        }
    } catch {
        # Fallback por si la consola no soporta ReadKey (ej. entrada redirigida)
        return Read-Host $Prompt
    }
}

# --- Menu de Configuracion de Rutas ---
function Show-ConfigMenu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'config.menu_title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'config.menu_subtitle')
        Write-Host ""
        Write-Host (Get-AIOString 'config.opt_mount_dir')
        Write-Host (Get-AIOString 'config.current_path') -NoNewline; Write-Host $Script:MOUNT_DIR -ForegroundColor Yellow
        Write-Host (Get-AIOString 'config.opt_mount_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'config.opt_scratch_dir')
        Write-Host (Get-AIOString 'config.current_path') -NoNewline; Write-Host $Script:Scratch_DIR -ForegroundColor Yellow
        Write-Host (Get-AIOString 'config.opt_scratch_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'config.opt_language')
        Write-Host (Get-AIOString 'config.current_language') -NoNewline; Write-Host (Get-AIOLanguageDisplaySummary) -ForegroundColor Cyan
        Write-Host (Get-AIOString 'config.opt_language_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""
        $opcionC = Read-MenuOption (Get-AIOString 'common.select_option')

        switch ($opcionC.ToUpper()) {
            "1" {
                Write-Host (Get-AIOString 'config.select_new_mount') -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title (Get-AIOString 'config.dialog_mount_title')
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:MOUNT_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: MOUNT_DIR cambiado a '$newPath'"
                    Save-Config
                } else {
                    Write-Warning (Get-AIOString 'common.operation_cancelled_no_changes')
                }
                Pause
            }
            "2" {
                Write-Host (Get-AIOString 'config.select_new_scratch') -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title (Get-AIOString 'config.dialog_scratch_title')
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:Scratch_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: Scratch_DIR cambiado a '$newPath'"
                    Save-Config
                } else {
                    Write-Warning (Get-AIOString 'common.operation_cancelled_no_changes')
                }
                Pause
            }
            "3" {
                if (Show-AIOLanguageSelector) {
                    Save-Config
                    $Script:AIODashboardCache = $null
                    $script:AIODashboardEditionCatalog = $null
                    $script:EditionCatalog = $null
                    $Script:ForceMenuRefresh = $true
                    Start-Sleep -Seconds 1
                }
            }
            "V" {
                return
            }
            default { Write-Warning (Get-AIOString 'common.invalid_option'); Start-Sleep 1 }
        }
    }
}

function Mount-Save-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.mount_save.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.mount_save.sec_mount') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.mount_save.opt1')
        Write-Host (Get-AIOString 'menu.mount_save.opt1_desc' $Script:MOUNT_DIR) -ForegroundColor Gray
        Write-Host ""
        if ($Script:IMAGE_MOUNTED -eq 1) {
            Write-Host (Get-AIOString 'menu.mount_save.opt2')
            Write-Host ""
        }
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host (Get-AIOString 'menu.mount_save.sec_save') -ForegroundColor Yellow
            Write-Host (Get-AIOString 'menu.mount_save.opt3' $Script:MOUNTED_INDEX)
            Write-Host (Get-AIOString 'menu.mount_save.opt3_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host (Get-AIOString 'menu.mount_save.opt4')
            Write-Host (Get-AIOString 'menu.mount_save.opt4_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host (Get-AIOString 'menu.mount_save.opt5') -ForegroundColor Green
            Write-Host (Get-AIOString 'menu.mount_save.opt5_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host (Get-AIOString 'menu.mount_save.sec_unmount') -ForegroundColor Yellow
            Write-Host (Get-AIOString 'menu.mount_save.opt6') -ForegroundColor Green
            Write-Host (Get-AIOString 'menu.mount_save.opt6_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host (Get-AIOString 'menu.mount_save.opt7')
            Write-Host (Get-AIOString 'menu.mount_save.opt7_desc') -ForegroundColor Gray
            Write-Host ""
        }
        Write-Host (Get-AIOString 'menu.mount_save.opt_clean') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.mount_save.opt_clean_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host (Get-AIOString 'common.back_previous') -ForegroundColor Red
        Write-Host ""
        $opcionMS = Read-MenuOption (Get-AIOString 'common.select_option')

        if ($opcionMS.ToUpper() -in @("3","4","5","6","7") -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Warning (Get-AIOString 'menu.mount_save.not_mounted_warn')
            Pause
            continue
        }

        switch ($opcionMS.ToUpper()) {
            "1" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Mount-Image' (Montar una nueva imagen en el directorio de trabajo)."
                Mount-Image
                if ($Script:IMAGE_MOUNTED -gt 0) {
                    Write-Log -LogLevel INFO -Message "MenuMountSave: Montaje exitoso detectado. Redirigiendo directamente al Main-Menu."
                    return
                }
            }
            "2" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Reload-Image' (Forzar recarga del estado de la imagen montada)."
                if (Reload-Image) {
                    Write-Log -LogLevel INFO -Message "MenuMountSave: Recarga exitosa detectada. Redirigiendo directamente al Main-Menu."
                    return
                }
            }
            "3" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Save-Changes' (Modo: Commit - Sobrescribir indice actual en la imagen base)."
                Save-Changes -Mode 'Commit'
            }
            "4" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Save-Changes' (Modo: Append - Guardar cambios como un indice WIM nuevo)."
                Save-Changes -Mode 'Append'
            }
            "5" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Save-Changes' (Modo: NewWim - Exportar montaje a un archivo WIM completamente independiente)."
                Save-Changes -Mode 'NewWim'
            }
            "6" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Unmount-Image -Commit' (Confirmar guardado y desmontar la imagen actual)."
                Unmount-Image -Commit
            }
            "7" {
                Write-Log -LogLevel INFO -Message "MenuMountSave: Accediendo a 'Unmount-Image' (Descartar todos los cambios y desmontar la imagen actual)."
                Unmount-Image
            }
            "L" {
                Repair-InvalidMounts
                Pause
            }
            "V" {
                return
            }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function Edit-Indexes-Menu {
     while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.edit_indexes.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.edit_indexes.opt1')
        Write-Host (Get-AIOString 'menu.edit_indexes.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.edit_indexes.opt2')
        Write-Host (Get-AIOString 'menu.edit_indexes.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.edit_indexes.opt3')
        Write-Host (Get-AIOString 'menu.edit_indexes.opt3_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host (Get-AIOString 'common.back_previous') -ForegroundColor Red
        Write-Host ""
        $opcionEI = Read-MenuOption (Get-AIOString 'common.select_option')
                
        switch ($opcionEI.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuEditIndex: Accediendo a 'Export-Index' (Exportar un indice hacia otra imagen)."
                Export-Index 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuEditIndex: Accediendo a 'Delete-Index' (Eliminar un indice de la imagen actual)."
                Delete-Index 
            }
            "3" {
                Write-Log -LogLevel INFO -Message "MenuEditIndex: Integrar y ordenar indices."
                Show-AIOIndexIntegrator
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1 
            }
        }
    }
}

function Convert-Image-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.convert.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.convert.sec_wim_esd') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.convert.opt1')
        Write-Host (Get-AIOString 'menu.convert.opt1_desc') -ForegroundColor Gray
        Write-Host (Get-AIOString 'menu.convert.opt2')
        Write-Host (Get-AIOString 'menu.convert.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.convert.sec_swm') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.convert.opt3')
        Write-Host (Get-AIOString 'menu.convert.opt3_desc') -ForegroundColor Gray
        Write-Host (Get-AIOString 'menu.convert.opt4')
        Write-Host (Get-AIOString 'menu.convert.opt4_desc') -ForegroundColor Gray
        Write-Host (Get-AIOString 'menu.convert.opt5')
        Write-Host (Get-AIOString 'menu.convert.opt5_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.convert.sec_vhd') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.convert.opt6')
        Write-Host (Get-AIOString 'menu.convert.opt6_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_previous') -ForegroundColor Red
        Write-Host ""
        $opcionCI = Read-MenuOption (Get-AIOString 'common.select_option')

        switch ($opcionCI.ToUpper()) {
            "1" {
                Write-Log -LogLevel INFO -Message "MenuConvert: Accediendo a 'Convert-WIMToESD' (WIM a ESD)."
                Convert-WIMToESD
            }
            "2" {
                Write-Log -LogLevel INFO -Message "MenuConvert: Accediendo a 'Convert-ImageFormat' (ESDToWIM)."
                Convert-ImageFormat -Mode ESDToWIM
            }
            "3" { Convert-ImageFormat -Mode ToSWM }
            "4" { Convert-ImageFormat -Mode ToWIM }
            "5" { Convert-ImageFormat -Mode ToESD }
            "6" {
                Write-Log -LogLevel INFO -Message "MenuConvert: Accediendo a 'Convert-VHD' (VHD/VHDX a WIM)."
                Convert-VHD
            }
            "V" { return }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function Image-Management-Menu {
     while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.image_mgmt.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.image_mgmt.opt1') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.image_mgmt.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.image_mgmt.opt2') -ForegroundColor Green
        Write-Host (Get-AIOString 'menu.image_mgmt.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.image_mgmt.opt3') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.image_mgmt.opt3_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""
        $opcionIM = Read-MenuOption (Get-AIOString 'common.select_option')

        switch ($opcionIM.ToUpper()) {
            "1" {
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Mount-Save-Menu' (Ciclo de vida de montaje/guardado)."
                # Invocacion directa: la salida de DISM debe llegar a la consola.
                Mount-Save-Menu
                if ($Script:IMAGE_MOUNTED -gt 0) { return }
            }
            "2" {
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Show-WimMetadata-GUI' (Edicion de Metadatos XML)."
                Show-WimMetadata-GUI
            }
            "3" {
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Edit-Indexes-Menu' (Gestion de Indices WIM/ESD)."
                Edit-Indexes-Menu
            }
            "V" {
                return
            }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function Cambio-Edicion-Menu {
    Clear-Host
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Warning (Get-AIOString 'common.mount_required_short')
        Pause
        return
    }

    # --- CARGAR CATÁLOGO DE EDICIONES ---
    $editionsFile = Join-Path $PSScriptRoot "Catalogos\Ediciones.ps1"
    if (-not (Test-Path $editionsFile)) { $editionsFile = Join-Path $PSScriptRoot "Modulo-Ediciones.ps1" }
    if (-not (Test-Path $editionsFile)) { $editionsFile = Join-Path $PSScriptRoot "Ediciones.ps1" }
    
    if (Test-Path $editionsFile) { 
        . $editionsFile 
    } else { 
        Write-Warning (Get-AIOString 'edition.catalog_missing_warn')
        Start-Sleep -Seconds 2
    }

    # Helper interno para traducir usando el catálogo y quitar la palabra "Windows " para ahorrar espacio en consola
    function Get-FriendlyEditionName($EditionID) {
        if (Get-Command Get-WindowsEditionMetadata -ErrorAction SilentlyContinue) {
            $meta = Get-WindowsEditionMetadata -QueryString $EditionID
            return ($meta.Name -replace "(?i)^Windows ", "")
        }
        return $EditionID
    }
    
    # --- BLOQUE DE SEGURIDAD PARA VHD ---
    if ($Script:IMAGE_MOUNTED -eq 2) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host (Get-AIOString 'edition.vhd_warn_title') -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host (Get-AIOString 'edition.vhd_warn_l1') -ForegroundColor White
        Write-Host (Get-AIOString 'edition.vhd_warn_l2') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'edition.vhd_risks_hdr') -ForegroundColor Red
        Write-Host (Get-AIOString 'edition.vhd_risk1')
        Write-Host (Get-AIOString 'edition.vhd_risk2')
        Write-Host (Get-AIOString 'edition.vhd_risk3')
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        
        $confirmVHD = Read-Host (Get-AIOString 'edition.vhd_confirm_prompt')
        if ($confirmVHD.ToUpper() -ne 'CONFIRMAR') {
            Write-Warning (Get-AIOString 'edition.vhd_cancelled_sec')
            Start-Sleep -Seconds 2
            return
        }
        Clear-Host
    }
    
    Write-Host (Get-AIOString 'edition.reading_info') -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION: Obteniendo info..."

    $WIN_PRODUCT_NAME = $null
    $WIN_CURRENT_BUILD = $null
    $WIN_VERSION_FRIENDLY = "Desconocida"
    $CURRENT_EDITION_DETECTED = "Desconocida"

    # Reutilizar los metadatos ya verificados por el Dashboard para evitar otro reg load + DISM /Get-CurrentEdition
    $dashMeta = if ($null -ne $Script:AIODashboardCache -and $null -ne $Script:AIODashboardCache.Data) {
        $Script:AIODashboardCache.Data
    } elseif (Get-Command Get-AIOCachedDashboardMetadata -ErrorAction SilentlyContinue) {
        Get-AIOCachedDashboardMetadata -MountState $Script:IMAGE_MOUNTED -MountPath $Script:MOUNT_DIR `
            -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX
    } else { $null }

    if ($null -ne $dashMeta) {
        if ($dashMeta.Edition -and -not (Test-AIODashboardValueUnavailable ([string]$dashMeta.Edition))) {
            $CURRENT_EDITION_DETECTED = [string]$dashMeta.Edition
        }
        if ($dashMeta.Name -match '^(Windows (?:11|10|8\.1|8|7|Server(?:\s+\d{4}(?:\s+R2)?)?))\b') {
            $WIN_VERSION_FRIENDLY = $matches[1]
        } elseif ($dashMeta.Name -and -not (Test-AIODashboardValueUnavailable ([string]$dashMeta.Name))) {
            $WIN_VERSION_FRIENDLY = [string]$dashMeta.Name
        }
    }

    if ($CURRENT_EDITION_DETECTED -eq "Desconocida") {
        try {
            $dismEdition = dism /Image:$Script:MOUNT_DIR /Get-CurrentEdition /English 2>$null
            $currentEditionLine = $dismEdition | Select-String -Pattern "(Current Edition|Edici.n actual)\s*:"
            if ($currentEditionLine) { $CURRENT_EDITION_DETECTED = ($currentEditionLine.Line -split ':', 2)[1].Trim() }
        } catch { Write-Warning (Get-AIOString 'edition.current_err') }
    }

    # Traducir nombre de la edición actual usando el catálogo
    $DISPLAY_EDITION = $CURRENT_EDITION_DETECTED
    if ($CURRENT_EDITION_DETECTED -ne "Desconocida") {
        $DISPLAY_EDITION = Get-FriendlyEditionName $CURRENT_EDITION_DETECTED
    }

    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'edition.menu_title') -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'edition.lbl_image' $Script:MOUNT_DIR) -ForegroundColor Gray
    Write-Host (Get-AIOString 'edition.lbl_os' $WIN_VERSION_FRIENDLY) -ForegroundColor Gray
    Write-Host (Get-AIOString 'edition.lbl_edition' $DISPLAY_EDITION) -ForegroundColor Gray
    Write-Host ""
    Write-Host (Get-AIOString 'edition.targets_hdr') -ForegroundColor Yellow
    Write-Host ""

    $targetEditions = @()
    try {
        $dismTargets = dism /Image:$Script:MOUNT_DIR /Get-TargetEditions /English 2>$null
        $dismTargets | Select-String "Target Edition :" | ForEach-Object {
            $line = ($_.Line -split ':', 2)[1].Trim()
            if ($line) { $targetEditions += $line }
        }
    } catch { 
        Write-Host ""
        Write-Warning (Get-AIOString 'edition.targets_err')
    }

    # Validacion: Si es null o tiene 0 elementos
    if ($null -eq $targetEditions -or $targetEditions.Count -eq 0) {
        Write-Host ""
        Write-Warning (Get-AIOString 'edition.no_targets')
        Write-Host (Get-AIOString 'edition.causes_hdr') -ForegroundColor Gray
        Write-Host (Get-AIOString 'edition.cause1') -ForegroundColor Gray
        Write-Host (Get-AIOString 'edition.cause2') -ForegroundColor Gray
        Write-Host (Get-AIOString 'edition.cause3') -ForegroundColor Gray
        Pause
        return
    }

    # Calculamos cuantas filas necesitamos para 2 columnas
    $totalItems = $targetEditions.Count
    $rowCount = [math]::Ceiling($totalItems / 2)

    # Iteramos por FILAS, no por items linealmente
    for ($row = 0; $row -lt $rowCount; $row++) {
        
        # --- COLUMNA IZQUIERDA ---
        $indexLeft = $row
        if ($indexLeft -lt $totalItems) {
            $editionRaw = $targetEditions[$indexLeft]
            $displayNum = $indexLeft + 1 # Mostramos base 1
            
            # Traducción usando el catálogo
            $editionName = Get-FriendlyEditionName $editionRaw

            # Formato: [1 ] Nombre... (Relleno a 60 caracteres)
            $leftText = "   [{0,-2}] {1}" -f $displayNum, $editionName
            Write-Host $leftText.PadRight(60) -NoNewline -ForegroundColor White
        }

        # --- COLUMNA DERECHA ---
        $indexRight = $row + $rowCount
        
        if ($indexRight -lt $totalItems) {
            $editionRaw = $targetEditions[$indexRight]
            $displayNum = $indexRight + 1
            
            # Traducción usando el catálogo
            $editionName = Get-FriendlyEditionName $editionRaw

            $rightText = "   [{0,-2}] {1}" -f $displayNum, $editionName
            Write-Host $rightText -ForegroundColor White
        } else {
            Write-Host ""
        }
    }

    Write-Host ""
    Write-Host "-------------------------------------------------------"
    Write-Host ""
    Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
    Write-Host ""
    $opcionEdicion = Read-MenuOption (Get-AIOString 'edition.select_prompt' $targetEditions.Count)

    if ($opcionEdicion.ToUpper() -eq "V") { return }

    $opcionIndex = 0
    if (-not [int]::TryParse($opcionEdicion, [ref]$opcionIndex) -or $opcionIndex -lt 1 -or $opcionIndex -gt $targetEditions.Count) {
        Write-Warning (Get-AIOString 'common.invalid_option')
        Pause
        return
    }

    $selectedEdition = $targetEditions[$opcionIndex - 1] 

    Write-Host (Get-AIOString 'edition.changing_to' $DISPLAY_EDITION $selectedEdition) -ForegroundColor Yellow
    Write-Host (Get-AIOString 'edition.wait_minutes') -ForegroundColor Gray
    Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION: Cambiando edicion de '$DISPLAY_EDITION' a '$selectedEdition'."

    dism /Image:$Script:MOUNT_DIR /Set-Edition:$selectedEdition
    if ($LASTEXITCODE -in @(0, 3010)) {
        if (-not [string]::Equals([string]$selectedEdition, [string]$CURRENT_EDITION_DETECTED, [StringComparison]::OrdinalIgnoreCase)) {
            $Script:ForceMenuRefresh = $true
        }
        Write-Host (Get-AIOString 'edition.done_ok') -ForegroundColor Green
    } else {
        Write-Host (Get-AIOString 'edition.failed' $LASTEXITCODE)
        Write-Log -LogLevel ERROR -Message "Fallo cambio edicion. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Drivers-Menu {
    while ($true) {
        Clear-Host
        if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning (Get-AIOString 'common.mount_required_short'); Pause; return }
        
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.drivers.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.drivers.opt1')
        Write-Host (Get-AIOString 'menu.drivers.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.drivers.opt2')
        Write-Host (Get-AIOString 'menu.drivers.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_short') -ForegroundColor Red
        
        $opcionD = Read-MenuOption ("`n" + (Get-AIOString 'common.select_option'))
        
        switch ($opcionD.ToUpper()) {
            "1" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuDrivers: Accediendo a 'Show-Drivers-GUI' (Inyeccion de Controladores)."
                    Show-Drivers-GUI 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuDrivers: Intento de acceso a inyeccion denegado. No hay ninguna imagen montada."
                    Write-Warning (Get-AIOString 'common.mount_required_first')
                    Pause 
                } 
            }
            "2" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuDrivers: Accediendo a 'Show-Uninstall-Drivers-GUI' (Eliminacion de Controladores)."
                    Show-Uninstall-Drivers-GUI 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuDrivers: Intento de acceso a eliminacion denegado. No hay ninguna imagen montada."
                    Write-Warning (Get-AIOString 'common.mount_required_first')
                    Pause 
                } 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1 
            }
        }
    }
}

function Content-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.content.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'common.status_label') -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host (Get-AIOString 'common.status_wim_mounted') -ForegroundColor Green }
            2 { Write-Host (Get-AIOString 'common.status_vhd_mounted') -ForegroundColor Cyan }
            Default { Write-Host (Get-AIOString 'common.status_not_mounted') -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host (Get-AIOString 'menu.content.opt1') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.content.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.content.opt2') -ForegroundColor Green
        Write-Host (Get-AIOString 'menu.content.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.content.opt3') -ForegroundColor Magenta
        Write-Host (Get-AIOString 'menu.content.opt3_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""

        $opcionCont = Read-MenuOption (Get-AIOString 'common.select_option')

        if ($opcionCont.ToUpper() -ne "V" -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Log -LogLevel WARN -Message "MenuContent: Acceso denegado a la opcion [$opcionCont]. No hay ninguna imagen montada."
            Write-Warning (Get-AIOString 'common.mount_required_tools')
            Pause
            continue
        }

        switch ($opcionCont.ToUpper()) {
            "1" { Write-Log -LogLevel INFO -Message "MenuContent: Accediendo a 'Show-Bloatware-GUI'"; Show-Bloatware-GUI }
            "2" { Write-Log -LogLevel INFO -Message "MenuContent: Accediendo a 'Show-AppxInjector-GUI'"; Show-AppxInjector-GUI }
            "3" { Write-Log -LogLevel INFO -Message "MenuContent: Accediendo a 'Show-Addons-GUI'"; Show-Addons-GUI }
            "V" { return }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function System-Tweaks-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.system_tweaks.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'common.status_label') -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host (Get-AIOString 'common.status_wim_mounted') -ForegroundColor Green }
            2 { Write-Host (Get-AIOString 'common.status_vhd_mounted') -ForegroundColor Cyan }
            Default { Write-Host (Get-AIOString 'common.status_not_mounted') -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host (Get-AIOString 'menu.system_tweaks.opt1') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.system_tweaks.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.system_tweaks.opt2') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.system_tweaks.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.system_tweaks.opt3') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.system_tweaks.opt3_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""

        $opcionSys = Read-MenuOption (Get-AIOString 'common.select_option')

        if ($opcionSys.ToUpper() -ne "V" -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Log -LogLevel WARN -Message "MenuSystemTweaks: Acceso denegado a la opcion [$opcionSys]. No hay ninguna imagen montada."
            Write-Warning (Get-AIOString 'common.mount_required_tools')
            Pause
            continue
        }

        switch ($opcionSys.ToUpper()) {
            "1" { Write-Log -LogLevel INFO -Message "MenuSystemTweaks: Accediendo a 'Show-Features-GUI'"; Show-Features-GUI }
            "2" { Write-Log -LogLevel INFO -Message "MenuSystemTweaks: Accediendo a 'Show-Services-Offline-GUI'"; Show-Services-Offline-GUI }
            "3" { Write-Log -LogLevel INFO -Message "MenuSystemTweaks: Accediendo a 'Show-Tweaks-Offline-GUI'"; Show-Tweaks-Offline-GUI }
            "V" { return }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function OOBE-Branding-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.oobe.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'common.status_label') -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host (Get-AIOString 'common.status_wim_mounted') -ForegroundColor Green }
            2 { Write-Host (Get-AIOString 'common.status_vhd_mounted') -ForegroundColor Cyan }
            Default { Write-Host (Get-AIOString 'common.status_not_mounted') -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host (Get-AIOString 'menu.oobe.opt1') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.oobe.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.oobe.opt2') -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.oobe.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""

        $opcionOOBE = Read-MenuOption (Get-AIOString 'common.select_option')

        if ($opcionOOBE.ToUpper() -ne "V" -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Log -LogLevel WARN -Message "MenuOOBEBranding: Acceso denegado a la opcion [$opcionOOBE]. No hay ninguna imagen montada."
            Write-Warning (Get-AIOString 'common.mount_required_tools')
            Pause
            continue
        }

        switch ($opcionOOBE.ToUpper()) {
            "1" { Write-Log -LogLevel INFO -Message "MenuOOBEBranding: Accediendo a 'Show-Unattend-GUI'"; Show-Unattend-GUI }
            "2" { Write-Log -LogLevel INFO -Message "MenuOOBEBranding: Accediendo a 'Show-OEMBranding-GUI'"; Show-OEMBranding-GUI }
            "V" { return }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

function Updates-Languages-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.updates_lang.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.updates_lang.opt1') -ForegroundColor Green
        Write-Host (Get-AIOString 'menu.updates_lang.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.updates_lang.opt2') -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.updates_lang.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""

        $opcionUL = (Read-MenuOption (Get-AIOString 'common.select_option')).Trim().ToUpper()
        switch ($opcionUL) {
            "1" { Write-Log -LogLevel INFO -Message "MenuUpdatesLang: Accediendo a 'WindowsUpdate-Menu'"; WindowsUpdate-Menu }
            "2" { Write-Log -LogLevel INFO -Message "MenuUpdatesLang: Accediendo a 'LanguagePack-Menu'"; LanguagePack-Menu }
            "V" { return }
            default {
                Write-Warning (Get-AIOString 'common.invalid_option')
                Start-Sleep 1
            }
        }
    }
}

# Clasificacion conservadora: un proceso terminado no equivale a un analisis valido.
function Get-AIOSfcAssessment {
    param(
        [AllowNull()][object]$ExitCode,
        [bool]$LogReadSucceeded,
        [int]$Batches,
        [int]$CompletedBatches,
        [int]$FailureCount,
        [int]$ChangeCount,
        [string]$ExecutionError = ''
    )
    $status = 'Indeterminate'; $success = $false; $level = 'WARN'; $color = 'Yellow'
    $message = Get-AIOString 'limpieza.sfc_unconfirmed'
    if ($ExecutionError) {
        $status = 'Failed'; $level = 'ERROR'; $color = 'Red'
        $message = Get-AIOString 'limpieza.sfc_exec_failed' $ExecutionError
    } elseif ($null -ne $ExitCode -and [int]$ExitCode -ne 0) {
        $status = 'Failed'; $level = 'ERROR'; $color = 'Red'
        $message = "SFC termino con codigo $ExitCode. Revisa la salida y el log detallado."
    } elseif ($null -ne $ExitCode -and $LogReadSucceeded -and $Batches -gt 0 -and $CompletedBatches -eq $Batches) {
        if ($FailureCount -gt 0) {
            $status = 'ReviewRequired'
            $message = Get-AIOString 'limpieza.sfc_repair_incidents'
        } elseif ($ChangeCount -gt 0) {
            $status = 'CompletedWithChanges'; $success = $true
            $message = Get-AIOString 'limpieza.sfc_repair_events'
        } else {
            $status = 'NoIssuesReported'; $success = $true; $level = 'INFO'; $color = 'Green'
            $message = 'Verificacion completa sin incidencias de integridad registradas.'
        }
    }
    [pscustomobject]@{ Status=$status; Success=$success; LogLevel=$level; Color=$color; Message=$message }
}

function Get-AIODismHealthState {
    param([string]$Text)
    # /English hace estables estos mensajes incluso en anfitriones en espanol.
    if ($Text -match '(?i)component store (?:cannot be repaired|is not repairable)') { return 'NonRepairable' }
    if ($Text -match '(?i)component store is repairable') { return 'Repairable' }
    if ($Text -match '(?i)no component store corruption detected') { return 'Healthy' }
    return 'Unknown'
}

function Invoke-AIOImageHealthCheck {
    param(
        [Parameter(Mandatory=$true)][string]$MountDir,
        [Parameter(Mandatory=$true)][ValidateSet('CheckHealth','ScanHealth')][string]$Mode
    )
    $healthLogDir = if ($script:logDir -and (Test-Path -LiteralPath $script:logDir -PathType Container)) {
        $script:logDir
    } else { [IO.Path]::GetTempPath() }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $healthLog = Join-Path $healthLogDir "DISM_${Mode}_${stamp}.log"
    $consoleLog = Join-Path $healthLogDir "DISM_${Mode}_${stamp}_salida.log"
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $progressLine = @{ Active = $false; Width = 0 }
    $exitCode = $null; $healthState = 'Unknown'; $runError = ''
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /$Mode; Imagen='$MountDir'; Log='$healthLog'."
    try {
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'SystemRoot no disponible.' }
        $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
        $exe = Join-Path $env:SystemRoot "$systemFolder\dism.exe"
        $argsDism = @("/Image:$MountDir", '/Cleanup-Image', "/$Mode", '/English', "/LogPath:$healthLog")
        # Recoger stdout/stderr y el codigo inmediatamente; no heredar LASTEXITCODE de otra operacion.
        $global:LASTEXITCODE = $null
        $PSNativeCommandUseErrorActionPreference = $false
        & $exe @argsDism 2>&1 | ForEach-Object {
            $lineText = [string]$_
            [void]$lines.Add($lineText)
            # DISM usa retornos de carro para actualizar su barra. Al capturar
            # la salida, PowerShell entrega esas actualizaciones por separado.
            foreach ($displayLine in ($lineText -split "`r`n|`r|`n")) {
                if ($displayLine -match '^\s*\[[^\]\r\n]*\d+(?:[.,]\d+)?%[^\]\r\n]*\]\s*$') {
                    $bar = $displayLine.Trim()
                    $availableWidth = 79
                    try {
                        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
                        if ($consoleWidth -gt 1) { $availableWidth = $consoleWidth - 1 }
                    } catch {}
                    # No ocupar la ultima columna: evitar el salto automatico.
                    if ($bar.Length -gt $availableWidth) { $bar = $bar.Substring(0, $availableWidth) }
                    $renderWidth = [Math]::Min($availableWidth, [Math]::Max($progressLine.Width, $bar.Length))
                    Write-Host ("`r" + $bar.PadRight($renderWidth)) -NoNewline
                    $progressLine.Active = $true
                    $progressLine.Width = $renderWidth
                } else {
                    # Separar el diagnostico de la ultima actualizacion de la barra.
                    if ($progressLine.Active) {
                        if ([string]::IsNullOrWhiteSpace($displayLine)) { continue }
                        Write-Host ''
                        $progressLine.Active = $false
                        $progressLine.Width = 0
                    }
                    Write-Host $displayLine
                }
            }
        }
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) { throw 'DISM no proporciono codigo de salida.' }
        if ($exitCode -in @(0, 3010)) { $healthState = Get-AIODismHealthState -Text ($lines -join "`n") }
    } catch {
        $runError = $_.Exception.Message
        Write-Log -LogLevel ERROR -Message "LIMPIEZA: DISM /$Mode fallo: $runError"
    } finally {
        if ($progressLine.Active) { Write-Host '' }
        $sw.Stop()
    }
    try { [IO.File]::WriteAllLines($consoleLog, $lines.ToArray(), [Text.Encoding]::UTF8) }
    catch { Write-Log -LogLevel WARN -Message "No se pudo guardar la salida de DISM: $($_.Exception.Message)" }
    $success = (-not $runError -and $null -ne $exitCode -and $exitCode -in @(0, 3010) -and $healthState -ne 'Unknown')
    $exitText = if ($null -eq $exitCode) { 'No disponible' } else { [string]$exitCode }
    $level = if (-not $success) { 'ERROR' } elseif ($healthState -eq 'Healthy') { 'INFO' } else { 'WARN' }
    Write-Log -LogLevel $level -Message "LIMPIEZA: DISM /$Mode terminado (ExitCode=$exitText, Estado=$healthState, Tiempo=$($sw.Elapsed.ToString()), Log='$healthLog', Salida='$consoleLog')."
    Write-Host (Get-AIOString 'limpieza.health_summary' $healthState $exitText $healthLog)
    [pscustomobject]@{ Success=$success; ExitCode=$exitCode; ImageHealthState=$healthState; LogPath=$healthLog; ConsoleLogPath=$consoleLog }
}

function Invoke-AIOComponentStoreAnalysis {
    param([Parameter(Mandatory=$true)][string]$MountDir)

    $analysisLogDir = if ($script:logDir -and (Test-Path -LiteralPath $script:logDir -PathType Container)) {
        $script:logDir
    } else { [IO.Path]::GetTempPath() }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $analysisLog = Join-Path $analysisLogDir "DISM_AnalyzeComponentStore_${stamp}.log"
    $consoleLog = Join-Path $analysisLogDir "DISM_AnalyzeComponentStore_${stamp}_salida.log"
    $lines = New-Object 'System.Collections.Generic.List[string]'
    $progressLine = @{ Active = $false; Width = 0 }
    $exitCode = $null; $cleanupRecommended = 'Unknown'; $runError = ''
    try {
        if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'SystemRoot no disponible.' }
        $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
        $exe = Join-Path $env:SystemRoot "$systemFolder\dism.exe"
        $argsDism = @("/Image:$MountDir", '/Cleanup-Image', '/AnalyzeComponentStore', '/English', "/LogPath:$analysisLog")
        # Capturar stderr tambien en Windows PowerShell 5.1; el codigo decide el resultado.
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        $global:LASTEXITCODE = $null
        & $exe @argsDism 2>&1 | ForEach-Object {
            $lineText = [string]$_
            [void]$lines.Add($lineText)
            # Conservar todas las actualizaciones en el log, pero dibujar la barra
            # en una sola linea, igual que en Invoke-AIOImageHealthCheck.
            foreach ($displayLine in ($lineText -split "`r`n|`r|`n")) {
                if ($displayLine -match '^\s*\[[^\]\r\n]*\d+(?:[.,]\d+)?%[^\]\r\n]*\]\s*$') {
                    $bar = $displayLine.Trim()
                    $availableWidth = 79
                    try {
                        $consoleWidth = $Host.UI.RawUI.WindowSize.Width
                        if ($consoleWidth -gt 1) { $availableWidth = $consoleWidth - 1 }
                    } catch {}
                    # Evitar el salto automatico y borrar restos de barras mas largas.
                    if ($bar.Length -gt $availableWidth) { $bar = $bar.Substring(0, $availableWidth) }
                    $renderWidth = [Math]::Min($availableWidth, [Math]::Max($progressLine.Width, $bar.Length))
                    Write-Host ("`r" + $bar.PadRight($renderWidth)) -NoNewline
                    $progressLine.Active = $true
                    $progressLine.Width = $renderWidth
                } else {
                    if ($progressLine.Active) {
                        if ([string]::IsNullOrWhiteSpace($displayLine)) { continue }
                        Write-Host ''
                        $progressLine.Active = $false
                        $progressLine.Width = 0
                    }
                    Write-Host $displayLine
                }
            }
        }
        $exitCode = $global:LASTEXITCODE
        if ($null -eq $exitCode) { throw 'DISM no proporciono codigo de salida.' }
        if ($exitCode -notin @(0, 3010)) { throw "DISM /AnalyzeComponentStore termino con codigo $exitCode." }

        # Un resultado ausente, ambiguo o no reconocido nunca equivale a "No".
        $recommendations = [regex]::Matches(($lines -join "`n"), '(?im)^[ \t]*Component Store Cleanup Recommended\b([^\r\n]*)')
        if ($recommendations.Count -ne 1 -or $recommendations[0].Groups[1].Value -notmatch '^[ \t]*:[ \t]*(Yes|No)[ \t]*$') {
            throw 'No se pudo interpretar una recomendacion unica de limpieza (Yes/No).'
        }
        $cleanupRecommended = $Matches[1]
    } catch {
        $runError = $_.Exception.Message
    } finally {
        if ($progressLine.Active) { Write-Host '' }
    }
    try { [IO.File]::WriteAllLines($consoleLog, $lines.ToArray(), [Text.Encoding]::UTF8) }
    catch { Write-Log -LogLevel WARN -Message "No se pudo guardar la salida del analisis DISM: $($_.Exception.Message)" }
    $success = (-not $runError -and $null -ne $exitCode -and $exitCode -in @(0, 3010) -and $cleanupRecommended -in @('Yes', 'No'))
    $exitText = if ($null -eq $exitCode) { 'No disponible' } else { [string]$exitCode }
    $level = if ($success) { 'INFO' } else { 'ERROR' }
    Write-Log -LogLevel $level -Message "LIMPIEZA: AnalyzeComponentStore (ExitCode=$exitText, Recomendacion=$cleanupRecommended, Error='$runError', Log='$analysisLog', Salida='$consoleLog')."
    Write-Host (Get-AIOString 'limpieza.comp_summary' $cleanupRecommended $exitText $analysisLog)
    if (-not $success) {
        Write-Warning (Get-AIOString 'limpieza.comp_unconfirmed' $runError $consoleLog)
    }
    [pscustomobject]@{ Success=$success; ExitCode=$exitCode; CleanupRecommended=$cleanupRecommended; LogPath=$analysisLog; ConsoleLogPath=$consoleLog }
}

function Limpieza-Menu {
 
	# --- Funcion auxiliar interna para el fallback de RestoreHealth ---
    function Invoke-RestoreHealthWithFallback {
        param(
            [string]$MountDir,
            [switch]$IsSequence
        )

        Write-Host (Get-AIOString 'limpieza.restore_start') -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "LIMPIEZA: Ejecutando DISM /RestoreHealth..."

        $exitCode = $null
        try {
            $restoreResult = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments @("/Image:$MountDir", '/Cleanup-Image', '/RestoreHealth')
            $exitCode = $restoreResult.ExitCode
        } catch {
            Write-Warning (Get-AIOString 'limpieza.restore_run_err' $_.Exception.Message)
            Write-Log -LogLevel ERROR -Message "LIMPIEZA: Error ejecutando RestoreHealth: $($_.Exception.Message)"
        }

        if ($exitCode -notin @(0, 3010)) {
            Write-Host (Get-AIOString 'limpieza.restore_failed_code' $exitCode) -ForegroundColor Red
            Write-Host (Get-AIOString 'limpieza.restore_offline_hint') -ForegroundColor Gray
            Write-Log -LogLevel WARN -Message "LIMPIEZA: RestoreHealth inicial devolvio $exitCode. Iniciando protocolo de Fallback."

            $useSourceChoice = Read-Host (Get-AIOString 'limpieza.restore_use_wim_prompt')

            if (Test-AIOYesResponse $useSourceChoice) {
                Write-Log -LogLevel INFO -Message "LIMPIEZA: Usuario eligio usar fuente WIM para RestoreHealth."
                $sourceWimPath = Select-PathDialog -DialogType File -Title (Get-AIOString 'limpieza.restore_dialog_title') -Filter (Get-AIOString 'save.wim_filter')

                if ($sourceWimPath) {
                    Write-Host (Get-AIOString 'limpieza.restore_analyzing_wim') -ForegroundColor Yellow
                    try {
                        $sourceInfo = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments @('/Get-WimInfo', "/WimFile:$sourceWimPath")
                        if ($null -eq $sourceInfo.ExitCode -or $sourceInfo.ExitCode -notin @(0, 3010)) {
                            throw "No se pudieron consultar los indices del WIM (Codigo: $($sourceInfo.ExitCode))."
                        }

                        [int]$sourceIndex = 0
                        $inputIndex = Read-Host (Get-AIOString 'limpieza.restore_index_prompt')

                        if ([int]::TryParse($inputIndex, [ref]$sourceIndex) -and $sourceIndex -gt 0) {
                            Write-Host (Get-AIOString 'limpieza.restore_retrying_local') -ForegroundColor Yellow
                            Write-Log -LogLevel ACTION -Message "LIMPIEZA: Reintentando RestoreHealth con /LimitAccess y Source WIM."

                            $ext = [System.IO.Path]::GetExtension($sourceWimPath).ToUpper()
                            $sourceType = if ($ext -eq ".ESD") { "ESD" } else { "WIM" }

                            $dismArgs = @("/Image:$MountDir", '/Cleanup-Image', '/RestoreHealth', "/Source:${sourceType}:${sourceWimPath}:$sourceIndex", '/LimitAccess')
                            $exitCode = $null
                            $restoreResult = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments $dismArgs
                            $exitCode = $restoreResult.ExitCode

                            if ($exitCode -in @(0, 3010)) {
                                Write-Host (Get-AIOString 'limpieza.restore_wim_ok') -ForegroundColor Green
                                Write-Log -LogLevel INFO -Message "LIMPIEZA: RestoreHealth exitoso con fuente WIM."
                            } else {
                                Write-Host (Get-AIOString 'limpieza.restore_wim_err' $exitCode) -ForegroundColor Red
                                Write-Log -LogLevel ERROR -Message "LIMPIEZA: RestoreHealth fallo con fuente WIM (Codigo: $exitCode)."
                            }
                        } else {
                            Write-Warning (Get-AIOString 'limpieza.restore_invalid_idx')
                        }
                    } catch {
                        $exitCode = $null
                        Write-Warning (Get-AIOString 'limpieza.restore_wim_exc' $_.Exception.Message)
                        Write-Log -LogLevel ERROR -Message "LIMPIEZA: Error en fallback RestoreHealth: $($_.Exception.Message)"
                    }
                } else {
                    Write-Warning (Get-AIOString 'limpieza.restore_no_wim')
                }
            }
        } else {
            Write-Host (Get-AIOString 'limpieza.restore_ok') -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "LIMPIEZA: DISM /RestoreHealth exitoso."
        }

        if ($exitCode -in @(0, 3010)) {
            if (Get-Command Request-AIODashboardRefreshIfDegraded -ErrorAction SilentlyContinue) {
                Request-AIODashboardRefreshIfDegraded
            }
        }
        if (-not $IsSequence) { Pause }
        # Devolver solo el resultado: la salida nativa se muestra en la consola.
        [pscustomobject]@{ Success=($null -ne $exitCode -and $exitCode -in @(0, 3010)); ExitCode=$exitCode }
    }

    function Invoke-AIOOfflineSfcScan {
        param(
            [Parameter(Mandatory = $true)][string]$MountDir
        )
        $sfcBoot = $MountDir
        if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
        $sfcWin = Join-Path -Path $MountDir -ChildPath "Windows"

        if (-not (Test-Path -LiteralPath $sfcWin -PathType Container)) {
            Write-Host (Get-AIOString 'limpieza.sfc_no_win_dir' $sfcWin) -ForegroundColor Red
            Write-Log -LogLevel ERROR -Message "LIMPIEZA: No se encontro la carpeta Windows en '$sfcWin' para ejecutar SFC."
            return $false
        }

        # ---------------- Ayudantes visuales ----------------
        $lineWidth = 119
        try { $w = $Host.UI.RawUI.WindowSize.Width; if ($w -gt 20) { $lineWidth = $w - 1 } } catch {}
        $wrapWidth = [Math]::Min($lineWidth, 110)
        $spinState = @{ Row = -1 }   # fila de consola donde se dibujo el ultimo indicador de actividad

        # Quita el formato interno de CSI: [l:14]'texto' -> 'texto'
        function ConvertTo-SfcCleanText {
            param([string]$Text)
            if ([string]::IsNullOrEmpty($Text)) { return "" }
            $t = [regex]::Replace($Text, '\[l:\d+(?:\s+ml:\d+)?\]\x27', "'")
            $t = $t -replace '\s+', ' '
            return $t.Trim()
        }

        # Traduce y compacta los mensajes [SR] mas comunes; si no reconoce el formato devuelve el texto limpio
        function Format-SfcSrText {
            param([string]$Text)
            $t = ConvertTo-SfcCleanText -Text $Text

            if ($t -match '^Cannot repair member file \x27(?<f>[^\x27]+)\x27 of (?<c>[^,]+), version (?<v>[^,]+), arch (?<a>[^,]+),.*hash mismatch') {
                return @("No se pudo reparar '$($Matches['f'])' (hash distinto en el almacen)", "Componente: $($Matches['c']) v$($Matches['v']) ($($Matches['a']))")
            }
            if ($t -match '^This component was referenced by \x27(?<p>[^\x27]+)\x27') {
                $pkgRaw  = $Matches['p']
                $parts   = $pkgRaw -split '~'
                $pkgName = $parts[0]
                $pkgVer  = ""
                if ($parts.Count -ge 5 -and $parts[4] -match '^\d+\.\d+\.\d+\.\d+') { $pkgVer = " v$($Matches[0])" }
                return @("Componente referenciado por el paquete:", "$pkgName$pkgVer")
            }
            if ($t -match '^Could not reproject corrupted file (?<p>.+?); source file in store is also corrupted') {
                $pathShow = ($Matches['p'] -replace '^\\\?\?\\', '') -replace '\\{2,}', '\'
                return @("No se pudo restaurar el archivo corrupto:", $pathShow, "El origen en el almacen tambien esta corrupto")
            }
            return @($t)
        }

        # Imprime uno o varios segmentos con ajuste de linea por palabras y sangria (cada segmento inicia en linea nueva)
        function Write-SfcWrapped {
            param(
                [string[]]$Text,
                [string]$FirstPrefix = "     * ",
                [string]$NextPrefix  = "       ",
                [string]$Color = "Gray"
            )
            $avail = $wrapWidth - $FirstPrefix.Length
            if ($avail -lt 20) { $avail = 20 }
            $isFirst = $true
            foreach ($segment in $Text) {
                $wrapped = New-Object System.Collections.Generic.List[string]
                $cur = ""
                foreach ($word in ($segment -split ' ')) {
                    while ($word.Length -gt $avail) {
                        if ($cur.Length -gt 0) { $wrapped.Add($cur); $cur = "" }
                        $wrapped.Add($word.Substring(0, $avail))
                        $word = $word.Substring($avail)
                    }
                    if ($cur.Length -eq 0) { $cur = $word }
                    elseif (($cur.Length + 1 + $word.Length) -le $avail) { $cur += " " + $word }
                    else { $wrapped.Add($cur); $cur = $word }
                }
                if ($cur.Length -gt 0) { $wrapped.Add($cur) }
                foreach ($wl in $wrapped) {
                    $pfx = if ($isFirst) { $FirstPrefix } else { $NextPrefix }
                    Write-Host ($pfx + $wl) -ForegroundColor $Color
                    $isFirst = $false
                }
            }
        }

        # Borra la linea del indicador de actividad (sin dejar restos) antes de imprimir un evento
        function Clear-SfcLiveLine {
            Write-Host ("`r" + (" " * $lineWidth) + "`r") -NoNewline
        }

        # Si sfc.exe imprimio texto despues del indicador, la linea del indicador quedo huerfana: se blanquea en su fila
        # (solo si la fila sigue siendo valida, es decir, la consola no ha desplazado el contenido)
        function Clear-SfcStaleSpinner {
            if ($spinState.Row -lt 0) { return }
            try {
                $raw = $Host.UI.RawUI
                $cur = $raw.CursorPosition
                if ($spinState.Row -lt $cur.Y -and $cur.Y -lt ($raw.BufferSize.Height - 1)) {
                    $pos = $cur
                    $pos.X = 0
                    $pos.Y = $spinState.Row
                    $raw.CursorPosition = $pos
                    Write-Host (" " * $lineWidth) -NoNewline
                    $raw.CursorPosition = $cur
                }
            } catch {}
            $spinState.Row = -1
        }

        function Write-SfcLiveEvent {
            param([string]$Tag, [string[]]$Text, [string]$Color = "Cyan")
            Clear-SfcLiveLine
            $pfx = "   [$Tag] "
            Write-SfcWrapped -Text $Text -FirstPrefix $pfx -NextPrefix (" " * $pfx.Length) -Color $Color
        }
        # ----------------------------------------------------

        $sfcLogDir = if ($script:logDir -and (Test-Path -LiteralPath $script:logDir -PathType Container)) {
            $script:logDir
        } else {
            [System.IO.Path]::GetTempPath()
        }
        $sfcStamp = (Get-Date -Format 'yyyyMMdd_HHmmss_fff') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sfcLogPath = Join-Path -Path $sfcLogDir -ChildPath "SFC_Offline_${sfcStamp}.log"

        # Si la ruta contiene espacios y termina en '\', duplicar la barra final para que '\"' no escape la comilla en el parser C de sfc.exe
        $bootArg = if ($sfcBoot -match '\s') { "/offbootdir=`"$($sfcBoot.TrimEnd('\'))\\`"" } else { "/offbootdir=$sfcBoot" }
        $winArg  = if ($sfcWin -match '\s')  { "/offwindir=`"$sfcWin`"" }  else { "/offwindir=$sfcWin" }
        $logArg  = if ($sfcLogPath -match '\s') { "/offlogfile=`"$sfcLogPath`"" } else { "/offlogfile=$sfcLogPath" }
        $sfcCmdArgs = "/scannow $bootArg $winArg $logArg"

        Write-Host (Get-AIOString 'limpieza.sfc_start') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'limpieza.sfc_log_lbl' $sfcLogPath) -ForegroundColor DarkGray
        Write-Log -LogLevel ACTION -Message "LIMPIEZA: Iniciando SFC Offline -> sfc.exe $sfcCmdArgs"

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $lastOffset = 0L
        $carryOver = ""
        $liveBatches = 0
        $liveComponents = 0
        $spinnerChars = @('|', '/', '-', '\')
        $spinIdx = 0
        $liveSeen = New-Object System.Collections.Generic.HashSet[string]

        $sfcProc = $null
        $sfcStarted = $false
        $sfcExit = $null
        $sfcExecutionError = ''
        try {
            # Process.Start conserva el handle del hijo hasta leer ExitCode.
            # Evita depender del objeto devuelto por Start-Process sin -Wait.
            $sfcProc = New-Object System.Diagnostics.Process
            $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
            $sfcProc.StartInfo.FileName = Join-Path $env:SystemRoot "$systemFolder\sfc.exe"
            $sfcProc.StartInfo.Arguments = $sfcCmdArgs
            $sfcProc.StartInfo.UseShellExecute = $false
            $sfcProc.StartInfo.CreateNoWindow = $false
            $sfcStarted = $sfcProc.Start()
            if (-not $sfcStarted) { throw 'No se pudo iniciar sfc.exe.' }

            # Esperar a que sfc.exe imprima su encabezado y cree el log antes de dibujar el indicador (evita lineas de actividad huerfanas)
            $startWait = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $sfcProc.HasExited -and $startWait.ElapsedMilliseconds -lt 8000) {
                $logItem = Get-Item -LiteralPath $sfcLogPath -ErrorAction SilentlyContinue
                if ($logItem -and $logItem.Length -gt 0) { break }
                [void]$sfcProc.WaitForExit(200)
            }
            [void]$sfcProc.WaitForExit(700)

            while (-not $sfcProc.WaitForExit(500)) {
                Clear-SfcStaleSpinner
                if (Test-Path -LiteralPath $sfcLogPath -PathType Leaf) {
                    try {
                        $fs = New-Object System.IO.FileStream(
                            $sfcLogPath,
                            [System.IO.FileMode]::Open,
                            [System.IO.FileAccess]::Read,
                            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
                        )
                        try {
                            if ($fs.Length -gt $lastOffset) {
                                [void]$fs.Seek($lastOffset, [System.IO.SeekOrigin]::Begin)
                                $toRead = [int][Math]::Min(($fs.Length - $lastOffset), 1MB)
                                $buf = New-Object byte[] $toRead
                                $readBytes = $fs.Read($buf, 0, $toRead)
                                if ($readBytes -gt 0) {
                                    $lastOffset += $readBytes
                                    $chunk = [System.Text.Encoding]::UTF8.GetString($buf, 0, $readBytes)
                                    $combined = $carryOver + $chunk
                                    $newLines = $combined -split "`r?`n"
                                    if (-not $combined.EndsWith("`n")) {
                                        $carryOver = $newLines[-1]
                                        $newLines = if ($newLines.Count -gt 1) { $newLines[0..($newLines.Count - 2)] } else { @() }
                                    } else {
                                        $carryOver = ""
                                    }
                                    foreach ($nl in $newLines) {
                                        if ($nl -match '\[SR\]\s+Verifying\s+(\d+)\b') {
                                            $liveBatches++
                                            $liveComponents += [int]$Matches[1]
                                        }
                                        elseif ($nl -match '\[SR\]\s+(Repairing corrupted file|Cannot repair member file|Repaired file)\b(.*)$') {
                                            $liveEvt = @(Format-SfcSrText -Text ($Matches[1] + $Matches[2]))
                                            # SFC repite el mismo evento varias veces: mostrar cada uno una sola vez
                                            if ($liveSeen.Add("SR|" + ($liveEvt -join ' '))) {
                                                $liveCol = if ($liveEvt[0] -match '^No se pudo') { 'Red' } else { 'Cyan' }
                                                Write-SfcLiveEvent -Tag "SFC-SR" -Text $liveEvt -Color $liveCol
                                            }
                                        }
                                        elseif ($nl -match 'Hashes for file member\s+(.*)\s+do not match') {
                                            $liveHash = (ConvertTo-SfcCleanText -Text $Matches[1]).Trim("'")
                                            if ($liveSeen.Add("HASH|$liveHash")) {
                                                Write-SfcLiveEvent -Tag "SFC-HASH" -Text "Hash distinto detectado: $liveHash" -Color "Yellow"
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        finally {
                            $fs.Dispose()
                        }
                    }
                    catch {}
                }

                $spin = $spinnerChars[$spinIdx % $spinnerChars.Count]
                $spinIdx++
                $elapsedStr = $sw.Elapsed.ToString("mm\:ss")
                if ($liveComponents -gt 0) {
                    $progressTxt = if ($liveBatches -eq $liveComponents) { Get-AIOString 'limpieza.sfc_comp_verified' $liveComponents } else { Get-AIOString 'limpieza.sfc_batch_verified' $liveBatches $liveComponents }
                    $statusMsg = Get-AIOString 'limpieza.sfc_live_progress' $spin $progressTxt $elapsedStr
                } else {
                    $statusMsg = Get-AIOString 'limpieza.sfc_live_analyzing' $spin $elapsedStr
                }
                $padWidth = [Math]::Min(100, $lineWidth)
                if ($statusMsg.Length -gt $padWidth) { $statusMsg = $statusMsg.Substring(0, $padWidth) }
                Write-Host ("`r" + $statusMsg.PadRight($padWidth)) -NoNewline -ForegroundColor Cyan
                try { $spinState.Row = $Host.UI.RawUI.CursorPosition.Y } catch { $spinState.Row = -1 }
            }

            # Limpiar el indicador y dejar una unica linea final estatica
            Clear-SfcStaleSpinner
            Clear-SfcLiveLine
            $sw.Stop()
            Write-Host (Get-AIOString 'limpieza.sfc_finished' ($sw.Elapsed.ToString('mm\:ss'))) -ForegroundColor Cyan
            $sfcProc.WaitForExit()
            $sfcExit = $sfcProc.ExitCode
            if ($null -eq $sfcExit) { throw 'SFC no proporciono codigo de salida.' }
        }
        catch {
            $sfcExecutionError = $_.Exception.Message
            Write-Log -LogLevel ERROR -Message "LIMPIEZA: Error de ejecucion/supervision SFC: $sfcExecutionError"
            # Un fallo visual o de supervision no debe iniciar un segundo SFC.
            if ($sfcStarted) {
                try { $sfcProc.WaitForExit(); $sfcExit = $sfcProc.ExitCode } catch {}
            }
        }
        finally {
            $sw.Stop()
            if ($null -ne $sfcProc) { $sfcProc.Dispose() }
        }

        # Analisis completo post-ejecucion sobre el archivo /offlogfile ya cerrado por sfc.exe
        $totalBatches = 0
        $totalComponents = 0
        $repairQueueCount = $null
        $completedBatches = 0
        $sfcLogReadSucceeded = $false
        $wcpVersion = ""
        $srRepairEntries = New-Object System.Collections.Generic.List[string]
        $hashMismatchEntries = New-Object System.Collections.Generic.List[string]
        $overlapEntries = New-Object System.Collections.Generic.List[string]
        $allSrLines = New-Object System.Collections.Generic.List[string]

        if (Test-Path -LiteralPath $sfcLogPath -PathType Leaf) {
            try {
                foreach ($line in [System.IO.File]::ReadLines($sfcLogPath)) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }

                    if (-not $wcpVersion -and $line -match 'WcpInitialize:\s+wcp\.dll\s+version\s+([^\s]+)') {
                        $wcpVersion = $Matches[1]
                    }

                    if ($line -match '\[SR\]\s*(.*)$') {
                        $srBody = $Matches[1].Trim()
                        [void]$allSrLines.Add($srBody)

                        if ($srBody -match '^Verifying\s+(\d+)\b') {
                            $totalBatches++
                            $totalComponents += [int]$Matches[1]
                        }
                        elseif ($srBody -eq 'Verify complete') {
                            $completedBatches++
                        }
                        elseif ($srBody -match '^Repairing\s+(\d+)\s+components') {
                            $repairQueueCount = [int]$Matches[1]
                        }
                        elseif ($srBody -notmatch '^(Verifying\s+\d+|Beginning Verify and Repair transaction|Verify complete|Repair complete)\b') {
                            if (-not $srRepairEntries.Contains($srBody)) {
                                [void]$srRepairEntries.Add($srBody)
                            }
                        }
                    }

                    if ($line -match 'Hashes for file member\s+(.*?)\s+do not match') {
                        $hm = $Matches[1].Trim()
                        if (-not $hashMismatchEntries.Contains($hm)) {
                            [void]$hashMismatchEntries.Add($hm)
                        }
                    }
                    elseif ($line -match 'Warning:\s+Overlap:\s+(.*)$') {
                        $ov = $Matches[1].Trim()
                        if (-not $overlapEntries.Contains($ov)) {
                            [void]$overlapEntries.Add($ov)
                        }
                    }
                }
                $sfcLogReadSucceeded = $true
            }
            catch {
                Write-Log -LogLevel WARN -Message "LIMPIEZA: Error al analizar '$sfcLogPath': $($_.Exception.Message)"
                $sfcLogReadSucceeded = $false
            }
        }

        $failureCount = @($srRepairEntries | Where-Object { $_ -match 'Cannot repair|Could not reproject|also corrupted|Repair failed' }).Count
        $changeCount = $srRepairEntries.Count + $hashMismatchEntries.Count + $overlapEntries.Count
        if ($null -ne $repairQueueCount -and $repairQueueCount -gt 0) { $changeCount += $repairQueueCount }
        $sfcAssessment = Get-AIOSfcAssessment -ExitCode $sfcExit -LogReadSucceeded $sfcLogReadSucceeded `
            -Batches $totalBatches -CompletedBatches $completedBatches -FailureCount $failureCount `
            -ChangeCount $changeCount -ExecutionError $sfcExecutionError
        $repairQueueText = if ($null -eq $repairQueueCount) { 'No reportada' } else { [string]$repairQueueCount }
        $sfcExitText = if ($null -eq $sfcExit) { 'No disponible' } else { [string]$sfcExit }

        $totalElapsed = $sw.Elapsed.ToString("mm\:ss")
        Write-Host "`n   =======================================================" -ForegroundColor DarkCyan
        Write-Host (Get-AIOString 'limpieza.sfc_report_title') -ForegroundColor Cyan
        Write-Host "   =======================================================" -ForegroundColor DarkCyan
        if ($wcpVersion) {
            Write-Host (Get-AIOString 'limpieza.sfc_wcp' $wcpVersion) -ForegroundColor Gray
        }
        Write-Host (Get-AIOString 'limpieza.sfc_elapsed' $totalElapsed) -ForegroundColor Gray
        $batchTxt = if ($totalBatches -ne $totalComponents) { " (en $totalBatches lotes CSI)" } else { "" }
        Write-Host (Get-AIOString 'limpieza.sfc_components' $totalComponents $batchTxt) -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.sfc_exit_code' $sfcExitText) -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.sfc_queue' $repairQueueText) -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.sfc_result' $sfcAssessment.Message) -ForegroundColor $sfcAssessment.Color

        if ($hashMismatchEntries.Count -gt 0) {
            Write-Host (Get-AIOString 'limpieza.sfc_hash_hdr' $hashMismatchEntries.Count) -ForegroundColor Yellow
            foreach ($hmItem in $hashMismatchEntries) {
                $hmShow = (ConvertTo-SfcCleanText -Text $hmItem).Trim("'")
                Write-SfcWrapped -Text $hmShow -FirstPrefix "     * " -NextPrefix "       " -Color "White"
                Write-Log -LogLevel ACTION -Message "SFC_OFFLINE_HASH_MISMATCH: $hmItem"
            }
        }

        if ($srRepairEntries.Count -gt 0) {
            Write-Host (Get-AIOString 'limpieza.sfc_sr_hdr' $srRepairEntries.Count) -ForegroundColor Cyan
            foreach ($srItem in $srRepairEntries) {
                $col = if ($srItem -match 'Cannot repair|Could not reproject|also corrupted') { 'Red' }
                       elseif ($srItem -match 'referenced by') { 'Yellow' }
                       else { 'Green' }
                Write-SfcWrapped -Text (Format-SfcSrText -Text $srItem) -FirstPrefix "     * " -NextPrefix "       " -Color $col
                Write-Log -LogLevel ACTION -Message "SFC_OFFLINE_SR: $srItem"
            }
        }
        elseif ($null -ne $repairQueueCount -and $repairQueueCount -eq 0) {
            Write-Host (Get-AIOString 'limpieza.sfc_sr_zero') -ForegroundColor Gray
            if ($overlapEntries.Count -gt 0) {
                Write-Host (Get-AIOString 'limpieza.sfc_csi_overlap' $overlapEntries.Count) -ForegroundColor Yellow
                foreach ($ovItem in ($overlapEntries | Select-Object -First 8)) {
                    Write-SfcWrapped -Text (ConvertTo-SfcCleanText -Text $ovItem) -FirstPrefix "     * " -NextPrefix "       " -Color "Gray"
                    Write-Log -LogLevel INFO -Message "SFC_OFFLINE_OVERLAP: $ovItem"
                }
                if ($overlapEntries.Count -gt 8) {
                    Write-Host (Get-AIOString 'limpieza.sfc_more_log' ($overlapEntries.Count - 8)) -ForegroundColor DarkGray
                }
            }
            else {
                Write-Host (Get-AIOString 'limpieza.sfc_no_extra') -ForegroundColor Gray
            }
        }
        elseif ($repairQueueCount -gt 0) {
            Write-Host (Get-AIOString 'limpieza.sfc_sr_unconfirmed' $repairQueueCount) -ForegroundColor Yellow
        }

        if (Test-Path -LiteralPath $sfcLogPath -PathType Leaf) {
            $logLenKB = [Math]::Round((Get-Item -LiteralPath $sfcLogPath).Length / 1KB, 1)
            Write-Host (Get-AIOString 'limpieza.sfc_full_log' $logLenKB $sfcLogPath) -ForegroundColor Gray
        } else {
            Write-Host (Get-AIOString 'limpieza.sfc_no_log_warn' $sfcLogPath) -ForegroundColor Yellow
        }
        Write-Host "   =======================================================" -ForegroundColor DarkCyan
        Write-Host ""

        Write-Log -LogLevel $sfcAssessment.LogLevel -Message "LIMPIEZA: SFC Offline terminado en $totalElapsed (Estado=$($sfcAssessment.Status), ExitCode=$sfcExitText, wcp=$wcpVersion, Lotes=$totalBatches, LotesCompletos=$completedBatches, Componentes=$totalComponents, ColaReparacion=$repairQueueText, HashMismatch=$($hashMismatchEntries.Count), AccionesSR=$($srRepairEntries.Count), Overlaps=$($overlapEntries.Count), Log='$sfcLogPath')."

        if (Get-Command Request-AIODashboardRefreshIfDegraded -ErrorAction SilentlyContinue) {
            Request-AIODashboardRefreshIfDegraded
        }
        return $sfcAssessment.Success
    }

	while ($true) {
        Clear-Host
        if ($Script:IMAGE_MOUNTED -eq 0)
        {
            Write-Warning (Get-AIOString 'common.mount_required_short')
            Pause
            return
        }
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'limpieza.menu_title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'limpieza.opt1') -NoNewline; Write-Host " (DISM /CheckHealth)" -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.opt2') -NoNewline; Write-Host " (DISM /ScanHealth)" -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.opt3') -NoNewline; Write-Host "           (DISM /RestoreHealth)" -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.opt4') -NoNewline; Write-Host " (SFC /Scannow /OffWindir)" -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.opt5') -NoNewline; Write-Host "   (DISM /AnalyzeComponentStore)" -ForegroundColor Gray
        Write-Host (Get-AIOString 'limpieza.opt6') -NoNewline; Write-Host "    (DISM /StartComponentCleanup)" -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'limpieza.opt7') -ForegroundColor Yellow
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host (Get-AIOString 'common.back_short') -ForegroundColor Red

        $opcionL = Read-MenuOption ("`n" + (Get-AIOString 'common.select_option'))
        Write-Log -LogLevel INFO -Message "MENU_LIMPIEZA: Usuario selecciono '$opcionL'."

        switch ($opcionL.ToUpper()) {
            "1" {
                Write-Host (Get-AIOString 'limpieza.running_checkhealth') -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /CheckHealth..."
                Invoke-AIOImageHealthCheck -MountDir $Script:MOUNT_DIR -Mode CheckHealth | Out-Null
                Pause
            }
            "2" {
                Write-Host (Get-AIOString 'limpieza.running_scanhealth') -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /ScanHealth..."
                Invoke-AIOImageHealthCheck -MountDir $Script:MOUNT_DIR -Mode ScanHealth | Out-Null
                Pause
            }
            "3" {
                Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR | Out-Null
            }
            "4" {
                Invoke-AIOOfflineSfcScan -MountDir $Script:MOUNT_DIR | Out-Null
                Pause
            }
            "5" {
                Write-Host (Get-AIOString 'limpieza.running_analyze') -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /AnalyzeComponentStore..."
                $analysisResult = Invoke-AIOComponentStoreAnalysis -MountDir $Script:MOUNT_DIR
                if ($analysisResult.Success) {
                    $recommendationText = if ($analysisResult.CleanupRecommended -eq 'Yes') { 'Si' } else { 'No' }
                    Write-Host (Get-AIOString 'limpieza.analyze_done' $recommendationText) -ForegroundColor Green
                    if ($analysisResult.ExitCode -eq 3010) {
                        Write-Warning (Get-AIOString 'limpieza.dism_3010_warn')
                    }
                }
                Pause
            }
            "6" {
                Write-Host (Get-AIOString 'limpieza.prep_cleanup') -ForegroundColor Yellow
                
                # --- NUEVA LOGICA: Preguntar por /ResetBase ---
                $useResetBase = Read-Host (Get-AIOString 'limpieza.resetbase_prompt')

                $cleanupArgs = @("/Image:$Script:MOUNT_DIR", '/Cleanup-Image', '/StartComponentCleanup', "/ScratchDir:$Script:Scratch_DIR")
                if (Test-AIOYesResponse $useResetBase) {
                    Write-Host (Get-AIOString 'limpieza.cleanup_with_rb') -ForegroundColor Cyan
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /StartComponentCleanup /ResetBase..."
                    $cleanupArgs += '/ResetBase'
                } else {
                    Write-Host (Get-AIOString 'limpieza.cleanup_no_rb') -ForegroundColor Cyan
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /StartComponentCleanup (Sin ResetBase)..."
                }
                try {
                    $cleanupResult = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments $cleanupArgs
                    if ($null -eq $cleanupResult.ExitCode -or $cleanupResult.ExitCode -notin @(0, 3010)) {
                        throw "DISM /StartComponentCleanup termino con codigo $($cleanupResult.ExitCode)."
                    }
                    Write-Host (Get-AIOString 'limpieza.cleanup_ok') -ForegroundColor Green
                    Write-Log -LogLevel INFO -Message "LIMPIEZA: Limpieza manual completada (ExitCode=$($cleanupResult.ExitCode))."
                    if ($cleanupResult.ExitCode -eq 3010) {
                        Write-Warning (Get-AIOString 'limpieza.dism_3010_warn')
                    }
                } catch {
                    Write-Warning (Get-AIOString 'limpieza.cleanup_err' $_.Exception.Message)
                    Write-Log -LogLevel ERROR -Message "LIMPIEZA: Error en limpieza manual: $($_.Exception.Message)"
                }
                Pause
            }
            "7" {
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: Iniciando secuencia COMPLETA..."

                # Preguntar por /ResetBase antes de iniciar la secuencia para no interrumpir el flujo después
                $useResetBaseSeq = Read-Host (Get-AIOString 'limpieza.seq_resetbase_prompt')
                $resetBaseFlag = (Test-AIOYesResponse $useResetBaseSeq)

                # --- PASO 1 ---
                Write-Host (Get-AIOString 'limpieza.seq_step1') -ForegroundColor Yellow
                $checkResult = Invoke-AIOImageHealthCheck -MountDir $Script:MOUNT_DIR -Mode CheckHealth
                if (-not $checkResult.Success) {
                    Write-Warning (Get-AIOString 'limpieza.seq_step1_stop')
                    Pause; continue
                }
                $sequenceRestartRequired = ($checkResult.ExitCode -eq 3010)

                # --- PASO 2 ---
                Write-Host (Get-AIOString 'limpieza.seq_step2') -ForegroundColor Yellow
                $scanResult = Invoke-AIOImageHealthCheck -MountDir $Script:MOUNT_DIR -Mode ScanHealth
                $imageState = $scanResult.ImageHealthState
                if (-not $scanResult.Success) {
                    Write-Warning (Get-AIOString 'limpieza.seq_step2_stop')
                    Pause; continue
                }
                $sequenceRestartRequired = $sequenceRestartRequired -or ($scanResult.ExitCode -eq 3010)

                # --- LOGICA DE DECISION (PASO 3) ---
                if ($imageState -eq "NonRepairable") {
                    Write-Host (Get-AIOString 'limpieza.seq_sec_alert') -ForegroundColor Red
                    Write-Warning (Get-AIOString 'limpieza.seq_nonrepairable_warn')
                    [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'limpieza.seq_nonrepairable_msg'), (Get-AIOString 'limpieza.fatal_error_title'), 'OK', 'Error')
                    Pause; continue
                }
                elseif ($imageState -eq "Healthy") {
                    Write-Host (Get-AIOString 'limpieza.seq_step3') -ForegroundColor DarkGray
                    Write-Host (Get-AIOString 'limpieza.seq_step3_skip') -ForegroundColor Green
                }
                else {
                    Write-Host (Get-AIOString 'limpieza.seq_step3') -ForegroundColor Yellow
                    $restoreResult = Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR -IsSequence
                    if (-not $restoreResult.Success) {
                        Write-Warning (Get-AIOString 'limpieza.seq_step3_stop')
                        Write-Log -LogLevel ERROR -Message 'LIMPIEZA: Secuencia detenida por reparacion fallida o cancelada.'
                        Pause; continue
                    }
                    $sequenceRestartRequired = $sequenceRestartRequired -or ($restoreResult.ExitCode -eq 3010)
                }

                # --- PASO 4 ---
                Write-Host (Get-AIOString 'limpieza.seq_step4') -ForegroundColor Yellow
                $sfcOk = Invoke-AIOOfflineSfcScan -MountDir $Script:MOUNT_DIR
                if (-not $sfcOk) {
                    Write-Warning (Get-AIOString 'limpieza.seq_step4_stop')
                    Pause; continue
                }

                # --- PASO 5 ---
                Write-Host (Get-AIOString 'limpieza.seq_step5') -ForegroundColor Yellow
                $analysisResult = Invoke-AIOComponentStoreAnalysis -MountDir $Script:MOUNT_DIR
                if (-not $analysisResult.Success) {
                    Write-Warning (Get-AIOString 'limpieza.seq_step5_stop')
                    Pause; continue
                }
                $cleanupRecommended = $analysisResult.CleanupRecommended
                $sequenceRestartRequired = $sequenceRestartRequired -or ($analysisResult.ExitCode -eq 3010)

                # ScanHealth ya detiene la secuencia si el estado es Unknown.
                if ($cleanupRecommended -eq "Yes") {
                    Write-Host (Get-AIOString 'limpieza.seq_cleanup_go') -ForegroundColor Cyan;
                    
                    $cleanupArgs = @("/Image:$Script:MOUNT_DIR", '/Cleanup-Image', '/StartComponentCleanup', "/ScratchDir:$Script:Scratch_DIR")
                    # Se conserva la decision existente sobre cuando aplicar /ResetBase.
                    if ($resetBaseFlag) {
                        Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Ejecutando limpieza CON /ResetBase."
                        $cleanupArgs += '/ResetBase'
                    } else {
                        Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Ejecutando limpieza SIN /ResetBase."
                    }
                    try {
                        $cleanupResult = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments $cleanupArgs
                        if ($null -eq $cleanupResult.ExitCode -or $cleanupResult.ExitCode -notin @(0, 3010)) {
                            throw "DISM /StartComponentCleanup termino con codigo $($cleanupResult.ExitCode)."
                        }
                        Write-Log -LogLevel INFO -Message "LIMPIEZA: StartComponentCleanup completado (ExitCode=$($cleanupResult.ExitCode))."
                        $sequenceRestartRequired = $sequenceRestartRequired -or ($cleanupResult.ExitCode -eq 3010)
                    } catch {
                        Write-Warning (Get-AIOString 'limpieza.seq_cleanup_err' $_.Exception.Message)
                        Write-Log -LogLevel ERROR -Message "LIMPIEZA: Secuencia detenida por error en StartComponentCleanup: $($_.Exception.Message)"
                        Pause; continue
                    }
                } else {
                    Write-Host (Get-AIOString 'limpieza.seq_cleanup_skip') -ForegroundColor Green;
                }
                
                Write-Host (Get-AIOString 'limpieza.seq_done') -ForegroundColor Green
                Write-Log -LogLevel INFO -Message "LIMPIEZA: Secuencia completada con resultados verificados. ReinicioRequerido=$sequenceRestartRequired."
                if ($sequenceRestartRequired) {
                    Write-Warning (Get-AIOString 'limpieza.dism_3010_warn')
                }
                Pause
            }
            "V" { return }
            default { Write-Warning (Get-AIOString 'common.invalid_option'); Start-Sleep 1 }
        }
    }
}

# =================================================================
#  UTILIDADES DE REGISTRO OFFLINE (MOTOR NECESARIO)
# =================================================================
# --- HELPE: Importador de Registro Silencioso (Headless) ---
function Import-OfflineReg {
    param(
        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]$FilePath,

        [Parameter(Mandatory=$true, ParameterSetName='Content')]
        [string]$RegContent,

        [switch]$PassThru
    )

    $logSource = if ($PSCmdlet.ParameterSetName -eq 'Content') { '[Payload en memoria]' } else { $FilePath }
    Write-Log -LogLevel INFO -Message "Procesando Registro (Motor Agrupado .NET): $logSource"

    # ── Helpers privados ──────────────────────────────────────────────────────
    function Get-OfflineSubPath {
        param([string]$Raw, [string]$CS)
        if     ($Raw -match '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\TK_CLASSES(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\TK_CLASSES', 'OfflineSoftware\Classes' }
        elseif ($Raw -match '(?i)^(?:HKEY_CLASSES_ROOT|HKCR)(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_CLASSES_ROOT|HKCR)', 'OfflineSoftware\Classes' }
        elseif ($Raw -match '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)\\(?:CurrentControlSet|ControlSet\d{3})(?:\\|$)') { return $Raw -replace "(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)\\(?:CurrentControlSet|ControlSet\d{3})", "OfflineSystem\$CS" }
        elseif ($Raw -match '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)', 'OfflineSystem' }
        elseif ($Raw -match '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SOFTWARE|TK_SOFTWARE)(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SOFTWARE|TK_SOFTWARE)', 'OfflineSoftware' }
        elseif ($Raw -match '(?i)^(?:HKEY_USERS|HKU)\\\.DEFAULT(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_USERS|HKU)\\\.DEFAULT', 'OfflineDefaultUser' }
        elseif ($Raw -match '(?i)^(?:HKEY_CURRENT_USER|HKCU)\\(?:Software|TK_SOFTWARE)\\Classes(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_CURRENT_USER|HKCU)\\(?:Software|TK_SOFTWARE)\\Classes', 'OfflineUserClasses' }
        elseif ($Raw -match '(?i)^(?:HKEY_CURRENT_USER|HKCU)(?:\\|$)') { return $Raw -replace '(?i)^(?:HKEY_CURRENT_USER|HKCU)', 'OfflineUser' }
        elseif ($Raw -match '(?i)^HKEY_LOCAL_MACHINE\\TK_USER(?:\\|$)') { return $Raw -replace '(?i)^HKEY_LOCAL_MACHINE\\TK_USER', 'OfflineUser' }
        return $null
    }

    function ConvertFrom-RegHexData {
        param([string]$HexData, [string]$TypeCode)
        $hexClean = $HexData.Trim() -replace '\s', ''
        if ($hexClean -notmatch '^(?:[0-9a-fA-F]{1,2}(?:,[0-9a-fA-F]{1,2})*,?)?$') {
            throw 'Datos hexadecimales invalidos: se esperaban bytes separados por comas.'
        }
        $byteList = [System.Collections.Generic.List[byte]]::new()
        if ($hexClean -ne '') {
            foreach ($seg in ($hexClean -split ',')) { if ($seg -ne '') { $byteList.Add([Convert]::ToByte($seg, 16)) } }
        }
        $bytes = $byteList.ToArray()
        if ($TypeCode -in @('1', '2', '7') -and ($bytes.Length % 2) -ne 0) {
            throw 'Cadena UTF-16 incompleta: la cantidad de bytes debe ser par.'
        }
        if (($TypeCode -eq '4' -and $bytes.Length -ne 4) -or
            ($TypeCode -eq 'b' -and $bytes.Length -ne 8)) {
            throw "Longitud invalida para hex($TypeCode): $($bytes.Length) bytes."
        }
        return ,$bytes
    }

    function Write-RegHexValue {
        param([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [string]$TypeCode, [string]$HexData)
        $bytes = ConvertFrom-RegHexData -HexData $HexData -TypeCode $TypeCode

        $targetKind = switch ($TypeCode) {
            '2' { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            '7' { [Microsoft.Win32.RegistryValueKind]::MultiString  }
            'b' { [Microsoft.Win32.RegistryValueKind]::QWord        }
            '4' { [Microsoft.Win32.RegistryValueKind]::DWord        }
            '1' { [Microsoft.Win32.RegistryValueKind]::String       }
           default { [Microsoft.Win32.RegistryValueKind]::Binary       }
        }

        $needsDelete = $false
        try {
            $existingKind = $Key.GetValueKind($Name)
            $needsDelete  = ($existingKind -ne $targetKind)
        } catch [System.IO.IOException] { $needsDelete = $true } 
          catch { $needsDelete = $false }

        if ($needsDelete) { try { $Key.DeleteValue($Name, $false) } catch { } }
        
        switch ($TypeCode) {
            '2' { $v = if ($bytes.Length -gt 0) { [System.Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) } else { '' }; $Key.SetValue($Name, $v, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            '7' {
                $strList = [System.Collections.Generic.List[string]]::new()
                if ($bytes.Length -gt 2) {
                    $raw = [System.Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0)
                    foreach ($s in ($raw -split [char]0)) { if ($s -ne '') { $strList.Add($s) } }
                }
                $Key.SetValue($Name, $strList.ToArray(), [Microsoft.Win32.RegistryValueKind]::MultiString)
            }
            'b' { $i64 = if ($bytes.Length -ge 8) { [BitConverter]::ToInt64($bytes, 0) } else { 0L }; $Key.SetValue($Name, $i64, [Microsoft.Win32.RegistryValueKind]::QWord) }
            '4' { $i32 = if ($bytes.Length -ge 4) { [BitConverter]::ToInt32($bytes, 0) } else { 0 }; $Key.SetValue($Name, $i32, [Microsoft.Win32.RegistryValueKind]::DWord) }
            '1' { $v = if ($bytes.Length -gt 0) { [System.Text.Encoding]::Unicode.GetString($bytes).TrimEnd([char]0) } else { '' }; $Key.SetValue($Name, $v, [Microsoft.Win32.RegistryValueKind]::String) }
            default { $Key.SetValue($Name, $bytes, [Microsoft.Win32.RegistryValueKind]::Binary) }
        }
    }

    # ── Configuración ─────────────────────────────────────────────────────────
    $SHIELDED = '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:COMPONENTS|TK_COMPONENTS|SECURITY|TK_SECURITY|SAM|TK_SAM)'
    $rxHeader = [regex]::new('^\[-?(?:HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_CLASSES_ROOT|HKEY_USERS|HKLM|HKCU|HKCR|HKU)\\', 'Compiled,IgnoreCase')
    $rxValue  = [regex]::new('^(@|"(?:[^"\\]|\\.)*")\s*=', 'Compiled')
    $rxHexFragment = [regex]::new('^(?:[0-9a-f]{1,2}\s*(?:,\s*[0-9a-f]{1,2}\s*)*,?\s*)?$', 'Compiled,IgnoreCase')

    $controlSet = Get-OfflineControlSet
    $hive       = [Microsoft.Win32.Registry]::LocalMachine

    $groupedOps        = [System.Collections.Specialized.OrderedDictionary]::new()
    $currentKeyPath    = $null
    $skipSection       = $false
    $hexPending        = $null
    $isFirst           = $true
    $componentsBlocked = 0
    $keysWritten       = 0
    $valuesWritten     = 0
    $errors            = 0
    $parseErrors       = 0

    $reader    = $null
    $memStream = $null

    # ── FASE 1: Parseo en Memoria ─────────────────────────────────────────────
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Content') {
            $srcBytes  = [System.Text.Encoding]::Unicode.GetBytes($RegContent)
            $memStream = [System.IO.MemoryStream]::new($srcBytes, $false)
            $reader    = [System.IO.StreamReader]::new($memStream, [System.Text.Encoding]::Unicode)
        } else {
            $bom = [System.IO.File]::ReadAllBytes($FilePath)
            $srcEncoding = if ($bom.Length -ge 2 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) { [System.Text.Encoding]::Unicode }
                elseif ($bom.Length -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) { [System.Text.Encoding]::UTF8 }
                elseif ($bom.Length -ge 2 -and $bom[0] -eq 0xFE -and $bom[1] -eq 0xFF) { [System.Text.Encoding]::BigEndianUnicode }
                else { [System.Text.Encoding]::Default }
            $bom    = $null
            $reader = [System.IO.StreamReader]::new($FilePath, $srcEncoding)
        }

        $lineCount = 0
        
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineCount++
            
            $trimmed = $line.Trim()
			
            if ($isFirst) {
                $isFirst = $false
                $trimmed = $trimmed.TrimStart([char]0xFEFF)
                if ($trimmed -match '(?i)^Windows\s+Registry\s+Editor') { continue }
            }
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith(';')) { continue }

            if ($null -ne $hexPending) {
                $hasContinuation = $trimmed.EndsWith('\')
                $fragment = if ($hasContinuation) { $trimmed.Substring(0, $trimmed.Length - 1).TrimEnd() } else { $trimmed }
                if (-not $rxHexFragment.IsMatch($fragment) -or
                    [string]::IsNullOrEmpty($fragment) -or
                    ($hasContinuation -and -not $fragment.EndsWith(','))) {
                    # Una nueva asignacion o cabecera no forma parte del valor anterior.
                    # Reprocesar esta misma linea permite informar cada valor truncado.
                    Write-Log -LogLevel WARN -Message "Import-OfflineReg: Linea $($hexPending.LineNumber), valor '$($hexPending.Name)' en '$currentKeyPath': continuacion hexadecimal incompleta o invalida antes de la linea $lineCount."
                    $parseErrors++
                    $hexPending = $null
                } else {
                    $hexPending.Data += $fragment
                    if ($hasContinuation) { continue }

                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetHex'; Name = $hexPending.Name; TypeCode = $hexPending.TypeCode; Data = $hexPending.Data; LineNumber = $hexPending.LineNumber })
                    $hexPending = $null
                    continue
                }
            }

            if ($lineCount % 1000 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }

            if ($rxHeader.IsMatch($trimmed)) {
                $isDelete = $trimmed.StartsWith('[-')
                $rawPath  = $trimmed -replace '^\[-?', '' -replace '\].*$', ''

                if ($rawPath -match $SHIELDED) {
                    $skipSection = $true; $componentsBlocked++
                    Write-Log -LogLevel WARN -Message "Import-OfflineReg: [ESCUDO] Bloqueado -> $rawPath"
                    continue
                }

                $subPath = Get-OfflineSubPath -Raw $rawPath -CS $controlSet
                if ($null -eq $subPath) { $skipSection = $true; continue }
                
                $currentKeyPath = $subPath
                $skipSection = $false

                if (-not $groupedOps.Contains($currentKeyPath)) {
                    $groupedOps[$currentKeyPath] = [System.Collections.Generic.List[psobject]]::new()
                }

                if ($isDelete) {
                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'DeleteKey' })
                } else {
                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'CreateKey' })
                }
                continue
            }

            if ($skipSection -or $null -eq $currentKeyPath) { continue }
            if (-not $rxValue.IsMatch($trimmed))         { continue }

            $valueName = if ($trimmed[0] -eq '@') { '' } else { [regex]::Match($trimmed, '^"((?:[^"\\]|\\.)*)"').Groups[1].Value -replace '\\"', '"' -replace '\\\\', '\' }
            $rhs = $trimmed -replace '^(?:@|"(?:[^"\\]|\\.)*")\s*=\s*', ''

            if ($rhs -eq '-') {
                $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'DeleteValue'; Name = $valueName })
            } elseif ($rhs -match '^dword:([0-9a-fA-F]{1,8})$') {
                $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetDWord'; Name = $valueName; Data = $matches[1] })
            } elseif ($rhs -match '^qword:([0-9a-fA-F]{1,16})$') {
                $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetQWord'; Name = $valueName; Data = $matches[1] })
            } elseif ($rhs -match '^"((?:[^"\\]|\\.)*)"$') {
                $str = $matches[1] -replace '\\"', '"' -replace '\\\\', '\'
                $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetString'; Name = $valueName; Data = $str })
            } elseif ($rhs -match '^hex(?:\(([0-9a-fA-F]*)\))?:(.*)$') {
                $typeCode = $matches[1]
                $hexFrag  = $matches[2].TrimEnd()
                if ($hexFrag.EndsWith('\')) {
                    $hexFrag = $hexFrag.Substring(0, $hexFrag.Length - 1).TrimEnd()
                    # hex:\ puede dejar todos los bytes para la linea siguiente.
                    # La coma solo es obligatoria si ya hay bytes en este fragmento.
                    if (-not $rxHexFragment.IsMatch($hexFrag) -or
                        ($hexFrag.Length -gt 0 -and -not $hexFrag.EndsWith(','))) {
                        Write-Log -LogLevel WARN -Message "Import-OfflineReg: Linea $lineCount, valor '$valueName' en '$currentKeyPath': fragmento hexadecimal invalido; los bytes antes de una continuacion deben terminar en coma."
                        $parseErrors++
                    } else {
                        $hexPending = [PSCustomObject]@{ Name = $valueName; TypeCode = $typeCode; Data = $hexFrag; LineNumber = $lineCount }
                    }
                } else {
                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetHex'; Name = $valueName; TypeCode = $typeCode; Data = $hexFrag; LineNumber = $lineCount })
                }
            }
        }

        if ($null -ne $hexPending) {
            Write-Log -LogLevel WARN -Message "Import-OfflineReg: Linea $($hexPending.LineNumber), valor '$($hexPending.Name)' en '$currentKeyPath': continuacion hexadecimal incompleta al final del archivo."
            $parseErrors++
        }

        # Validar todos los bytes antes de desbloquear claves o modificar el registro.
        # Un archivo malformado se rechaza completo; no queda importado parcialmente.
        foreach ($kp in $groupedOps.Keys) {
            foreach ($op in $groupedOps[$kp]) {
                if ($op.Action -ne 'SetHex') { continue }
                try {
                    ConvertFrom-RegHexData -HexData $op.Data -TypeCode $op.TypeCode | Out-Null
                } catch {
                    Write-Log -LogLevel WARN -Message "Import-OfflineReg: Linea $($op.LineNumber), valor '$($op.Name)' en '$kp': $($_.Exception.Message)"
                    $parseErrors++
                }
            }
        }
        if ($parseErrors -gt 0) {
            throw "Import-OfflineReg: $parseErrors errores de formato. Archivo rechazado antes de escribir claves o valores. Revisa las lineas indicadas en el log."
        }
    } catch {
        Write-Log -LogLevel ERROR -Message "Import-OfflineReg (Fase 1): Fallo parseo en '$logSource' - $($_.Exception.Message)"
        throw
    } finally {
        if ($null -ne $reader)    { $reader.Dispose() }
        if ($null -ne $memStream) { $memStream.Dispose() }
    }

    # ── FASE 2: Ejecución Agrupada ────────────────────────────────────────────
    $currentKey = $null
    
    # NUEVO: Aseguramos privilegios críticos de forma segura antes del procesamiento masivo
    Enable-Privileges

    try {
        $keyProcessCount = 0
        
        foreach ($kp in $groupedOps.Keys) {
            $keyProcessCount++
            if ($keyProcessCount % 25 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }

            $actions = $groupedOps[$kp]

            # Desbloqueo pre-escritura simplificado
            Unlock-OfflineKey -KeyPath "HKLM:\$kp"

            $keyCreated = $false
            foreach ($op in $actions) {
                try {
                    switch ($op.Action) {
                        'DeleteKey' {
                            if ($null -ne $currentKey) { $currentKey.Dispose(); $currentKey = $null; $keyCreated = $false }
                            if ($kp -notmatch '\\') { continue } # Proteger raíz
                            $parentSub = $kp -replace '\\[^\\]+$', ''
                            $leafName  = $kp -replace '^.*\\', ''
                            
                            $parentKey = $hive.OpenSubKey($parentSub, $true)
                            if ($null -ne $parentKey) {
                                try { $parentKey.DeleteSubKeyTree($leafName, $false) }
                                finally { $parentKey.Dispose() }
                            }
                        }
                        'CreateKey' {
                            if (-not $keyCreated) {
                                $currentKey = $hive.CreateSubKey($kp, $true)
                                $keyCreated = $true; $keysWritten++
                            }
                        }
                        default {
                            if (-not $keyCreated) {
                                $currentKey = $hive.CreateSubKey($kp, $true)
                                $keyCreated = $true; $keysWritten++
                            }
                            if ($null -ne $currentKey) {
                                switch ($op.Action) {
                                    'DeleteValue' { $currentKey.DeleteValue($op.Name, $false) }
                                    'SetDWord'    { $uint = [Convert]::ToUInt32($op.Data, 16); $int = [BitConverter]::ToInt32([BitConverter]::GetBytes($uint), 0); $currentKey.SetValue($op.Name, $int, [Microsoft.Win32.RegistryValueKind]::DWord); $valuesWritten++ }
                                    'SetQWord'    { $u64 = [Convert]::ToUInt64($op.Data, 16); $i64 = [BitConverter]::ToInt64([BitConverter]::GetBytes($u64), 0); $currentKey.SetValue($op.Name, $i64, [Microsoft.Win32.RegistryValueKind]::QWord); $valuesWritten++ }
                                    'SetString'   { $currentKey.SetValue($op.Name, $op.Data, [Microsoft.Win32.RegistryValueKind]::String); $valuesWritten++ }
                                    'SetHex'      { Write-RegHexValue $currentKey $op.Name $op.TypeCode $op.Data; $valuesWritten++ }
                                }
                            }
                        }
                    }
                    # Solo las escrituras en los 12 valores de metadatos del SO leidos por el Dashboard
                    # invalidan el panel; escribir otros valores (ej. RegisteredOwner) conserva la cache.
                    if (Get-Command Test-AIODashboardRegistryMutationAffectsMetadata -ErrorAction SilentlyContinue) {
                        if (Test-AIODashboardRegistryMutationAffectsMetadata -KeyPath $kp -Action $op.Action -ValueName $op.Name) {
                            $Script:ForceMenuRefresh = $true
                        }
                    } else {
                        $dashboardKey = 'OfflineSoftware\Microsoft\Windows NT\CurrentVersion'
                        if (($kp -eq $dashboardKey -and $op.Action -ne 'CreateKey') -or
                            ($op.Action -eq 'DeleteKey' -and $dashboardKey.StartsWith($kp + '\', [StringComparison]::OrdinalIgnoreCase))) {
                            $Script:ForceMenuRefresh = $true
                        }
                    }
                } catch {
                    Write-Log -LogLevel WARN -Message "Import-OfflineReg: Fallo '$($op.Action)' -> '$($op.Name)' en '$kp' - $($_.Exception.Message)"
                    $errors++
                }
            }
            if ($null -ne $currentKey) { $currentKey.Dispose(); $currentKey = $null }
        }
    } catch {
        Write-Log -LogLevel ERROR -Message "Import-OfflineReg (Fase 2): Fallo critico inyectando - $($_.Exception.Message)"
        throw
    } finally {
        if ($null -ne $currentKey) { $currentKey.Dispose() }
		# Colección asíncrona: libera la presión del LOH sin bloquear el hilo de la UI
        [GC]::Collect()
    }

    if ($componentsBlocked -gt 0) { Write-Log -LogLevel WARN -Message "Import-OfflineReg: $componentsBlocked secciones bloqueadas (COMPONENTS/SECURITY/SAM)." }
    
    if ($errors -gt 0) { 
        Write-Log -LogLevel WARN -Message "Import-OfflineReg: $errors advertencias de inyeccion."
        throw "Import-OfflineReg: $errors errores durante inyeccion. Revisa el log para detalle."
    }
    
    $importStatus = if ($componentsBlocked -gt 0) { 'CompletedWithOmissions' } else { 'Completed' }
    $importLevel = if ($componentsBlocked -gt 0) { 'WARN' } else { 'INFO' }
    Write-Log -LogLevel $importLevel -Message "Import-OfflineReg: $importStatus — $keysWritten claves afectadas, $valuesWritten valores inyectados, $componentsBlocked secciones bloqueadas."
    if ($PassThru) {
        [pscustomobject]@{
            Status = $importStatus
            KeysWritten = $keysWritten
            ValuesWritten = $valuesWritten
            BlockedSections = $componentsBlocked
        }
    }
}

function Mount-Hives {
    Write-Log -LogLevel INFO -Message "HIVES: Iniciando secuencia de montaje inteligente..."
    $swMount = [System.Diagnostics.Stopwatch]::StartNew()
    $resumenMount = [ordered]@{
        Cargadas = 0
        Omitidas = 0
        Fallidas = @()
    }
    
    # 1. Rutas fisicas
    $hiveDir = Join-Path $Script:MOUNT_DIR "Windows\System32\config"
    $userDir = Join-Path $Script:MOUNT_DIR "Users\Default"
    
    $sysHive     = Join-Path $hiveDir "SYSTEM"
    $softHive    = Join-Path $hiveDir "SOFTWARE"
    $compHive    = Join-Path $hiveDir "COMPONENTS" 
    $defaultHive = Join-Path $hiveDir "DEFAULT"
    $userHive    = Join-Path $userDir "NTUSER.DAT" 
    $classHive   = Join-Path $userDir "AppData\Local\Microsoft\Windows\UsrClass.dat"

    # 2. Validacion critica (SYSTEM y SOFTWARE son obligatorios incluso en Boot.wim)
    if (-not (Test-Path $sysHive) -or -not (Test-Path $softHive)) { 
        [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'hives.missing_critical'), (Get-AIOString 'limpieza.fatal_error_title'), 'OK', 'Error')
        return $false 
    }

    # 3. Check preventivo: Si SYSTEM ya esta montado, asumimos que todo esta listo.
    if ((Test-Path "Registry::HKLM\OfflineSystem") -and (Test-Path "Registry::HKLM\OfflineSoftware")) {
        Write-Log -LogLevel INFO -Message "HIVES: Detectados hives base ya montados. Omitiendo carga."
        return $true
    }

    try {
        # --- CARGA OBLIGATORIA (SYSTEM / SOFTWARE) ---
        Write-Host (Get-AIOString 'hives.loading_system') -NoNewline
        $p1 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSystem `"$sysHive`"" -Wait -PassThru -NoNewWindow
        $ec1 = $p1.ExitCode; $p1.Dispose()
        if ($ec1 -ne 0) { throw (Get-AIOString 'hives.fail_system') } else { Write-Host "OK" -ForegroundColor Green; $resumenMount.Cargadas++ }

        Write-Host (Get-AIOString 'hives.loading_software') -NoNewline
        $p2 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSoftware `"$softHive`"" -Wait -PassThru -NoNewWindow
        $ec2 = $p2.ExitCode; $p2.Dispose()
        if ($ec2 -ne 0) { throw (Get-AIOString 'hives.fail_software') } else { Write-Host "OK" -ForegroundColor Green; $resumenMount.Cargadas++ }

        # --- Carga del Perfil Default (.DEFAULT) ---
        if (Test-Path $defaultHive) {
            Write-Host (Get-AIOString 'hives.loading_default_user') -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineDefaultUser `"$defaultHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host (Get-AIOString 'hives.failed_skipped') -ForegroundColor Red 
                $resumenMount.Fallidas += "DEFAULT"
                Write-Log -LogLevel WARN -Message "Fallo al cargar DEFAULT (ExitCode: $($p.ExitCode))"
            }
        }

        # --- CARGA CONDICIONAL (BOOT / REPARACION) ---

        # COMPONENTS (A veces no existe en WinPE/Boot.wim muy ligeros)
        if (Test-Path $compHive) {
            Write-Host (Get-AIOString 'hives.loading_components') -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineComponents `"$compHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host (Get-AIOString 'hives.failed_skipped') -ForegroundColor Red 
                $resumenMount.Fallidas += "COMPONENTS"
                Write-Log -LogLevel WARN -Message "Fallo al cargar COMPONENTS (ExitCode: $($p.ExitCode))"
            }
        }

        # NTUSER.DAT (No existe en Boot.wim)
        if (Test-Path $userHive) {
            Write-Host (Get-AIOString 'hives.loading_user') -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUser `"$userHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host (Get-AIOString 'hives.failed_skipped') -ForegroundColor Red 
                $resumenMount.Fallidas += "USER"
                Write-Log -LogLevel WARN -Message "Fallo al cargar NTUSER.DAT (ExitCode: $($p.ExitCode))"
            }
        } else {
            Write-Host (Get-AIOString 'hives.user_skipped_winpe') -ForegroundColor DarkGray
            $resumenMount.Omitidas++
        }

        # UsrClass.dat (No existe en Boot.wim ni antes del primer inicio de sesion del perfil)
        if (-not (Test-Path $classHive) -and (Test-Path $userHive)) {
            # El perfil Default tiene NTUSER.DAT pero aun no genero UsrClass.dat (nadie ha iniciado
            # sesion todavia). Lo creamos en blanco -exactamente igual que hace Windows en el primer
            # logon- para poder provisionar asociaciones HKCU\Software\Classes (ej. handlers de PDF)
            # antes de que exista un usuario real.
			try {
                $classDir = Split-Path $classHive -Parent
                if (-not (Test-Path $classDir)) { New-Item -Path $classDir -ItemType Directory -Force | Out-Null }

                $tempKeyName = "_TempEmptyHive_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
                $softwareRoot = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("OfflineSoftware", $true)
                if ($null -eq $softwareRoot) { throw "No se pudo abrir OfflineSoftware para crear la key de andamiaje." }
                $tempKey = $softwareRoot.CreateSubKey($tempKeyName, $true)
                if ($null -ne $tempKey) { $tempKey.Dispose() }
                $softwareRoot.Dispose()

                $pSave = Start-Process reg.exe -ArgumentList "save `"HKLM\OfflineSoftware\$tempKeyName`" `"$classHive`"" -Wait -PassThru -NoNewWindow

                $softwareRoot2 = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("OfflineSoftware", $true)
                if ($null -ne $softwareRoot2) {
                    $softwareRoot2.DeleteSubKeyTree($tempKeyName, $false)
                    $softwareRoot2.Dispose()
                }

                if ($pSave.ExitCode -ne 0) { throw "reg.exe save fallo (Codigo: $($pSave.ExitCode))" }
                Write-Log -LogLevel INFO -Message "HIVES: UsrClass.dat no existia para el perfil Default; se creo un hive vacio (igual que el primer inicio de sesion de Windows)."
            } catch {
                Write-Log -LogLevel WARN -Message "HIVES: No se pudo crear UsrClass.dat vacio para Default -> $($_.Exception.Message)"
            }
        }

        if (Test-Path $classHive) {
            Write-Host (Get-AIOString 'hives.loading_classes') -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUserClasses `"$classHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host (Get-AIOString 'hives.failed_skipped') -ForegroundColor Red 
                $resumenMount.Fallidas += "CLASSES"
                Write-Log -LogLevel WARN -Message "Fallo al cargar UsrClass.dat (ExitCode: $($p.ExitCode))"
            }
        } else {
            $resumenMount.Omitidas++
        }

        $swMount.Stop()
        Write-Log -LogLevel INFO -Message ("HIVES: [RESUMEN] Cargadas: $($resumenMount.Cargadas) | Omitidas (no aplica en esta imagen): $($resumenMount.Omitidas)" +
            $(if ($resumenMount.Fallidas.Count -gt 0) { " | FALLIDAS: $($resumenMount.Fallidas -join ', ')" } else { "" }) +
            " | Tiempo total: $([math]::Round($swMount.Elapsed.TotalSeconds, 2))s")

        return $true
    } catch {
        Write-Host "`n[FATAL] $_"
        Write-Log -LogLevel ERROR -Message "Fallo Mount-Hives: $_"
        # Intento de limpieza de emergencia
        Unmount-Hives
        return $false
    }
}

$NativeRegDef = @'
using System;
using System.Runtime.InteropServices;

public class NativeRegistry
{
    // Constante para HKEY_LOCAL_MACHINE
    public const uint HKEY_LOCAL_MACHINE = 0x80000002;

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern int RegUnLoadKey(uint hKey, string lpSubKey);
}
'@

# Cargar la clase solo si no existe en la sesión actual
if (-not ([System.Management.Automation.PSTypeName]'NativeRegistry').Type) {
    Add-Type -TypeDefinition $NativeRegDef -PassThru | Out-Null
}

function Unmount-Hives {
    Write-Host (Get-AIOString 'hives.unloading') -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Iniciando proceso de descarga de colmenas de registro."
    $swUnmount = [System.Diagnostics.Stopwatch]::StartNew()
    $resumen = [ordered]@{
        Desmontadas   = 0
        ViaFallback   = 0
        NoMontadas    = 0
        Reintentos    = 0
        Fallidas      = @()
    }
    
	# --- NUEVO: PARACAÍDAS SDDL ---
    if ($Script:SDDL_Backups.Count -gt 0) {
        Restore-AllOfflineSDDL
    }
	
    # 1. TRUCO DE VETERANO: El "Doble Tap" al Recolector de Basura.
    # Asegura que las referencias circulares de WinForms y COM se purguen completamente.
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Ejecutando recoleccion de basura (GC) agresiva para liberar handles."
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect() 
    
    # Pausa de seguridad para permitir que el kernel libere los archivos fisicos
    # FIX: un Start-Sleep puro bloquea el hilo por completo sin bombear el message
    # loop de Windows. Si esta funcion se invoca con una ventana WinForms todavia
    # viva (p.ej. desde/antes de resolver FormClosing), ese silencio de 5 segundos
    # es lo que dispara el "Not Responding"/ghosting de DWM: la ventana deja de
    # responder a mensajes y queda desdibujada, y cualquier MessageBox pendiente
    # se atrasa junto con ella. Se sustituye por una espera equivalente que sigue
    # llamando a Application::DoEvents() en tramos cortos.
    Write-Host (Get-AIOString 'hives.waiting_handles') -ForegroundColor DarkGray
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Pausa de seguridad de 5 segundos para liberar bloqueos del kernel."
    $waitUntil = (Get-Date).AddSeconds(5)
    while ((Get-Date) -lt $waitUntil) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    
    # Lista ampliada de Hives a descargar
    $hives = @(
        "HKLM\OfflineSystem", 
        "HKLM\OfflineSoftware", 
        "HKLM\OfflineComponents",
		"HKLM\OfflineDefaultUser",
        "HKLM\OfflineUser", 
        "HKLM\OfflineUserClasses"
    )
    
    foreach ($hive in $hives) {
        # 2. EVITAMOS Test-Path: Usamos reg query silenciado para evitar que 
        # el proveedor de PS mantenga un micro-bloqueo sobre la clave.
        $isMounted = $false
        reg query $hive 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $isMounted = $true }

        if ($isMounted) {
            # Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Colmena detectada como montada -> $hive. Procediendo a descargar."
            $retries = 0; $done = $false
            while ($retries -lt 5 -and -not $done) {
                
                # 1. Intentamos el desmontaje nativo estándar
                reg unload $hive 2>$null | Out-Null
                
                if ($LASTEXITCODE -eq 0) { 
                    $done = $true 
                    $resumen.Desmontadas++
                    # Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: [EXITO] $hive desmontada correctamente en el intento $($retries + 1)."
                } else { 
                    # 2. FALLBACK A LA API NATIVA (P/Invoke)
                    # La API requiere solo el nombre de la subclave (ej: "OfflineSystem")
                    $subKeyToUnload = $hive -replace "(?i)^HKLM\\", ""
                    
                    # RegUnLoadKey requiere solo restauracion y respaldo.
                    Enable-Privileges -Privileges @('SeBackupPrivilege', 'SeRestorePrivilege')
                    
                    $nativeResult = [NativeRegistry]::RegUnLoadKey([NativeRegistry]::HKEY_LOCAL_MACHINE, $subKeyToUnload)
                    
                    if ($nativeResult -eq 0) {
                        $done = $true
                        $resumen.ViaFallback++
                        Write-Log -LogLevel ACTION -Message "UNMOUNT_HIVES: [FALLBACK NATIVO] $hive liberada forzosamente usando advapi32.dll en el intento $($retries + 1)."
                    } else {
                        $retries++
                        $resumen.Reintentos++
                        Write-Host "." -NoNewline -ForegroundColor Yellow
                        Write-Log -LogLevel WARN -Message "UNMOUNT_HIVES: Intento $retries fallido (reg.exe y API Nativa devolvió código $nativeResult). Reintentando..."
                        
                        # 3. RECOLECCIÓN DINÁMICA
                        [GC]::Collect()
                        
                        # Espera incremental entre reintentos (bombeando mensajes, ver FIX arriba)
                        $retryUntil = (Get-Date).AddMilliseconds(500 * $retries)
                        while ((Get-Date) -lt $retryUntil) {
                            [System.Windows.Forms.Application]::DoEvents()
                            Start-Sleep -Milliseconds 50
                        }
                    }
                }
            }
            if (-not $done) { 
                $resumen.Fallidas += $hive
                Write-Log -LogLevel ERROR -Message "UNMOUNT_HIVES: Fallo CRITICO al desmontar $hive tras 5 intentos. Archivo permanentemente bloqueado."
                
                # FRENO DE EMERGENCIA: Si no abortamos aquí, DISM corromperá la imagen (CONFIG_INITIALIZATION_FAILED)
                $errMsg = Get-AIOString 'core.hive_locked_fatal' $hive
                
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show($errMsg, (Get-AIOString 'hives.corruption_danger_title'), 'OK', 'Error')
                
                throw $errMsg
            }
        } else {
            $resumen.NoMontadas++
            # Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: La colmena $hive no estaba montada. Se omite."
        }
    }
    $swUnmount.Stop()
    Write-Host (Get-AIOString 'hives.process_done') -ForegroundColor Green
    Write-Log -LogLevel INFO -Message ("UNMOUNT_HIVES: [RESUMEN] Desmontadas: $($resumen.Desmontadas) (Fallback nativo: $($resumen.ViaFallback)) | " +
        "Ya libres: $($resumen.NoMontadas) | Reintentos totales: $($resumen.Reintentos)" +
        $(if ($resumen.Fallidas.Count -gt 0) { " | FALLIDAS: $($resumen.Fallidas -join ', ')" } else { "" }) +
        " | Tiempo total: $([math]::Round($swUnmount.Elapsed.TotalSeconds, 2))s")
}

function Translate-OfflinePath {
    param([string]$OnlinePath)
    
    # 1. Guardia de entrada defensiva (Bug 3)
    if ([string]::IsNullOrWhiteSpace($OnlinePath)) {
        Write-Log -LogLevel WARN -Message "Translate-OfflinePath: Se recibio una ruta nula o vacia. Se omite."
        return $null
    }
    
    # 2. Limpieza inicial y normalización
    $cleanPath = $OnlinePath -replace "^Registry::", "" 
    $cleanPath = $cleanPath -replace "^HKLM:", "HKEY_LOCAL_MACHINE"
    $cleanPath = $cleanPath -replace "^HKLM\\", "HKEY_LOCAL_MACHINE\"
    $cleanPath = $cleanPath -replace "^HKCU:", "HKEY_CURRENT_USER"
    $cleanPath = $cleanPath -replace "^HKCU\\", "HKEY_CURRENT_USER\"
    $cleanPath = $cleanPath -replace "^HKCR:", "HKEY_CLASSES_ROOT"
    $cleanPath = $cleanPath -replace "^HKCR\\", "HKEY_CLASSES_ROOT\"
	$cleanPath = $cleanPath -replace "^HKU:", "HKEY_USERS"
    $cleanPath = $cleanPath -replace "^HKU\\", "HKEY_USERS\"
    $cleanPath = $cleanPath.Trim()

    # --- USUARIO DEFAULT (HKEY_USERS\.DEFAULT) ---
    if ($cleanPath -match "^HKEY_USERS\\\.DEFAULT(?:\\|$)") {
        return $cleanPath -replace "^HKEY_USERS\\\.DEFAULT", "HKLM\OfflineDefaultUser"
    }
	
	# --- Mapeo de Clases de Usuario (UsrClass.dat) ---
    # Bug 2: Uso de grupos no capturadores (?:\\|$)
    if ($cleanPath -match "HKEY_CURRENT_USER\\Software\\Classes(?:\\|$)") {
        
        # Bug 1: Caché de la comprobación Test-Path para evitar I/O redundante
        if ($null -eq $Script:OfflineUserClassesPresent) {
            $Script:OfflineUserClassesPresent = Test-Path "HKLM:\OfflineUserClasses"
        }
        
        if ($Script:OfflineUserClassesPresent) {
            return $cleanPath -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM\OfflineUserClasses"
        } else {
            return $cleanPath -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM\OfflineSoftware\Classes"
        }
    }

    # USUARIO (HKCU Genérico - NTUSER.DAT)
    if ($cleanPath -match "HKEY_CURRENT_USER(?:\\|$)") {
        return $cleanPath -replace "HKEY_CURRENT_USER", "HKLM\OfflineUser"
    }

    # SYSTEM (HKEY_LOCAL_MACHINE\SYSTEM)
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SYSTEM(?:\\|$)") {
        $newPath = $cleanPath -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKLM\OfflineSystem"
        
        if ($newPath -match "CurrentControlSet|ControlSet\d{3}") {
            $dynamicSet = Get-OfflineControlSet
            if (-not $dynamicSet) {
                Write-Log -LogLevel ERROR -Message "Translate-OfflinePath: Imposible traducir, ControlSet es nulo para la ruta '$cleanPath'."
                return $null
            }
            return $newPath -replace "CurrentControlSet|ControlSet\d{3}", $dynamicSet
        }
        return $newPath
    }

    # SOFTWARE (HKEY_LOCAL_MACHINE\SOFTWARE)
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SOFTWARE(?:\\|$)") {
        return $cleanPath -replace "HKEY_LOCAL_MACHINE\\SOFTWARE", "HKLM\OfflineSoftware"
    }
    
    # CLASSES ROOT (Global)
    if ($cleanPath -match "HKEY_CLASSES_ROOT(?:\\|$)") {
        return $cleanPath -replace "HKEY_CLASSES_ROOT", "HKLM\OfflineSoftware\Classes"
    }
    
    # COMPONENTS
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\COMPONENTS(?:\\|$)") {
        return $cleanPath -replace "HKEY_LOCAL_MACHINE\\COMPONENTS", "HKLM\OfflineComponents"
    }
    
    # Loguear colmenas huérfanas o no mapeadas
    Write-Log -LogLevel WARN -Message "Translate-OfflinePath: Hive no reconocida o no mapeada para la ruta: '$cleanPath'. Se omite."
    return $null
}

# --- UTILIDAD: ACTIVAR PRIVILEGIOS DE TOKEN (SeTakeOwnership / SeRestore) ---
function Initialize-AIOPrivilegeNative {
    if (([System.Management.Automation.PSTypeName]'AIOPrivilegeNative').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AIOPrivilegeNative {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TokenPrivileges {
        public uint Count;
        public long Luid;
        public uint Attributes;
    }
    [DllImport("kernel32.dll", ExactSpelling=true)]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", EntryPoint="LookupPrivilegeValueW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", ExactSpelling=true, SetLastError=true)]
    private static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll,
        ref TokenPrivileges state, uint length, IntPtr previous, IntPtr returned);
    public static void Enable(string privilege) {
        IntPtr token = IntPtr.Zero;
        try {
            if (!OpenProcessToken(GetCurrentProcess(), 0x0020 | 0x0008, out token)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            long luid;
            if (!LookupPrivilegeValue(null, privilege, out luid)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            TokenPrivileges state = new TokenPrivileges();
            state.Count = 1;
            state.Luid = luid;
            state.Attributes = 0x00000002;
            bool adjusted = AdjustTokenPrivileges(token, false, ref state, 0, IntPtr.Zero, IntPtr.Zero);
            int error = Marshal.GetLastWin32Error();
            // TRUE tambien puede devolver ERROR_NOT_ALL_ASSIGNED (1300).
            if (!adjusted || error != 0) { throw new Win32Exception(error); }
        } finally {
            if (token != IntPtr.Zero) { CloseHandle(token); }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Enable-Privileges {
    param(
        [ValidateNotNullOrEmpty()]
        [string[]]$Privileges = @(
            'SeTakeOwnershipPrivilege', 'SeRestorePrivilege',
            'SeBackupPrivilege', 'SeSecurityPrivilege'
        )
    )
    if (-not (Get-Variable -Name AIOEnabledPrivileges -Scope Script -ErrorAction SilentlyContinue)) {
        $Script:AIOEnabledPrivileges = @{}
    }
    Initialize-AIOPrivilegeNative
    $failures = @()
    foreach ($privilege in @($Privileges | Sort-Object -Unique)) {
        if ($Script:AIOEnabledPrivileges.ContainsKey($privilege)) { continue }
        try {
            [AIOPrivilegeNative]::Enable($privilege)
            $Script:AIOEnabledPrivileges[$privilege] = $true
        } catch {
            # No guardar fallos: la siguiente llamada debe poder reintentarlo.
            $failures += "${privilege}: $($_.Exception.Message)"
        }
    }
    $defaults = @('SeTakeOwnershipPrivilege', 'SeRestorePrivilege', 'SeBackupPrivilege', 'SeSecurityPrivilege')
    $Script:GlobalPrivilegesEnabled = @($defaults | Where-Object {
        -not $Script:AIOEnabledPrivileges.ContainsKey($_)
    }).Count -eq 0
    if ($failures.Count -gt 0) { throw ('No se pudieron activar los privilegios: ' + ($failures -join '; ')) }
}

# Diccionario global en RAM para almacenar los permisos exactos de fabrica
$Script:SDDL_Backups = @{}
# Diccionario global para respaldar permisos de archivos (SDDL)
$Script:FileSDDL_Backups = @{}

function Unlock-OfflineKey {
    param([string]$KeyPath)
    
    Enable-Privileges

    # Normalizar ruta
    $psPath       = $KeyPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|Registry::HKEY_LOCAL_MACHINE|Registry::HKLM)[:\\]*", ""
    $finalSubKey  = $psPath
    $originalPath = $psPath   # conservar para distinguir los dos casos del bucle
    $rootHive     = [Microsoft.Win32.Registry]::LocalMachine
    
    # Buscar el ancestro más cercano que exista y esté bloqueado
    while ($true) {
        $check = $null
        try {
            $check = $rootHive.OpenSubKey($finalSubKey, [System.Security.AccessControl.RegistryRights]::WriteKey)
            
            if ($check) {
                if ($finalSubKey -eq $originalPath) {
                    # El destino existe y ya tiene WriteKey: no hay nada que desbloquear.
                    return
                }
                # Llegamos aquí porque el destino original no existía y subimos al padre.
                # Aunque el padre abre con WriteKey, en colmenas offline ese derecho no
                # garantiza CreateSubKey. Hay que desbloquear el padre explicitamente.
                break
            }
            # $check es $null: la clave todavía no existe. Subir un nivel.
        } catch [System.Security.SecurityException] {
            # La clave existe pero el acceso fue denegado: esta es la que hay que desbloquear.
            break 
        } catch {
            Write-Log -LogLevel WARN -Message "Unlock-OfflineKey: Error inesperado en $finalSubKey - $($_.Exception.Message)"
            return
        } finally {
            if ($null -ne $check) { $check.Dispose() }
        }
        
        $lastSlash = $finalSubKey.LastIndexOf("\")
        if ($lastSlash -lt 0) { return }
        $finalSubKey = $finalSubKey.Substring(0, $lastSlash)
    }

    Unlock-Single-Key -SubKeyPath $finalSubKey
}

function Unlock-Single-Key {
    param([string]$SubKeyPath)
    
    # Protección absoluta de las raíces de las colmenas
    if ($SubKeyPath -match "^(OfflineSystem|OfflineSoftware|OfflineUser|OfflineUserClasses|OfflineComponents|OfflineDefaultUser)$") { return }
    
	if ($Script:SDDL_Backups.ContainsKey($SubKeyPath)) { return }
	
    Enable-Privileges
    $rootKey = [Microsoft.Win32.Registry]::LocalMachine
    $keyOwner = $null; $keyPerms = $null

    $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $success = $false

    # --- PASO 1: RESPALDAR SDDL Y TOMAR POSESIÓN ---
    try {
        $rights = [System.Security.AccessControl.RegistryRights]::TakeOwnership -bor [System.Security.AccessControl.RegistryRights]::ReadPermissions
        $keyOwner = $rootKey.OpenSubKey($SubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
        
        if ($keyOwner) {
            if (-not $Script:SDDL_Backups.ContainsKey($SubKeyPath)) {
                # CORRECCIÓN BUG 1: Solo solicitamos Access y Owner (Evitamos la SACL)
                $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
                $originalAcl = $keyOwner.GetAccessControl($sections)
                $Script:SDDL_Backups[$SubKeyPath] = $originalAcl.GetSecurityDescriptorSddlForm($sections)
            }

            $acl = $keyOwner.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $acl.SetOwner($sidAdmin)
            $keyOwner.SetAccessControl($acl)
        }
    } catch { 
        Write-Log -LogLevel WARN -Message "Unlock-Single-Key: Fallo al tomar posesión de $SubKeyPath - $($_.Exception.Message)"
    } finally {
        if ($null -ne $keyOwner) { $keyOwner.Dispose() }
    }

    # --- PASO 2: ASIGNAR CONTROL TOTAL ---
    try {
        $keyPerms = $rootKey.OpenSubKey($SubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($keyPerms) {
            $acl = $keyPerms.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sidAdmin, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $acl.SetAccessRule($rule)
            $keyPerms.SetAccessControl($acl)
            $success = $true
        }
    } catch {
        Write-Log -LogLevel WARN -Message "Unlock-Single-Key: Fallo al asignar FullControl en $SubKeyPath - $($_.Exception.Message)"
    } finally {
        if ($null -ne $keyPerms) { $keyPerms.Dispose() }
    }
    
    # --- PASO 3: FALLBACK REGINI ---
    if (-not $success) {
        try {
            $kernelPath = "\Registry\Machine\$SubKeyPath"
            $reginiContent = "$kernelPath [1 17]"
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value $reginiContent -Encoding Ascii
            $reginiProc = Start-Process regini.exe -ArgumentList "`"$tempFile`"" -PassThru -WindowStyle Hidden -Wait
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            if ($reginiProc.ExitCode -ne 0) {
                Write-Log -LogLevel WARN -Message "Unlock-Single-Key: regini fallo (ExitCode $($reginiProc.ExitCode)) en $SubKeyPath"
            }
        } catch {
            Write-Log -LogLevel WARN -Message "Unlock-Single-Key: Fallo fallback regini en $SubKeyPath - $($_.Exception.Message)"
        }
    }
}

function Restore-KeyOwner {
    param([string]$KeyPath)
    
    Enable-Privileges 
    $cleanPath = $KeyPath -replace "^Registry::", ""
    $subPath = $cleanPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|HKLM:|HKEY_LOCAL_MACHINE:)[:\\]+", ""
    $hive = [Microsoft.Win32.Registry]::LocalMachine
    $keyObj = $null

    $wasTracked = $Script:SDDL_Backups.ContainsKey($subPath)

    # =========================================================
    # RESTAURACIÓN QUIRÚRGICA VÍA SDDL (Prioridad Absoluta)
    # =========================================================
    if ($wasTracked) {
        try {
            $originalSddl = $Script:SDDL_Backups[$subPath]
            $rights = [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::TakeOwnership
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
            
            if ($keyObj) {
                $aclRestored = New-Object System.Security.AccessControl.RegistrySecurity
                $aclRestored.SetSecurityDescriptorSddlForm($originalSddl)
                $keyObj.SetAccessControl($aclRestored)
                
                # Write-Log -LogLevel INFO -Message "Restauracion SDDL Limpia: $subPath"
                $Script:SDDL_Backups.Remove($subPath)
                return
            }
        } catch {
            Write-Log -LogLevel WARN -Message "Fallo restauracion SDDL en $subPath. Aplicando Fallback clasico."
        } finally {
            if ($null -ne $keyObj) { $keyObj.Dispose(); $keyObj = $null }
        }
    }

    # =========================================================
    # RESTAURACIÓN CLÁSICA / FALLBACK (Sin tocar herencia)
    # =========================================================
    $sidAdmin   = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $sidTrusted = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
    
    $isUserHive  = $subPath -match "^OfflineUser(\\|$)"
    # Cualquier clave de politicas de grupo (GPO) queda en Administradores como red
    # de seguridad adicional -- en Windows real, Policies\* nunca es propiedad de
    # TrustedInstaller. Pero el criterio general es "-not $wasTracked": si la clave
    # nunca paso por Unlock-OfflineKey (no hay SDDL original respaldado), no existe
    # ninguna posesion previa que restaurar -- forzar TrustedInstaller ahi seria
    # inventar una restauracion de algo que esta herramienta nunca desbloqueo. Esto
    # cubre CUALQUIER clave recien creada, sea cual sea su ruta, no solo Policies.
    $isPolicyKey = $subPath -match "(?i)\\Policies(\\|$)"
    $targetOwner = if ($isUserHive -or $isPolicyKey -or -not $wasTracked) { $sidAdmin } else { $sidTrusted }

    try {
        # Paso 1: Tomar posesion TEMPORAL para nosotros mismos. SeTakeOwnershipPrivilege/
        # SeRestorePrivilege permiten este WRITE_OWNER sin importar la DACL actual, pero
        # ChangePermissions (WRITE_DAC) NO esta cubierto por esos privilegios: solo el
        # propietario ACTUAL de la clave recibe WRITE_DAC de forma implicita. Por eso hay
        # que tomar posesion ANTES de poder tocar permisos, no despues (orden invertido
        # respecto a la version anterior, que fallaba con Acceso Denegado en claves cuyo
        # dueño actual no era ya el proceso, p.ej. claves recien creadas por Unlock-OfflineKey).
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $acl.SetOwner($sidAdmin)
            $keyObj.SetAccessControl($acl)
            $keyObj.Dispose(); $keyObj = $null
        }

        # Paso 2: Ahora que somos propietarios, WRITE_DAC esta disponible de forma
        # implicita -> retirar TODAS las reglas de Administradores sin modificar la herencia
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($keyObj) {
            # Solo Access: evitar solicitar SACL (requiere SeSecurityPrivilege y lanza
            # InvalidOperationException en claves sin ese derecho explícito)
            $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $acl.PurgeAccessRules($sidAdmin)
            $keyObj.SetAccessControl($acl)
            $keyObj.Dispose(); $keyObj = $null
        }

        # Paso 3: Devolver el propietario final a TrustedInstaller (Si es de sistema).
        # SeRestorePrivilege permite asignar un SID arbitrario como propietario sin
        # importar quien lo tenga ahora mismo.
        if (-not $isUserHive) {
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($keyObj) {
                $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
                $acl.SetOwner($targetOwner)
                $keyObj.SetAccessControl($acl)
            }
        }
    } catch {
        Write-Log -LogLevel ERROR -Message "Fallo en Restore-KeyOwner ($subPath): $($_.Exception.Message)"
    } finally {
        if ($null -ne $keyObj) { $keyObj.Dispose() }
    }
}

function Restore-AllOfflineSDDL {
    $totalPendientes = $Script:SDDL_Backups.Count
    
    if ($totalPendientes -eq 0) {
        Write-Log -LogLevel INFO -Message "Restaurador SDDL: No hay permisos pendientes de restauracion."
        return
    }

    Write-Log -LogLevel ACTION -Message "Restaurador SDDL: Iniciando inyeccion de $totalPendientes descriptores de seguridad (ACLs)..."
    
    # Usamos Stopwatch para medir el tiempo real de la restauración
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    foreach ($p in @($Script:SDDL_Backups.Keys)) {
        Restore-KeyOwner -KeyPath "HKLM:\$p"
    }
    
    $stopwatch.Stop()
    $tiempoRestauracion = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)
    
    $Script:SDDL_Backups.Clear()
    
    Write-Log -LogLevel INFO -Message "Restaurador SDDL: OK — $totalPendientes claves protegidas. (Tiempo: $tiempoRestauracion segundos)"
}

function Unlock-Single-File {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    
    # [Fix 3] Guard de inicialización de la variable global
    if ($null -eq $Script:FileSDDL_Backups) {
        $Script:FileSDDL_Backups = @{}
    }

    # [Fix 4] Normalización de ruta para usarla como clave exacta en el diccionario
    $normalizedPath = [System.IO.Path]::GetFullPath($FilePath).ToLowerInvariant()
    
    Enable-Privileges
    
    $fileInfo = New-Object System.IO.FileInfo($FilePath)

    # --- PASO 1: RESPALDAR SDDL ---
    try {
        $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
        $originalAcl = $fileInfo.GetAccessControl($sections)
        
        if (-not $Script:FileSDDL_Backups.ContainsKey($normalizedPath)) {
            $Script:FileSDDL_Backups[$normalizedPath] = $originalAcl.GetSecurityDescriptorSddlForm($sections)
            Write-Log -LogLevel INFO -Message "FileUnlocker: SDDL original de '$($fileInfo.Name)' respaldado en memoria."
        }
    } catch {
        Write-Log -LogLevel WARN -Message "FileUnlocker: Fallo al leer SDDL original de '$FilePath' - $($_.Exception.Message)"
    }

    # --- PASO 2: TOMAR POSESIÓN Y CONTROL TOTAL ---
    try {
        $p1 = Start-Process "takeown.exe" -ArgumentList "/F `"$FilePath`" /A" -Wait -PassThru -WindowStyle Hidden
        # [Fix 1] Uso de notación SID universal para el grupo de Administradores
        $p2 = Start-Process "icacls.exe" -ArgumentList "`"$FilePath`" /grant *S-1-5-32-544:F /Q" -Wait -PassThru -WindowStyle Hidden
        
        if ($p1.ExitCode -eq 0 -and $p2.ExitCode -eq 0) {
            Write-Log -LogLevel ACTION -Message "FileUnlocker: Control total obtenido sobre '$($fileInfo.Name)' via SID."
            
            # [Fix 2] Aislamiento del cambio de atributos
            try {
                $fileInfo.Attributes = [System.IO.FileAttributes]::Normal
            } catch {
                Write-Log -LogLevel WARN -Message "FileUnlocker: No se pudieron quitar atributos de '$($fileInfo.Name)' - $($_.Exception.Message)"
            }
        } else {
            throw "takeown (Exit: $($p1.ExitCode)) o icacls (Exit: $($p2.ExitCode)) devolvieron errores de ejecución."
        }
    } catch {
        Write-Log -LogLevel ERROR -Message "FileUnlocker: Falla critica intentando tomar control del archivo '$FilePath' - $($_.Exception.Message)"
    }
}

function Restore-FileOwner {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )
    
    if (-not (Test-Path -LiteralPath $FilePath)) { return }
    
    # [Fix 3] Guard de inicialización
    if ($null -eq $Script:FileSDDL_Backups) {
        $Script:FileSDDL_Backups = @{}
    }

    # [Fix 4] Normalización de ruta
    $normalizedPath = [System.IO.Path]::GetFullPath($FilePath).ToLowerInvariant()
    
    Enable-Privileges
    
    # =========================================================
    # RESTAURACIÓN QUIRÚRGICA VÍA SDDL (Prioridad Absoluta)
    # =========================================================
    if ($Script:FileSDDL_Backups.ContainsKey($normalizedPath)) {
        try {
            $originalSddl = $Script:FileSDDL_Backups[$normalizedPath]
            
            $fileSec = New-Object System.Security.AccessControl.FileSecurity
            $fileSec.SetSecurityDescriptorSddlForm($originalSddl)
            
            [System.IO.File]::SetAccessControl($FilePath, $fileSec)
            
            Write-Log -LogLevel INFO -Message "FileRestorer: Permisos restaurados limpiamente via SDDL para '$([System.IO.Path]::GetFileName($FilePath))'."
            $Script:FileSDDL_Backups.Remove($normalizedPath)
            return
        } catch {
            Write-Log -LogLevel WARN -Message "FileRestorer: Fallo restauracion SDDL. Aplicando Fallback manual (TrustedInstaller)."
        }
    }

    # =========================================================
    # RESTAURACIÓN DE EMERGENCIA (Fallback a TrustedInstaller)
    # =========================================================
    try {
        # [Fix 5] Captura y validación de Exit Codes de los subprocesos
        $p1 = Start-Process "icacls.exe" -ArgumentList "`"$FilePath`" /setowner `"NT SERVICE\TrustedInstaller`" /Q" -Wait -PassThru -WindowStyle Hidden
        if ($p1.ExitCode -ne 0) { Write-Log -LogLevel WARN -Message "FileRestorer: icacls setowner devolvió codigo $($p1.ExitCode)." }

        $p2 = Start-Process "icacls.exe" -ArgumentList "`"$FilePath`" /grant:r `"NT SERVICE\TrustedInstaller`":F /Q" -Wait -PassThru -WindowStyle Hidden
        if ($p2.ExitCode -ne 0) { Write-Log -LogLevel WARN -Message "FileRestorer: icacls grant devolvió código $($p2.ExitCode)." }

        # [Fix 1] Uso del SID universal para la remoción del grupo Administradores local
        $p3 = Start-Process "icacls.exe" -ArgumentList "`"$FilePath`" /remove *S-1-5-32-544 /Q" -Wait -PassThru -WindowStyle Hidden
        if ($p3.ExitCode -ne 0) { Write-Log -LogLevel WARN -Message "FileRestorer: icacls remove devolvió código $($p3.ExitCode)." }

        Write-Log -LogLevel ACTION -Message "FileRestorer: Propiedad de emergencia devuelta a TrustedInstaller."
    } catch {
        Write-Log -LogLevel ERROR -Message "FileRestorer: Error en Fallback de icacls - $($_.Exception.Message)"
    }
}

function Get-OfflineControlSet { 
    if ($null -ne $Script:CachedControlSet) {
        return $Script:CachedControlSet
    }

    if (-not (Test-Path "HKLM:\OfflineSystem")) {
        Write-Log -LogLevel WARN -Message "Get-OfflineControlSet: OfflineSystem no esta montado. Imposible determinar ControlSet."
        return "ControlSet001"   # fallback seguro: evita null propagandose a los callers
    }

    $SystemHivePath = "HKLM:\OfflineSystem"
    $currentSet     = 1
    
    if (Test-Path "$SystemHivePath\Select") {
        try {
            $props = Get-ItemProperty -Path "$SystemHivePath\Select" -ErrorAction SilentlyContinue
            if ($props -and $null -ne $props.Current) {
                $currentSet = [int]$props.Current   # cast explícito: evita fallo de -f d3 con strings
            }
        } catch {
            Write-Log -LogLevel WARN -Message "Get-OfflineControlSet: No se pudo leer HKLM:\OfflineSystem\Select. Usando ControlSet001."
        }
    }
    
    $Script:CachedControlSet = "ControlSet{0:d3}" -f $currentSet
    return $Script:CachedControlSet
}

# Funcion auxiliar de Check y Reparacion Montaje
function Check-And-Repair-Mounts {
    Write-Host (Get-AIOString 'mounts_repair.checking_wim') -ForegroundColor DarkGray
    if ($Script:IMAGE_MOUNTED -eq 2) { return }
    if (Test-AIOHostWinREProtectedMount -Path $Script:MOUNT_DIR) {
        Write-Log -LogLevel INFO -Message 'MountRepair: Se omite la recuperacion automatica por la comprobacion de WinRE del host.'
        return
    }
    try {
        $mounts = @(Get-AIOMountedImages)
        $current = Get-AIOMountForPath -Mounts $mounts -Path $Script:MOUNT_DIR
        if (Test-AIOHostWinREProtectedMount -Path $Script:MOUNT_DIR -Mount $current) { return }
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel WARN -Message "MountRepair: No se pudo consultar DISM: $($_.Exception.Message)"
        return
    }

    # Un montaje de otra herramienta no representa el estado de MOUNT_DIR.
    if ($null -eq $current) { return }
    $updated = $current
    if ($current.Status -eq 'OK') {
        if ($Script:IMAGE_MOUNTED -eq 1) { return }
    } elseif ($current.Status -in @('Needs Remount', 'Invalid')) {
        $msgResult = [System.Windows.Forms.MessageBox]::Show(
            (Get-AIOString 'mounts_repair.dialog_body' $current.Status $Script:MOUNT_DIR),
            (Get-AIOString 'mounts_repair.dialog_title'), 'YesNoCancel', 'Warning'
        )
        if ($msgResult -eq 'No') {
            Repair-InvalidMounts
            return
        }
        if ($msgResult -ne 'Yes') { return }

        Write-Host (Get-AIOString 'mounts_repair.attempting_remount') -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "MountRepair: Iniciando Remount-Image de '$($current.ImageFile)', indice $($current.ImageIndex), en '$Script:MOUNT_DIR'."
        try {
            $remountResult = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -WaitForToolOnly -Arguments @('/Remount-Image',"/MountDir:$Script:MOUNT_DIR",'/English')
            $remountCode = $remountResult.ExitCode
            Write-Log -LogLevel INFO -Message "MountRepair: Remount-Image termino con codigo $remountCode."
        } catch {
            Write-Warning (Get-AIOString 'mounts_repair.remount_exec_err' $_.Exception.Message)
            Write-Log -LogLevel ERROR -Message "MountRepair: Error ejecutando Remount-Image: $($_.Exception.Message)"
            return
        }
        if ($remountCode -ne 0) {
            Write-Warning (Get-AIOString 'mounts_repair.remount_failed_code' $remountCode)
            Write-Log -LogLevel ERROR -Message "MountRepair: Remount-Image fallo en '$Script:MOUNT_DIR': $remountCode"
            return
        }
        Write-Host (Get-AIOString 'mounts_repair.dism_done_verifying' $Script:MOUNT_DIR) -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "MountRepair: Consultando Get-MountedImageInfo despues del remonte."
        try {
            $updated = Get-AIOMountForPath -Mounts @(Get-AIOMountedImages) -Path $Script:MOUNT_DIR
            Write-Log -LogLevel INFO -Message "MountRepair: Inventario recibido. Estado='$($updated.Status)'."
        } catch {
            Write-Warning $_.Exception.Message
            Write-Log -LogLevel WARN -Message "MountRepair: Fallo al volver a consultar el inventario: $($_.Exception.Message)"
            return
        }
    } else {
        Write-Warning (Get-AIOString 'mounts_repair.status_unrecognized' $Script:MOUNT_DIR $current.Status)
        return
    }
    try {
        if ($null -eq $updated -or $updated.Status -ne 'OK' -or -not (Test-Path -LiteralPath $updated.MountDir -PathType Container)) {
            throw 'DISM finalizo, pero el punto solicitado todavia no figura como OK y accesible.'
        }
        if ($updated.ReadWrite -ne 'Yes' -or [string]::IsNullOrWhiteSpace($updated.ImageFile) -or $updated.ImageIndex -lt 1) {
            throw 'La sesion no se puede usar para edicion: es de solo lectura o sus metadatos estan incompletos.'
        }
        if (($current.ImageIndex -gt 0 -and $current.ImageIndex -ne $updated.ImageIndex) -or
            ($current.ImageFile -and (ConvertTo-AIOMountPath $current.ImageFile) -ne (ConvertTo-AIOMountPath $updated.ImageFile)) -or
            (Test-AIOHostWinREProtectedMount -Path $Script:MOUNT_DIR -Mount $updated)) {
            throw 'La imagen o el indice del montaje cambio o esta protegido.'
        }
        $Script:IMAGE_MOUNTED = 1
        $Script:WIM_FILE_PATH = $updated.ImageFile
        $Script:MOUNTED_INDEX = $updated.ImageIndex
        $Script:CachedControlSet = $null
        $Script:AIODashboardCache = $null
        $Script:ForceMenuRefresh = $false
        Write-Host (Get-AIOString 'mounts_repair.recovered_ok') -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "MountRepair: Sesion recuperada en '$Script:MOUNT_DIR'."
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel WARN -Message "MountRepair: No se pudo validar la sesion recuperada: $($_.Exception.Message)"
    }
}

# --- Helper: ejecutar una funcion que requiere imagen montada ---
function Invoke-IfMounted {
    param(
        [string]$FuncLabel,
        [scriptblock]$Action
    )
    if ($Script:IMAGE_MOUNTED) {
        Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a '$FuncLabel'"
        & $Action
    } else {
        Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a $FuncLabel denegado (No hay imagen montada)."
        Show-Mount-Warning
    }
}

# --- Submenu: Herramientas de Arranque y Medios --
function Boot-Tools-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'menu.boot_tools.title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host (Get-AIOString 'menu.boot_tools.opt1') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.boot_tools.opt1_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.boot_tools.opt2') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.boot_tools.opt2_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.boot_tools.opt3') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.boot_tools.opt3_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'menu.boot_tools.opt4') -ForegroundColor White
        Write-Host (Get-AIOString 'menu.boot_tools.opt4_desc') -ForegroundColor Gray
        Write-Host ""
        Write-Host (Get-AIOString 'common.back_main') -ForegroundColor Red
        Write-Host ""

        $bootOpt = (Read-MenuOption (Get-AIOString 'common.select_option_spaced')).Trim().ToUpper()
        switch ($bootOpt) {
            "1" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Manage-BootWim-Menu'"; Manage-BootWim-Menu }
            "2" { Invoke-IfMounted "Manage-WinRE-Menu" { Manage-WinRE-Menu } }
            "3" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-IsoMaker-GUI'"; Show-IsoMaker-GUI }
            "4" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-Deploy-To-VHD-GUI'"; Show-Deploy-To-VHD-GUI }
            "V" { Write-Log -LogLevel INFO -Message "MenuBoot: Volviendo al menu principal"; return }
            default {
                Write-Log -LogLevel WARN -Message "MenuBoot: Opcion invalida seleccionada ($bootOpt)."
                Write-Warning (Get-AIOString 'common.invalid_option_short')
            }
        }
    }
}

# :main_menu (Funcion principal que muestra el menu inicial)
function Main-Menu {
    $Host.UI.RawUI.WindowTitle = "AdminImagenOffline v$($script:Version) by SOFTMAXTER"

    # --- Constantes de presentacion (calculadas una sola vez, fuera del bucle) ---
    $width        = 80
    $separator    = "=" * $width
    $separatorMid = "-" * $width
    $verStr       = "v$($script:Version)"
    $auth         = "by SOFTMAXTER"

    while ($true) {
        $title = Get-AIOString 'menu.main.title'
        $metadata = Get-AIOCachedDashboardMetadata -MountState $Script:IMAGE_MOUNTED -MountPath $Script:MOUNT_DIR `
            -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ForceRefresh:$Script:ForceMenuRefresh
        # Consumir la solicitud una sola vez; la navegacion conserva la cache.
        $Script:ForceMenuRefresh = $false

        # --- 2. INTERFAZ GRÁFICA (Dashboard) ---
        # [FIX] Todos los separadores usan ahora $separator / $separatorMid (antes dos de ellos eran literales hardcodeados)
        Clear-Host
        Write-Host $separator -ForegroundColor Cyan
        Write-Host (" " * [math]::Floor(($width - $title.Length)  / 2) + $title)  -ForegroundColor Cyan
        Write-Host (" " * [math]::Floor(($width - $verStr.Length) / 2) + $verStr) -ForegroundColor Gray
        Write-Host (" " * [math]::Floor(($width - $auth.Length)   / 2) + $auth)   -ForegroundColor White
        Write-Host $separator -ForegroundColor Cyan
        
        # Panel de Estado
        Write-Host ""
        Write-Host (Get-AIOString 'menu.main.status_header') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.main.source_label') -NoNewline
        if ($Script:WIM_FILE_PATH) {
            $displayPath = if ($Script:WIM_FILE_PATH.Length -gt 60) { "..." + $Script:WIM_FILE_PATH.Substring($Script:WIM_FILE_PATH.Length - 60) } else { $Script:WIM_FILE_PATH }
            Write-Host $displayPath -ForegroundColor White
        } else { Write-Host (Get-AIOString 'menu.main.source_none') -ForegroundColor DarkGray }

        Write-Host (Get-AIOString 'menu.main.mount_label') -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host (Get-AIOString 'menu.main.mount_wim_active') -ForegroundColor Green   -NoNewline; Write-Host (Get-AIOString 'menu.main.mount_wim_index' $Script:MOUNTED_INDEX) -ForegroundColor Gray }
            2 { Write-Host (Get-AIOString 'menu.main.mount_vhd_active') -ForegroundColor Magenta -NoNewline; Write-Host (Get-AIOString 'menu.main.mount_vhd_mode') -ForegroundColor Gray }
            Default { Write-Host (Get-AIOString 'common.status_not_mounted') -ForegroundColor Red }
        }
        Write-Host ""

        # Mostrar detalles solo si esta montado
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-AIODashboardMetadata -Metadata $metadata -MountPath $Script:MOUNT_DIR -Width $width
        }
        Write-Host $separator -ForegroundColor Cyan
        Write-Host ""

        if ($Script:AIOHostWinREAttentionRequired) {
            Write-Host (Get-AIOString 'startup.winre_notice_line1') -ForegroundColor Yellow
            Write-Host (Get-AIOString 'startup.winre_notice_line2') -ForegroundColor Gray
            Write-Host ''
        }

        # Menu de Opciones
        Write-Host (Get-AIOString 'menu.main.section_image') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.main.opt1')
        Write-Host (Get-AIOString 'menu.main.opt2')
        Write-Host (Get-AIOString 'menu.main.opt3')
        Write-Host (Get-AIOString 'menu.main.opt4') -ForegroundColor Green
        Write-Host ""
        Write-Host (Get-AIOString 'menu.main.section_engineering') -ForegroundColor Yellow
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host (Get-AIOString 'menu.main.opt5_on')  -ForegroundColor White
            Write-Host (Get-AIOString 'menu.main.opt6_on')  -ForegroundColor White
            Write-Host (Get-AIOString 'menu.main.opt7_on')  -ForegroundColor White
            Write-Host (Get-AIOString 'menu.main.opt8_on')  -ForegroundColor White
            Write-Host (Get-AIOString 'menu.main.opt9_on')  -ForegroundColor White
            Write-Host (Get-AIOString 'menu.main.opt10_on') -ForegroundColor White
        } else {
            # Opciones deshabilitadas visualmente
            Write-Host (Get-AIOString 'menu.main.opt5_off')  -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'menu.main.opt6_off')  -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'menu.main.opt7_off')  -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'menu.main.opt8_off')  -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'menu.main.opt9_off')  -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'menu.main.opt10_off') -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host (Get-AIOString 'menu.main.section_system') -ForegroundColor Yellow
        Write-Host (Get-AIOString 'menu.main.opt_config')
        Write-Host ""
        Write-Host $separatorMid
        Write-Host (Get-AIOString 'menu.main.footer') -ForegroundColor Gray
        Write-Host ""

        # [FIX] .Trim() antes de .ToUpper() para tolerar espacios accidentales en el input
        $prompt  = if ($Script:IMAGE_MOUNTED -gt 0) { Get-AIOString 'menu.main.prompt_ready' } else { Get-AIOString 'menu.main.prompt_idle' }
        $opcionM = (Read-Host " $prompt").Trim().ToUpper()
        
        # Manejo de Errores y Navegacion
        switch ($opcionM) {
            "1"  { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Image-Management-Menu'";  Image-Management-Menu  }
            "2"  { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Convert-Image-Menu'";     Convert-Image-Menu     }
            "3"  { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Boot-Tools-Menu'";        Boot-Tools-Menu        }
            "4"  { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Updates-Languages-Menu'"; Updates-Languages-Menu }
            "5"  { Invoke-IfMounted "Drivers-Menu"        { Drivers-Menu        } }
            "6"  { Invoke-IfMounted "Content-Menu"        { Content-Menu        } }
            "7"  { Invoke-IfMounted "System-Tweaks-Menu"  { System-Tweaks-Menu  } }
            "8"  { Invoke-IfMounted "OOBE-Branding-Menu"  { OOBE-Branding-Menu  } }
            "9"  { Invoke-IfMounted "Limpieza-Menu"       { Limpieza-Menu       } }
            "10" { Invoke-IfMounted "Cambio-Edicion-Menu" { Cambio-Edicion-Menu } }
            "C"  { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Show-ConfigMenu'"; Show-ConfigMenu }
            "L" {
                if ($null -ne $script:logFile -and (Test-Path $script:logFile)) {
                    Write-Log -LogLevel INFO -Message "MenuMain: El usuario abrio el archivo de Log principal."
                    Start-Process notepad.exe -ArgumentList $script:logFile
                } else {
                    Write-Log -LogLevel ERROR -Message "MenuMain: Intento de abrir el log fallido. El archivo no existe aun."
                    [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'menu.main.log_missing'), (Get-AIOString 'common.error_title'), 'OK', 'Error')
                }
            }
            "H" {
                $msg = Get-AIOString 'menu.main.about_body' $script:Version
                [System.Windows.Forms.MessageBox]::Show($msg, (Get-AIOString 'menu.main.about_title'), 0, 64)
            }
            "S" { 
                Write-Log -LogLevel ACTION -Message "MenuMain: El usuario inicio la secuencia de salida del programa."
                if ($Script:IMAGE_MOUNTED -gt 0) {
                    [System.Console]::Beep(500, 300)
                    $confirmExit = Read-Host (Get-AIOString 'menu.main.exit_mounted_prompt')
                    
                    if (Test-AIOYesResponse $confirmExit) {
                        Write-Log -LogLevel ACTION -Message "MenuExit: El usuario acepto desmontar (con guardado) antes de salir."
                        Unmount-Image -Commit
                        
                        # Validacion post-desmontaje (Previene el cierre si fallo DISM)
                        if ($Script:IMAGE_MOUNTED -eq 0) { exit }
                        else {
                            Write-Log -LogLevel WARN -Message "MenuExit: Abortando salida. El desmontaje fracasó."
                            Write-Warning (Get-AIOString 'menu.main.exit_dism_failed')
                            Start-Sleep -Seconds 3
                        }
                    }
                    elseif (Test-AIONoResponse $confirmExit) {
                        Write-Log -LogLevel ERROR -Message "MenuExit: ALERTA - El usuario forzo la salida dejando una imagen montada (Huerfana)."
                        Write-Warning (Get-AIOString 'menu.main.exit_orphan_warn')
                        Start-Sleep -Seconds 2
                        exit
                    }
                    else {
                        Write-Log -LogLevel INFO -Message "MenuExit: El usuario cancelo la salida. Volviendo al menu."
                    }
                } else {
                    Write-Log -LogLevel INFO -Message "MenuExit: Saliendo del programa limpiamente (Sin imagenes montadas)."
                    Write-Host (Get-AIOString 'menu.main.goodbye') -ForegroundColor Green
                    Start-Sleep -Seconds 1
                    exit 
                }
            }
            default { 
                Write-Host (Get-AIOString 'common.invalid_option_retry') -ForegroundColor Red -BackgroundColor Black
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

# Pequeña funcion auxiliar para evitar repetir el mensaje de error
function Show-Mount-Warning {
    [System.Console]::Beep(400, 200)
    Write-Host (Get-AIOString 'common.mount_blocked') -ForegroundColor Yellow -BackgroundColor DarkRed
    Start-Sleep -Seconds 2
}

function Invoke-AIOConsoleSystemTool {
    param(
        [Parameter(Mandatory=$true)][ValidateSet('dism.exe','reagentc.exe')][string]$Tool,
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string[]]$Arguments,
        [switch]$WaitForToolOnly
    )
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'No se conoce SystemRoot del anfitrion.' }
    $systemFolder = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemFolder = 'Sysnative' }
    $exe = Join-Path $env:SystemRoot "$systemFolder\$Tool"
    # Start-Process une ArgumentList en una cadena. Proteger espacios, comillas
    # y barras finales segun las reglas de argumentos nativos de Windows.
    $commandLine = (@($Arguments | ForEach-Object {
        $escaped = [regex]::Replace($_, '(\\*)"', '$1$1\"')
        $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
        '"' + $escaped + '"'
    }) -join ' ')
    $process = $null
    try {
        # El hijo hereda la consola incluso si el caller captura este resultado.
        # No redirigir stdout/stderr: DISM conserva su progreso en la misma linea.
        # Usar siempre Process.Start + WaitForExit sobre el PID directo de la herramienta
        # (evita que Start-Process -Wait quede colgado esperando procesos auxiliares como wimserv.exe).
        $start = New-Object System.Diagnostics.ProcessStartInfo
        $start.FileName = $exe
        $start.Arguments = $commandLine
        $start.UseShellExecute = $false
        $process = [Diagnostics.Process]::Start($start)
        if ($null -eq $process) { throw "No se pudo iniciar $Tool." }
        if ($WaitForToolOnly) {
            Write-Log -LogLevel INFO -Message "ConsoleTool: $Tool iniciado, PID=$($process.Id)."
            while (-not $process.WaitForExit(30000)) {
                Write-Host (Get-AIOString 'core.waiting_tool' $Tool $process.Id) -ForegroundColor DarkGray
            }
        } else {
            $process.WaitForExit()
        }
        if ($null -eq $process -or $null -eq $process.ExitCode) { throw "No se obtuvo el codigo de salida de $Tool." }
        [pscustomobject]@{ ExitCode = [int]$process.ExitCode }
    } finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

# --- Comprobacion de WinRE del anfitrion antes de recuperar imagenes anteriores ---
function ConvertTo-AIOHostWinREPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $value = $Path.Trim().Replace('/', '\')
    if ($value.StartsWith('\??\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\?\' + $value.Substring(4)
    } elseif ($value.StartsWith('\Device\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\?\GLOBALROOT' + $value
    }
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    } elseif ($value.StartsWith('\\?\') -and $value.Substring(4) -match '^[A-Za-z]:\\') {
        $value = $value.Substring(4)
    }
    # Nunca convertir GLOBALROOT/Volume en una ruta relativa al directorio actual.
    if ($value -notmatch '^(?:[A-Za-z]:\\|\\\\)' -or $value -match '(?:^|\\)\.\.?(?:\\|$)') { return '' }
    return $value.TrimEnd('\')
}

function Initialize-AIOHostWinREPathNative {
    if (([System.Management.Automation.PSTypeName]'AIOHostWinREPathNative').Type) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class AIOHostWinREPathNative {
    [DllImport("kernel32.dll", EntryPoint="CreateFileW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern SafeFileHandle CreateFile(string path, uint access, uint share,
        IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", EntryPoint="GetFinalPathNameByHandleW", ExactSpelling=true, CharSet=CharSet.Unicode, SetLastError=true)]
    private static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder path, uint length, uint flags);
    public static string Resolve(string path) {
        // Solo consulta: acceso 0, compartir lectura/escritura/borrado, OPEN_EXISTING.
        using (SafeFileHandle handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero)) {
            if (handle.IsInvalid) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            StringBuilder buffer = new StringBuilder(1024);
            uint length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 2);
            if (length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
            if (length >= buffer.Capacity) {
                buffer = new StringBuilder(checked((int)length + 1));
                length = GetFinalPathNameByHandle(handle, buffer, (uint)buffer.Capacity, 2);
                if (length == 0) { throw new Win32Exception(Marshal.GetLastWin32Error()); }
                if (length >= buffer.Capacity) { throw new InvalidOperationException("La ruta cambio durante la consulta."); }
            }
            return buffer.ToString(); // VOLUME_NAME_NT: no depende de letras de unidad.
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Get-AIOHostWinREPathIdentity {
    param([string]$Path)
    $normalized = ConvertTo-AIOHostWinREPath $Path
    if (-not $normalized) { return '' }
    try {
        # FILE_FLAG_BACKUP_SEMANTICS solo aprovecha privilegios ya activados.
        Enable-Privileges -Privileges @('SeBackupPrivilege')
        Initialize-AIOHostWinREPathNative
        return [AIOHostWinREPathNative]::Resolve($normalized).TrimEnd('\')
    } catch {
        # Una coincidencia de nombres o rutas inaccesibles no prueba identidad.
        return ''
    }
}

function Invoke-AIOHostWinREReAgent {
    param([Parameter(Mandatory=$true)][string[]]$Arguments)
    $systemFolder = 'System32'
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { $systemFolder = 'Sysnative' }
    $exe = Join-Path $env:SystemRoot "$systemFolder\reagentc.exe"
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    $lines = @(& $exe @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { throw 'No se pudo ejecutar reagentc.exe del anfitrion.' }
    [pscustomobject]@{ ExitCode=[int]$exitCode; Lines=$lines }
}

function Get-AIOHostWinREAgentDocument {
    $xmlPath = Join-Path $env:SystemRoot 'System32\Recovery\ReAgent.xml'
    if (-not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) { return $null }
    $document = New-Object System.Xml.XmlDocument
    $document.XmlResolver = $null
    $document.LoadXml((Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop))
    if ($null -eq $document.SelectSingleNode('/WindowsRE')) { throw 'ReAgent.xml no contiene la configuracion WindowsRE esperada.' }
    return ,$document
}

function Get-AIOHostWinREMountHint {
    # Este dato solo elige ReAgentC DESPUES de confirmar el archivo en DISM.
    $document = Get-AIOHostWinREAgentDocument
    if ($null -eq $document) { return '' }
    return ConvertTo-AIOHostWinREPath ([string]$document.WindowsRE.WinreMount.path)
}

function Get-AIOHostWinRELocationPaths {
    param([Parameter(Mandatory=$true)][System.Xml.XmlElement]$Location)
    # Los GUID de ReAgent.xml identifican DISCOS, no nombres Volume{GUID}.
    # En MBR, id es la firma del disco; offset identifica su particion.
    $relative = $Location.GetAttribute('path').Replace('/', '\')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.StartsWith('\\') -or
        $relative -match '[:*?"<>|\x00-\x1f]' -or $relative -match '(?:^|\\)\.\.?(?:\\|$)') { return }
    $relative = $relative.Trim('\')
    if (-not $relative) { return }
    if (-not $relative.EndsWith('\winre.wim', [StringComparison]::OrdinalIgnoreCase) -and $relative -ine 'winre.wim') {
        $relative += '\winre.wim'
    }
    $diskGuid = [guid]::Empty
    $offset = [uint64]0
    if (-not [guid]::TryParse($Location.GetAttribute('guid'), [ref]$diskGuid) -or
        -not [uint64]::TryParse($Location.GetAttribute('offset'), [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$offset) -or $offset -eq 0) { return }
    if ($diskGuid -ne [guid]::Empty) {
        $disks = @(Get-Disk -ErrorAction Stop | Where-Object {
            $candidateGuid = [guid]::Empty
            ([string]$_.PartitionStyle -in @('GPT','2')) -and
                [guid]::TryParse([string]$_.Guid, [ref]$candidateGuid) -and $candidateGuid -eq $diskGuid
        })
    } else {
        $signature = [uint32]0
        if (-not [uint32]::TryParse($Location.GetAttribute('id'), [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$signature) -or $signature -eq 0) { return }
        $disks = @(Get-Disk -ErrorAction Stop | Where-Object {
            ([string]$_.PartitionStyle -in @('MBR','1')) -and $_.Signature -eq $signature
        })
    }
    if ($disks.Count -gt 1) { throw 'Varios discos coinciden con ReAgent.xml. No se puede confirmar el origen de WinRE.' }
    if ($disks.Count -eq 0) { return }
    $diskNumber = [uint32]0
    if (-not [uint32]::TryParse([string]$disks[0].Number, [ref]$diskNumber)) { return }
    $partitions = @(Get-Partition -DiskNumber $diskNumber -ErrorAction Stop | Where-Object {
        $_.DiskNumber -eq $diskNumber -and $_.Offset -eq $offset
    })
    if ($partitions.Count -gt 1) { throw 'Varias particiones coinciden con ReAgent.xml. No se puede confirmar el origen de WinRE.' }
    if ($partitions.Count -eq 0) { return }
    $roots = @($partitions[0].AccessPaths)
    # GLOBALROOT permite consultar una particion sin asignarle letra ni montarla.
    $partitionNumber = [uint32]0
    if ([uint32]::TryParse([string]$partitions[0].PartitionNumber, [ref]$partitionNumber) -and $partitionNumber -gt 0) {
        $roots += "\\?\GLOBALROOT\device\harddisk$diskNumber\partition$partitionNumber\"
    }
    @($roots | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            $path = ConvertTo-AIOHostWinREPath (([string]$_).TrimEnd('\') + '\' + $relative)
            if ($path) { $path }
        }
    } | Sort-Object -Unique)
}

function Get-AIOHostWinREConfiguration {
    if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { throw 'No se conoce SystemRoot del anfitrion.' }
    $query = Invoke-AIOHostWinREReAgent -Arguments @('/info')
    if ($query.ExitCode -ne 0) { throw "reagentc /info fallo (codigo $($query.ExitCode))." }
    $locations = @($query.Lines | ForEach-Object {
        # Acepta, entre otros, Windows RE location / Ubicacion de Windows RE.
        # No confundir Recovery image location (otra imagen) con Windows RE.
        if ($_ -match '^\s*[^:]*Windows\s*RE[^:]*:\s*(?<location>.*?)\s*$') {
            $path = ConvertTo-AIOHostWinREPath $matches['location']
            if ($path) { $path }
        }
    } | Sort-Object -Unique)
    if ($locations.Count -gt 1) { throw 'reagentc /info devolvio varias ubicaciones de Windows RE; no se elegira una por suposicion.' }
    $registeredPath = ''
    if ($locations.Count -eq 1) {
        $registeredPath = $locations[0]
        if (-not $registeredPath.EndsWith('\winre.wim', [StringComparison]::OrdinalIgnoreCase)) { $registeredPath += '\winre.wim' }
    }
    $registeredPaths = @()
    $registeredKeys = @()
    if ($registeredPath) {
        $registeredPaths += $registeredPath
        $key = Get-AIOHostWinREPathIdentity $registeredPath
        if ($key) { $registeredKeys += $key }
    }
    $document = Get-AIOHostWinREAgentDocument
    $mountHint = ''
    if ($null -ne $document) {
        $mountHint = ConvertTo-AIOHostWinREPath ([string]$document.WindowsRE.WinreMount.path)
        foreach ($name in @('WinreLocation', 'ImageLocation')) {
            $nodes = @($document.SelectNodes("/WindowsRE/$name"))
            if ($nodes.Count -gt 1) { throw "ReAgent.xml contiene varios nodos $name; el origen es ambiguo." }
            if ($nodes.Count -eq 0) { continue }
            $paths = @(Get-AIOHostWinRELocationPaths -Location $nodes[0])
            $keys = @($paths | ForEach-Object { Get-AIOHostWinREPathIdentity $_ } | Where-Object { $_ } | Sort-Object -Unique)
            if ($keys.Count -gt 1) { throw "Las rutas de la particion de $name resuelven a archivos diferentes. Se conserva el montaje." }
            $registeredPaths += $paths
            $registeredKeys += $keys
        }
    }
    $registeredPaths = @($registeredPaths | Sort-Object -Unique)
    $registeredKeys = @($registeredKeys | Sort-Object -Unique)
    $stagedPath = ConvertTo-AIOHostWinREPath (Join-Path $env:SystemRoot 'System32\Recovery\winre.wim')
    [pscustomobject]@{
        RegisteredPath  = $registeredPath
        RegisteredKey   = if ($registeredKeys.Count) { $registeredKeys[0] } else { '' }
        RegisteredPaths = $registeredPaths
        RegisteredKeys  = $registeredKeys
        StagedPath      = $stagedPath
        StagedKey       = Get-AIOHostWinREPathIdentity $stagedPath
        ReAgentMount    = $mountHint
    }
}

function Get-AIOHostWinREMountMatch {
    param([Parameter(Mandatory=$true)]$Mount, [Parameter(Mandatory=$true)]$Configuration)
    $mountPath = ConvertTo-AIOHostWinREPath $Mount.MountDir
    $imagePath = ConvertTo-AIOHostWinREPath $Mount.ImageFile
    $imageKey = Get-AIOHostWinREPathIdentity $Mount.ImageFile
    $registered = $imageKey -and (@($Configuration.RegisteredKeys) -icontains $imageKey)
    $staged = $imageKey -and $Configuration.StagedKey -and $imageKey -ieq $Configuration.StagedKey
    $hintMatches = $mountPath -and $Configuration.ReAgentMount -and $mountPath -ieq $Configuration.ReAgentMount
    [pscustomobject]@{
        Confirmed  = [bool]($registered -or $staged)
        Suspected  = [bool]($hintMatches -or ([string]$Mount.ImageFile -match '(?i)(?:^|[\\/])winre\.wim$') -or
            ($imagePath -and $imagePath -in (@($Configuration.RegisteredPaths) + @($Configuration.StagedPath))))
        UseReAgent = [bool](($registered -or $staged) -and $hintMatches -and $Mount.ImageIndex -eq 1)
        ImageKey   = $imageKey
        MountPath  = $mountPath
    }
}

function Test-AIOHostWinREProtectedMount {
    param([string]$Path, $Mount = $null)
    if ($Script:AIOHostWinRECheckFailed) { return $true }
    # Tambien excluir un WinRE que aparezca entre la comprobacion y la recuperacion.
    # El nombre solo sirve para CONSERVAR; nunca autoriza un desmontaje.
    if ($null -ne $Mount -and [string]$Mount.ImageFile -match '(?i)(?:^|[\\/])winre\.wim$') { return $true }
    $normalized = ConvertTo-AIOHostWinREPath $Path
    return [bool]($normalized -and $Script:AIOHostWinREProtectedMounts -icontains $normalized)
}

function Read-AIOHostWinREUnmountChoice {
    param([Parameter(Mandatory=$true)]$Mount)
    if ($Mount.ReadWrite -eq 'Yes') {
        Write-Host (Get-AIOString 'host_winre.opt_commit') -ForegroundColor Green
        Write-Host (Get-AIOString 'host_winre.opt_discard') -ForegroundColor Yellow
    } else {
        Write-Host (Get-AIOString 'host_winre.opt_readonly') -ForegroundColor Green
    }
    Write-Host (Get-AIOString 'host_winre.opt_keep') -ForegroundColor Cyan
    while ($true) {
        $choice = ([string](Read-Host (Get-AIOString 'common.select_option') -ErrorAction Stop)).Trim()
        if ($choice -eq '' -or $choice -eq '3') { return 'Keep' }
        if ($choice -eq '1') {
            if ($Mount.ReadWrite -eq 'Yes') { return 'Commit' }
            return 'Discard' # DISM exige Discard para cerrar una imagen de solo lectura.
        }
        if ($choice -eq '2' -and $Mount.ReadWrite -eq 'Yes') { return 'Discard' }
        Write-Host (Get-AIOString 'host_winre.invalid_unchanged') -ForegroundColor Yellow
    }
}

function Dismount-AIOHostWinREBeforeMenu {
    $Script:AIOHostWinREProtectedMounts = @()
    $Script:AIOHostWinRECheckFailed = $false
    $Script:AIOHostWinREAttentionRequired = $false
    try {
        $mounts = @(Get-AIOMountedImages)
        if ($mounts.Count -eq 0) { return }
        $configuration = Get-AIOHostWinREConfiguration
    } catch {
        $Script:AIOHostWinRECheckFailed = $true
        $Script:AIOHostWinREAttentionRequired = $true
        Write-Warning (Get-AIOString 'host_winre.verify_failed_warn' $_.Exception.Message)
        Write-Log -LogLevel WARN -Message "HostWinRECheck: Comprobacion incompleta; montajes intactos. $($_.Exception.Message)"
        return
    }

    foreach ($mount in $mounts) {
        try {
            $match = Get-AIOHostWinREMountMatch -Mount $mount -Configuration $configuration
            if (-not $match.Confirmed -and -not $match.Suspected) { continue }
            if (-not $match.MountPath) { throw 'DISM devolvio una carpeta de montaje no valida.' }
            $Script:AIOHostWinREProtectedMounts += $match.MountPath
            if (-not $match.Confirmed) {
                $Script:AIOHostWinREAttentionRequired = $true
                Write-Warning (Get-AIOString 'host_winre.unconfirmed_host_warn' $mount.ImageFile $mount.MountDir)
                Write-Log -LogLevel WARN -Message "HostWinRECheck: Origen no confirmado; se conserva '$($mount.MountDir)' ($($mount.ImageFile))."
                continue
            }
            Write-Host (Get-AIOString 'host_winre.confirmed_hdr') -ForegroundColor Yellow
            Write-Host (Get-AIOString 'host_winre.lbl_file' $mount.ImageFile) -ForegroundColor Gray
            Write-Host (Get-AIOString 'host_winre.lbl_mount' $mount.MountDir $mount.ImageIndex $mount.Status) -ForegroundColor Gray
            if ($mount.Status -ne 'OK' -or $mount.ReadWrite -notin @('Yes','No') -or $mount.ImageIndex -lt 1) {
                $Script:AIOHostWinREAttentionRequired = $true
                Write-Warning (Get-AIOString 'host_winre.manual_review_warn')
                Write-Log -LogLevel WARN -Message "HostWinRECheck: Se conserva '$($mount.MountDir)'; estado/permisos/indice no aptos para desmontaje."
                continue
            }
            $choice = Read-AIOHostWinREUnmountChoice -Mount $mount
            if ($choice -eq 'Keep') {
                $Script:AIOHostWinREAttentionRequired = $true
                Write-Log -LogLevel INFO -Message "HostWinRECheck: Usuario conserva '$($mount.MountDir)'; excluido de recuperacion automatica."
                continue
            }

            # Otra herramienta puede haber cambiado la carpeta durante la pregunta.
            # Revalidar inventario, origen del host, indice, permisos y metodo.
            $current = Get-AIOMountForPath -Mounts @(Get-AIOMountedImages) -Path $mount.MountDir
            if ($null -eq $current) {
                Write-Host (Get-AIOString 'host_winre.no_longer_listed') -ForegroundColor Gray
                continue
            }
            $freshConfig = Get-AIOHostWinREConfiguration
            $fresh = Get-AIOHostWinREMountMatch -Mount $current -Configuration $freshConfig
            if (-not $fresh.Confirmed -or $fresh.ImageKey -ine $match.ImageKey -or
                $fresh.MountPath -ine $match.MountPath -or $fresh.UseReAgent -ne $match.UseReAgent -or
                $current.ImageIndex -ne $mount.ImageIndex -or $current.ReadWrite -ne $mount.ReadWrite -or
                $current.Status -ne 'OK' -or -not (Test-Path -LiteralPath $current.MountDir -PathType Container)) {
                throw 'El montaje o la configuracion de WinRE cambio. Se cancelo el desmontaje para no actuar sobre otra imagen.'
            }

            Write-Host (Get-AIOString 'host_winre.unmounting' $choice) -ForegroundColor Cyan
            Write-Log -LogLevel ACTION -Message "HostWinRECheck: Usuario eligio /$choice para '$($current.MountDir)' ($($current.ImageFile))."
            # No descargar colmenas ajenas ni usar Cleanup-Mountpoints. Si otro
            # proceso mantiene archivos abiertos, conservar el error y el montaje.
            if ($fresh.UseReAgent) {
                $result = Invoke-AIOConsoleSystemTool -Tool 'reagentc.exe' -Arguments @('/unmountre','/path',$current.MountDir,"/$choice")
            } else {
                $result = Invoke-AIOConsoleSystemTool -Tool 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$($current.MountDir)","/$choice",'/English')
            }

            # El codigo de salida no reemplaza a la comprobacion del inventario.
            $remaining = Get-AIOMountForPath -Mounts @(Get-AIOMountedImages) -Path $current.MountDir
            if ($result.ExitCode -ne 0) { throw "El desmontaje devolvio el codigo $($result.ExitCode). No se reintentara con otro metodo ni se descartaran cambios automaticamente." }
            if ($null -ne $remaining) { throw 'DISM sigue registrando la carpeta. El desmontaje no se considera confirmado.' }
            if ($fresh.UseReAgent -and (Get-AIOHostWinREMountHint) -ieq $match.MountPath) {
                throw 'DISM ya no registra la carpeta, pero ReAgent.xml conserva el montaje. Se requiere revision manual.'
            }
            # Liberar solo esta ruta una vez verificadas todas las condiciones.
            # Los montajes conservados o pendientes siguen protegidos.
            $Script:AIOHostWinREProtectedMounts = @(
                $Script:AIOHostWinREProtectedMounts | Where-Object { $_ -ine $match.MountPath }
            )
            Write-Host (Get-AIOString 'host_winre.unmounted_ok') -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "HostWinRECheck: /$choice completado y ausencia en DISM verificada: '$($current.MountDir)'."
        } catch {
            # No declarar exito ni permitir que las rutas posteriores adopten
            # imagenes cuyo estado/origen no se pudo comprobar en esta sesion.
            $Script:AIOHostWinRECheckFailed = $true
            $Script:AIOHostWinREAttentionRequired = $true
            Write-Warning (Get-AIOString 'host_winre.unmount_unconfirmed' $mount.MountDir $_.Exception.Message)
            Write-Log -LogLevel ERROR -Message "HostWinRECheck: Se suspende la recuperacion automatica. $($_.Exception.Message)"
            return
        }
    }
}


# =================================================================
#  Verificacion de Montaje Existente
# =================================================================
$Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null

Write-Host (Get-AIOString 'core.checking_mounted') -ForegroundColor Gray

# --- PASO 0: COMPROBAR WINRE DEL HOST Y ELEGIR QUE HACER CON SUS CAMBIOS ---
Dismount-AIOHostWinREBeforeMenu

# --- PASO 1: DETECCION WIM/ESD (DISM) ---
try {
    $mounts = @(Get-AIOMountedImages)
    # Asociar ruta, archivo, indice y estado del MISMO bloque de DISM.
    # Solo retomar la carpeta configurada; no apropiarse de montajes de Info WIM.
    $current = Get-AIOMountForPath -Mounts $mounts -Path $Script:MOUNT_DIR
    if (-not (Test-AIOHostWinREProtectedMount -Path $Script:MOUNT_DIR -Mount $current) -and
        $null -ne $current -and $current.Status -eq 'OK' -and $current.ReadWrite -eq 'Yes' -and
        $current.ImageIndex -gt 0 -and -not [string]::IsNullOrWhiteSpace($current.ImageFile) -and
        (Test-Path -LiteralPath $current.MountDir -PathType Container)) {
        $Script:IMAGE_MOUNTED = 1
        $Script:WIM_FILE_PATH = $current.ImageFile
        $Script:MOUNTED_INDEX = $current.ImageIndex
        Write-Log -LogLevel INFO -Message "WIM detectado y validado: $Script:WIM_FILE_PATH en $Script:MOUNT_DIR"
    }
} catch {
    Write-Warning (Get-AIOString 'startup.dism_inventory_warn' $_.Exception.Message)
    Write-Log -LogLevel WARN -Message "Error verificando DISM: $($_.Exception.Message)"
}

# Recuperar solo una sesion VHD registrada por esta herramienta.
if ($Script:IMAGE_MOUNTED -eq 0 -and -not $Script:AIOHostWinRECheckFailed) {
    Restore-AIOVhdSession
}

# --- REPORTE FINAL ---
if ($Script:IMAGE_MOUNTED -eq 0) {
    Write-Log -LogLevel INFO -Message "No se recupero ninguna imagen previa para edicion."
} elseif ($Script:IMAGE_MOUNTED -eq 1) {
    Write-Host (Get-AIOString 'startup.wim_recovered' $Script:WIM_FILE_PATH) -ForegroundColor Yellow
    Write-Host (Get-AIOString 'startup.wim_recovered_detail' $Script:MOUNTED_INDEX $Script:MOUNT_DIR) -ForegroundColor Yellow
    
    # Limpieza preventiva de hives huerfanos si se detecto un montaje previo
    Unmount-Hives 
    [GC]::Collect()
}

# 1. Cargar configuracion y definir rutas
Ensure-WorkingDirectories 

# 2. Limpieza preventiva
Initialize-ScratchSpace

# 3. Verificar estado de montajes anteriores
Check-And-Repair-Mounts

# =============================================
#  Punto de Entrada: Iniciar el Menu Principal
# =============================================
# EVENTO DE SALIDA CONTROLADA POR POWERSHELL.
# No se dispara al cerrar la ventana con "X". La limpieza normal esta en finally.
$OnExitScript = {
    # Solo intentamos desmontar si detectamos que se quedaron montados
    if (Test-Path "Registry::HKLM\OfflineSystem") {
        Write-Host (Get-AIOString 'startup.exit_event_hives') -ForegroundColor Red
        # Invocamos la logica de desmontaje directamente (sin llamar a la funcion para evitar conflictos de scope)
        $hives = @("HKLM\OfflineSystem", "HKLM\OfflineSoftware", "HKLM\OfflineComponents", "HKLM\OfflineDefaultUser", "HKLM\OfflineUser", "HKLM\OfflineUserClasses")
        foreach ($h in $hives) { 
            if (Test-Path "Registry::$h") { reg unload $h 2>$null }
        }
    }
}
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -SupportEvent -Action $OnExitScript | Out-Null

# BLOQUE PRINCIPAL BLINDADO
try {
    # Ejecutamos el bucle principal
    Main-Menu
}

catch {
    $ErrorActionPreference = "Continue" # Asegurar que podemos procesar el error
    
    # 1. Capturar detalles técnicos y del entorno
    $ex = $_.Exception
    $line = $_.InvocationInfo.ScriptLineNumber
    $cmd = $_.InvocationInfo.MyCommand
    $stack = $_.ScriptStackTrace
    
    # --- NUEVO: Extraer la excepción real de .NET y contexto del sistema ---
    $innerExc = if ($null -ne $ex.InnerException) { $ex.InnerException.Message } else { "N/A" }
    $osVersion = [Environment]::OSVersion.VersionString
    $psVersion = $PSVersionTable.PSVersion.ToString()
    $mntState = if ($null -ne $Script:IMAGE_MOUNTED) { $Script:IMAGE_MOUNTED } else { "N/A" }
    $mntPath = if ($null -ne $Script:WIM_FILE_PATH) { $Script:WIM_FILE_PATH } else { "N/A" }

    # 2. Formatear mensaje para el usuario (Limpio)
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host (Get-AIOString 'crash.title') -ForegroundColor Red
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host (Get-AIOString 'crash.unexpected') -ForegroundColor Gray
    Write-Host (Get-AIOString 'crash.error_label') -NoNewline; Write-Host $_.ToString() -ForegroundColor Yellow
    Write-Host (Get-AIOString 'crash.line_label') -NoNewline; Write-Host $line -ForegroundColor Cyan
    Write-Host ""

    # 3. Escribir Log Técnico Completo (Reporte Forense)
    $logPayload = @"

==================================================
CRASH REPORT - EXCEPCION NO CONTROLADA
==================================================
Timestamp  : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Script Ver : v$($script:Version)
OS Context : $osVersion
PS Context : $psVersion
Mount State: $mntState | Target: $mntPath
--------------------------------------------------
Error Msg  : $($_.ToString())
Inner Exc. : $innerExc
Command    : $cmd
Line       : $line
Category   : $($_.CategoryInfo.ToString())
Stack Tr.  : 
$stack
==================================================
"@
    # Escribimos en el log usando tu función optimizada
    Write-Log -LogLevel ERROR -Message $logPayload

    # 4. Opción de recuperación
    Write-Host (Get-AIOString 'crash.forensic_saved') -ForegroundColor Gray
    Write-Warning (Get-AIOString 'crash.auto_cleanup_warn')
    Pause
}

finally {
    # ESTO SE EJECUTA SIEMPRE: Ya sea que salgas bien, por error, o con CTRL+C
    Write-Host (Get-AIOString 'startup.finalizing_cleanup') -ForegroundColor DarkGray
    
    try {
        # No ocultar el error si alguna colmena sigue cargada.
        Unmount-Hives
    } finally {
        Unregister-Event -SourceIdentifier PowerShell.Exiting -Force -ErrorAction SilentlyContinue
    }
    Write-Log -LogLevel INFO -Message "Cierre de sesion completado."
}
} finally {
    # Se ejecuta incluso si falla Unmount-Hives, el evento o el arranque.
    # La liberacion es idempotente para las rutas que ya cerraron su handle.
    Release-SingleInstanceMutex
}
