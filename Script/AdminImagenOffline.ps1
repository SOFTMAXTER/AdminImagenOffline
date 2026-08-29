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
    1.5.4

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
$script:Version = "1.5.4"

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
        Write-Warning "No se pudo escribir en el archivo de log: $_"
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
    Write-Host "           NUEVA VERSION DISPONIBLE DETECTADA!          " -ForegroundColor Green
    Write-Host "  =======================================================" -ForegroundColor Cyan
    Write-Host "     Version Local  : v$($script:Version)" -ForegroundColor Gray
    Write-Host "     Version Remota : v$remoteVersionStr" -ForegroundColor Yellow

    if ($changelog.Count -gt 0) {
        Write-Host "  -------------------------------------------------------" -ForegroundColor Cyan
        Write-Host "     NOVEDADES Y CAMBIOS: " -ForegroundColor Magenta
        foreach ($line in $changelog) {
            Write-Host "      $line" -ForegroundColor White
        }
    }
    Write-Host "  =======================================================" -ForegroundColor Cyan

    $updateChoice = (Read-Host "`n  [?] Deseas descargar e instalar la actualizacion ahora? (S/N)").ToUpper()
    if ($updateChoice -ne 'S') {
        Write-Host "`n  [i] Actualizacion pospuesta por el usuario." -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "UPDATER: Actualizacion a v$remoteVersionStr pospuesta por el usuario. Respuesta: '$updateChoice'."
        Start-Sleep -Seconds 1
        return
    }

    Write-Log -LogLevel ACTION -Message "UPDATER: El usuario acepto instalar la version v$remoteVersionStr."
    Write-Host "`n  [!] Preparando la actualizacion de forma segura..." -ForegroundColor Magenta

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

        Write-Host "   > Descargando paquete (v$remoteVersionStr)..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "UPDATER: Descargando paquete v$remoteVersionStr."
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop

        if (-not (Test-Path -LiteralPath $tempZip -PathType Leaf)) {
            throw "La descarga finalizo sin crear el archivo '$tempZip'."
        }
        $downloadSize = (Get-Item -LiteralPath $tempZip -ErrorAction Stop).Length
        if ($downloadSize -le 0) { throw "El paquete descargado esta vacio." }
        Write-Log -LogLevel INFO -Message "UPDATER: Descarga completada. Tamano: $downloadSize bytes."

        Write-Host "   > Extrayendo archivos..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "UPDATER: Extrayendo paquete en '$tempExtract'."
        Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force -ErrorAction Stop

        $repoExtractedPath = Join-Path -Path $tempExtract -ChildPath "AdminImagenOffline-main"
        if (-not (Test-Path -LiteralPath $repoExtractedPath -PathType Container)) {
            throw "La estructura esperada del paquete no existe: '$repoExtractedPath'."
        }
        Write-Log -LogLevel INFO -Message "UPDATER: Extraccion completada correctamente."

        Write-Host "   > Generando motor de inyeccion..." -ForegroundColor Cyan
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

        Write-Host "`n  [!] El sistema se cerrara para aplicar los cambios." -ForegroundColor Red
        Write-Log -LogLevel ACTION -Message "UPDATER: Lanzando ApplyUpdate.cmd y cerrando la sesion actual para liberar archivos."
        Start-Sleep -Seconds 2

        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$batPath`"" -ErrorAction Stop | Out-Null
        Write-Log -LogLevel INFO -Message "UPDATER: ApplyUpdate.cmd iniciado correctamente. El registro continuara desde CMD."
        exit
    }
    catch {
        $errorMessage = $_.Exception.Message
        $errorType = $_.Exception.GetType().FullName
        $errorLine = $_.InvocationInfo.ScriptLineNumber

        Write-Host "`n  [ERROR] Fallo la actualizacion: $errorMessage" -ForegroundColor Red
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
        Write-Host "Cargando configuracion desde $script:configFile..." -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "Cargando configuracion desde $script:configFile"
        try {
            $config = Get-Content -Path $script:configFile | ConvertFrom-Json
            
            if ($config.MountDir) {
                $Script:MOUNT_DIR = $config.MountDir
                Write-Log -LogLevel INFO -Message "Config: MOUNT_DIR cargado como '$($Script:MOUNT_DIR)'"
            }
            if ($config.ScratchDir) {
                $Script:Scratch_DIR = $config.ScratchDir
                Write-Log -LogLevel INFO -Message "Config: Scratch_DIR cargado como '$($Script:Scratch_DIR)'"
            }
        } catch {
            Write-Warning "No se pudo leer el archivo de configuracion (JSON invalido o corrupto). Usando valores por defecto."
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
        }
        $configToSave | ConvertTo-Json | Set-Content -Path $script:configFile -Encoding utf8
        Write-Host "[OK] Configuracion guardada." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Configuracion guardada en $script:configFile"
    } catch {
        Write-Host "[ERROR] No se pudo guardar el archivo de configuracion en '$($script:configFile)'."
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
        Write-Warning "El directorio de Montaje (MOUNT_DIR) no existe:"
        Write-Host $Script:MOUNT_DIR -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   [C] Crearlo automaticamente"
        Write-Host "   [S] Seleccionar un directorio diferente"
        Write-Host "   [N] Salir del script"
        $choice = Read-Host "`nSelecciona una opcion"
        
        switch ($choice.ToUpper()) {
            'C' {
                Write-Host "[+] Creando directorio '$($Script:MOUNT_DIR)'..." -ForegroundColor Yellow
                try {
                    New-Item -Path $Script:MOUNT_DIR -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Write-Host "[OK] Directorio creado." -ForegroundColor Green
                    Write-Log -LogLevel ACTION -Message "Directorio MOUNT_DIR '$($Script:MOUNT_DIR)' creado automaticamente."
                } catch {
                    Write-Host "[ERROR] No se pudo crear el directorio. Error: $($_.Exception.Message)"
                    Write-Log -LogLevel ERROR -Message "Fallo al auto-crear MOUNT_DIR. Error: $($_.Exception.Message)"
                    Read-Host "Presiona Enter para salir."; exit
                }
            }
            'S' {
                Write-Host "[+] Selecciona el NUEVO Directorio de Montaje..." -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title "Selecciona el Directorio de Montaje (ej. D:\TEMP)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:MOUNT_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: MOUNT_DIR cambiado a '$newPath' (en el inicio)."
                    Save-Config # Guardar la nueva seleccion
                } else {
                    Write-Warning "No se selecciono ruta. Saliendo."
                    Read-Host "Presiona Enter para salir."; exit
                }
            }
            default {
                Write-Host "Operacion cancelada por el usuario. Saliendo."
                Write-Log -LogLevel INFO -Message "Usuario cancelo en la verificacion de directorios."
                exit
            }
        }
    }

    # --- 2. Verificar Scratch_DIR ---
    if (-not (Test-Path $Script:Scratch_DIR)) {
        Write-Warning "El directorio Temporal (Scratch_DIR) no existe:"
        Write-Host $Script:Scratch_DIR -ForegroundColor Yellow
        Write-Host ""
        Write-Host "   [C] Crearlo automaticamente"
        Write-Host "   [S] Seleccionar un directorio diferente (se guardara permanentemente)"
        Write-Host "   [N] Salir del script"
        $choice = Read-Host "`nSelecciona una opcion"
        
        switch ($choice.ToUpper()) {
            'C' {
                Write-Host "[+] Creando directorio '$($Script:Scratch_DIR)'..." -ForegroundColor Yellow
                try {
                    New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    Write-Host "[OK] Directorio creado." -ForegroundColor Green
                    Write-Log -LogLevel ACTION -Message "Directorio Scratch_DIR '$($Script:Scratch_DIR)' creado automaticamente."
                } catch {
                    Write-Host "[ERROR] No se pudo crear el directorio. Error: $($_.Exception.Message)"
                    Write-Log -LogLevel ERROR -Message "Fallo al auto-crear Scratch_DIR. Error: $($_.Exception.Message)"
                    Read-Host "Presiona Enter para salir."; exit
                }
            }
            'S' {
                Write-Host "[+] Selecciona el NUEVO Directorio Temporal (Scratch)..." -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title "Selecciona el Directorio Temporal (ej. D:\Scratch)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:Scratch_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: Scratch_DIR cambiado a '$newPath' (en el inicio)."
                    Save-Config # Guardar la nueva seleccion
                } else {
                    Write-Warning "No se selecciono ruta. Saliendo."
                    Read-Host "Presiona Enter para salir."; exit
                }
            }
            default {
                Write-Host "Operacion cancelada por el usuario. Saliendo."
                Write-Log -LogLevel INFO -Message "Usuario cancelo en la verificacion de directorios."
                exit
            }
        }
    }
    
    Write-Log -LogLevel INFO -Message "Verificacion de directorios de trabajo completada."
    Start-Sleep -Seconds 1
}

function Initialize-ScratchSpace {
    Write-Log -LogLevel INFO -Message "MANTENIMIENTO: Inicializando espacio Scratch..."
    
    if (Test-Path $Script:Scratch_DIR) {
        # Intentamos limpiar contenido anterior
        try {
            $junkFiles = Get-ChildItem -Path $Script:Scratch_DIR -Recurse -Force -ErrorAction SilentlyContinue
            if ($junkFiles) {
                Write-Host "Limpiando archivos temporales antiguos en Scratch..." -ForegroundColor DarkGray
                
                # Usamos Remove-Item con Force y Recurse. 
                # SilentlyContinue es vital porque algunos archivos pueden estar bloqueados por el sistema (inofensivo).
                $junkFiles | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
                
                Write-Log -LogLevel ACTION -Message "Scratch_DIR limpiado preventivamente."
            }
        }
        catch {
            Write-Log -LogLevel WARN -Message "No se pudo realizar limpieza profunda del Scratch. (Puede estar en uso)"
        }
    }
    else {
        # Si no existe, la creamos (Logica original mejorada)
        try {
            New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force | Out-Null
            Write-Log -LogLevel INFO -Message "Scratch_DIR creado: $Script:Scratch_DIR"
        }
        catch {
            Write-Host "No se pudo crear el directorio Scratch. Verifica permisos."
            Write-Log -LogLevel ERROR -Message "Fallo al crear Scratch_DIR: $_"
        }
    }
}

