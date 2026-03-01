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
    1.5.0

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
$script:Version = "1.5.0"

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
    
    try {
        $parentDir = Split-Path -Parent $PSScriptRoot
        $logDir = Join-Path -Path $parentDir -ChildPath "Logs"
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force | Out-Null
        }
        $logFile = Join-Path -Path $logDir -ChildPath "Registro.log"
        
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $logFile -Append -Encoding utf8
    }
    catch {
        Write-Warning "No se pudo escribir en el archivo de log: $_"
    }
}

# --- INICIO DEL MODULO DE AUTO-ACTUALIZACION ---
function Invoke-FullRepoUpdater {
    # --- CONFIGURACION ---
    $repoUser = "SOFTMAXTER"
    $repoName = "AdminImagenOffline"
    $repoBranch = "main"
    
    # URLs directas
    $versionUrl = "https://raw.githubusercontent.com/$repoUser/$repoName/$repoBranch/version.txt"
    $zipUrl = "https://github.com/$repoUser/$repoName/archive/refs/heads/$repoBranch.zip"
    
    $updateAvailable = $false
    $remoteVersionStr = ""

    try {
        Write-Host "Buscando actualizaciones..." -ForegroundColor Gray
        # Timeout corto para no afectar el inicio si no hay red
        $response = Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 5 -ErrorAction Stop
        $remoteVersionStr = $response.Content.Trim()

        # --- LOGICA ROBUSTA DE VERSIONADO ---
        try {
            $localV = [System.Version]$script:Version
            $remoteV = [System.Version]$remoteVersionStr
            
            if ($remoteV -gt $localV) {
                $updateAvailable = $true
            }
        }
        catch {
            # Fallback: Comparacion de texto simple si el formato no es estandar
            if ($remoteVersionStr -ne $script:Version) { 
                $updateAvailable = $true 
            }
        }
    }
    catch {
        # Silencioso si no hay conexion, no es critico
        return
    }

    # --- Si hay una actualizacion, preguntamos al usuario ---
    if ($updateAvailable) {
        Write-Host "`n¡Nueva version encontrada!" -ForegroundColor Green
        Write-Host ""
		Write-Host "Version Local: v$($script:Version)" -ForegroundColor Gray
        Write-Host "Version Remota: v$remoteVersionStr" -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "UPDATER: Nueva version detectada. Local: v$($script:Version) | Remota: v$remoteVersionStr"
        
		Write-Host ""
        $confirmation = Read-Host "Deseas descargar e instalar la actualizacion ahora? (S/N)"
        
        if ($confirmation.ToUpper() -eq 'S') {
            Write-Warning "`nEl actualizador se ejecutara en una nueva ventana."
            Write-Warning "Este script principal se cerrara para permitir la actualizacion."
            Write-Log -LogLevel ACTION -Message "UPDATER: Iniciando proceso de actualizacion. El script se cerrara."
            
            # --- Preparar el script del actualizador externo ---
            $tempDir = Join-Path $env:TEMP "AdminUpdater"
            if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
            New-Item -Path $tempDir -ItemType Directory | Out-Null
            
            $updaterScriptPath = Join-Path $tempDir "updater.ps1"
            $installPath = (Split-Path -Path $PSScriptRoot -Parent)
            $batchPath = Join-Path $installPath "Run.bat"

            # Contenido del script temporal
            $updaterScriptContent = @"
param(`$parentPID)
`$ErrorActionPreference = 'Stop'
`$Host.UI.RawUI.WindowTitle = 'PROCESO DE ACTUALIZACION DE AdminImagenOffline - NO CERRAR'

# Funcion auxiliar para logs del actualizador
function Write-UpdateLog { param([string]`$msg) Write-Host "`n`$msg" -ForegroundColor Cyan }

try {
    `$tempDir_updater = "$tempDir"
    `$tempZip_updater = Join-Path "`$tempDir_updater" "update.zip"
    `$tempExtract_updater = Join-Path "`$tempDir_updater" "extracted"

    Write-UpdateLog "[PASO 1/6] Descargando la nueva version v$remoteVersionStr..."
    Invoke-WebRequest -Uri "$zipUrl" -OutFile "`$tempZip_updater"

    Write-UpdateLog "[PASO 2/6] Descomprimiendo archivos..."
    Expand-Archive -Path "`$tempZip_updater" -DestinationPath "`$tempExtract_updater" -Force
    
    # GitHub extrae en una subcarpeta
    `$updateSourcePath = (Get-ChildItem -Path "`$tempExtract_updater" -Directory | Select-Object -First 1).FullName

    Write-UpdateLog "[PASO 3/6] Esperando a que el proceso principal finalice..."
    try {
        # Espera segura con Timeout para no colgarse
        Get-Process -Id `$parentPID -ErrorAction Stop | Wait-Process -ErrorAction Stop -Timeout 30
    } catch {
        Write-Host "   - El proceso principal ya ha finalizado." -ForegroundColor Gray
    }

    Write-UpdateLog "[PASO 4/6] Preparando instalacion (limpiando archivos antiguos)..."
    
    # --- EXCLUSIONES ESPECIFICAS DE AdminImagenOffline ---
    `$itemsToRemove = Get-ChildItem -Path "$installPath" -Exclude "Logs", "config.json", "sxs"
    if (`$null -ne `$itemsToRemove) { 
        Remove-Item -Path `$itemsToRemove.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-UpdateLog "[PASO 5/6] Instalando nuevos archivos..."
    Copy-Item -Path "`$updateSourcePath\*" -Destination "$installPath" -Recurse -Force
    
    # Desbloqueamos los archivos descargados
    Get-ChildItem -Path "$installPath" -Recurse | Unblock-File -ErrorAction SilentlyContinue

    Write-UpdateLog "[PASO 6/6] ¡Actualizacion completada con exito!"
    Write-Host "`nReiniciando AdminImagenOffline en 5 segundos..." -ForegroundColor Green
    Start-Sleep -Seconds 5
    
    # Limpieza y reinicio
    Remove-Item -Path "`$tempDir_updater" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -FilePath "$batchPath"
}
catch {
    `$errFile = Join-Path "`$env:TEMP" "AdminImagenOfflineUpdateError.log"
    "ERROR FATAL DE ACTUALIZACION: `$_" | Out-File -FilePath `$errFile -Force
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show("La actualizacion fallo.`nRevisa: `$errFile", "Error AdminImagenOffline", 'OK', 'Error')
    exit 1
}
"@
            # Guardar el script del actualizador con codificacion UTF8 limpia
            $utf8NoBom = New-Object System.Text.UTF8Encoding $false
            [System.IO.File]::WriteAllText($updaterScriptPath, $updaterScriptContent, $utf8NoBom)
            
            # Lanzar el actualizador y cerrar
            $launchArgs = "/c start `"PROCESO DE ACTUALIZACION`" powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$updaterScriptPath`" -parentPID $PID"
            Start-Process cmd.exe -ArgumentList $launchArgs -WindowStyle Normal
            
            exit
        } else {
            Write-Host "`nActualizacion omitida por el usuario." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

# Ejecutar el actualizador DESPUES de definir la version
Invoke-FullRepoUpdater

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
# --- Verificacion de Privilegios de Administrador ---
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Warning "Este script necesita ser ejecutado como Administrador."
    Write-Host "Por favor, cierra esta ventana, haz clic derecho en el archivo del script y selecciona 'Ejecutar como Administrador'."
    Read-Host "Presiona Enter para salir."
    exit
}

try {
    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
    $name = "LongPathsEnabled"
    
    # Obtenemos la propiedad; si no existe, no arrojará error gracias a SilentlyContinue
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
#  Registro Inicial
# =================================================================
# --- Rutas de Log (Definidas aqui para usar Write-Log inmediatamente) ---
try {
    # Si $PSScriptRoot es null (ejecutando seleccion en ISE), usar directorio actual como fallback
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    # Determinar directorio padre (asumiendo que puede estar en /bin o no)
    $parentDir = Split-Path -Parent $scriptRoot
    $script:logDir = Join-Path -Path $parentDir -ChildPath "Logs"
    if (-not (Test-Path $script:logDir)) {
        New-Item -Path $script:logDir -ItemType Directory -Force | Out-Null
    }
    $script:logFile = Join-Path -Path $script:logDir -ChildPath "Registro.log"
} catch {
    Write-Warning "No se pudo crear el directorio de Logs. El registro de eventos se desactivara. Error: $_"
    $script:logFile = $null
}

Write-Log -LogLevel INFO -Message "================================================="
Write-Log -LogLevel INFO -Message "AdminImagenOffline v$($script:Version) iniciado en modo Administrador."

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
# ERROR PRESERVADO (inicialmente): Se usa el valor por defecto que podria no existir
$Script:Scratch_DIR = $defaultScratchDir 
$Script:IMAGE_MOUNTED = 0
$Script:MOUNTED_INDEX = $null

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
#  FUNCIONES DE ACCION (Montaje/Desmontaje)
# =============================================
function Mount-Image {
    Clear-Host
    Write-Log -LogLevel INFO -Message "MountManager: Iniciando solicitud de montaje de imagen."

    if ($Script:IMAGE_MOUNTED -eq 1) {
        Write-Log -LogLevel WARN -Message "MountManager: Operacion cancelada. Ya existe una imagen montada en el entorno."
        Write-Warning "La imagen ya se encuentra montada."
        Pause; return
    }

    $path = Select-PathDialog -DialogType File -Title "Seleccione la imagen a montar" -Filter "Archivos Soportados (*.wim, *.vhd, *.vhdx)|*.wim;*.vhd;*.vhdx|Todos (*.*)|*.*"
    if ([string]::IsNullOrEmpty($path)) { 
        Write-Log -LogLevel INFO -Message "MountManager: El usuario cancelo el dialogo de seleccion de archivo."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    
    $Script:WIM_FILE_PATH = $path
    $extension = [System.IO.Path]::GetExtension($path).ToUpper()
    Write-Log -LogLevel INFO -Message "MountManager: Archivo seleccionado -> $Script:WIM_FILE_PATH | Formato detectado: $extension"

    # =======================================================
    #  MODO VHD / VHDX (LOGICA ROBUSTA)
    # =======================================================
    if ($extension -eq ".VHD" -or $extension -eq ".VHDX") {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "         MODO DE MONTAJE DE DISCO VIRTUAL (VHD)        " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "1. NO se usa la carpeta de montaje temporal."
        Write-Host "2. El VHD se monta como unidad nativa (Letra)."
        Write-Host "3. Los cambios son EN TIEMPO REAL." -ForegroundColor Red
        Write-Host ""
        
        Write-Log -LogLevel INFO -Message "MountManager: Cambiando a motor de virtualizacion (Hyper-V/VHD). Solicitando confirmacion al usuario."
        if ((Read-Host "Escribe 'SI' para adjuntar").ToUpper() -ne 'SI') {
            Write-Log -LogLevel INFO -Message "MountManager: El usuario aborto el montaje del disco virtual en la confirmacion."
            $Script:WIM_FILE_PATH = $null; return
        }

        try {
            Write-Host "[+] Montando VHD..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando Mount-VHD para adjuntar el disco virtual."
            $vhdInfo = Mount-VHD -Path $Script:WIM_FILE_PATH -PassThru -ErrorAction Stop
            
            # 1. Escaneo Inteligente de Particiones
            Write-Log -LogLevel INFO -Message "MountManager: Escaneando tabla de particiones del disco virtual montado."
            $targetPart = $null
            $partitions = Get-Partition -DiskNumber $vhdInfo.Number | Where-Object { $_.Size -gt 1GB } # Filtramos EFI/MSR

            foreach ($part in $partitions) {
                # Auto-Asignar letra si falta
                if (-not $part.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Write-Log -LogLevel INFO -Message "MountManager: Asignando letra temporal [$freeLet] a particion sin montar."
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction SilentlyContinue
                    $part.DriveLetter = $freeLet # Actualizamos objeto en memoria
                }
                
                # Verificar si es Windows
                if (Test-Path "$($part.DriveLetter):\Windows\System32\config\SYSTEM") {
                    $targetPart = $part
                    Write-Log -LogLevel INFO -Message "MountManager: Instalacion de Windows detectada automaticamente en particion [$($part.DriveLetter):]."
                    break 
                }
            }

            # 2. Seleccion (Automatica o Manual)
            if ($targetPart) {
                Write-Host "[AUTO] Windows detectado en particion $($targetPart.DriveLetter):" -ForegroundColor Green
                $selectedPart = $targetPart
            } else {
                # Fallback: Menu manual si no detectamos Windows
                Write-Log -LogLevel WARN -Message "MountManager: No se detecto instalacion de Windows. Lanzando seleccion manual de particion."
                Write-Warning "No se detecto una instalacion de Windows obvia."
                Write-Host "Seleccione la particion manualmente:" -ForegroundColor Cyan
                
                $menuItems = @{}
                $i = 1
                $allParts = Get-Partition -DiskNumber $vhdInfo.Number | Where-Object { $_.DriveLetter }
                
                foreach ($p in $allParts) {
                    $gb = [math]::Round($p.Size / 1GB, 2)
                    Write-Host "   [$i] Unidad $($p.DriveLetter): ($gb GB)"
                    $menuItems[$i] = $p
                    $i++
                }
                
                $choice = Read-Host "Numero de particion"
                if ($menuItems[$choice]) { 
                    $selectedPart = $menuItems[$choice] 
                    Write-Log -LogLevel INFO -Message "MountManager: El usuario selecciono manualmente la particion [$($selectedPart.DriveLetter):]."
                } else { 
                    throw "Seleccion invalida." 
                }
            }

            # 3. Configurar Entorno Global
            $driveLetter = "$($selectedPart.DriveLetter):\"
            $Script:MOUNT_DIR = $driveLetter
            $Script:IMAGE_MOUNTED = 2         # Estado 2 = VHD
            $Script:MOUNTED_INDEX = $selectedPart.PartitionNumber
            
            Write-Host "[OK] VHD Montado en: $Script:MOUNT_DIR" -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "MountManager: VHD Montado y vinculado exitosamente. Entorno local redireccionado a $Script:MOUNT_DIR"

        } catch {
            Write-Host "Error VHD: $_"
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo critico durante montaje/escaneo VHD: $($_.Exception.Message)"
            try { Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction SilentlyContinue } catch {}
            $Script:WIM_FILE_PATH = $null
        }
        Pause; return
    }

    # =======================================================
    #  MODO WIM (DISM)
    # =======================================================
    Write-Host "[+] Leyendo WIM..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "MountManager: Consultando a DISM la estructura de indices del archivo WIM."
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"

    $INDEX = Read-Host "`nNumero de indice a montar"
    Write-Log -LogLevel INFO -Message "MountManager: Indice seleccionado por el usuario -> [$INDEX]"
    
    # Limpieza proactiva de carpeta corrupta
    if ((Get-ChildItem $Script:MOUNT_DIR -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        Write-Log -LogLevel WARN -Message "MountManager: Se detectaron archivos residuales en la carpeta de montaje ($Script:MOUNT_DIR)."
        Write-Warning "El directorio de montaje no esta vacio ($Script:MOUNT_DIR)."
        if ((Read-Host "Limpiar carpeta? (S/N)") -match 'S') {
            Write-Log -LogLevel INFO -Message "MountManager: Ejecutando limpieza forzada (DISM /cleanup-wim y eliminacion recursiva) en la carpeta de montaje."
            dism /cleanup-wim
            Remove-Item "$Script:MOUNT_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            Write-Log -LogLevel INFO -Message "MountManager: El usuario declino limpiar la carpeta. Continuando asumiendo riesgo de montaje sobre directorio no vacio."
        }
    }

    Write-Host "[+] Montando (Indice: $INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando DISM /Mount-Wim para adjuntar indice $INDEX en $Script:MOUNT_DIR."
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        Write-Host "[OK] Imagen montada." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "MountManager: Montaje WIM completado exitosamente. Entorno listo para personalizacion."
    } else {
        Write-Host "[ERROR] Fallo montaje (Code: $LASTEXITCODE)."
        if ($LASTEXITCODE.ToString("X") -match "C1420116|C1420117") {
            Write-Warning "Posible bloqueo de archivos. Reinicia o ejecuta Limpieza."
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo montaje WIM. Codigo DISM ($LASTEXITCODE) indica directorio no vacio o error de acceso (C1420116/C1420117)."
        } else {
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo montaje WIM. Code: $LASTEXITCODE"
        }
    }
    Pause
}

function Unmount-Image {
    param([switch]$Commit)
    
    Clear-Host
    $modeText = if ($Commit) { "Commit (Guardar y Desmontar)" } else { "Discard (Descartar Cambios)" }
    Write-Log -LogLevel ACTION -Message "UnmountManager: Solicitud de desmontaje iniciada. Modo: [$modeText]"

    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Log -LogLevel WARN -Message "UnmountManager: Operacion rechazada. No hay ninguna imagen montada."
        Write-Warning "No hay ninguna imagen montada."
        Pause; return
    }

    # --- BLOQUEO ESD (Si el usuario intenta Guardar y Desmontar un ESD) ---
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')
    if ($Commit -and $isEsd) {
        Write-Log -LogLevel WARN -Message "UnmountManager: Bloqueo de seguridad activado. Intento de 'Commit' sobre archivo de compresion solida (.ESD)."
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "      OPERACION NO PERMITIDA EN ARCHIVOS .ESD          " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "No puedes hacer 'Guardar y Desmontar' sobre una imagen ESD comprimida." -ForegroundColor Red
        Write-Host "Debes usar la opcion 'Desmontar (Descartar Cambios)' o convertirla a WIM primero." -ForegroundColor Gray
        Pause
        return
    }

    Write-Host "[INFO] Iniciando secuencia de desmontaje segura..." -ForegroundColor Cyan

    # 1. Cierre proactivo de Hives (CRÍTICO)
    Write-Host "   > Descargando hives del registro..." -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "UnmountManager: Ejecutando Unmount-Hives para liberar bloqueos de registro."
    Unmount-Hives
    
    # 2. Garbage Collection para liberar handles de .NET
    Write-Log -LogLevel INFO -Message "UnmountManager: Forzando recoleccion de basura (.NET GC) para soltar handles residuales."
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    # 3. Desmontaje VHD (Lógica separada)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        try {
            Write-Host "   > Desmontando disco virtual (VHD)..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "UnmountManager: Ejecutando Dismount-VHD para el disco virtual en $Script:WIM_FILE_PATH"
            Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
            
            if ($Commit) {
                Write-Host "[OK] VHD Desmontado (Los cambios en VHD se guardan automaticamente en tiempo real)." -ForegroundColor Green
            } else {
                Write-Host "[OK] VHD Desmontado." -ForegroundColor Green
            }
            
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            Load-Config # Restaurar ruta original
            Write-Log -LogLevel INFO -Message "UnmountManager: Desmontaje de VHD exitoso. Entorno virtualizado cerrado."
        } catch {
            Write-Log -LogLevel ERROR -Message "UnmountManager: Fallo al desmontar VHD - $($_.Exception.Message)"
            Write-Error "Fallo al desmontar VHD: $_"
            Write-Warning "Cierre cualquier carpeta abierta en la unidad virtual e intente de nuevo."
        }
        Pause; return
    }

    # 4. Bucle de Reintentos para WIM (Resiliencia)
    $maxRetries = 3
    $retry = 0
    $success = $false
    
    # Determinamos los argumentos de DISM en base al parámetro $Commit
    $dismArg = if ($Commit) { "/commit" } else { "/discard" }
    $actionText = if ($Commit) { "Guardando y Desmontando (Commit)" } else { "Desmontando (Discard)" }

    Write-Log -LogLevel ACTION -Message "UnmountManager: Iniciando bucle de desmontaje WIM para '$Script:MOUNT_DIR' con parametros: $dismArg"

    while ($retry -lt $maxRetries -and -not $success) {
        $retry++
        Write-Host "   > Intento $retry de $($maxRetries): $actionText WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "UnmountManager: Ejecutando DISM (Intento $retry de $maxRetries)..."
        
        dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" $dismArg
        
        if ($LASTEXITCODE -eq 0) {
            $success = $true
        } else {
            Write-Warning "Fallo la operacion (Codigo: $LASTEXITCODE). Esperando 3 segundos..."
            Write-Log -LogLevel WARN -Message "UnmountManager: Intento $retry fallo con LASTEXITCODE $LASTEXITCODE. Pausando 3 segundos para liberar bloqueos."
            Start-Sleep -Seconds 3
            
            # Intento de limpieza intermedio
            if ($retry -eq 2) {
                Write-Host "   > Intentando limpieza de recursos (cleanup-wim)..." -ForegroundColor Red
                Write-Log -LogLevel WARN -Message "UnmountManager: Ejecutando DISM /cleanup-wim de emergencia antes del ultimo intento."
                dism /cleanup-wim
            }
        }
    }

    if ($success) {
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
        Write-Host "[OK] Imagen desmontada correctamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "UnmountManager: Operacion WIM completada exitosamente. Entorno local limpio."
    } else {
        Write-Host "[ERROR FATAL] No se pudo desmontar la imagen." -ForegroundColor Red
        Write-Host "Posibles causas: Antivirus escaneando, carpeta abierta en Explorador o CMD." -ForegroundColor Gray
        Write-Log -LogLevel ERROR -Message "UnmountManager: Fallo critico y definitivo al intentar desmontar el WIM tras $retry intentos. (Ultimo LASTEXITCODE: $LASTEXITCODE)"
    }
    Pause
}

function Reload-Image {
    param([int]$RetryCount = 0)

    Clear-Host
    
    if ($RetryCount -eq 0) {
        Write-Log -LogLevel ACTION -Message "ImageReloader: Solicitud de recarga de imagen (Reload) iniciada."
    }

    # Seguridad anti-bucle: Maximo 3 intentos
    if ($RetryCount -ge 3) {
        Write-Host "[ERROR FATAL] Se ha intentado recargar la imagen 3 veces sin exito."
        Write-Host "Es posible que un archivo este bloqueado por un Antivirus o el Explorador."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Abortado tras 3 intentos fallidos por bloqueos del sistema o antivirus."
        Pause
        return
    }

    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Log -LogLevel WARN -Message "ImageReloader: Operacion rechazada. No hay ninguna imagen montada en el sistema."
        Write-Warning "No hay imagen montada."; Pause; return 
    }
    
    # Asegurar descarga de Hives antes de recargar
    Write-Log -LogLevel INFO -Message "ImageReloader: [Intento $($RetryCount + 1)] Desmontando colmenas de registro residuales..."
    Unmount-Hives 

    Write-Host "Intento de recarga: $($RetryCount + 1)" -ForegroundColor DarkGray
    Write-Host "[+] Desmontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ImageReloader: Ejecutando DISM /Unmount-Wim con parametro /Discard..."
    
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Error al desmontar. Ejecutando limpieza profunda..."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Fallo el desmontaje (LASTEXITCODE: $LASTEXITCODE). Ejecutando DISM /Cleanup-Wim..."
        
        dism /cleanup-wim
        
        # --- Pausa de seguridad ---
        Write-Host "Esperando 5 segundos para liberar archivos..." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "ImageReloader: Forzando pausa de 5 segundos para liberar handles de archivos del sistema operativo."
        Start-Sleep -Seconds 5 
        # -----------------------------------------------
        
        # Llamada recursiva con contador incrementado
        Write-Log -LogLevel WARN -Message "ImageReloader: Iniciando llamada recursiva de recarga..."
        Reload-Image -RetryCount ($RetryCount + 1) 
        return
    }

    Write-Host "[+] Remontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ImageReloader: Imagen desmontada. Ejecutando DISM /Mount-Wim para restaurar el estado original."
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen recargada exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "ImageReloader: Recarga completada exitosamente. El entorno esta listo para seguir trabajando."
        $Script:IMAGE_MOUNTED = 1
    } else {
        Write-Host "[ERROR] Error al remontar la imagen."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Fallo critico al remontar la imagen. El entorno ha quedado desmontado. LASTEXITCODE: $LASTEXITCODE"
        $Script:IMAGE_MOUNTED = 0
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Guardar Cambios)
# =============================================
function Save-Changes {
    param ([string]$Mode) # 'Commit', 'Append' o 'NewWim'

    Write-Log -LogLevel INFO -Message "SaveManager: Solicitud de guardado iniciada. Modo solicitado: [$Mode]"

    # 1. Validacion de Montaje
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Log -LogLevel WARN -Message "SaveManager: Operacion rechazada. No hay ninguna imagen montada en el sistema."
        Write-Warning "No hay imagen montada para guardar."; Pause; return 
    }

    # 2. BLOQUEO VHD (Como discutimos antes)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel INFO -Message "SaveManager: Operacion omitida. El usuario esta trabajando sobre un VHD/VHDX (Guardado en tiempo real)."
        Clear-Host
        Write-Warning "AVISO: Estas trabajando sobre un disco virtual (VHD/VHDX)."
        Write-Host "Los cambios en VHD se guardan automaticamente en tiempo real al editar archivos." -ForegroundColor Cyan
        Write-Host "No es necesario (ni posible) ejecutar operaciones de 'Commit' o 'Capture' aqui." -ForegroundColor Gray
        Write-Host "Simplemente desmonta la imagen para finalizar." -ForegroundColor Yellow
        Pause
        return
    }

    Write-Host "Preparando para guardar..." -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "SaveManager: Asegurando que las colmenas de registro (Hives) esten desmontadas antes de llamar a DISM."
    Unmount-Hives

    # 3. BLOQUEO ESD
    # Verificamos si la extension original era .esd
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')

    if ($isEsd -and ($Mode -match 'Commit|Append|NewWim')) {
        Write-Log -LogLevel WARN -Message "SaveManager: Bloqueo de seguridad activado. Intento de escritura directa ('$Mode') sobre un archivo de compresion solida (.ESD)."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host "      OPERACION NO PERMITIDA EN ARCHIVOS .ESD          " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Has intentado hacer '$Mode' sobre una imagen ESD comprimida." -ForegroundColor Red
        Write-Host ""
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los archivos ESD son de 'compresion solida' y no admiten escritura incremental." -ForegroundColor Gray
        Write-Host "DISM fallara si intentas guardar cambios directamente sobre el archivo original." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    # 4. Logica Original (WIM con modo NewWim)
    if ($Mode -eq 'Commit') {
        Clear-Host
        Write-Host "[+] Guardando cambios en el indice $Script:MOUNTED_INDEX..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image para sobrescribir el indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    } 
    elseif ($Mode -eq 'Append') {
        Clear-Host
        Write-Host "[+] Guardando cambios en un nuevo indice (Append)..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image /Append para crear un indice nuevo en la imagen."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR" /append
    } 
    elseif ($Mode -eq 'NewWim') {
        Clear-Host
        Write-Host "--- Guardar como Nuevo Archivo WIM (Exportar Estado Actual) ---" -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "SaveManager: Modo NewWim (Capture-Image) activado. Solicitando ruta de destino y metadatos."
        
        # 1. Seleccionar destino
        if ($Script:WIM_FILE_PATH) {
            $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
            $baseName = $wimFileObject.BaseName
            $dirName = $wimFileObject.DirectoryName
        } else {
            $baseName = "Imagen"
            $dirName = "C:\"
        }
        
        $DEFAULT_DEST_PATH = Join-Path $dirName "${baseName}_MOD.wim"
        
        $DEST_WIM_PATH = Select-SavePathDialog -Title "Guardar copia como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
        if (-not $DEST_WIM_PATH) { 
            Write-Log -LogLevel INFO -Message "SaveManager: El usuario cancelo la seleccion de la ruta destino para NewWim."
            Write-Warning "Operacion cancelada."; return 
        }

        # Metadatos (Nombre)
        $defaultName = "Custom Image"
        try {
            $info = Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ErrorAction SilentlyContinue
            if ($info -and $info.ImageName) { $defaultName = $info.ImageName }
        } catch {}
        
        $IMAGE_NAME = Read-Host "Ingrese el NOMBRE para la imagen interna (Enter = '$defaultName')"
        if ([string]::IsNullOrWhiteSpace($IMAGE_NAME)) { $IMAGE_NAME = $defaultName }

        # --- Metadatos (Descripcion) ---
        $IMAGE_DESC = Read-Host "Ingrese la DESCRIPCION (Opcional)"
        if ([string]::IsNullOrWhiteSpace($IMAGE_DESC)) { $IMAGE_DESC = "Imagen creada con AdminImagenOffline" }
        
        Write-Host "`n[+] Capturando estado actual a nuevo WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Capture-Image desde la carpeta de montaje hacia '$DEST_WIM_PATH' (Nombre: $IMAGE_NAME)."
        
        dism /Capture-Image /ImageFile:"$DEST_WIM_PATH" /CaptureDir:"$Script:MOUNT_DIR" /Name:"$IMAGE_NAME" /Description:"$IMAGE_DESC" /Compress:max /CheckIntegrity

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Copia guardada exitosamente en:" -ForegroundColor Green
            Write-Host "     $DEST_WIM_PATH" -ForegroundColor Cyan
            Write-Host "`nNOTA: La imagen original sigue montada. Debes desmontarla (sin guardar) al salir." -ForegroundColor Gray
            Write-Log -LogLevel INFO -Message "SaveManager: Operacion NewWim completada exitosamente. Imagen original continua montada."
        } else {
            Write-Host "[ERROR] Fallo al capturar la nueva imagen (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "SaveManager: Fallo en DISM Capture-Image (NewWim). Codigo LASTEXITCODE: $LASTEXITCODE"
        }
        Pause
        return 
    }

    # Bloque comun para Commit/Append exitoso
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Cambios guardados." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "SaveManager: Cambios ($Mode) guardados exitosamente en la imagen original."
    } else {
        # Si llegamos aqui con un error, es un error legitimo de DISM (no por bloqueo de ESD)
        Write-Host "[ERROR] Fallo al guardar cambios (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "SaveManager: Fallo en DISM al guardar cambios ($Mode). Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Edicion de indices)
# =============================================
function Export-Index {
    Clear-Host
    Write-Log -LogLevel INFO -Message "IndexManager: Iniciando modulo de exportacion de indices WIM."

    if (-not $Script:WIM_FILE_PATH) {
        Write-Log -LogLevel INFO -Message "IndexManager: No hay un WIM global cargado. Solicitando archivo origen al usuario."
        $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM de origen" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) {
            Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion del archivo WIM de origen."
            Write-Warning "Operacion cancelada."
            Pause
            return
        }
        $Script:WIM_FILE_PATH = $path
        Write-Log -LogLevel INFO -Message "IndexManager: Archivo WIM de origen seleccionado -> $Script:WIM_FILE_PATH"
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: Usando archivo WIM global pre-cargado -> $Script:WIM_FILE_PATH"
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo origen."
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    
    $INDEX_TO_EXPORT = Read-Host "`nIngrese el numero de Indice que desea exportar"
    # Validar que INDEX_TO_EXPORT sea un numero valido podria añadirse aqui
    Write-Log -LogLevel INFO -Message "IndexManager: Indice objetivo ingresado por el usuario -> [$INDEX_TO_EXPORT]"

    $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $wimFileObject.DirectoryName "$($wimFileObject.BaseName)_indice_$($INDEX_TO_EXPORT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Exportar indice como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion de la ruta de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "IndexManager: Ruta de destino establecida -> $DEST_WIM_PATH"

    Write-Host "[+] Exportando Indice $INDEX_TO_EXPORT a '$DEST_WIM_PATH'..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "IndexManager: Ejecutando DISM /Export-Image para clonar el Indice $INDEX_TO_EXPORT de '$($Script:WIM_FILE_PATH)' hacia '$DEST_WIM_PATH'."
    
    dism /export-image /sourceimagefile:"$Script:WIM_FILE_PATH" /sourceindex:$INDEX_TO_EXPORT /destinationimagefile:"$DEST_WIM_PATH"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Indice exportado exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "IndexManager: Exportacion completada exitosamente. El indice $INDEX_TO_EXPORT ha sido extraido a un nuevo archivo."
    } else {
        Write-Host "[ERROR] Fallo al exportar el Indice (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "IndexManager: Fallo la exportacion del indice en DISM. Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}

function Delete-Index {
    Clear-Host
    Write-Log -LogLevel INFO -Message "IndexManager: Iniciando modulo de eliminacion de indices WIM."

    if (-not $Script:WIM_FILE_PATH) {
        Write-Log -LogLevel INFO -Message "IndexManager: No hay un WIM global cargado. Solicitando archivo al usuario."
        $path = Select-PathDialog -DialogType File -Title "Seleccione WIM para borrar indice" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) { 
            Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la seleccion del archivo WIM."
            Write-Warning "Operacion cancelada."; Pause; return 
        }
        $Script:WIM_FILE_PATH = $path
        Write-Log -LogLevel INFO -Message "IndexManager: Archivo WIM seleccionado -> $Script:WIM_FILE_PATH"
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: Usando archivo WIM global pre-cargado -> $Script:WIM_FILE_PATH"
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo."
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    
    $INDEX_TO_DELETE = Read-Host "`nIngrese el numero de Indice que desea eliminar"
    # Validar que INDEX_TO_DELETE sea un numero valido podria añadirse aqui
    Write-Log -LogLevel INFO -Message "IndexManager: Indice objetivo ingresado por el usuario -> [$INDEX_TO_DELETE]"

    $CONFIRM = Read-Host "Esta seguro que desea eliminar el Indice $INDEX_TO_DELETE de forma PERMANENTE? (S/N)"

    if ($CONFIRM -match '^(s|S)$') {
        Write-Host "[+] Eliminando Indice $INDEX_TO_DELETE..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "IndexManager: Ejecutando DISM /Delete-Image para eliminar el Indice $INDEX_TO_DELETE de '$($Script:WIM_FILE_PATH)'."
        
        dism /delete-image /imagefile:"$Script:WIM_FILE_PATH" /index:$INDEX_TO_DELETE
        
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Indice eliminado exitosamente." -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "IndexManager: Eliminacion completada exitosamente. Indice $INDEX_TO_DELETE purgado del WIM."
        } else {
            Write-Host "[ERROR] Error al eliminar el Indice (Codigo: $LASTEXITCODE). Puede que este montado o en uso."
            Write-Log -LogLevel ERROR -Message "IndexManager: Fallo la eliminacion del indice en DISM. Codigo LASTEXITCODE: $LASTEXITCODE. Posible bloqueo de archivo o WIM montado."
        }
    } else {
        Write-Log -LogLevel INFO -Message "IndexManager: El usuario cancelo la eliminacion en la confirmacion de seguridad."
        Write-Warning "Operacion cancelada."
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Conversion de Imagen)
# =============================================
function Convert-ESD {
    Clear-Host; Write-Host "--- Convertir ESD a WIM ---" -ForegroundColor Yellow
    
    Write-Log -LogLevel INFO -Message "ConvertESD: Iniciando modulo de conversion y descompresion (ESD -> WIM)."

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo ESD a convertir" -Filter "Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if (-not $path) { 
        Write-Log -LogLevel INFO -Message "ConvertESD: El usuario cancelo la seleccion del archivo de origen."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    $ESD_FILE_PATH = $path
    Write-Log -LogLevel INFO -Message "ConvertESD: Archivo origen seleccionado -> $ESD_FILE_PATH"

    Write-Host "[+] Obteniendo informacion de los indices del ESD..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ConvertESD: Consultando a DISM la estructura de indices del archivo."
    dism /get-wiminfo /wimfile:"$ESD_FILE_PATH"
    
    $INDEX_TO_CONVERT = Read-Host "`nIngrese el numero de indice que desea convertir"
    # Validar INDEX_TO_CONVERT
    Write-Log -LogLevel INFO -Message "ConvertESD: Indice objetivo ingresado por el usuario -> [$INDEX_TO_CONVERT]"

    $esdFileObject = Get-Item -Path $ESD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $esdFileObject.DirectoryName "$($esdFileObject.BaseName)_indice_$($INDEX_TO_CONVERT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Convertir ESD a WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "ConvertESD: El usuario cancelo la seleccion de la ruta de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "ConvertESD: Ruta de destino establecida -> $DEST_WIM_PATH"

    Write-Host "[+] Convirtiendo... Esto puede tardar varios minutos." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "ConvertESD: Ejecutando DISM /Export-Image del archivo '$ESD_FILE_PATH' (Indice: $INDEX_TO_CONVERT) hacia '$DEST_WIM_PATH'."
    
    dism /export-image /SourceImageFile:"$ESD_FILE_PATH" /SourceIndex:$INDEX_TO_CONVERT /DestinationImageFile:"$DEST_WIM_PATH" /Compress:max /CheckIntegrity

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Conversion completada exitosamente." -ForegroundColor Green
        Write-Host "Nuevo archivo WIM creado en: `"$DEST_WIM_PATH`"" -ForegroundColor Gray
        $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        Write-Host "La ruta del nuevo WIM ha sido cargada en el script." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "ConvertESD: Conversion completada exitosamente. Variable global del WIM actualizada a la nueva ruta."
    } else {
        Write-Host "[ERROR] Error durante la conversion (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "ConvertESD: Fallo la conversion en DISM. Codigo LASTEXITCODE: $LASTEXITCODE"
    }
    Pause
}

function Convert-VHD {
    Clear-Host
    Write-Host "--- Convertir VHD/VHDX a WIM (Auto-Mount) ---" -ForegroundColor Yellow
    
    Write-Log -LogLevel INFO -Message "ConvertVHD: Iniciando modulo de conversion inteligente de VHD/VHDX a WIM."

    # 1. Verificar modulo Hyper-V
    if (-not (Get-Command "Mount-Vhd" -ErrorAction SilentlyContinue)) {
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Faltan dependencias. El cmdlet 'Mount-Vhd' (Hyper-V) no esta disponible."
        Write-Host "[ERROR] El cmdlet 'Mount-Vhd' no esta disponible."
        Write-Warning "Necesitas habilitar el modulo de Hyper-V o las herramientas de gestion de discos virtuales."
        Pause; return
    }

    # 2. Seleccion de Archivo
    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo VHD o VHDX a convertir" -Filter "Archivos VHD (*.vhd, *.vhdx)|*.vhd;*.vhdx|Todos (*.*)|*.*"
    if (-not $path) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de origen."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    $VHD_FILE_PATH = $path
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo origen seleccionado -> $VHD_FILE_PATH"

    # 3. Seleccion de Destino
    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { 
        Write-Log -LogLevel INFO -Message "ConvertVHD: El usuario cancelo la seleccion del archivo de destino."
        Write-Warning "Operacion cancelada."; Pause; return 
    }
    Write-Log -LogLevel INFO -Message "ConvertVHD: Archivo destino establecido -> $DEST_WIM_PATH"

    # 4. Metadatos
    Write-Host "`n--- Ingrese los metadatos para la nueva imagen WIM ---" -ForegroundColor Yellow
    $inputName = Read-Host "Ingrese el NOMBRE de la imagen (ej: Captured VHD)"
    $inputDesc = Read-Host "Ingrese la DESCRIPCION de la imagen (Enter = Auto)"
    
    if ([string]::IsNullOrWhiteSpace($inputName)) { $IMAGE_NAME = "Captured VHD" } else { $IMAGE_NAME = $inputName }
    if ([string]::IsNullOrWhiteSpace($inputDesc)) { $IMAGE_DESC = "Convertido desde VHD el $(Get-Date -Format 'yyyy-MM-dd')" } else { $IMAGE_DESC = $inputDesc }

    Write-Log -LogLevel INFO -Message "ConvertVHD: Metadatos configurados -> Nombre: [$IMAGE_NAME] | Desc: [$IMAGE_DESC]"

    Write-Host "`n[+] Montando y analizando estructura del VHD..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "ConvertVHD: Iniciando proceso de montaje y analisis de particiones."

    $DRIVE_LETTER = $null
    $mountedDisk = $null

    try {
        # A. Montar VHD sin letra inicial
        $mountedDisk = Mount-Vhd -Path $VHD_FILE_PATH -PassThru -ErrorAction Stop
        
        # B. Obtener todas las particiones de DATOS (Ignoramos pequeñas tipo EFI/MSR < 2GB para ir rapido)
        #    Esto filtra basura y acelera el proceso.
        $partitions = Get-Partition -DiskNumber $mountedDisk.Number | Where-Object { $_.Size -gt 3GB }

        foreach ($part in $partitions) {
            $currentLet = $part.DriveLetter
            
            # --- LOGICA DE AUTO-ASIGNACIoN ---
            if (-not $currentLet) {
                # Buscar letra libre (Z hacia A)
                $usedLetters = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
                $alphabet = [char[]](90..65) # Z..A
                $freeLet = $null
                foreach ($l in $alphabet) { if ($usedLetters -notcontains $l) { $freeLet = $l; break } }

                if ($freeLet) {
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Asignando letra temporal [$freeLet] a particion sin montar."
                    Write-Host "   > Particion sin montar detectada. Asignando letra temporal $freeLet`:..." -ForegroundColor DarkGray
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction SilentlyContinue
                    $currentLet = $freeLet # Usamos esta letra para verificar
                }
            }

            # --- VERIFICACIoN DE WINDOWS ---
            if ($currentLet) {
                $winPath = "$currentLet`:\Windows\System32\config\SYSTEM"
                if (Test-Path $winPath) {
                    $DRIVE_LETTER = $currentLet
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Instalacion de Windows validada en la particion [$DRIVE_LETTER`]."
                    Write-Host "   [OK] Windows detectado en particion $DRIVE_LETTER`:" -ForegroundColor Green
                    break # ¡Encontrado! Dejamos de buscar.
                } else {
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Particion [$currentLet`] ignorada (No contiene instalacion de Windows)."
                    Write-Host "   [-] Particion $currentLet`: no contiene Windows. Ignorando." -ForegroundColor DarkGray
                }
            }
        }

        if (-not $DRIVE_LETTER) {
            Write-Log -LogLevel ERROR -Message "ConvertVHD: Fallo estructural. No se encontro ninguna instalacion de Windows valida en el VHD."
            throw "No se encontro ninguna instalacion de Windows valida en el VHD (se escanearon todas las particiones >3GB)."
        }

        Write-Host "   > Optimizando volumen antes de la captura (Trim)..." -ForegroundColor DarkGray
        Write-Log -LogLevel INFO -Message "ConvertVHD: Ejecutando Optimize-Volume (Trim) en el disco virtual."
        try {
            Optimize-Volume -DriveLetter $DRIVE_LETTER -ReTrim -ErrorAction Stop | Out-Null
        } catch {
            Write-Log -LogLevel WARN -Message "ConvertVHD: Omitiendo Trim. El volumen no lo soporta o esta en solo lectura. ($($_.Exception.Message))"
        }
        
        # 5. Captura (DISM)
        Write-Host "`n[+] Capturando volumen $DRIVE_LETTER`: a WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "ConvertVHD: Ejecutando DISM /Capture-Image del volumen [$DRIVE_LETTER`] hacia '$DEST_WIM_PATH'."

        dism /capture-image /imagefile:"$DEST_WIM_PATH" /capturedir:"$DRIVE_LETTER`:\" /name:"$IMAGE_NAME" /description:"$IMAGE_DESC" /compress:max /checkintegrity

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Captura completada exitosamente." -ForegroundColor Green
            $Script:WIM_FILE_PATH = $DEST_WIM_PATH
            Write-Log -LogLevel INFO -Message "ConvertVHD: Captura completada exitosamente. Archivo WIM generado."
        } else {
            Write-Host "[ERROR] Fallo DISM (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "ConvertVHD: DISM fallo con LASTEXITCODE: $LASTEXITCODE"
        }

    } catch {
        Write-Host "Error critico durante la conversion: $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "ConvertVHD: Excepcion critica durante la conversion - $($_.Exception.Message)"
    } finally {
        # 6. Limpieza Final (Importante)
        if ($mountedDisk) {
            Write-Log -LogLevel INFO -Message "ConvertVHD: Desmontando disco virtual y limpiando el entorno."
            Write-Host "[+] Desmontando VHD..." -ForegroundColor Yellow
            Dismount-Vhd -Path $VHD_FILE_PATH -ErrorAction SilentlyContinue
        }
        Pause
    }
}

# =================================================================
#  Modulo Avanzado: Gestor de Entorno de RecuperaciOn (WinRE)
# =================================================================
function Manage-WinRE-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "       Gestor Avanzado de Entorno de Recuperacion      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Iniciando el modulo de gestion de Entorno de Recuperacion."

    # Acepta tanto WIM (1) como VHD/VHDX (2)
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Write-Warning "Debes montar una imagen de sistema (install.wim o VHD/VHDX) primero."
        Write-Log -LogLevel WARN -Message "WinRE_Manager: Intento de acceso denegado. No hay imagen montada."
        Pause; return 
    }

    # Ruta estandar donde se esconde WinRE dentro del sistema (WIM o VHD)
    $winrePath = Join-Path $Script:MOUNT_DIR "Windows\System32\Recovery\winre.wim"
    
    if (-not (Test-Path -LiteralPath $winrePath)) {
        Write-Warning "No se encontro 'winre.wim' en la ruta habitual."
        Write-Host "Es posible que la imagen montada sea un boot.wim o que el WinRE ya haya sido eliminado." -ForegroundColor Gray
        Write-Log -LogLevel WARN -Message "WinRE_Manager: No se encontro winre.wim en la ruta esperada ($winrePath)."
        Pause; return
    }

    Write-Host "`n[1/5] Preparando entorno de trabajo temporal..." -ForegroundColor Yellow
    $winreStaging = Join-Path $Script:Scratch_DIR "WinRE_Staging"
    $winreMount = Join-Path $Script:Scratch_DIR "WinRE_Mount"

    Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando y creando directorios temporales de trabajo (Staging/Mount)."
    # Limpieza previa por si quedo basura de un intento anterior
    if (Test-Path $winreMount) { dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null }
    if (Test-Path $winreStaging) { Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue }
    
    New-Item -Path $winreStaging -ItemType Directory -Force | Out-Null
    New-Item -Path $winreMount -ItemType Directory -Force | Out-Null

    Write-Host "[2/5] Extrayendo winre.wim de la imagen principal..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Desbloqueando atributos del archivo original y copiando a Staging."
    
    # --- Manipulacion pura con .NET para evadir las restricciones de PowerShell ---
    $winreFile = Get-Item -LiteralPath $winrePath -Force
    $originalAttributes = $winreFile.Attributes
    $winreFile.Attributes = 'Normal'

    $tempWinrePath = Join-Path $winreStaging "winre.wim"
    Copy-Item -LiteralPath $winrePath -Destination $tempWinrePath -Force

    Write-Host "[3/5] Montando winre.wim (Esto puede tardar unos segundos)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Montando winre.wim temporal via DISM..."
    dism /mount-image /imagefile:"$tempWinrePath" /index:1 /mountdir:"$winreMount"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo montar winre.wim. Abortando..." -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Fallo critico al montar winre.wim. Codigo DISM: $LASTEXITCODE"
        dism /cleanup-wim | Out-Null
        # Restaurar atributos si falla el montaje
        $winreFile = Get-Item -LiteralPath $winrePath -Force
        $winreFile.Attributes = $originalAttributes
        Pause; return
    }

    Write-Host "[OK] WinRE Montado Exitosamente." -ForegroundColor Green
    Write-Log -LogLevel INFO -Message "WinRE_Manager: Montaje exitoso. Desviando variable global MOUNT_DIR hacia el entorno WinRE."
    Start-Sleep -Seconds 2

    $originalMountDir = $Script:MOUNT_DIR
    $Script:MOUNT_DIR = $winreMount

    try {
        # --- MINI-MENU DE EDICION WINRE ---
        $doneEditing = $false
        while (-not $doneEditing) {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "          MODO DE EDICION EN WINRE ACTIVO              " -ForegroundColor Magenta
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host "El entorno de recuperacion esta montado y listo."
            Write-Host "Puedes inyectar Addons (DaRT) y Drivers (VMD/RAID/Red)."
            Write-Host ""
            Write-Host "   [1] Inyectar Addons (.tpk, .bpk, .reg, .cab)"
            Write-Host "   [2] Inyectar Drivers (.inf)" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
            Write-Host ""
            
            $opcionRE = Read-Host " Elige una opcion"
            switch ($opcionRE.ToUpper()) {
                "1" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Addons."; Show-Addons-GUI }
                "2" { Write-Log -LogLevel INFO -Message "WinRE_Manager: Lanzando modulo de Drivers."; Show-Drivers-GUI }
                "T" { $doneEditing = $true; Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario termino la edicion interactiva." }
                default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
            }
        }

        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "              GUARDAR Y REINYECTAR WINRE               " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        $guardar = Read-Host "Deseas GUARDAR los cambios y devolver el winre.wim a la imagen principal? (S/N)"

        Write-Host "`n[4/5] Desmontando winre.wim..." -ForegroundColor Yellow
        if ($guardar.ToUpper() -eq 'S') {
            Write-Log -LogLevel ACTION -Message "WinRE_Manager: Iniciando proceso de guardado (Commit) de winre.wim..."
            dism /unmount-image /mountdir:"$winreMount" /commit
            
            if ($LASTEXITCODE -eq 0) {
                Write-Host "[5/5] Optimizando y Reinyectando winre.wim..." -ForegroundColor Yellow
                Enable-Privileges 
                
                # =========================================================
                #  MOTOR DE COMPRESION EXTREMA (EXPORT-IMAGE)
                # =========================================================
                $optimizedWinrePath = Join-Path $winreStaging "winre_optimized.wim"
                $sizeBefore = (Get-Item -LiteralPath $tempWinrePath).Length
                
                Write-Host "      -> Ejecutando reconstruccion de diccionario WIM (Tardara unos minutos)..." -ForegroundColor Cyan
                Write-Log -LogLevel ACTION -Message "WinRE_Manager: Ejecutando DISM /Export-Image para reconstruir el diccionario WIM y purgar peso muerto."
                
                $dismArgs = "/Export-Image /SourceImageFile:`"$tempWinrePath`" /SourceIndex:1 /DestinationImageFile:`"$optimizedWinrePath`" /Bootable"
                $proc = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru

                if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $optimizedWinrePath)) {
                    # Eliminamos el WinRE viejo e inflado de la imagen base
                    Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue
                    
                    # Movemos el nuevo y comprimido a su lugar
                    Move-Item -LiteralPath $optimizedWinrePath -Destination $winrePath -Force

                    # Restauramos los atributos originales de fabrica (+h +s) via .NET
                    $restoredFile = Get-Item -LiteralPath $winrePath -Force
                    $restoredFile.Attributes = $originalAttributes

                    $sizeAfter = (Get-Item -LiteralPath $winrePath).Length
                    $savedMB = [math]::Round(($sizeBefore - $sizeAfter) / 1MB, 2)
                    $finalMB = [math]::Round($sizeAfter / 1MB, 2)

                    Write-Host "[EXITO] WinRE optimizado e integrado correctamente." -ForegroundColor Green
                    Write-Host "        Tamano final: $finalMB MB (Ahorro de $savedMB MB de peso muerto)." -ForegroundColor DarkGreen
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Optimizacion exitosa. Tamano Final: $finalMB MB. Ahorro: $savedMB MB."
                } else {
                    Write-Host "[ADVERTENCIA] La compresion profunda fallo (Codigo: $($proc.ExitCode))." -ForegroundColor Red
                    Write-Host "              Aplicando metodo de volcado de emergencia..." -ForegroundColor Yellow
                    Write-Log -LogLevel ERROR -Message "WinRE_Manager: Fallo Export-Image (Codigo: $($proc.ExitCode)). Aplicando volcado basico de emergencia."
                    
                    # Fallback de Seguridad
                    Copy-Item -LiteralPath $tempWinrePath -Destination $winrePath -Force
                    $restoredFile = Get-Item -LiteralPath $winrePath -Force
                    $restoredFile.Attributes = $originalAttributes
                    Write-Host "[OK] WinRE guardado con exito (Sin compresion adicional)." -ForegroundColor Green
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Archivo guardado correctamente mediante volcado basico."
                }
            } else {
                Write-Host "[ERROR] Fallo al guardar winre.wim. La imagen principal no fue modificada." -ForegroundColor Red
                Write-Log -LogLevel ERROR -Message "WinRE_Manager: DISM fallo al hacer commit. Codigo de salida: $LASTEXITCODE"
            }
        } else {
            Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario eligio descartar los cambios (Discard)."
            dism /unmount-image /mountdir:"$winreMount" /discard
            Write-Host "Cambios descartados. La imagen principal no fue modificada." -ForegroundColor Gray
            
            # Restauramos atributos si descartamos los cambios
            $restoredFile = Get-Item -LiteralPath $winrePath -Force
            $restoredFile.Attributes = $originalAttributes
        }
    } finally {
        # --- RESTAURAR EL ESTADO GLOBAL (CRITICO) ---
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Restaurando variable global MOUNT_DIR y limpiando temporales."
        $Script:MOUNT_DIR = $originalMountDir
        
        # Limpieza de basura temporal
        Remove-Item $winreStaging -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $winreMount -Recurse -Force -ErrorAction SilentlyContinue
    }
    Pause
}

function Manage-BootWim-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "        Gestor Inteligente de Arranque (boot.wim)      " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Log -LogLevel INFO -Message "BootWimManager: Iniciando modulo de gestion de arranque (boot.wim)."

    # 1. Seguridad: Verificar que no haya nada montado
    if ($Script:IMAGE_MOUNTED -ne 0) {
        Write-Log -LogLevel WARN -Message "BootWimManager: Acceso bloqueado. Ya existe una imagen montada en $Script:MOUNT_DIR."
        Write-Warning "Ya tienes una imagen montada ($Script:MOUNT_DIR)."
        Write-Host "Debes desmontarla antes de editar el boot.wim para evitar conflictos." -ForegroundColor Gray
        Pause; return
    }

    # 2. Seleccionar archivo
    Write-Host "Selecciona tu archivo 'boot.wim'..." -ForegroundColor Yellow
    $bootPath = Select-PathDialog -DialogType File -Title "Selecciona boot.wim" -Filter "Archivos WIM|*.wim"
    if (-not $bootPath) { 
        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario cancelo la seleccion del archivo boot.wim."
        return 
    }

    Write-Log -LogLevel INFO -Message "BootWimManager: Archivo seleccionado -> $bootPath"

    # 3. Analizar Indices
    Write-Host "Analizando estructura del boot.wim..." -ForegroundColor DarkGray
    try {
        $images = Get-WindowsImage -ImagePath $bootPath
    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo al leer la estructura de indices del WIM. Probable corrupcion. - $($_.Exception.Message)"
        Write-Warning "Error leyendo el WIM. Esta corrupto?"
        Pause; return
    }

    Write-Host "`nIndices detectados:" -ForegroundColor Cyan
    $idxSetup = $null
    $idxPE = $null

    foreach ($img in $images) {
        $desc = "Generico"
        # Heuristica para identificar que es cada indice
        if ($img.ImageName -match "Setup|Installation|Instalar") { 
            $desc = "Instalador de Windows (Setup)"; $idxSetup = $img.ImageIndex 
        }
        elseif ($img.ImageName -match "PE|Preinstallation") { 
            $desc = "Windows PE (Rescate/Live)"; $idxPE = $img.ImageIndex 
        }
        
        Write-Log -LogLevel INFO -Message "BootWimManager: Indice detectado [$($img.ImageIndex)] $($img.ImageName) -> $desc"
        Write-Host "   [$($img.ImageIndex)] $($img.ImageName)" -NoNewline
        Write-Host " --> $desc" -ForegroundColor Yellow
    }
    Write-Host ""

    # 4. Seleccion Inteligente
    Write-Host "======================================================="
    Write-Host "Donde quieres inyectar DaRT/Addons?"
    Write-Host "   [1] En el Instalador (Indice $idxSetup)" -ForegroundColor White
    Write-Host "       (Aparecera al pulsar 'Reparar el equipo' durante la instalacion)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [2] En Windows PE (Indice $idxPE)" -ForegroundColor White
    Write-Host "       (Para crear un USB booteable exclusivo de diagnostico)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [M] Seleccion Manual (Si la deteccion fallo)" -ForegroundColor DarkGray
    
    $sel = Read-Host "Selecciona una opcion"
    $targetIndex = $null

    switch ($sel) {
        "1" { $targetIndex = $idxSetup }
        "2" { $targetIndex = $idxPE }
        "M" { $targetIndex = Read-Host "Introduce el numero de Indice manualmente" }
    }

    if (-not $targetIndex -or $targetIndex -eq "") { 
        Write-Log -LogLevel WARN -Message "BootWimManager: Seleccion de indice invalida o vacia."
        Write-Warning "Seleccion invalida."; Pause; return 
    }

    Write-Log -LogLevel INFO -Message "BootWimManager: Indice objetivo fijado en -> [$targetIndex]"

    # 5. Proceso de Montaje y Edicion
    try {
        # Configuramos las variables globales para engañar al resto del script
        $Script:WIM_FILE_PATH = $bootPath
        $Script:MOUNTED_INDEX = $targetIndex
        $Script:IMAGE_MOUNTED = 1 # Flag virtual activado
        
        # Limpieza previa
        Initialize-ScratchSpace

        # Montaje Real
        Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando montaje del boot.wim (Indice: $targetIndex)..."
        Write-Host "`n[+] Montando boot.wim (Indice $targetIndex)..." -ForegroundColor Yellow
        dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

        if ($LASTEXITCODE -eq 0) {
            Write-Log -LogLevel INFO -Message "BootWimManager: Montaje exitoso. Desplegando menu de edicion en vivo."
            # --- MINI-MENU DE EDICION BOOT.WIM ---
            $doneEditingBoot = $false
            while (-not $doneEditingBoot) {
                Clear-Host
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "             MODO EDICION BOOT.WIM ACTIVO              " -ForegroundColor Magenta
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host "Imagen montada en: $Script:MOUNT_DIR"
                Write-Host ""
                Write-Host "   [1] Inyectar Addons y Paquetes (Ej. DaRT)"
                Write-Host "   [2] Inyectar Drivers (.inf) -> Vital para detectar discos" -ForegroundColor Cyan
                Write-Host ""
                Write-Host "   [T] Terminar edicion y proceder a Guardar" -ForegroundColor Green
                Write-Host ""
                
                $opcionBoot = Read-Host " Elige una opcion"
                switch ($opcionBoot.ToUpper()) {
                    "1" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Addons."; Show-Addons-GUI }
                    "2" { Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Drivers."; Show-Drivers-GUI }
                    "T" { 
                        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario termino la edicion interactiva."
                        $doneEditingBoot = $true 
                    }
                    default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
                }
            }

            # Pregunta final
            Clear-Host
            Write-Host "======================================================="
            if ((Read-Host "Deseas GUARDAR los cambios en el boot.wim? (S/N)").ToUpper() -eq 'S') {
                Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando guardado de cambios (Commit) en boot.wim."
                Unmount-Image -Commit
            } else {
                Write-Log -LogLevel INFO -Message "BootWimManager: Descartando cambios (Discard) en boot.wim."
                Unmount-Image # Discard por defecto
            }

        } else {
            Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo critico al montar el boot.wim. Codigo DISM: $LASTEXITCODE"
            Write-Error "Fallo al montar el boot.wim."
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
            Pause
        }

    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Excepcion no controlada en el gestor de arranque - $($_.Exception.Message)"
        Write-Error "Error critico en el gestor de arranque: $_"
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
        Pause
    }
}

# =================================================================
#  MODULO DE INYECCION DE ADDONS (.TPK, .BPK, .REG, .CAB)
# =================================================================
# --- HELPER 1: Importador de Registro Silencioso (Headless) ---
# Extrae la lógica de tu Show-Tweaks-Offline-GUI para uso automatizado
function Import-OfflineReg {
    param([string]$FilePath)
    
    Write-Log -LogLevel INFO -Message "Procesando Registro Automatizado: $FilePath"
    
    # 1. Lectura Inteligente (Autodetección nativa de codificación)
    $content = Get-Content -Path $FilePath -Raw
    
    # 2. Traducción de Rutas (Motor Universal)
    $newContent = $content -replace "(?i)HKEY_LOCAL_MACHINE\\(SOFTWARE|TK_SOFTWARE)", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                           -replace "(?i)HKLM\\(SOFTWARE|TK_SOFTWARE)", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                           -replace "(?i)HKEY_LOCAL_MACHINE\\(SYSTEM|TK_SYSTEM)", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                           -replace "(?i)HKLM\\(SYSTEM|TK_SYSTEM)", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                           -replace "(?i)HKEY_CURRENT_USER\\(Software|TK_SOFTWARE)\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses" `
                           -replace "(?i)HKCU\\(Software|TK_SOFTWARE)\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses" `
                           -replace "(?i)HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE\\TK_USER", "HKEY_LOCAL_MACHINE\OfflineUser" `
                           -replace "(?i)HKCU", "HKEY_LOCAL_MACHINE\OfflineUser" `
                           -replace "(?i)HKEY_CLASSES_ROOT|HKEY_LOCAL_MACHINE\\TK_CLASSES", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes" `
                           -replace "(?i)HKCR", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"

    $tempReg = Join-Path $Script:Scratch_DIR "headless_import_$($RANDOM).reg"
    
    # regedit.exe requiere estrictamente UTF-16 LE (Unicode) para no corromper caracteres
    [System.IO.File]::WriteAllText($tempReg, $newContent, [System.Text.Encoding]::Unicode)

    # 3. Análisis y Desbloqueo de Claves
    $keysToProcess = New-Object System.Collections.Generic.HashSet[string]
    $pattern = '\[-?(HKEY_LOCAL_MACHINE\\(OfflineSoftware|OfflineSystem|OfflineUser|OfflineUserClasses|OfflineComponents)[^\]]*)\]'
    $matches = [regex]::Matches($newContent, $pattern)
                    
    foreach ($m in $matches) {
        $keyPath = $m.Groups[1].Value.Trim()
        if ($keyPath.StartsWith("-")) { $keyPath = $keyPath.Substring(1) }
        $null = $keysToProcess.Add($keyPath)
    }

    foreach ($targetKey in $keysToProcess) { Unlock-OfflineKey -KeyPath $targetKey }

    # 4. Importación con el motor tolerante a fallos (regedit.exe en lugar de reg.exe)
    $process = Start-Process regedit.exe -ArgumentList "/s `"$tempReg`"" -Wait -PassThru -WindowStyle Hidden
    
    # 5. Restauración Crítica de Permisos (Con escudo Anti-Comodines)
    foreach ($targetKey in $keysToProcess) {
        $psCheckPath = $targetKey -replace "^HKEY_LOCAL_MACHINE", "HKLM:"
        if (Test-Path -LiteralPath $psCheckPath) { Restore-KeyOwner -KeyPath $targetKey }
    }

    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue
}

# --- HELPER 2: Extractor Inteligente por Análisis de Cabecera ---
function Expand-AddonArchive {
    # AÑADIMOS EL PARÁMETRO $WimIndex
    param([string]$FilePath, [string]$DestPath, [int]$WimIndex = 1)
    
    $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = New-Object byte[] 4
    $stream.Read($buffer, 0, 4) | Out-Null
    $stream.Close()
    $hexSignature = [BitConverter]::ToString($buffer) -replace '-'

    if (-not (Test-Path $DestPath)) { New-Item -Path $DestPath -ItemType Directory -Force | Out-Null }

    if ($hexSignature -match "^4D535749") { 
        Write-Log -LogLevel INFO -Message "Firma detectada: WIM (MSWI). Extrayendo payload (Indice $WimIndex)..."
        Expand-WindowsImage -ImagePath $FilePath -Index $WimIndex -ApplyPath $DestPath -ErrorAction Stop | Out-Null
    }
    else {
        throw "Firma no reconocida ($hexSignature). No es WIM, válido."
    }
}

# --- MOTOR PRINCIPAL: Inyector de Addons ---
function Install-OfflineAddon {
    # AÑADIMOS EL PARÁMETRO $WimIndex
    param([string]$FilePath, [int]$WimIndex = 1)
    
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    
    if ($ext -eq '.reg') {
        Import-OfflineReg -FilePath $FilePath
        return "Registro inyectado exitosamente."
    }

    if ($ext -match '\.(wum|tpk|bpk)$') {
        $tempExtract = Join-Path $Script:Scratch_DIR "Addon_$baseName"
        
        try {
            # PASAMOS EL ÍNDICE AL EXTRACTOR
            Expand-AddonArchive -FilePath $FilePath -DestPath $tempExtract -WimIndex $WimIndex
            
            # --- FASE A: Inyección de Archivos (Mapeo de Estructura Blindado) ---
            $hasFiles = $false
            $rootFolders = Get-ChildItem -Path $tempExtract -Directory
            
            foreach ($folder in $rootFolders) {
                $targetDir = Join-Path $Script:MOUNT_DIR $folder.Name
                Write-Log -LogLevel ACTION -Message "Inyectando estructura: $($folder.Name) -> $targetDir"
                
                # Activamos privilegios de Dios (SeBackup / SeRestore)
                Enable-Privileges

                # Usamos Robocopy en Modo Backup (/B) para ignorar permisos de TrustedInstaller
                # /E = Recursivo | /B = Backup Mode | /IS = Sobrescribir iguales | /IT = Sobrescribir modificados
                # /R:0 /W:0 = Sin reintentos | /NJH /NJS /NDL /NC /NS /NP = Totalmente silencioso
                $roboArgs = "`"$($folder.FullName)`" `"$targetDir`" /E /B /IS /IT /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP"
                
                $proc = Start-Process robocopy.exe -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
                
                # Robocopy devuelve códigos < 8 si fue exitoso (1=Copiado, 2=Extras, 3=Ambos, etc)
                if ($proc.ExitCode -ge 8) {
                    Write-Log -LogLevel ERROR -Message "Robocopy fallo al inyectar $($folder.Name) (Codigo: $($proc.ExitCode))"
                    throw "Robocopy no pudo inyectar los archivos en $targetDir. (Codigo de salida: $($proc.ExitCode))"
                }
                
                $hasFiles = $true
            }

            $regFiles = Get-ChildItem -Path $tempExtract -Filter "*.reg" -Recurse
            foreach ($reg in $regFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando registro adjunto: $($reg.Name)"
                Import-OfflineReg -FilePath $reg.FullName
            }

            $msg = "Inyectado: "
            if ($hasFiles) { $msg += "[Archivos] " }
            if ($regFiles) { $msg += "[Registro] " }
            if ($cabFiles) { $msg += "[Paquete DISM] " }
            return $msg.Trim()

        } finally {
            if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    throw "Formato no soportado para inyeccion automática."
}

# --- INTERFAZ GRÁFICA DEL GESTOR DE ADDONS ---
function Show-Addons-GUI {
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    if (-not (Mount-Hives)) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Instalador de Addons y Paquetes Avanzados (.WIM .TPK, .BPK, .REG)"
    $form.Size = New-Object System.Drawing.Size(950, 640)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # --- TÍTULO Y BOTÓN DE CARGA ---
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Integracion de Paquetes de Terceros"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"; $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $btnAddFiles = New-Object System.Windows.Forms.Button
    $btnAddFiles.Text = "+ Agregar Addons (.wim, .tpk, .bpk, .reg)..."
    $btnAddFiles.Location = "670, 12"
    $btnAddFiles.Size = "240, 30"
    $btnAddFiles.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddFiles.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFiles)

    # --- DETECCIÓN INTELIGENTE DE ARQUITECTURA (INSTANTÁNEA) ---
    $defaultIdx = 1 # Asumimos x86 por defecto
    if (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) {
        $defaultIdx = 2 # Si existe SysWOW64, es un Windows x64 garantizado
    }

    # --- SELECTOR DE ARQUITECTURA (GRUPO) ---
    $grpArch = New-Object System.Windows.Forms.GroupBox
    $grpArch.Text = " Arquitectura del Addon (Solo aplica para desempaquetar .wim/.tpk/.bpk) "
    $grpArch.Location = "20, 50"
    $grpArch.Size = "890, 55"
    $grpArch.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpArch)

    $radX86 = New-Object System.Windows.Forms.RadioButton
    $radX86.Text = "x86 / 32-bits"
    $radX86.Location = "20, 22"
    $radX86.AutoSize = $true
    $radX86.ForeColor = [System.Drawing.Color]::White
    if ($defaultIdx -eq 1) { $radX86.Checked = $true }
    $grpArch.Controls.Add($radX86)

    $radX64 = New-Object System.Windows.Forms.RadioButton
    $radX64.Text = "x64 / 64-bits"
    $radX64.Location = "200, 22"
    $radX64.AutoSize = $true
    $radX64.ForeColor = [System.Drawing.Color]::White
    if ($defaultIdx -eq 2) { $radX64.Checked = $true }
    $grpArch.Controls.Add($radX64)

    # --- LISTVIEW (DESPLAZADO HACIA ABAJO) ---
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = "20, 120"
    $lv.Size = "890, 370"
    $lv.View = "Details"
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lv.ForeColor = [System.Drawing.Color]::White
    
    $lv.Columns.Add("Estado", 150) | Out-Null
    $lv.Columns.Add("Archivo", 250) | Out-Null
    $lv.Columns.Add("Tipo Detectado", 120) | Out-Null
    $lv.Columns.Add("Ruta Completa", 360) | Out-Null
    $form.Controls.Add($lv)

    # --- ESTADO Y BOTONES INFERIORES ---
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Agrega los archivos a la cola de inyeccion."
    $lblStatus.Location = "20, 500"
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    $btnRemoveItem = New-Object System.Windows.Forms.Button
    $btnRemoveItem.Text = "Quitar de la lista"
    $btnRemoveItem.Location = "20, 520"
    $btnRemoveItem.Size = "150, 30"
    $btnRemoveItem.BackColor = [System.Drawing.Color]::Crimson
    $btnRemoveItem.FlatStyle = "Flat"
    $form.Controls.Add($btnRemoveItem)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "INYECTAR TODOS LOS ADDONS"
    $btnInstall.Location = "640, 510"
    $btnInstall.Size = "270, 40"
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.FlatStyle = "Flat"
    $btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnInstall)

    # --- EVENTOS ---
    $btnAddFiles.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Addons Windows (*.tpk;*.bpk;*.wim;*.reg;*)|*.tpk;*.bpk;*.wim;*.reg|Todos los archivos (*.*)|*.*"
        $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $lv.BeginUpdate()
            foreach ($file in $ofd.FileNames) {
                $item = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                $item.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                $item.SubItems.Add([System.IO.Path]::GetExtension($file).ToUpper()) | Out-Null
                $item.SubItems.Add($file) | Out-Null
                $item.ForeColor = [System.Drawing.Color]::Yellow
                $item.Tag = $file
                $lv.Items.Add($item) | Out-Null
            }
            $lv.EndUpdate()
        }
    })

    $btnRemoveItem.Add_Click({
        foreach ($item in $lv.SelectedItems) { $lv.Items.Remove($item) }
    })

    $btnInstall.Add_Click({
        if ($lv.Items.Count -eq 0) { 
            Write-Log -LogLevel WARN -Message "AddonInjector: Intento de ejecucion sin addons en la lista."
            return 
        }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Iniciar la inyeccion en lote? Esto fusionara archivos y claves de registro en el orden correcto.", "Confirmar", 'YesNo', 'Warning')
        if ($confirm -ne 'Yes') { 
            Write-Log -LogLevel INFO -Message "AddonInjector: Operacion cancelada por el usuario en el cuadro de confirmacion."
            return 
        }

        Write-Log -LogLevel ACTION -Message "AddonInjector: Iniciando motor de inyeccion inteligente de Addons."

        $btnInstall.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $errors = 0; $success = 0; $skipped = 0

        # Capturamos la arquitectura de la UI
        $selectedIndex = if ($radX86.Checked) { 1 } else { 2 }
        $isX64 = $radX64.Checked
        Write-Log -LogLevel INFO -Message "AddonInjector: Destino arquitectonico -> $(if($isX64){'x64'}else{'x86'}) | Indice WIM local: $selectedIndex"

        # --- 1. EXTRAER ELEMENTOS PENDIENTES ---
        $pendingItems = @()
        foreach ($item in $lv.Items) {
            if ($item.Text -eq "EN ESPERA") {
                $pendingItems += $item
            }
        }

        # --- 2. ORDENAMIENTO INTELIGENTE (Prioridad + Alfabeto) ---
        $lblStatus.Text = "Calculando orden de inyeccion..."
        $form.Refresh()

        $sortedItems = $pendingItems | Sort-Object {
            $fileName = $_.SubItems[1].Text.ToLower()
            $priority = 5 # Prioridad por defecto (otros)
            
            # Asignacion de pesos (1 es lo primero que se instala)
            if ($fileName -match "_main\.(tpk|bpk|wim)$") { $priority = 1 } # Paquetes Principales
            elseif ($fileName -match "_main\.reg$")               { $priority = 2 } # Registro Principal
            elseif ($fileName -match "\.(tpk|bpk|wim)$")   { $priority = 3 } # Paquetes de Idioma / Extras
            elseif ($fileName -match "\.reg$")                     { $priority = 4 } # Registros de Idioma / Extras

            # Al retornar "Prioridad-Nombre", PowerShell agrupa primero por fase y luego alfabeticamente
            # Ej: "1-firefox_main.tpk" se procesara antes que "2-firefox_x64_main.reg"
            "$priority-$fileName"
        }
        Write-Log -LogLevel INFO -Message "AddonInjector: Fase 2 - $($sortedItems.Count) elementos ordenados por algoritmo de prioridad."

        # --- 3. PROCESAMIENTO E INYECCION ---
        foreach ($item in $sortedItems) {
            $fileName = $item.SubItems[1].Text.ToLower()

            # --- CONDICION 1: FILTRO DE ARQUITECTURA ---
            # Busca variaciones como _x64, -x64, 64bit, 64-bit, amd64
            $is64BitFile = $fileName -match "(\b|_|\.|-)(x64|64-?bit|amd64)(\b|_|\.|-)"
            $is32BitFile = $fileName -match "(\b|_|\.|-)(x86|32-?bit)(\b|_|\.|-)"

            if ($isX64 -and $is32BitFile) {
                $item.Text = "OMITIDO (Arch)"
                $item.SubItems[2].Text = "Ignorado (Solo x86)"
                $item.ForeColor = [System.Drawing.Color]::DarkGray
                $skipped++
                Write-Log -LogLevel INFO -Message "AddonInjector: Omitiendo [$fileName] (Paquete de 32-bits en imagen destino x64)."
                continue
            }
            if (-not $isX64 -and $is64BitFile) {
                $item.Text = "OMITIDO (Arch)"
                $item.SubItems[2].Text = "Ignorado (Solo x64)"
                $item.ForeColor = [System.Drawing.Color]::DarkGray
                $skipped++
                Write-Log -LogLevel INFO -Message "AddonInjector: Omitiendo [$fileName] (Paquete de 64-bits en imagen destino x86)."
                continue
            }

            # --- CONDICION 2: INYECCION EN ORDEN ---
            $lblStatus.Text = "Inyectando: $($item.SubItems[1].Text)..."
            $item.Text = "PROCESANDO..."
            
            # Hacemos auto-scroll en la UI para ver por donde va
            $item.EnsureVisible()
            $form.Refresh()

            Write-Log -LogLevel INFO -Message "AddonInjector: Instalando -> [$fileName]"

            try {
                # Llamamos al motor pasandole la ruta y el indice WIM a usar
                $resultado = Install-OfflineAddon -FilePath $item.Tag -WimIndex $selectedIndex
                
                $item.Text = "COMPLETADO"
                $item.SubItems[2].Text = $resultado
                $item.ForeColor = [System.Drawing.Color]::LightGreen
                $success++
                Write-Log -LogLevel INFO -Message "AddonInjector: Completado. Motor devolvio: $resultado"
            } catch {
                $item.Text = "ERROR"
                $item.SubItems[2].Text = $_.Exception.Message
                $item.ForeColor = [System.Drawing.Color]::Salmon
                $errors++
                Write-Log -LogLevel ERROR -Message "AddonInjector: Fallo critico instalando addon [$fileName] - $($_.Exception.Message)"
            }
        }

        Write-Log -LogLevel ACTION -Message "AddonInjector: Ciclo de inyeccion finalizado. Exitos: $success | Errores: $errors | Omitidos (Arch): $skipped"

        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnInstall.Enabled = $true
        $lblStatus.Text = "Proceso terminado."
        [System.Windows.Forms.MessageBox]::Show("Inyeccion de Addons finalizada.`n`nExitos: $success`nErrores: $errors`nOmitidos (Arch): $skipped", "Reporte de Operacion", 'OK', 'Information')
    })

    # Cierre seguro (Desmontar Hives de registro)
    $form.Add_FormClosing({ Unmount-Hives })
    
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
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
                    Save-Config # Guardar inmediatamente
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
                    Save-Config # Guardar inmediatamente
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
        Write-Host "       (Descarga la imagen. ¡Cambios no guardados se pierden!)" -ForegroundColor Gray
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
        Write-Host "   [5] Convertir Imagen a WIM" -ForegroundColor White
        Write-Host "       (Importa imagen desde ESD o VHD)" -ForegroundColor Gray
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
            "5" { 
                Write-Log -LogLevel INFO -Message "MenuImageMgmt: Accediendo a 'Convert-Image-Menu' (Conversion WIM/ESD/SWM)."
                Convert-Image-Menu 
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
    if ($Script:IMAGE_MOUNTED -eq 0)
	{
		Write-Warning "Necesita montar imagen primero."
		Pause
		return
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
        elseif ($buildNum -eq 9600) { $WIN_VERSION_FRIENDLY = "Windows 8.1" } # Build correcto para 8.1 es 9600
        elseif ($buildNum -in (7601, 7600)) { $WIN_VERSION_FRIENDLY = "Windows 7" }
    }
    if ($WIN_VERSION_FRIENDLY -eq "Desconocida" -and $WIN_PRODUCT_NAME) {
        if ($WIN_PRODUCT_NAME -match "Windows 11") { $WIN_VERSION_FRIENDLY = "Windows 11" }
        elseif ($WIN_PRODUCT_NAME -match "Windows 10") { $WIN_VERSION_FRIENDLY = "Windows 10" }
        elseif ($WIN_PRODUCT_NAME -match "Windows 8\.1|Server 2012 R2") { $WIN_VERSION_FRIENDLY = "Windows 8.1" } # Punto escapado
        elseif ($WIN_PRODUCT_NAME -match "Windows 7|Server 2008 R2") { $WIN_VERSION_FRIENDLY = "Windows 7" }
    }

    # Obtener edicion actual con DISM
    try {
        $dismEdition = dism /Image:$Script:MOUNT_DIR /Get-CurrentEdition 2>$null
        $currentEditionLine = $dismEdition | Select-String -Pattern "(Current Edition|Edici.n actual)\s*:"
        if ($currentEditionLine) { $CURRENT_EDITION_DETECTED = ($currentEditionLine.Line -split ':', 2)[1].Trim() }
    } catch { Write-Warning "No se pudo obtener la edicion actual via DISM." }

    # Traducir nombre de edicion
    $DISPLAY_EDITION = switch -Wildcard ($CURRENT_EDITION_DETECTED) {
        "Core" { "Home" } "CoreSingleLanguage" { "Home SL" } "ProfessionalCountrySpecific" { "Pro CS" }
        "ProfessionalEducation" { "Pro Edu" } "ProfessionalSingleLanguage" { "Pro SL" } "ProfessionalWorkstation" { "Pro WS" }
        "IoTEnterprise" { "IoT Ent" } "IoTEnterpriseK" { "IoT Ent K" } "IoTEnterpriseS" { "IoT Ent LTSC" }
        "EnterpriseS" { "Ent LTSC" } "ServerRdsh" { "Server Rdsh" } Default { $CURRENT_EDITION_DETECTED }
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
    # (Total dividido entre 2, redondeado hacia arriba)
    $totalItems = $targetEditions.Count
    $rowCount = [math]::Ceiling($totalItems / 2)

    # Iteramos por FILAS, no por items linealmente
    for ($row = 0; $row -lt $rowCount; $row++) {
        
        # --- COLUMNA IZQUIERDA ---
        $indexLeft = $row
        if ($indexLeft -lt $totalItems) {
            $editionRaw = $targetEditions[$indexLeft]
            $displayNum = $indexLeft + 1 # Mostramos base 1
            
            # Mapeo de Nombres
            $editionName = switch -Wildcard ($editionRaw) {
                 "Core" { "Home" }
                 "CoreSingleLanguage" { "Home Single Language" }
                 "Professional" { "Professional" }
                 "ProfessionalCountrySpecific" { "Professional Country Specific" }
                 "ProfessionalEducation" { "Professional Education" }
                 "ProfessionalSingleLanguage" { "Professional Single Language" }
                 "ProfessionalWorkstation" { "Professional Workstation" }
                 "IoTEnterprise" { "IoT Enterprise" }
                 "IoTEnterpriseK" { "IoT Enterprise K" }
                 "IoTEnterpriseS" { "IoT Enterprise LTSC" }
                 "EnterpriseS" { "Enterprise LTSC" }
                 "ServerRdsh" { "Enterprise Multi-Session" }
                 "CloudEdition" { "Cloud" }
                 Default { $editionRaw }
            }

            # Formato: [1 ] Nombre... (Relleno a 60 caracteres para dar espacio a nombres largos)
            $leftText = "   [{0,-2}] {1}" -f $displayNum, $editionName
            Write-Host $leftText.PadRight(60) -NoNewline -ForegroundColor White
        }

        # --- COLUMNA DERECHA ---
        # El indice derecho es: Fila actual + Cantidad de Filas
        $indexRight = $row + $rowCount
        
        if ($indexRight -lt $totalItems) {
            $editionRaw = $targetEditions[$indexRight]
            $displayNum = $indexRight + 1
            
            $editionName = switch -Wildcard ($editionRaw) {
                 "Core" { "Home" }
                 "CoreSingleLanguage" { "Home Single Language" }
                 "Professional" { "Professional" }
                 "ProfessionalCountrySpecific" { "Professional Country Specific" }
                 "ProfessionalEducation" { "Professional Education" }
                 "ProfessionalSingleLanguage" { "Professional Single Language" }
                 "ProfessionalWorkstation" { "Professional Workstation" }
                 "IoTEnterprise" { "IoT IoTEnterprise" }
                 "IoTEnterpriseK" { "IoT IoTEnterprise K" }
                 "IoTEnterpriseS" { "IoT IoTEnterprise LTSC" }
                 "EnterpriseS" { "IoTEnterprise LTSC" }
                 "ServerRdsh" { "Server Rdsh" }
                 "CloudEdition" { "Cloud" }
                 Default { $editionRaw }
            }

            $rightText = "   [{0,-2}] {1}" -f $displayNum, $editionName
            Write-Host $rightText -ForegroundColor White
        } else {
            # Si no hay elemento a la derecha, solo saltamos de linea
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
        Cambio-Edicion-Menu; return # Llama recursivamente para reintentar
    }

    $selectedEdition = $targetEditions[$opcionIndex - 1] # Los arrays en PS son base 0

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
        Write-Host "       (Optimizar el arranque deshabilitando servicios)" -ForegroundColor Gray
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
        Write-Host "       (Aplica wallpaper/lockscreen e inyecta logo e informacion del fabricante)" -ForegroundColor Gray
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

# :limpieza_menu
function Limpieza-Menu {
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
        Write-Host "   [6] Limpiar Componentes" -NoNewline; Write-Host "    (DISM /StartComponentCleanup /ResetBase)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [7] Ejecutar TODO (1-6)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host "   [V] Volver" -ForegroundColor Red
        $opcionL = Read-Host "`nSelecciona una opcion"
        Write-Log -LogLevel INFO -Message "MENU_LIMPIEZA: Usuario selecciono '$opcionL'."

        # --- Funcion auxiliar interna para el fallback de RestoreHealth ---
        function Invoke-RestoreHealthWithFallback {
            param(
                [string]$MountDir,
                [switch]$IsSequence # Para saber si estamos en la opcion '7'
            )

            Write-Host "`n[+] Ejecutando DISM /RestoreHealth..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "LIMPIEZA: Ejecutando DISM /RestoreHealth..."
            DISM /Image:$MountDir /Cleanup-Image /RestoreHealth
            $exitCode = $LASTEXITCODE

            if ($exitCode -ne 0) {
                Write-Host "[ERROR] DISM /RestoreHealth fallo (Codigo: $exitCode). Puede que no encuentre los archivos necesarios." -ForegroundColor Red
                Write-Log -LogLevel ERROR -Message "LIMPIEZA: DISM /RestoreHealth fallo inicialmente (Codigo: $exitCode)."

                $useSourceChoice = Read-Host "Deseas intentar la reparacion usando un archivo WIM como fuente? (S/N)"
                if ($useSourceChoice.ToUpper() -eq 'S') {
                    Write-Log -LogLevel INFO -Message "LIMPIEZA: Usuario eligio usar fuente WIM para RestoreHealth."
                    $sourceWimPath = Select-PathDialog -DialogType File -Title "Selecciona el archivo WIM de origen (ej. install.wim)" -Filter "Archivos WIM (*.wim)|*.wim"
                    if (-not [string]::IsNullOrWhiteSpace($sourceWimPath)) {
                        Write-Host "[+] Obteniendo indices del WIM seleccionado..." -ForegroundColor Yellow
                        dism /get-wiminfo /wimfile:"$sourceWimPath"
                        $sourceIndex = Read-Host "`nIntroduce el numero de INDICE del WIM que contiene la version correcta de Windows"
                        # Validar que sourceIndex sea un numero

                        # correcto
                        if (-not [string]::IsNullOrWhiteSpace($sourceIndex)) 
						{
                             Write-Host "[+] Reintentando DISM /RestoreHealth con fuente WIM..." -ForegroundColor Yellow
                             $sourceArgument = "/Source:WIM:$($sourceWimPath):$($sourceIndex)"
                             Write-Log -LogLevel ACTION -Message "LIMPIEZA: Reintentando RestoreHealth con $sourceArgument"
                             DISM /Image:$MountDir /Cleanup-Image /RestoreHealth $sourceArgument
                             $exitCode = $LASTEXITCODE # Actualizar el codigo de salida

                             if ($exitCode -eq 0) {
                                 Write-Host "[OK] DISM /RestoreHealth completado exitosamente usando la fuente WIM." -ForegroundColor Green
                                 Write-Log -LogLevel INFO -Message "LIMPIEZA: RestoreHealth exitoso con fuente WIM."
                             } else {
                                 Write-Host "[ERROR] DISM /RestoreHealth volvio a fallar incluso con la fuente WIM (Codigo: $exitCode)." -ForegroundColor Red
                                 Write-Log -LogLevel ERROR -Message "LIMPIEZA: RestoreHealth fallo de nuevo con fuente WIM (Codigo: $exitCode)."
                             }
                        } else {
                             Write-Warning "No se ingreso un indice. Omitiendo reintento con fuente."
                             Write-Log -LogLevel WARN -Message "LIMPIEZA: No se ingreso indice para fuente WIM."
                        }
                    } else {
                        Write-Warning "No se selecciono un archivo WIM. Omitiendo reintento con fuente."
                        Write-Log -LogLevel WARN -Message "LIMPIEZA: Usuario cancelo seleccion de fuente WIM."
                    }
                } else {
                    Write-Warning "Operacion de reparacion con fuente WIM omitida por el usuario."
                    Write-Log -LogLevel WARN -Message "LIMPIEZA: Usuario omitio reintento con fuente WIM."
                }
            } else {
                 Write-Host "[OK] DISM /RestoreHealth completado exitosamente." -ForegroundColor Green
                 Write-Log -LogLevel INFO -Message "LIMPIEZA: DISM /RestoreHealth exitoso (primer intento)."
            }
            # Solo pausar si NO estamos en la secuencia completa
            if (-not $IsSequence) { Pause }
        }

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
                # Definir rutas dinamicas basadas en el directorio de montaje actual
                $sfcBoot = $Script:MOUNT_DIR
                # SFC es estricto: offbootdir debe terminar en backslash (\)
                if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
                $sfcWin = Join-Path -Path $Script:MOUNT_DIR -ChildPath "Windows"

                Write-Host "`n[+] Verificando archivos (SFC)..." -ForegroundColor Yellow
                Write-Host "    BootDir: $sfcBoot" -ForegroundColor Gray
                Write-Host "    WinDir : $sfcWin" -ForegroundColor Gray

                Write-Log -LogLevel ACTION -Message "LIMPIEZA: SFC /Scannow Offline en '$sfcBoot' / '$sfcWin'..."
				
				if (-not (Test-Path $sfcWin)) {
                     Write-Host "No se encuentra la carpeta Windows en $sfcWin. Esta montada correctamente?"
                     Pause; break
                }

                # Ejecucion corregida
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
                Write-Host "`n[+] Limpiando componentes..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /StartComponentCleanup /ResetBase..."
                DISM /Cleanup-Image /Image:$Script:MOUNT_DIR /StartComponentCleanup /ResetBase /ScratchDir:$Script:Scratch_DIR
                Pause
            }
            "7" {
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: Iniciando secuencia COMPLETA..."
                
                # --- PASO 1: CheckHealth ---
                Write-Host "`n[1/5] Verificando salud rapida (CheckHealth)..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: (1/5) CheckHealth..."
                DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /CheckHealth

                # --- PASO 2: ScanHealth (Diagnostico Inteligente) ---
                Write-Host "`n[2/5] Escaneando a fondo (ScanHealth)..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: (2/5) ScanHealth..."
                
                $imageState = "Unknown" # Estado por defecto por si falla el Cmdlet
                
                try {
                    # Usamos el Cmdlet nativo para obtener el objeto de estado
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
                    Write-Warning "Cmdlet nativo no disponible. Usando DISM clasico (Diagnostico ciego)..."
                    DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /ScanHealth
                    # Si cae aqui, $imageState sigue siendo "Unknown", asi que intentaremos reparar por si acaso.
                }

                # --- LOGICA DE DECISION ---
                if ($imageState -eq "NonRepairable") {
                    # CASO CRiTICO: ABORTAR
                    Write-Host "`n[!] ALERTA DE SEGURIDAD" -ForegroundColor Red
                    Write-Warning "La imagen es IRREPARABLE. Deteniendo secuencia para evitar daños mayores."
                    Write-Log -LogLevel ERROR -Message "LIMPIEZA: Abortado. Estado NonRepairable."
                    [System.Windows.Forms.MessageBox]::Show("La imagen esta en estado 'NonRepairable'.`nLa secuencia se detendra.", "Error Fatal", 'OK', 'Error')
                    Pause; return
                }
                elseif ($imageState -eq "Healthy") {
                    # CASO OPTIMO: SALTAR REPARACIoN
                    Write-Host "`n[3/5] Reparando imagen..." -ForegroundColor DarkGray
                    Write-Host "   >>> OMITIDO: La imagen ya esta saludable." -ForegroundColor Green
                    Write-Log -LogLevel INFO -Message "LIMPIEZA: (3/5) RestoreHealth omitido (Imagen Saludable)."
                }
                else {
                    # CASO REPARABLE O DESCONOCIDO: EJECUTAR
                    Write-Host "`n[3/5] Reparando imagen..." -ForegroundColor Yellow
                    Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR -IsSequence
                }

                # --- PASO 4 ---
                Write-Host "`n[4/5] Verificando archivos (SFC)..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: (4/5) SFC Offline..."

                $sfcBoot = $Script:MOUNT_DIR
                if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
                $sfcWin = Join-Path -Path $Script:MOUNT_DIR -ChildPath "Windows"

                SFC /scannow /offbootdir="$sfcBoot" /offwindir="$sfcWin"
                if ($LASTEXITCODE -ne 0) { Write-Warning "SFC encontro errores o no pudo completar."}

                # --- PASO 5 ---
                Write-Host "`n[5/5] Analizando/Limpiando componentes..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Analyze/Cleanup..."
                
                $cleanupRecommended = "No"
                try {
                    $analysis = DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /AnalyzeComponentStore
                    $recommendLine = $analysis | Select-String "Component Store Cleanup Recommended"
                    if ($recommendLine -and ($recommendLine.Line -split ':', 2)[1].Trim() -eq "Yes") { $cleanupRecommended = "Yes" }
                } catch { Write-Warning "No se pudo analizar el almacen de componentes." }

                if ($cleanupRecommended -eq "Yes") {
                    Write-Host "Limpieza recomendada. Procediendo..." -ForegroundColor Cyan;
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Limpieza recomendada. Ejecutando..."
                    DISM /Cleanup-Image /Image:$Script:MOUNT_DIR /StartComponentCleanup /ResetBase /ScratchDir:$Script:Scratch_DIR
                } else {
                    Write-Host "La limpieza del almacen de componentes no es necesaria." -ForegroundColor Green;
                }
                
                Write-Host "[OK] Secuencia completada." -ForegroundColor Green
                Pause
            }
            "V" { return }
            default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

# =================================================================
#  Modulo GUI de Metadatos
# =================================================================
function Show-WimMetadata-GUI {
    
    # 1. Cargar dependencias
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Xml
    Add-Type -AssemblyName System.Xml.Linq

    # 2. Motor C#
    $wimEngineSource = @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Xml.Linq; 
using System.Linq;
using System.IO;

public class WimMasterEngine
{
    private const uint WIM_GENERIC_READ  = 0x80000000;
    private const uint WIM_GENERIC_WRITE = 0x40000000;
    private const uint WIM_OPEN_EXISTING = 3;
    
    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr WIMCreateFile(string pszWimPath, uint dwDesiredAccess, uint dwCreationDisposition, uint dwFlagsAndAttributes, uint dwCompressionType, out uint pdwCreationResult);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMSetTemporaryPath(IntPtr hWim, string pszPath);

    [DllImport("wimgapi.dll", SetLastError = true)]
    private static extern IntPtr WIMLoadImage(IntPtr hWim, uint dwImageIndex);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMGetImageInformation(IntPtr hImage, out IntPtr pInfoHdr, out uint dwcbInfoHdr);

    [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WIMSetImageInformation(IntPtr hImage, IntPtr pInfoHdr, uint cbInfoHdr);

    [DllImport("wimgapi.dll", SetLastError = true)]
    private static extern bool WIMCloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr hMem);

    private static void SetElementValue(XElement parent, string elementName, string value)
    {
        XElement el = parent.Element(elementName);
        if (el == null) {
            if (!string.IsNullOrEmpty(value)) parent.Add(new XElement(elementName, value));
        } else {
            el.Value = value ?? "";
        }
    }

    // Usar ruta temporal del sistema
    private static void ForceSafeTempPath(IntPtr hWim)
    {
        try {
            string sysTemp = Path.GetTempPath(); 
            WIMSetTemporaryPath(hWim, sysTemp);
        } catch { }
    }

    public static string GetImageXml(string wimPath, int index)
    {
        GC.Collect(); GC.WaitForPendingFinalizers();
        IntPtr hWim = IntPtr.Zero; IntPtr hImg = IntPtr.Zero; IntPtr pInfo = IntPtr.Zero;

        try {
            uint res;
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ForceSafeTempPath(hWim);

            hImg = WIMLoadImage(hWim, (uint)index);
            if (hImg == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            uint size;
            if (!WIMGetImageInformation(hImg, out pInfo, out size))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            string xmlRaw = Marshal.PtrToStringUni(pInfo);
            if (xmlRaw.StartsWith("\uFEFF")) xmlRaw = xmlRaw.Substring(1);
            return xmlRaw;
        }
        finally {
            if (pInfo != IntPtr.Zero) LocalFree(pInfo);
            if (hImg != IntPtr.Zero) WIMCloseHandle(hImg);
            if (hWim != IntPtr.Zero) WIMCloseHandle(hWim);
        }
    }

    public static void WriteImageMetadata(string wimPath, int index, string name, string desc, string dispName, string dispDesc, string editionId)
    {
        GC.Collect(); GC.WaitForPendingFinalizers();
        IntPtr hWim = IntPtr.Zero; IntPtr hImg = IntPtr.Zero; IntPtr pXmlBuffer = IntPtr.Zero;

        try {
            uint res;
            // Abrimos con permisos de Escritura
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_WRITE | WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            ForceSafeTempPath(hWim);

            hImg = WIMLoadImage(hWim, (uint)index);
            if (hImg == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            // 1. Leer XML Actual
            IntPtr pInfo; uint size;
            if (!WIMGetImageInformation(hImg, out pInfo, out size)) throw new Win32Exception(Marshal.GetLastWin32Error());
            string currentXml = Marshal.PtrToStringUni(pInfo);
            LocalFree(pInfo);
            if (currentXml.StartsWith("\uFEFF")) currentXml = currentXml.Substring(1);

            // 2. Modificar XML en memoria
            XDocument doc = XDocument.Parse(currentXml);
            XElement root = doc.Root; 
            SetElementValue(root, "NAME", name);
            SetElementValue(root, "DESCRIPTION", desc);
            SetElementValue(root, "DISPLAYNAME", dispName);
            SetElementValue(root, "DISPLAYDESCRIPTION", dispDesc);

            XElement windowsNode = root.Element("WINDOWS");
            if (windowsNode == null) { windowsNode = new XElement("WINDOWS"); root.Add(windowsNode); }
            SetElementValue(windowsNode, "EDITIONID", editionId);

            StringBuilder sb = new StringBuilder();
            using (StringWriter writer = new StringWriter(sb)) { doc.Save(writer, SaveOptions.None); }
            string newXmlString = sb.ToString();

            // 3. Escribir XML nuevo (Esto guarda los cambios en el Header inmediatamente)
            pXmlBuffer = Marshal.StringToHGlobalUni(newXmlString);
            if (!WIMSetImageInformation(hImg, pXmlBuffer, (uint)(newXmlString.Length * 2)))
                throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        finally {
            if (pXmlBuffer != IntPtr.Zero) Marshal.FreeHGlobal(pXmlBuffer);
            if (hImg != IntPtr.Zero) WIMCloseHandle(hImg);
            if (hWim != IntPtr.Zero) WIMCloseHandle(hWim);
            GC.Collect();
        }
    }
    
    public static int GetImageCount(string wimPath)
    {
         GC.Collect(); IntPtr hWim = IntPtr.Zero;
         try {
            uint res;
            hWim = WIMCreateFile(wimPath, WIM_GENERIC_READ, WIM_OPEN_EXISTING, 0, 0, out res);
            if (hWim == IntPtr.Zero) return 0;
            ForceSafeTempPath(hWim); 
            return GetImageCountNative(hWim);
         }
         catch { return 0; }
         finally { if(hWim != IntPtr.Zero) WIMCloseHandle(hWim); }
    }

    [DllImport("wimgapi.dll", EntryPoint="WIMGetImageCount")]
    private static extern int GetImageCountNative(IntPtr hWim);
}
"@

    # 3. Compilacion
    try {
        if (-not ([System.Management.Automation.PSTypeName]'WimMasterEngine').Type) {
            $refs = @("System.Xml", "System.Xml.Linq", "System.Core")
            Add-Type -TypeDefinition $wimEngineSource -Language CSharp -ReferencedAssemblies $refs
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Error compilacion C#:`n$($_.Exception.Message)", "Error Critico", 'OK', 'Error'); return
    }

    # 4. GUI
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Editor Metadatos WIM"
    $form.Size = New-Object System.Drawing.Size(850, 600)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lblFile = New-Object System.Windows.Forms.Label
	$lblFile.Text = "WIM:"
	$lblFile.Location = "20, 20"
	$lblFile.AutoSize = $true; $form.Controls.Add($lblFile)
    $txtPath = New-Object System.Windows.Forms.TextBox
	$txtPath.Location = "80, 18"
	$txtPath.Size = "600, 23"; $txtPath.ReadOnly=$true
	$txtPath.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$txtPath.ForeColor=[System.Drawing.Color]::White
	$form.Controls.Add($txtPath)
    $btnBrowse = New-Object System.Windows.Forms.Button
	$btnBrowse.Text="..."
	$btnBrowse.Location="690, 17"
	$btnBrowse.Size="40, 25"
	$btnBrowse.BackColor=[System.Drawing.Color]::Gray
	$btnBrowse.FlatStyle="Flat"
	$form.Controls.Add($btnBrowse)

    $lblIdx = New-Object System.Windows.Forms.Label
	$lblIdx.Text = "Index:"
	$lblIdx.Location = "20, 60"
	$lblIdx.AutoSize = $true; $form.Controls.Add($lblIdx)
    $cmbIndex = New-Object System.Windows.Forms.ComboBox
	$cmbIndex.Location = "80, 58"
	$cmbIndex.Size = "600, 25"
	$cmbIndex.DropDownStyle="DropDownList"
	$cmbIndex.BackColor=[System.Drawing.Color]::FromArgb(50,50,50)
	$cmbIndex.ForeColor=[System.Drawing.Color]::White
	$form.Controls.Add($cmbIndex)

    # Aumentamos Size del Grid
    $dgv = New-Object System.Windows.Forms.DataGridView
	$dgv.Location = "20, 100"
	$dgv.Size = "790, 380"
	$dgv.AllowUserToAddRows=$false
	$dgv.AllowUserToDeleteRows=$false
	$dgv.RowHeadersVisible=$false
	$dgv.AutoSizeColumnsMode="Fill"
	$dgv.BackgroundColor=[System.Drawing.Color]::FromArgb(40,40,40)
	$dgv.GridColor=[System.Drawing.Color]::Gray
    $dgv.DefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(40,40,40)
	$dgv.DefaultCellStyle.ForeColor=[System.Drawing.Color]::White
	$dgv.DefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::SteelBlue
    $dgv.Columns.Add("Prop","Propiedad")|Out-Null
	$dgv.Columns.Add("Val","Valor")|Out-Null
	$dgv.Columns[0].ReadOnly=$true
	$dgv.Columns[0].FillWeight=30
	$form.Controls.Add($dgv)

    $btnSave = New-Object System.Windows.Forms.Button
	$btnSave.Text="GUARDAR (Commit)"
	$btnSave.Location="550, 500"
	$btnSave.Size="260, 40"
	$btnSave.BackColor=[System.Drawing.Color]::SeaGreen
	$btnSave.ForeColor=[System.Drawing.Color]::White
	$btnSave.FlatStyle="Flat"
	$btnSave.Enabled=$false
	$form.Controls.Add($btnSave)
    $lblStatus = New-Object System.Windows.Forms.Label
	$lblStatus.Location="20, 510"
	$lblStatus.Size="500, 25"
	$lblStatus.ForeColor=[System.Drawing.Color]::Yellow
	$lblStatus.Text="Listo."
	$form.Controls.Add($lblStatus)

    # --- EVENTO CARGAR ---
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "WIM|*.wim"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtPath.Text = $ofd.FileName
			$cmbIndex.Items.Clear()
			$dgv.Rows.Clear()
			$btnSave.Enabled=$false
            $lblStatus.Text = "Escaneando nombres..."
            $form.Refresh()

            try {
                $count = [WimMasterEngine]::GetImageCount($ofd.FileName)
                if ($count -gt 0) { 
                    for ($i=1; $i -le $count; $i++) {
                        $name = "Desconocido"
                        try {
                            $xmlRaw = [WimMasterEngine]::GetImageXml($ofd.FileName, $i)
                            $xml = [System.Xml.Linq.XDocument]::Parse($xmlRaw)
                            $nameEl = $xml.Root.Element("NAME")
                            if ($null -ne $nameEl) { $name = $nameEl.Value }
                        } catch {}
                        $cmbIndex.Items.Add("[$i] $name") 
                    }
                    $cmbIndex.SelectedIndex=0; $lblStatus.Text="WIM Cargado." 
                }
            } catch { [System.Windows.Forms.MessageBox]::Show("Error: $_") }
        }
    })

    # --- EVENTO SELECCION (Muestra Metadatos Extendidos) ---
    $cmbIndex.Add_SelectedIndexChanged({
        if ($txtPath.Text) {
            $idx = $cmbIndex.SelectedIndex + 1; $dgv.Rows.Clear()
            try {
                $xml = [System.Xml.Linq.XDocument]::Parse([WimMasterEngine]::GetImageXml($txtPath.Text, $idx))
                $img = $xml.Root
                
                # --- Funcion Helper Interna ---
                function Get-NodeVal($el, $name) { 
                    $x = $el.Element($name)
                    if ($null -ne $x) { return $x.Value } else { return "" }
                }
                
                # --- 1. Datos Editables ---
                $dgv.Rows.Add("Nombre", (Get-NodeVal $img "NAME")) | Out-Null
                $dgv.Rows.Add("Descripcion", (Get-NodeVal $img "DESCRIPTION")) | Out-Null
                $dgv.Rows.Add("Nombre Mostrado", (Get-NodeVal $img "DISPLAYNAME")) | Out-Null
                $dgv.Rows.Add("Descripcion Mostrada", (Get-NodeVal $img "DISPLAYDESCRIPTION")) | Out-Null
                
                $winNode = $img.Element("WINDOWS")
                $editionId = ""
                if ($null -ne $winNode) { $editionId = Get-NodeVal $winNode "EDITIONID" }
                $dgv.Rows.Add("ID de Edicion", $editionId) | Out-Null

                # --- 2. Datos Solo Lectura (Calculados) ---
                
                # A) Arquitectura
                $archVal = ""
                if ($null -ne $winNode) { $archVal = Get-NodeVal $winNode "ARCH" }
                $archStr = switch ($archVal) { "0" {"x86"} "9" {"x64"} "12" {"ARM64"} default {$archVal} }
                $rowArch = $dgv.Rows.Add("Arquitectura", $archStr)

                # B) Version
                $verStr = ""
                if ($null -ne $winNode) {
                    $vNode = $winNode.Element("VERSION")
                    if ($null -ne $vNode) {
                        $maj = Get-NodeVal $vNode "MAJOR"
                        $min = Get-NodeVal $vNode "MINOR"
                        $bld = Get-NodeVal $vNode "BUILD"
                        $spb = Get-NodeVal $vNode "SPBUILD"
                        $verStr = "$maj.$min.$bld.$spb"
                    }
                }
                $rowVer = $dgv.Rows.Add("Version", $verStr)

                # C) Size (Bytes -> GB)
                $bytesStr = Get-NodeVal $img "TOTALBYTES"
                $sizeDisplay = ""
                if ($bytesStr -match "^\d+$") {
                    $gb = [math]::Round([long]$bytesStr / 1GB, 2)
                    $sizeDisplay = "$gb GB"
                }
                $rowSize = $dgv.Rows.Add("Size", $sizeDisplay)

                # D) Fecha Creacion
                $dateStr = ""
                $cTime = $img.Element("CREATIONTIME")
                if ($null -ne $cTime) {
                    try {
                        # Convertir estructura High/Low a DateTime
                        $high = [long](Get-NodeVal $cTime "HIGHPART")
                        $low = [long](Get-NodeVal $cTime "LOWPART")
                        # Combinar bits
                        $combined = ($high -shl 32) -bor ($low -band 0xFFFFFFFFL)
                        $dateObj = [DateTime]::FromFileTime($combined)
                        $dateStr = $dateObj.ToString("yyyy-MM-dd HH:mm")
                    } catch { $dateStr = "Desconocida" }
                }
                $rowDate = $dgv.Rows.Add("Fecha de Creacion", $dateStr)

                # E) Idioma(s) Instalado(s)
                $langStr = "Desconocido"
                if ($null -ne $winNode) {
                    $langsNode = $winNode.Element("LANGUAGES")
                    if ($null -ne $langsNode) {
                        $langList = @()
                        # Extraer todos los lenguajes instalados
                        foreach ($lNode in $langsNode.Elements("LANGUAGE")) {
                            $langList += $lNode.Value
                        }
                        
                        $defaultLang = Get-NodeVal $langsNode "DEFAULT"
                        
                        if ($langList.Count -gt 0) {
                            $langStr = $langList -join ", "
                            # Indicar cual es el predeterminado si hay varios
                            if (-not [string]::IsNullOrWhiteSpace($defaultLang)) {
                                $langStr += " (Predeterminado: $defaultLang)"
                            }
                        }
                    }
                }
                $rowLang = $dgv.Rows.Add("Idioma(s)", $langStr)

                # --- 3. Aplicar Estilo Solo Lectura ---
                # Agregamos la variable $rowLang al array de celdas bloqueadas
                foreach ($rIndex in @($rowArch, $rowVer, $rowSize, $rowDate, $rowLang)) {
                    $dgv.Rows[$rIndex].ReadOnly = $true
                    $dgv.Rows[$rIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60) # Gris oscuro
                    $dgv.Rows[$rIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Silver
                }

                $btnSave.Enabled = $true
            } catch { 
                $lblStatus.Text="Error Lectura."
                [System.Windows.Forms.MessageBox]::Show("Error: $_")
            }
        }
    })

    # --- EVENTO GUARDAR ---
    $btnSave.Add_Click({
        $path=$txtPath.Text; $idx=$cmbIndex.SelectedIndex+1
        
        # Diccionario simple para mapear nombre de fila -> valor
        $d=@{}
        foreach($r in $dgv.Rows){ $d[$r.Cells[0].Value]=$r.Cells[1].Value }
        
        Write-Log -LogLevel ACTION -Message "WimMetadataManager: Iniciando reescritura de metadatos XML para el WIM [$path] (Indice: $idx)."
        Write-Log -LogLevel INFO -Message "WimMetadataManager: Valores a inyectar -> Nombre: [$($d['Nombre'])] | Edicion: [$($d['ID de Edicion'])]"

        $form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text="Guardando..."
        $form.Refresh()
        $btnSave.Enabled=$false
        $success = $false

        try {
            # Llamada al motor nativo C#
            [WimMasterEngine]::WriteImageMetadata(
                $path, 
                $idx, 
                $d["Nombre"], 
                $d["Descripcion"], 
                $d["Nombre Mostrado"], 
                $d["Descripcion Mostrada"], 
                $d["ID de Edicion"]
            )
            
            $success = $true
            $lblStatus.Text="OK"
            Write-Log -LogLevel INFO -Message "WimMetadataManager: Metadatos guardados exitosamente. El archivo WIM ha sido actualizado."
            [System.Windows.Forms.MessageBox]::Show("Guardado Exitoso", "OK", 'OK', 'Information')

        } catch { 
            if (-not $success) {
                $lblStatus.Text="Error"
                $errMsg = $_.Exception.Message
                Write-Log -LogLevel ERROR -Message "WimMetadataManager: Falla critica al escribir metadatos usando la API .NET - $errMsg"
                [System.Windows.Forms.MessageBox]::Show("Error al guardar: $errMsg", "Error", 'OK', 'Error')
            }
        } finally { 
            $form.Cursor=[System.Windows.Forms.Cursors]::Default; $btnSave.Enabled=$true 
            # Actualizamos la lista desplegable con el nuevo nombre
            if ($success) { 
                $cmbIndex.Items[$idx - 1] = "[$idx] " + $d["Nombre"] 
                Write-Log -LogLevel INFO -Message "WimMetadataManager: UI y lista de indices actualizados con el nuevo nombre."
            }
        }
    })

    $form.ShowDialog() | Out-Null
	$form.Dispose()
	$form = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500
}

# =================================================================
#  Modulo GUI de Drivers
# =================================================================
function Show-Drivers-GUI {
    param()
    
    # 1. Validaciones
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 2. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Inyector de Drivers - (Offline)"
    $form.Size = New-Object System.Drawing.Size(1000, 650)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestion de Drivers"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Botones Superiores
    $btnLoadFolder = New-Object System.Windows.Forms.Button
    $btnLoadFolder.Text = "[CARPETA] Cargar..."
    $btnLoadFolder.Location = New-Object System.Drawing.Point(600, 12)
    $btnLoadFolder.Size = New-Object System.Drawing.Size(160, 30)
    $btnLoadFolder.BackColor = [System.Drawing.Color]::FromArgb(70, 70, 70)
    $btnLoadFolder.ForeColor = [System.Drawing.Color]::White
    $btnLoadFolder.FlatStyle = "Flat"
    $form.Controls.Add($btnLoadFolder)

    $btnAddFile = New-Object System.Windows.Forms.Button
    $btnAddFile.Text = "+ Agregar Archivo .INF"
    $btnAddFile.Location = New-Object System.Drawing.Point(770, 12)
    $btnAddFile.Size = New-Object System.Drawing.Size(180, 30)
    $btnAddFile.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddFile.ForeColor = [System.Drawing.Color]::White
    $btnAddFile.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFile)

    # Leyenda
    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Text = "Amarillo = Ya instalado | Blanco = Nuevo"
    $lblLegend.Location = New-Object System.Drawing.Point(20, 45)
    $lblLegend.AutoSize = $true
    $lblLegend.ForeColor = [System.Drawing.Color]::Gold
    $form.Controls.Add($lblLegend)

    # ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(20, 70)
    $listView.Size = New-Object System.Drawing.Size(940, 470)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $listView.ForeColor = [System.Drawing.Color]::White
    
    # Columnas
    $listView.Columns.Add("Estado", 100) | Out-Null
    $listView.Columns.Add("Archivo INF", 180) | Out-Null
    $listView.Columns.Add("Clase", 100) | Out-Null
    $listView.Columns.Add("Version", 120) | Out-Null
    $listView.Columns.Add("Ruta Completa", 400) | Out-Null

    $form.Controls.Add($listView)

    # Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Listo."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 550)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    # Botones Inferiores
    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "INYECTAR SELECCIONADOS"
    $btnInstall.Location = New-Object System.Drawing.Point(760, 560)
    $btnInstall.Size = New-Object System.Drawing.Size(200, 35)
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatStyle = "Flat"
    $form.Controls.Add($btnInstall)

    $btnSelectNew = New-Object System.Windows.Forms.Button
    $btnSelectNew.Text = "Seleccionar Solo Nuevos"
    $btnSelectNew.Location = New-Object System.Drawing.Point(20, 580)
    $btnSelectNew.Size = New-Object System.Drawing.Size(150, 25)
    $btnSelectNew.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectNew.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectNew)

    # Cache Global
    $script:cachedInstalledDrivers = @()

    # --- HELPER: PROCESAMIENTO ROBUSTO DE INF ---
    $Script:ProcessInfFile = {
        param($fileObj)
        
        $classType = "Desconocido"; $localVersion = "---"
        $statusText = "Nuevo"; $isInstalled = $false

        try {
            # Optimizacion masiva: Uso de StreamReader nativo de .NET
            $stream = [System.IO.StreamReader]::new($fileObj.FullName)
            $linesRead = 0
            
            while ($null -ne ($line = $stream.ReadLine()) -and $linesRead -lt 300) {
                # Buscar Clase
                if ($line -match "^Class\s*=\s*(.*)") {
                    $classType = $matches[1].Trim()
                }
                # Buscar Version (DriverVer = fecha, version)
                if ($line -match "DriverVer\s*=\s*.*?,([0-9\.\s]+)") {
                    $localVersion = $matches[1].Trim()
                }

                # Optimizacion: Si ya encontramos ambos, salimos del bucle
                if ($classType -ne "Desconocido" -and $localVersion -ne "---") { break }
                
                $linesRead++
            }
        } catch {
            # Silencioso en caso de error de lectura (ej. archivo bloqueado)
        } finally {
            # CRITICO: Liberar el handle del archivo siempre
            if ($null -ne $stream) {
                $stream.Close()
                $stream.Dispose()
            }
        }

        # Logica de Comparacion
        $foundByName = $script:cachedInstalledDrivers | Where-Object { [System.IO.Path]::GetFileName($_.OriginalFileName) -eq $fileObj.Name }
        
        if ($foundByName) {
            $isInstalled = $true; $statusText = "INSTALADO"
        } 
        elseif ($localVersion -ne "---") {
            # Comparar version exacta + clase
            $foundByVer = $script:cachedInstalledDrivers | Where-Object { $_.Version -eq $localVersion -and $_.ClassName -eq $classType }
            if ($foundByVer) { $isInstalled = $true; $statusText = "INSTALADO" }
        }

        # Crear Item
        $item = New-Object System.Windows.Forms.ListViewItem($statusText)
        $item.SubItems.Add($fileObj.Name) | Out-Null
        $item.SubItems.Add($classType) | Out-Null
        $item.SubItems.Add($localVersion) | Out-Null
        $item.SubItems.Add($fileObj.FullName) | Out-Null
        $item.Tag = $fileObj.FullName
        
        if ($isInstalled) {
            $item.BackColor = [System.Drawing.Color]::FromArgb(60, 50, 0)
            $item.ForeColor = [System.Drawing.Color]::Gold
            $item.Checked = $false
        } else {
            $item.Checked = $true
        }
        return $item
    }

    # 3. EVENTO LOAD
    $form.Add_Shown({
        $form.Refresh(); $listView.BeginUpdate()
        $lblStatus.Text = "Analizando drivers instalados en WIM..."
        $form.Refresh()
        
        try {
            $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
            if ($dismDrivers) { $script:cachedInstalledDrivers = $dismDrivers }
        } catch {}

        $listView.EndUpdate()
        $lblStatus.Text = "Listo. Usa los botones superiores."
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    # Botones de Carga
    $btnLoadFolder.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Buscar drivers recursivamente"
        if ($fbd.ShowDialog() -eq 'OK') {
            $selPath = $fbd.SelectedPath
            $lblStatus.Text = "Escaneando..."
            $form.Refresh()
            $listView.BeginUpdate()
            $files = Get-ChildItem -Path $selPath -Filter "*.inf" -Recurse
            foreach ($f in $files) {
                $newItem = & $Script:ProcessInfFile -fileObj $f
                $listView.Items.Add($newItem) | Out-Null
            }
            $listView.EndUpdate()
            $lblStatus.Text = "Drivers cargados: $($listView.Items.Count)"
        }
    })

    $btnAddFile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Archivos INF (*.inf)|*.inf"; $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $listView.BeginUpdate()
            foreach ($fn in $ofd.FileNames) {
                try {
                    $newItem = & $Script:ProcessInfFile -fileObj (Get-Item $fn)
                    $listView.Items.Add($newItem) | Out-Null
                } catch {}
            }
            $listView.EndUpdate()
        }
    })

    # Resto de logica
    $btnSelectNew.Add_Click({
        foreach ($item in $listView.Items) {
            if ($item.Text -match "Nuevo") { $item.Checked = $true } else { $item.Checked = $false }
        }
    })

    $btnInstall.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { 
            Write-Log -LogLevel WARN -Message "Driver_Injector: Intento de instalacion sin drivers seleccionados en la GUI."
            return 
        }

        if ([System.Windows.Forms.MessageBox]::Show("Inyectar $($checkedItems.Count) drivers?", "Confirmar", 'YesNo') -eq 'Yes') {
            Write-Log -LogLevel ACTION -Message "Driver_Injector: Iniciando inyeccion masiva de $($checkedItems.Count) controladores en la imagen."
            $btnInstall.Enabled = $false
            
            $count = 0
            $errs = 0
            $total = $checkedItems.Count
            $success = 0

            foreach ($item in $checkedItems) {
                $count++
                $driverName = $item.SubItems[1].Text
                $driverPath = $item.Tag
                
                $lblStatus.Text = "Instalando ($count/$total): $driverName..."
                $form.Refresh()
                
                Write-Log -LogLevel INFO -Message "Driver_Injector: Procesando [$count/$total] -> $driverPath"
                
                try {
                    # Comando de inyeccion
                    dism /Image:$Script:MOUNT_DIR /Add-Driver /Driver:"$driverPath" /ForceUnsigned | Out-Null
                    
                    if ($LASTEXITCODE -eq 0) {
                        # Feedback Visual Inmediato
                        $item.BackColor = [System.Drawing.Color]::DarkGreen
                        $item.Text = "INSTALADO"
                        $item.Checked = $false
                        $success++
                        Write-Log -LogLevel INFO -Message "Driver_Injector: Exito. Controlador inyectado correctamente."
                    } else { 
                        throw "DISM rechazo el controlador. LASTEXITCODE: $LASTEXITCODE" 
                    }
                } catch { 
                    $errs++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    $item.Text = "ERROR"
                    Write-Log -LogLevel ERROR -Message "Driver_Injector: Falla critica inyectando [$driverName] - $($_.Exception.Message)"
                }
            }

            Write-Log -LogLevel ACTION -Message "Driver_Injector: Ciclo de inyeccion finalizado. Exitos: $success | Errores: $errs"

            $lblStatus.Text = "Actualizando base de datos de drivers... Por favor espera."
            $form.Refresh()
            
            Write-Log -LogLevel INFO -Message "Driver_Injector: Consultando a DISM para reconstruir la cache interna de drivers instalados..."
            
            try {
                # Forzamos la relectura de lo que realmente quedo instalado en la imagen
                $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                if ($dismDrivers) { 
                    $script:cachedInstalledDrivers = $dismDrivers 
                    Write-Log -LogLevel INFO -Message "Driver_Injector: Cache recargada exitosamente. Se encontraron $($dismDrivers.Count) controladores en la imagen."
                } else {
                    Write-Log -LogLevel WARN -Message "Driver_Injector: Get-WindowsDriver no devolvio resultados al recargar la cache."
                }
            } catch {
                Write-Log -LogLevel ERROR -Message "Driver_Injector: Fallo al ejecutar Get-WindowsDriver durante la recarga de cache - $($_.Exception.Message)"
                Write-Warning "No se pudo actualizar la cache de drivers."
            }

            $btnInstall.Enabled = $true
            $lblStatus.Text = "Proceso terminado. Errores: $errs"
            
            [System.Windows.Forms.MessageBox]::Show("Proceso terminado.`nErrores: $errs`n`nLa lista de drivers instalados se ha actualizado internamente.", "Info", 'OK', 'Information')
        } else {
            Write-Log -LogLevel INFO -Message "Driver_Injector: El usuario cancelo la inyeccion en el cuadro de confirmacion."
        }
    })
	
	# Cierre Seguro
    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Seguro que quieres cerrar esta ventana?", 
            "Confirmar", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  Modulo GUI de Desinstalacion de Drivers
# =================================================================
function Show-Uninstall-Drivers-GUI {
    param()
    
    # 1. Validaciones
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 2. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Eliminar Drivers de la Imagen - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(850, 600)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Drivers de Terceros Instalados (OEM)"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Advertencia
    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.Text = "CUIDADO: No elimines drivers de arranque (Disco/USB) o la imagen no iniciara."
    $lblWarn.Location = New-Object System.Drawing.Point(350, 20)
    $lblWarn.AutoSize = $true
    $lblWarn.ForeColor = [System.Drawing.Color]::Salmon
    $form.Controls.Add($lblWarn)

    # ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(20, 50)
    $listView.Size = New-Object System.Drawing.Size(790, 450)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $listView.ForeColor = [System.Drawing.Color]::White
    
    # Columnas
    $listView.Columns.Add("Nombre Publicado (ID)", 150) | Out-Null
    $listView.Columns.Add("Archivo Original", 200) | Out-Null
    $listView.Columns.Add("Clase", 120) | Out-Null
    $listView.Columns.Add("Proveedor", 150) | Out-Null
    $listView.Columns.Add("Version", 100) | Out-Null

    $form.Controls.Add($listView)

    # Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Leyendo almacen de drivers..."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 510)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    # Botones
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "ELIMINAR SELECCIONADOS"
    $btnDelete.Location = New-Object System.Drawing.Point(560, 520)
    $btnDelete.Size = New-Object System.Drawing.Size(250, 35)
    $btnDelete.BackColor = [System.Drawing.Color]::Crimson
    $btnDelete.ForeColor = [System.Drawing.Color]::White
    $btnDelete.FlatStyle = "Flat"
    $form.Controls.Add($btnDelete)

    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Marcar Todo"
    $btnSelectAll.Location = New-Object System.Drawing.Point(20, 530)
    $btnSelectAll.Size = New-Object System.Drawing.Size(100, 25)
    $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectAll.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectAll)

    # 4. Logica de Carga (Get-WindowsDriver)
    $form.Add_Shown({
        $form.Refresh()
        $listView.BeginUpdate()
        
        try {
            # Obtenemos solo drivers de terceros (sin -All) para evitar borrar drivers de sistema Microsoft
            $drivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction Stop
            
            foreach ($drv in $drivers) {
                # El "Published Name" (ej. oem1.inf) es lo que DISM necesita para borrar
                $oemName = $drv.Driver 
                
                $item = New-Object System.Windows.Forms.ListViewItem($oemName)
                $item.SubItems.Add($drv.OriginalFileName) | Out-Null
                $item.SubItems.Add($drv.ClassName) | Out-Null
                $item.SubItems.Add($drv.ProviderName) | Out-Null
                $item.SubItems.Add($drv.Version) | Out-Null
                
                # Guardamos el nombre OEM en el Tag para usarlo al borrar
                $item.Tag = $oemName 
                
                $listView.Items.Add($item) | Out-Null
            }
            $lblStatus.Text = "Drivers encontrados: $($listView.Items.Count)"
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
        }
        catch {
            $lblStatus.Text = "Error al leer drivers: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }
        $listView.EndUpdate()
    })

    # 5. Eventos de Botones
    $btnSelectAll.Add_Click({
        foreach ($item in $listView.Items) { $item.Checked = $true }
    })

    $btnDelete.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a ELIMINAR PERMANENTEMENTE $($checkedItems.Count) drivers.`nEstas seguro?", "Confirmar Eliminacion", 'YesNo', 'Warning')
        if ($confirm -eq 'Yes') {
            $btnDelete.Enabled = $false

            $count = 0
            $total = $checkedItems.Count
            $errors = 0

            foreach ($item in $checkedItems) {
                $count++
                $oemInf = $item.Tag
                $origName = $item.SubItems[1].Text
                
                $lblStatus.Text = "Eliminando ($count/$total): $origName ($oemInf)..."
                $form.Refresh()

                Write-Log -LogLevel ACTION -Message "DRIVER_REMOVE: Eliminando $oemInf ($origName)"
                
                try {
                    # Comando de eliminacion
                    dism /Image:$Script:MOUNT_DIR /Remove-Driver /Driver:"$oemInf" | Out-Null
                    
                    if ($LASTEXITCODE -ne 0) { throw "Error DISM $LASTEXITCODE" }
                    
                    # Feedback Visual
                    $item.BackColor = [System.Drawing.Color]::Gray
                    $item.ForeColor = [System.Drawing.Color]::Black
                    $item.Text += " [BORRADO]"
                    $item.Checked = $false
                } catch {
                    $errors++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    Write-Log -LogLevel ERROR -Message "Fallo al eliminar $oemInf"
                }
            }

            $btnDelete.Enabled = $true
            $lblStatus.Text = "Proceso finalizado. Errores: $errors"
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nEliminados: $($total - $errors)`nErrores: $errors", "Resultado", 'OK', 'Information')
        }
    })
	
	# Cierre Seguro
    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Seguro que quieres cerrar esta ventana?", 
            "Confirmar", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  Modulo GUI de Bloatware
# =================================================================
function Show-Bloatware-GUI {
    param()
    
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Config Formulario ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Gestor de Aplicaciones (Bloatware) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(800, 700)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White

    # Título y Filtros
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Eliminacion de Apps Preinstaladas"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"; $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Buscador
    $lblSearch = New-Object System.Windows.Forms.Label
	$lblSearch.Text = "Buscar:"
	$lblSearch.Location = "20, 50"
	$lblSearch.AutoSize=$true
    $form.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
	$txtSearch.Location = "70, 48"
	$txtSearch.Size = "400, 23"
    $form.Controls.Add($txtSearch)

    # Toggle Seguridad
    $chkShowSystem = New-Object System.Windows.Forms.CheckBox
    $chkShowSystem.Text = "Mostrar Apps del Sistema (Peligroso)"
	$chkShowSystem.Location = "500, 48"
	$chkShowSystem.AutoSize=$true
    $chkShowSystem.ForeColor = [System.Drawing.Color]::Salmon
    $form.Controls.Add($chkShowSystem)

    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = "20, 80"
	$lv.Size = "740, 500"
    $lv.View = "Details"
	$lv.CheckBoxes = $true
	$lv.FullRowSelect = $true
	$lv.GridLines = $true
    $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
	$lv.ForeColor = [System.Drawing.Color]::White
    $lv.Columns.Add("Aplicacion (Nombre)", 400) | Out-Null
    $lv.Columns.Add("Categoria", 150) | Out-Null
    $lv.Columns.Add("Package ID", 150) | Out-Null
    $form.Controls.Add($lv)

    # Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Cargando catalogo..."
    $lblStatus.Location = "20, 590"
	$lblStatus.AutoSize = $true
	$lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Botones
    $btnSelectRec = New-Object System.Windows.Forms.Button
    $btnSelectRec.Text = "Marcar Recomendados (Bloat)"
	$btnSelectRec.Location = "20, 620"
	$btnSelectRec.Size = "200, 30"
    $btnSelectRec.BackColor = [System.Drawing.Color]::Orange
	$btnSelectRec.ForeColor = [System.Drawing.Color]::Black
	$btnSelectRec.FlatStyle="Flat"
    $form.Controls.Add($btnSelectRec)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "ELIMINAR SELECCIONADOS"
	$btnRemove.Location = "500, 615"
	$btnRemove.Size = "260, 40"
    $btnRemove.BackColor = [System.Drawing.Color]::Crimson
	$btnRemove.ForeColor = [System.Drawing.Color]::White
	$btnRemove.FlatStyle="Flat"
    $btnRemove.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnRemove)

    # --- LOGICA ---
    $script:cachedApps = @()
    $script:safePattern = ""
    $script:bloatPattern = ""

    # Helper de Llenado
    $PopulateList = {
        $lv.BeginUpdate()
        $lv.Items.Clear()
        $filter = $txtSearch.Text
        $showSys = $chkShowSystem.Checked

        foreach ($app in $script:cachedApps) {
            # 1. Filtro Texto
            if ($filter.Length -gt 0 -and $app.DisplayName -notmatch $filter) { continue }

            # 2. Clasificación
            $type = "Normal"
            $color = [System.Drawing.Color]::White
            
            if ($app.PackageName -match $script:safePattern -or $app.DisplayName -match $script:safePattern) {
                if (-not $showSys) { continue }
                $type = "Sistema (Vital)"
                $color = [System.Drawing.Color]::LightGreen
            }
            elseif ($app.PackageName -match $script:bloatPattern -or $app.DisplayName -match $script:bloatPattern) {
                $type = "Bloatware"
                $color = [System.Drawing.Color]::Orange
            }

            $item = New-Object System.Windows.Forms.ListViewItem($app.DisplayName)
            $item.SubItems.Add($type) | Out-Null
            $item.SubItems.Add($app.PackageName) | Out-Null
            $item.ForeColor = $color
            $item.Tag = $app.PackageName
            $lv.Items.Add($item) | Out-Null
        }
        $lv.EndUpdate()
        $lblStatus.Text = "Mostrando: $($lv.Items.Count) aplicaciones."
    }

    # Carga Inicial
    $form.Add_Shown({
        $form.Refresh(); $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        
        # Cargar Catálogo (Logica existente)
        $appsFile = Join-Path $PSScriptRoot "Catalogos\Bloatware.ps1"
        if (-not (Test-Path $appsFile)) { $appsFile = Join-Path $PSScriptRoot "Bloatware.ps1" }
        
        $safeList = @("Microsoft.WindowsStore", "Microsoft.WindowsCalculator", "Microsoft.VCLibs", "Microsoft.NET.Native")
        $bloatList = @("Microsoft.BingNews", "Microsoft.GetHelp", "Microsoft.SkypeApp", "Microsoft.Solitaire")

        if (Test-Path $appsFile) {
            . $appsFile
            if ($script:AppLists) { $safeList = $script:AppLists.Safe; $bloatList = $script:AppLists.Bloat }
        }
        $script:safePattern = ($safeList -join "|").Replace(".", "\.")
        $script:bloatPattern = ($bloatList -join "|").Replace(".", "\.")

        try {
            $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            & $PopulateList
        } catch {
            $lblStatus.Text = "Error: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Eventos
    $txtSearch.Add_TextChanged({ & $PopulateList })
    $chkShowSystem.Add_CheckedChanged({ & $PopulateList })

    $btnSelectRec.Add_Click({
        foreach ($item in $lv.Items) {
            if ($item.SubItems[1].Text -eq "Bloatware") { $item.Checked = $true }
        }
    })

    $btnRemove.Add_Click({
        $checked = $lv.CheckedItems
        if ($checked.Count -eq 0) { 
            Write-Log -LogLevel WARN -Message "AppxManager: Intento de ejecucion sin aplicaciones seleccionadas."
            return 
        }
        
        if ([System.Windows.Forms.MessageBox]::Show("Eliminar $($checked.Count) apps permanentemente?", "Confirmar", 'YesNo', 'Warning') -eq 'Yes') {
            Write-Log -LogLevel ACTION -Message "AppxManager: Iniciando eliminacion en lote de $($checked.Count) aplicaciones preinstaladas (Appx)."
            
            $btnRemove.Enabled = $false
            $errs = 0
            $success = 0
            
            foreach ($item in $checked) {
                $pkg = $item.Tag
                $lblStatus.Text = "Eliminando: $($item.Text)..."; $form.Refresh()
                Write-Log -LogLevel INFO -Message "AppxManager: Intentando purgar paquete -> $pkg"
                
                try {
                    Remove-AppxProvisionedPackage -Path $Script:MOUNT_DIR -PackageName $pkg -ErrorAction Stop | Out-Null
                    
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $item.Text += " (ELIMINADO)"
                    $item.Checked = $false
                    $success++
                    
                    Write-Log -LogLevel INFO -Message "AppxManager: Paquete purgado con exito."
                } catch {
                    $errs++
                    $item.ForeColor = [System.Drawing.Color]::Red
                    Write-Log -LogLevel ERROR -Message "AppxManager: Falla al eliminar paquete [$pkg] - $($_.Exception.Message)"
                }
            }
            
            $btnRemove.Enabled = $true
            $lblStatus.Text = "Listo. Errores: $errs"
            
            Write-Log -LogLevel ACTION -Message "AppxManager: Proceso de limpieza finalizado. Exitos: $success | Errores: $errs"
            Write-Log -LogLevel INFO -Message "AppxManager: Refrescando cache interna de aplicaciones de la imagen..."
            
            # Actualizar caché
            $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            & $PopulateList
            
            Write-Log -LogLevel INFO -Message "AppxManager: Lista visual recargada correctamente."
        } else {
            Write-Log -LogLevel INFO -Message "AppxManager: El usuario cancelo la eliminacion en el cuadro de confirmacion."
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  Modulo GUI de Servicios Offline
# =================================================================
function Show-Services-Offline-GUI {
    param()

    # 1. Validaciones
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    # 2. Cargar Catalogo
    $servicesFile = Join-Path $PSScriptRoot "Catalogos\Servicios.ps1"
    if (-not (Test-Path $servicesFile)) { $servicesFile = Join-Path $PSScriptRoot "Servicios.ps1" }
    
    if (Test-Path $servicesFile) { 
        . $servicesFile 
    } else { 
        [System.Windows.Forms.MessageBox]::Show("No se encontro Servicios.ps1", "Error", 'OK', 'Error')
        return 
    }

    # 3. Montar Hives
    if (-not (Mount-Hives)) { return }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Collections

    # 4. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Optimizador de Servicios Offline - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(1100, 750)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # ToolTip
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 5000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay = 500
    $toolTip.ShowAlways = $true

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestion de Servicios por Categoria"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- CONTROL DE PESTANAS ---
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 40)
    $tabControl.Size = New-Object System.Drawing.Size(1045, 540)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tabControl)

    # --- PANEL DE ACCIONES ---
    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Location = New-Object System.Drawing.Point(20, 600)
    $pnlActions.Size = New-Object System.Drawing.Size(1045, 100)
    $pnlActions.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $pnlActions.BorderStyle = "FixedSingle"
    $form.Controls.Add($pnlActions)

    # Barra de Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Cargando Hives... espera."
    $lblStatus.Location = New-Object System.Drawing.Point(10, 10)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $pnlActions.Controls.Add($lblStatus)

    # Boton Marcar Todo
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Marcar Todo"
    $btnSelectAll.Location = New-Object System.Drawing.Point(10, 40)
    $btnSelectAll.Size = New-Object System.Drawing.Size(140, 40)
    $btnSelectAll.BackColor = [System.Drawing.Color]::Gray
    $btnSelectAll.FlatStyle = "Flat"
    $toolTip.SetToolTip($btnSelectAll, "Marca todos los servicios visibles en la pestana actual.")
    $pnlActions.Controls.Add($btnSelectAll)

    # Boton Restaurar (NUEVO)
    $btnRestore = New-Object System.Windows.Forms.Button
    $btnRestore.Text = "RESTAURAR ORIGINALES"
    $btnRestore.Location = New-Object System.Drawing.Point(400, 40)
    $btnRestore.Size = New-Object System.Drawing.Size(280, 40)
    $btnRestore.BackColor = [System.Drawing.Color]::FromArgb(200, 100, 0) # Naranja
    $btnRestore.ForeColor = [System.Drawing.Color]::White
    $btnRestore.FlatStyle = "Flat"
    $btnRestore.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $toolTip.SetToolTip($btnRestore, "Devuelve los servicios seleccionados a su estado por defecto (Manual/Automatico).")
    $pnlActions.Controls.Add($btnRestore)

    # Boton Deshabilitar
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "DESHABILITAR SELECCION"
    $btnApply.Location = New-Object System.Drawing.Point(700, 40)
    $btnApply.Size = New-Object System.Drawing.Size(320, 40)
    $btnApply.BackColor = [System.Drawing.Color]::Crimson
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $toolTip.SetToolTip($btnApply, "Deshabilita los servicios seleccionados.")
    $pnlActions.Controls.Add($btnApply)

    # Lista global
    $globalListViews = New-Object System.Collections.Generic.List[System.Windows.Forms.ListView]

    # 4. Logica de Carga Dinamica
    $form.Add_Shown({
        $form.Refresh()
        
        # Obtener categorias unicas
        $categories = $script:ServiceCatalog | Select-Object -ExpandProperty Category -Unique | Sort-Object
        $tabControl.SuspendLayout()

        foreach ($cat in $categories) {
            $tabPage = New-Object System.Windows.Forms.TabPage
            $tabPage.Text = "  $cat  "
            $tabPage.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
            $lv.View = [System.Windows.Forms.View]::Details
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White
            $lv.BorderStyle = "None"
            
            $lv.Columns.Add("Servicio", 200) | Out-Null
            $lv.Columns.Add("Estado Actual", 120) | Out-Null
            $lv.Columns.Add("Config. Original", 120) | Out-Null
            $lv.Columns.Add("Descripcion", 450) | Out-Null
            
            $tabPage.Tag = $cat
            $tabPage.Controls.Add($lv)
            $tabControl.TabPages.Add($tabPage)
            $globalListViews.Add($lv)
        }

        # Llenar Datos
        $totalServices = 0

        foreach ($svc in $script:ServiceCatalog) {
            # Buscar el ListView correcto
            $targetLV = $null
            foreach ($tab in $tabControl.TabPages) {
                if ($tab.Tag -eq $svc.Category) {
                    $targetLV = $tab.Controls[0] 
                    break
                }
            }

            if ($targetLV) {
                $ctrlSet = Get-OfflineControlSet # Llamamos a la nueva funcion
                $regPath = "Registry::HKLM\OfflineSystem\$ctrlSet\Services\$($svc.Name)"
                $currentStart = "No Encontrado"
                $isDisabled = $false
                
                if (Test-Path $regPath) {
                    $val = (Get-ItemProperty -Path $regPath -Name "Start" -ErrorAction SilentlyContinue).Start
                    
                    if ($val -eq 4) { 
                        $currentStart = "Deshabilitado"
                        $isDisabled = $true
                    }
                    elseif ($val -eq 2) { $currentStart = "Automatico" }
                    elseif ($val -eq 3) { $currentStart = "Manual" }
                    else { $currentStart = "Desconocido ($val)" }
                }

                $item = New-Object System.Windows.Forms.ListViewItem($svc.Name)
                $item.SubItems.Add($currentStart) | Out-Null
                
                # Traducir DefaultStartupType del ingles al espanol para mostrar
                $defDisplay = $svc.DefaultStartupType
                if ($defDisplay -eq "Automatic") { $defDisplay = "Automatico" }
                
                $item.SubItems.Add($defDisplay) | Out-Null
                $item.SubItems.Add($svc.Description) | Out-Null
                
                # IMPORTANTE: Guardamos el OBJETO COMPLETO en el Tag para usarlo al restaurar
                $item.Tag = $svc 

                # Colores
                if ($isDisabled) {
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                    $item.Checked = $false 
                } elseif ($currentStart -eq "No Encontrado") {
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $item.Checked = $false 
                } else {
                    $item.ForeColor = [System.Drawing.Color]::White
                    $item.Checked = $true 
                }

                $targetLV.Items.Add($item) | Out-Null
                $totalServices++
            }
        }

        $tabControl.ResumeLayout()
        $lblStatus.Text = "Carga lista. $totalServices servicios encontrados."
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    # 5. Logica de Procesamiento (Helper Interno)
    $ProcessServices = {
        param($Mode) # 'Disable' o 'Restore'

        Write-Log -LogLevel INFO -Message "ServiceManager: Recopilando servicios seleccionados para operacion ($Mode)."

        $allChecked = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($i in $lv.CheckedItems) { $allChecked.Add($i) }
        }

        if ($allChecked.Count -eq 0) { 
            Write-Log -LogLevel WARN -Message "ServiceManager: Intento de ejecucion sin servicios seleccionados."
            [System.Windows.Forms.MessageBox]::Show("No hay servicios seleccionados.", "Aviso", 'OK', 'Warning')
            return 
        }

        $actionTxt = if ($Mode -eq 'Disable') { "DESHABILITAR" } else { "RESTAURAR" }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a $actionTxt $($allChecked.Count) servicios.`nEstas seguro?", "Confirmar", 'YesNo', 'Warning')
        if ($confirm -eq 'No') { 
            Write-Log -LogLevel INFO -Message "ServiceManager: Operacion cancelada por el usuario."
            return 
        }

        Write-Log -LogLevel ACTION -Message "ServiceManager: Iniciando proceso de servicios. Modo: [$Mode] | Cantidad a procesar: $($allChecked.Count)"

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $successCount = 0
        $errCount = 0

        foreach ($item in $allChecked) {
            $svcObj = $item.Tag # Recuperamos el objeto completo
            $svcName = $svcObj.Name
            $regPath = "Registry::HKLM\OfflineSystem\ControlSet001\Services\$svcName"
            
            $lblStatus.Text = "$actionTxt Servicio: $svcName..."
            $form.Refresh()

            # Determinar Valor
            $targetVal = 3 # Manual por defecto
            
            if ($Mode -eq 'Disable') {
                $targetVal = 4
            } else {
                # Modo RESTORE: Mapear texto a numero
                switch ($svcObj.DefaultStartupType) {
                    "Automatic" { $targetVal = 2 }
                    "Manual"    { $targetVal = 3 }
                    "Disabled"  { $targetVal = 4 }
                    default     { $targetVal = 3 }
                }
            }

            Write-Log -LogLevel INFO -Message "ServiceManager: Procesando [$svcName] -> Target Start Value: $targetVal"

            # Desbloqueo preventivo
            Unlock-Single-Key -SubKeyPath ($regPath -replace "^Registry::HKLM\\", "")

            try {
                # Metodo PowerShell
                if (-not (Test-Path $regPath)) { throw "La clave del servicio no existe en la colmena Offline." }
                
                Set-ItemProperty -Path $regPath -Name "Start" -Value $targetVal -Type DWord -Force -ErrorAction Stop
                
                # Actualizar UI
                if ($Mode -eq 'Disable') {
                    $item.SubItems[1].Text = "Deshabilitado"
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                } else {
                    $restoredText = if ($targetVal -eq 2) { "Automatico" } else { "Manual" }
                    $item.SubItems[1].Text = "$restoredText (Restaurado)"
                    $item.ForeColor = [System.Drawing.Color]::Cyan
                }
                
                $item.Checked = $false
                $successCount++
                Write-Log -LogLevel INFO -Message "ServiceManager: [$svcName] modificado exitosamente via PowerShell nativo."

            } catch {
                Write-Log -LogLevel WARN -Message "ServiceManager: Fallo API nativa para [$svcName] - $($_.Exception.Message). Usando fallback reg.exe..."
                
                # Fallback REG.EXE
                $cmdRegPath = $regPath -replace "^Registry::", ""
                $proc = Start-Process reg.exe -ArgumentList "add `"$cmdRegPath`" /v Start /t REG_DWORD /d $targetVal /f" -PassThru -WindowStyle Hidden -Wait
                
                if ($proc.ExitCode -eq 0) {
                    if ($Mode -eq 'Disable') {
                        $item.SubItems[1].Text = "Deshabilitado"
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                    } else {
                        $item.SubItems[1].Text = "Restaurado"
                        $item.ForeColor = [System.Drawing.Color]::Cyan
                    }
                    $item.Checked = $false
                    $successCount++
                    Write-Log -LogLevel INFO -Message "ServiceManager: [$svcName] modificado exitosamente usando Fallback (reg.exe)."
                } else {
                    $errCount++
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $item.SubItems[1].Text = "ERROR ACCESO"
                    Write-Log -LogLevel ERROR -Message "ServiceManager: Falla critica para [$svcName]. Fallback reg.exe devolvio codigo: $($proc.ExitCode)"
                }
            }
            Restore-KeyOwner -KeyPath $regPath
        }

        Write-Log -LogLevel ACTION -Message "ServiceManager: Proceso finalizado. Exitos: $successCount | Errores: $errCount"

        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $lblStatus.Text = "Proceso finalizado."
        [System.Windows.Forms.MessageBox]::Show("Procesados: $successCount`nErrores: $errCount", "Informe", 'OK', 'Information')
    }

    # 6. Eventos de Botones
    $btnSelectAll.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0]
            foreach ($item in $lv.Items) {
                # Solo marcar si no esta ya deshabilitado/inexistente
                if ($item.SubItems[1].Text -notmatch "Deshabilitado|No Encontrado") {
                    $item.Checked = $true
                }
            }
        }
    })

    $btnApply.Add_Click({ & $ProcessServices -Mode 'Disable' })
    $btnRestore.Add_Click({ & $ProcessServices -Mode 'Restore' })

    # Cierre Seguro
    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir?", 
            "Confirmar Salida", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else {
            $lblStatus.Text = "Desmontando Hives..."
            $form.Refresh()
            Start-Sleep -Milliseconds 500
            Unmount-Hives
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $globalListViews.Clear()
    $globalListViews = $null
    [GC]::Collect()
}

# =================================================================
#  Modulo GUI de Caracteristicas de Windows Offline
# =================================================================
function Show-Features-GUI {
    param()
    
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- Configuracion del Formulario ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Caracteristicas de Windows (Features) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(900, 700)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Tooltip para descripciones
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 10000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay = 500

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestor de Caracteristicas"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 10"
	$lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- BARRA DE BUSQUEDA ---
    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Buscar:"
	$lblSearch.Location = "20, 45"
	$lblSearch.AutoSize=$true
    $form.Controls.Add($lblSearch)

    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = "70, 42"
	$txtSearch.Size = "600, 23"
    $txtSearch.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
    $txtSearch.ForeColor = [System.Drawing.Color]::White
    $form.Controls.Add($txtSearch)

    # ListView
    $lv = New-Object System.Windows.Forms.ListView
    $lv.Location = "20, 80"
    $lv.Size = "840, 480"
    $lv.View = "Details"
    $lv.CheckBoxes = $true
    $lv.FullRowSelect = $true
    $lv.GridLines = $true
    $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lv.ForeColor = [System.Drawing.Color]::White
    $lv.ShowItemToolTips = $true
    
    $lv.Columns.Add("Caracteristica", 350) | Out-Null
    $lv.Columns.Add("Estado", 150) | Out-Null
    $lv.Columns.Add("Nombre Interno", 300) | Out-Null

    $form.Controls.Add($lv)

    # Estado y Botones
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Cargando datos... (La interfaz puede congelarse unos segundos)"
    $lblStatus.Location = "20, 570"
	$lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # NUEVO BOTÓN: Integración Offline de .NET 3.5
    $btnNetFx3 = New-Object System.Windows.Forms.Button
    $btnNetFx3.Text = "INTEGRAR .NET 3.5 (SXS)"
    $btnNetFx3.Location = "400, 600"
    $btnNetFx3.Size = "220, 40"
    $btnNetFx3.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnNetFx3.ForeColor = [System.Drawing.Color]::White
    $btnNetFx3.FlatStyle = "Flat"
    $btnNetFx3.Enabled = $false
    $toolTip.SetToolTip($btnNetFx3, "Instala .NET Framework 3.5 buscando la carpeta 'sxs' localmente.")
    $form.Controls.Add($btnNetFx3)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "APLICAR CAMBIOS"
    $btnApply.Location = "640, 600"
	$btnApply.Size = "220, 40"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
	$btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Enabled = $false
    $form.Controls.Add($btnApply)

    # Variable Global para Cache
    $script:cachedFeatures = @()

    # --- FUNCION HELPER PARA LLENAR LA LISTA ---
    $PopulateList = {
        param($FilterText)
        $lv.BeginUpdate()
        $lv.Items.Clear()
        
        foreach ($feat in $script:cachedFeatures) {
            $displayName = $feat.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $feat.FeatureName
            }

            if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
                if ($displayName -notmatch $FilterText -and $feat.FeatureName -notmatch $FilterText) {
                    continue 
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($displayName)
            
            # --- CORRECCIÓN CRÍTICA: Forzar a string para evitar el error del Enum ---
            $stateString = $feat.State.ToString()
            $stateDisplay = $stateString
            $color = [System.Drawing.Color]::White

            switch ($stateString) {
                "Enabled" { 
                    $stateDisplay = "Habilitado"
                    $color = [System.Drawing.Color]::Cyan
                    $item.Checked = $true
                }
                "Disabled" { 
                    $stateDisplay = "Deshabilitado" 
                    $item.Checked = $false
                }
                "DisabledWithPayloadRemoved" {
                    $stateDisplay = "Removido (Requiere Source)"
                    $color = [System.Drawing.Color]::Salmon
                    $item.Checked = $false
                }
                "EnablePending" {
                    $stateDisplay = "Pendiente (Habilitar)"
                    $color = [System.Drawing.Color]::Yellow
                    $item.Checked = $true
                }
                "DisablePending" {
                    $stateDisplay = "Pendiente (Deshabilitar)"
                    $color = [System.Drawing.Color]::Orange
                    $item.Checked = $false
                }
                Default {
                    # Fallback de seguridad: si aparece otro estado raro de DISM
                    $stateDisplay = $stateString 
                }
            }

            # Aseguramos el cast explícito a [string] al añadir los subitems a WinForms
            $item.SubItems.Add([string]$stateDisplay) | Out-Null
            $item.SubItems.Add([string]$feat.FeatureName) | Out-Null
            
            $item.ForeColor = $color
            $item.ToolTipText = $feat.Description
            $item.Tag = $feat

            $lv.Items.Add($item) | Out-Null
        }
        $lv.EndUpdate()
    }

    # --- EVENTO DE CARGA INICIAL ---
    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        
        try {
            $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
            & $PopulateList -FilterText ""
            
            $lblStatus.Text = "Total: $($script:cachedFeatures.Count). Listo para filtrar o aplicar."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnApply.Enabled = $true
            $btnNetFx3.Enabled = $true # Habilitamos el nuevo botón
        } catch {
            $lblStatus.Text = "Error critico al leer features: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "FEATURES_GUI: Error carga inicial: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- EVENTO DE BUSQUEDA ---
    $txtSearch.Add_TextChanged({ & $PopulateList -FilterText $txtSearch.Text })

    # --- LOGICA DEL BOTON .NET 3.5 ---
    $btnNetFx3.Add_Click({
        $sxsPath = $null
        
        # 1. Busqueda automatica
        $pathLocal = Join-Path $PSScriptRoot "sxs"
        if (Test-Path $pathLocal) { 
            $sxsPath = $pathLocal 
        } else {
            # 2. Busqueda interactiva
            $res = [System.Windows.Forms.MessageBox]::Show(
                "No se detecto la carpeta 'sxs' en la raiz del script automaticamente.`n`nDeseas seleccionarla manualmente?", 
                "Buscar Origen (.NET 3.5)", 
                'YesNo', 
                'Question'
            )
            
            if ($res -eq 'Yes') {
                $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
                $fbd.Description = "Selecciona la carpeta 'sxs' (Puede ser la original del ISO de Windows)"
                if ($fbd.ShowDialog() -eq 'OK') {
                    $sxsPath = $fbd.SelectedPath
                } else { return }
            } else { return }
        }

        if ($sxsPath) {
            # 3. FILTRO INTELIGENTE DE PAQUETES
            $cabFiles = Get-ChildItem -Path $sxsPath -Filter "*netfx3*.cab" -ErrorAction SilentlyContinue
            
            if (-not $cabFiles -or $cabFiles.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("No se encontro ningun paquete de .NET 3.5 (*netfx3*.cab) en la ruta seleccionada.`n`nPor favor verifica la carpeta.", "Origen Invalido", 'OK', 'Warning')
                return
            }

            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $btnNetFx3.Enabled = $false
            $btnApply.Enabled = $false
            
            $lblStatus.Text = "Aislando paquetes NetFx3 para instalacion rapida..."
            $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
            $form.Refresh()

            try {
                # A. Crear Entorno Esteril (Staging)
                $isolatedSxs = Join-Path $Script:Scratch_DIR "NetFx3_Staging"
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                New-Item -Path $isolatedSxs -ItemType Directory -Force | Out-Null

                # B. Copiar solo los paquetes relevantes y auditar tipos
                $neutralCount = 0
                $langCount = 0

                foreach ($cab in $cabFiles) {
                    Copy-Item -Path $cab.FullName -Destination $isolatedSxs -Force
                    
                    if ($cab.Name -match "~~.cab$") { $neutralCount++ }
                    else { $langCount++ }
                }

                Write-Log -LogLevel ACTION -Message "Smart SXS: Aislados $neutralCount paquetes neutros y $langCount de idioma en $isolatedSxs"
                
                # C. Ejecucion optimizada de DISM
                $lblStatus.Text = "Instalando .NET 3.5..."
                $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
                $form.Refresh()

                # Invocamos a DISM apuntando SOLO a la carpeta aislada, evitando que procese la basura del ISO
                dism /Image:"$Script:MOUNT_DIR" /Enable-Feature /FeatureName:NetFx3 /All /LimitAccess /Source:"$isolatedSxs" | Out-Null

                if ($LASTEXITCODE -eq 0) {
                    $lblStatus.Text = "Instalacion de .NET 3.5 exitosa."
                    $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
                    
                    $msg = ".NET Framework 3.5 se integro correctamente.`n`nSe inyectaron:`n- $neutralCount Paquete(s) Base (Neutral)`n- $langCount Paquete(s) de Idioma (Satelite)"
                    [System.Windows.Forms.MessageBox]::Show($msg, "Exito", 'OK', 'Information')
                    
                    # Refrescar cache de caracteristicas
                    $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
                    & $PopulateList -FilterText $txtSearch.Text
                } else {
                    $lblStatus.Text = "Error al instalar .NET 3.5 (Codigo $LASTEXITCODE)."
                    $lblStatus.ForeColor = [System.Drawing.Color]::Red
                    [System.Windows.Forms.MessageBox]::Show("Fallo la instalacion.`nCodigo DISM: $LASTEXITCODE", "Error", 'OK', 'Error')
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Excepcion inesperada: $_", "Error", 'OK', 'Error')
            } finally {
                # D. Limpieza del entorno esteril
                if (Test-Path $isolatedSxs) { Remove-Item $isolatedSxs -Recurse -Force -ErrorAction SilentlyContinue }
                
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
                $btnNetFx3.Enabled = $true
                $btnApply.Enabled = $true
            }
        }
    })

    # --- LOGICA DE APLICACION ESTANDAR ---
    $btnApply.Add_Click({
        if ($txtSearch.Text.Length -gt 0) {
            $res = [System.Windows.Forms.MessageBox]::Show("Filtro activo. Solo se procesaran elementos visibles.`nContinuar?", "Advertencia", 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
        }

        $changes = 0
        $errors = 0
        
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled = $false
        $btnNetFx3.Enabled = $false

        foreach ($item in $lv.Items) {
            $feat = $item.Tag
            $originalState = $feat.State
            $isNowChecked = $item.Checked
            
            $shouldEnable = ($originalState -ne "Enabled" -and $isNowChecked)
            $shouldDisable = ($originalState -eq "Enabled" -and -not $isNowChecked)

            if ($shouldEnable -or $shouldDisable) {
                
                # Bloqueo de seguridad: Evitar que usen el botón estándar para .NET 3.5 si requiere source
                if ($shouldEnable -and $feat.FeatureName -eq "NetFx3" -and $originalState -eq "DisabledWithPayloadRemoved") {
                    [System.Windows.Forms.MessageBox]::Show("Para habilitar .NET Framework 3.5, por favor usa el boton azul dedicado 'INTEGRAR .NET 3.5 (SXS)'.", "Aviso", 'OK', 'Information')
                    $item.Checked = $false
                    continue
                }

                $action = if ($shouldEnable) { "Enable" } else { "Disable" }
                $lblStatus.Text = "Procesando: $action $($feat.FeatureName)..."
                $form.Refresh()

                try {
                    Write-Log -LogLevel ACTION -Message "FEATURES: $action $($feat.FeatureName)"
                    
                    if ($shouldEnable) {
                        Enable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -All -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Habilitado"
                        $item.ForeColor = [System.Drawing.Color]::Cyan
                        $feat.State = "Enabled"
                    } else {
                        Disable-WindowsOptionalFeature -Path $Script:MOUNT_DIR -FeatureName $feat.FeatureName -NoRestart -ErrorAction Stop | Out-Null
                        $item.SubItems[1].Text = "Deshabilitado"
                        $item.ForeColor = [System.Drawing.Color]::White
                        $feat.State = "Disabled"
                    }
                    $changes++
                } catch {
                    $errors++
                    Write-Log -LogLevel ERROR -Message "Fallo $action feature $($feat.FeatureName): $_"
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $item.SubItems[1].Text = "ERROR"
                }
            }
        }
        
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnApply.Enabled = $true
        $btnNetFx3.Enabled = $true
        $lblStatus.Text = "Proceso finalizado."
        [System.Windows.Forms.MessageBox]::Show("Operacion completada.`nCambios: $changes`nErrores: $errors", "Informe", 'OK', 'Information')
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:cachedFeatures = $null
    [GC]::Collect()
}

# =================================================================
#  Modulo GUI de Gestor OOBE Offline
# =================================================================
function Show-Unattend-GUI {
    param()
    
    # 1. Validacion de Seguridad
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error Montaje", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- INTELIGENCIA DE SISTEMA: DETECTAR ARQUITECTURA ---
    $detectedArch = "amd64"
    try {
        $imgInfo = Get-WindowsImage -Path $Script:MOUNT_DIR -ErrorAction Stop
        switch ($imgInfo.Architecture) {
            0  { $detectedArch = "x86" }
            9  { $detectedArch = "amd64" }
            12 { $detectedArch = "arm64" }
        }
    } catch {
        Write-Log -LogLevel WARN -Message "No se pudo detectar arquitectura. Usando amd64 por defecto."
    }

    # 2. Setup del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Gestor OOBE Inteligente ($detectedArch) - Integrado"
    $form.Size = New-Object System.Drawing.Size(720, 880) # Formulario más alto para los nuevos menús
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Sistema de Pestanas
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = "10, 10"
    $tabControl.Size = "685, 820"
    $form.Controls.Add($tabControl)

    # =========================================================
    # PESTANA 1: GENERADOR AVANZADO
    # =========================================================
    $tabBasic = New-Object System.Windows.Forms.TabPage
    $tabBasic.Text = " Generador Avanzado "
    $tabBasic.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $tabControl.TabPages.Add($tabBasic)

    # --- GRUPO USUARIO ---
    $grpUser = New-Object System.Windows.Forms.GroupBox
    $grpUser.Text = " Usuario Admin Local (Opcional) "
    $grpUser.Location = "20, 15"
    $grpUser.Size = "620, 110"
    $grpUser.ForeColor = [System.Drawing.Color]::White
    $tabBasic.Controls.Add($grpUser)

    $chkInteractiveUser = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveUser.Text = "Forzar creacion manual de usuario (Mostrar pantalla OOBE)"
    $chkInteractiveUser.Location = "20, 25"
    $chkInteractiveUser.AutoSize = $true
    $chkInteractiveUser.ForeColor = [System.Drawing.Color]::Yellow
    $grpUser.Controls.Add($chkInteractiveUser)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "Usuario:"
    $lblUser.Location = "20, 55"
    $lblUser.AutoSize = $true
    $grpUser.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = "80, 53"
    $txtUser.Text = "Admin"
    $grpUser.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Clave:"
    $lblPass.Location = "250, 55"
    $lblPass.AutoSize = $true
    $grpUser.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Location = "300, 53"
    $txtPass.Text = "1234"
    $txtPass.PasswordChar = "*"
    $grpUser.Controls.Add($txtPass)

    $chkInteractiveUser.Add_CheckedChanged({
        if ($chkInteractiveUser.Checked) {
            $txtUser.Enabled = $false; $txtPass.Enabled = $false
        } else {
            $txtUser.Enabled = $true; $txtPass.Enabled = $true
        }
    })

    # --- GRUPO HACKS ---
    $grpHacks = New-Object System.Windows.Forms.GroupBox
    $grpHacks.Text = " Hacks y Bypass (Universal Win10/Win11) "
    $grpHacks.Location = "20, 135"
    $grpHacks.Size = "620, 145" # Más alto para el omitir wifi
    $grpHacks.ForeColor = [System.Drawing.Color]::Cyan
    $tabBasic.Controls.Add($grpHacks)

    $chkBypass = New-Object System.Windows.Forms.CheckBox
    $chkBypass.Text = "Bypass Requisitos (TPM 2.0, SecureBoot, RAM) - Ignorado en Win10"
    $chkBypass.Location = "20, 25"
    $chkBypass.AutoSize = $true
    $chkBypass.Checked = $true
    $grpHacks.Controls.Add($chkBypass)

    $chkNet = New-Object System.Windows.Forms.CheckBox
    $chkNet.Text = "Saltar Cuenta Microsoft (Forzar Local) + Saltar EULA"
    $chkNet.Location = "20, 55"
    $chkNet.AutoSize = $true
    $chkNet.Checked = $true
    $grpHacks.Controls.Add($chkNet)

    $chkNRO = New-Object System.Windows.Forms.CheckBox
    $chkNRO.Text = "Permitir instalacion sin Internet (BypassNRO)"
    $chkNRO.Location = "20, 85"
    $chkNRO.AutoSize = $true
    $chkNRO.Checked = $true
    $chkNRO.ForeColor = [System.Drawing.Color]::LightGreen
    $grpHacks.Controls.Add($chkNRO)

    # NUEVO: Omitir WiFi
    $chkHideWifi = New-Object System.Windows.Forms.CheckBox
    $chkHideWifi.Text = "Omitir la configuracion de red Wi-Fi (HideWirelessSetupInOOBE)"
    $chkHideWifi.Location = "20, 115"
    $chkHideWifi.AutoSize = $true
    $chkHideWifi.Checked = $true
    $chkHideWifi.ForeColor = [System.Drawing.Color]::LightGreen
    $grpHacks.Controls.Add($chkHideWifi)

    # --- NUEVO GRUPO: IDIOMA Y TECLADO ---
    $grpLang = New-Object System.Windows.Forms.GroupBox
    $grpLang.Text = " Elija las preferencias de idioma y la distribucion del teclado "
    $grpLang.Location = "20, 290"
    $grpLang.Size = "620, 215"
    $grpLang.ForeColor = [System.Drawing.Color]::PaleGoldenrod
    $tabBasic.Controls.Add($grpLang)

    $chkInteractiveLang = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveLang.Text = "Seleccionar la configuracion de idioma de forma interactiva durante la instalacion de Windows"
    $chkInteractiveLang.Location = "20, 25"
    $chkInteractiveLang.AutoSize = $true
    $chkInteractiveLang.Checked = $true
    $chkInteractiveLang.ForeColor = [System.Drawing.Color]::Yellow
    $grpLang.Controls.Add($chkInteractiveLang)

    # Sub-Bloque 1: Idioma UI
    $lblLangH1 = New-Object System.Windows.Forms.Label
    $lblLangH1.Text = "Instale Windows utilizando esta configuracion de idioma:"
    $lblLangH1.Location = "20, 55"
    $lblLangH1.AutoSize = $true
    $lblLangH1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grpLang.Controls.Add($lblLangH1)

    $lblSetupLang = New-Object System.Windows.Forms.Label
    $lblSetupLang.Text = "Idioma de visualizacion de Windows:"
    $lblSetupLang.Location = "20, 80"
    $lblSetupLang.AutoSize = $true
    $grpLang.Controls.Add($lblSetupLang)

    $cmbSetupLang = New-Object System.Windows.Forms.ComboBox
    $cmbSetupLang.Location = "240, 78"
    $cmbSetupLang.Size = "220, 23"
    $cmbSetupLang.DropDownStyle = "DropDownList"
    $cmbSetupLang.Items.AddRange(@("en-US (English - United States)", "es-ES (Spanish - Spain)", "es-MX (Spanish - Mexico)"))
    $cmbSetupLang.SelectedIndex = 0
    $cmbSetupLang.Enabled = $false
    $grpLang.Controls.Add($cmbSetupLang)

    # Sub-Bloque 2: Región y Teclado
    $lblLangH2 = New-Object System.Windows.Forms.Label
    $lblLangH2.Text = "Especifique el primer idioma y la distribucion del teclado:"
    $lblLangH2.Location = "20, 115"
    $lblLangH2.AutoSize = $true
    $lblLangH2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $grpLang.Controls.Add($lblLangH2)

    $lblSysLang = New-Object System.Windows.Forms.Label
    $lblSysLang.Text = "Idioma:"
    $lblSysLang.Location = "20, 140"
    $lblSysLang.AutoSize = $true
    $grpLang.Controls.Add($lblSysLang)

    $cmbSysLang = New-Object System.Windows.Forms.ComboBox
    $cmbSysLang.Location = "80, 138"
    $cmbSysLang.Size = "220, 23"
    $cmbSysLang.DropDownStyle = "DropDownList"
    $cmbSysLang.Items.AddRange(@("en-US (English - United States)", "es-ES (Spanish - Spain)", "es-MX (Spanish - Mexico)"))
    $cmbSysLang.SelectedIndex = 0
    $cmbSysLang.Enabled = $false
    $grpLang.Controls.Add($cmbSysLang)

    $lblKeyboard = New-Object System.Windows.Forms.Label
    $lblKeyboard.Text = "Distribucion del teclado / Editor de metodos de entrada:"
    $lblKeyboard.Location = "20, 175"
    $lblKeyboard.AutoSize = $true
    $grpLang.Controls.Add($lblKeyboard)

    $cmbKeyboard = New-Object System.Windows.Forms.ComboBox
    $cmbKeyboard.Location = "330, 173"
    $cmbKeyboard.Size = "260, 23"
    $cmbKeyboard.DropDownStyle = "DropDownList"
    $cmbKeyboard.Items.AddRange(@(
        "0409:00000409 (US)",
        "0409:00020409 (United States-International)", 
        "040A:0000040A (Spanish)", 
        "080A:0000080A (Latin America)"
    ))
    $cmbKeyboard.SelectedIndex = 1
    $cmbKeyboard.Enabled = $false
    $grpLang.Controls.Add($cmbKeyboard)

    # Lógica de Interacción Idioma
    $chkInteractiveLang.Add_CheckedChanged({
        if ($chkInteractiveLang.Checked) {
            $cmbSetupLang.Enabled = $false
            $cmbSysLang.Enabled = $false
            $cmbKeyboard.Enabled = $false
        } else {
            $cmbSetupLang.Enabled = $true
            $cmbSysLang.Enabled = $true
            $cmbKeyboard.Enabled = $true
        }
    })

    # --- GRUPO TWEAKS ---
    $grpTweaks = New-Object System.Windows.Forms.GroupBox
    $grpTweaks.Text = " Optimizacion, Visual y Privacidad "
    $grpTweaks.Location = "20, 515"
    $grpTweaks.Size = "620, 220"
    $grpTweaks.ForeColor = [System.Drawing.Color]::Orange
    $tabBasic.Controls.Add($grpTweaks)

    $chkVisuals = New-Object System.Windows.Forms.CheckBox
    $chkVisuals.Text = "Estilo Win10: Barra Izquierda + Menu Contextual Clasico"
    $chkVisuals.Location = "20, 30"
    $chkVisuals.AutoSize = $true
    $chkVisuals.Checked = $true
    $grpTweaks.Controls.Add($chkVisuals)

    $chkExt = New-Object System.Windows.Forms.CheckBox
    $chkExt.Text = "Explorador: Mostrar Extensiones y Rutas Largas"
    $chkExt.Location = "20, 60"
    $chkExt.AutoSize = $true
    $chkExt.Checked = $true
    $grpTweaks.Controls.Add($chkExt)
    
    $chkBloat = New-Object System.Windows.Forms.CheckBox
    $chkBloat.Text = "Debloat: Desactivar Copilot, Widgets y Sugerencias"
    $chkBloat.Location = "20, 90"
    $chkBloat.AutoSize = $true
    $chkBloat.Checked = $true
    $grpTweaks.Controls.Add($chkBloat)

    $chkHidePS = New-Object System.Windows.Forms.CheckBox
    $chkHidePS.Text = "Ocultar cualquier ventana de PowerShell durante la instalacion"
    $chkHidePS.Location = "20, 120"
    $chkHidePS.AutoSize = $true
    $chkHidePS.Checked = $true
    $grpTweaks.Controls.Add($chkHidePS)

    $chkCtt = New-Object System.Windows.Forms.CheckBox
    $chkCtt.Text = "Extra: Anadir Menu Clic Derecho 'Optimizar Sistema' (ChrisTitus)"
    $chkCtt.Location = "20, 150"
    $chkCtt.AutoSize = $true
    $chkCtt.Checked = $true
    $chkCtt.ForeColor = [System.Drawing.Color]::LightGreen
    $grpTweaks.Controls.Add($chkCtt)

    $chkTelemetry = New-Object System.Windows.Forms.CheckBox
    $chkTelemetry.Text = "Privacidad: Desactivar Telemetria Total (DiagTrack y Rastreo MS)"
    $chkTelemetry.Location = "20, 180"
    $chkTelemetry.AutoSize = $true
    $chkTelemetry.Checked = $true
    $chkTelemetry.ForeColor = [System.Drawing.Color]::LightCoral
    $grpTweaks.Controls.Add($chkTelemetry)

    $btnGen = New-Object System.Windows.Forms.Button
    $btnGen.Text = "GENERAR E INYECTAR XML"
    $btnGen.Location = "180, 745" # Boton movido hacia abajo
    $btnGen.Size = "300, 45"
    $btnGen.BackColor = [System.Drawing.Color]::SeaGreen
    $btnGen.ForeColor = [System.Drawing.Color]::White
    $btnGen.FlatStyle = "Flat"
    $btnGen.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $tabBasic.Controls.Add($btnGen)

    # =========================================================
    # PESTANA 2: IMPORTAR
    # =========================================================
    $tabImport = New-Object System.Windows.Forms.TabPage
    $tabImport.Text = " Importar Externo "
    $tabImport.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $tabControl.TabPages.Add($tabImport)
    
    $lblImp = New-Object System.Windows.Forms.Label
    $lblImp.Text = "Selecciona un XML existente:"
    $lblImp.Location="20,20"
    $lblImp.AutoSize=$true
    $tabImport.Controls.Add($lblImp)

    $txtImpPath = New-Object System.Windows.Forms.TextBox
    $txtImpPath.Location="20,50"
    $txtImpPath.Size="500,23"
    $tabImport.Controls.Add($txtImpPath)

    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text="..."
    $btnBrowse.Location="530,48"
    $btnBrowse.Size="40,25"
    $tabImport.Controls.Add($btnBrowse)
    
    # Enlace Web
    $lnkWeb = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text = "Generador Online Recomendado (schneegans.de)"
    $lnkWeb.Location = "20, 85"
    $lnkWeb.AutoSize = $true
    $lnkWeb.LinkColor = [System.Drawing.Color]::Yellow
    $tabImport.Controls.Add($lnkWeb)
    
    # Estado Validacion
    $lblValid = New-Object System.Windows.Forms.Label
    $lblValid.Text = "Estado: Esperando archivo..."
    $lblValid.Location = "20, 120"
    $lblValid.AutoSize=$true
    $lblValid.ForeColor = [System.Drawing.Color]::Silver
    $tabImport.Controls.Add($lblValid)

    $btnInjectImp = New-Object System.Windows.Forms.Button
    $btnInjectImp.Text="VALIDAR E INYECTAR"
    $btnInjectImp.Location="150,160"
    $btnInjectImp.Size="200,40"
    $btnInjectImp.BackColor=[System.Drawing.Color]::Orange
    $btnInjectImp.Enabled=$false
    $tabImport.Controls.Add($btnInjectImp)

    # --- LOGICA DE GENERACION ---
    $InjectXmlLogic = {
        param($Content, $Desc)
        
        # 1. Inyectar en el WIM (Para la fase OOBE/Specialize)
        $pantherDir = Join-Path $Script:MOUNT_DIR "Windows\Panther"
        if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
        $destFile = Join-Path $pantherDir "unattend.xml"
        
        try {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText($destFile, $Content, $utf8NoBom)
            
            # 2. Ofrecer guardar una copia para la raíz del USB/ISO (Para la fase WinPE/Idioma)
            $msg = "El archivo se inyecto en el WIM (Windows\Panther\unattend.xml) para la fase de configuración OOBE.`n`n"
            $msg += "Sin embargo, para que funcionen la Seleccion de Idioma inicial y los Bypasses de TPM, "
            $msg += "DEBES colocar una copia de este archivo en la RAIZ de tu USB/ISO bajo el nombre 'autounattend.xml'.`n`n"
            $msg += "¿Deseas guardar una copia en tu PC ahora mismo?"

            $res = [System.Windows.Forms.MessageBox]::Show($msg, "Inyección Parcial Exitosa", 'YesNo', 'Information')
            
            if ($res -eq 'Yes') {
                $sfd = New-Object System.Windows.Forms.SaveFileDialog
                $sfd.Filter = "Archivo Autounattend (*.xml)|*.xml"
                $sfd.FileName = "autounattend.xml"
                $sfd.Title = "Guardar copia para la raiz del USB/ISO"
                
                if ($sfd.ShowDialog() -eq 'OK') {
                    [System.IO.File]::WriteAllText($sfd.FileName, $Content, $utf8NoBom)
                    [System.Windows.Forms.MessageBox]::Show("Copia guardada en:`n$($sfd.FileName)", "Exito", 'OK', 'Information')
                }
            }
            $form.Close()
        } catch { 
            [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", 'OK', 'Error') 
        }
    }

    $btnGen.Add_Click({
        # 1. Fase windowsPE (Bypass Requisitos, Idiomas y Teclado)
        $wpeRunSync = New-Object System.Collections.Generic.List[string]
        $wpeOrder = 1

        if ($chkBypass.Checked) {
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
        }

        $wpeSetupBlock = ""
        if ($wpeRunSync.Count -gt 0) {
            $wpeSetupBlock = @"
        <component name="Microsoft-Windows-Setup" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                $($wpeRunSync -join "`n                ")
            </RunSynchronous>
            <UserData>
                <ProductKey><Key>00000-00000-00000-00000-00000</Key><WillShowUI>OnError</WillShowUI></ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
"@
        }

        # Procesamiento de Componente Internacional/Idioma (Solo si NO es interactivo)
        $wpeIntlBlock = ""
        if (-not $chkInteractiveLang.Checked) {
            $sLang = ($cmbSetupLang.Text -split ' ')[0]
            $sysL = ($cmbSysLang.Text -split ' ')[0]
            $kL = ($cmbKeyboard.Text -split ' ')[0]

            $wpeIntlBlock = @"
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>$sLang</UILanguage>
            </SetupUILanguage>
            <InputLocale>$kL</InputLocale>
            <SystemLocale>$sysL</SystemLocale>
            <UILanguage>$sysL</UILanguage>
            <UserLocale>$sysL</UserLocale>
        </component>
"@
        }

        # Ensamblar windowsPE
        $wpeBlock = ""
        if ($wpeSetupBlock -ne "" -or $wpeIntlBlock -ne "") {
            $wpeBlock = @"
    <settings pass="windowsPE">
$wpeIntlBlock
$wpeSetupBlock
    </settings>
"@
        }

        # 2. Fase specialize (BypassNRO - Sin Internet)
        $specializeBlock = ""
        if ($chkNRO.Checked) {
            $specializeBlock = @"
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
"@
        }

        # 3. Fase oobeSystem (Usuario, Omitir WiFi y Tweaks)
        
        # A. Comandos de Logueo (FirstLogon)
        $cmds = New-Object System.Collections.Generic.List[string]
        $order = 1
        $psPrefix = "powershell.exe -NoProfile -Command"
        if ($chkHidePS.Checked) { $psPrefix = "powershell.exe -WindowStyle Hidden -NoProfile -Command" }

        if ($chkTelemetry.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection"" /v AllowTelemetry /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Services\DiagTrack"" /v Start /t REG_DWORD /d 4 /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Services\dmwappushservice"" /v Start /t REG_DWORD /d 4 /f</CommandLine></SynchronousCommand>"); $order++
        }

        if ($chkCtt.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema"" /v ""MUIVerb"" /t REG_SZ /d ""Optimizar el sistema"" /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema"" /v ""icon"" /t REG_SZ /d ""powershell.exe"" /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema\command"" /ve /t REG_SZ /d ""$psPrefix Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command irm christitus.com/win | iex' -Verb RunAs"" /f</CommandLine></SynchronousCommand>"); $order++
        }

        if ($chkVisuals.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"" /v TaskbarAl /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"" /ve /f</CommandLine></SynchronousCommand>"); $order++
        }

        if ($chkExt.Checked) {
             $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"" /v HideFileExt /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>"); $order++
             $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SYSTEM\CurrentControlSet\Control\FileSystem"" /v LongPathsEnabled /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>"); $order++
        }

        if ($chkBloat.Checked) {
             $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKCU\Software\Policies\Microsoft\Windows\WindowsCopilot"" /v TurnOffWindowsCopilot /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>"); $order++
             $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Dsh"" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f</CommandLine></SynchronousCommand>"); $order++
             $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent"" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f</CommandLine></SynchronousCommand>"); $order++
        }

        $logonCommandsBlock = ""
        if ($cmds.Count -gt 0) {
            $logonCommandsBlock = "<FirstLogonCommands>`n" + ($cmds -join "`n") + "`n            </FirstLogonCommands>"
        }

        # B. Inteligencia de Cuentas (Interactivo vs Automatico)
        $userAccountsBlock = ""
        $isInteractive = $chkInteractiveUser.Checked -or [string]::IsNullOrWhiteSpace($txtUser.Text)
        $hideWifiXmlVal = if ($chkHideWifi.Checked) { "true" } else { "false" }

        if ($isInteractive) {
            $hideLocal = "false"
        } else {
            $hideLocal = "true"
            $userAccountsBlock = @"
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Password>
                            <Value>$($txtPass.Text)</Value>
                            <PlainText>true</PlainText>
                        </Password>
                        <Description>Admin Local</Description>
                        <DisplayName>$($txtUser.Text)</DisplayName>
                        <Group>Administrators</Group>
                        <Name>$($txtUser.Text)</Name>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
                <Password>
                    <Value>$($txtPass.Text)</Value>
                    <PlainText>true</PlainText>
                </Password>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Username>$($txtUser.Text)</Username>
            </AutoLogon>
"@
        }

        # 4. Ensamblar XML Final
        $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    $wpeBlock
    $specializeBlock
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            $userAccountsBlock
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>$hideLocal</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>$hideWifiXmlVal</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
            </OOBE>
            $logonCommandsBlock
        </component>
    </settings>
</unattend>
"@
        & $InjectXmlLogic -Content $xmlContent -Desc "XML Generado Localmente"
    })

    # Eventos de Importacion
    $lnkWeb.Add_Click({ Start-Process "https://schneegans.de/windows/unattend-generator/" })
    
    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "XML (*.xml)|*.xml"
        if($ofd.ShowDialog() -eq 'OK'){ 
            $txtImpPath.Text = $ofd.FileName 
            try {
                $check = [xml](Get-Content $ofd.FileName)
                if ($check.unattend) {
                    $lblValid.Text = "XML Valido detectado."
                    $lblValid.ForeColor = [System.Drawing.Color]::LightGreen
                    $btnInjectImp.Enabled=$true
                } else { throw }
            } catch {
                $lblValid.Text = "Archivo invalido."
                $lblValid.ForeColor = [System.Drawing.Color]::Salmon
                $btnInjectImp.Enabled=$false
            }
        }
    })
    $btnInjectImp.Add_Click({
        if(Test-Path $txtImpPath.Text){ & $InjectXmlLogic -Content (Get-Content $txtImpPath.Text -Raw) -Desc "XML Importado" }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  Modulo GUI: OEM Branding
# =================================================================
function Show-OEMBranding-GUI {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "OEM Branding - Personalizacion Universal"
    $form.Size = New-Object System.Drawing.Size(600, 560)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Inyeccion de Branding y Propiedades del Sistema"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"
	$lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- GRUPO 1: IMAGENES Y FONDOS ---
    $grpImages = New-Object System.Windows.Forms.GroupBox
    $grpImages.Text = " Politicas de Imagen (Fondos) "
    $grpImages.Location = "20, 50"
    $grpImages.Size = "540, 140"
    $grpImages.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpImages)

    $lblWall = New-Object System.Windows.Forms.Label
    $lblWall.Text = "Fondo de Escritorio (JPG/PNG):"
    $lblWall.Location = "15, 30"
	$lblWall.AutoSize = $true
	$lblWall.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblWall)

    $txtWall = New-Object System.Windows.Forms.TextBox
    $txtWall.Location = "15, 50"
	$txtWall.Size = "420, 23"
    $txtWall.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$txtWall.ForeColor = [System.Drawing.Color]::White
    $txtWall.ReadOnly = $true
    $grpImages.Controls.Add($txtWall)

    $btnWall = New-Object System.Windows.Forms.Button
    $btnWall.Text = "Examinar..."
    $btnWall.Location = "445, 48"
	$btnWall.Size = "80, 26"
    $btnWall.BackColor = [System.Drawing.Color]::Gray
	$btnWall.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnWall)

    $lblLock = New-Object System.Windows.Forms.Label
    $lblLock.Text = "Pantalla de Bloqueo (Opcional):"
    $lblLock.Location = "15, 80"
	$lblLock.AutoSize = $true; $lblLock.ForeColor = [System.Drawing.Color]::White
    $grpImages.Controls.Add($lblLock)

    $txtLock = New-Object System.Windows.Forms.TextBox
    $txtLock.Location = "15, 100"
	$txtLock.Size = "420, 23"
    $txtLock.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$txtLock.ForeColor = [System.Drawing.Color]::White
    $txtLock.ReadOnly = $true
    $grpImages.Controls.Add($txtLock)

    $btnLock = New-Object System.Windows.Forms.Button
    $btnLock.Text = "Examinar..."
    $btnLock.Location = "445, 98"; $btnLock.Size = "80, 26"
    $btnLock.BackColor = [System.Drawing.Color]::Gray
	$btnLock.FlatStyle = "Flat"
    $grpImages.Controls.Add($btnLock)

    # --- GRUPO 2: INFORMACION OEM (PROPIEDADES DEL SISTEMA) ---
    $grpOem = New-Object System.Windows.Forms.GroupBox
    $grpOem.Text = " Informacion del Ensamblador (OEM) "
    $grpOem.Location = "20, 200"
    $grpOem.Size = "540, 230"
    $grpOem.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpOem)

    # Fila 1: Fabricante y Modelo
    $lblFab = New-Object System.Windows.Forms.Label
    $lblFab.Text = "Fabricante:"
	$lblFab.Location = "15, 30"
	$lblFab.AutoSize = $true
	$lblFab.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblFab)
    $txtFab = New-Object System.Windows.Forms.TextBox
    $txtFab.Location = "90, 27"
	$txtFab.Size = "160, 23"
    $grpOem.Controls.Add($txtFab)

    $lblMod = New-Object System.Windows.Forms.Label
    $lblMod.Text = "Modelo:"
	$lblMod.Location = "270, 30"
	$lblMod.AutoSize = $true
	$lblMod.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblMod)
    $txtMod = New-Object System.Windows.Forms.TextBox
    $txtMod.Location = "330, 27"
	$txtMod.Size = "195, 23"
    $grpOem.Controls.Add($txtMod)

    # Fila 2: URL de Soporte
    $lblUrl = New-Object System.Windows.Forms.Label
    $lblUrl.Text = "URL Web:"
	$lblUrl.Location = "15, 70"
	$lblUrl.AutoSize = $true
	$lblUrl.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblUrl)
    $txtUrl = New-Object System.Windows.Forms.TextBox
    $txtUrl.Location = "90, 67"
	$txtUrl.Size = "435, 23"
    $grpOem.Controls.Add($txtUrl)

    # Fila 3 Teléfono y Horario
    $lblPhone = New-Object System.Windows.Forms.Label
    $lblPhone.Text = "Telefono:"
	$lblPhone.Location = "15, 110"
	$lblPhone.AutoSize = $true
	$lblPhone.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblPhone)
    $txtPhone = New-Object System.Windows.Forms.TextBox
    $txtPhone.Location = "90, 107"
	$txtPhone.Size = "160, 23"
    $grpOem.Controls.Add($txtPhone)

    $lblHours = New-Object System.Windows.Forms.Label
    $lblHours.Text = "Horario:"
	$lblHours.Location = "270, 110"
	$lblHours.AutoSize = $true
	$lblHours.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblHours)
    $txtHours = New-Object System.Windows.Forms.TextBox
    $txtHours.Location = "330, 107"
	$txtHours.Size = "195, 23"
    $grpOem.Controls.Add($txtHours)

    # Fila 4: Logo
    $lblLogo = New-Object System.Windows.Forms.Label
    $lblLogo.Text = "Logo OEM (Obligatorio formato .BMP, ideal 120x120px):"
    $lblLogo.Location = "15, 150"
	$lblLogo.AutoSize = $true; $lblLogo.ForeColor = [System.Drawing.Color]::White
    $grpOem.Controls.Add($lblLogo)

    $txtLogo = New-Object System.Windows.Forms.TextBox
    $txtLogo.Location = "15, 170"
	$txtLogo.Size = "420, 23"
    $txtLogo.BackColor = [System.Drawing.Color]::FromArgb(50,50,50); $txtLogo.ForeColor = [System.Drawing.Color]::White
    $txtLogo.ReadOnly = $true
    $grpOem.Controls.Add($txtLogo)

    $btnLogo = New-Object System.Windows.Forms.Button
    $btnLogo.Text = "Examinar..."
    $btnLogo.Location = "445, 168"
	$btnLogo.Size = "80, 26"
    $btnLogo.BackColor = [System.Drawing.Color]::Gray
	$btnLogo.FlatStyle = "Flat"
    $grpOem.Controls.Add($btnLogo)

    # --- BOTON DE APLICACION ---
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "APLICAR BRANDING A LA IMAGEN"
    $btnApply.Location = "120, 450"
	$btnApply.Size = "340, 45"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnApply)

    # --- EVENTOS DE EXAMINAR ---
    $btnWall.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') { $txtWall.Text = $ofd.FileName }
    })
    $btnLock.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "Imagenes (*.jpg;*.jpeg;*.png)|*.jpg;*.jpeg;*.png"
        if ($ofd.ShowDialog() -eq 'OK') { $txtLock.Text = $ofd.FileName }
    })
    $btnLogo.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "Imagen Bitmap (*.bmp)|*.bmp"
        if ($ofd.ShowDialog() -eq 'OK') { $txtLogo.Text = $ofd.FileName }
    })

    # --- LOGICA DE APLICACION ---
    $btnApply.Add_Click({
        if (-not $txtWall.Text -and -not $txtFab.Text -and -not $txtLock.Text) { 
            Write-Log -LogLevel WARN -Message "OEM_Branding: El usuario intento aplicar sin seleccionar imagenes o metadatos. Abortando."
            [System.Windows.Forms.MessageBox]::Show("Selecciona al menos un fondo o configura los datos del fabricante.", "Aviso", 'OK', 'Warning')
            return 
        }
        
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled = $false

        Write-Log -LogLevel ACTION -Message "OEM_Branding: Iniciando motor de inyeccion de Branding y Metadatos OEM."

        try {
            Write-Log -LogLevel INFO -Message "OEM_Branding: Solicitando montaje de colmenas de registro (Mount-Hives)..."
            if (-not (Mount-Hives)) { throw "No se pudieron cargar los hives del registro." }
            
            try {
                # 1. AUTO-DETECCION DE EDICION
                $editionId = "Desconocida"
                $regCurrentVer = "HKLM:\OfflineSoftware\Microsoft\Windows NT\CurrentVersion"
                $editionData = Get-ItemProperty -Path $regCurrentVer -Name "EditionID" -ErrorAction SilentlyContinue
                if ($editionData) { $editionId = $editionData.EditionID }

                $isGpoSupported = ($editionId -match "Enterprise|Education|Server")
                Write-Log -LogLevel INFO -Message "OEM_Branding: Inteligencia de Edicion -> [$editionId]. Soporte GPO: $isGpoSupported"

                Enable-Privileges

                # 2. PROCESAMIENTO DE FONDOS
                if ($txtWall.Text -or $txtLock.Text) {
                    if ($isGpoSupported) {
                        # --- METODO 1: GPO (Enterprise / Education / Server) ---
                        Write-Log -LogLevel ACTION -Message "OEM_Branding: Iniciando inyeccion de fondos usando Metodo 1 (Directivas GPO)."
                        
                        $oemDir = Join-Path $Script:MOUNT_DIR "Windows\Web\Wallpaper\OEM"
                        if (-not (Test-Path $oemDir)) { New-Item -Path $oemDir -ItemType Directory -Force | Out-Null }
                        
                        $polPath = "OfflineSoftware\Policies\Microsoft\Windows\Personalization"
                        Unlock-Single-Key -SubKeyPath $polPath
                        
                        $psPolPath = "HKLM:\$polPath"
                        if (-not (Test-Path $psPolPath)) { New-Item -Path $psPolPath -Force | Out-Null }

                        if ($txtWall.Text) {
                            Write-Log -LogLevel INFO -Message "OEM_Branding: Procesando Fondo (GPO) -> $($txtWall.Text)"
                            $ext = [System.IO.Path]::GetExtension($txtWall.Text)
                            $destFile = Join-Path $oemDir "Fondo_OEM$ext"
                            Copy-Item -Path $txtWall.Text -Destination $destFile -Force
                            Set-ItemProperty -Path $psPolPath -Name "DesktopImage" -Value "C:\Windows\Web\Wallpaper\OEM\Fondo_OEM$ext" -Type String -Force
                        }
                        if ($txtLock.Text) {
                            Write-Log -LogLevel INFO -Message "OEM_Branding: Procesando LockScreen (GPO) -> $($txtLock.Text)"
                            $ext = [System.IO.Path]::GetExtension($txtLock.Text)
                            $destFile = Join-Path $oemDir "Lock_OEM$ext"
                            Copy-Item -Path $txtLock.Text -Destination $destFile -Force
                            Set-ItemProperty -Path $psPolPath -Name "LockScreenImage" -Value "C:\Windows\Web\Wallpaper\OEM\Lock_OEM$ext" -Type String -Force
                        }

                        Restore-KeyOwner -KeyPath $psPolPath
                    } 
                    else {
                        # --- METODO 2: THEMES OVERRIDE Y CSP (Home / Pro / Core) ---
                        Write-Log -LogLevel ACTION -Message "OEM_Branding: Iniciando inyeccion de fondos usando Metodo 2 (Themes Override & CSP)."
                        
                        $oemDir = Join-Path $Script:MOUNT_DIR "Windows\Web\Wallpaper\OEM"
                        if (-not (Test-Path $oemDir)) { New-Item -Path $oemDir -ItemType Directory -Force | Out-Null }

                        # A. Procesamiento del Fondo de Escritorio (Vía .theme)
                        if ($txtWall.Text) {
                            Write-Log -LogLevel INFO -Message "OEM_Branding: Procesando Fondo (.theme) -> $($txtWall.Text)"
                            $ext = [System.IO.Path]::GetExtension($txtWall.Text)
                            $destWall = Join-Path $oemDir "Fondo_OEM$ext"
                            Copy-Item -Path $txtWall.Text -Destination $destWall -Force

                            # Generar archivo de Tema (.theme) completo
                            $themeContent = @"
; Copyright (c) Microsoft Corp. / OEM Modified

[Theme]
DisplayName=OEM Custom Theme
SetLogonBackground=0

; Computer
[CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}\DefaultIcon]
DefaultValue=%SystemRoot%\System32\imageres.dll,-109

; UsersFiles
[CLSID\{59031A47-3F72-44A7-89C5-5595FE6B30EE}\DefaultIcon]
DefaultValue=%SystemRoot%\System32\imageres.dll,-123

; Network
[CLSID\{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}\DefaultIcon]
DefaultValue=%SystemRoot%\System32\imageres.dll,-25

; Recycle Bin
[CLSID\{645FF040-5081-101B-9F08-00AA002F954E}\DefaultIcon]
Full=%SystemRoot%\System32\imageres.dll,-54
Empty=%SystemRoot%\System32\imageres.dll,-55

[Control Panel\Cursors]
AppStarting=%SystemRoot%\cursors\aero_working.ani
Arrow=%SystemRoot%\cursors\aero_arrow.cur
Crosshair=
Hand=%SystemRoot%\cursors\aero_link.cur
Help=%SystemRoot%\cursors\aero_helpsel.cur
IBeam=
No=%SystemRoot%\cursors\aero_unavail.cur
NWPen=%SystemRoot%\cursors\aero_pen.cur
SizeAll=%SystemRoot%\cursors\aero_move.cur
SizeNESW=%SystemRoot%\cursors\aero_nesw.cur
SizeNS=%SystemRoot%\cursors\aero_ns.cur
SizeNWSE=%SystemRoot%\cursors\aero_nwse.cur
SizeWE=%SystemRoot%\cursors\aero_ew.cur
UpArrow=%SystemRoot%\cursors\aero_up.cur
Wait=%SystemRoot%\cursors\aero_busy.ani
DefaultValue=Windows Default
DefaultValue.MUI=@main.cpl,-1020

[Control Panel\Desktop]
Wallpaper=C:\Windows\Web\Wallpaper\OEM\Fondo_OEM$ext
TileWallpaper=0
WallpaperStyle=10
Pattern=

[VisualStyles]
Path=%ResourceDir%\Themes\Aero\Aero.msstyles
ColorStyle=NormalColor
Size=NormalSize
AutoColorization=0
ColorizationColor=0XC40078D4
SystemMode=Dark
AppMode=Dark

[boot]
SCRNSAVE.EXE=

[MasterThemeSelector]
MTSM=RJSPBS

[Sounds]
SchemeName=@%SystemRoot%\System32\mmres.dll,-800
"@
                            $themeDir = Join-Path $Script:MOUNT_DIR "Windows\Resources\Themes"
                            if (-not (Test-Path $themeDir)) { New-Item -Path $themeDir -ItemType Directory -Force | Out-Null }
                            
                            $themeFile = Join-Path $themeDir "oem.theme"
                            
                            # Escribir UTF-8 Puro sin BOM usando .NET
                            Write-Log -LogLevel INFO -Message "OEM_Branding: Escribiendo archivo oem.theme puro (sin BOM)."
                            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                            [System.IO.File]::WriteAllText($themeFile, $themeContent, $utf8NoBom)

                            # Inyectar el tema como predeterminado en el registro
                            $themeRegPath = "OfflineSoftware\Microsoft\Windows\CurrentVersion\Themes"
                            Unlock-OfflineKey -KeyPath $themeRegPath
                            if (-not (Test-Path "HKLM:\$themeRegPath")) { New-Item -Path "HKLM:\$themeRegPath" -Force | Out-Null }
                            
                            Set-ItemProperty -Path "HKLM:\$themeRegPath" -Name "InstallTheme" -Value "%SystemRoot%\Resources\Themes\oem.theme" -Type String -Force
                            Restore-KeyOwner -KeyPath "HKLM:\$themeRegPath"
                        }

                        # B. Procesamiento de la Pantalla de Bloqueo (Vía PersonalizationCSP)
                        if ($txtLock.Text) {
                            Write-Log -LogLevel INFO -Message "OEM_Branding: Procesando LockScreen (CSP) -> $($txtLock.Text)"
                            $ext = [System.IO.Path]::GetExtension($txtLock.Text)
                            $destLock = Join-Path $oemDir "Lock_OEM$ext"
                            Copy-Item -Path $txtLock.Text -Destination $destLock -Force

                            # Inyectar LockScreen usando el proveedor CSP
                            $cspRegPath = "OfflineSoftware\Microsoft\Windows\CurrentVersion\PersonalizationCSP"
                            Unlock-Single-Key -SubKeyPath $cspRegPath
                            if (-not (Test-Path "HKLM:\$cspRegPath")) { New-Item -Path "HKLM:\$cspRegPath" -Force | Out-Null }

                            $internalLockPath = "C:\Windows\Web\Wallpaper\OEM\Lock_OEM$ext"
                            Set-ItemProperty -Path "HKLM:\$cspRegPath" -Name "LockScreenImagePath" -Value $internalLockPath -Type String -Force
                            Set-ItemProperty -Path "HKLM:\$cspRegPath" -Name "LockScreenImageUrl" -Value $internalLockPath -Type String -Force
                            Set-ItemProperty -Path "HKLM:\$cspRegPath" -Name "LockScreenImageStatus" -Value 1 -Type DWord -Force
                            
                            Restore-KeyOwner -KeyPath "HKLM:\$cspRegPath"
                        }
                    }
                }

                # 3. METADATOS OEM CON GESTION DE CLAVES PROPIA
                if ($txtFab.Text -or $txtMod.Text -or $txtLogo.Text -or $txtPhone.Text -or $txtHours.Text -or $txtUrl.Text) {
                    Write-Log -LogLevel ACTION -Message "OEM_Branding: Inyectando metadatos de informacion del fabricante (OEMInformation)."
                    $infoSubPath = "OfflineSoftware\Microsoft\Windows\CurrentVersion\OEMInformation"
                    Unlock-Single-Key -SubKeyPath $infoSubPath
                    
                    $psInfoPath = "HKLM:\$infoSubPath"
                    if (-not (Test-Path $psInfoPath)) { New-Item -Path $psInfoPath -Force | Out-Null }

                    if ($txtFab.Text)   { Set-ItemProperty -Path $psInfoPath -Name "Manufacturer" -Value $txtFab.Text -Type String -Force }
                    if ($txtMod.Text)   { Set-ItemProperty -Path $psInfoPath -Name "Model"        -Value $txtMod.Text -Type String -Force }
                    if ($txtUrl.Text)   { Set-ItemProperty -Path $psInfoPath -Name "SupportURL"   -Value $txtUrl.Text -Type String -Force }
                    if ($txtPhone.Text) { Set-ItemProperty -Path $psInfoPath -Name "SupportPhone" -Value $txtPhone.Text -Type String -Force }
                    if ($txtHours.Text) { Set-ItemProperty -Path $psInfoPath -Name "SupportHours" -Value $txtHours.Text -Type String -Force }
                    
                    if ($txtLogo.Text) { 
                        Write-Log -LogLevel INFO -Message "OEM_Branding: Procesando Logo OEM -> $($txtLogo.Text)"
                        $oemInfoDir = Join-Path $Script:MOUNT_DIR "Windows\System32\oem"
                        if (-not (Test-Path $oemInfoDir)) { New-Item -Path $oemInfoDir -ItemType Directory -Force | Out-Null }
                        $destFile = Join-Path $oemInfoDir "oemlogo.bmp"
                        Copy-Item -Path $txtLogo.Text -Destination $destFile -Force
                        Set-ItemProperty -Path $psInfoPath -Name "Logo" -Value "C:\Windows\System32\oem\oemlogo.bmp" -Type String -Force 
                    }

                    Restore-KeyOwner -KeyPath $psInfoPath
                }
                
                $msg = "Branding inyectado correctamente.`n`nEdicion detectada: $editionId"
                if ($txtWall.Text -or $txtLock.Text) { $msg += "`nMetodo de aplicacion: $(if($isGpoSupported){'Directiva de Grupo (GPO)'}else{'Themes Override & CSP'})" }
                
                Write-Log -LogLevel INFO -Message "OEM_Branding: Operacion completada con exito."
                [System.Windows.Forms.MessageBox]::Show($msg, "Exito", 'OK', 'Information')
                $form.Close()

            } finally {
                Write-Log -LogLevel INFO -Message "OEM_Branding: Ejecutando limpieza y desmontaje de colmenas de registro..."
                Unmount-Hives
            }
        } catch {
            Write-Log -LogLevel ERROR -Message "OEM_Branding: Fallo critico durante la inyeccion - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Error al aplicar Branding: $_", "Error", 'OK', 'Error')
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnApply.Enabled = $true
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
}

# =================================================================
#  Modulo GUI: Inyector y Actualizador de Apps Modernas
# =================================================================
function Show-AppxInjector-GUI {
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Aprovisionamiento de Apps Modernas (APPX / MSIX) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(850, 580) # Ensanchado para la nueva columna
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    $toolTip = New-Object System.Windows.Forms.ToolTip

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestor Inteligente de Aplicaciones Universales (UWP/WinUI)"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"; $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- VARIABLE GLOBAL PARA CACHE DE APPS ---
    $script:cachedAppx = @()
	$script:detectedLicense = $null

    # --- HELPER INTELIGENTE DE DETECCION ---
    $CheckAppExists = {
        param([string]$FilePath)
        $fileName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        
        # El estandar de Windows usa "_" para separar Nombre, Version y Hash
        $baseName = $fileName.Split('_')[0]
        
        # Buscar coincidencias en la imagen montada
        $match = $script:cachedAppx | Where-Object { $_.DisplayName -match [regex]::Escape($baseName) -or $_.PackageName -match [regex]::Escape($baseName) }
        
        if ($match) {
            return $match[0].Version # Retorna la version instalada actualmente
        }
        return $null
    }

    # --- GRUPO 1: PAQUETE PRINCIPAL ---
    $grpMain = New-Object System.Windows.Forms.GroupBox
    $grpMain.Text = " 1. Paquete Principal (App) "
    $grpMain.Location = "20, 50"
    $grpMain.Size = "790, 90"
    $grpMain.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpMain)

    $lblMain = New-Object System.Windows.Forms.Label
    $lblMain.Text = "Archivo (.appx, .msix, .appxbundle, .msixbundle):"
    $lblMain.Location = "15, 25"; $lblMain.AutoSize = $true; $lblMain.ForeColor = [System.Drawing.Color]::White
    $grpMain.Controls.Add($lblMain)

    $txtMain = New-Object System.Windows.Forms.TextBox
    $txtMain.Location = "15, 45"; $txtMain.Size = "670, 23"
    $txtMain.BackColor = [System.Drawing.Color]::FromArgb(50,50,50); $txtMain.ForeColor = [System.Drawing.Color]::White
    $txtMain.ReadOnly = $true
    $grpMain.Controls.Add($txtMain)

    $btnMain = New-Object System.Windows.Forms.Button
    $btnMain.Text = "Buscar..."
    $btnMain.Location = "695, 43"; $btnMain.Size = "80, 26"
    $btnMain.BackColor = [System.Drawing.Color]::Gray; $btnMain.FlatStyle = "Flat"
    $grpMain.Controls.Add($btnMain)

    # --- GRUPO 2: DEPENDENCIAS ---
    $grpDeps = New-Object System.Windows.Forms.GroupBox
    $grpDeps.Text = " 2. Dependencias (Frameworks, VCLibs, etc.) "
    $grpDeps.Location = "20, 150"
    $grpDeps.Size = "790, 250"
    $grpDeps.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpDeps)

    $lblDepInfo = New-Object System.Windows.Forms.Label
    $lblDepInfo.Text = "Añade las librerias necesarias. El sistema verificara si ya estan integradas."
    $lblDepInfo.Location = "15, 25"; $lblDepInfo.AutoSize = $true; $lblDepInfo.ForeColor = [System.Drawing.Color]::DarkGray
    $grpDeps.Controls.Add($lblDepInfo)

    $lvDeps = New-Object System.Windows.Forms.ListView
    $lvDeps.Location = "15, 50"
    $lvDeps.Size = "760, 140"
    $lvDeps.View = "Details"
    $lvDeps.FullRowSelect = $true
    $lvDeps.GridLines = $true
    $lvDeps.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lvDeps.ForeColor = [System.Drawing.Color]::White
    
    $lvDeps.Columns.Add("Estado / Version Actual", 180) | Out-Null
    $lvDeps.Columns.Add("Archivo de Dependencia", 550) | Out-Null
    $grpDeps.Controls.Add($lvDeps)

    $btnAddDep = New-Object System.Windows.Forms.Button
    $btnAddDep.Text = "+ Agregar Paquetes"
    $btnAddDep.Location = "15, 200"; $btnAddDep.Size = "140, 30"
    $btnAddDep.BackColor = [System.Drawing.Color]::RoyalBlue; $btnAddDep.FlatStyle = "Flat"
    $grpDeps.Controls.Add($btnAddDep)

    $btnRemDep = New-Object System.Windows.Forms.Button
    $btnRemDep.Text = "- Quitar Seleccion"
    $btnRemDep.Location = "165, 200"; $btnRemDep.Size = "130, 30"
    $btnRemDep.BackColor = [System.Drawing.Color]::Crimson; $btnRemDep.FlatStyle = "Flat"
    $grpDeps.Controls.Add($btnRemDep)

    # --- ESTADO Y BOTON ACCION ---
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Iniciando modulo..."
    $lblStatus.Location = "20, 420"; $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "PROCESAR (Inyectar / Actualizar)"
    $btnApply.Location = "240, 470"; $btnApply.Size = "360, 50"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnApply.Enabled = $false
    $form.Controls.Add($btnApply)

    # --- EVENTO DE CARGA INICIAL (Auditoria de la Imagen) ---
    $form.Add_Shown({
        $form.Refresh()
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = "Escaneando paquetes instalados en la imagen... (Esto tomara unos segundos)"
        $form.Refresh()
        
        try {
            $script:cachedAppx = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR -ErrorAction Stop
            $lblStatus.Text = "Escaneo completado. $($script:cachedAppx.Count) apps detectadas. Listo para trabajar."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnApply.Enabled = $true
        } catch {
            $lblStatus.Text = "Advertencia: No se pudieron cargar los paquetes instalados."
            $lblStatus.ForeColor = [System.Drawing.Color]::Salmon
            $btnApply.Enabled = $true # Habilitamos de todas formas
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- EVENTOS DE INTERFAZ ---
    $btnMain.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Paquetes Modernos (*.appx;*.msix;*.appxbundle;*.msixbundle)|*.appx;*.msix;*.appxbundle;*.msixbundle"
        if ($ofd.ShowDialog() -eq 'OK') { 
            $txtMain.Text = $ofd.FileName 
            $baseDir = Split-Path $ofd.FileName -Parent
            
            # --- AUTO-DISCOVERY DE DEPENDENCIAS ---
            $lvDeps.BeginUpdate()
            $lvDeps.Items.Clear() # Limpiamos por si habia algo antes
            
            # Buscar recursivamente todos los paquetes en esa carpeta y subcarpetas
            $autoDeps = Get-ChildItem -Path $baseDir -Include "*.appx", "*.msix" -Recurse -File -ErrorAction SilentlyContinue
            
            $count = 0
            foreach ($dep in $autoDeps) {
                # Evitar meter el paquete principal como dependencia de si mismo
                if ($dep.FullName -ne $ofd.FileName) {
                    $item = New-Object System.Windows.Forms.ListViewItem("AUTO-DETECTADO")
                    $item.ForeColor = [System.Drawing.Color]::Cyan
                    $item.SubItems.Add($dep.Name) | Out-Null
                    $item.Tag = $dep.FullName
                    $lvDeps.Items.Add($item) | Out-Null
                    $count++
                }
            }
            $lvDeps.EndUpdate()

            # --- AUTO-DISCOVERY DE LICENCIA ---
            $script:detectedLicense = $null
            $licFile = Get-ChildItem -Path $baseDir -Filter "*license*.xml" -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($licFile) {
                $script:detectedLicense = $licFile.FullName
            }

            # --- CHEQUEO INTELIGENTE DE ACTUALIZACION ---
            $existingVer = & $CheckAppExists -FilePath $ofd.FileName
            
            $statusStr = ""
            if ($existingVer) {
                $statusStr = "[ACTUALIZAR] (v$existingVer). "
                $lblStatus.ForeColor = [System.Drawing.Color]::Orange
            } else {
                $statusStr = "[NUEVA]. "
                $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
            }

            $statusStr += "Autocargadas $count dependencias."
            if ($script:detectedLicense) { $statusStr += " [Licencia XML OK]" }
            
            $lblStatus.Text = $statusStr
        }
    })

    $btnAddDep.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Paquetes Dependencia (*.appx;*.msix)|*.appx;*.msix"
        $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $lvDeps.BeginUpdate()
            foreach ($file in $ofd.FileNames) {
                
                # Evitar duplicados en la lista visual
                $existsInList = $false
                foreach ($item in $lvDeps.Items) { if ($item.Tag -eq $file) { $existsInList = $true; break } }
                
                if (-not $existsInList) {
                    # Chequeo Inteligente contra la Imagen WIM
                    $existingVer = & $CheckAppExists -FilePath $file
                    
                    $item = New-Object System.Windows.Forms.ListViewItem
                    
                    if ($existingVer) {
                        $item.Text = "YA INSTALADO (v$existingVer)"
                        $item.ForeColor = [System.Drawing.Color]::Orange
                    } else {
                        $item.Text = "NUEVO PAQUETE"
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                    }

                    $item.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                    $item.Tag = $file
                    $lvDeps.Items.Add($item) | Out-Null
                }
            }
            $lvDeps.EndUpdate()
        }
    })

    $btnRemDep.Add_Click({
        foreach ($item in $lvDeps.SelectedItems) { $lvDeps.Items.Remove($item) }
    })

    # --- LOGICA DE APROVISIONAMIENTO (CORE) ---
    $btnApply.Add_Click({
        if (-not $txtMain.Text) {
            [System.Windows.Forms.MessageBox]::Show("Debes seleccionar un paquete principal.", "Aviso", 'OK', 'Warning')
            return
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled = $false
        $btnAddDep.Enabled = $false
        $btnRemDep.Enabled = $false
        $btnMain.Enabled = $false

        $lblStatus.Text = "Inyectando aplicación y dependencias... Por favor espere."
        $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
        $form.Refresh()

        try {
            # Extraer array de rutas de dependencias
            $depPaths = @()
            foreach ($item in $lvDeps.Items) { $depPaths += $item.Tag }

            Write-Log -LogLevel ACTION -Message "Inyectando Appx/MSIX: $($txtMain.Text) con $($depPaths.Count) dependencias."
            
            # Parametros base
            $params = @{
                Path = $Script:MOUNT_DIR
                PackagePath = $txtMain.Text
                ErrorAction = 'Stop'
            }

            if ($depPaths.Count -gt 0) { $params.Add('DependencyPackagePath', $depPaths) }
            
            # Decision de Licencia
            if ($script:detectedLicense) {
                Write-Log -LogLevel INFO -Message "Utilizando archivo de licencia: $($script:detectedLicense)"
                $params.Add('LicensePath', $script:detectedLicense)
            } else {
                Write-Log -LogLevel INFO -Message "Sin licencia. Usando -SkipLicense."
                $params.Add('SkipLicense', $true)
            }

            # Ejecutar inyeccion (Splatting para codigo mas limpio)
            Add-AppxProvisionedPackage @params | Out-Null

            $lblStatus.Text = "Aplicacion inyectada exitosamente."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            [System.Windows.Forms.MessageBox]::Show("La aplicacion fue aprovisionada/actualizada correctamente en la imagen.", "Exito", 'OK', 'Information')
            
            # Limpiar la UI y recargar cache
            $txtMain.Text = ""
            $lvDeps.Items.Clear()
            $script:detectedLicense = $null
            $script:cachedAppx = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue

        } catch {
            $lblStatus.Text = "Error al inyectar paquete."
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "Fallo inyeccion Appx/MSIX: $_"
            [System.Windows.Forms.MessageBox]::Show("Fallo el aprovisionamiento de la aplicacion.`n`nDetalle Técnico: $_", "Error", 'OK', 'Error')
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnApply.Enabled = $true
            $btnAddDep.Enabled = $true
            $btnRemDep.Enabled = $true
            $btnMain.Enabled = $true
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:cachedAppx = $null
    [GC]::Collect()
}

# =================================================================
#  UTILIDADES DE REGISTRO OFFLINE (MOTOR NECESARIO)
# =================================================================
function Mount-Hives {
    Write-Log -LogLevel INFO -Message "HIVES: Iniciando secuencia de montaje inteligente..."
    
    # 1. Rutas fisicas
    $hiveDir = Join-Path $Script:MOUNT_DIR "Windows\System32\config"
    $userDir = Join-Path $Script:MOUNT_DIR "Users\Default"
    
    $sysHive   = Join-Path $hiveDir "SYSTEM"
    $softHive  = Join-Path $hiveDir "SOFTWARE"
    $compHive  = Join-Path $hiveDir "COMPONENTS" # Hive de Componentes (Opcional en Boot)
    $userHive  = Join-Path $userDir "NTUSER.DAT" # Hive de Usuario (No existe en Boot)
    $classHive = Join-Path $userDir "AppData\Local\Microsoft\Windows\UsrClass.dat" # Clases (No existe en Boot)

    # 2. Validacion critica (SYSTEM y SOFTWARE son obligatorios incluso en Boot.wim)
    if (-not (Test-Path $sysHive) -or -not (Test-Path $softHive)) { 
        [System.Windows.Forms.MessageBox]::Show("Error Critico: No se encuentran SYSTEM o SOFTWARE.`nLa imagen esta corrupta o no es valida?", "Error Fatal", 'OK', 'Error')
        return $false 
    }

    # 3. Check preventivo: Si SYSTEM ya esta montado, asumimos que todo esta listo.
    if (Test-Path "Registry::HKLM\OfflineSystem") {
        Write-Log -LogLevel INFO -Message "HIVES: Detectados hives ya montados. Omitiendo carga."
        return $true
    }

    try {
        # --- CARGA OBLIGATORIA (SYSTEM / SOFTWARE) ---
        Write-Host "Cargando SYSTEM..." -NoNewline
        $p1 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSystem `"$sysHive`"" -Wait -PassThru -NoNewWindow
        if ($p1.ExitCode -ne 0) { throw "Fallo SYSTEM" } else { Write-Host "OK" -ForegroundColor Green }

        Write-Host "Cargando SOFTWARE..." -NoNewline
        $p2 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSoftware `"$softHive`"" -Wait -PassThru -NoNewWindow
        if ($p2.ExitCode -ne 0) { throw "Fallo SOFTWARE" } else { Write-Host "OK" -ForegroundColor Green }

        # --- CARGA CONDICIONAL (BOOT / REPARACION) ---

        # COMPONENTS (A veces no existe en WinPE/Boot.wim muy ligeros)
        if (Test-Path $compHive) {
            Write-Host "Cargando COMPONENTS..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineComponents `"$compHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                Write-Log -LogLevel WARN -Message "Fallo al cargar COMPONENTS (ExitCode: $($p.ExitCode))"
            }
        }

        # NTUSER.DAT (No existe en Boot.wim)
        if (Test-Path $userHive) {
            Write-Host "Cargando USER..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUser `"$userHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                Write-Log -LogLevel WARN -Message "Fallo al cargar NTUSER.DAT (ExitCode: $($p.ExitCode))"
            }
        } else {
            Write-Host "USER (Omitido - Modo Boot/WinPE)" -ForegroundColor DarkGray
        }

        # UsrClass.dat (No existe en Boot.wim)
        if (Test-Path $classHive) {
            Write-Host "Cargando CLASSES..." -NoNewline
            $p = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUserClasses `"$classHive`"" -Wait -PassThru -NoNewWindow
            if ($p.ExitCode -eq 0) { 
                Write-Host "OK" -ForegroundColor Green 
            } else { 
                Write-Host "FALLO (Omitido)" -ForegroundColor Red 
                Write-Log -LogLevel WARN -Message "Fallo al cargar UsrClass.dat (ExitCode: $($p.ExitCode))"
            }
        }

        return $true
    } catch {
        Write-Host "`n[FATAL] $_"
        Write-Log -LogLevel ERROR -Message "Fallo Mount-Hives: $_"
        # Intento de limpieza de emergencia
        Unmount-Hives
        return $false
    }
}

function Unmount-Hives {
    Write-Host "Guardando y descargando Hives..." -ForegroundColor Yellow
    
    # Garbage Collection forzada y limpieza de memoria para soltar handles de registro
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    
    # --- Pausa de seguridad para permitir que el kernel libere los archivos fisicos ---
    Write-Host "Esperando a que el sistema libere los manejadores de archivos..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 2 
    
    # Lista ampliada de Hives a descargar
    $hives = @(
        "HKLM\OfflineSystem", 
        "HKLM\OfflineSoftware", 
        "HKLM\OfflineComponents", 
        "HKLM\OfflineUser", 
        "HKLM\OfflineUserClasses"
    )
    
    foreach ($hive in $hives) {
        if (Test-Path "Registry::$hive") {
            $retries = 0; $done = $false
            while ($retries -lt 5 -and -not $done) {
                # Intentamos el desmontaje nativo
                reg unload $hive 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { 
                    $done = $true 
                } else { 
                    $retries++
                    # Pequeña espera incremental entre reintentos si hay bloqueo
                    Write-Host "." -NoNewline -ForegroundColor Yellow
                    Start-Sleep -Milliseconds (500 * $retries) 
                }
            }
            if (-not $done) { 
                Write-Warning "`n [!] No se pudo desmontar $hive. Puede estar bloqueado por un proceso externo."
                Write-Log -LogLevel WARN -Message "Fallo al desmontar $hive tras 5 intentos."
            }
        }
    }
    Write-Host " [Proceso Finalizado]" -ForegroundColor Green
}

function Translate-OfflinePath {
    param([string]$OnlinePath)
    
    # 1. Limpieza inicial y normalizacion
    $cleanPath = $OnlinePath -replace "^Registry::", "" 
    $cleanPath = $cleanPath -replace "^HKLM:", "HKEY_LOCAL_MACHINE"
    $cleanPath = $cleanPath -replace "^HKLM\\", "HKEY_LOCAL_MACHINE\"
    $cleanPath = $cleanPath -replace "^HKCU:", "HKEY_CURRENT_USER"
    $cleanPath = $cleanPath -replace "^HKCU\\", "HKEY_CURRENT_USER\"
    $cleanPath = $cleanPath -replace "^HKCR:", "HKEY_CLASSES_ROOT"
    $cleanPath = $cleanPath -replace "^HKCR\\", "HKEY_CLASSES_ROOT\"
    $cleanPath = $cleanPath.Trim()

    # --- Mapeo de Clases de Usuario (UsrClass.dat) ---
    if ($cleanPath -match "HKEY_CURRENT_USER\\Software\\Classes") {
        # PARCHE INTELIGENTE: Si la colmena de clases del usuario no existe (típico en WIM offline),
        # redirigimos el ajuste a nivel de máquina (HKLM\SOFTWARE\Classes) para que se aplique globalmente.
        if (Test-Path "HKLM:\OfflineUserClasses") {
            return $cleanPath -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM\OfflineUserClasses"
        } else {
            return $cleanPath -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM\OfflineSoftware\Classes"
        }
    }

    # USUARIO (HKCU Generico - NTUSER.DAT)
    if ($cleanPath -match "HKEY_CURRENT_USER") {
        return $cleanPath -replace "HKEY_CURRENT_USER", "HKLM\OfflineUser"
    }

    # SYSTEM (HKEY_LOCAL_MACHINE\SYSTEM)
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SYSTEM") {
        $newPath = $cleanPath -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKLM\OfflineSystem"
        
        # Reemplazo inteligente de CurrentControlSet
        if ($newPath -match "CurrentControlSet") {
            $dynamicSet = Get-OfflineControlSet
            return $newPath -replace "CurrentControlSet", $dynamicSet
        }
        return $newPath -replace "ControlSet001", (Get-OfflineControlSet)
    }

    # SOFTWARE (HKEY_LOCAL_MACHINE\SOFTWARE)
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SOFTWARE") {
        return $cleanPath -replace "HKEY_LOCAL_MACHINE\\SOFTWARE", "HKLM\OfflineSoftware"
    }
    
    # CLASSES ROOT (Global) -> Lo mandamos a Software\Classes de la Maquina
    if ($cleanPath -match "HKEY_CLASSES_ROOT") {
        return $cleanPath -replace "HKEY_CLASSES_ROOT", "HKLM\OfflineSoftware\Classes"
    }
	
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\COMPONENTS") {
        return $cleanPath -replace "HKEY_LOCAL_MACHINE\\COMPONENTS", "HKLM\OfflineComponents"
    }
    
    return $null
}

# --- UTILIDAD: ACTIVAR PRIVILEGIOS DE TOKEN (SeTakeOwnership / SeRestore) ---
function Enable-Privileges {
    param(
        [string[]]$Privileges = @("SeTakeOwnershipPrivilege", "SeRestorePrivilege", "SeBackupPrivilege")
    )
    
    $definition = @'
    using System;
    using System.Runtime.InteropServices;
    
    public class TokenManipulator
    {
        [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
        internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
        
        [DllImport("kernel32.dll", ExactSpelling = true)]
        internal static extern IntPtr GetCurrentProcess();
        
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
            try {
                bool retVal;
                TokPriv1Luid tp;
                IntPtr hproc = GetCurrentProcess();
                IntPtr htok = IntPtr.Zero;
                retVal = OpenProcessToken(hproc, TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok);
                tp.Count = 1;
                tp.Luid = 0;
                tp.Attr = SE_PRIVILEGE_ENABLED;
                retVal = LookupPrivilegeValue(null, privilege, ref tp.Luid);
                retVal = AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
                return retVal;
            } catch { return false; }
        }
    }
'@
    # Cargar el tipo solo una vez
    if (-not ([System.Management.Automation.PSTypeName]'TokenManipulator').Type) {
        Add-Type -TypeDefinition $definition -PassThru | Out-Null
    }
    
    foreach ($priv in $Privileges) {
        [TokenManipulator]::AddPrivilege($priv) | Out-Null
    }
}

# Diccionario global en RAM para almacenar los permisos exactos de fábrica
$Script:SDDL_Backups = @{}

function Unlock-OfflineKey {
    param([string]$KeyPath)
    
    # 1. Privilegios (Siempre lo primero)
    Enable-Privileges

    # 2. Normalizar ruta
    $psPath = $KeyPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|Registry::HKEY_LOCAL_MACHINE|Registry::HKLM)[:\\]*", ""
    # Ahora $psPath es algo como "OfflineUser\Software\Microsoft..."
    
    # 3. IDENTIFICAR LA "RAiZ MAESTRA" (La Colmena)
    # Si estamos tocando OfflineUser, la raiz es "OfflineUser".
    $hiveName = $psPath.Split('\')[0] 
    
    if ($hiveName -in @("OfflineUser", "OfflineSoftware", "OfflineSystem", "OfflineComponents", "OfflineUserClasses")) {
        $rootHivePath = $hiveName
        
        # DESBLOQUEAR LA RAiZ PRIMERO
        Unlock-Single-Key -SubKeyPath $rootHivePath
    }

    # 4. Ahora intentamos desbloquear el ancestro mas cercano de la clave destino
    # (Igual que antes, para casos especificos profundos)
    $finalSubKey = $psPath
    $rootHive = [Microsoft.Win32.Registry]::LocalMachine
    
    while ($true) {
        try {
            # Check rapido de existencia
            $check = $rootHive.OpenSubKey($finalSubKey, [System.Security.AccessControl.RegistryRights]::ReadPermissions)
            if ($check) { $check.Close(); break }
        } catch { break } # Si existe pero esta bloqueada, break para desbloquearla
        
        $lastSlash = $finalSubKey.LastIndexOf("\")
        if ($lastSlash -lt 0) { return }
        $finalSubKey = $finalSubKey.Substring(0, $lastSlash)
    }

    # Desbloquear la clave especifica encontrada
    Unlock-Single-Key -SubKeyPath $finalSubKey
}

# --- RESTAURAR PROPIEDAD Y HERENCIA ---
function Restore-KeyOwner {
    param([string]$KeyPath)
    
    Enable-Privileges 
    $cleanPath = $KeyPath -replace "^Registry::", ""
    $subPath = $cleanPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|HKLM:|HKEY_LOCAL_MACHINE:)[:\\]+", ""
    $hive = [Microsoft.Win32.Registry]::LocalMachine

    # =========================================================
    # RESTAURACIÓN QUIRÚRGICA VÍA SDDL (Prioridad 1)
    # =========================================================
    if ($Script:SDDL_Backups.ContainsKey($subPath)) {
        try {
            $originalSddl = $Script:SDDL_Backups[$subPath]
            
            # Pedimos permisos para devolver la propiedad (TakeOwnership) y los accesos (ChangePermissions)
            $rights = [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::TakeOwnership
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
            
            if ($keyObj) {
                $aclRestored = New-Object System.Security.AccessControl.RegistrySecurity
                $aclRestored.SetSecurityDescriptorSddlForm($originalSddl)
                $keyObj.SetAccessControl($aclRestored)
                $keyObj.Close()
                
                Write-Log -LogLevel INFO -Message "Restauración SDDL Limpia: $subPath"
                $Script:SDDL_Backups.Remove($subPath) # Liberar memoria RAM
                return # SALIMOS: La clave quedó idéntica a fábrica
            }
        } catch {
            Write-Log -LogLevel WARN -Message "Fallo restauracion SDDL puro en $subPath. Aplicando Fallback clásico."
        }
    }

    # =========================================================
    # RESTAURACIÓN CLÁSICA / FALLBACK (Si no se logró respaldar el SDDL)
    # =========================================================
    $sidAdmin   = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $sidTrusted = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
    
    $isUserHive = $subPath -match "OfflineUser"
    $targetOwner = if ($isUserHive) { $sidAdmin } else { $sidTrusted }

    try {
        # Paso 1: Administradores toman el control para poder editar
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $acl.SetOwner($sidAdmin) 
            $keyObj.SetAccessControl($acl)
            $keyObj.Close()
        }

        # Paso 2: Resetear la herencia de permisos
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl()
            if (-not $isUserHive) {
                $acl.SetAccessRuleProtection($false, $false)
            }
            $keyObj.SetAccessControl($acl)
            $keyObj.Close()
            Write-Log -LogLevel INFO -Message "Restaurado (Herencia Reseteada): $subPath"
        }

        # Paso 3: Devolver a TrustedInstaller (Si es de sistema)
        if (-not $isUserHive) {
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($keyObj) {
                $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
                $acl.SetOwner($targetOwner)
                $keyObj.SetAccessControl($acl)
                $keyObj.Close()
            }
        }
    } catch {
        Write-Log -LogLevel ERROR -Message "Fallo en Restore-KeyOwner ($subPath): $($_.Exception.Message)"
    }
}

# --- LA FUNCIoN DE DESBLOQUEO ---
function Unlock-Single-Key {
    param([string]$SubKeyPath)
    
    # Filtro de seguridad para raices (No tocar bajo ningun concepto)
    if ($SubKeyPath -match "^(OfflineSystem|OfflineSoftware|OfflineUser|OfflineUserClasses|OfflineComponents)$") { return }
    
    # Asegurar privilegios de Administrador (SeTakeOwnership)
    Enable-Privileges
    $rootKey = [Microsoft.Win32.Registry]::LocalMachine

    # --- VERIFICACION PREVIA ---
    # Si podemos abrirla con 'WriteKey', no hace falta desbloquear nada.
    try {
        $testKey = $rootKey.OpenSubKey($SubKeyPath, [System.Security.AccessControl.RegistryRights]::WriteKey)
        if ($testKey) {
            $testKey.Close()
            return # SALIR: Ya tenemos permisos, no tocamos nada.
        }
    } catch { }

    $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $success = $false

    # --- PASO 1: TOMAR POSESION (Dueño) ---
    try {
        # Usamos ReadWriteSubTree para puentear bloqueos de API
        $keyOwner = $rootKey.OpenSubKey($SubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($keyOwner) {
            $acl = $keyOwner.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $acl.SetOwner($sidAdmin)
            $keyOwner.SetAccessControl($acl)
            $keyOwner.Close()
        }
    } catch { }

    # --- PASO 2: ASIGNAR CONTROL TOTAL ---
    # Lo hacemos en un paso separado para que el sistema reconozca al nuevo dueño
    try {
        $keyPerms = $rootKey.OpenSubKey($SubKeyPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($keyPerms) {
            $acl = $keyPerms.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sidAdmin, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $acl.SetAccessRule($rule)
            $keyPerms.SetAccessControl($acl)
            $keyPerms.Close()
            $success = $true
        }
    } catch { }
    
    # --- PASO 3: FALLBACK REGINI (En caso de desastre extremo) ---
    if (-not $success) {
        try {
            $kernelPath = "\Registry\Machine\$SubKeyPath"
            $reginiContent = "$kernelPath [1 17]"
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value $reginiContent -Encoding Ascii
            $p = Start-Process regini.exe -ArgumentList "`"$tempFile`"" -PassThru -WindowStyle Hidden -Wait
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            
            if ($p.ExitCode -eq 0) {
                 Write-Log -LogLevel WARN -Message "REGINI forzado en: $SubKeyPath"
            }
        } catch {}
    }
}

function Show-RegPreview-GUI {
    param([string]$FilePath)

    # 1. Configuracion de la Ventana (Optimizada)
    Add-Type -AssemblyName System.Windows.Forms
    $pForm = New-Object System.Windows.Forms.Form
    $pForm.Text = "Vista Previa Rapida - $([System.IO.Path]::GetFileName($FilePath))"
    $pForm.Size = New-Object System.Drawing.Size(1200, 600)
    $pForm.StartPosition = "CenterParent"
    $pForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $pForm.ForeColor = [System.Drawing.Color]::White
    $pForm.FormBorderStyle = "FixedDialog"
    $pForm.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Analizando cambios... (Modo Turbo .NET)"
    $lbl.Location = New-Object System.Drawing.Point(15, 10)
    $lbl.AutoSize = $true
    $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $pForm.Controls.Add($lbl)

    $lvP = New-Object System.Windows.Forms.ListView
    $lvP.Location = New-Object System.Drawing.Point(15, 40)
    $lvP.Size = New-Object System.Drawing.Size(1150, 480)
    $lvP.View = "Details"
    $lvP.FullRowSelect = $true
    $lvP.GridLines = $true
    $lvP.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $lvP.ForeColor = [System.Drawing.Color]::White
    # Doble buffer para evitar parpadeo
    $lvP.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]"NonPublic,Instance").SetValue($lvP, $true, $null)

    $lvP.Columns.Add("Tipo", 80) | Out-Null
    $lvP.Columns.Add("Nombre / Ruta", 550) | Out-Null
    $lvP.Columns.Add("Valor en Imagen (Actual)", 250) | Out-Null
    $lvP.Columns.Add("Valor en Archivo (Nuevo)", 250) | Out-Null

    $pForm.Controls.Add($lvP)

    $btnConfirm = New-Object System.Windows.Forms.Button
    $btnConfirm.Text = "CONFIRMAR IMPORTACION"
    $btnConfirm.Location = New-Object System.Drawing.Point(965, 530)
    $btnConfirm.Size = New-Object System.Drawing.Size(200, 30)
    $btnConfirm.BackColor = [System.Drawing.Color]::SeaGreen
    $btnConfirm.ForeColor = [System.Drawing.Color]::White
    $btnConfirm.DialogResult = "OK"
    $btnConfirm.FlatStyle = "Flat"
    $btnConfirm.Enabled = $false # Deshabilitado hasta terminar carga

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(850, 530)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 30)
    $btnCancel.BackColor = [System.Drawing.Color]::Crimson
    $btnCancel.ForeColor = [System.Drawing.Color]::White
    $btnCancel.DialogResult = "Cancel"
    $btnCancel.FlatStyle = "Flat"

    $pForm.Controls.Add($btnConfirm)
    $pForm.Controls.Add($btnCancel)

    # --- LoGICA DE CARGA DE ALTO RENDIMIENTO ---
    $pForm.Add_Shown({
        $pForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lvP.BeginUpdate()
        
        try {
            # 1. Lectura en bloque (IO rapido)
            $lines = [System.IO.File]::ReadAllLines($FilePath)
            
            # 2. Acceso directo al Registro .NET (Bypasseando la capa lenta de PowerShell)
            $baseKey = [Microsoft.Win32.Registry]::LocalMachine
            $currentSubKeyStr = $null
            $currentSubKeyObj = $null

            # Pre-compilacion de Regex para velocidad (USANDO COMILLAS SIMPLES PARA EVITAR ERRORES)
            $regKey = [regex]'^\[(-?)(HKEY_.*|HKLM.*|HKCU.*|HKCR.*)\]$'
            $regVal = [regex]'"(.+?)"=(.*)'
            $regDef = [regex]'^@=(.*)'

            foreach ($line in $lines) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                $line = $line.Trim()

                # CASO A: CLAVE
                if ($line -match $regKey) {
                    $isDelete = $matches[1] -eq "-"
                    $keyRaw = $matches[2]
                    
                    # Cerrar clave anterior para liberar memoria
                    if ($currentSubKeyObj) { $currentSubKeyObj.Close(); $currentSubKeyObj = $null }

                    # --- Traduccion de Rutas (Optimizado) ---
                    # Convertimos todo a rutas relativas de HKLM para .NET OpenSubKey
                    $relPath = $keyRaw -replace "^(HKEY_LOCAL_MACHINE|HKLM)\\SOFTWARE", "OfflineSoftware" `
                                       -replace "^(HKEY_LOCAL_MACHINE|HKLM)\\SYSTEM", "OfflineSystem" `
                                       -replace "^(HKEY_CURRENT_USER|HKCU)\\Software\\Classes", "OfflineUserClasses" `
                                       -replace "^(HKEY_CURRENT_USER|HKCU)", "OfflineUser" `
                                       -replace "^(HKEY_CLASSES_ROOT|HKCR)", "OfflineSoftware\Classes"
                    
                    # Limpieza final
                    $relPath = $relPath -replace "^(HKEY_LOCAL_MACHINE|HKLM)\\", ""
                    $currentSubKeyStr = $relPath

                    # Intentamos abrir la clave en modo SOLO LECTURA (Rapido)
                    $exists = $false
                    try {
                        $currentSubKeyObj = $baseKey.OpenSubKey($relPath, $false) # $false = ReadOnly
                        if ($currentSubKeyObj) { $exists = $true }
                    } catch {}

                    # UI
                    $item = New-Object System.Windows.Forms.ListViewItem("CLAVE")
                    $item.SubItems.Add($keyRaw) | Out-Null
                    
                    if ($isDelete) {
                        $item.SubItems.Add("EXISTE") | Out-Null
                        $item.SubItems.Add(">>> ELIMINAR <<<") | Out-Null
                        $item.ForeColor = [System.Drawing.Color]::Salmon
                    } else {
                        $item.SubItems.Add( $(if($exists){"EXISTE"}else{"NUEVA"}) ) | Out-Null
                        $item.SubItems.Add("-") | Out-Null
                        $item.ForeColor = [System.Drawing.Color]::Yellow
                    }
                    $lvP.Items.Add($item) | Out-Null
                }
                
                # CASO B: VALOR NOMBRADO ("Nombre"="Valor")
                elseif ($currentSubKeyStr -and $line -match $regVal) {
                    $valName = $matches[1]
                    $newVal = $matches[2]
                    $currVal = "No existe"
                    
                    # Lectura Directa .NET (0ms latencia)
                    if ($currentSubKeyObj) {
                        $raw = $currentSubKeyObj.GetValue($valName, $null)
                        if ($null -ne $raw) {
                            $currVal = if ($raw -eq "") { "(Vacio)" } else { $raw.ToString() }
                        }
                    }

                    $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                    $item.SubItems.Add($valName) | Out-Null
                    $item.SubItems.Add("$currVal") | Out-Null
                    $item.SubItems.Add("$newVal") | Out-Null

                    if ("$currVal" -eq "$newVal") {
                        $item.ForeColor = [System.Drawing.Color]::Gray
                    } else {
                        $item.ForeColor = [System.Drawing.Color]::Cyan
                    }
                    $lvP.Items.Add($item) | Out-Null
                }

                # CASO C: VALOR POR DEFECTO (@="Valor")
                elseif ($currentSubKeyStr -and $line -match $regDef) {
                    $valName = "(Predeterminado)"
                    $newVal = $matches[1]
                    $currVal = "No existe"

                    if ($currentSubKeyObj) {
                        $raw = $currentSubKeyObj.GetValue("", $null) # "" accede al Default
                        if ($null -ne $raw) {
                            $currVal = if ($raw -eq "") { "(Vacio)" } else { $raw.ToString() }
                        }
                    }

                    $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                    $item.SubItems.Add($valName) | Out-Null
                    $item.SubItems.Add("$currVal") | Out-Null
                    $item.SubItems.Add("$newVal") | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Cyan
                    $lvP.Items.Add($item) | Out-Null
                }
            }

            # Limpieza final de handles
            if ($currentSubKeyObj) { $currentSubKeyObj.Close() }
            
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Error leyendo vista previa: $_", "Error", 'OK', 'Error')
        } finally {
            $lvP.EndUpdate()
            $pForm.Cursor = [System.Windows.Forms.Cursors]::Default
            $lbl.Text = "Analisis completado."
            $btnConfirm.Enabled = $true
        }
    })

    return ($pForm.ShowDialog() -eq 'OK')
}

function Get-OfflineControlSet { 
    $SystemHivePath = "HKLM\OfflineSystem"
    $currentSet = 1 # Fallback seguro (ControlSet001)
    
    if (Test-Path "$SystemHivePath\Select") {
        try {
            $props = Get-ItemProperty -Path "$SystemHivePath\Select" -ErrorAction SilentlyContinue
            if ($props -and $props.Current) {
                $currentSet = $props.Current
            }
        } catch {
            Write-Log -LogLevel WARN -Message "No se pudo determinar el ControlSet activo. Usando Default (001)."
        }
    }
    
    # Retorna formato string (ej. "ControlSet001")
    return "ControlSet{0:d3}" -f $currentSet
}

#  Modulo GUI: Gestor de Cola de Registro y Perfiles (.REG)
function Show-RegQueue-GUI {
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $frmQ = New-Object System.Windows.Forms.Form
    $frmQ.Text = "Gestor de Importacion en Lote y Perfiles (.REG)"
    $frmQ.Size = New-Object System.Drawing.Size(950, 650)
    $frmQ.StartPosition = "CenterParent"
    $frmQ.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $frmQ.ForeColor = [System.Drawing.Color]::White
    $frmQ.FormBorderStyle = "FixedDialog"
    $frmQ.MaximizeBox = $false

    $lblQ = New-Object System.Windows.Forms.Label
    $lblQ.Text = "Cola de Procesamiento de Registro"
    $lblQ.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblQ.Location = "20, 15"; $lblQ.AutoSize = $true
    $frmQ.Controls.Add($lblQ)

    # ListView para la cola
    $lvQ = New-Object System.Windows.Forms.ListView
    $lvQ.Location = "20, 50"
    $lvQ.Size = "890, 400"
    $lvQ.View = "Details"
    $lvQ.FullRowSelect = $true
    $lvQ.GridLines = $true
    $lvQ.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lvQ.ForeColor = [System.Drawing.Color]::White
    $lvQ.HideSelection = $false

    $lvQ.Columns.Add("Estado", 140) | Out-Null
    $lvQ.Columns.Add("Archivo", 250) | Out-Null
    $lvQ.Columns.Add("Ruta Completa", 480) | Out-Null
    $frmQ.Controls.Add($lvQ)

    # --- BOTONES DE CONTROL DE COLA ---
    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "+ Agregar"
    $btnAdd.Location = "20, 460"
    $btnAdd.Size = "100, 35"
    $btnAdd.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAdd.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnAdd)

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "- Quitar"
    $btnRemove.Location = "130, 460"
    $btnRemove.Size = "100, 35"
    $btnRemove.BackColor = [System.Drawing.Color]::Crimson
    $btnRemove.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnRemove)

    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Limpiar"
    $btnClear.Location = "240, 460"
    $btnClear.Size = "100, 35"
    $btnClear.BackColor = [System.Drawing.Color]::Gray
    $btnClear.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnClear)

    $btnPreview = New-Object System.Windows.Forms.Button
    $btnPreview.Text = "Auditar (Vista Previa)"
    $btnPreview.Location = "350, 460"
    $btnPreview.Size = "160, 35"
    $btnPreview.BackColor = [System.Drawing.Color]::Teal
    $btnPreview.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnPreview)

    # --- NUEVOS BOTONES DE PERFIL ---
    $btnLoadProfile = New-Object System.Windows.Forms.Button
    $btnLoadProfile.Text = "Cargar Perfil"
    $btnLoadProfile.Location = "20, 510"
    $btnLoadProfile.Size = "140, 35"
    $btnLoadProfile.BackColor = [System.Drawing.Color]::DarkOrchid
    $btnLoadProfile.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnLoadProfile)

    $btnSaveProfile = New-Object System.Windows.Forms.Button
    $btnSaveProfile.Text = "Guardar Perfil"
    $btnSaveProfile.Location = "170, 510"
    $btnSaveProfile.Size = "140, 35"
    $btnSaveProfile.BackColor = [System.Drawing.Color]::Indigo
    $btnSaveProfile.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnSaveProfile)

    # --- BOTON DE PROCESO ---
    $btnProcess = New-Object System.Windows.Forms.Button
    $btnProcess.Text = "PROCESAR LOTE MAESTRO"
    $btnProcess.Location = "640, 470"
    $btnProcess.Size = "270, 60"
    $btnProcess.BackColor = [System.Drawing.Color]::SeaGreen
    $btnProcess.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnProcess.FlatStyle = "Flat"
    $frmQ.Controls.Add($btnProcess)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Agregue archivos o cargue un perfil para comenzar."
    $lblStatus.Location = "20, 570"
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $frmQ.Controls.Add($lblStatus)

    # --- EVENTOS BÁSICOS ---
    $btnAdd.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Archivos de Registro (*.reg)|*.reg"
        $ofd.Multiselect = $true
        
        if ($ofd.ShowDialog() -eq 'OK') {
            $lvQ.BeginUpdate()
            foreach ($file in $ofd.FileNames) {
                $exists = $false
                foreach ($item in $lvQ.Items) {
                    if ($item.Tag -eq $file) { $exists = $true; break }
                }
                
                if (-not $exists) {
                    $newItem = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                    $newItem.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                    $newItem.SubItems.Add($file) | Out-Null
                    $newItem.ForeColor = [System.Drawing.Color]::Yellow
                    $newItem.Tag = $file
                    $lvQ.Items.Add($newItem) | Out-Null
                }
            }
            $lvQ.EndUpdate()
            $lblStatus.Text = "Archivos en cola: $($lvQ.Items.Count)"
        }
    })

    $btnRemove.Add_Click({
        foreach ($item in $lvQ.SelectedItems) { $lvQ.Items.Remove($item) }
        $lblStatus.Text = "Archivos en cola: $($lvQ.Items.Count)"
    })

    $btnClear.Add_Click({
        $lvQ.Items.Clear()
        $lblStatus.Text = "Cola vacia."
    })

    $btnPreview.Add_Click({
        if ($lvQ.SelectedItems.Count -ne 1) {
            [System.Windows.Forms.MessageBox]::Show("Selecciona exactamente un (1) archivo de la lista para auditarlo.", "Aviso", 'OK', 'Warning')
            return
        }
        $selectedFilePath = $lvQ.SelectedItems[0].Tag
        $null = Show-RegPreview-GUI -FilePath $selectedFilePath
    })

    # --- EVENTOS DE PERFIL ---
    $btnSaveProfile.Add_Click({
        if ($lvQ.Items.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("La cola esta vacia. Agrega archivos primero.", "Aviso", 'OK', 'Warning')
            return
        }
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
        $sfd.Filter = "Perfil de Tweaks (*.txt)|*.txt"
        $sfd.FileName = "MiPerfilTweaks.txt"
        
        if ($sfd.ShowDialog() -eq 'OK') {
            $rutas = @()
            foreach ($item in $lvQ.Items) { $rutas += $item.Tag }
            
            try {
                $rutas | Out-File -FilePath $sfd.FileName -Encoding utf8
                $lblStatus.Text = "Perfil guardado correctamente."
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al guardar el perfil: $_", "Error", 'OK', 'Error')
            }
        }
    })

    $btnLoadProfile.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Perfil de Tweaks (*.txt)|*.txt"
        
        if ($ofd.ShowDialog() -eq 'OK') {
            try {
                $rutas = Get-Content $ofd.FileName
                $lvQ.BeginUpdate()
                
                $cargados = 0
                $omitidos = 0
                
                foreach ($ruta in $rutas) {
                    if ([string]::IsNullOrWhiteSpace($ruta)) { continue }
                    
                    if (-not (Test-Path -LiteralPath $ruta)) {
                        $omitidos++
                        continue
                    }

                    $exists = $false
                    foreach ($item in $lvQ.Items) {
                        if ($item.Tag -eq $ruta) { $exists = $true; break }
                    }
                    
                    if (-not $exists) {
                        $newItem = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                        $newItem.SubItems.Add([System.IO.Path]::GetFileName($ruta)) | Out-Null
                        $newItem.SubItems.Add($ruta) | Out-Null
                        $newItem.ForeColor = [System.Drawing.Color]::Yellow
                        $newItem.Tag = $ruta
                        $lvQ.Items.Add($newItem) | Out-Null
                        $cargados++
                    }
                }
                $lvQ.EndUpdate()
                
                $lblStatus.Text = "Perfil cargado. Archivos en cola: $($lvQ.Items.Count)"
                if ($omitidos -gt 0) {
                    [System.Windows.Forms.MessageBox]::Show("Se omitieron $omitidos archivos porque ya no existen en la ruta guardada.", "Aviso de Perfil", 'OK', 'Information')
                }
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Error al leer el perfil: $_", "Error", 'OK', 'Error')
            }
        }
    })

    # --- EVENTO MAESTRO ---
    $btnProcess.Add_Click({
        if ($lvQ.Items.Count -eq 0) { return }

        $res = [System.Windows.Forms.MessageBox]::Show("Se fusionaran e importaran $($lvQ.Items.Count) archivos en una sola transaccion.`n¿Desea continuar?", "Confirmar Lote", 'YesNo', 'Question')
        if ($res -ne 'Yes') { 
            Write-Log -LogLevel INFO -Message "RegBatch: El usuario cancelo el procesamiento del lote en el cuadro de confirmacion."
            return 
        }

        Write-Log -LogLevel ACTION -Message "RegBatch: Iniciando procesamiento en lote de $($lvQ.Items.Count) archivos .reg."

        $btnAdd.Enabled = $false; $btnRemove.Enabled = $false; $btnClear.Enabled = $false; $btnPreview.Enabled = $false; $btnLoadProfile.Enabled = $false; $btnSaveProfile.Enabled = $false; $btnProcess.Enabled = $false
        $frmQ.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        $tempReg = Join-Path $env:TEMP "gui_import_batch_$PID.reg"
        $keysToProcess = New-Object System.Collections.Generic.HashSet[string]
        
        $combinedContent = New-Object System.Text.StringBuilder
        $null = $combinedContent.AppendLine("Windows Registry Editor Version 5.00")
        $null = $combinedContent.AppendLine("")

        $errors = 0
        $importExitCode = 0

        try {
            Write-Log -LogLevel INFO -Message "RegBatch: Fase 1 - Analizando, limpiando cabeceras y traduciendo rutas a colmenas Offline..."
            $lblStatus.Text = "Fase 1: Analizando y fusionando archivos en memoria..."
            $frmQ.Refresh()

            foreach ($item in $lvQ.Items) {
                if ($item.Text -ne "EN ESPERA" -and $item.Text -ne "ERROR LECTURA") { continue }
                
                $item.Text = "PROCESANDO"
                $item.ForeColor = [System.Drawing.Color]::Cyan
                $frmQ.Refresh()
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    # Dejamos que .NET detecte la codificacion (BOM) automaticamente
                    $content = [System.IO.File]::ReadAllText($item.Tag)
                    
                    # Regex robusto: Elimina la cabecera sin importar los saltos de linea o basura previa
                    $content = $content -replace "(?is)^.*?Windows Registry Editor Version 5\.00\r?\n*", ""

                    # --- PARCHE DE REDIRECCION INTELIGENTE (UsrClass.dat missing) ---
                    $targetUserClasses = "HKEY_LOCAL_MACHINE\OfflineUserClasses"
                    if (-not (Test-Path "HKLM:\OfflineUserClasses")) {
                        $targetUserClasses = "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"
                    }

                    $newContent = $content -replace "(?i)HKEY_LOCAL_MACHINE\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                                           -replace "(?i)HKLM\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                                           -replace "(?i)HKEY_LOCAL_MACHINE\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                                           -replace "(?i)HKLM\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                                           -replace "(?i)HKEY_CURRENT_USER\\Software\\Classes", $targetUserClasses `
                                           -replace "(?i)HKCU\\Software\\Classes", $targetUserClasses `
                                           -replace "(?i)HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE\OfflineUser" `
                                           -replace "(?i)HKCU", "HKEY_LOCAL_MACHINE\OfflineUser" `
                                           -replace "(?i)HKEY_CLASSES_ROOT", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes" `
                                           -replace "(?i)HKCR", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"

                    $null = $combinedContent.AppendLine($newContent)

                    $pattern = '\[-?(HKEY_LOCAL_MACHINE\\(OfflineSoftware|OfflineSystem|OfflineUser|OfflineUserClasses|OfflineComponents)[^\]]*)\]'
                    $matches = [regex]::Matches($newContent, $pattern)
                    
                    foreach ($m in $matches) {
                        $keyPath = $m.Groups[1].Value.Trim()
                        if ($keyPath.StartsWith("-")) { $keyPath = $keyPath.Substring(1) }
                        $null = $keysToProcess.Add($keyPath)
                    }

                    $item.Text = "LISTO (Fusionado)"
                    Write-Log -LogLevel INFO -Message "RegBatch: Fusionado exitosamente -> $($item.Tag)"
                } catch {
                    $item.Text = "ERROR LECTURA"
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $errors++
                    Write-Log -LogLevel WARN -Message "RegBatch: Error al leer/fusionar el archivo $($item.Tag) - $($_.Exception.Message)"
                }
            }

            $totalKeys = $keysToProcess.Count
            Write-Log -LogLevel ACTION -Message "RegBatch: Fase 2 - Desbloqueando $totalKeys claves maestras unicas..."
            $lblStatus.Text = "Fase 2: Desbloqueando $totalKeys claves unicas..."
            $frmQ.Refresh()

            $currentKey = 0
            foreach ($targetKey in $keysToProcess) {
                $currentKey++
                if ($currentKey % 5 -eq 0) {
                    $lblStatus.Text = "Desbloqueando ($currentKey / $totalKeys)..."
                    $frmQ.Refresh()
                    [System.Windows.Forms.Application]::DoEvents()
                }
                Unlock-OfflineKey -KeyPath $targetKey
            }

            Write-Log -LogLevel ACTION -Message "RegBatch: Fase 3 - Generando archivo maestro e importando via regedit.exe..."
            $lblStatus.Text = "Fase 3: Importando lote maestro al registro..."
            $frmQ.Refresh()
            
            # Guardamos siempre en UTF-16 LE (Unicode), el estandar estricto de regedit
            [System.IO.File]::WriteAllText($tempReg, $combinedContent.ToString(), [System.Text.Encoding]::Unicode)

            # Usamos el motor nativo de Windows (mas tolerante a la fusion de archivos)
            $process = Start-Process regedit.exe -ArgumentList "/s `"$tempReg`"" -Wait -PassThru -WindowStyle Hidden
            $importExitCode = $process.ExitCode
            
            Write-Log -LogLevel INFO -Message "RegBatch: regedit.exe finalizo con codigo de salida: $importExitCode"

        } catch {
            Write-Log -LogLevel ERROR -Message "RegBatch: Fallo critico procesando el lote - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Fallo critico en el procesamiento: $_", "Error", 'OK', 'Error')
        } finally {
            Write-Log -LogLevel INFO -Message "RegBatch: Fase 4 - Asegurando SDDL y restaurando herencia de las claves modificadas."
            $lblStatus.Text = "Fase 4: Asegurando permisos y restaurando herencia..."
            $frmQ.Refresh()
            
            $restoredCount = 0
            foreach ($targetKey in $keysToProcess) {
                $psCheckPath = $targetKey -replace "^HKEY_LOCAL_MACHINE", "HKLM:"
                
                if (Test-Path -LiteralPath $psCheckPath) {
                    Restore-KeyOwner -KeyPath $targetKey
                    $restoredCount++
                }
                
                if ($restoredCount % 5 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
            }

            Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

            foreach ($item in $lvQ.Items) {
                if ($item.Text -eq "LISTO (Fusionado)") {
                    if ($importExitCode -eq 0) {
                        $item.Text = "COMPLETADO"
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                    } else {
                        $item.Text = "ADVERTENCIA"
                        $item.ForeColor = [System.Drawing.Color]::Orange
                    }
                }
            }

            $frmQ.Cursor = [System.Windows.Forms.Cursors]::Default
            $btnAdd.Enabled = $true; $btnRemove.Enabled = $true; $btnClear.Enabled = $true; $btnPreview.Enabled = $true; $btnLoadProfile.Enabled = $true; $btnSaveProfile.Enabled = $true; $btnProcess.Enabled = $true

            if ($importExitCode -eq 0) {
                Write-Log -LogLevel INFO -Message "RegBatch: Transaccion de Lote completada. Claves restauradas: $restoredCount."
                $lblStatus.Text = "Lote finalizado con exito."
                [System.Windows.Forms.MessageBox]::Show("Transaccion procesada correctamente.`nClaves unicas aseguradas: $restoredCount", "Exito", 'OK', 'Information')
            } else {
                Write-Log -LogLevel WARN -Message "RegBatch: Lote finalizado con advertencias. Regedit.exe rechazo algunos valores o lineas mal formadas."
                $lblStatus.Text = "Lote finalizado con errores en reg.exe."
                [System.Windows.Forms.MessageBox]::Show("El motor devolvio una advertencia ($importExitCode).`nAlgunos valores podrian haber sido rechazados por el sistema.", "Atencion", 'OK', 'Warning')
            }
        }
    })

    $frmQ.ShowDialog() | Out-Null
    $frmQ.Dispose()
    [GC]::Collect()
}

# =================================================================
#  Modulo GUI de Tweaks Offline
# =================================================================
function Show-Tweaks-Offline-GUI {
    # 1. Validaciones Previas
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    # 2. Cargar Catalogo (Fallback inteligente)
    $tweaksFile = Join-Path $PSScriptRoot "Catalogos\Ajustes.ps1"
    if (-not (Test-Path $tweaksFile)) { $tweaksFile = Join-Path $PSScriptRoot "Ajustes.ps1" }
    if (Test-Path $tweaksFile) { . $tweaksFile } else { Write-Warning "Falta Ajustes.ps1"; return }

    # 3. Montar Hives
    if (-not (Mount-Hives)) { return }

    # --- INICIO DE CONSTRUCCION GUI ---
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Collections 

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Optimizacion de Registro Offline (WIM) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(1200, 800) 
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Inicializar el objeto ToolTip
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 5000
    $toolTip.InitialDelay = 500
    $toolTip.ReshowDelay = 500
    $toolTip.ShowAlways = $true

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestor de Ajustes y Registro"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Boton Importar .REG
    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = "IMPORTAR ARCHIVO .REG..."
    $btnImport.Location = New-Object System.Drawing.Point(950, 10)
    $btnImport.Size = New-Object System.Drawing.Size(200, 35)
    $btnImport.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnImport.ForeColor = [System.Drawing.Color]::White
    $btnImport.FlatStyle = "Flat"
    $form.Controls.Add($btnImport)
    
        # --- LOGICA DE ANaLISIS .REG (Interna para la GUI) ---
    $Script:AnalyzeRegToString = {
        param($filePath)
        $report = "--- RESUMEN DE CAMBIOS ---`n"
        $lines = Get-Content $filePath
        $currentKeyOffline = $null

        foreach ($line in $lines) {
            $line = $line.Trim()
            if ($line -match "^\[(-?)(HKEY_.*|HKLM.*|HKCU.*)\]$") {
                $isDelete = $matches[1] -eq "-"
                $keyRaw = $matches[2]
                
                # Traduccion Secuencial (La que arreglamos)
                $keyOffline = $keyRaw.Replace("HKEY_LOCAL_MACHINE\SOFTWARE", "HKLM:\OfflineSoftware")
                $keyOffline = $keyOffline.Replace("HKLM\SOFTWARE", "HKLM:\OfflineSoftware")
                $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SYSTEM", "HKLM:\OfflineSystem")
                $keyOffline = $keyOffline.Replace("HKLM\SYSTEM", "HKLM:\OfflineSystem")
                $keyOffline = $keyOffline.Replace("HKEY_CURRENT_USER", "HKLM:\OfflineUser")
                $keyOffline = $keyOffline.Replace("HKCU", "HKLM:\OfflineUser")

                if (-not $keyOffline.StartsWith("HKLM:\")) { $keyOffline = $keyOffline -replace "^HKLM\\", "HKLM:\" }
                $currentKeyOffline = $keyOffline

                $existStr = if (Test-Path $currentKeyOffline) { "(EXISTE)" } else { "(NUEVA)" }
                $report += "`n[CLAVE] $keyRaw $existStr`n"
            }
            elseif ($currentKeyOffline -and $line -match '^"(.+?)"=(.*)') {
                $valName = $matches[1]
                $newVal = $matches[2]
                $currVal = "No existe"
                try {
                    if (Test-Path $currentKeyOffline) {
                        $p = Get-ItemProperty -Path $currentKeyOffline -Name $valName -ErrorAction SilentlyContinue
                        if ($p) { $currVal = $p.$valName }
                    }
                } catch {}
                $report += "   VALOR: $valName | Actual: $currVal -> Nuevo: $newVal`n"
            }
        }
        return $report
    }

    # --- EVENTO: IMPORTAR .REG (SOPORTE MULTIPLE / BATCH) ---
    $btnImport.Add_Click({
        Show-RegQueue-GUI
    })

    # Control de Pestanas
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 60)
    $tabControl.Size = New-Object System.Drawing.Size(1140, 580) 
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tabControl)

    # --- PANEL DE ACCIONES GLOBALES ---
    $pnlActions = New-Object System.Windows.Forms.Panel
    $pnlActions.Location = New-Object System.Drawing.Point(20, 650)
    $pnlActions.Size = New-Object System.Drawing.Size(1140, 100)
    $pnlActions.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
    $pnlActions.BorderStyle = "FixedSingle"
    $form.Controls.Add($pnlActions)

    # Barra de Estado 
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Selecciona ajustes en varias pestanas y aplica todo al final."
    $lblStatus.Location = New-Object System.Drawing.Point(10, 10)
    $lblStatus.AutoSize = $true
    $lblStatus.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $pnlActions.Controls.Add($lblStatus)

    # 1. Boton Marcar Todo
    $btnSelectAllGlobal = New-Object System.Windows.Forms.Button
    $btnSelectAllGlobal.Text = "Marcar Todo"
    $btnSelectAllGlobal.Location = New-Object System.Drawing.Point(10, 40)
    $btnSelectAllGlobal.Size = New-Object System.Drawing.Size(160, 40)
    $btnSelectAllGlobal.BackColor = [System.Drawing.Color]::Gray
    $btnSelectAllGlobal.FlatStyle = "Flat"
    # ToolTip agregado
    $toolTip.SetToolTip($btnSelectAllGlobal, "Solo se seleccionaran los elementos visibles en la PESTANA ACTUAL.")
    $pnlActions.Controls.Add($btnSelectAllGlobal)

    # 2. Boton Marcar Inactivos
    $btnSelectInactive = New-Object System.Windows.Forms.Button
    $btnSelectInactive.Text = "Marcar Inactivos"
    $btnSelectInactive.Location = New-Object System.Drawing.Point(180, 40)
    $btnSelectInactive.Size = New-Object System.Drawing.Size(160, 40)
    $btnSelectInactive.BackColor = [System.Drawing.Color]::DimGray
    $btnSelectInactive.ForeColor = [System.Drawing.Color]::White
    $btnSelectInactive.FlatStyle = "Flat"
    # ToolTip agregado
    $toolTip.SetToolTip($btnSelectInactive, "Solo se seleccionaran los elementos visibles en la PESTANA ACTUAL.")
    $pnlActions.Controls.Add($btnSelectInactive)

    # 3. Boton Restaurar (Global)
    $btnRestoreGlobal = New-Object System.Windows.Forms.Button
    $btnRestoreGlobal.Text = "RESTAURAR VALORES"
    $btnRestoreGlobal.Location = New-Object System.Drawing.Point(450, 40)
    $btnRestoreGlobal.Size = New-Object System.Drawing.Size(320, 40)
    $btnRestoreGlobal.BackColor = [System.Drawing.Color]::FromArgb(200, 100, 0) # Naranja
    $btnRestoreGlobal.ForeColor = [System.Drawing.Color]::White
    $btnRestoreGlobal.FlatStyle = "Flat"
    $btnRestoreGlobal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $pnlActions.Controls.Add($btnRestoreGlobal)

    # 4. Boton Aplicar (Global)
    $btnApplyGlobal = New-Object System.Windows.Forms.Button
    $btnApplyGlobal.Text = "APLICAR SELECCION"
    $btnApplyGlobal.Location = New-Object System.Drawing.Point(790, 40)
    $btnApplyGlobal.Size = New-Object System.Drawing.Size(320, 40)
    $btnApplyGlobal.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApplyGlobal.ForeColor = [System.Drawing.Color]::White
    $btnApplyGlobal.FlatStyle = "Flat"
    $btnApplyGlobal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $pnlActions.Controls.Add($btnApplyGlobal)

    # Lista Global para rastrear todos los ListViews
    $globalListViews = New-Object System.Collections.Generic.List[System.Windows.Forms.ListView]

    # --- GENERAR PESTANAS Y LISTAS ---
    $form.Add_Shown({
        $form.Refresh()
        $cats = $script:SystemTweaks | Where { $_.Method -eq "Registry" } | Select -Expand Category -Unique | Sort
        $tabControl.SuspendLayout()

        foreach ($cat in $cats) {
            $tp = New-Object System.Windows.Forms.TabPage
            $tp.Text = "  $cat  "
            $tp.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            # ListView Especifico
            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = "Fill"
            $lv.View = "Details"
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White
            
            $imgList = New-Object System.Windows.Forms.ImageList
            $imgList.ImageSize = New-Object System.Drawing.Size(1, 28) 
            $lv.SmallImageList = $imgList
            
            $lv.Columns.Add("Ajuste", 450) | Out-Null
            $lv.Columns.Add("Estado Actual", 120) | Out-Null
            $lv.Columns.Add("Descripcion", 500) | Out-Null
            
            # Llenar datos
            $tweaks = $script:SystemTweaks | Where { $_.Category -eq $cat -and $_.Method -eq "Registry" }
            foreach ($tw in $tweaks) {
                $pathRaw = Translate-OfflinePath -OnlinePath $tw.RegistryPath
                if ($pathRaw) {
                    $item = New-Object System.Windows.Forms.ListViewItem($tw.Name)
                    
                    $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                    $state = "INACTIVO"
                    $color = [System.Drawing.Color]::White 
                    
                    try {
                        $curr = (Get-ItemProperty -Path $psPath -Name $tw.RegistryKey -ErrorAction SilentlyContinue).($tw.RegistryKey)
                        if ("$curr" -eq "$($tw.EnabledValue)") {
                            $state = "ACTIVO"
                            $color = [System.Drawing.Color]::Cyan
                        }
                    } catch {}

                    $item.SubItems.Add($state) | Out-Null
                    $item.SubItems.Add($tw.Description) | Out-Null
                    $item.ForeColor = $color
                    $item.Tag = $tw 
                    $lv.Items.Add($item) | Out-Null
                }
            }

            $tp.Controls.Add($lv)
            $tabControl.TabPages.Add($tp)
            $globalListViews.Add($lv)
        }
        $tabControl.ResumeLayout()
    })

    # --- LOGICA DE EVENTOS ---

    # A. Marcar Todo
    $btnSelectAllGlobal.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0] 
            foreach ($item in $lv.Items) {
                if ($item.Checked) { $item.Checked = $false } else { $item.Checked = $true }
            }
        }
    })

    # B. Marcar Inactivos
    $btnSelectInactive.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0]
            foreach ($item in $lv.Items) {
                # Solo marca si NO esta ACTIVO
                if ($item.SubItems[1].Text -ne "ACTIVO") {
                    $item.Checked = $true
                }
            }
        }
    })

    # Helper de Procesamiento
    $ProcessChanges = {
        param($Mode) # 'Apply' o 'Restore'

        Write-Log -LogLevel INFO -Message "Tweak_Engine: Recopilando elementos marcados para la operacion ($Mode)."
        
        $allCheckedItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($item in $lv.CheckedItems) {
                $allCheckedItems.Add($item)
            }
        }

        if ($allCheckedItems.Count -eq 0) {
            Write-Log -LogLevel WARN -Message "Tweak_Engine: El usuario intento iniciar el proceso sin seleccionar ningun ajuste."
            [System.Windows.Forms.MessageBox]::Show("No hay ajustes seleccionados.", "Aviso", 'OK', 'Warning')
            return
        }

        $msgTitle = if ($Mode -eq 'Apply') { "Aplicar Cambios" } else { "Restaurar Cambios" }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Se Aplicaran $($allCheckedItems.Count) ajustes en TOTAL.`nDeseas continuar?", $msgTitle, 'YesNo', 'Question')
        if ($confirm -eq 'No') { 
            Write-Log -LogLevel INFO -Message "Tweak_Engine: Operacion cancelada por el usuario en el cuadro de confirmacion."
            return 
        }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = "Procesando registro... ($Mode)"
        $form.Refresh()

        Write-Log -LogLevel ACTION -Message "Tweak_Engine: Iniciando procesamiento de $($allCheckedItems.Count) claves de registro. Modo: [$Mode]"

        $errors = 0
        $success = 0

        $hiveObj = [Microsoft.Win32.Registry]::LocalMachine

        foreach ($it in $allCheckedItems) {
            $t = $it.Tag 
            $pathRaw = Translate-OfflinePath -OnlinePath $t.RegistryPath
            
            if ($pathRaw) {
                $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                $subPathNet = $pathRaw -replace "^HKLM\\", "" 
                
                $valToSet = $null
                $isDeleteProperty = $false
                $isDeleteKey = $false

                if ($Mode -eq 'Apply') {
                    $valToSet = $t.EnabledValue
                } else {
                    $valToSet = $t.DefaultValue
                    if ($valToSet -eq "DeleteKey") { $isDeleteKey = $true }
                    elseif ($valToSet -eq "DeleteValue") { $isDeleteProperty = $true }
                }

                try {
                    # --- ACCION DE BORRAR CARPETA (Para Restaurar) ---
                    if ($isDeleteKey) {
                        # CRITICO: Para borrar una clave, necesitamos permisos sobre el PADRE.
                        $parentPathPS = Split-Path $psPath
                        
                        Unlock-OfflineKey -KeyPath $parentPathPS
                        Unlock-OfflineKey -KeyPath $psPath

                        $checkKey = $hiveObj.OpenSubKey($subPathNet)
                        if ($null -ne $checkKey) {
                            $checkKey.Close() # Liberar el handle inmediatamente
                            # Borramos usando la API nativa
                            $hiveObj.DeleteSubKeyTree($subPathNet)
                            Write-Log -LogLevel INFO -Message "Tweak_Engine: Arbol de claves borrado nativamente -> $subPathNet"
                        }
                        
                        # Devolvemos la propiedad al padre (la clave original ya fue destruida)
                        Restore-KeyOwner -KeyPath $parentPathPS

                        $it.SubItems[1].Text = "RESTAURADO"
                        $it.ForeColor = [System.Drawing.Color]::LightGray
                        $it.Checked = $false 
                        $success++
                        continue
                    }

                    # --- ACCION DE CREAR/MODIFICAR (Motor .NET) ---
                    Unlock-OfflineKey -KeyPath $psPath
                    
                    $keyObj = $hiveObj.CreateSubKey($subPathNet)
                    
                    if ($null -ne $keyObj) {
                        $targetRegKey = $t.RegistryKey
                        
                        if ($targetRegKey -match "^\(Default\)$|^\(Predeterminado\)$") { 
                            $targetRegKey = "" 
                        }

                        if ($isDeleteProperty) {
                            $keyObj.DeleteValue($targetRegKey, $false)
                            Write-Log -LogLevel INFO -Message "Tweak_Engine: Valor borrado -> [$targetRegKey] en $subPathNet"
                        } 
                        else {
                            $type = switch ($t.RegistryType) {
                                "String"       { [Microsoft.Win32.RegistryValueKind]::String }
                                "ExpandString" { [Microsoft.Win32.RegistryValueKind]::ExpandString }
                                "Binary"       { [Microsoft.Win32.RegistryValueKind]::Binary }
                                "DWord"        { [Microsoft.Win32.RegistryValueKind]::DWord }
                                "MultiString"  { [Microsoft.Win32.RegistryValueKind]::MultiString }
                                "QWord"        { [Microsoft.Win32.RegistryValueKind]::QWord }
                                Default        { [Microsoft.Win32.RegistryValueKind]::DWord }
                            }
                            
                            $safeVal = $valToSet
                            if ($null -eq $safeVal) { $safeVal = "" }

                            # --- CONVERSION ESTRICTA DE TIPOS (Bypass de Overflow en PowerShell) ---
                            try {
                                if ($type -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
                                    # 1. Lo convertimos al tipo sin signo (Acepta hasta 4294967295)
                                    $uintVal = [uint32]$safeVal
                                    # 2. Extraemos los bytes puros y los forzamos a Int32 (-1) evadiendo la matematica de PS
                                    $safeVal = [BitConverter]::ToInt32([BitConverter]::GetBytes($uintVal), 0)
                                } 
                                elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::QWord) {
                                    $uint64Val = [uint64]$safeVal
                                    $safeVal = [BitConverter]::ToInt64([BitConverter]::GetBytes($uint64Val), 0)
                                } 
                                elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::MultiString) {
                                    $safeVal = [string[]]$safeVal
                                } 
                                elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
                                    $safeVal = [byte[]]$safeVal
                                } 
                                elseif ($type -eq [Microsoft.Win32.RegistryValueKind]::String -or $type -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) {
                                    $safeVal = [string]$safeVal
                                }
                            } catch {
                                Write-Log -LogLevel WARN -Message "Tweak_Engine: Fallo en el casting estricto para $($t.Name). Se forzara el tipo nativo. Error: $($_.Exception.Message)"
                            }

                            $keyObj.SetValue($targetRegKey, $safeVal, $type)
                            # Escribimos en LOG el valor crudo solo si es un texto simple para no llenar el log de binarios ilegibles
                            if ($type -eq [Microsoft.Win32.RegistryValueKind]::String -or $type -eq [Microsoft.Win32.RegistryValueKind]::DWord) {
                                Write-Log -LogLevel INFO -Message "Tweak_Engine: Aplicado -> $subPathNet\$targetRegKey = $safeVal"
                            }
                        }
                        $keyObj.Close() # Cerrar siempre para no dejar colmenas trabadas
                    } else {
                        throw "La API de .NET CreateSubKey devolvio nulo al intentar instanciar la ruta."
                    }

                    # --- DEVOLVER PERMISOS ---
                    Restore-KeyOwner -KeyPath $psPath

                    # Actualizar UI
                    if ($Mode -eq 'Apply') {
                         $it.SubItems[1].Text = "ACTIVO"
                         $it.ForeColor = [System.Drawing.Color]::Cyan
                    } else {
                         $it.SubItems[1].Text = "RESTAURADO"
                         $it.ForeColor = [System.Drawing.Color]::LightGray
                    }
                    $it.Checked = $false 
                    $success++
                    
                } catch {
                    $errors++
                    $it.SubItems[1].Text = "ERROR"
                    $it.ForeColor = [System.Drawing.Color]::Red
                    Write-Log -LogLevel ERROR -Message "Tweak_Engine: Falla critica procesando $($t.Name) ($Mode) - $($_.Exception.Message)"
                }
            } else {
                Write-Log -LogLevel ERROR -Message "Tweak_Engine: No se pudo traducir la ruta Offline para el Tweak: $($t.Name)"
                $errors++
            }
        }
        
        Write-Log -LogLevel ACTION -Message "Tweak_Engine: Proceso finalizado. Exitos: $success | Errores: $errors"

        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $lblStatus.Text = "Proceso finalizado."
        [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nExitos: $success`nErrores: $errors", "Informe", 'OK', 'Information')
    }

    # Eventos de Botones Globales
    $btnApplyGlobal.Add_Click({ & $ProcessChanges -Mode 'Apply' })
    $btnRestoreGlobal.Add_Click({ & $ProcessChanges -Mode 'Restore' })

    # Cierre Seguro
    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Estas seguro de que deseas salir?`nSe guardaran y desmontaran los Hives del registro.", 
            "Confirmar Salida", 
            [System.Windows.Forms.MessageBoxButtons]::YesNo, 
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -eq 'No') {
            $_.Cancel = $true
        } else {
            $lblStatus.Text = "Sincronizando y desmontando Hives... Por favor espere."
            $form.Refresh()
            Start-Sleep -Milliseconds 500 
            Unmount-Hives 
        }
    })
    
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $globalListViews.Clear()
    $globalListViews = $null
    [GC]::Collect()
}

# =================================================================
#  Modulo GUI de Despliegue (WIM -> VHD/VHDX Bootable)
# =================================================================
# --- HELPER PRIVADO: Obtener letra de unidad libre (Z -> A) ---
function Get-UnusedDriveLetter {
    # Obtenemos las letras usadas actualmente
    $used = Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Name
    # Alfabeto invertido (preferimos usar Z, Y, X para montajes temporales)
    $alphabet = [char[]](90..65) 
    
    foreach ($letter in $alphabet) {
        if ($used -notcontains $letter) {
            return $letter
        }
    }
    throw "No hay letras de unidad disponibles para montar las particiones temporales."
}

function Show-Deploy-To-VHD-GUI {
    # 1. Verificacion de Requisitos
    if (-not (Get-Command "New-VHD" -ErrorAction SilentlyContinue)) {
        [System.Windows.Forms.MessageBox]::Show("Este modulo requiere Hyper-V o PowerShell Storage module.", "Error", 'OK', 'Error')
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Despliegue WIM a VHDX"
    $form.Size = New-Object System.Drawing.Size(720, 600)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # --- UI SECTIONS ---
    $grpSource = New-Object System.Windows.Forms.GroupBox
    $grpSource.Text = " 1. Imagen de Origen "
    $grpSource.Location = New-Object System.Drawing.Point(20, 15)
	$grpSource.Size = New-Object System.Drawing.Size(660, 120)
	$grpSource.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpSource)

    $txtWim = New-Object System.Windows.Forms.TextBox
    $txtWim.Location = "20, 25"
	$txtWim.Size = "540, 23"
	$txtWim.ReadOnly = $true
	$txtWim.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$txtWim.ForeColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($txtWim)

    $btnBrowseWim = New-Object System.Windows.Forms.Button
    $btnBrowseWim.Text = "..."
	$btnBrowseWim.Location = "570, 24"
	$btnBrowseWim.Size = "70, 25"
	$btnBrowseWim.BackColor = [System.Drawing.Color]::Silver
	$btnBrowseWim.FlatStyle = "Flat"
    $grpSource.Controls.Add($btnBrowseWim)

    $lblIdx = New-Object System.Windows.Forms.Label
    $lblIdx.Text = "Indice:"
	$lblIdx.Location = "20, 60"
	$lblIdx.AutoSize = $true
	$lblIdx.ForeColor = [System.Drawing.Color]::Silver
    $grpSource.Controls.Add($lblIdx)

    $cmbIndex = New-Object System.Windows.Forms.ComboBox
    $cmbIndex.Location = "20, 80"
	$cmbIndex.Size = "620, 25"
	$cmbIndex.DropDownStyle = "DropDownList"
	$cmbIndex.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$cmbIndex.ForeColor = [System.Drawing.Color]::White
    $grpSource.Controls.Add($cmbIndex)

    $grpDest = New-Object System.Windows.Forms.GroupBox
    $grpDest.Text = " 2. Configuracion de Disco y Particiones "
    $grpDest.Location = New-Object System.Drawing.Point(20, 150)
	$grpDest.Size = New-Object System.Drawing.Size(660, 220)
	$grpDest.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpDest)

    $lblVhdPath = New-Object System.Windows.Forms.Label
    $lblVhdPath.Text = "Ruta VHDX:"
	$lblVhdPath.Location = "20, 25"
	$lblVhdPath.AutoSize = $true
	$lblVhdPath.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblVhdPath)

    $txtVhd = New-Object System.Windows.Forms.TextBox
    $txtVhd.Location = "20, 45"
	$txtVhd.Size = "540, 23"
	$txtVhd.ReadOnly = $true
	$txtVhd.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
	$txtVhd.ForeColor = [System.Drawing.Color]::White
    $grpDest.Controls.Add($txtVhd)

    $btnBrowseVhd = New-Object System.Windows.Forms.Button
    $btnBrowseVhd.Text = "Guardar"
	$btnBrowseVhd.Location = "570, 44"
	$btnBrowseVhd.Size = "70, 25"
	$btnBrowseVhd.BackColor = [System.Drawing.Color]::Silver
	$btnBrowseVhd.FlatStyle = "Flat"
    $grpDest.Controls.Add($btnBrowseVhd)

    $lblSize = New-Object System.Windows.Forms.Label
    $lblSize.Text = "Size Total (GB):"
	$lblSize.Location = "20, 85"
	$lblSize.AutoSize = $true
    $grpDest.Controls.Add($lblSize)

    $numSize = New-Object System.Windows.Forms.NumericUpDown
    $numSize.Location = "140, 83"
	$numSize.Size = "80, 25"
	$numSize.Minimum = 10
	$numSize.Maximum = 10000
	$numSize.Value = 60
    $grpDest.Controls.Add($numSize)

    $chkDynamic = New-Object System.Windows.Forms.CheckBox
    $chkDynamic.Text = "Expansion Dinamica"
	$chkDynamic.Location = "250, 85"
	$chkDynamic.AutoSize = $true
	$chkDynamic.Checked = $true
    $grpDest.Controls.Add($chkDynamic)

    $chkUEFI = New-Object System.Windows.Forms.CheckBox
    $chkUEFI.Text = "Esquema GPT (UEFI)"
	$chkUEFI.Location = "420, 85"
	$chkUEFI.AutoSize = $true
	$chkUEFI.Checked = $true
	$chkUEFI.ForeColor = [System.Drawing.Color]::LightGreen
    $grpDest.Controls.Add($chkUEFI)

    $lblPartInfo = New-Object System.Windows.Forms.Label
    $lblPartInfo.Text = "--- Size de Particiones de Sistema ---"
    $lblPartInfo.Location = "20, 125"
	$lblPartInfo.AutoSize = $true
	$lblPartInfo.ForeColor = [System.Drawing.Color]::Silver
    $grpDest.Controls.Add($lblPartInfo)

    $lblEfiSize = New-Object System.Windows.Forms.Label
    $lblEfiSize.Text = "EFI (MB):"
	$lblEfiSize.Location = "20, 155"
	$lblEfiSize.AutoSize = $true
    $grpDest.Controls.Add($lblEfiSize)

    $numEfiSize = New-Object System.Windows.Forms.NumericUpDown
    $numEfiSize.Location = "140, 153"
	$numEfiSize.Size = "80, 25"
	$numEfiSize.Minimum = 50
	$numEfiSize.Maximum = 2000
	$numEfiSize.Value = 100
    $grpDest.Controls.Add($numEfiSize)

    $lblMsrSize = New-Object System.Windows.Forms.Label
    $lblMsrSize.Text = "MSR (MB):"
	$lblMsrSize.Location = "250, 155"
	$lblMsrSize.AutoSize = $true
    $grpDest.Controls.Add($lblMsrSize)

    $numMsrSize = New-Object System.Windows.Forms.NumericUpDown
    $numMsrSize.Location = "330, 153"
	$numMsrSize.Size = "80, 25"
	$numMsrSize.Minimum = 0
	$numMsrSize.Maximum = 500
	$numMsrSize.Value = 16
    $grpDest.Controls.Add($numMsrSize)

    $chkUEFI.Add_CheckedChanged({
        if ($chkUEFI.Checked) {
            $numEfiSize.Value = 100
            $lblMsrSize.Visible = $true; $numMsrSize.Visible = $true
            $lblEfiSize.Text = "EFI (MB):"
        } else {
            $numEfiSize.Value = 500
            $lblMsrSize.Visible = $false; $numMsrSize.Visible = $false
            $lblEfiSize.Text = "Sys. Rsvd (MB):"
        }
    })

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Esperando configuracion..."
	$lblStatus.Location = "20, 520"
	$lblStatus.AutoSize = $true
	$lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $btnDeploy = New-Object System.Windows.Forms.Button
    $btnDeploy.Text = "CREAR VHDX Y DESPLEGAR"
    $btnDeploy.Location = New-Object System.Drawing.Point(380, 440)
	$btnDeploy.Size = New-Object System.Drawing.Size(300, 50)
	$btnDeploy.BackColor = [System.Drawing.Color]::SeaGreen
	$btnDeploy.ForeColor = [System.Drawing.Color]::White
	$btnDeploy.FlatStyle = "Flat"
	$btnDeploy.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnDeploy)

    $btnBrowseWim.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog; $ofd.Filter = "Imagenes (*.wim, *.esd)|*.wim;*.esd"
        if ($ofd.ShowDialog() -eq 'OK') {
            $txtWim.Text = $ofd.FileName
            $cmbIndex.Items.Clear()
            $lblStatus.Text = "Leyendo..."; $form.Refresh()
            try {
                $info = Get-WindowsImage -ImagePath $ofd.FileName
                foreach ($img in $info) { $cmbIndex.Items.Add("[$($img.ImageIndex)] $($img.ImageName)") }
                if ($cmbIndex.Items.Count -gt 0) { $cmbIndex.SelectedIndex = 0 }
                $lblStatus.Text = "WIM Cargado."
            } catch { $lblStatus.Text = "Error leyendo WIM." }
        }
    })

    $btnBrowseVhd.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog; $sfd.Filter = "VHDX (*.vhdx)|*.vhdx|VHD (*.vhd)|*.vhd"
        if ($sfd.ShowDialog() -eq 'OK') { $txtVhd.Text = $sfd.FileName }
    })

    # --- LOGICA CORE DE DESPLIEGUE ---
    $btnDeploy.Add_Click({
        if (-not $txtWim.Text -or -not $txtVhd.Text) { [System.Windows.Forms.MessageBox]::Show("Rutas vacias.", "Error", 'OK', 'Error'); return }
        
        $vhdPath = $txtVhd.Text
        $wimPath = $txtWim.Text
        $idx = $cmbIndex.SelectedIndex + 1
        $totalSize = [long]$numSize.Value * 1GB
        $isDynamic = $chkDynamic.Checked
        $isGPT = $chkUEFI.Checked
        $sizeBootMB = [int]$numEfiSize.Value
        $sizeMsrMB  = [int]$numMsrSize.Value

        if (Test-Path $vhdPath) {
            if ([System.Windows.Forms.MessageBox]::Show("El VHD existe. Se borrara todo su contenido.`nContinuar?", "Confirmar", 'YesNo', 'Warning') -eq 'No') { return }
            try { 
                Remove-Item $vhdPath -Force -ErrorAction Stop 
                Write-Log -LogLevel ACTION -Message "DEPLOY_VHD: VHD existente eliminado ($vhdPath)."
            } catch { 
                [System.Windows.Forms.MessageBox]::Show("No se pudo borrar el archivo. Esta en uso?", "Error", 'OK', 'Error')
                return 
            }
        }

        $btnDeploy.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $lblStatus.Text = "Creando VHD..."
            $form.Refresh()
            
            Write-Log -LogLevel ACTION -Message "DEPLOY_VHD: Iniciando creacion. Origen: WIM Idx $idx | Destino: $vhdPath"
            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Specs -> Tamaño: $([math]::Round($totalSize/1GB, 2))GB | Dinamico: $isDynamic | Estilo: $(if($isGPT){'GPT'}else{'MBR'})"

            if ($isDynamic) { New-VHD -Path $vhdPath -SizeBytes $totalSize -Dynamic -ErrorAction Stop | Out-Null }
            else { New-VHD -Path $vhdPath -SizeBytes $totalSize -Fixed -ErrorAction Stop | Out-Null }

            $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
            $diskNum = $disk.Number
            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Disco virtual creado y montado como Disco $diskNum."

            $partStyle = if ($isGPT) { "GPT" } else { "MBR" }
            Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop

            $driveLetterSystem = $null
            $driveLetterBoot = $null

            # --- PARTICIONADO ROBUSTO ---
            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Formateando y asignando particiones..."
            if ($isGPT) {
                # GPT: EFI + MSR + WINDOWS
                $lblStatus.Text = "Particionando GPT..."
                
                # 1. EFI
                $pEFI = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -ErrorAction Stop
                Format-Volume -Partition $pEFI -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
                if (-not $pEFI.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pEFI -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterBoot = "$($freeLet):"
                } else { $driveLetterBoot = "$($pEFI.DriveLetter):" }

                # 2. MSR
                if ($sizeMsrMB -gt 0) {
                    New-Partition -DiskNumber $diskNum -Size ($sizeMsrMB * 1MB) -GptType "{e3c9e316-0b5c-4db8-817d-f92df00215ae}" -ErrorAction Stop | Out-Null
                }

                # 3. Windows
                $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                Format-Volume -Partition $pWin -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
                if (-not $pWin.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pWin -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterSystem = "$($freeLet):"
                } else { $driveLetterSystem = "$($pWin.DriveLetter):" }

            } else {
                # MBR: SYSTEM RESERVED + WINDOWS
                $lblStatus.Text = "Particionando MBR..."
                
                # 1. System Reserved
                $pBoot = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) -IsActive -ErrorAction Stop
                Format-Volume -Partition $pBoot -FileSystem NTFS -NewFileSystemLabel "System Reserved" -Confirm:$false | Out-Null
                if (-not $pBoot.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pBoot -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterBoot = "$($freeLet):"
                } else { $driveLetterBoot = "$($pBoot.DriveLetter):" }

                # 2. Windows
                $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                Format-Volume -Partition $pWin -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
                if (-not $pWin.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pWin -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterSystem = "$($freeLet):"
                } else { $driveLetterSystem = "$($pWin.DriveLetter):" }
            }

            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Particiones listas. Boot ($driveLetterBoot), Sistema ($driveLetterSystem)."

            # 4. APLICACION IMAGEN
            $lblStatus.Text = "Desplegando imagen a $driveLetterSystem..."
            $form.Refresh()
            
            Write-Log -LogLevel ACTION -Message "DEPLOY_VHD: Aplicando imagen (Expand-WindowsImage) hacia $driveLetterSystem..."
            Expand-WindowsImage -ImagePath $wimPath -Index $idx -ApplyPath $driveLetterSystem -ErrorAction Stop

            # 5. BOOT
            $lblStatus.Text = "Configurando arranque..."
            $fw = if ($isGPT) { "UEFI" } else { "BIOS" }
            Write-Log -LogLevel ACTION -Message "DEPLOY_VHD: Configurando gestor de arranque nativo ($fw) con BCDBoot..."
            
            $proc = Start-Process "bcdboot.exe" -ArgumentList "$driveLetterSystem\Windows /s $driveLetterBoot /f $fw" -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0) { throw "BCDBOOT fallo (Codigo de salida: $($proc.ExitCode))" }

            # 6. FIN
            $lblStatus.Text = "Desmontando..."
            $form.Refresh()
            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Desmontando VHD del sistema."
            Dismount-VHD -Path $vhdPath -ErrorAction Stop
            
            $lblStatus.Text = "Listo."
            Write-Log -LogLevel INFO -Message "DEPLOY_VHD: *** DESPLIEGUE FINALIZADO CON EXITO ***"
            [System.Windows.Forms.MessageBox]::Show("Despliegue completado con exito.", "Exito", 'OK', 'Information')

        } catch {
            $lblStatus.Text = "Error Critico."
            Write-Log -LogLevel ERROR -Message "DEPLOY_VHD: FALLO CRITICO - $($_.Exception.Message)"
            Write-Warning "Fallo despliegue: $_"
            [System.Windows.Forms.MessageBox]::Show("Error Critico:`n$_", "Error", 'OK', 'Error')
            try { 
                Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue 
                Write-Log -LogLevel INFO -Message "DEPLOY_VHD: Limpieza de emergencia (Desmontaje) ejecutada."
            } catch {}
        } finally {
            $btnDeploy.Enabled = $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # 1. Configuracion del motor de ToolTips
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 8000   # Mantiene el mensaje visible 8 segundos
    $toolTip.InitialDelay = 500    # Tarda 0.5s en aparecer (evita parpadeos al mover rapido)
    $toolTip.ReshowDelay = 500     # Tiempo para reaparecer en otro control
    $toolTip.ShowAlways = $true    # Mostrar incluso si la ventana no tiene el foco
    $toolTip.IsBalloon = $false    # $true para estilo "globo", $false para rectangulo clasico

    # 2. Asignacion de descripciones a los controles existentes

    # --- Grupo Origen ---
    $toolTip.SetToolTip($btnBrowseWim, "Haz clic para seleccionar el archivo de imagen (.wim o .esd) que contiene el instalador de Windows.")
    $toolTip.SetToolTip($cmbIndex, "Selecciona la edicion de Windows a instalar (ej. Home, Pro, Enterprise).`nCada indice es una version diferente dentro del mismo archivo.")

    # --- Grupo Destino ---
    $toolTip.SetToolTip($btnBrowseVhd, "Define donde se guardara el nuevo archivo de disco virtual (.vhdx o .vhd).")
    $toolTip.SetToolTip($txtVhd, "Ruta completa del archivo de disco virtual de destino.")
    
    # --- Configuracion de Disco ---
    $toolTip.SetToolTip($numSize, "Size maximo que podra tener el disco virtual (en Gigabytes).")
    
    $toolTip.SetToolTip($chkDynamic, "Marcado (Recomendado): El archivo empieza pequeño y crece segun guardes datos.`nDesmarcado (Fixed): El archivo ocupa todo el Size (GB) inmediatamente (Mejor rendimiento, ocupa mas espacio).")
    
    $toolTip.SetToolTip($chkUEFI, "Marcado (GPT): Para PCs modernos con UEFI. Crea particiones EFI y MSR.`nDesmarcado (MBR): Para PCs antiguos con BIOS Legacy. Crea particion 'System Reserved'.")

    # --- Configuracion de Particiones (Avanzado) ---
    $toolTip.SetToolTip($numEfiSize, "Size de la particion de arranque (EFI o System Reserved).`n100MB es el estandar recomendado.")
    $toolTip.SetToolTip($numMsrSize, "Size de la particion MSR (Microsoft Reserved).`nSolo aplica en discos GPT/UEFI.")

    # --- Boton de Accion ---
    $toolTip.SetToolTip($btnDeploy, "ADVERTENCIA: Iniciara el proceso de creacion, formateo y aplicacion de imagen.`nSi el archivo VHD existe, sera sobrescrito.")

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  Modulo GUI de Generador de ISO
# =================================================================
function Show-IsoMaker-GUI {
    # 1. Busqueda de Dependencia (Rutas del ADK oficial y herramientas locales)
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    
    $adkPaths = @(
        "$scriptPath\Tools\oscdimg.exe",
        "$scriptPath\..\Tools\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\11\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
    )

    $oscdimgExe = $null
    foreach ($path in $adkPaths) {
        if (Test-Path $path) { 
            $oscdimgExe = $path 
            break 
        }
    }

    # Fallback 1: Comprobar si el usuario lo añadio al PATH del sistema
    if (-not $oscdimgExe) {
        $cmd = Get-Command "oscdimg.exe" -ErrorAction SilentlyContinue
        if ($cmd) { $oscdimgExe = $cmd.Source }
    }

    # Fallback 2: Seleccion manual del usuario (Tu bloque de codigo)
    if (-not $oscdimgExe) {
        Add-Type -AssemblyName System.Windows.Forms
        $res = [System.Windows.Forms.MessageBox]::Show(
            "No se encontro 'oscdimg.exe' en las rutas estandar del ADK.`n`nDeseas buscar el ejecutable manualmente?", 
            "Falta Dependencia", 
            'YesNo', 
            'Warning'
        )
        
        if ($res -eq 'Yes') {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Oscdimg (oscdimg.exe)|oscdimg.exe"
            if ($ofd.ShowDialog() -eq 'OK') { 
                $oscdimgExe = $ofd.FileName 
            } else { 
                return # El usuario abrio el dialogo pero le dio a Cancelar. Abortamos silenciosamente.
            }
        } else { 
            # Fallback 3: El usuario dijo "No". Disparamos el fallo elegante exigiendo el ADK.
            $msg = "Para utilizar el Generador de ISO, es un requisito estricto contar con 'oscdimg.exe'.`n`n" +
                   "Por favor, descarga e instala el Windows Assessment and Deployment Kit (ADK) " +
                   "(especificamente las 'Deployment Tools') desde la pagina oficial de Microsoft y vuelve a intentarlo."
                   
            [System.Windows.Forms.MessageBox]::Show($msg, "Requisito Faltante: Windows ADK", 'OK', 'Error')
            return # Abortamos la creacion de la GUI
        }
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # --- GUI SETUP ---
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Generador de ISO (BIOS/UEFI)"
    $form.Size = New-Object System.Drawing.Size(700, 720)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # --- GRUPO 1: CONFIGURACION ---
    $grpCfg = New-Object System.Windows.Forms.GroupBox
    $grpCfg.Text = " 1. Configuracion de la Imagen "
    $grpCfg.Location = "15, 10"
    $grpCfg.Size = "650, 160"
    $grpCfg.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($grpCfg)

    $lblSrc = New-Object System.Windows.Forms.Label
    $lblSrc.Text = "Carpeta Origen (Debe contener boot, efi, sources...):"
    $lblSrc.Location = "15, 25"
	$lblSrc.AutoSize=$true
	$lblSrc.ForeColor=[System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblSrc)

    $txtSrc = New-Object System.Windows.Forms.TextBox
    $txtSrc.Location = "15, 45"
	$txtSrc.Size = "530, 23"
    $grpCfg.Controls.Add($txtSrc)

    $btnSrc = New-Object System.Windows.Forms.Button
    $btnSrc.Text = "..."
	$btnSrc.Location = "555, 43"
	$btnSrc.Size = "80, 25"
    $btnSrc.BackColor=[System.Drawing.Color]::Silver
	$btnSrc.FlatStyle="Flat"
    $grpCfg.Controls.Add($btnSrc)

    $lblDst = New-Object System.Windows.Forms.Label
    $lblDst.Text = "Archivo ISO Destino:"
    $lblDst.Location = "15, 75"
	$lblDst.AutoSize=$true
	$lblDst.ForeColor=[System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblDst)

    $txtDst = New-Object System.Windows.Forms.TextBox
    $txtDst.Location = "15, 95"
	$txtDst.Size = "530, 23"
    $grpCfg.Controls.Add($txtDst)
    
    $btnDst = New-Object System.Windows.Forms.Button
    $btnDst.Text = "Guardar"
	$btnDst.Location = "555, 93"
	$btnDst.Size = "80, 25"
    $btnDst.BackColor=[System.Drawing.Color]::Silver
	$btnDst.FlatStyle="Flat"
    $grpCfg.Controls.Add($btnDst)

    $lblLabel = New-Object System.Windows.Forms.Label
    $lblLabel.Text = "Etiqueta de Volumen (Label):"
    $lblLabel.Location = "15, 130"
	$lblLabel.AutoSize=$true
	$lblLabel.ForeColor=[System.Drawing.Color]::Silver
    $grpCfg.Controls.Add($lblLabel)

    $txtLabel = New-Object System.Windows.Forms.TextBox
    $txtLabel.Location = "180, 127"
	$txtLabel.Size = "200, 23"
	$txtLabel.Text = "WINDOWS_CUSTOM"
    $grpCfg.Controls.Add($txtLabel)

    # --- GRUPO 2: AUTOMATIZACION ---
    $grpAuto = New-Object System.Windows.Forms.GroupBox
    $grpAuto.Text = " 2. Automatizacion OOBE (Opcional) "
    $grpAuto.Location = "15, 180"
    $grpAuto.Size = "650, 100"
    $grpAuto.ForeColor = [System.Drawing.Color]::Orange
    $form.Controls.Add($grpAuto)

    $lblAutoInfo = New-Object System.Windows.Forms.Label
    $lblAutoInfo.Text = "Inyectar 'autounattend.xml' en la raiz del medio:"
    $lblAutoInfo.Location = "15, 25"
	$lblAutoInfo.AutoSize=$true
	$lblAutoInfo.ForeColor=[System.Drawing.Color]::Silver
    $grpAuto.Controls.Add($lblAutoInfo)

    $txtUnattend = New-Object System.Windows.Forms.TextBox
    $txtUnattend.Location = "15, 45"
	$txtUnattend.Size = "430, 23"
    $grpAuto.Controls.Add($txtUnattend)
    
    $btnUnattend = New-Object System.Windows.Forms.Button
    $btnUnattend.Text = "Buscar XML"
	$btnUnattend.Location = "455, 43"
	$btnUnattend.Size = "80, 25"
    $btnUnattend.BackColor=[System.Drawing.Color]::Silver
	$btnUnattend.FlatStyle="Flat"
	$btnUnattend.ForeColor=[System.Drawing.Color]::Black
    $grpAuto.Controls.Add($btnUnattend)

    $lnkWeb = New-Object System.Windows.Forms.LinkLabel
    $lnkWeb.Text = "Generador Online (schneegans.de)"
	$lnkWeb.Location = "15, 75"
	$lnkWeb.AutoSize = $true
	$lnkWeb.LinkColor = [System.Drawing.Color]::Yellow
    $grpAuto.Controls.Add($lnkWeb)

    # LOG
    $txtLog = New-Object System.Windows.Forms.TextBox
    $txtLog.Location = "15, 290"
	$txtLog.Size = "650, 300"
    $txtLog.Multiline = $true
	$txtLog.ScrollBars = "Vertical"
	$txtLog.ReadOnly = $true
    $txtLog.BackColor = [System.Drawing.Color]::Black
	$txtLog.ForeColor = [System.Drawing.Color]::Lime
    $txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
    $txtLog.Text = "Esperando configuracion...`r`nMotor: $oscdimgExe"
    $form.Controls.Add($txtLog)

    $btnMake = New-Object System.Windows.Forms.Button
    $btnMake.Text = "CREAR ISO BOOTEABLE"
    $btnMake.Location = "200, 615"
	$btnMake.Size = "300, 40"
    $btnMake.BackColor = [System.Drawing.Color]::SeaGreen
	$btnMake.ForeColor = [System.Drawing.Color]::White
    $btnMake.FlatStyle = "Flat"
	$btnMake.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnMake)

    # --- EVENTOS ---
    $btnSrc.Add_Click({
        $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecciona carpeta raiz de Windows (donde estan setup.exe, boot, efi...)"
        if ($fbd.ShowDialog() -eq 'OK') { 
            $txtSrc.Text = $fbd.SelectedPath 
            
            # --- LOGICA DE AUTO-ETIQUETA (NATIVA Y BLINDADA V2) ---
            $installWim = Join-Path $fbd.SelectedPath "sources\install.wim"
            $installEsd = Join-Path $fbd.SelectedPath "sources\install.esd"
            $targetImage = $null
            
            if (Test-Path -LiteralPath $installWim) { $targetImage = $installWim }
            elseif (Test-Path -LiteralPath $installEsd) { $targetImage = $installEsd }
            
            if ($targetImage) {
                $txtLog.AppendText("`r`n[INFO] Analizando metadatos (Motor DISM Nativo)...")
                $form.Refresh()
                
                try {
                    # 1. Determinar PREFIJO usando el cmdlet rapido
                    $prefix = "CCCOMA"
                    $allImages = Get-WindowsImage -ImagePath $targetImage -ErrorAction SilentlyContinue
                    if ($allImages) {
                        $allNames = $allImages.ImageName -join " "
                        if ($allNames -match "Server") { $prefix = "SSS" }
                        elseif ($allNames -match "Enterprise" -or $allNames -match "LTSC") { $prefix = "CCBOMA" }
                    }

                    # 2. Extraer Arquitectura e Idioma leyendo la consola cruda
                    $dismInfo = dism.exe /Get-ImageInfo /ImageFile:"$targetImage" /Index:1 /English
                    
                    # Unimos todas las lineas en un solo gran bloque de texto
                    $dismText = $dismInfo -join "`r`n"
                    
                    # Extraer Arquitectura
                    $archStr = "X64" # Default
                    if ($dismText -match "Architecture\s*:\s*x86") { $archStr = "X86" }
                    elseif ($dismText -match "Architecture\s*:\s*arm64") { $archStr = "ARM64" }
                    
                    # Extraer Idioma (Con soporte para saltos de linea "\r?\n")
                    $langStr = "EN-US" # Default
                    if ($dismText -match "Languages?\s*:\s*\r?\n\s*([a-zA-Z]{2}-[a-zA-Z]{2,3})") {
                        $langStr = $matches[1].ToUpper()
                    }

                    # 3. Ensamblar la Etiqueta Oficial
                    $txtLabel.Text = "$($prefix)_$($archStr)FRE_$($langStr)_DV9"
                    
                    $txtLog.AppendText("`r`n[EXITO] Etiqueta Oficial Generada: $($txtLabel.Text)")
                    $txtLog.AppendText("`r`n[INFO] Familia: $prefix | Arch: $archStr | Idioma: $langStr")
                    
                } catch {
                    $txtLog.AppendText("`r`n[WARN] Error leyendo metadatos. Usando etiqueta estandar.")
                    $txtLabel.Text = "CCCOMA_X64FRE_ES-ES_DV9"
                }
            } else {
                $txtLog.AppendText("`r`n[WARN] No se encontro install.wim/esd. Usando etiqueta base.")
                $txtLabel.Text = "WINDOWS_CUSTOM"
            }
        }
    })
    $btnDst.Add_Click({
        $sfd = New-Object System.Windows.Forms.SaveFileDialog
		$sfd.Filter = "Imagen ISO (*.iso)|*.iso"
        if ($sfd.ShowDialog() -eq 'OK') { $txtDst.Text = $sfd.FileName }
    })
    $btnUnattend.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
		$ofd.Filter = "XML Files (*.xml)|*.xml"
        if ($ofd.ShowDialog() -eq 'OK') { $txtUnattend.Text = $ofd.FileName }
    })
    $lnkWeb.Add_Click({ Start-Process "https://schneegans.de/windows/unattend-generator/" })

    # --- LOGICA SEGURA (METODO SINCRONO) ---
    $btnMake.Add_Click({
        $src = $txtSrc.Text; $iso = $txtDst.Text; $label = $txtLabel.Text; $xmlPath = $txtUnattend.Text

        if (-not $src -or -not $iso) { 
            Write-Log -LogLevel WARN -Message "ISO_Maker: El usuario intento compilar sin definir rutas de origen o destino."
            [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error')
            return 
        }
        
        $biosBoot = Join-Path $src "boot\etfsboot.com"
        $uefiBoot = Join-Path $src "efi\microsoft\boot\efisys.bin"

        if (-not (Test-Path $biosBoot)) { 
            Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo estructural. Falta boot\etfsboot.com en la ruta de origen ($src)."
            [System.Windows.Forms.MessageBox]::Show("No se encuentra boot\etfsboot.com.", "Error Estructural", 'OK', 'Error')
            return 
        }

        if (-not [string]::IsNullOrWhiteSpace($xmlPath) -and (Test-Path $xmlPath)) {
            Write-Log -LogLevel INFO -Message "ISO_Maker: Archivo Unattend.xml detectado. Inyectando en la raiz de la ISO."
            try { Copy-Item -Path $xmlPath -Destination (Join-Path $src "autounattend.xml") -Force -ErrorAction Stop }
            catch { 
                Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo al copiar el archivo XML a la raiz - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $_", "Error", 'OK', 'Error')
                return 
            }
        }

        $btnMake.Enabled = $false; $grpCfg.Enabled = $false; $grpAuto.Enabled = $false
        $txtLog.Text = "--- INICIO DEL LOG ---`r`n"
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Argumentos
        $bootArg = "-bootdata:2#p0,e,b`"{0}`"#pEF,e,b`"{1}`"" -f $biosBoot, $uefiBoot
        $allArgs = '-m -o -u2 -udfver102 -l"{0}" {1} "{2}" "{3}"' -f $label, $bootArg, $src, $iso

        Write-Log -LogLevel ACTION -Message "ISO_Maker: Iniciando compilacion de ISO..."
        Write-Log -LogLevel INFO -Message "ISO_Maker: Etiqueta: [$label] | Origen: [$src] | Destino: [$iso]"
        Write-Log -LogLevel INFO -Message "ISO_Maker: Argumentos CMD: oscdimg.exe $allArgs"

        $txtLog.AppendText("COMANDO:`r`noscdimg.exe $allArgs`r`n----------------`r`n")
        $form.Refresh() # Forzar pintado antes de iniciar

        try {
            $pInfo = New-Object System.Diagnostics.ProcessStartInfo
            $pInfo.FileName = $oscdimgExe
            $pInfo.Arguments = $allArgs
            $pInfo.RedirectStandardOutput = $true
            $pInfo.RedirectStandardError = $true
            $pInfo.UseShellExecute = $false
            $pInfo.CreateNoWindow = $true

            $proc = New-Object System.Diagnostics.Process
            $proc.StartInfo = $pInfo
            
            if ($proc.Start()) {
                # --- BUCLE DE LECTURA SEGURO (SIN EVENTOS) ---
                while (-not $proc.HasExited) {
                    # Leer Output
                    while ($proc.StandardOutput.Peek() -gt -1) {
                        $line = $proc.StandardOutput.ReadLine()
                        if (-not [string]::IsNullOrWhiteSpace($line)) {
                            $txtLog.AppendText($line + "`r`n")
                            $txtLog.ScrollToCaret()
                        }
                    }
                    # Leer Error (Filtrado)
                    while ($proc.StandardError.Peek() -gt -1) {
                        $errLine = $proc.StandardError.ReadLine()
                        
                        if ([string]::IsNullOrWhiteSpace($errLine)) {
                            $txtLog.AppendText($errLine + "`r`n")
                            continue
                        }

                        if ($errLine -match "% complete" -or $errLine -match "Scanning source") {
                            $txtLog.AppendText($errLine + "`r`n") 
                        } 
                        else {
                            $txtLog.AppendText("[ERR] " + $errLine + "`r`n")
                        }
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 50
                }
                
                # Lectura final remanente
                $remOut = $proc.StandardOutput.ReadToEnd(); if($remOut){ $txtLog.AppendText($remOut) }
                $remErr = $proc.StandardError.ReadToEnd(); if($remErr){ $txtLog.AppendText($remErr) }
                
                $exitCode = $proc.ExitCode
                $proc.Dispose()

                try {
                    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                    $logFileName = "ISO_Build_$timestamp.log"
                    $logPath = Join-Path $script:logDir $logFileName
                    
                    $txtLog.Text | Out-File -FilePath $logPath -Encoding utf8 -Force
                    
                    $txtLog.AppendText("`r`n[INFO] Log guardado en: $logFileName")
                    Write-Log -LogLevel INFO -Message "ISO_Maker: Archivo de volcado individual creado en: $logPath"
                } catch {
                    $txtLog.AppendText("`r`n[WARN] No se pudo guardar el archivo de log.")
                    Write-Log -LogLevel WARN -Message "ISO_Maker: No se pudo guardar el archivo .log individual de oscdimg."
                }

                if ($exitCode -eq 0) {
                    Write-Log -LogLevel INFO -Message "ISO_Maker: Compilacion de ISO completada con EXITO."
                    $txtLog.AppendText("`r`n[EXITO] ISO Creada.")
                    [System.Windows.Forms.MessageBox]::Show("ISO creada en:`n$iso", "Exito", 'OK', 'Information')
                } else {
                    Write-Log -LogLevel ERROR -Message "ISO_Maker: oscdimg fallo con codigo de salida: $exitCode"
                    $txtLog.AppendText("`r`n[ERROR] Codigo: $exitCode")
                    [System.Windows.Forms.MessageBox]::Show("Fallo la creacion. Revisa el Log para detalles.", "Error", 'OK', 'Error')
                }
            } else { 
                Write-Log -LogLevel ERROR -Message "ISO_Maker: Fallo critico. El proceso oscdimg.exe no pudo iniciarse."
                throw "No inicio oscdimg" 
            }

        } catch {
            Write-Log -LogLevel ERROR -Message "ISO_Maker: Excepcion controlada de aplicacion - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show("Excepcion: $_", "Crash", 'OK', 'Error')
            $txtLog.AppendText("`r`nEXCEPCION: $_")
        } finally {
            if (-not $form.IsDisposed) {
                $btnMake.Enabled = $true; $grpCfg.Enabled = $true; $grpAuto.Enabled = $true
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
    [GC]::Collect()
}

# =================================================================
#  Modulo de Inyeccion Languages
# =================================================================
function Inject-WinReLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$InstallMountDir,
        [Parameter(Mandatory=$true)][string]$WinPeLangPackPath, # Ruta a la carpeta con los .cab de WinPE para el idioma
        [Parameter(Mandatory=$true)][string]$LangCode           # Ej: 'es-MX' o 'es-ES'
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Iniciando inyeccion del idioma [$LangCode] en el entorno de recuperacion."

    $winRePath = Join-Path $InstallMountDir "Windows\System32\Recovery\winre.wim"
    $tempWorkDir = Join-Path $env:TEMP "DeltaPack_WinRE_Workspace"
    $winReMountDir = Join-Path $tempWorkDir "Mount"
    $winReTempPath = Join-Path $tempWorkDir "winre.wim"

    # 1. Validacion de existencia
    if (-not (Test-Path $winRePath)) {
        Write-Log -LogLevel WARN -Message "LangInjector[WinRE]: No se encontro winre.wim en la ruta estandar. Es posible que la imagen original lo haya eliminado."
        Write-Warning "No se encontro winre.wim en la imagen. Se omitira la inyeccion de recuperacion."
        return $false
    }

    try {
        # 2. Preparacion del entorno de trabajo aislado
        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Preparando entorno de trabajo aislado en $tempWorkDir"
        if (Test-Path $tempWorkDir) { Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Path $winReMountDir -Force

        # Quitar atributos de Solo Lectura/Oculto/Sistema antes de copiar
        Set-ItemProperty -Path $winRePath -Name Attributes -Value "Normal" -ErrorAction SilentlyContinue
        Copy-Item -Path $winRePath -Destination $winReTempPath -Force
        
        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Archivo winre.wim extraido con exito al espacio temporal."

        # 3. Montaje del WinRE
        Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Ejecutando DISM /Mount-Wim para winre.wim..."
        dism /mount-wim /wimfile:"$winReTempPath" /index:1 /mountdir:"$winReMountDir" | Out-Null
        
        if ($LASTEXITCODE -ne 0) { throw "Fallo al montar winre.wim. Codigo DISM: $LASTEXITCODE" }

        # 4. Inyeccion de Paquetes (LP y Satelites WinPE)
        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Buscando e inyectando paquetes .cab de idioma desde $WinPeLangPackPath..."
        
        # Filtramos solo los paquetes que corresponden al idioma objetivo
        $cabFiles = Get-ChildItem -Path $WinPeLangPackPath -Filter "*$LangCode*.cab" -Recurse
        
        if ($cabFiles.Count -eq 0) { throw "No se encontraron paquetes .cab para $LangCode en la ruta especificada." }

        foreach ($cab in $cabFiles) {
            Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Inyectando paquete -> $($cab.Name)"
            dism /image:"$winReMountDir" /add-package /packagepath:"$($cab.FullName)" | Out-Null
            if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw "Fallo al inyectar $($cab.Name). Codigo: $LASTEXITCODE" }
        }

        # 5. Configuracion del Idioma Predeterminado
        Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Configurando [$LangCode] como idioma predeterminado del entorno..."
        dism /image:"$winReMountDir" /Set-AllIntl:$LangCode | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Fallo al establecer el idioma predeterminado. Codigo: $LASTEXITCODE" }

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjector[WinRE]: Falla critica durante el proceso - $($_.Exception.Message)"
        Write-Error "Fallo la inyeccion en WinRE: $($_.Exception.Message)"
        
        # Desmontar descartando cambios en caso de error
        dism /unmount-wim /mountdir:"$winReMountDir" /discard | Out-Null
        return $false

    } finally {
        # 7. Desmontaje Seguro y Reemplazo
        if (Test-Path $winReMountDir) {
            $mountInfo = dism /get-mountedwiminfo | Select-String $winReMountDir
            if ($mountInfo) {
                Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Guardando cambios y desmontando winre.wim..."
                dism /unmount-wim /mountdir:"$winReMountDir" /commit | Out-Null
                
                if ($LASTEXITCODE -eq 0) {
                    # --- OPTIMIZACION TIER 1 (Exportacion) ---
                    Write-Host "`n   > Optimizando tamaño final del WinRE (Exportando)..." -ForegroundColor Yellow
                    $winReOptimized = Join-Path $tempWorkDir "winre_optimized.wim"
                    Write-Log -LogLevel ACTION -Message "LangInjector[WinRE]: Optimizando archivo mediante Export-Image."
                    
                    dism /export-image /sourceimagefile:"$winReTempPath" /sourceindex:1 /destinationimagefile:"$winReOptimized" /compress:max | Out-Null
                    
                    if ($LASTEXITCODE -eq 0 -and (Test-Path $winReOptimized)) {
                        Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Exportacion exitosa. Reemplazando el winre.wim original."
                        Copy-Item -Path $winReOptimized -Destination $winRePath -Force
                    } else {
                        Write-Log -LogLevel WARN -Message "LangInjector[WinRE]: Fallo la exportacion. Usando WIM sin optimizar. Codigo: $LASTEXITCODE"
                        Copy-Item -Path $winReTempPath -Destination $winRePath -Force
                    }
                    # -----------------------------------------
                    
                    # Restaurar atributos ocultos/sistema por seguridad
                    Set-ItemProperty -Path $winRePath -Name Attributes -Value "Hidden, System" -ErrorAction SilentlyContinue
                    Write-Log -LogLevel INFO -Message "LangInjector[WinRE]: Proceso completado exitosamente."
                } else {
                    Write-Log -LogLevel ERROR -Message "LangInjector[WinRE]: Error critico al desmontar winre.wim. Codigo: $LASTEXITCODE"
                }
            }
        }
        
        # Garbage Collection proactivo
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        
        # Limpieza de temporales
        Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    return $true
}

function Inject-OsLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$MountDir,
        [Parameter(Mandatory=$true)][string]$LangPackPath, # Ruta a la carpeta con el LP principal
        [Parameter(Mandatory=$true)][string]$FodPath,      # Ruta a la carpeta con los FODs
        [Parameter(Mandatory=$false)][string]$LxpPath,     # Opcional: Ruta a la carpeta con los Appx LXP
        [Parameter(Mandatory=$true)][string]$LangCode      # Ej: 'es-MX' o 'es-ES'
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Iniciando inyeccion Tier 1 para el idioma [$LangCode] en el Install.wim."

    try {
        # 1. Inyectar el Language Pack Principal (LP)
        Write-Log -LogLevel INFO -Message "LangInjector[OS]: Buscando el paquete de idioma principal (Client-Language-Pack)..."
        $lpCab = Get-ChildItem -Path $LangPackPath -Filter "*Client-Language-Pack*$LangCode*.cab" -Recurse | Select-Object -First 1

        if (-not $lpCab) { throw "No se encontro el paquete de idioma principal (LP) para $LangCode en la ruta proporcionada." }

        Write-Host "   > Inyectando paquete base ($LangCode)..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyectando LP -> $($lpCab.Name)"
        
        dism /image:"$MountDir" /Add-Package /PackagePath:"$($lpCab.FullName)" | Out-Null
        
        # DISM devuelve 3010 cuando requiere un reinicio, en un montaje offline, esto es un exito.
        if ($LASTEXITCODE -notin @(0, 3010)) { throw "Error al inyectar el LP. Codigo DISM: $LASTEXITCODE" }

        # 2. Inyectar los Features on Demand (FODs)
        Write-Host "   > Inyectando caracteristicas bajo demanda (Voz, Fuentes, Texto)..." -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "LangInjector[OS]: Inyectando Features on Demand (FODs) satelites..."
        
        $fodTypes = @("Basic", "Fonts", "Handwriting", "Speech", "TextToSpeech")

        foreach ($fod in $fodTypes) {
            $fodCab = Get-ChildItem -Path $FodPath -Filter "*LanguageFeatures-$fod*$LangCode*.cab" -Recurse | Select-Object -First 1
            if ($fodCab) {
                Write-Log -LogLevel INFO -Message "LangInjector[OS]: Inyectando FOD -> $($fodCab.Name)"
                dism /image:"$MountDir" /Add-Package /PackagePath:"$($fodCab.FullName)" | Out-Null
                if ($LASTEXITCODE -notin @(0, 3010)) { 
                    Write-Log -LogLevel WARN -Message "LangInjector[OS]: Advertencia al inyectar FOD $($fodCab.Name). Codigo: $LASTEXITCODE" 
                }
            } else {
                Write-Log -LogLevel WARN -Message "LangInjector[OS]: FOD '$fod' no encontrado para $LangCode. Se omitira, pero podria afectar funcionalidades del SO."
            }
        }

        # 3. Inyectar Local Experience Pack (LXP)
        if ($LxpPath -and (Test-Path $LxpPath)) {
            Write-Host "   > Inyectando paquete de experiencia local (LXP UWP)..." -ForegroundColor Yellow
            Write-Log -LogLevel INFO -Message "LangInjector[OS]: Buscando paquete de experiencia local (LXP Appx)..."
            
            $lxpAppx = Get-ChildItem -Path $LxpPath -Filter "*$LangCode*.appx*" -Recurse | Select-Object -First 1
            $lxpLicense = Get-ChildItem -Path $LxpPath -Filter "*$LangCode*license*.xml" -Recurse | Select-Object -First 1

            if ($lxpAppx) {
                Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyectando LXP Appx -> $($lxpAppx.Name)"
                $dismLxpCmd = "dism /image:`"$MountDir`" /Add-ProvisionedAppxPackage /PackagePath:`"$($lxpAppx.FullName)`""
                if ($lxpLicense) { 
                    $dismLxpCmd += " /LicensePath:`"$($lxpLicense.FullName)`"" 
                } else { 
                    $dismLxpCmd += " /SkipLicense" 
                }

                Invoke-Expression $dismLxpCmd | Out-Null
                if ($LASTEXITCODE -notin @(0, 3010)) { 
                    Write-Log -LogLevel WARN -Message "LangInjector[OS]: Error al inyectar LXP. Codigo: $LASTEXITCODE" 
                }
            }
        }

        # 4. Establecer como Predeterminado Absoluto
        Write-Host "   > Configurando $LangCode como idioma predeterminado del sistema..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Configurando [$LangCode] como idioma, teclado y zona predeterminada..."
        
        dism /image:"$MountDir" /Set-AllIntl:$LangCode | Out-Null
        dism /image:"$MountDir" /Set-SKUIntlDefaults:$LangCode | Out-Null

        if ($LASTEXITCODE -notin @(0, 3010)) { throw "Error al configurar el idioma predeterminado. Codigo: $LASTEXITCODE" }

        Write-Log -LogLevel ACTION -Message "LangInjector[OS]: Inyeccion en Install.wim finalizada exitosamente."
        return $true

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjector[OS]: Falla critica en la inyeccion principal - $($_.Exception.Message)"
        Write-Error "Fallo la inyeccion en Install.wim: $($_.Exception.Message)"
        return $false
    }
}

function Inject-BootWimLanguage {
    param (
        [Parameter(Mandatory=$true)][string]$BootWimPath,         # Ruta directa al archivo boot.wim
        [Parameter(Mandatory=$true)][string]$IsoDistributionDir,  # Carpeta raiz donde extrajiste la ISO (para el lang.ini)
        [Parameter(Mandatory=$true)][string]$WinPeLangPackPath,   # Ruta a la carpeta con los .cab de WinPE / Setup
        [Parameter(Mandatory=$true)][string]$LangCode             # Ej: 'es-MX' o 'es-ES'
    )

    Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Iniciando inyeccion Tier 1 para el idioma [$LangCode] en el Boot.wim."

    $tempWorkDir = Join-Path $env:TEMP "DeltaPack_Boot_Workspace"
    $bootMountDir = Join-Path $tempWorkDir "Mount"
    
    # 1. Preparacion del entorno de trabajo
    if (Test-Path $tempWorkDir) { Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue }
    $null = New-Item -ItemType Directory -Path $bootMountDir -Force

    # Verificar cuantos indices tiene el boot.wim
    Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Analizando estructura del boot.wim..."
    $bootImages = Get-WindowsImage -ImagePath $BootWimPath -ErrorAction Stop
    $indexCount = $bootImages.Count

    Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Se detectaron $indexCount indices en el boot.wim."

    # Filtramos los paquetes CAB correspondientes al idioma
    $cabFiles = Get-ChildItem -Path $WinPeLangPackPath -Filter "*$LangCode*.cab" -Recurse
    if ($cabFiles.Count -eq 0) { throw "No se encontraron paquetes WinPE/Setup para $LangCode en $WinPeLangPackPath." }

    # Bucle para procesar cada indice del boot.wim (Usualmente 1 y 2)
    for ($i = 1; $i -le $indexCount; $i++) {
        try {
            Write-Host "`n[+] Procesando boot.wim (Indice $i de $indexCount)..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Ejecutando DISM /Mount-Wim para el Indice $i..."
            
            dism /mount-wim /wimfile:"$BootWimPath" /index:$i /mountdir:"$bootMountDir" | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Fallo al montar el Indice $i del boot.wim. Codigo: $LASTEXITCODE" }

            # Inyectar todos los paquetes de idioma (LP y Setup Satellites)
            Write-Host "   > Inyectando paquetes de idioma WinPE/Setup..." -ForegroundColor DarkGray
            Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Inyectando $($cabFiles.Count) paquetes de idioma en el Indice $i..."
            
            foreach ($cab in $cabFiles) {
                dism /image:"$bootMountDir" /add-package /packagepath:"$($cab.FullName)" | Out-Null
                if ($LASTEXITCODE -notin @(0, 3010)) { 
                    Write-Log -LogLevel WARN -Message "LangInjector[Boot]: Advertencia al inyectar $($cab.Name). Codigo: $LASTEXITCODE" 
                }
            }

            # Configurar Idioma Predeterminado
            Write-Host "   > Configurando $LangCode por defecto..." -ForegroundColor DarkGray
            Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Estableciendo [$LangCode] como predeterminado (Indice $i)..."
            dism /image:"$bootMountDir" /Set-AllIntl:$LangCode | Out-Null

            # =========================================================================
            # MAGIA TIER 1: Regenerar LANG.INI (Solo se hace en el Indice de Setup, usualmente el 2)
            # =========================================================================
            if ($i -eq 2 -or $indexCount -eq 1) {
                if (Test-Path $IsoDistributionDir) {
                    Write-Host "   > Regenerando archivo de orquestacion Lang.ini..." -ForegroundColor Cyan
                    Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Regenerando lang.ini en la distribucion ISO ($IsoDistributionDir)..."
                    
                    # Este comando sincroniza los idiomas inyectados con la carpeta "sources" de la ISO externa
                    dism /image:"$bootMountDir" /Gen-LangINI /distribution:"$IsoDistributionDir" | Out-Null
                    
                    if ($LASTEXITCODE -notin @(0, 3010)) {
                        Write-Log -LogLevel ERROR -Message "LangInjector[Boot]: Falla al generar lang.ini. Codigo: $LASTEXITCODE"
                    } else {
                        Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Lang.ini actualizado correctamente. El instalador detectara el idioma [$LangCode]."
                        
                        # Extra: Asegurar que el Setup arranque en el nuevo idioma modificando el lang.ini para que sea el default
                        dism /image:"$bootMountDir" /Set-SetupUILang:$LangCode /distribution:"$IsoDistributionDir" | Out-Null
                    }
                } else {
                    Write-Log -LogLevel WARN -Message "LangInjector[Boot]: No se proporciono una carpeta de distribucion ISO valida. Se omitira la regeneracion de lang.ini."
                }
            }

            # Desmontar y Guardar
            Write-Host "   > Guardando cambios en el Indice $i..." -ForegroundColor Green
            Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Guardando y desmontando el Indice $i..."
            dism /unmount-wim /mountdir:"$bootMountDir" /commit | Out-Null

        } catch {
            Write-Log -LogLevel ERROR -Message "LangInjector[Boot]: Falla en el Indice $i - $($_.Exception.Message)"
            Write-Error "Error en el indice $i del boot.wim: $($_.Exception.Message)"
            dism /unmount-wim /mountdir:"$bootMountDir" /discard | Out-Null
            return $false
        }
    }

    # --- OPTIMIZACION (Exportacion Multindice) ---
    Write-Host "`n[+] Optimizando tamaño final del boot.wim (Exportando indices)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Iniciando exportacion secuencial para optimizar el boot.wim..."
    $bootOptimized = Join-Path $tempWorkDir "boot_optimized.wim"
    $exportSuccess = $true
    
    for ($j = 1; $j -le $indexCount; $j++) {
        dism /export-image /sourceimagefile:"$BootWimPath" /sourceindex:$j /destinationimagefile:"$bootOptimized" /compress:max | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $exportSuccess = $false
            Write-Log -LogLevel ERROR -Message "LangInjector[Boot]: Fallo exportacion del indice $j. Codigo: $LASTEXITCODE"
            break
        }
    }
    
    if ($exportSuccess -and (Test-Path $bootOptimized)) {
        Write-Log -LogLevel INFO -Message "LangInjector[Boot]: Exportacion exitosa. Reemplazando boot.wim original."
        Copy-Item -Path $bootOptimized -Destination $BootWimPath -Force
    } else {
        Write-Log -LogLevel WARN -Message "LangInjector[Boot]: Optimizacion fallida. Se conservara el boot.wim sin optimizar."
    }

    # Limpieza final
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Remove-Item -Path $tempWorkDir -Recurse -Force -ErrorAction SilentlyContinue

    Write-Log -LogLevel ACTION -Message "LangInjector[Boot]: Inyeccion de idioma en boot.wim completada exitosamente."
    return $true
}

function Show-LanguageInjector {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "         Inyector de Idiomas (OSD Offline)             " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    
    Write-Log -LogLevel INFO -Message "LangInjectorGUI: Iniciando asistente de inyeccion de idiomas."

    # 1. Validacion de estado del motor base
    if ($Script:IMAGE_MOUNTED -ne 1) {
        Write-Log -LogLevel WARN -Message "LangInjectorGUI: Acceso denegado. Se requiere un install.wim montado."
        Write-Warning "Debes montar el archivo 'install.wim' de destino antes de iniciar este proceso."
        Write-Host "El motor necesita el OS montado para extraer el WinRE e inyectar el sistema base." -ForegroundColor Gray
        Pause; return
    }

    Write-Host "Este asistente automatizado procesara WinRE, el OS y Boot.wim en secuencia." -ForegroundColor DarkGray
    Write-Host "Requisitos previos:" -ForegroundColor Yellow
    Write-Host " 1. ISO de Idiomas (Language and Optional Features) extraida." -ForegroundColor White
    Write-Host " 2. Windows ADK instalado O carpeta de WinPE Addons manual." -ForegroundColor White
    Write-Host " 3. Carpeta de distribucion de tu ISO de Windows (donde esta la carpeta 'sources').`n" -ForegroundColor White

    # 2. Captura del Codigo de Idioma
    $langCode = Read-Host "Ingrese el codigo de idioma objetivo (Ej: es-MX, es-ES, en-US)"
    if ([string]::IsNullOrWhiteSpace($langCode)) { 
        Write-Log -LogLevel INFO -Message "LangInjectorGUI: Operacion cancelada (Codigo de idioma vacio)."
        return 
    }
    Write-Log -LogLevel INFO -Message "LangInjectorGUI: Codigo de idioma objetivo configurado -> [$langCode]"

    # 3. Recopilacion de Rutas (Con Select-PathDialog y Auto-Deteccion)
    Write-Host "`n[Paso 1 de 4] Selecciona la carpeta raiz de la ISO de Idiomas (FODs y Client LP)..." -ForegroundColor Cyan
    $osLangPath = Select-PathDialog -DialogType Folder -Title "Selecciona carpeta de la ISO de Idiomas"
    if (-not $osLangPath) { return }

    # --- AUTO-DETECCION DE WINPE (Estilo Tier 1 / abbodi1406) ---
    Write-Host "`n[Paso 2 de 4] Buscando paquetes WinPE (ADK) para el idioma [$langCode]..." -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "LangInjectorGUI: Iniciando escaneo de auto-descubrimiento para paquetes WinPE."
    
    $peLangPath = $null
    
    # Rutas de escaneo
    $adkPath = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\Assessment and Deployment Kit\Windows Preinstallation Environment\amd64\WinPE_OCs"
    $localPePath = Join-Path $PSScriptRoot "WinPE\amd64\WinPE_OCs"

    # Verificamos si la ruta existe Y si contiene la subcarpeta del idioma especifico
    if ((Test-Path $adkPath) -and (Test-Path (Join-Path $adkPath $langCode))) {
        $peLangPath = $adkPath
        Write-Host "   [OK] ADK oficial detectado automaticamente en:" -ForegroundColor Green
        Write-Host "   $peLangPath" -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "LangInjectorGUI: Auto-descubrimiento exitoso. WinPE Addons encontrados en ADK oficial."
    } elseif ((Test-Path $localPePath) -and (Test-Path (Join-Path $localPePath $langCode))) {
        $peLangPath = $localPePath
        Write-Host "   [OK] Carpeta WinPE local detectada automaticamente en:" -ForegroundColor Green
        Write-Host "   $peLangPath" -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "LangInjectorGUI: Auto-descubrimiento exitoso. WinPE Addons encontrados en directorio local."
    } else {
        Write-Host "   [!] No se encontro el ADK de Windows instalado para este idioma." -ForegroundColor Yellow
        Write-Host "   Por favor, selecciona manualmente la carpeta raiz de los paquetes WinPE..." -ForegroundColor Cyan
        $peLangPath = Select-PathDialog -DialogType Folder -Title "Selecciona carpeta de WinPE Addons"
        if (-not $peLangPath) { 
            Write-Log -LogLevel INFO -Message "LangInjectorGUI: El usuario cancelo la seleccion manual de WinPE."
            return 
        }
    }

    Write-Host "`n[Paso 3 de 4] Selecciona la carpeta raiz de tu ISO de Windows (Distribucion con carpeta 'sources')..." -ForegroundColor Cyan
    $isoDistPath = Select-PathDialog -DialogType Folder -Title "Selecciona la raiz de la ISO de Windows a compilar"
    if (-not $isoDistPath) { return }

    # Verificar existencia de boot.wim en la distribucion
    $bootWimPath = Join-Path $isoDistPath "sources\boot.wim"
    if (-not (Test-Path $bootWimPath)) {
        Write-Log -LogLevel ERROR -Message "LangInjectorGUI: No se encontro boot.wim en $bootWimPath."
        Write-Warning "No se encontro el archivo 'sources\boot.wim' en la carpeta de distribucion seleccionada."
        Write-Host "Asegurate de seleccionar la carpeta raiz que contiene las carpetas 'boot', 'efi', 'sources', etc." -ForegroundColor Gray
        Pause; return
    }

    Write-Host "`n[Paso 4 de 4] Confirmacion Final" -ForegroundColor Cyan
    Write-Host "Se inyectara el idioma [$langCode] en:" -ForegroundColor White
    Write-Host " - WinRE (Oculto en el install.wim montado)" -ForegroundColor Gray
    Write-Host " - Install.wim (SO Principal montado)" -ForegroundColor Gray
    Write-Host " - Boot.wim (En $bootWimPath)" -ForegroundColor Gray
    Write-Host " - Lang.ini (Regeneracion en $isoDistPath)" -ForegroundColor Gray
    
    $confirm = Read-Host "`n¿Iniciar inyeccion masiva? Esto tomara bastante tiempo (S/N)"
    if ($confirm -notmatch '^(s|S)$') { 
        Write-Log -LogLevel INFO -Message "LangInjectorGUI: El usuario cancelo en la confirmacion final."
        return 
    }

    $startTime = Get-Date
    Write-Log -LogLevel ACTION -Message "LangInjectorGUI: Arrancando secuencia maestra de inyeccion Tier 1 para [$langCode]."

    # =======================================================
    # ORQUESTACION DE MOTORES (Bloque Try/Catch maestro)
    # =======================================================
    try {
        # FASE 1: WinRE
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 1: Procesando Entorno de Recuperacion (winre.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        $winReSuccess = Inject-WinReLanguage -InstallMountDir $Script:MOUNT_DIR -WinPeLangPackPath $peLangPath -LangCode $langCode
        
        if (-not $winReSuccess) {
            Write-Warning "La inyeccion en WinRE fallo o se omitio. Continuando con el OS principal..."
        }

        # FASE 2: Install.wim (OS)
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 2: Procesando Sistema Operativo (install.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        # Asumimos que los LXP estan en la misma ISO de lenguajes, ajusta si los tienes separados
        $osSuccess = Inject-OsLanguage -MountDir $Script:MOUNT_DIR -LangPackPath $osLangPath -FodPath $osLangPath -LxpPath $osLangPath -LangCode $langCode

        if (-not $osSuccess) {
            throw "La inyeccion en el sistema operativo fallo. Abortando secuencia para evitar una imagen corrupta."
        }

        # FASE 3: Boot.wim y Lang.ini
        Write-Host "`n=======================================================" -ForegroundColor Magenta
        Write-Host " FASE 3: Procesando Instalador y Lang.ini (boot.wim)" -ForegroundColor Magenta
        Write-Host "=======================================================" -ForegroundColor Magenta
        $bootSuccess = Inject-BootWimLanguage -BootWimPath $bootWimPath -IsoDistributionDir $isoDistPath -WinPeLangPackPath $peLangPath -LangCode $langCode

        if (-not $bootSuccess) {
            Write-Warning "La inyeccion en boot.wim tuvo errores. Revisa los logs."
        }

        $endTime = Get-Date
        $timeSpan = New-TimeSpan -Start $startTime -End $endTime

        Write-Log -LogLevel ACTION -Message "LangInjectorGUI: Secuencia maestra completada en $($timeSpan.Minutes) minutos y $($timeSpan.Seconds) segundos."
        
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Green
        Write-Host "        INYECCION DE IDIOMA COMPLETADA ($langCode)     " -ForegroundColor Green
        Write-Host "=======================================================" -ForegroundColor Green
        Write-Host "Tiempo transcurrido: $($timeSpan.Minutes) min $($timeSpan.Seconds) seg" -ForegroundColor Gray
        Write-Host ""
        Write-Host "IMPORTANTE:" -ForegroundColor Yellow
        Write-Host "Recuerda ejecutar la opcion 'Guardar y Desmontar' en el Menu Principal" -ForegroundColor White
        Write-Host "para aplicar permanentemente los cambios en el install.wim." -ForegroundColor White
        Write-Host ""
        
        [System.Windows.Forms.MessageBox]::Show("Inyeccion del idioma $langCode completada en la estructura base y el instalador.", "Operacion Exitosa", 'OK', 'Information')

    } catch {
        Write-Log -LogLevel ERROR -Message "LangInjectorGUI: Secuencia maestra abortada por excepcion - $($_.Exception.Message)"
        Write-Error "El orquestador de idiomas sufrio un error fatal: $_"
    }

    Pause
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
                
                # Intentamos re-leer qué imagen es para actualizar las variables del script
                try {
                    $info = dism /Get-MountedImageInfo
                    $wimLine = $info | Select-String -Pattern "Image File|Archivo de imagen" | Select -First 1
                    if ($wimLine) { 
                        $Script:WIM_FILE_PATH = ($wimLine.Line -split ':', 2)[1].Trim()
                        if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
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

# :main_menu (Funcion principal que muestra el menu inicial)
function Main-Menu {
    $Host.UI.RawUI.WindowTitle = "AdminImagenOffline v$($script:Version) by SOFTMAXTER | Panel de Control"
    
    # Variables de estado local para evitar consultas repetitivas a DISM (Lag)
    $cachedImageName = "---"
    $cachedImageVer  = "---"
    $cachedImageArch = "---"
    $lastMountState  = -1 # Forzar recarga inicial

    while ($true) {
        Clear-Host
        
        # --- 1. LÓGICA DE ACTUALIZACIÓN (Solo si cambia el estado) ---
        if ($Script:IMAGE_MOUNTED -ne $lastMountState) {
            $lastMountState = $Script:IMAGE_MOUNTED
            
            # --- CASO 1: WIM / ESD ---
            if ($Script:IMAGE_MOUNTED -eq 1) {
                Write-Host "Leyendo metadatos WIM..." -ForegroundColor DarkGray
                Write-Log -LogLevel INFO -Message "Dashboard: Estado de montaje alterado. Refrescando metadatos del WIM actual..."
                Clear-Host
                try {
                    $info = Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ErrorAction Stop
                    $cachedImageName = $info.ImageName
                    
                    # Traducir número de Arquitectura a Texto
                    switch ($info.Architecture) {
                        0  { $cachedImageArch = "x86" }
                        9  { $cachedImageArch = "x64" }
                        12 { $cachedImageArch = "ARM64" }
                        Default { $cachedImageArch = "Arch:$($info.Architecture)" }
                    }
                    
                    # Versión
                    if ($null -ne $info.Version -and $info.Version.ToString() -ne "") {
                        $cachedImageVer = $info.Version.ToString()
                    } elseif ($info.Build) {
                        $cachedImageVer = "10.0.$($info.Build)" 
                    } else {
                        $cachedImageVer = "Desconocida"
                    }
                    Write-Log -LogLevel INFO -Message "Dashboard: Metadatos WIM cargados exitosamente -> $cachedImageName ($cachedImageArch)"
                } catch { 
                    Write-Log -LogLevel WARN -Message "Dashboard: Fallo al leer metadatos WIM con DISM - $($_.Exception.Message)"
                    $cachedImageName = "Error Lectura"; $cachedImageVer = "--"; $cachedImageArch = "--" 
                }
            }
            # --- CASO 2: VHD / VHDX ---
            elseif ($Script:IMAGE_MOUNTED -eq 2) {
                Write-Log -LogLevel INFO -Message "Dashboard: Analizando estructura interna del VHD montado para refrescar UI..."
                $cachedImageName = "VHD Nativo"
                $sysDir = "$Script:MOUNT_DIR\Windows"
                
                # A) Detección de Arquitectura (Basada en carpetas)
                if (Test-Path "$sysDir\SysArm32") {
                    $cachedImageArch = "ARM64"
                } elseif (Test-Path "$sysDir\SysWOW64") {
                    $cachedImageArch = "x64"
                } elseif (Test-Path "$sysDir\System32") {
                    $cachedImageArch = "x86"
                } else {
                    $cachedImageArch = "Desconocida"
                }

                # B) Detección de Versión (Kernel)
                $kernelFile = "$sysDir\System32\ntoskrnl.exe"
                if (Test-Path $kernelFile) {
                    try {
                        $verInfo = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($kernelFile)
                        $cachedImageVer = "{0}.{1}.{2}" -f $verInfo.ProductMajorPart, $verInfo.ProductMinorPart, $verInfo.ProductBuildPart
                    } catch { 
                        Write-Log -LogLevel WARN -Message "Dashboard: Fallo al extraer FileVersionInfo de ntoskrnl.exe en VHD - $($_.Exception.Message)"
                        $cachedImageVer = "Error" 
                    }
                } else {
                    Write-Log -LogLevel WARN -Message "Dashboard: No se encontro ntoskrnl.exe en el VHD. Marcando como 'Sin Sistema'."
                    $cachedImageVer = "Sin Sistema"
                }
            }
            else {
                # Nada montado
                Write-Log -LogLevel INFO -Message "Dashboard: No hay imagenes montadas. Limpiando cache visual."
                $cachedImageName = "---"; $cachedImageVer = "---"; $cachedImageArch = "---"
            }
        }

        # --- 2. INTERFAZ GRÁFICA (Dashboard) ---
        $width = 80
        Write-Host ("=" * $width) -ForegroundColor Cyan
        
        $title = "ADMINISTRADOR DE IMAGEN OFFLINE"
        Write-Host (" " * [math]::Floor(($width - $title.Length) / 2) + $title) -ForegroundColor Cyan
        
        $verStr = "v$($script:Version)"
        Write-Host (" " * [math]::Floor(($width - $verStr.Length) / 2) + $verStr) -ForegroundColor Gray
        
        $auth = "by SOFTMAXTER"
        Write-Host (" " * [math]::Floor(($width - $auth.Length) / 2) + $auth) -ForegroundColor White
        
        Write-Host ("=" * $width) -ForegroundColor Cyan
        
        # Panel de Estado
        Write-Host ""
        Write-Host " ESTADO ACTUAL:" -ForegroundColor Yellow
        Write-Host "  + Fuente      : " -NoNewline
        if ($Script:WIM_FILE_PATH) { 
            # Truncar ruta si es muy larga para que no rompa el diseño
            $displayPath = if ($Script:WIM_FILE_PATH.Length -gt 60) { "..." + $Script:WIM_FILE_PATH.Substring($Script:WIM_FILE_PATH.Length - 60) } else { $Script:WIM_FILE_PATH }
            Write-Host $displayPath -ForegroundColor White 
        } else { Write-Host "Ninguna seleccionada" -ForegroundColor DarkGray }

        Write-Host "  + Montaje     : " -NoNewline
        switch ($Script:IMAGE_MOUNTED) {
            1 { Write-Host "[WIM] EN EDICION" -ForegroundColor Green -NoNewline; Write-Host " (Indice: $Script:MOUNTED_INDEX)" -ForegroundColor Gray }
            2 { Write-Host "[VHD] DISCO VIRTUAL" -ForegroundColor Magenta -NoNewline; Write-Host " (Modo Directo)" -ForegroundColor Gray }
            Default { Write-Host "NO MONTADA" -ForegroundColor Red }
        }
        Write-Host ""

        # Mostrar detalles solo si está montado
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "  + Detalles SO : " -NoNewline; Write-Host "$cachedImageName ($cachedImageArch)" -ForegroundColor Cyan
            Write-Host "  + Build       : " -NoNewline; Write-Host $cachedImageVer -ForegroundColor Cyan
            Write-Host "  + Directorio  : " -NoNewline; Write-Host $Script:MOUNT_DIR -ForegroundColor Gray
        }
        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host ""        
        # Menú de Opciones (Diseño en 2 Columnas simuladas o Grupos)
        Write-Host " [ GESTION DE IMAGEN ]" -ForegroundColor Yellow
        Write-Host "   1. Montar / Desmontar / Guardar Imagen" 
        Write-Host "   2. Convertir Formatos (ESD -> WIM, VHD -> WIM)"
        Write-Host "   3. Herramientas de Arranque y Medios (Boot.wim, ISO, VHD)"
        Write-Host ""
        Write-Host " [ INGENIERIA & AJUSTES ]" -ForegroundColor Yellow
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "   4. Drivers (Inyectar/Eliminar)" -ForegroundColor White
            Write-Host "   5. Personalizacion (Apps, Tweaks, Unattend.xml)" -ForegroundColor White
            Write-Host "   6. Limpieza y Reparacion (DISM/SFC)" -ForegroundColor White
            Write-Host "   7. Cambiar Edicion (Home -> Pro)" -ForegroundColor White
			Write-Host "   8. Gestion de Idiomas (Inyectar LP/FOD/LXP)" -ForegroundColor Cyan
        } else {
            # Opciones deshabilitadas visualmente
            Write-Host "   4. Drivers (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   5. Personalizacion (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   6. Limpieza y Reparacion (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   7. Cambiar Edicion (Requiere Montaje)" -ForegroundColor DarkGray
			Write-Host "   8. Gestion de Idiomas (Inyectar LP/FOD/LXP)" -ForegroundColor DarkGray
        }
        Write-Host ""
        Write-Host " [ SISTEMA ]" -ForegroundColor Yellow
        Write-Host "   8. Configuracion (Rutas)"
        Write-Host ""
        Write-Host "--------------------------------------------------------------------------------"
        Write-Host "   [L] Ver Logs   [H] Ayuda/Info   [S] Salir" -ForegroundColor Gray
        Write-Host ""

        $prompt = "Seleccione una opcion"
        if ($Script:IMAGE_MOUNTED -gt 0) { $prompt = "Comando (Imagen Lista)" }
        
        $opcionM = Read-Host " $prompt"
        
        # Manejo de Errores y Navegación
        switch ($opcionM.ToUpper()) {
            "1" { 
                Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Image-Management-Menu'"
                Image-Management-Menu 
            }
            "2" { 
                Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Convert-Image-Menu'"
                Convert-Image-Menu 
            }
            "3" { 
                while($true) {
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
                    Write-Host "   [3] Despliegue a VHD (Instalacion Virtual)" -ForegroundColor White
                    Write-Host "       (Instala Windows en un disco virtual nativo)" -ForegroundColor Gray
                    Write-Host ""
                    Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
                    Write-Host ""
                    
                    $bootOpt = Read-Host " Elige una opcion"
                    switch ($bootOpt.ToUpper()) {
                        "1" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Manage-BootWim-Menu'"; Manage-BootWim-Menu }
                        "2" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-IsoMaker-GUI'"; Show-IsoMaker-GUI }
                        "3" { Write-Log -LogLevel INFO -Message "MenuBoot: Accediendo a 'Show-Deploy-To-VHD-GUI'"; Show-Deploy-To-VHD-GUI }
                        "V" { Write-Log -LogLevel INFO -Message "MenuBoot: Volviendo al menu principal"; break }
                        default { 
                            Write-Log -LogLevel WARN -Message "MenuBoot: Opcion invalida seleccionada ($bootOpt)."
                            Write-Warning "Opcion invalida" 
                        }
                    }
                    if ($bootOpt.ToUpper() -eq "V") { break }
                }
            }
            "4" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Drivers-Menu'"
                    Drivers-Menu 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a Drivers denegado (No hay imagen montada)."
                    Show-Mount-Warning 
                } 
            }
            "5" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Customization-Menu'"
                    Customization-Menu 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a Personalizacion denegado (No hay imagen montada)."
                    Show-Mount-Warning 
                } 
            }
            "6" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Limpieza-Menu'"
                    Limpieza-Menu 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a Limpieza (DISM) denegado (No hay imagen montada)."
                    Show-Mount-Warning 
                } 
            }
            "7" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Cambio-Edicion-Menu'"
                    Cambio-Edicion-Menu 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a Cambio de Edicion denegado (No hay imagen montada)."
                    Show-Mount-Warning 
                } 
            }
            "8" { 
                if ($Script:IMAGE_MOUNTED) { 
                    Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Show-LanguageInjector-GUI'"
                    Show-LanguageInjector-GUI 
                } else { 
                    Write-Log -LogLevel WARN -Message "MenuMain: Intento de acceso a Idiomas denegado (No hay imagen montada)."
                    Show-Mount-Warning 
                } 
            }
            "9" { 
                Write-Log -LogLevel INFO -Message "MenuMain: Accediendo a 'Show-ConfigMenu'"
                Show-ConfigMenu
			}
            'L' {
                $logFile = Join-Path (Split-Path -Parent $PSScriptRoot) "Logs\Registro.log"
                if (Test-Path $logFile) {
                    Write-Log -LogLevel INFO -Message "MenuMain: El usuario abrio el archivo de Log principal en el Bloc de Notas."
                    Start-Process notepad.exe -ArgumentList $logFile
                    $statusMessage = "Abriendo logs..."; $statusColor = "Green"
                } else {
                    Write-Log -LogLevel ERROR -Message "MenuMain: Intento de abrir el log fallido. El archivo no existe aun ($logFile)."
                    $statusMessage = "Error: El archivo de log aun no existe."; $statusColor = "Red"
                }
            }
            'H' {
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
                    $confirmExit = Read-Host "Hay una imagen montada! Si sales ahora, quedara montada.`nDeseas desmontarla antes de salir? (S/N/Cancelar)"
                    if ($confirmExit -eq 'S') { 
                        Write-Log -LogLevel ACTION -Message "MenuExit: El usuario acepto desmontar la imagen antes de salir."
                        Unmount-Image
                        exit 
                    }
                    elseif ($confirmExit -eq 'N') { 
                        Write-Log -LogLevel ERROR -Message "MenuExit: ALERTA - El usuario forzo la salida dejando una imagen montada (Huerfana)."
                        Write-Warning "Saliendo... Recuerda ejecutar 'Limpieza' al volver."
                        exit 
                    }
                    else {
                        Write-Log -LogLevel INFO -Message "MenuExit: El usuario cancelo la salida. Volviendo al menu."
                    }
                } else {
                    Write-Log -LogLevel INFO -Message "MenuExit: Saliendo del programa limpiamente (Sin imagenes montadas)."
                    Write-Host "Hasta luego." -ForegroundColor Green
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
# Pequeña función auxiliar para evitar repetir el mensaje de error
function Show-Mount-Warning {
    [System.Console]::Beep(400, 200)
    Write-Host " [!] ACCION BLOQUEADA: Debe montar una imagen primero (Opcion 1)." -ForegroundColor Yellow -BackgroundColor DarkRed
    Start-Sleep -Seconds 2
}

# =================================================================
#  Verificacion de Montaje Existente
# =================================================================
$Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null
$TEMP_DISM_OUT = Join-Path $env:TEMP "dism_check_$($RANDOM).tmp"

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
                $Script:WIM_FILE_PATH = ($wimPathLine.Line -split ':', 2)[1].Trim()
                if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
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
            # 2. Obtener TODAS las particiones con letra de unidad válida
            # (Quitamos el Select-Object -First 1 para no quedarnos solo con la EFI)
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }

            foreach ($part in $partitions) {
                $rootPath = "$($part.DriveLetter):\"

                # 3. HEURISTICA: Es esta partición específica una instalación de Windows?
                if (Test-Path "$rootPath\Windows\System32\config\SYSTEM") {

                    # ¡ENCONTRADO!
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
            # Si ya encontramos imagen (IMAGE_MOUNTED=2), rompemos el bucle de discos también
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
    
    # Limpieza preventiva de hives huérfanos si se detecto un montaje previo
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
        $hives = @("HKLM\OfflineSystem", "HKLM\OfflineSoftware", "HKLM\OfflineComponents", "HKLM\OfflineUser", "HKLM\OfflineUserClasses")
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
    # --- MEJORA: Logging Detallado de Errores (Stack Trace) ---
    $ErrorActionPreference = "Continue" # Asegurar que podemos procesar el error
    
    # 1. Capturar detalles técnicos
    $ex = $_.Exception
    $line = $_.InvocationInfo.ScriptLineNumber
    $cmd = $_.InvocationInfo.MyCommand
    $stack = $_.ScriptStackTrace

    # 2. Formatear mensaje para el usuario (Limpio)
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host "             ¡ERROR CRITICO DEL SISTEMA!               " -ForegroundColor Red
    Write-Host "=======================================================" -ForegroundColor Red
    Write-Host ""
    Write-Host "Ha ocurrido un error inesperado que detuvo la ejecucion." -ForegroundColor Gray
    Write-Host "Error: " -NoNewline; Write-Host $_.ToString() -ForegroundColor Yellow
    Write-Host "Linea: " -NoNewline; Write-Host $line -ForegroundColor Cyan
    Write-Host ""

    # 3. Escribir Log Técnico Completo (Para el SysAdmin)
    $logPayload = @"
CRASH REPORT
--------------------------------------------------
Timestamp : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Error     : $($_.ToString())
Command   : $cmd
Line      : $line
Category  : $($_.CategoryInfo.ToString())
Stack Tr. : 
$stack
--------------------------------------------------
"@
    Write-Log -LogLevel ERROR -Message $logPayload

    # 4. Opcion de recuperacion
    Write-Host "El detalle completo se ha guardado en el archivo de registro." -ForegroundColor Gray
    Write-Warning "Se recomienda desmontar Hives y limpiar carpetas antes de reintentar."
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
