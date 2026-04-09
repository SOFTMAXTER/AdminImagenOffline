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
    1.5.2

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
$script:Version = "1.5.2"

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
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $script:logFile -Append -Encoding utf8
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
        Write-Host "`nNueva version encontrada!" -ForegroundColor Green
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

    Write-UpdateLog "[PASO 4/6] Verificando integridad de la descarga..."
    
    # --- LECTURA PREVENTIVA ---
    # Capturamos los nuevos archivos ANTES de borrar los viejos.
    `$elementosNuevos = Get-ChildItem -Path `$updateSourcePath -Force
    
    if (`$elementosNuevos.Count -eq 0) {
        throw "ERROR DE INTEGRIDAD: El archivo ZIP descargado esta vacio o corrupto. Abortando actualizacion para proteger la instalacion actual."
    }

    Write-UpdateLog "[PASO 5/6] Preparando instalacion (eliminando version anterior)..."

    # --- 1. ELIMINACION POR LISTA EXPLICITA (Solo si la descarga fue exitosa) ---
    `$elementosABorrar = @(
        "Run.bat",
        "Script",
        "README.md",
        "LICENSE",
        "version.txt"
    )

    foreach (`$elemento in `$elementosABorrar) {
        `$rutaDestino = Join-Path "$installPath" `$elemento
        if (Test-Path -LiteralPath `$rutaDestino) {
            Remove-Item -Path `$rutaDestino -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-UpdateLog "[PASO 6/6] Instalando nuevos archivos..."
    
    # --- 2. COPIA BLINDADA ---
    foreach (`$nuevo in `$elementosNuevos) {
        `$destinoFinal = Join-Path "$installPath" `$nuevo.Name
        Copy-Item -Path `$nuevo.FullName -Destination `$destinoFinal -Recurse -Force
    }
    
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

# --- HELPER PRIVADO: Obtener letra de unidad libre (Z -> A) ---
function Get-UnusedDriveLetter {
    # 1. Usamos la clase nativa de .NET para una detección absoluta.
    # A diferencia de Get-PSDrive, esto detecta todas las letras ocupadas en el sistema operativo a bajo nivel.
    $usedLetters = [System.IO.DriveInfo]::GetDrives() | Select-Object -ExpandProperty Name | ForEach-Object { $_[0] }
    
    # 2. Rango ASCII invertido: Z (90) hasta F (70).
    # Esto protege las letras A y B (Legacy), C (Sistema), D y E (Ópticos o discos secundarios fijos).
    $alphabet = [char[]](90..70) 
    
    foreach ($letter in $alphabet) {
        if ($usedLetters -notcontains $letter) {
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

Get-ChildItem -Path $PSScriptRoot -Filter "Modulo-*.ps1" | ForEach-Object {
    . $_.FullName
}

. "$PSScriptRoot\Modulo-Appx.ps1"
. "$PSScriptRoot\Modulo-DeployVHD.ps1"
. "$PSScriptRoot\Modulo-Drivers.ps1"
. "$PSScriptRoot\Modulo-Features.ps1"
. "$PSScriptRoot\Modulo-Idioma.ps1"
. "$PSScriptRoot\Modulo-IsoMaker.ps1"
. "$PSScriptRoot\Modulo-Metadata.ps1"
. "$PSScriptRoot\Modulo-OEMBranding.ps1"
. "$PSScriptRoot\Modulo-Unattend.ps1"

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
function Select-WindowsMediaSource {
	param(
        [string]$ExtractDir = $(Join-Path $parentDir "ISO_Extract")
    )

    Write-Log -LogLevel INFO -Message "SourceSelector: Iniciando seleccion de fuente de medios (Solo ISO)."
    $SelectedPath = $null

    Add-Type -AssemblyName System.Windows.Forms

    # --- 1. SELECCION DE ISO ---
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Filter = "Archivos ISO (*.iso)|*.iso"
    $ofd.Title = "SELECCIONA TU ISO DE WINDOWS"
    
    if ($ofd.ShowDialog() -ne 'OK') { 
        Write-Log -LogLevel INFO -Message "SourceSelector: Usuario cancelo la seleccion de ISO."
        Write-Warning "Operacion cancelada."
        return $null 
    }
    
    $IsoPath = $ofd.FileName
	Clear-Host
	Write-Host ""
    Write-Host "ISO Seleccionada: $IsoPath" -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "SourceSelector: ISO seleccionada -> $IsoPath"

    # --- 2. AVISO Y LIMPIEZA DE CONTENIDO PREVIO ---
    if (Test-Path $ExtractDir) {
        # Verificamos si realmente hay archivos adentro (para no asustar si la carpeta está vacía)
        $existingFiles = Get-ChildItem -Path $ExtractDir -Force
        
        if ($existingFiles.Count -gt 0) {
            $warnMsg = "Se ha detectado contenido previo en la carpeta de extraccion:`n$ExtractDir`n`nPara evitar que los archivos se mezclen y corrompan la imagen, se ELIMINARA todo el contenido actual de esa carpeta antes de extraer la nueva ISO.`n`nEstas de acuerdo en vaciar la carpeta y continuar?"
            
            $dialogRes = [System.Windows.Forms.MessageBox]::Show($warnMsg, "Advertencia de Limpieza", 'YesNo', 'Warning')
            
            if ($dialogRes -ne 'Yes') {
                Write-Log -LogLevel INFO -Message "SourceSelector: Operacion cancelada por el usuario para no borrar el directorio previo."
                Write-Warning "Extracción cancelada para proteger los archivos existentes."
                return $null
            }
            
            Write-Host "  >> Vaciando directorio de extraccion anterior..." -ForegroundColor DarkGray
            Write-Log -LogLevel ACTION -Message "SourceSelector: Eliminando contenido previo en $ExtractDir."
            # Borramos el contenido, no la carpeta principal
            Remove-Item "$ExtractDir\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    } else {
        # Si no existe, la creamos
        New-Item -ItemType Directory -Path $ExtractDir -Force | Out-Null
    }
    
    # --- 3. MONTAJE Y EXTRACCION ---
    try {
        Write-Host "  >> Montando imagen de disco..." -ForegroundColor Gray
        $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -StorageType ISO
        
        # Pausa tactica de veterano
        Start-Sleep -Seconds 2 
        
        $vol = $mountResult | Get-Volume
        
        if (-not $vol) { throw "No se pudo obtener la letra de la unidad montada." }
        
        $driveRoot = "$($vol.DriveLetter):\" 
        
        Write-Host "  >> Copiando archivos (esto puede tardar varios minutos)..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "SourceSelector: Copiando contenido de $driveRoot a $ExtractDir via Robocopy."
        
        $argsRobo = @($driveRoot, $ExtractDir, "/E", "/NFL", "/NDL", "/NJH", "/NJS")
        $proc = Start-Process "robocopy.exe" -ArgumentList $argsRobo -Wait -PassThru -NoNewWindow
        
        if ($proc.ExitCode -ge 8) {
            Write-Log -LogLevel WARN -Message "SourceSelector: Robocopy fallo con exit code $($proc.ExitCode). Usando Copy-Item."
            Write-Warning "Robocopy reporto errores. Intentando metodo alternativo (Copy-Item)..."
            Copy-Item -Path "$driveRoot*" -Destination $ExtractDir -Recurse -Force
        }
        
        Write-Log -LogLevel INFO -Message "SourceSelector: Desmontando ISO."
        Dismount-DiskImage -ImagePath $IsoPath | Out-Null
        $SelectedPath = $ExtractDir
        
    } catch {
        Write-Log -LogLevel ERROR -Message "SourceSelector: Fallo al procesar la ISO - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Error critico al procesar la ISO:`n$($_.Exception.Message)", "Error ISO", 'OK', 'Error')
        
        try { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null } catch {}
        return $null
    }

    # --- 4. PERMISOS ---
    Write-Host "  >> Normalizando atributos de archivos (Quitando Solo Lectura)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "SourceSelector: Eliminando atributos IsReadOnly en $SelectedPath"
    
    try {
        Get-ChildItem -Path $SelectedPath -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.IsReadOnly) { $_.IsReadOnly = $false }
        }
        Write-Host "  [OK] Atributos normalizados." -ForegroundColor Green
    } catch {
        Write-Log -LogLevel WARN -Message "SourceSelector: Advertencia menor al cambiar atributos - $($_.Exception.Message)"
    }

    return $SelectedPath
}

function Mount-Image {
    Clear-Host
    Write-Log -LogLevel INFO -Message "MountManager: Iniciando solicitud de montaje de imagen."

    if ($Script:IMAGE_MOUNTED -eq 1) {
        Write-Log -LogLevel WARN -Message "MountManager: Operacion cancelada. Ya existe una imagen montada en el entorno."
        Write-Warning "La imagen ya se encuentra montada."
        Pause; return
    }

    # =======================================================
    #  NUEVA LÓGICA: SELECCIÓN DE ORIGEN (ISO vs Archivo)
    # =======================================================
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host "               SELECCION DE FUENTE                     " -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host " Que deseas montar?`n"
    Write-Host "   [1] Archivo Individual (.wim, .vhd, .vhdx)"
    Write-Host "   [2] Extraer desde una ISO de Windows" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "   [V] Cancelar y Volver" -ForegroundColor Red
    Write-Host ""
    
    $sourceType = Read-Host "Elige una opcion"

    if ($sourceType.ToUpper() -eq 'V') { return }

    if ($sourceType -eq '2') {
        Write-Log -LogLevel INFO -Message "MountManager: Usuario eligio extraer desde ISO/Carpeta."

        # Llamamos a nuestra nueva y robusta función
        $ExtractPath = Select-WindowsMediaSource
        
        if (-not $ExtractPath) { 
            Write-Log -LogLevel INFO -Message "MountManager: Seleccion de fuente cancelada."
            return 
        }

        # Auto-detectar la imagen del sistema operativo
        $wimPath = Join-Path $ExtractPath "sources\install.wim"
        $esdPath = Join-Path $ExtractPath "sources\install.esd"

        if (Test-Path -LiteralPath $wimPath) {
            $Script:WIM_FILE_PATH = $wimPath
            Write-Host "`n[OK] Imagen base detectada: install.wim" -ForegroundColor Green
        } elseif (Test-Path -LiteralPath $esdPath) {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Red
            Write-Host "             FORMATO ESD DETECTADO                     " -ForegroundColor Yellow
            Write-Host "=======================================================" -ForegroundColor Red
            Write-Host "La ISO extraida contiene un archivo 'install.esd' (Compresion Solida)." -ForegroundColor White
            Write-Host "DISM no permite montar archivos .esd para realizar ediciones directas." -ForegroundColor Gray
            Write-Host ""
            Write-Host "SOLUCION:" -ForegroundColor Cyan
            Write-Host "Ve al Menu Principal -> [2] Convertir Formatos."
            Write-Host "Selecciona 'Convertir ESD a WIM' y apunta a este archivo:" -ForegroundColor Gray
            Write-Host $esdPath -ForegroundColor Yellow
            Write-Host ""
            Write-Log -LogLevel WARN -Message "MountManager: install.esd detectado. Abortando montaje directo."
            Pause; return
        } else {
            Write-Warning "No se encontro install.wim ni install.esd en la ruta: $ExtractPath\sources"
            Write-Log -LogLevel ERROR -Message "MountManager: No se encontro imagen base en la ISO extraida."
            Pause; return
        }

    } elseif ($sourceType -eq '1') {
        $path = Select-PathDialog -DialogType File -Title "Seleccione la imagen a montar" -Filter "Archivos Soportados (*.wim, *.vhd, *.vhdx)|*.wim;*.vhd;*.vhdx|Todos (*.*)|*.*"
        if ([string]::IsNullOrEmpty($path)) { 
            Write-Log -LogLevel INFO -Message "MountManager: El usuario cancelo el dialogo de seleccion de archivo individual."
            Write-Warning "Operacion cancelada."; Pause; return 
        }
        $Script:WIM_FILE_PATH = $path
    } else {
        Write-Warning "Opción no válida."
        Pause; return
    }
    
    $extension = [System.IO.Path]::GetExtension($Script:WIM_FILE_PATH).ToUpper()
    Write-Log -LogLevel INFO -Message "MountManager: Archivo seleccionado -> $Script:WIM_FILE_PATH | Formato detectado: $extension"

    # =======================================================
    #  MODO VHD / VHDX (CON LA PAUSA TÁCTICA APLICADA)
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
            
            # --- CORRECCIÓN: Pausa táctica (Respiración del bus virtual) ---
            Write-Log -LogLevel INFO -Message "MountManager: Esperando 2 segundos para inicializacion logica del disco..."
            Start-Sleep -Seconds 2

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
                    
                    Start-Sleep -Milliseconds 500 # Micro-pausa para NTFS
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
            $Script:CachedControlSet = $null
            
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
    Write-Host "`n[+] Leyendo estructura del WIM..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "MountManager: Consultando a DISM la estructura de indices del archivo WIM."
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH" /English

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
        $Script:CachedControlSet = $null
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

    # 3. Desmontaje VHD (Logica separada)
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
			$Script:CachedControlSet = $null
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
    
    # Determinamos los argumentos de DISM en base al parametro $Commit
    $dismArg = if ($Commit) { "/commit" } else { "/discard" }
    $actionText = if ($Commit) { "Guardando y Desmontando (Commit)" } else { "Desmontando (Discard)" }

    Write-Log -LogLevel ACTION -Message "UnmountManager: Iniciando bucle de desmontaje WIM para '$Script:MOUNT_DIR' con parametros: $dismArg"

    while ($retry -lt $maxRetries -and -not $success) {
        $retry++
        Write-Host "   > Intento $retry de $($maxRetries): $actionText WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "UnmountManager: Ejecutando DISM (Intento $retry de $maxRetries)..."
        
        if ($Commit) {
            Write-Host "   [!] Empaquetando y comprimiendo cambios en el archivo WIM..." -ForegroundColor Cyan
            Write-Host "   [!] DISM tardara varios minutos en iniciar la barra de progreso. Por favor, no interrumpa el proceso..." -ForegroundColor DarkGray
        } else {
            Write-Host "   [!] Revirtiendo estructura de directorios y liberando bloqueos..." -ForegroundColor Cyan
            Write-Host "   [!] Esto tomara unos instantes. Por favor, espere..." -ForegroundColor Gray
        }

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
		$Script:CachedControlSet = $null
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
		$Script:CachedControlSet = $null
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
        Write-Host "    > Por favor espera. DISM esta inicializando el motor de guardado (puede tardar en comenzar)..." -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "SaveManager: Ejecutando DISM /Commit-Image para sobrescribir el indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    } 
    elseif ($Mode -eq 'Append') {
        Clear-Host
        Write-Host "[+] Guardando cambios en un nuevo indice (Append)..." -ForegroundColor Yellow
        Write-Host "    > Por favor espera. DISM esta calculando las diferencias (puede tardar en comenzar)..." -ForegroundColor Gray
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
        Write-Host "    > Por favor espera. DISM esta preparando la compresion maxima (puede tardar unos minutos en iniciar)..." -ForegroundColor Gray
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

    $isVhd = ($Script:WIM_FILE_PATH -match '\.vhdx?$')
    if ($isVhd -or $Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel WARN -Message "IndexManager: Bloqueo activado. Intento de exportar indices desde un disco virtual."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host "      OPERACION NO PERMITIDA EN DISCOS VIRTUALES       " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Has intentado exportar un indice desde un archivo VHD o VHDX." -ForegroundColor White
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los discos virtuales usan particiones (bloques), no indices de imagen como los WIM/ESD." -ForegroundColor Gray
        Write-Host "Para extraer Windows de un VHD, usa la opcion 'Convertir VHD/VHDX a WIM' en el menu de Conversion." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo origen."
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta leyendo la estructura del archivo (Esto puede tardar unos segundos)..." -ForegroundColor Cyan
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
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta iniciando el proceso de exportacion (No cierre la ventana)..." -ForegroundColor Cyan
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

    $isVhd = ($Script:WIM_FILE_PATH -match '\.vhdx?$')
    if ($isVhd -or $Script:IMAGE_MOUNTED -eq 2) {
        Write-Log -LogLevel WARN -Message "IndexManager: Bloqueo activado. Intento de eliminar indices en un disco virtual."
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host "      OPERACION NO PERMITIDA EN DISCOS VIRTUALES       " -ForegroundColor Yellow
        Write-Host "=======================================================" -ForegroundColor Red
        Write-Host ""
        Write-Host "Has intentado eliminar un indice de un archivo VHD o VHDX." -ForegroundColor White
        Write-Host "EXPLICACION TECNICA:" -ForegroundColor Cyan
        Write-Host "Los discos virtuales no contienen indices gestionables por DISM." -ForegroundColor Gray
        Write-Host "Si deseas eliminar el sistema operativo o particiones de un VHD, debes montarlo y usar el Administrador de Discos de Windows (diskmgmt.msc)." -ForegroundColor Gray
        Write-Host ""
        Pause
        return
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Log -LogLevel INFO -Message "IndexManager: Consultando a DISM la estructura de indices del archivo."
    
    # MENSAJE DE ESPERA AÑADIDO AQUI
    Write-Host "Por favor, espere. DISM esta leyendo la estructura del archivo (Esto puede tardar unos segundos)..." -ForegroundColor Cyan
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    
    $INDEX_TO_DELETE = Read-Host "`nIngrese el numero de Indice que desea eliminar"
    # Validar que INDEX_TO_DELETE sea un numero valido podria añadirse aqui
    Write-Log -LogLevel INFO -Message "IndexManager: Indice objetivo ingresado por el usuario -> [$INDEX_TO_DELETE]"

    $CONFIRM = Read-Host "Esta seguro que desea eliminar el Indice $INDEX_TO_DELETE de forma PERMANENTE? (S/N)"

    if ($CONFIRM -match '^(s|S)$') {
        Write-Host "[+] Eliminando Indice $INDEX_TO_DELETE..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "IndexManager: Ejecutando DISM /Delete-Image para eliminar el Indice $INDEX_TO_DELETE de '$($Script:WIM_FILE_PATH)'."
        
        # MENSAJE DE ESPERA AÑADIDO AQUI
        Write-Host "Por favor, espere. DISM esta procediendo a borrar el indice (La operacion tomara algo de tiempo)..." -ForegroundColor Cyan
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
    
    Write-Host "   > Inicializando motor DISM, por favor espere..." -ForegroundColor Cyan
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
    
    Write-Host "   > Inicializando motor DISM, por favor espere..." -ForegroundColor Cyan
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
        Write-Host "[ERROR] El cmdlet 'Mount-Vhd' no esta disponible en el sistema actual." -ForegroundColor Red
        Write-Host "Necesitas habilitar las herramientas de gestion de discos virtuales de Hyper-V." -ForegroundColor Gray
        Write-Host ""
        Write-Host "Para solucionarlo, abre una consola PowerShell como Administrador y ejecuta:" -ForegroundColor Yellow
        Write-Host "Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell" -ForegroundColor Cyan
        Write-Host ""
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
        # A. Montar VHD quitándole el control automático a Windows (NoDriveLetter)
        # Esto evita condiciones de carrera con el sistema Plug and Play
        $mountedDisk = Mount-Vhd -Path $VHD_FILE_PATH -NoDriveLetter -PassThru -ErrorAction Stop
        
        # Pausa táctica (Respiración del bus SCSI virtual)
        Start-Sleep -Seconds 2

        # B. Obtener particiones filtrando por topología real, no por tamaño arbitrario
        # Excluimos explícitamente particiones de Sistema (EFI), Reservadas (MSR) y Ocultas/OEM.
        $partitions = Get-Partition -DiskNumber $mountedDisk.Number | Where-Object { 
            $_.Type -notin @('System', 'Reserved', 'Recovery') -and 
            $_.IsHidden -eq $false -and
            $_.Size -gt 500MB 
        }

        foreach ($part in $partitions) {
            $currentLet = $part.DriveLetter
            $assignedTemp = $false
            
            # --- LÓGICA DE AUTO-ASIGNACIÓN (Con validación de éxito) ---
            if (-not $currentLet) {
                try {
                    # Invocamos al helper global (protegido contra mapeos de red y restringido de Z a F)
                    $freeLet = Get-UnusedDriveLetter
                    
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Intentando asignar letra temporal [$freeLet] a la Particion $($part.PartitionNumber)."
                    Write-Host "   > Inspeccionando particion sin letra. Asignando $freeLet`: temporalmente..." -ForegroundColor Gray
                    
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction Stop
                    $currentLet = $freeLet
                    $assignedTemp = $true
                    
                    # Micro-pausa para que el sistema de archivos (NTFS) monte el volumen
                    Start-Sleep -Milliseconds 500 
                } catch {
                    Write-Log -LogLevel WARN -Message "ConvertVHD: Particion protegida, RAW, cifrada, o sin letras disponibles. Ignorando. ($($_.Exception.Message))"
                    continue # Saltamos a la siguiente iteración
                }
            }

            # --- VERIFICACIÓN EXACTA DE WINDOWS ---
            if ($currentLet) {
                $winPath = "$currentLet`:\Windows\System32\config\SYSTEM"
                
                if (Test-Path -LiteralPath $winPath) {
                    $DRIVE_LETTER = $currentLet
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Instalacion de Windows validada en la particion [$DRIVE_LETTER`]."
                    Write-Host "   [OK] Windows detectado en particion $DRIVE_LETTER`:" -ForegroundColor Green
                    break # ¡Encontrado! Detenemos la búsqueda.
                } else {
                    Write-Log -LogLevel INFO -Message "ConvertVHD: Particion [$currentLet`] no es el sistema operativo."
                    Write-Host "   [-] Particion $currentLet`: no contiene Windows. Ignorando." -ForegroundColor Gray
                    
                    # Limpieza: Si asignamos la letra y no era Windows, la removemos para no dejar basura montada
                    if ($assignedTemp) {
                        Remove-PartitionAccessPath -InputObject $part -AccessPath "$currentLet`:" -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        if (-not $DRIVE_LETTER) {
            Write-Log -LogLevel ERROR -Message "ConvertVHD: Fallo estructural. No se encontro ninguna instalacion de Windows valida en el VHD."
            throw "No se encontro ninguna instalacion de Windows valida en el VHD. Asegurese de que la imagen no esta cifrada con BitLocker."
        }

        Write-Host "   > Optimizando volumen antes de la captura (Trim)..." -ForegroundColor Gray
        Write-Log -LogLevel INFO -Message "ConvertVHD: Ejecutando Optimize-Volume (Trim) en el disco virtual."
        
        try {
            Optimize-Volume -DriveLetter $DRIVE_LETTER -ReTrim -ErrorAction Stop | Out-Null
        } catch {
            Write-Log -LogLevel WARN -Message "ConvertVHD: Omitiendo Trim. El volumen no lo soporta o es de solo lectura. ($($_.Exception.Message))"
        }
        
        # 5. Captura (DISM)
        Write-Host "`n[+] Capturando volumen $DRIVE_LETTER`: a WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "ConvertVHD: Ejecutando DISM /Capture-Image del volumen [$DRIVE_LETTER`] hacia '$DEST_WIM_PATH'."

        Write-Host "   > Inicializando motor DISM, por favor espere..." -ForegroundColor Cyan
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
    
    # --- CAPTURA DE SEGURIDAD (Atributos y ACLs NTFS) ---
    $winreFile = Get-Item -LiteralPath $winrePath -Force
    $originalAttributes = $winreFile.Attributes
    # Guardamos los permisos exactos (TrustedInstaller, etc.)
    $originalAcl = Get-Acl -LiteralPath $winrePath 
    Write-Log -LogLevel INFO -Message "WinRE_Manager: ACLs y atributos originales de winre.wim respaldados en memoria."

    # Cambiamos a Normal para manipulación segura
    $winreFile.Attributes = 'Normal'

    $tempWinrePath = Join-Path $winreStaging "winre.wim"
    Copy-Item -LiteralPath $winrePath -Destination $tempWinrePath -Force

    Write-Host "[3/5] Montando winre.wim (Esto puede tardar unos segundos)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "WinRE_Manager: Montando winre.wim temporal via DISM..."
    dism /mount-image /imagefile:"$tempWinrePath" /index:1 /mountdir:"$winreMount"

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] No se pudo montar winre.wim. Abortando..." -ForegroundColor Red
        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Fallo critico al montar winre.wim. Codigo DISM: $LASTEXITCODE"
        
        # FIX: Evitar la bomba nuclear global, solo desmontamos nuestro dir
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Ejecutando limpieza de emergencia (discard) especificamente en $winreMount."
        dism /unmount-image /mountdir:"$winreMount" /discard 2>$null | Out-Null
        
        # Restaurar atributos si falla
        $winreFile = Get-Item -LiteralPath $winrePath -Force
        $winreFile.Attributes = $originalAttributes
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Atributos restaurados tras el fallo de montaje."
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
            Write-Host "   [1] Inyectar Addons (.tpk, .bpk, .reg,)"
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
                #  MOTOR DE COMPRESIÓN EXTREMA (EXPORT-IMAGE)
                # =========================================================
                $optimizedWinrePath = Join-Path $winreStaging "winre_optimized.wim"
                $sizeBefore = (Get-Item -LiteralPath $tempWinrePath).Length
                
                Write-Host "      -> Ejecutando reconstruccion de diccionario WIM (Tardara unos minutos)..." -ForegroundColor Cyan
                Write-Log -LogLevel ACTION -Message "WinRE_Manager: Ejecutando Export-Image con flag /Bootable para reconstruir el diccionario WIM."
                
                $dismArgs = "/Export-Image /SourceImageFile:`"$tempWinrePath`" /SourceIndex:1 /DestinationImageFile:`"$optimizedWinrePath`" /Bootable"
                $proc = Start-Process "dism.exe" -ArgumentList $dismArgs -Wait -NoNewWindow -PassThru

                if ($proc.ExitCode -eq 0 -and (Test-Path -LiteralPath $optimizedWinrePath)) {
                    # Eliminamos el WinRE viejo e inflado de la imagen base
                    Remove-Item -LiteralPath $winrePath -Force -ErrorAction SilentlyContinue
                    
                    # Movemos el nuevo y comprimido a su lugar
                    Move-Item -LiteralPath $optimizedWinrePath -Destination $winrePath -Force

                    # FIX: Restauramos el ACL original (Propiedad de TrustedInstaller)
                    Set-Acl -Path $winrePath -AclObject $originalAcl
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: ACL original restaurado en el winre.wim optimizado."

                    $sizeAfter = (Get-Item -LiteralPath $winrePath).Length
                    $savedMB = [math]::Round(($sizeBefore - $sizeAfter) / 1MB, 2)
                    $finalMB = [math]::Round($sizeAfter / 1MB, 2)

                    Write-Host "[EXITO] WinRE optimizado e integrado correctamente." -ForegroundColor Green
                    Write-Host "        Tamano final: $finalMB MB (Ahorro de $savedMB MB de peso muerto)." -ForegroundColor DarkGreen
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Optimizacion exitosa. Tamano final: $finalMB MB (Ahorro: $savedMB MB)."
                } else {
                    Write-Host "[ADVERTENCIA] La compresion profunda fallo (Codigo: $($proc.ExitCode))." -ForegroundColor Red
                    Write-Host "              Aplicando metodo de volcado de emergencia..." -ForegroundColor Yellow
                    Write-Log -LogLevel WARN -Message "WinRE_Manager: Fallo Export-Image (Codigo: $($proc.ExitCode)). Aplicando volcado de emergencia."
                    
                    # Fallback de Seguridad
                    Copy-Item -LiteralPath $tempWinrePath -Destination $winrePath -Force
                    
                    # FIX: Restauramos el ACL original en el fallback también
                    Set-Acl -Path $winrePath -AclObject $originalAcl
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: ACL original restaurado en el winre.wim de volcado de emergencia."
                    
                    Write-Host "[OK] WinRE guardado con exito (Sin compresion adicional)." -ForegroundColor Green
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
            Write-Log -LogLevel INFO -Message "WinRE_Manager: Atributos restaurados tras descartar los cambios."
        }
    } finally {
        # --- RESTAURAR EL ESTADO GLOBAL (CRÍTICO) ---
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Restaurando variable global MOUNT_DIR, atributos originales y limpiando temporales."
        $Script:MOUNT_DIR = $originalMountDir
        
        # FIX: Restaurar SIEMPRE los atributos (Hidden, System), sin importar si hubo éxito, error o crash
        if (Test-Path -LiteralPath $winrePath) {
            $restoredFile = Get-Item -LiteralPath $winrePath -Force
            $restoredFile.Attributes = $originalAttributes
            Write-Log -LogLevel INFO -Message "WinRE_Manager: Asegurando que winre.wim mantenga sus atributos nativos (Hidden, System)."
        }
        
        # Limpieza de basura temporal
        Write-Log -LogLevel INFO -Message "WinRE_Manager: Limpiando directorios de Staging y Mount."
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
    Write-Host "   [1] En Windows PE (Indice $idxPE)" -ForegroundColor White
    Write-Host "       (Para crear un USB booteable exclusivo de diagnostico)" -ForegroundColor Gray
    Write-Host ""
	Write-Host "   [2] En el Instalador (Indice $idxSetup)" -ForegroundColor White
    Write-Host "       (Aparecera al pulsar 'Reparar el equipo' durante la instalacion)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "   [M] Seleccion Manual (Si la deteccion fallo)" -ForegroundColor DarkGray
    
    $sel = Read-Host "Selecciona una opcion"
    $targetIndex = $null

    switch ($sel) {
        "1" { $targetIndex = $idxPE }
        "2" { $targetIndex = $idxSetup }
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
        Write-Host "   [6] Limpiar Componentes" -NoNewline; Write-Host "    (DISM /StartComponentCleanup)" -ForegroundColor Gray
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

                            $dismArgs = @(
                                "/Image:`"$MountDir`"", 
                                "/Cleanup-Image", 
                                "/RestoreHealth", 
                                "/Source:${sourceType}:`"$sourceWimPath`":$sourceIndex", 
                                "/LimitAccess"
                            )

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
                $useResetBaseSeq = Read-Host "`nAntes de iniciar: ¿Deseas incluir el parametro /ResetBase en la limpieza final?`n[ADVERTENCIA] Impide desinstalar actualizaciones previas (S/N)"
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

            # 2. Clasificacion
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
        
        # Cargar Catalogo (Logica existente)
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
            
            # Actualizar cache
            $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            & $PopulateList
            
            Write-Log -LogLevel INFO -Message "AppxManager: Lista visual recargada correctamente."
        } else {
            Write-Log -LogLevel INFO -Message "AppxManager: El usuario cancelo la eliminacion en el cuadro de confirmacion."
        }
    })

    $form.ShowDialog() | Out-Null
    # 1. Destrucción explícita del control pesado
    if ($null -ne $listView) {
        $listView.Dispose()
    }
    # 2. Destrucción del formulario
    $form.Dispose()
    # 3. Forzar limpieza profunda
    [GC]::Collect()
	$script:cachedApps = $null
    [GC]::WaitForPendingFinalizers()
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

    # 1. Destrucción explícita de objetos GDI y controles pesados
    if ($null -ne $globalListViews) {
        foreach ($lv in $globalListViews) {
            # Si el ListView tiene un ImageList asociado, destrúyelo primero
            if ($null -ne $lv.SmallImageList) { 
                $lv.SmallImageList.Dispose() 
            }
            # Destruir el control
            $lv.Dispose()
        }
        $globalListViews.Clear()
        $globalListViews = $null
    }

    # 2. Destrucción del formulario padre
    $form.Dispose()

    # 3. Forzar limpieza profunda de memoria
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

}

# =================================================================
#  MODULO DE INYECCION DE ADDONS (.WIM, .TPK, .BPK, .REG,)
# =================================================================
# --- HELPER 1: Importador de Registro Silencioso (Headless) ---
function Import-OfflineReg {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath
    )

    Write-Log -LogLevel INFO -Message "Procesando Registro Automatizado: $FilePath"

    $lines         = [System.IO.File]::ReadAllLines($FilePath)
    $cleanLines    = New-Object System.Collections.Generic.List[string]
    $keysToProcess = New-Object System.Collections.Generic.HashSet[string]

    # Hives bloqueados: CBS/DISM (COMPONENTS), seguridad (SECURITY, SAM)
    $SHIELDED_HIVES = "COMPONENTS|TK_COMPONENTS|SECURITY|TK_SECURITY|SAM|TK_SAM"

    $componentsSkipped  = 0
    $skipCurrentSection = $false
    $isFirst            = $true

    foreach ($line in $lines) {

        # ── PASO 1: Primera línea — BOM y cabecera del archivo
        if ($isFirst) {
            $line = $line.TrimStart([char]0xFEFF, [char]0xEF, [char]0xBB, [char]0xBF)
            if ($line -match 'Windows Registry Editor Version 5\.00') {
                $line = 'Windows Registry Editor Version 5.00'
            }
            $isFirst = $false
            $cleanLines.Add($line)
            continue
        }

        # ── PASO 2: Detección de cabecera de clave
        if ($line -match '^\[-?(?:HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_CLASSES_ROOT|HKLM|HKCU|HKCR)\\') {

            $rawKeyPath = $line -replace '^\[-?', '' -replace '\].*$', ''

            # ── ESCUDO DE INTEGRIDAD — evaluar sobre ruta SIN traducir
            if ($rawKeyPath -match '(?i)^(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:' + $SHIELDED_HIVES + ')') {
                $skipCurrentSection = $true
                $componentsSkipped++
                Write-Log -LogLevel WARN -Message "Import-OfflineReg: [ESCUDO] Seccion bloqueada -> $line"
                continue
            }
            $skipCurrentSection = $false

            # ── TRADUCCIÓN DE RUTAS
            # Bloque 1: TK_CLASSES bajo HKLM — debe ir ANTES que el bloque SOFTWARE
            # para evitar que HKLM\TK_CLASSES sea ignorado por la guarda de HKCR.
            $line = $line -replace '(?i)(?:HKEY_LOCAL_MACHINE|HKLM)\\TK_CLASSES', `
                                   'HKEY_LOCAL_MACHINE\OfflineSoftware\Classes'

            # Bloque 2: HKEY_CLASSES_ROOT / HKCR — solo si la línea NO es ya HKLM
            # (evita doble sustitución tras el reemplazo de TK_CLASSES de arriba)
            if ($line -notmatch '(?i)HKEY_LOCAL_MACHINE') {
                $line = $line -replace '(?i)HKEY_CLASSES_ROOT', `
                                       'HKEY_LOCAL_MACHINE\OfflineSoftware\Classes' `
                              -replace '(?i)^\[-?HKCR\\', `
                                       '[HKEY_LOCAL_MACHINE\OfflineSoftware\Classes\'
            }

            # Bloque 3: SYSTEM — CurrentControlSet ANTES que SYSTEM genérico
            $controlSet = Get-OfflineControlSet
            $line = $line -replace '(?i)(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)\\CurrentControlSet', `
                                   "HKEY_LOCAL_MACHINE\OfflineSystem\$controlSet" `
                          -replace '(?i)(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SYSTEM|TK_SYSTEM)', `
                                   'HKEY_LOCAL_MACHINE\OfflineSystem'

            # Bloque 4: SOFTWARE
            $line = $line -replace '(?i)(?:HKEY_LOCAL_MACHINE|HKLM)\\(?:SOFTWARE|TK_SOFTWARE)', `
                                   'HKEY_LOCAL_MACHINE\OfflineSoftware'

            # Bloque 5: HKCU\Software\Classes — ANTES que HKCU genérico
            $line = $line -replace '(?i)(?:HKEY_CURRENT_USER|HKCU)\\(?:Software|TK_SOFTWARE)\\Classes', `
                                   'HKEY_LOCAL_MACHINE\OfflineUserClasses' `
                          -replace '(?i)^\[-?HKCU\\Software\\Classes', `
                                   '[HKEY_LOCAL_MACHINE\OfflineUserClasses'

            # Bloque 6: HKCU genérico — DESPUÉS del bloque de Classes
            $line = $line -replace '(?i)(?:HKEY_CURRENT_USER|HKEY_LOCAL_MACHINE\\TK_USER)', `
                                   'HKEY_LOCAL_MACHINE\OfflineUser' `
                          -replace '(?i)^\[-?HKCU\\', `
                                   '[HKEY_LOCAL_MACHINE\OfflineUser\'
        }

        # ── PASO 3: Escudo activo — descartar valores de secciones bloqueadas
        if ($skipCurrentSection) { continue }

        # ── PASO 4: Registrar clave traducida para desbloqueo SDDL
        if ($line -match '^\[-?(HKEY_LOCAL_MACHINE\\[^\]]+)\]$') {
            $null = $keysToProcess.Add($matches[1].Trim())
        }

        # ── PASO 5: Línea validada → buffer limpio
        $cleanLines.Add($line)
    }

    if ($componentsSkipped -gt 0) {
        Write-Log -LogLevel WARN -Message "Import-OfflineReg: [ESCUDO] $componentsSkipped secciones bloqueadas (COMPONENTS/SECURITY/SAM) en '$([System.IO.Path]::GetFileName($FilePath))'."
    }

    # Archivo temporal con nombre trazable + GUID corto (evita colisiones)
    $safeName = ([System.IO.Path]::GetFileNameWithoutExtension($FilePath)) -replace '[\\/:*?"<>|]', '_'
    $tempReg  = Join-Path $Script:Scratch_DIR "Temp_${safeName}_$([System.Guid]::NewGuid().ToString('N').Substring(0, 8)).reg"
    [System.IO.File]::WriteAllLines($tempReg, $cleanLines, [System.Text.Encoding]::Unicode)

    # Desbloqueo SDDL de todas las claves a modificar
    foreach ($targetKey in $keysToProcess) {
        Unlock-OfflineKey -KeyPath $targetKey
    }

    # INYECCIÓN BLINDADA
    $procInfo                        = New-Object System.Diagnostics.ProcessStartInfo
    $procInfo.FileName               = "reg.exe"
    $procInfo.Arguments              = "import `"$tempReg`""
    $procInfo.RedirectStandardError  = $true
    $procInfo.UseShellExecute        = $false
    $procInfo.CreateNoWindow         = $true

    $errBuilder = New-Object System.Text.StringBuilder
    $process    = [System.Diagnostics.Process]::Start($procInfo)

    # Lectura asíncrona del stderr para evitar deadlock con buffers grandes
    $errEvent = Register-ObjectEvent -InputObject $process `
        -EventName "ErrorDataReceived" `
        -Action { if ($Event.SourceEventArgs.Data) { $errBuilder.AppendLine($Event.SourceEventArgs.Data) | Out-Null } }

    $process.BeginErrorReadLine()
    $process.WaitForExit()

    Unregister-Event -SourceIdentifier $errEvent.Name -ErrorAction SilentlyContinue
    $errOut = $errBuilder.ToString().Trim()

    # Restaurar permisos originales (SDDL) y limpiar el diccionario
    foreach ($path in @($Script:SDDL_Backups.Keys)) {
        Restore-KeyOwner -KeyPath "HKLM:\$path"
    }
    if ($null -ne $Script:SDDL_Backups) { $Script:SDDL_Backups.Clear() }

    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

    # Evaluación de resultado — stderr es más confiable que ExitCode en reg.exe
    if ($process.ExitCode -ne 0 -or $errOut -match '(?i)ERROR|Access is denied|Acceso denegado') {
        Write-Log -LogLevel ERROR -Message "Import-OfflineReg: reg.exe fallo (ExitCode: $($process.ExitCode)) | Detalle: $errOut"
        throw "Error critico al inyectar el registro. Motor devolvio: $errOut"
    }

    Write-Log -LogLevel INFO -Message "Import-OfflineReg: Registro inyectado exitosamente."
}

# --- HELPER 2: Extractor Inteligente por Analisis de Cabecera ---
function Expand-AddonArchive {
    param([string]$FilePath, [string]$DestPath, [int]$WimIndex = 1)
    
    # 1. Validar Firma Binaria
    $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = New-Object byte[] 4
    $stream.Read($buffer, 0, 4) | Out-Null
    $stream.Close()
    $hexSignature = [BitConverter]::ToString($buffer) -replace '-'

    if (-not (Test-Path $DestPath)) { New-Item -Path $DestPath -ItemType Directory -Force | Out-Null }

    if ($hexSignature -match "^4D535749") { 
        $actualIndexToExtract = $WimIndex

        # 2. Contar índices usando DISM nativo (Ignora la extensión del archivo)
        $dismInfo = dism.exe /Get-WimInfo /WimFile:"$FilePath" /English | Select-String "Index :"
        $indexCount = @($dismInfo).Count

        # 3. Lógica de Fallback Estricta
        if ($indexCount -eq 1) {
            $actualIndexToExtract = 1
            Write-Log -LogLevel INFO -Message "Paquete de indice unico detectado ($indexCount). Forzando extraccion del Indice 1."
        } elseif ($indexCount -eq 0) {
            # Fallback por si la consola falla al leer
            $actualIndexToExtract = 1
            Write-Log -LogLevel WARN -Message "No se pudieron contar los indices. Forzando Indice 1 por seguridad."
        }

        Write-Log -LogLevel INFO -Message "Firma detectada: WIM (MSWI). Extrayendo payload (Indice $actualIndexToExtract)..."

        # 4. Extraer usando DISM nativo
        $proc = Start-Process "dism.exe" -ArgumentList "/Apply-Image /ImageFile:`"$FilePath`" /Index:$actualIndexToExtract /ApplyDir:`"$DestPath`"" -Wait -NoNewWindow -PassThru
        
        if ($proc.ExitCode -ne 0) {
            throw "DISM /Apply-Image fallo al extraer el paquete (Codigo de salida: $($proc.ExitCode))."
        }
    }
    else {
        throw "Formato no reconocido (Firma: $hexSignature). No es un empaquetado valido."
    }
}

# --- MOTOR PRINCIPAL: Inyector de Addons ---
function Install-OfflineAddon {
    param([string]$FilePath, [int]$WimIndex = 1)
    
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    
    if ($ext -eq '.reg') {
        Import-OfflineReg -FilePath $FilePath
        return "Registro inyectado exitosamente."
    }

    if ($ext -match '\.(wim|tpk|bpk)$') {
        $tempExtract = Join-Path $Script:Scratch_DIR "Addon_$baseName"

        try {
            # Extraemos el payload usando nuestro extractor blindado
            Expand-AddonArchive -FilePath $FilePath -DestPath $tempExtract -WimIndex $WimIndex

            # --- FASE A: Inyeccion de Archivos (Mapeo de Estructura Blindado) ---
            $hasFiles = $false
            
            # Verificamos si hay ALGO en la raiz extraida (Excluyendo los .reg)
            $payloadFiles = Get-ChildItem -Path $tempExtract -Force | Where-Object { $_.Extension -ne '.reg' }
            
            if ($payloadFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando estructura de archivos completa hacia $Script:MOUNT_DIR"
                
                # Activamos privilegios (SeBackup / SeRestore)
                Enable-Privileges

                $safeMountDir = $Script:MOUNT_DIR.TrimEnd('\', '/')

				# Usamos Robocopy en Modo Backup (/B) para ignorar permisos de TrustedInstaller
                # /E = Recursivo | /B = Backup Mode | /IS = Sobrescribir iguales | /IT = Sobrescribir modificados
                # /R:0 /W:0 = Sin reintentos | /NJH /NJS /NDL /NC /NS /NP = Totalmente silencioso
                $roboArgs = "`"$tempExtract`" `"$safeMountDir`" /E /B /IS /IT /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP"
                
                $proc = Start-Process robocopy.exe -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
                
                # Evaluamos el bitmask de Robocopy (8 o superior es fallo critico)
                if ($proc.ExitCode -ge 8) {
                    Write-Log -LogLevel ERROR -Message "Robocopy fallo al inyectar la carga util (Codigo: $($proc.ExitCode))"
                    throw "Robocopy fallo en $safeMountDir. Bug de sintaxis o bloqueo de archivos. (Codigo: $($proc.ExitCode))"
                }
                
                $hasFiles = $true
            }

            # --- FASE B: Inyección de Registro ---
            $regFiles = Get-ChildItem -Path $tempExtract -Filter "*.reg" -Recurse
            foreach ($reg in $regFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando registro adjunto: $($reg.Name)"
                Import-OfflineReg -FilePath $reg.FullName
            }

            $msg = "Inyectado: "
            if ($hasFiles) { $msg += "[Archivos] " }
            if ($regFiles) { $msg += "[Registro] " }
            return $msg.Trim()

        } finally {
            # Limpieza absoluta garantizada
            if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    throw "Formato no soportado para inyeccion automatica."
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

    # NUEVO: Botón de Información / Ayuda
    $btnHelp = New-Object System.Windows.Forms.Button
    $btnHelp.Text = "?"
    $btnHelp.Location = "630, 12"
    $btnHelp.Size = "30, 30"
    $btnHelp.BackColor = [System.Drawing.Color]::DarkOrange
    $btnHelp.FlatStyle = "Flat"
    $btnHelp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnHelp)

    $btnAddFiles = New-Object System.Windows.Forms.Button
    $btnAddFiles.Text = "+ Agregar Addons (.wim, .tpk, .bpk, .reg)..."
    $btnAddFiles.Location = "670, 12"
    $btnAddFiles.Size = "240, 30"
    $btnAddFiles.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddFiles.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFiles)

    # NUEVO: Label de advertencia de nomenclatura (Texto Rápido)
    $lblNomenclatura = New-Object System.Windows.Forms.Label
    $lblNomenclatura.Text = "Aviso: Usa los sufijos _x64, _x86 en el nombre del archivo para activar el Escudo de Arquitectura.`nY para los Paquetes principales debe incluir _main al final del nombre es MUY IMPORTANTE"
    $lblNomenclatura.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
    $lblNomenclatura.ForeColor = [System.Drawing.Color]::White
    $lblNomenclatura.Location = "20, 42"
    $lblNomenclatura.AutoSize = $true
    $form.Controls.Add($lblNomenclatura)

    # --- DETECCIÓN INTELIGENTE DE ARQUITECTURA (INSTANTÁNEA) ---
    $defaultIdx = 1 # Asumimos x86 por defecto
    if (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) {
        $defaultIdx = 2 # Si existe SysWOW64, es un Windows x64 garantizado
    }

    # --- SELECTOR DE ARQUITECTURA (GRUPO) ---
    $grpArch = New-Object System.Windows.Forms.GroupBox
    $grpArch.Text = " Arquitectura del Addon (Solo aplica para desempaquetar .wim/.tpk/.bpk) "
    $grpArch.Location = "20, 65" 
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
    $lv.Location = "20, 135"
    $lv.Size = "890, 360"
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
    $lblStatus.Location = "20, 505"
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    $btnRemoveItem = New-Object System.Windows.Forms.Button
    $btnRemoveItem.Text = "Quitar de la lista"
    $btnRemoveItem.Location = "20, 530"
    $btnRemoveItem.Size = "150, 30"
    $btnRemoveItem.BackColor = [System.Drawing.Color]::Crimson
    $btnRemoveItem.FlatStyle = "Flat"
    $form.Controls.Add($btnRemoveItem)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "INYECTAR TODOS LOS ADDONS"
    $btnInstall.Location = "640, 520"
    $btnInstall.Size = "270, 40"
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.FlatStyle = "Flat"
    $btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnInstall)

    # --- EVENTO DEL BOTÓN DE AYUDA ---
    $btnHelp.Add_Click({
        $helpMsg = "INSTRUCCIONES DE NOMENCLATURA PARA ADDONS`n`n"
        $helpMsg += "Para que el motor inteligente proteja tu imagen WIM de colapsos, "
        $helpMsg += "los archivos deben indicar su arquitectura en el nombre ANTES de la extension.`n`n"
        $helpMsg += "Ejemplos Correctos:`n"
        $helpMsg += "  >  MiPaquetePrincipal_main.tpk`n"
		$helpMsg += "  >  Registro_x64_main.reg`n"
        $helpMsg += "  >  MiPaqueteIdioma_x64_es-mx.tpk`n"
        $helpMsg += "  >  Herramienta_main.bpk`n`n"
        $helpMsg += "Por que es importante?`n"
        $helpMsg += "Si agregas una carpeta entera de Addons, el script leera estos sufijos y "
        $helpMsg += "OMITIRA automaticamente los paquetes/Registro 'x86' o 'arm' si tu imagen de destino es 'x64', "
        $helpMsg += "evitando pantallas azules y corrupcion en la instalacion."

        [System.Windows.Forms.MessageBox]::Show($helpMsg, "Reglas de Empaquetado", 'OK', 'Information')
    })

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
			[System.Windows.Forms.Application]::DoEvents()
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
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Iniciando proceso de descarga de colmenas de registro."
    
    # 1. TRUCO DE VETERANO: El "Doble Tap" al Recolector de Basura.
    # Asegura que las referencias circulares de WinForms y COM se purguen completamente.
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Ejecutando recoleccion de basura (GC) agresiva para liberar handles."
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    [GC]::Collect() 
    
    # Pausa de seguridad para permitir que el kernel libere los archivos fisicos
    Write-Host "Esperando a que el sistema libere los manejadores de archivos..." -ForegroundColor DarkGray
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Pausa de seguridad de 5 segundos para liberar bloqueos del kernel."
    Start-Sleep -Seconds 5
    
    # Lista ampliada de Hives a descargar
    $hives = @(
        "HKLM\OfflineSystem", 
        "HKLM\OfflineSoftware", 
        "HKLM\OfflineComponents", 
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
            Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Colmena detectada como montada -> $hive. Procediendo a descargar."
            $retries = 0; $done = $false
            while ($retries -lt 5 -and -not $done) {
                
                # Intentamos el desmontaje nativo
                reg unload $hive 2>$null | Out-Null
                
                if ($LASTEXITCODE -eq 0) { 
                    $done = $true 
                    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: [EXITO] $hive desmontada correctamente en el intento $($retries + 1)."
                } else { 
                    $retries++
                    Write-Host "." -NoNewline -ForegroundColor Yellow
                    Write-Log -LogLevel WARN -Message "UNMOUNT_HIVES: Intento $retries fallido al desmontar $hive. Reintentando..."
                    
                    # 3. RECOLECCIÓN DINÁMICA: Si falla, forzamos al GC *dentro* del bucle.
                    # A veces un handle tardío se suelta justo aquí.
                    [GC]::Collect()
                    
                    # Espera incremental entre reintentos
                    Start-Sleep -Milliseconds (500 * $retries) 
                }
            }
            if (-not $done) { 
                Write-Log -LogLevel ERROR -Message "UNMOUNT_HIVES: Fallo CRITICO al desmontar $hive tras 5 intentos. Archivo permanentemente bloqueado."
                
                # FRENO DE EMERGENCIA: Si no abortamos aquí, DISM corromperá la imagen (CONFIG_INITIALIZATION_FAILED)
                $errMsg = "ERROR LETAL: La colmena $hive sigue bloqueada en memoria por un proceso externo o el Antivirus.`n`nSi la imagen se guarda (Commit) en este estado, QUEDARA CORRUPTA (Pantallazo Azul).`nCierra cualquier programa, pausa el Antivirus e inténtalo de nuevo."
                
                Add-Type -AssemblyName System.Windows.Forms
                [System.Windows.Forms.MessageBox]::Show($errMsg, "Peligro de Corrupcion", 'OK', 'Error')
                
                throw $errMsg
            }
        } else {
            Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: La colmena $hive no estaba montada. Se omite."
        }
    }
    Write-Host " [Proceso Finalizado]" -ForegroundColor Green
    Write-Log -LogLevel INFO -Message "UNMOUNT_HIVES: Proceso de descarga de colmenas finalizado sin errores."
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
    $cleanPath = $cleanPath.Trim()

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

# Diccionario global en RAM para almacenar los permisos exactos de fabrica
$Script:SDDL_Backups = @{}

function Unlock-OfflineKey {
    param([string]$KeyPath)
    
    Enable-Privileges

    # Normalizar ruta
    $psPath = $KeyPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|Registry::HKEY_LOCAL_MACHINE|Registry::HKLM)[:\\]*", ""
    $finalSubKey = $psPath
    $rootHive = [Microsoft.Win32.Registry]::LocalMachine
    
    # Buscar el ancestro más cercano que exista y esté bloqueado
    while ($true) {
        $check = $null
        try {
            # Intentamos abrir con permisos de ESCRITURA
            $check = $rootHive.OpenSubKey($finalSubKey, [System.Security.AccessControl.RegistryRights]::WriteKey)
            
            if ($check) { 
                # La clave existe y ya tenemos acceso de escritura. No hay nada que desbloquear.
                return 
            }
            # Si llega aquí sin lanzar excepción, $check es $null (la clave NO existe aún).
            # Debemos subir un nivel para evaluar al padre.
        } catch [System.Security.SecurityException] {
            # La clave existe, pero el acceso fue denegado. ¡Esta es la que debemos desbloquear!
            break 
        } catch {
            # Otro tipo de error (ej. corrupción de colmena). Abortamos por seguridad.
            Write-Log -LogLevel WARN -Message "Unlock-OfflineKey: Error inesperado en $finalSubKey - $($_.Exception.Message)"
            return
        } finally {
            if ($null -ne $check) { $check.Dispose() }
        }
        
        $lastSlash = $finalSubKey.LastIndexOf("\")
        if ($lastSlash -lt 0) { return } # Evita intentar desbloquear la raíz si no existe
        $finalSubKey = $finalSubKey.Substring(0, $lastSlash)
    }

    Unlock-Single-Key -SubKeyPath $finalSubKey
}

function Unlock-Single-Key {
    param([string]$SubKeyPath)
    
    # Protección absoluta de las raíces de las colmenas
    if ($SubKeyPath -match "^(OfflineSystem|OfflineSoftware|OfflineUser|OfflineUserClasses|OfflineComponents)$") { return }
    
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
            $p = Start-Process regini.exe -ArgumentList "`"$tempFile`"" -PassThru -WindowStyle Hidden -Wait
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

function Restore-KeyOwner {
    param([string]$KeyPath)
    
    Enable-Privileges 
    $cleanPath = $KeyPath -replace "^Registry::", ""
    $subPath = $cleanPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|HKLM:|HKEY_LOCAL_MACHINE:)[:\\]+", ""
    $hive = [Microsoft.Win32.Registry]::LocalMachine
    $keyObj = $null

    # =========================================================
    # RESTAURACIÓN QUIRÚRGICA VÍA SDDL (Prioridad Absoluta)
    # =========================================================
    if ($Script:SDDL_Backups.ContainsKey($subPath)) {
        try {
            $originalSddl = $Script:SDDL_Backups[$subPath]
            $rights = [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::TakeOwnership
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $rights)
            
            if ($keyObj) {
                $aclRestored = New-Object System.Security.AccessControl.RegistrySecurity
                $aclRestored.SetSecurityDescriptorSddlForm($originalSddl)
                $keyObj.SetAccessControl($aclRestored)
                
                Write-Log -LogLevel INFO -Message "Restauracion SDDL Limpia: $subPath"
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
    
    $isUserHive = $subPath -match "OfflineUser"
    $targetOwner = if ($isUserHive) { $sidAdmin } else { $sidTrusted }

    try {
        # Paso 1: Retirar TODAS las reglas de Administradores sin modificar la herencia
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl()
            
            # CORRECCIÓN BUG 2: Purgamos todas las reglas del SID en lugar de buscar coincidencias exactas
            $acl.PurgeAccessRules($sidAdmin) 
            
            $keyObj.SetAccessControl($acl)
            $keyObj.Dispose(); $keyObj = $null
        }

        # Paso 2: Devolver el propietario a TrustedInstaller (Si es de sistema)
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

function Get-OfflineControlSet { 
    if ($null -ne $Script:CachedControlSet) {
        return $Script:CachedControlSet
    }

    # CRÍTICO: Validar que el hive esté montado antes de asumir nada
    if (-not (Test-Path "HKLM:\OfflineSystem")) {
        Write-Log -LogLevel WARN -Message "Get-OfflineControlSet: OfflineSystem no esta montado. Imposible determinar ControlSet."
        return $null
    }

    $SystemHivePath = "HKLM:\OfflineSystem"
    $currentSet = 1
    
    if (Test-Path "$SystemHivePath\Select") {
        try {
            $props = Get-ItemProperty -Path "$SystemHivePath\Select" -ErrorAction SilentlyContinue
            if ($props -and $props.Current) {
                $currentSet = $props.Current
            }
        } catch {
            Write-Log -LogLevel WARN -Message "No se pudo leer HKLM:\OfflineSystem\Select. Usando Default (001)."
        }
    }
    
    $Script:CachedControlSet = "ControlSet{0:d3}" -f $currentSet
    return $Script:CachedControlSet
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
                            # Extraemos el valor original tal cual esta
                            $currVal = $raw.ToString()
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
                            # Extraemos el valor original tal cual esta
                            $currVal = $raw.ToString()
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

        $res = [System.Windows.Forms.MessageBox]::Show("Se fusionaran e importaran $($lvQ.Items.Count) archivos en una sola transaccion.`nDesea continuar?", "Confirmar Lote", 'YesNo', 'Question')
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
            $process = Start-Process reg.exe -ArgumentList "import `"$tempReg`"" -Wait -PassThru -WindowStyle Hidden
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
                            if ([string]::IsNullOrWhiteSpace($safeVal)) {
                                if ($type -eq [Microsoft.Win32.RegistryValueKind]::DWord -or $type -eq [Microsoft.Win32.RegistryValueKind]::QWord) {
                                    $safeVal = 0  # Fallback seguro para numéricos
                                } else {
                                    $safeVal = "" # Fallback seguro para cadenas
                                }
                            }

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

    # 1. Destrucción explícita de objetos GDI y controles pesados
    if ($null -ne $globalListViews) {
        foreach ($lv in $globalListViews) {
            # Si el ListView tiene un ImageList asociado, destrúyelo primero
            if ($null -ne $lv.SmallImageList) { 
                $lv.SmallImageList.Dispose() 
            }
            # Destruir el control
            $lv.Dispose()
        }
        $globalListViews.Clear()
        $globalListViews = $null
    }

    # 2. Destrucción del formulario padre
    $form.Dispose()

    # 3. Forzar limpieza profunda de memoria
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

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
                    
                    # Traducir numero de Arquitectura a Texto
                    switch ($info.Architecture) {
                        0  { $cachedImageArch = "x86" }
                        9  { $cachedImageArch = "x64" }
                        12 { $cachedImageArch = "ARM64" }
                        Default { $cachedImageArch = "Arch:$($info.Architecture)" }
                    }
                    
                    # Version
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
                
                # A) Deteccion de Arquitectura (Basada en carpetas)
                if (Test-Path "$sysDir\SysArm32") {
                    $cachedImageArch = "ARM64"
                } elseif (Test-Path "$sysDir\SysWOW64") {
                    $cachedImageArch = "x64"
                } elseif (Test-Path "$sysDir\System32") {
                    $cachedImageArch = "x86"
                } else {
                    $cachedImageArch = "Desconocida"
                }

                # B) Deteccion de Version (Kernel)
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

        # Mostrar detalles solo si esta montado
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "  + Detalles SO : " -NoNewline; Write-Host "$cachedImageName ($cachedImageArch)" -ForegroundColor Cyan
            Write-Host "  + Build       : " -NoNewline; Write-Host $cachedImageVer -ForegroundColor Cyan
            Write-Host "  + Directorio  : " -NoNewline; Write-Host $Script:MOUNT_DIR -ForegroundColor Gray
        }
        Write-Host "================================================================================" -ForegroundColor Cyan
        Write-Host ""        
        # Menu de Opciones (Diseño en 2 Columnas simuladas o Grupos)
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
        
        # Manejo de Errores y Navegacion
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
                    Write-Host "   [3] Despliegue a VHD / Disco Fisico" -ForegroundColor White
                    Write-Host "       (Aplica una imagen WIM/ESD a un VHDX o disco USB/externo)" -ForegroundColor Gray
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
    Write-Host "Ha ocurrido un error inesperado que detuvo la ejecución." -ForegroundColor Gray
    Write-Host "Error: " -NoNewline; Write-Host $_.ToString() -ForegroundColor Yellow
    Write-Host "Línea: " -NoNewline; Write-Host $line -ForegroundColor Cyan
    Write-Host ""

    # 3. Escribir Log Técnico Completo (Reporte Forense)
    $logPayload = @"

==================================================
CRASH REPORT - EXCEPCIÓN NO CONTROLADA
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
    Write-Host "El detalle técnico forense se ha guardado en el archivo de registro (Logs\Registro.log)." -ForegroundColor Gray
    Write-Warning "El sistema intentará desmontar las colmenas y limpiar el entorno automáticamente."
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