# =================================================================
#  Verificacion de Permisos de Administrador
# =================================================================
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Este script necesita ser ejecutado como Administrador."
    Write-Host "Por favor, cierra esta ventana, haz clic derecho en el archivo del script y selecciona 'Ejecutar como Administrador'."
    Read-Host "Presiona Enter para salir."
    exit
}

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
        Write-Host " -> [-] Habilitando soporte para rutas largas en el Registro..." -ForegroundColor Yellow
        Set-ItemProperty -Path $regPath -Name $name -Value 1 -Type DWord -Force -ErrorAction Stop
        Write-Host " -> [OK] Soporte habilitado exitosamente." -ForegroundColor Green
        # Write-Log -LogLevel ACTION -Message "Soporte para rutas largas (Long Paths) habilitado dinamicamente."
    }
} catch {
    Write-Warning "No se pudo comprobar o habilitar el soporte para rutas largas de forma automatica."
    Write-Host "Asegurate de que tu directorio temporal (Scratch_DIR) tenga una ruta muy corta (ej. C:\S) para evitar errores de extraccion con DISM." -ForegroundColor Yellow
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
            Write-Host "Realizando mantenimiento del archivo de Log..." -ForegroundColor Gray
            $oldLogFile = Join-Path -Path $script:logDir -ChildPath "Registro_old.log"
            
            # Sobrescribe el backup viejo con el log gigante actual y empieza uno nuevo
            Move-Item -LiteralPath $script:logFile -Destination $oldLogFile -Force
        }
    }
} catch {
    Write-Warning "No se pudo crear el directorio de Logs. El registro de eventos se desactivará. Error: $_"
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
$Script:IMAGE_MOUNTED = 0
$Script:MOUNTED_INDEX = $null
$Script:CachedControlSet = $null
$Script:OfflineUserClassesPresent = $null
$Script:ForceMenuRefresh = $false
$Script:GlobalPrivilegesEnabled = $false

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
    Write-Host "`n[ADVERTENCIA] Se omitieron $($modulosOmitidos.Count) archivo(s) por parecer copias duplicadas:" -ForegroundColor Yellow
    foreach ($nombreOmitido in $modulosOmitidos) { Write-Host "  - $nombreOmitido" -ForegroundColor Yellow }
    Write-Host "Revisa cual es la version correcta y elimina las demas manualmente.`n" -ForegroundColor Yellow
    Start-Sleep -Seconds 2
}

if ($script:ModulosFallidos.Count -gt 0) {
    Write-Host "`n[ADVERTENCIA] $($script:ModulosFallidos.Count) modulo(s) no se cargaron correctamente:" -ForegroundColor Yellow
    foreach ($nombreModulo in $script:ModulosFallidos) { Write-Host "  - $nombreModulo" -ForegroundColor Yellow }
    Write-Host "Revisa Registro.log para mas detalles. Las opciones de esos modulos no estaran disponibles.`n" -ForegroundColor Yellow
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
        Write-Host "No se pudo mostrar el dialogo de seleccion. Error: $($_.Exception.Message)"
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
        Write-Host "No se pudo mostrar el dialogo de guardado. Error: $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "Fallo al mostrar dialogo GUARDAR: $($_.Exception.Message)"
    }

    return $null # Devuelve nulo si el usuario cancela
}

# =============================================
#  FUNCIONES DE MENU (Interfaz de Usuario)
# =============================================
# --- Menu de Configuracion de Rutas ---
function Show-ConfigMenu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "             Configuracion de Rutas de Trabajo         " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "Estas rutas se guardaran permanentemente."
        Write-Host ""
        Write-Host "   [1] Directorio de Montaje (MOUNT_DIR)"
        Write-Host "       Ruta actual: " -NoNewline; Write-Host $Script:MOUNT_DIR -ForegroundColor Yellow
        Write-Host "       (Donde se montara la imagen WIM para edicion)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Directorio Temporal (Scratch_DIR)"
        Write-Host "       Ruta actual: " -NoNewline; Write-Host $Script:Scratch_DIR -ForegroundColor Yellow
        Write-Host "       (Usado por DISM para operaciones de limpieza)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
        Write-Host ""
        $opcionC = Read-Host "Selecciona una opcion"

        switch ($opcionC.ToUpper()) {
            "1" {
                Write-Host "`n[+] Selecciona el NUEVO Directorio de Montaje..." -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title "Selecciona el Directorio de Montaje (ej. D:\TEMP)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:MOUNT_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: MOUNT_DIR cambiado a '$newPath'"
                    Save-Config
                } else {
                    Write-Warning "Operacion cancelada. No se realizaron cambios."
                }
                Pause
            }
            "2" {
                Write-Host "`n[+] Selecciona el NUEVO Directorio Temporal (Scratch)..." -ForegroundColor Yellow
                $newPath = Select-PathDialog -DialogType Folder -Title "Selecciona el Directorio Temporal (ej. D:\Scratch)"
                if (-not [string]::IsNullOrWhiteSpace($newPath)) {
                    $Script:Scratch_DIR = $newPath
                    Write-Log -LogLevel ACTION -Message "CONFIG: Scratch_DIR cambiado a '$newPath'"
                    Save-Config
                } else {
                    Write-Warning "Operacion cancelada. No se realizaron cambios."
                }
                Pause
            }
            "V" {
                return
            }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
        }
    }
}

function Mount-Unmount-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "             Gestion de Montaje de Imagen              " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Montar Imagen"
        Write-Host "       (Carga un .wim o .vhd/vhdx en $Script:MOUNT_DIR)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Desmontar Imagen (Descartar Cambios)"
        Write-Host "       (Descarga la imagen. Cambios no guardados se pierden!)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Guardar y Desmontar Imagen (Commit)" -ForegroundColor Green
        Write-Host "       (Guarda todos los cambios y luego descarga la imagen)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [4] Recargar Imagen (Descartar Cambios)"
        Write-Host "       (Desmonta y vuelve a montar. util para revertir)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al menu anterior" -ForegroundColor Red
        Write-Host ""
        $opcionMU = Read-Host "Selecciona una opcion"
        
        switch ($opcionMU.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuMount: Accediendo a 'Mount-Image' (Montar una nueva imagen en el directorio de trabajo)."
                Mount-Image 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuMount: Accediendo a 'Unmount-Image' (Descartar todos los cambios y desmontar la imagen actual)."
                Unmount-Image 
            }
            "3" { 
                Write-Log -LogLevel INFO -Message "MenuMount: Accediendo a 'Unmount-Image -Commit' (Confirmar guardado y desmontar la imagen actual)."
                Unmount-Image -Commit 
            }
            "4" { 
                Write-Log -LogLevel INFO -Message "MenuMount: Accediendo a 'Reload-Image' (Forzar recarga del estado de la imagen montada)."
                Reload-Image 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Save-Changes-Menu {
    while ($true) {
        Clear-Host
        if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "No hay imagen montada para guardar."; Pause; return }
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "                 Guardar Cambios (Save)                " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Guardar cambios en el Indice actual ($($Script:MOUNTED_INDEX))"
        Write-Host "       (Sobrescribe el indice actual del archivo original)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Guardar cambios en un nuevo Indice (Append)"
        Write-Host "       (Agrega un nuevo indice al final del archivo original)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Guardar en un NUEVO archivo WIM (Save As...)" -ForegroundColor Green
        Write-Host "       (Crea un archivo .wim nuevo sin tocar el original)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al menu anterior" -ForegroundColor Red
        Write-Host ""
        $opcionSC = Read-Host "Selecciona una opcion"

        switch ($opcionSC.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuSave: Accediendo a 'Save-Changes' (Modo: Commit - Sobrescribir indice actual en la imagen base)."
                Save-Changes -Mode 'Commit' 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuSave: Accediendo a 'Save-Changes' (Modo: Append - Guardar cambios como un indice WIM nuevo)."
                Save-Changes -Mode 'Append' 
            }
            "3" { 
                Write-Log -LogLevel INFO -Message "MenuSave: Accediendo a 'Save-Changes' (Modo: NewWim - Exportar montaje a un archivo WIM completamente independiente)."
                Save-Changes -Mode 'NewWim' 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Edit-Indexes-Menu {
     while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "                  Editar Indices del WIM               " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Exportar un Indice"
        Write-Host "       (Crea un nuevo WIM solo con el indice seleccionado)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Eliminar un Indice"
        Write-Host "       (Borra permanentemente un indice del WIM)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al menu anterior" -ForegroundColor Red
        Write-Host ""
        $opcionEI = Read-Host "Selecciona una opcion"
                
        switch ($opcionEI.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuEditIndex: Accediendo a 'Export-Index' (Exportar un indice hacia otra imagen)."
                Export-Index 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuEditIndex: Accediendo a 'Delete-Index' (Eliminar un indice de la imagen actual)."
                Delete-Index 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Convert-Image-Menu {
     while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "             Convertir Formato de Imagen a WIM         " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Convertir ESD a WIM"
        Write-Host "       (Extrae un indice de un .esd a .wim)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Convertir VHD/VHDX a WIM"
        Write-Host "       (Captura un disco virtual a .wim)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al menu anterior" -ForegroundColor Red
        Write-Host ""
        $opcionCI = Read-Host "Selecciona una opcion"
                
        switch ($opcionCI.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuConvert: Accediendo a 'Convert-ESD' (Compresion/Descompresion de archivos ESD y WIM)."
                Convert-ESD 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuConvert: Accediendo a 'Convert-VHD' (Manejo de Discos Virtuales VHD/VHDX)."
                Convert-VHD 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Image-Management-Menu {
     while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "                  Gestion de Imagen                    " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Montar/Desmontar Imagen" -ForegroundColor White
        Write-Host "       (Cargar o descargar la imagen del WIM)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Guardar Cambios (Commit)" -ForegroundColor White
        Write-Host "       (Guarda cambios en imagen montada, sin desmontar)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Editar Info/Metadatos (Nombre, Descripcion, etc..)" -ForegroundColor Green
        Write-Host "       (Cambia el nombre que aparece al instalar Windows)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [4] Editar Indices (Exportar/Eliminar)" -ForegroundColor White
        Write-Host "       (Gestiona los indices dentro de un .wim)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
        Write-Host ""
        $opcionIM = Read-Host "Selecciona una opcion"
                
        switch ($opcionIM.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Mount-Unmount-Menu' (Montar/Desmontar Imagen)."
                Mount-Unmount-Menu 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Save-Changes-Menu' (Guardar Cambios)."
                Save-Changes-Menu 
            }
            "3" { 
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Show-WimMetadata-GUI' (Edicion de Metadatos XML)."
                Show-WimMetadata-GUI 
            }
            "4" { 
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Edit-Indexes-Menu' (Gestion de Indices WIM/ESD)."
                Edit-Indexes-Menu 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Cambio-Edicion-Menu {
    Clear-Host
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Warning "Necesita montar imagen primero."
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
        Write-Warning "No se encontró el catálogo de Ediciones. Se usarán los nombres crudos."
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
        Write-Host "            ! ADVERTENCIA DE SEGURIDAD (VHD) !         " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Estas a punto de cambiar la edicion en un DISCO VIRTUAL (VHD/VHDX)." -ForegroundColor White
        Write-Host "A diferencia de los archivos WIM, los cambios en VHD afectan al disco inmediatamente." -ForegroundColor Gray
        Write-Host ""
        Write-Host "RIESGOS:" -ForegroundColor Red
        Write-Host " * Si el proceso se interrumpe, el VHD podria quedar corrupto (BSOD)."
        Write-Host " * El cambio de edicion (ej. Home -> Pro) es generalmente IRREVERSIBLE."
        Write-Host " * Asegurate de tener una COPIA DE SEGURIDAD del archivo .vhdx antes de seguir."
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        
        $confirmVHD = Read-Host "Escribe 'CONFIRMAR' para asumir el riesgo y continuar"
        if ($confirmVHD.ToUpper() -ne 'CONFIRMAR') {
            Write-Warning "Operacion cancelada por seguridad."
            Start-Sleep -Seconds 2
            return
        }
        Clear-Host
    }
    
    Write-Host "[+] Obteniendo info de version/edicion..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION: Obteniendo info..."

    $WIN_PRODUCT_NAME = $null
    $WIN_CURRENT_BUILD = $null
    $WIN_VERSION_FRIENDLY = "Desconocida"
    $CURRENT_EDITION_DETECTED = "Desconocida"
    $hiveLoaded = $false

    try {
        reg load HKLM\OfflineImage "$($Script:MOUNT_DIR)\Windows\System32\config\SOFTWARE" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $hiveLoaded = $true } else { throw "No se pudo cargar HIVE" }
        $regPath = "Registry::HKLM\OfflineImage\Microsoft\Windows NT\CurrentVersion"
        $regProps = Get-ItemProperty -Path $regPath -ErrorAction SilentlyContinue
        if ($regProps) { $WIN_PRODUCT_NAME = $regProps.ProductName; $WIN_CURRENT_BUILD = $regProps.CurrentBuildNumber }
    } catch {
        Write-Warning "WARN: No se pudo cargar el hive del registro. Se intentara obtener informacion basica."
        Write-Log -LogLevel WARN -Message "CAMBIO_EDICION: Fallo carga HIVE: $($_.Exception.Message)"
    } finally {
        if ($hiveLoaded) { reg unload HKLM\OfflineImage 2>$null | Out-Null }
    }

    # Determinar version amigable
    if ($WIN_CURRENT_BUILD) {
        $buildNum = 0; [int]::TryParse($WIN_CURRENT_BUILD, [ref]$buildNum) | Out-Null
        if ($buildNum -ge 22000) { $WIN_VERSION_FRIENDLY = "Windows 11" }
        elseif ($buildNum -ge 10240) { $WIN_VERSION_FRIENDLY = "Windows 10" }
        elseif ($buildNum -eq 9600) { $WIN_VERSION_FRIENDLY = "Windows 8.1" } 
        elseif ($buildNum -in (7601, 7600)) { $WIN_VERSION_FRIENDLY = "Windows 7" }
    }
    if ($WIN_VERSION_FRIENDLY -eq "Desconocida" -and $WIN_PRODUCT_NAME) {
        if ($WIN_PRODUCT_NAME -match "Windows 11") { $WIN_VERSION_FRIENDLY = "Windows 11" }
        elseif ($WIN_PRODUCT_NAME -match "Windows 10") { $WIN_VERSION_FRIENDLY = "Windows 10" }
        elseif ($WIN_PRODUCT_NAME -match "Windows 8\.1|Server 2012 R2") { $WIN_VERSION_FRIENDLY = "Windows 8.1" } 
        elseif ($WIN_PRODUCT_NAME -match "Windows 7|Server 2008 R2") { $WIN_VERSION_FRIENDLY = "Windows 7" }
    }

    # Obtener edicion actual con DISM
    try {
        $dismEdition = dism /Image:$Script:MOUNT_DIR /Get-CurrentEdition 2>$null
        $currentEditionLine = $dismEdition | Select-String -Pattern "(Current Edition|Edici.n actual)\s*:"
        if ($currentEditionLine) { $CURRENT_EDITION_DETECTED = ($currentEditionLine.Line -split ':', 2)[1].Trim() }
    } catch { Write-Warning "No se pudo obtener la edicion actual via DISM." }

    # Traducir nombre de la edición actual usando el catálogo
    $DISPLAY_EDITION = $CURRENT_EDITION_DETECTED
    if ($CURRENT_EDITION_DETECTED -ne "Desconocida") {
        $DISPLAY_EDITION = Get-FriendlyEditionName $CURRENT_EDITION_DETECTED
    }

    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "               Cambiar Edicion de Windows                " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "  Imagen: $Script:MOUNT_DIR" -ForegroundColor Gray
    Write-Host "    SO Actual : $WIN_VERSION_FRIENDLY" -ForegroundColor Gray
    Write-Host "    Edicion   : $DISPLAY_EDITION" -ForegroundColor Gray
    Write-Host ""
    Write-Host "--- Ediciones de Destino Disponibles ---" -ForegroundColor Yellow
    Write-Host ""

    $targetEditions = @()
    try {
        $dismTargets = dism /Image:$Script:MOUNT_DIR /Get-TargetEditions 2>$null
        $dismTargets | Select-String "Target Edition :" | ForEach-Object {
            $line = ($_.Line -split ':', 2)[1].Trim()
            if ($line) { $targetEditions += $line }
        }
    } catch { 
        Write-Host ""
        Write-Warning "No se pudieron obtener las ediciones de destino."
    }

    # Validacion: Si es null o tiene 0 elementos
    if ($null -eq $targetEditions -or $targetEditions.Count -eq 0) {
        Write-Host ""
        Write-Warning "No se encontraron ediciones de destino compatibles para esta imagen."
        Write-Host "Causas posibles:" -ForegroundColor Gray
        Write-Host " 1. La imagen ya es la edicion mas alta (ej. Enterprise)." -ForegroundColor Gray
        Write-Host " 2. La imagen no admite upgrades (ej. algunas versiones VL)." -ForegroundColor Gray
        Write-Host " 3. Error interno de DISM al leer los metadatos." -ForegroundColor Gray
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
    Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
    Write-Host ""
    $opcionEdicion = Read-Host "Seleccione la edicion a la que desea cambiar (1-$($targetEditions.Count)) o V"

    if ($opcionEdicion.ToUpper() -eq "V") { return }

    $opcionIndex = 0
    if (-not [int]::TryParse($opcionEdicion, [ref]$opcionIndex) -or $opcionIndex -lt 1 -or $opcionIndex -gt $targetEditions.Count) {
        Write-Warning "Opcion no valida."
        Pause
        return
    }

    $selectedEdition = $targetEditions[$opcionIndex - 1] 

    Write-Host "[+] Cambiando la edicion de $DISPLAY_EDITION a: $selectedEdition" -ForegroundColor Yellow
    Write-Host "Esta operacion puede tardar varios minutos. Por favor, espere..." -ForegroundColor Gray
    Write-Log -LogLevel ACTION -Message "CAMBIO_EDICION: Cambiando edicion de '$DISPLAY_EDITION' a '$selectedEdition'."

    dism /Image:$Script:MOUNT_DIR /Set-Edition:$selectedEdition
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Proceso de cambio de edicion finalizado." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Fallo el cambio de edicion (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo cambio edicion. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Drivers-Menu {
    while ($true) {
        Clear-Host
        if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "Necesita montar imagen primero."; Pause; return }
        
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "             Gestion de Drivers (Offline)              " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Inyectar Drivers (Instalacion Inteligente)"
        Write-Host "       (GUI: Compara carpeta local vs imagen)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Desinstalar Drivers"
        Write-Host "       (GUI: Lista drivers instalados y permite borrarlos)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host "   [V] Volver" -ForegroundColor Red
        
        $opcionD = Read-Host "`nSelecciona una opcion"
        
        switch ($opcionD.ToUpper()) {
            "1" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuDrivers: Accediendo a 'Show-Drivers-GUI' (Inyeccion de Controladores)."
                    Show-Drivers-GUI 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuDrivers: Intento de acceso a inyeccion denegado. No hay ninguna imagen montada."
                    Write-Warning "Monta una imagen primero."
                    Pause 
                } 
            }
            "2" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuDrivers: Accediendo a 'Show-Uninstall-Drivers-GUI' (Eliminacion de Controladores)."
                    Show-Uninstall-Drivers-GUI 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuDrivers: Intento de acceso a eliminacion denegado. No hay ninguna imagen montada."
                    Write-Warning "Monta una imagen primero."
                    Pause 
                } 
            }
            "V" { 
                return 
            }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Customization-Menu {
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "          Centro de Personalizacion y Ajustes          " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host " Estado: " -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host "IMAGEN WIM MONTADA" -ForegroundColor Green }
            2 { Write-Host "DISCO VHD MONTADO" -ForegroundColor Cyan }
            Default { Write-Host "NO MONTADA" -ForegroundColor Red }
        }
        Write-Host ""
        Write-Host "   [1] Eliminar Bloatware (Apps)" -ForegroundColor White
        Write-Host "       (Gestor grafico para borrar aplicaciones preinstaladas)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Caracteristicas de Windows y .NET 3.5" -ForegroundColor White
        Write-Host "       (Habilitar/Deshabilitar SMB, Hyper-V, WSL e Integrar .NET 3.5)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Servicios del Sistema" -ForegroundColor White
        Write-Host "       (Optimizar el arranque deshabilitando servicios inecesarios (Seguros))" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [4] Tweaks y Registro" -ForegroundColor White
        Write-Host "       (Ajustes de rendimiento, privacidad e importador .REG)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [5] Inyector de Apps Modernas (Appx/MSIX)" -ForegroundColor Green
        Write-Host "       (Aprovisiona aplicaciones UWP y sus dependencias offline)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [6] Automatizacion OOBE (Unattend.xml)" -ForegroundColor White
        Write-Host "       (Configurar usuario, saltar EULA y privacidad automaticamente)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [7] Inyector de Addons (.wim, .tpk, .bpk, .reg)" -ForegroundColor Magenta
        Write-Host "       (Preinstalar programas y utilidades extra como 7-Zip o Visual C++)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [8] Gestionar WinRE (Inyectar DaRT / Herramientas)" -ForegroundColor Yellow
        Write-Host "       (Extrae, monta y modifica el entorno de recuperacion nativo)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [9] OEM Branding (Fondos y Metadatos del Sistema)" -ForegroundColor Cyan
        Write-Host "       (Aplica wallpaper/lockscreen e informacion del fabricante)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
        Write-Host ""

        $opcionCust = Read-Host "Selecciona una opcion"
        
        # Validacion global de montaje antes de llamar a las funciones
        if ($opcionCust.ToUpper() -ne "V" -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Log -LogLevel WARN -Message "MenuCustomization: Acceso denegado a la opcion [$opcionCust]. No hay ninguna imagen montada en el sistema."
            Write-Warning "Debes montar una imagen antes de usar estas herramientas."
            Pause
            continue
        }

        switch ($opcionCust.ToUpper()) {
            "1" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Bloatware-GUI'"; Show-Bloatware-GUI }
            "2" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Features-GUI'"; Show-Features-GUI }
            "3" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Services-Offline-GUI'"; Show-Services-Offline-GUI }
            "4" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Tweaks-Offline-GUI'"; Show-Tweaks-Offline-GUI }
            "5" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-AppxInjector-GUI'"; Show-AppxInjector-GUI }
            "6" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Unattend-GUI'"; Show-Unattend-GUI }
            "7" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-Addons-GUI'"; Show-Addons-GUI }
            "8" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Manage-WinRE-Menu'"; Manage-WinRE-Menu }
            "9" { Write-Log -LogLevel INFO -Message "MenuCustomization: Accediendo a 'Show-OEMBranding-GUI'"; Show-OEMBranding-GUI }
            "V" { return }
            default { 
                Write-Warning "Opcion no valida."
                Start-Sleep 1 
            }
        }
    }
}

function Limpieza-Menu {
 
	# --- Funcion auxiliar interna para el fallback de RestoreHealth ---
    function Invoke-RestoreHealthWithFallback {
        param(
            [string]$MountDir,
            [switch]$IsSequence
        )

        Write-Host "`n[+] Ejecutando DISM /RestoreHealth..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "LIMPIEZA: Ejecutando DISM /RestoreHealth..."

        DISM /Image:$MountDir /Cleanup-Image /RestoreHealth
        $exitCode = $LASTEXITCODE

        if ($exitCode -notin @(0, 3010)) {
            Write-Host "[ADVERTENCIA] DISM /RestoreHealth no pudo reparar la imagen (Codigo: $exitCode)." -ForegroundColor Red
            Write-Host "Es probable que falten los archivos necesarios y el sistema este offline." -ForegroundColor Gray
            Write-Log -LogLevel WARN -Message "LIMPIEZA: RestoreHealth inicial devolvio $exitCode. Iniciando protocolo de Fallback."

            $useSourceChoice = Read-Host "`nDeseas intentar la reparacion usando un archivo WIM intacto como fuente? (S/N)"

            if ($useSourceChoice -match '^(s|S)$') {
                Write-Log -LogLevel INFO -Message "LIMPIEZA: Usuario eligio usar fuente WIM para RestoreHealth."
                $sourceWimPath = Select-PathDialog -DialogType File -Title "Selecciona el WIM de origen (ej. install.wim)" -Filter "Archivos WIM (*.wim)|*.wim"

                if ($sourceWimPath) {
                    Write-Host "`n[+] Analizando indices del WIM seleccionado..." -ForegroundColor Yellow
                    dism /get-wiminfo /wimfile:"$sourceWimPath"

                    [int]$sourceIndex = 0
                    $inputIndex = Read-Host "`nIntroduce el numero de INDICE que coincide con tu edicion de Windows"

                    if ([int]::TryParse($inputIndex, [ref]$sourceIndex) -and $sourceIndex -gt 0) {
                        Write-Host "`n[+] Reintentando reparacion forzando la fuente local (/LimitAccess)..." -ForegroundColor Yellow
                        Write-Log -LogLevel ACTION -Message "LIMPIEZA: Reintentando RestoreHealth con /LimitAccess y Source WIM."

                        $ext = [System.IO.Path]::GetExtension($sourceWimPath).ToUpper()
                        $sourceType = if ($ext -eq ".ESD") { "ESD" } else { "WIM" }

                        $safeMountDir = $MountDir.TrimEnd('\')
                        $safeSource = $sourceWimPath.TrimEnd('\')

                        $dismArgs = "/Image:`"$safeMountDir`" /Cleanup-Image /RestoreHealth /Source:${sourceType}:`"$safeSource`":$sourceIndex /LimitAccess"

                        $proc = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru
                        $exitCode = $proc.ExitCode

                        if ($exitCode -in @(0, 3010)) {
                            Write-Host "[OK] DISM /RestoreHealth reparo la imagen exitosamente usando la fuente WIM." -ForegroundColor Green
                            Write-Log -LogLevel INFO -Message "LIMPIEZA: RestoreHealth exitoso con fuente WIM."
                        } else {
                            Write-Host "[ERROR] La reparacion fallo de nuevo con fuente WIM (Codigo: $exitCode)." -ForegroundColor Red
                            Write-Log -LogLevel ERROR -Message "LIMPIEZA: RestoreHealth fallo con fuente WIM (Codigo: $exitCode)."
                        }
                    } else {
                        Write-Warning "Indice no valido. Omitiendo reintento."
                    }
                } else {
                    Write-Warning "No se selecciono un archivo WIM."
                }
            }
        } else {
            Write-Host "[OK] DISM /RestoreHealth completado exitosamente." -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "LIMPIEZA: DISM /RestoreHealth exitoso."
        }

        if (-not $IsSequence) { Pause }
    }
	
	while ($true) {
        Clear-Host
        if ($Script:IMAGE_MOUNTED -eq 0)
        {
            Write-Warning "Necesita montar imagen primero."
            Pause
            return
        }
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "             Herramientas de Limpieza de Imagen          " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Verificar Salud (Rapido)" -NoNewline; Write-Host " (DISM /CheckHealth)" -ForegroundColor Gray
        Write-Host "   [2] Escaneo Avanzado (Lento)" -NoNewline; Write-Host " (DISM /ScanHealth)" -ForegroundColor Gray
        Write-Host "   [3] Reparar Imagen" -NoNewline; Write-Host "           (DISM /RestoreHealth)" -ForegroundColor Gray
        Write-Host "   [4] Reparacion SFC (Offline)" -NoNewline; Write-Host " (SFC /Scannow /OffWindir)" -ForegroundColor Gray
        Write-Host "   [5] Analizar Componentes" -NoNewline; Write-Host "   (DISM /AnalyzeComponentStore)" -ForegroundColor Gray
        Write-Host "   [6] Limpiar Componentes" -NoNewline; Write-Host "    (DISM /StartComponentCleanup)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [7] Ejecutar TODO (1-6)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host "   [V] Volver" -ForegroundColor Red

        $opcionL = Read-Host "`nSelecciona una opcion"
        Write-Log -LogLevel INFO -Message "MENU_LIMPIEZA: Usuario selecciono '$opcionL'."

        switch ($opcionL.ToUpper()) {
            "1" {
                Write-Host "`n[+] Verificando salud..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /CheckHealth..."
                DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /CheckHealth
                Pause
            }
            "2" {
                Write-Host "`n[+] Escaneando corrupcion..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /ScanHealth..."
                DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /ScanHealth
                Pause
            }
            "3" {
                Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR
            }
            "4" {
                $sfcBoot = $Script:MOUNT_DIR
                if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
                $sfcWin = Join-Path -Path $Script:MOUNT_DIR -ChildPath "Windows"

                Write-Host "`n[+] Verificando archivos (SFC)..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: SFC /Scannow Offline..."
                
                if (-not (Test-Path $sfcWin)) {
                     Write-Host "No se encuentra la carpeta Windows en $sfcWin. Esta montada correctamente?"
                     Pause; break
                }

                SFC /scannow /offbootdir="$sfcBoot" /offwindir="$sfcWin"
                if ($LASTEXITCODE -ne 0) { Write-Warning "SFC encontro errores o no pudo completar."}
                Pause
            }
            "5" {
                Write-Host "`n[+] Analizando componentes..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /AnalyzeComponentStore..."
                DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /AnalyzeComponentStore
                Pause
            }
            "6" {
                Write-Host "`n[+] Preparando limpieza de componentes..." -ForegroundColor Yellow
                
                # --- NUEVA LOGICA: Preguntar por /ResetBase ---
                $useResetBase = Read-Host "`nDeseas incluir el parametro /ResetBase?`n[ADVERTENCIA] Esto ahorra espacio, pero no podras desinstalar actualizaciones previas (S/N)"
                
                if ($useResetBase -match '^(s|S)$') {
                    Write-Host "`nEjecutando limpieza CON /ResetBase..." -ForegroundColor Cyan
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /StartComponentCleanup /ResetBase..."
                    DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:$Script:Scratch_DIR
                } else {
                    Write-Host "`nEjecutando limpieza estandar SIN /ResetBase..." -ForegroundColor Cyan
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /StartComponentCleanup (Sin ResetBase)..."
                    DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /StartComponentCleanup /ScratchDir:$Script:Scratch_DIR
                }
                Pause
            }
            "7" {
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: Iniciando secuencia COMPLETA..."

                # Preguntar por /ResetBase antes de iniciar la secuencia para no interrumpir el flujo después
                $useResetBaseSeq = Read-Host "`nAntes de iniciar: Deseas incluir el parametro /ResetBase en la limpieza final?`n[ADVERTENCIA] Impide desinstalar actualizaciones previas (S/N)"
                $resetBaseFlag = ($useResetBaseSeq -match '^(s|S)$')

                # --- PASO 1 ---
                Write-Host "`n[1/5] Verificando salud rapida (CheckHealth)..." -ForegroundColor Yellow
                DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /CheckHealth

                # --- PASO 2 ---
                Write-Host "`n[2/5] Escaneando a fondo (ScanHealth)..." -ForegroundColor Yellow
                $imageState = "Unknown"
                
                try {
                    $scanResult = Repair-WindowsImage -Path $Script:MOUNT_DIR -ScanHealth -ErrorAction Stop
                    $imageState = $scanResult.ImageHealthState
                    
                    Write-Host "   Diagnostico: " -NoNewline
                    switch ($imageState) {
                        "Healthy"       { Write-Host "SALUDABLE (No requiere reparacion)" -ForegroundColor Green }
                        "Repairable"    { Write-Host "DANADA (Reparable)" -ForegroundColor Cyan }
                        "NonRepairable" { Write-Host "IRREPARABLE (Critico)" -ForegroundColor Red }
                    }
                }
                catch {
                    Write-Warning "Cmdlet nativo no disponible. Usando DISM clasico..."
                    DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /ScanHealth
                }

                # --- LOGICA DE DECISION (PASO 3) ---
                if ($imageState -eq "NonRepairable") {
                    Write-Host "`n[!] ALERTA DE SEGURIDAD" -ForegroundColor Red
                    Write-Warning "La imagen es IRREPARABLE. Deteniendo secuencia."
                    [System.Windows.Forms.MessageBox]::Show("La imagen esta en estado 'NonRepairable'.`nLa secuencia se detendra.", "Error Fatal", 'OK', 'Error')
                    Pause; continue
                }
                elseif ($imageState -eq "Healthy") {
                    Write-Host "`n[3/5] Reparando imagen..." -ForegroundColor DarkGray
                    Write-Host "   >>> OMITIDO: La imagen ya esta saludable." -ForegroundColor Green
                }
                else {
                    Write-Host "`n[3/5] Reparando imagen..." -ForegroundColor Yellow
                    Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR -IsSequence
                }

                # --- PASO 4 ---
                Write-Host "`n[4/5] Verificando archivos (SFC)..." -ForegroundColor Yellow
                $sfcBoot = $Script:MOUNT_DIR
                if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
                $sfcWin = Join-Path -Path $Script:MOUNT_DIR -ChildPath "Windows"
                SFC /scannow /offbootdir="$sfcBoot" /offwindir="$sfcWin"

                # --- PASO 5 ---
                Write-Host "`n[5/5] Analizando/Limpiando componentes..." -ForegroundColor Yellow
                $cleanupRecommended = "No"
                try {
                    $analysis = DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /AnalyzeComponentStore
                    $recommendLine = $analysis | Select-String "Component Store Cleanup Recommended"
                    if ($recommendLine -and ($recommendLine.Line -split ':', 2)[1].Trim() -eq "Yes") { $cleanupRecommended = "Yes" }
                } catch { Write-Warning "No se pudo analizar el almacen de componentes." }

                if ($cleanupRecommended -eq "Yes" -or $imageState -eq "Unknown") {
                    Write-Host "Procediendo con la limpieza..." -ForegroundColor Cyan;
                    
                    # --- NUEVA LOGICA DE SECUENCIA: Aplicar elección de /ResetBase ---
                    if ($resetBaseFlag) {
                        Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Ejecutando limpieza CON /ResetBase."
                        DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /StartComponentCleanup /ResetBase /ScratchDir:$Script:Scratch_DIR
                    } else {
                        Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Ejecutando limpieza SIN /ResetBase."
                        DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /StartComponentCleanup /ScratchDir:$Script:Scratch_DIR
                    }
                } else {
                    Write-Host "La limpieza del almacen de componentes no es estrictamente necesaria (Omitida)." -ForegroundColor Green;
                }
                
                Write-Host "`n[OK] Secuencia completada." -ForegroundColor Green
                Pause
            }
            "V" { return }
            default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
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
        [string]$RegContent
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

    function Write-RegHexValue {
        param([Microsoft.Win32.RegistryKey]$Key, [string]$Name, [string]$TypeCode, [string]$HexData)
        $hexClean = $HexData.Trim() -replace '\s', ''
        $byteList = [System.Collections.Generic.List[byte]]::new()
        if ($hexClean -ne '') {
            foreach ($seg in ($hexClean -split ',')) { if ($seg -ne '') { $byteList.Add([Convert]::ToByte($seg, 16)) } }
        }
        $bytes = $byteList.ToArray()

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
            if ([string]::IsNullOrEmpty($trimmed)) { continue }

            if ($null -ne $hexPending) {
                $hexPending.Data += $trimmed.TrimEnd('\')
                if ($trimmed.EndsWith('\')) { continue }

                if (-not $skipSection -and $null -ne $currentKeyPath) {
                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetHex'; Name = $hexPending.Name; TypeCode = $hexPending.TypeCode; Data = $hexPending.Data })
                }
                $hexPending = $null
                continue
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
                $hexFrag  = $matches[2].TrimEnd('\')
                if ($rhs.TrimEnd().EndsWith('\')) {
                    $hexPending = [PSCustomObject]@{ Name = $valueName; TypeCode = $typeCode; Data = $hexFrag }
                } else {
                    $groupedOps[$currentKeyPath].Add([PSCustomObject]@{ Action = 'SetHex'; Name = $valueName; TypeCode = $typeCode; Data = $hexFrag })
                }
            }
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
    
    Write-Log -LogLevel INFO -Message "Import-OfflineReg: OK — $keysWritten claves afectadas, $valuesWritten valores inyectados."
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
        [System.Windows.Forms.MessageBox]::Show("Error Critico: No se encuentran SYSTEM o SOFTWARE.`nLa imagen esta corrupta o no es valida?", "Error Fatal", 'OK', 'Error')
        return $false 
    }

    # 3. Check preventivo: Si SYSTEM ya esta montado, asumimos que todo esta listo.
    if ((Test-Path "Registry::HKLM\OfflineSystem") -and (Test-Path "Registry::HKLM\OfflineSoftware")) {
        Write-Log -LogLevel INFO -Message "HIVES: Detectados hives base ya montados. Omitiendo carga."
        return $true
    }

    try {
        # --- CARGA OBLIGATORIA (SYSTEM / SOFTWARE) ---
        Write-Host "Cargando SYSTEM..." -NoNewline
        $p1 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSystem `"$sysHive`"" -Wait -PassThru -NoNewWindow
        $ec1 = $p1.ExitCode; $p1.Dispose()
        if ($ec1 -ne 0) { throw "Fallo SYSTEM" } else { Write-Host "OK" -ForegroundColor Green; $resumenMount.Cargadas++ }

        Write-Host "Cargando SOFTWARE..." -NoNewline
        $p2 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSoftware `"$softHive`"" -Wait -PassThru -NoNewWindow
        $ec2 = $p2.ExitCode; $p2.Dispose()
        if ($ec2 -ne 0) { throw "Fallo SOFTWARE" } else { Write-Host "OK" -ForegroundColor Green; $resumenMount.Cargadas++ }

        # --- Carga del Perfil Default (.DEFAULT) ---
        if (Test-Path $defaultHive) {
            Write-Host "Cargando DEFAULT USER..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineDefaultUser `"$defaultHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                $resumenMount.Fallidas += "DEFAULT"
                Write-Log -LogLevel WARN -Message "Fallo al cargar DEFAULT (ExitCode: $($p.ExitCode))"
            }
        }

        # --- CARGA CONDICIONAL (BOOT / REPARACION) ---

        # COMPONENTS (A veces no existe en WinPE/Boot.wim muy ligeros)
        if (Test-Path $compHive) {
            Write-Host "Cargando COMPONENTS..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineComponents `"$compHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                $resumenMount.Fallidas += "COMPONENTS"
                Write-Log -LogLevel WARN -Message "Fallo al cargar COMPONENTS (ExitCode: $($p.ExitCode))"
            }
        }

        # NTUSER.DAT (No existe en Boot.wim)
        if (Test-Path $userHive) {
            Write-Host "Cargando USER..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUser `"$userHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                $resumenMount.Fallidas += "USER"
                Write-Log -LogLevel WARN -Message "Fallo al cargar NTUSER.DAT (ExitCode: $($p.ExitCode))"
            }
        } else {
            Write-Host "USER (Omitido - Modo Boot/WinPE)" -ForegroundColor DarkGray
            $resumenMount.Omitidas++
        }

        # UsrClass.dat (No existe en Boot.wim)
        if (Test-Path $classHive) {
            Write-Host "Cargando CLASSES..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUserClasses `"$classHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
                $resumenMount.Cargadas++
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
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
    Write-Host "Guardando y descargando Hives..." -ForegroundColor Yellow
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
    Write-Host "Esperando a que el sistema libere los manejadores de archivos..." -ForegroundColor DarkGray
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
                    
                    # Aseguramos privilegios críticos (SeRestorePrivilege, SeBackupPrivilege)
                    Enable-Privileges 
                    
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
                $errMsg = "ERROR LETAL: La colmena $hive sigue bloqueada en memoria por un proceso externo o el Antivirus.`n`nSi la imagen se guarda (Commit) en este estado, QUEDARA CORRUPTA (Pantallazo Azul).`nCierra cualquier programa, pausa el Antivirus e intentalo de nuevo."
                
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show($errMsg, "Peligro de Corrupcion", 'OK', 'Error')
                
                throw $errMsg
            }
        } else {
            $resumen.NoMontadas++
            # Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: La colmena $hive no estaba montada. Se omite."
        }
    }
    $swUnmount.Stop()
    Write-Host " [Proceso Finalizado]" -ForegroundColor Green
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
function Enable-Privileges {
    param(
        [string[]]$Privileges = @(
            "SeTakeOwnershipPrivilege",
            "SeRestorePrivilege",
            "SeBackupPrivilege",
            "SeSecurityPrivilege"
        )
    )
    
    # CONTROL SINGLETON: Si ya se activaron en esta sesión, salimos de inmediato (0ms de coste)
    if ($Script:GlobalPrivilegesEnabled) { return }
    
    $definition = @'
    using System;
    using System.Runtime.InteropServices;
    
    public class TokenManipulator
    {
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
        
        [DllImport("kernel32.dll", ExactSpelling = true)]
        internal static extern IntPtr GetCurrentProcess();
        
        [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern bool CloseHandle(IntPtr handle);
        
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
        
        [DllImport("advapi32.dll", SetLastError = true)]
        internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
        
        [StructLayout(LayoutKind.Sequential, Pack = 1)]
        internal struct TokPriv1Luid
        {
            public int Count;
            public long Luid;
            public int Attr;
        }
        
        internal const int SE_PRIVILEGE_ENABLED = 0x00000002;
        internal const int TOKEN_QUERY = 0x00000008;
        internal const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
        
        public static bool AddPrivilege(string privilege)
        {
            IntPtr htok = IntPtr.Zero;
            try {
                bool retVal;
                TokPriv1Luid tp;
                IntPtr hproc = GetCurrentProcess();
                retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
                tp.Count = 1;
                tp.Luid = 0;
                tp.Attr = SE_PRIVILEGE_ENABLED;
                retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
                retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                return retVal;
            } catch { return false; }
            finally {
                if (htok != IntPtr.Zero) CloseHandle(htok);
            }
        }
    }
'@
    if (-not ([System.Management.Automation.PSTypeName]'TokenManipulator').Type) {
        Add-Type -TypeDefinition $definition -PassThru | Out-Null
    }
    
    foreach ($priv in $Privileges) {
        [TokenManipulator]::AddPrivilege($priv) | Out-Null
    }

    # Marcamos la bandera global para bloquear llamadas redundantes
    $Script:GlobalPrivilegesEnabled = $true
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
    Write-Host "Verificando consistencia del entorno WIM..." -ForegroundColor DarkGray
    
    # 1. Obtener informacion de DISM
    $dismInfo = dism /Get-MountedImageInfo 2>$null
    
    # 2. Detectar si nuestra carpeta de montaje esta en estado "Needs Remount" o "Invalid"
    # Esto ocurre si apagaste el PC sin desmontar.
    $needsRemount = $dismInfo | Select-String -Pattern "Status : Needs Remount|Estado : Necesita volverse a montar|Status : Invalid|Estado : No v.lido"
    
    # 3. Detectar si la carpeta existe pero DISM no dice nada (Mount Fantasma)
    $ghostMount = $false
    if (Test-Path $Script:MOUNT_DIR) {
        try { $null = Get-ChildItem -Path $Script:MOUNT_DIR -ErrorAction Stop } catch { $ghostMount = $true }
    }

    if ($needsRemount -or $ghostMount) {
        [System.Console]::Beep(500, 300)
        Add-Type -AssemblyName System.Windows.Forms
        
        # MENSAJE ESTILO DISM++ (Reparar sesion existente)
        $msgResult = [System.Windows.Forms.MessageBox]::Show(
            "La imagen montada en '$($Script:MOUNT_DIR)' parece estar danada (posible cierre inesperado).`n`nQuieres intentar RECUPERAR la sesion (Remount-Image)?`n`n[Si] = Intentar reconectar y salvar cambios.`n[No] = Eliminar punto de montaje (Cleanup-Wim).", 
            "Recuperacion de Imagen", 
            [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, 
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )

        if ($msgResult -eq 'Yes') {
            Clear-Host
            Write-Host ">>> INTENTANDO RECUPERAR SESION (Remount-Image)..." -ForegroundColor Yellow
            
            # Intento de Remount
            dism /Remount-Image /MountDir:"$Script:MOUNT_DIR"
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[EXITO] Imagen recuperada." -ForegroundColor Green
                $Script:IMAGE_MOUNTED = 1
                
                # Intentamos re-leer que imagen es para actualizar las variables del script
                try {
                    $info = dism /Get-MountedImageInfo
                    $wimLine = $info | Select-String -Pattern "Image File|Archivo de imagen" | Select -First 1
                    if ($wimLine) { 
                        $rawLine = $wimLine.Line
                        $colonIdx = $rawLine.IndexOf(':')
                        if ($colonIdx -ge 0) {
                            $Script:WIM_FILE_PATH = $rawLine.Substring($colonIdx + 1).Trim()
                            if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
                        }
                    }
                    $idxLine = $info | Select-String -Pattern "Image Index|ndice de imagen" | Select -First 1
                    if ($idxLine) { $Script:MOUNTED_INDEX = ($idxLine.Line -split ':', 2)[1].Trim() }
                } catch {}

                [System.Windows.Forms.MessageBox]::Show("Imagen recuperada correctamente.", "Exito", 'OK', 'Information')
            } else {
                Write-Host "Fallo la recuperacion (Codigo: $LASTEXITCODE)."
                [System.Windows.Forms.MessageBox]::Show("No se pudo recuperar la sesion. Se recomienda limpiar.", "Error", 'OK', 'Error')
            }
        }
        elseif ($msgResult -eq 'No') {
            Write-Host ">>> LIMPIANDO PUNTO DE MONTAJE (Cleanup-Wim)..." -ForegroundColor Red
            Unmount-Hives
            dism /Cleanup-Wim
            $Script:IMAGE_MOUNTED = 0
            [System.Windows.Forms.MessageBox]::Show("Limpieza completada. Debes montar la imagen de nuevo.", "Limpieza", 'OK', 'Information')
        }
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
        Write-Host "       Gestion de Arranque y Medios (Boot Tools)       " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Editar boot.wim (Inyectar DaRT/Drivers)" -ForegroundColor Yellow
        Write-Host "       (Modifica el entorno de instalacion o rescate)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Crear ISO Booteable" -ForegroundColor White
        Write-Host "       (Genera una ISO compatible con BIOS/UEFI)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Despliegue a VHD / Disco Fisico" -ForegroundColor White
        Write-Host "       (Aplica una imagen WIM/ESD a un VHDX o disco USB/externo)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
        Write-Host ""

        $bootOpt = (Read-Host " Elige una opcion").Trim().ToUpper()
        switch ($bootOpt) {
            "1" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Manage-BootWim-Menu'"; Manage-BootWim-Menu }
            "2" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-IsoMaker-GUI'"; Show-IsoMaker-GUI }
            "3" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-Deploy-To-VHD-GUI'"; Show-Deploy-To-VHD-GUI }
            "V" { Write-Log -LogLevel INFO -Message "MenuBoot: Volviendo al menu principal"; return }
            default {
                Write-Log -LogLevel WARN -Message "MenuBoot: Opcion invalida seleccionada ($bootOpt)."
                Write-Warning "Opcion invalida"
            }
        }
    }
}

# :main_menu (Funcion principal que muestra el menu inicial)
function Main-Menu {
    $Host.UI.RawUI.WindowTitle = "AdminImagenOffline v$($script:Version) by SOFTMAXTER | Panel de Control"

    # --- Constantes de presentacion (calculadas una sola vez, fuera del bucle) ---
    $width        = 80
    $separator    = "=" * $width
    $separatorMid = "-" * $width
    $title        = "ADMINISTRADOR DE IMAGEN OFFLINE"
    $verStr       = "v$($script:Version)"
    $auth         = "by SOFTMAXTER"

    # --- Estado de la cache (evita consultas repetitivas a DISM) ---
    $cachedImageName = "---"
    $cachedImageVer  = "---"
    $cachedImageArch = "---"
    $lastMountState  = -1

    while ($true) {
        Clear-Host
        
        # --- 1. LÓGICA DE ACTUALIZACIÓN (Solo si cambia el estado) ---
        if ($Script:IMAGE_MOUNTED -ne $lastMountState -or $Script:ForceMenuRefresh) {
            $lastMountState = $Script:IMAGE_MOUNTED
            
            $Script:ForceMenuRefresh = $false
            
            if ($Script:IMAGE_MOUNTED -eq 1 -or $Script:IMAGE_MOUNTED -eq 2) {
                Write-Host "Leyendo metadatos del sistema operativo..." -ForegroundColor DarkGray
                
                # ESTRATEGIA 1: LECTURA FÍSICA DIRECTA (Velocidad de la luz, unifica WIM y VHD)
                $sysDir = "$Script:MOUNT_DIR\Windows"
                $kernelFile = "$sysDir\System32\ntoskrnl.exe"
                
                # A) Detección de Arquitectura por estructura de carpetas (Instantáneo)
                if     (Test-Path "$sysDir\SysArm32") { $cachedImageArch = "ARM64" }
                elseif (Test-Path "$sysDir\SysWOW64") { $cachedImageArch = "x64" }
                elseif (Test-Path "$sysDir\System32") { $cachedImageArch = "x86" }
                else                                  { $cachedImageArch = "Desconocida" }

                # B) Extracción de Versión via Kernel (Bypass total al registro y a DISM)
                if (Test-Path $kernelFile) {
                    $verInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($kernelFile)
                    $cachedImageVer = "{0}.{1}.{2}.{3}" -f $verInfo.FileMajorPart, $verInfo.FileMinorPart, $verInfo.FileBuildPart, $verInfo.FilePrivatePart
                } else {
                    $cachedImageVer = "Desconocida"
                }

                # C) Nombre de la Edición (Resolución Inteligente)
                $cachedImageName = if ($Script:IMAGE_MOUNTED -eq 1) { "Imagen WIM" } else { "VHD Nativo" }
                
                # Chequeo dinámico: Si las colmenas Offline YA están montadas (Cero coste I/O)
                if (Test-Path "Registry::HKLM\OfflineSoftware") {
                    $regData = Get-ItemProperty -Path "Registry::HKLM\OfflineSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
                    if ($regData) {
                        if ($regData.ProductName)                            { $cachedImageName = $regData.ProductName }
                        if ($regData.CurrentBuildNumber -and $regData.UBR) { $cachedImageVer  = "10.0.$($regData.CurrentBuildNumber).$($regData.UBR)" }
                    }
                }
                else {
                    # Fallback unificado WIM + VHD: ambas tienen identica estructura en MOUNT_DIR.
                    # Elimina Get-WindowsImage del caso WIM (era el cuello de botella de 1-3 s).
                    $softwareHive = "$sysDir\System32\config\SOFTWARE"
                    if (Test-Path $softwareHive) {
                        $tempHive = "HKLM\TempDash_$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
                        reg load $tempHive $softwareHive 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) {
                            try {
                                $regData = Get-ItemProperty -Path "Registry::$tempHive\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
                                if ($regData.ProductName)                            { $cachedImageName = $regData.ProductName }
                                if ($regData.CurrentBuildNumber -and $regData.UBR) { $cachedImageVer  = "10.0.$($regData.CurrentBuildNumber).$($regData.UBR)" }
                            } finally {
                                [GC]::Collect()
                                reg unload $tempHive 2>$null | Out-Null
                            }
                        }
                    }
                }
                Write-Log -LogLevel INFO -Message "Dashboard: Metadatos cacheados -> $cachedImageName | $cachedImageVer | $cachedImageArch"
            }
            else {
                # Nada montado
                $cachedImageName = "---"; $cachedImageVer = "---"; $cachedImageArch = "---"
            }
        }

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
        Write-Host " ESTADO ACTUAL:" -ForegroundColor Yellow
        Write-Host "  + Fuente      : " -NoNewline
        if ($Script:WIM_FILE_PATH) { 
            # Truncar ruta si es muy larga para que no rompa el diseno
            $displayPath = if ($Script:WIM_FILE_PATH.Length -gt 60) { "..." + $Script:WIM_FILE_PATH.Substring($Script:WIM_FILE_PATH.Length - 60) } else { $Script:WIM_FILE_PATH }
            Write-Host $displayPath -ForegroundColor White 
        } else { Write-Host "Ninguna seleccionada" -ForegroundColor DarkGray }

        Write-Host "  + Montaje     : " -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host "[WIM] EN EDICION"    -ForegroundColor Green   -NoNewline; Write-Host " (Indice: $Script:MOUNTED_INDEX)" -ForegroundColor Gray }
            2 { Write-Host "[VHD] DISCO VIRTUAL" -ForegroundColor Magenta -NoNewline; Write-Host " (Modo Directo)"                 -ForegroundColor Gray }
            Default { Write-Host "NO MONTADA" -ForegroundColor Red }
        }
        Write-Host ""

        # Mostrar detalles solo si esta montado
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "  + Detalles SO : " -NoNewline; Write-Host "$cachedImageName ($cachedImageArch)" -ForegroundColor Cyan
            Write-Host "  + Build       : " -NoNewline; Write-Host $cachedImageVer -ForegroundColor Cyan
            Write-Host "  + Directorio  : " -NoNewline; Write-Host $Script:MOUNT_DIR -ForegroundColor Gray
        }
        Write-Host $separator -ForegroundColor Cyan
        Write-Host ""

        # Menu de Opciones
        Write-Host " [ GESTION DE IMAGEN ]" -ForegroundColor Yellow
        Write-Host "   1. Montar / Desmontar / Guardar Imagen" 
        Write-Host "   2. Convertir Formatos (ESD -> WIM, VHD -> WIM)"
        Write-Host "   3. Herramientas de Arranque y Medios (Boot.wim, ISO, VHD)"
        Write-Host "   [U] Integrar Actualizaciones (install.wim, winre.wim, boot.wim y SetupDU)" -ForegroundColor Green
        Write-Host "   [M] Integrar Idiomas / Crear Medio Multilingue" -ForegroundColor Cyan
        Write-Host ""
        Write-Host " [ INGENIERIA & AJUSTES ]" -ForegroundColor Yellow
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "   4. Drivers (Inyectar/Eliminar)"                  -ForegroundColor White
            Write-Host "   5. Personalizacion (Apps, Tweaks, Unattend.xml)" -ForegroundColor White
            Write-Host "   6. Limpieza y Reparacion (DISM/SFC)"             -ForegroundColor White
            Write-Host "   7. Cambiar Edicion (Home -> Pro)"                -ForegroundColor White
        } else {
            # Opciones deshabilitadas visualmente
            Write-Host "   4. Drivers (Requiere Montaje)"               -ForegroundColor DarkGray
            Write-Host "   5. Personalizacion (Requiere Montaje)"        -ForegroundColor DarkGray
            Write-Host "   6. Limpieza y Reparacion (Requiere Montaje)"  -ForegroundColor DarkGray
            Write-Host "   7. Cambiar Edicion (Requiere Montaje)"        -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host " [ SISTEMA ]" -ForegroundColor Yellow
        Write-Host "   [R] Configuracion (Rutas)"
        Write-Host ""
        Write-Host $separatorMid
        Write-Host "   [L] Ver Logs   [H] Ayuda/Info   [S] Salir" -ForegroundColor Gray
        Write-Host ""

        # [FIX] .Trim() antes de .ToUpper() para tolerar espacios accidentales en el input
        $prompt  = if ($Script:IMAGE_MOUNTED -gt 0) { "Comando (Imagen Lista)" } else { "Seleccione una opcion" }
        $opcionM = (Read-Host " $prompt").Trim().ToUpper()
        
        # Manejo de Errores y Navegacion
        switch ($opcionM) {
            "1" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Image-Management-Menu'"; Image-Management-Menu }
            "2" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Convert-Image-Menu'";    Convert-Image-Menu    }
            "3" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Boot-Tools-Menu'";       Boot-Tools-Menu       }
            "U" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'WindowsUpdate-Menu'"; WindowsUpdate-Menu }
            "M" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'LanguagePack-Menu'"; LanguagePack-Menu }
            "4" { Invoke-IfMounted "Drivers-Menu"        { Drivers-Menu        } }
            "5" { Invoke-IfMounted "Customization-Menu"  { Customization-Menu  } }
            "6" { Invoke-IfMounted "Limpieza-Menu"       { Limpieza-Menu       } }
            "7" { Invoke-IfMounted "Cambio-Edicion-Menu" { Cambio-Edicion-Menu } }
            "R" { Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Show-ConfigMenu'"; Show-ConfigMenu }
            "L" {
                if ($null -ne $script:logFile -and (Test-Path $script:logFile)) {
                    Write-Log -LogLevel INFO -Message "MenuMain: El usuario abrio el archivo de Log principal."
                    Start-Process notepad.exe -ArgumentList $script:logFile
                } else {
                    Write-Log -LogLevel ERROR -Message "MenuMain: Intento de abrir el log fallido. El archivo no existe aun."
                    [System.Windows.Forms.MessageBox]::Show("El archivo de log aun no existe o la ruta no es valida.", "Error", 'OK', 'Error')
                }
            }
            "H" {
                Write-Log -LogLevel INFO -Message "MenuMain: El usuario abrio el panel 'Acerca de'."
                $msg = "AdminImagenOffline v$($script:Version)`n" +
                       "Desarrollado por SOFTMAXTER`n`n" +
                       "Email: softmaxter@hotmail.com`n" +
                       "Blog: softmaxter.blogspot.com`n`n" +
                       "Una suite integral para el mantenimiento proactivo de sistemas Windows."
                
                [System.Windows.Forms.MessageBox]::Show($msg, "Acerca de", 0, 64)
            }
            "S" { 
                Write-Log -LogLevel ACTION -Message "MenuMain: El usuario inicio la secuencia de salida del programa."
                if ($Script:IMAGE_MOUNTED -gt 0) {
                    [System.Console]::Beep(500, 300)
                    $confirmExit = Read-Host "¡Hay una imagen montada! Si sales ahora, quedara bloqueada en el sistema.`nDeseas GUARDAR LOS CAMBIOS y desmontarla antes de salir? (S/N/Cancelar)"
                    
                    if ($confirmExit -eq 'S') { 
                        Write-Log -LogLevel ACTION -Message "MenuExit: El usuario acepto desmontar (con guardado) antes de salir."
                        Unmount-Image -Commit
                        
                        # Validacion post-desmontaje (Previene el cierre si fallo DISM)
                        if ($Script:IMAGE_MOUNTED -eq 0) { exit }
                        else { 
                            Write-Log -LogLevel WARN -Message "MenuExit: Abortando salida. El desmontaje fracasó."
                            Write-Warning "No se pudo cerrar el programa de forma segura. Resuelve el error de DISM e intentalo de nuevo."
                            Start-Sleep -Seconds 3
                        }
                    }
                    elseif ($confirmExit -eq 'N') { 
                        Write-Log -LogLevel ERROR -Message "MenuExit: ALERTA - El usuario forzo la salida dejando una imagen montada (Huerfana)."
                        Write-Warning "Saliendo... La imagen quedara huerfana. Recuerda ejecutar 'Limpieza' en tu proxima sesion."
                        Start-Sleep -Seconds 2
                        exit 
                    }
                    else {
                        Write-Log -LogLevel INFO -Message "MenuExit: El usuario cancelo la salida. Volviendo al menu."
                    }
                } else {
                    Write-Log -LogLevel INFO -Message "MenuExit: Saliendo del programa limpiamente (Sin imagenes montadas)."
                    Write-Host "Hasta luego, Ingeniero." -ForegroundColor Green
                    Start-Sleep -Seconds 1
                    exit 
                }
            }
            default { 
                Write-Host " Opcion no valida. Intente de nuevo." -ForegroundColor Red -BackgroundColor Black
                Start-Sleep -Milliseconds 500
            }
        }
    }
}

# Pequeña funcion auxiliar para evitar repetir el mensaje de error
function Show-Mount-Warning {
    [System.Console]::Beep(400, 200)
    Write-Host " [!] ACCION BLOQUEADA: Debe montar una imagen primero (Opcion 1)." -ForegroundColor Yellow -BackgroundColor DarkRed
    Start-Sleep -Seconds 2
}

# =================================================================
#  Verificacion de Montaje Existente
# =================================================================
$Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null
$TEMP_DISM_OUT = Join-Path $env:TEMP "dism_check_$([System.Guid]::NewGuid().ToString('N').Substring(0,8)).tmp"

Write-Host "Verificando imagenes montadas..." -ForegroundColor Gray

# --- PASO 1: DETECCION WIM/ESD (DISM) ---
try {
    # Capturamos salida a archivo para evitar problemas de codificacion
    dism /get-mountedimageinfo 2>$null | Out-File -FilePath $TEMP_DISM_OUT -Encoding utf8
    $mountInfo = Get-Content -Path $TEMP_DISM_OUT -Encoding utf8 -ErrorAction SilentlyContinue
    
    # Busca "Mount Dir :" O "Directorio de montaje :"
    $mountDirLine = $mountInfo | Select-String -Pattern "(Mount Dir|Directorio de montaje)\s*:" | Select-Object -First 1
    
    if ($mountDirLine) {
        $foundPath = ($mountDirLine.Line -split ':', 2)[1].Trim()
        
        # Validacion extra: DISM a veces reporta carpetas que ya no existen
        if (Test-Path $foundPath) {
            $Script:IMAGE_MOUNTED = 1
            $Script:MOUNT_DIR = $foundPath
            
            # Buscar Ruta del Archivo de Imagen
            $wimPathLine = $mountInfo | Select-String -Pattern "(Image File|Archivo de imagen)\s*:" | Select-Object -First 1
            if ($wimPathLine) {
                $rawLine = $wimPathLine.Line
                $colonIdx = $rawLine.IndexOf(':')
                if ($colonIdx -ge 0) {
                    $Script:WIM_FILE_PATH = $rawLine.Substring($colonIdx + 1).Trim()
                    if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
                }
            }

            # Buscar Indice
            $indexLine = $mountInfo | Select-String -Pattern "(Image Index|ndice de imagen)\s*:" | Select-Object -First 1
            if ($indexLine) { $Script:MOUNTED_INDEX = ($indexLine.Line -split ':', 2)[1].Trim() }
            
            Write-Log -LogLevel INFO -Message "WIM Detectado: $Script:WIM_FILE_PATH en $Script:MOUNT_DIR"
        }
    }
} catch {
    Write-Log -LogLevel WARN -Message "Error verificando DISM: $($_.Exception.Message)"
} finally {
    if (Test-Path $TEMP_DISM_OUT) { Remove-Item -Path $TEMP_DISM_OUT -Force -ErrorAction SilentlyContinue }
}

# --- PASO 2: DETECCION VHD/VHDX (Powershell Storage) ---
# Solo buscamos VHD si no encontramos un WIM montado (Prioridad WIM)
if ($Script:IMAGE_MOUNTED -eq 0) {
    try {
        # 1. Obtener discos virtuales
        # Buscamos discos cuyo BusType sea virtual o el modelo indique que lo es
        $vDisks = Get-Disk | Where-Object { $_.BusType -eq 'FileBackedVirtual' -or $_.Model -match "Virtual Disk" }

        foreach ($disk in $vDisks) {
            # 2. Obtener TODAS las particiones con letra de unidad valida
            # (Quitamos el Select-Object -First 1 para no quedarnos solo con la EFI)
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }

            foreach ($part in $partitions) {
                $rootPath = "$($part.DriveLetter):\"

                # 3. HEURISTICA: Es esta particion específica una instalacion de Windows?
                if (Test-Path "$rootPath\Windows\System32\config\SYSTEM") {

                    # ENCONTRADO!
                    $Script:IMAGE_MOUNTED = 2 # Estado 2 = VHD
                    $Script:MOUNT_DIR = $rootPath
                    $Script:MOUNTED_INDEX = $part.PartitionNumber

                    # Intentar recuperar la ruta del archivo .vhdx original
                    try {
                        if (Get-Command Get-VHD -ErrorAction SilentlyContinue) {
                            $vhdData = Get-VHD -DiskNumber $disk.Number -ErrorAction Stop
                            $Script:WIM_FILE_PATH = $vhdData.Path
                        } else {
                            $Script:WIM_FILE_PATH = "Disco Virtual (Disk $($disk.Number))" 
                        }
                    } catch {
                        $Script:WIM_FILE_PATH = "Disco Virtual Desconocido"
                    }

                    Write-Host "VHD Detectado: $Script:WIM_FILE_PATH" -ForegroundColor Yellow
                    Write-Host "Montado en: $Script:MOUNT_DIR" -ForegroundColor Yellow
                    Write-Log -LogLevel INFO -Message "VHD Recuperado: $Script:WIM_FILE_PATH en $Script:MOUNT_DIR"
                    break 
                }
            }
            # Si ya encontramos imagen (IMAGE_MOUNTED=2), rompemos el bucle de discos tambien
            if ($Script:IMAGE_MOUNTED -eq 2) { break }
        }
    } catch {
        Write-Log -LogLevel WARN -Message "Error verificando VHDs: $($_.Exception.Message)"
    }
}

# --- REPORTE FINAL ---
if ($Script:IMAGE_MOUNTED -eq 0) {
    Write-Log -LogLevel INFO -Message "No se encontraron imagenes montadas previamente."
} elseif ($Script:IMAGE_MOUNTED -eq 1) {
    Write-Host "Imagen WIM encontrada: $($Script:WIM_FILE_PATH)" -ForegroundColor Yellow
    Write-Host "Indice: $($Script:MOUNTED_INDEX) | Montada en: $($Script:MOUNT_DIR)" -ForegroundColor Yellow
    
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
# REGISTRO DE EVENTO DE SALIDA (Para capturar cierre de ventana "X")
$OnExitScript = {
    # Solo intentamos desmontar si detectamos que se quedaron montados
    if (Test-Path "Registry::HKLM\OfflineSystem") {
        Write-Host "`n[EVENTO SALIDA] Detectado cierre inesperado. Limpiando Hives..." -ForegroundColor Red
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
    Write-Host "             ¡ERROR CRITICO DEL SISTEMA!               " -ForegroundColor Red
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Ha ocurrido un error inesperado que detuvo la ejecucion." -ForegroundColor Gray
    Write-Host "Error: " -NoNewline; Write-Host $_.ToString() -ForegroundColor Yellow
    Write-Host "Línea: " -NoNewline; Write-Host $line -ForegroundColor Cyan
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
    Write-Host "El detalle tecnico forense se ha guardado en el archivo de registro (Logs\Registro.log)." -ForegroundColor Gray
    Write-Warning "El sistema intentara desmontar las colmenas y limpiar el entorno automaticamente."
    Pause
}

finally {
    # ESTO SE EJECUTA SIEMPRE: Ya sea que salgas bien, por error, o con CTRL+C
    Write-Host "`n[SISTEMA] Finalizando y asegurando limpieza..." -ForegroundColor DarkGray
    
    # 1. Asegurar descarga de Hives
    Unmount-Hives
    
    # 2. Desregistrar el evento para no dejar basura en la sesion de PS
    Unregister-Event -SourceIdentifier PowerShell.Exiting -ErrorAction SilentlyContinue
    
    Write-Log -LogLevel INFO -Message "Cierre de sesion completado."
}