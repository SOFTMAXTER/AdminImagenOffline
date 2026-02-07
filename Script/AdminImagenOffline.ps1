<#
.SYNOPSIS
    Administra imagenes de Windows (.wim, .esd) sin conexion.
.DESCRIPTION
    Permite montar, desmontar, guardar cambios, editar indices, convertir formatos (ESD/VHD a WIM),
    cambiar ediciones de Windows y realizar tareas de limpieza y reparacion en imagenes offline.
    Utiliza DISM y otras herramientas del sistema. Requiere ejecucion como Administrador.
.AUTHOR
    SOFTMAXTER
.VERSION
    1.4.6
#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.4.6"

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
        $confirmation = Read-Host "¿Deseas descargar e instalar la actualizacion ahora? (S/N)"
        
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
    `$itemsToRemove = Get-ChildItem -Path "$installPath" -Exclude "Logs", "config.json"
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
    if ($Script:IMAGE_MOUNTED -eq 1) {
        Write-Warning "La imagen ya se encuentra montada."
        Pause; return
    }

    $path = Select-PathDialog -DialogType File -Title "Seleccione la imagen a montar" -Filter "Archivos Soportados (*.wim,  *.vhd, *.vhdx)|*.wim;*.vhd;*.vhdx|Todos (*.*)|*.*"
    if ([string]::IsNullOrEmpty($path)) { Write-Warning "Operacion cancelada."; Pause; return }
    $Script:WIM_FILE_PATH = $path
    
    $extension = [System.IO.Path]::GetExtension($path).ToUpper()

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
        
        if ((Read-Host "Escribe 'SI' para adjuntar").ToUpper() -ne 'SI') {
            $Script:WIM_FILE_PATH = $null; return
        }

        try {
            Write-Host "[+] Montando VHD..." -ForegroundColor Yellow
            $vhdInfo = Mount-VHD -Path $Script:WIM_FILE_PATH -PassThru -ErrorAction Stop
            
            # 1. Escaneo Inteligente de Particiones
            $targetPart = $null
            $partitions = Get-Partition -DiskNumber $vhdInfo.Number | Where-Object { $_.Size -gt 1GB } # Filtramos EFI/MSR

            foreach ($part in $partitions) {
                # Auto-Asignar letra si falta
                if (-not $part.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction SilentlyContinue
                    $part.DriveLetter = $freeLet # Actualizamos objeto en memoria
                }
                
                # Verificar si es Windows
                if (Test-Path "$($part.DriveLetter):\Windows\System32\config\SYSTEM") {
                    $targetPart = $part
                    break 
                }
            }

            # 2. Seleccion (Automatica o Manual)
            if ($targetPart) {
                Write-Host "[AUTO] Windows detectado en particion $($targetPart.DriveLetter):" -ForegroundColor Green
                $selectedPart = $targetPart
            } else {
                # Fallback: Menu manual si no detectamos Windows
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
                if ($menuItems[$choice]) { $selectedPart = $menuItems[$choice] }
                else { throw "Seleccion invalida." }
            }

            # 3. Configurar Entorno Global
            $driveLetter = "$($selectedPart.DriveLetter):\"
            $Script:MOUNT_DIR = $driveLetter
            $Script:IMAGE_MOUNTED = 2         # Estado 2 = VHD
            $Script:MOUNTED_INDEX = $selectedPart.PartitionNumber
            
            Write-Host "[OK] VHD Montado en: $Script:MOUNT_DIR" -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "VHD Montado: $Script:WIM_FILE_PATH en $Script:MOUNT_DIR"

        } catch {
            Write-Host "Error VHD: $_"
            Write-Log -LogLevel ERROR -Message "Fallo montaje VHD: $_"
            try { Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction SilentlyContinue } catch {}
            $Script:WIM_FILE_PATH = $null
        }
        Pause; return
    }

    # =======================================================
    #  MODO WIM (DISM)
    # =======================================================
    Write-Host "[+] Leyendo WIM..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"

    $INDEX = Read-Host "`nNumero de indice a montar"
    
    # Limpieza proactiva de carpeta corrupta
    if ((Get-ChildItem $Script:MOUNT_DIR -Force -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0) {
        Write-Warning "El directorio de montaje no esta vacio ($Script:MOUNT_DIR)."
        if ((Read-Host "¿Limpiar carpeta? (S/N)") -match 'S') {
            dism /cleanup-wim
            Remove-Item "$Script:MOUNT_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host "[+] Montando (Indice: $INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Montando WIM: '$Script:WIM_FILE_PATH' (Idx: $INDEX)"
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        Write-Host "[OK] Imagen montada." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Fallo montaje (Code: $LASTEXITCODE)."
        if ($LASTEXITCODE.ToString("X") -match "C1420116|C1420117") {
            Write-Warning "Posible bloqueo de archivos. Reinicia o ejecuta Limpieza."
        }
        Write-Log -LogLevel ERROR -Message "Fallo montaje WIM. Code: $LASTEXITCODE"
    }
    Pause
}

function Unmount-Image {
    Clear-Host
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Warning "No hay ninguna imagen montada."
        Pause; return
    }

    Write-Host "[INFO] Iniciando secuencia de desmontaje segura..." -ForegroundColor Cyan

    # 1. Cierre proactivo de Hives (CRÍTICO)
    # Si no descargamos nuestros hives manuales, DISM fallará por "Acceso Denegado".
    Write-Host "   > Descargando hives del registro..." -ForegroundColor Gray
    Unmount-Hives
    
    # 2. Garbage Collection para liberar handles de .NET
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()

    # 3. Desmontaje VHD (Lógica separada)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        try {
            Write-Host "   > Desmontando disco virtual (VHD)..." -ForegroundColor Yellow
            Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
            Write-Host "[OK] VHD Desmontado." -ForegroundColor Green
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            Load-Config # Restaurar ruta original
        } catch {
            Write-Error "Fallo al desmontar VHD: $_"
            Write-Warning "Cierre cualquier carpeta abierta en la unidad virtual e intente de nuevo."
        }
        Pause; return
    }

    # 4. Bucle de Reintentos para WIM (Resiliencia)
    $maxRetries = 3
    $retry = 0
    $success = $false

    while ($retry -lt $maxRetries -and -not $success) {
        $retry++
        Write-Host "   > Intento $retry de $($maxRetries): Desmontando WIM (Discard)..." -ForegroundColor Yellow
        
        dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard
        
        if ($LASTEXITCODE -eq 0) {
            $success = $true
        } else {
            Write-Warning "Fallo el desmontaje (Codigo: $LASTEXITCODE). Esperando 3 segundos..."
            Start-Sleep -Seconds 3
            
            # Intento de limpieza intermedio
            if ($retry -eq 2) {
                Write-Host "   > Intentando limpieza de recursos (cleanup-wim)..." -ForegroundColor Red
                dism /cleanup-wim
            }
        }
    }

    if ($success) {
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
        Write-Host "[OK] Imagen desmontada correctamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Desmontaje exitoso tras $retry intentos."
    } else {
        Write-Host "[ERROR FATAL] No se pudo desmontar la imagen." -ForegroundColor Red
        Write-Host "Posibles causas: Antivirus escaneando, carpeta abierta en Explorador o CMD." -ForegroundColor Gray
        Write-Log -LogLevel ERROR -Message "Fallo crítico en Unmount-Image."
    }
    Pause
}

function Reload-Image {
    param([int]$RetryCount = 0)

    Clear-Host
    # Seguridad anti-bucle: Maximo 3 intentos
    if ($RetryCount -ge 3) {
        Write-Host "[ERROR FATAL] Se ha intentado recargar la imagen 3 veces sin exito."
        Write-Host "Es posible que un archivo este bloqueado por un Antivirus o el Explorador."
        Write-Log -LogLevel ERROR -Message "Reload-Image: Abortado tras 3 intentos fallidos."
        Pause
        return
    }

    if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "No hay imagen montada."; Pause; return }
    
    # Asegurar descarga de Hives antes de recargar
    Unmount-Hives 

    Write-Host "Intento de recarga: $($RetryCount + 1)" -ForegroundColor DarkGray
    Write-Host "[+] Desmontando imagen..." -ForegroundColor Yellow
    
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Error al desmontar. Ejecutando limpieza profunda..."
        Write-Log -LogLevel ERROR -Message "Fallo el desmontaje en recarga. Ejecutando cleanup-wim."
        
        dism /cleanup-wim
        
        # --- CORRECCION: Pausa de seguridad ---
        Write-Host "Esperando 5 segundos para liberar archivos..." -ForegroundColor Cyan
        Start-Sleep -Seconds 5 
        # -----------------------------------------------
        
        # Llamada recursiva con contador incrementado
        Reload-Image -RetryCount ($RetryCount + 1) 
        return
    }

    Write-Host "[+] Remontando imagen..." -ForegroundColor Yellow
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen recargada exitosamente." -ForegroundColor Green
        $Script:IMAGE_MOUNTED = 1
    } else {
        Write-Host "[ERROR] Error al remontar la imagen."
        $Script:IMAGE_MOUNTED = 0
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Guardar Cambios)
# =============================================
function Save-Changes {
    param ([string]$Mode) # 'Commit', 'Append' o 'NewWim'

    # 1. Validacion de Montaje
    if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "No hay imagen montada para guardar."; Pause; return }

    # 2. BLOQUEO VHD (Como discutimos antes)
    if ($Script:IMAGE_MOUNTED -eq 2) {
        Clear-Host
        Write-Warning "AVISO: Estas trabajando sobre un disco virtual (VHD/VHDX)."
        Write-Host "Los cambios en VHD se guardan automaticamente en tiempo real al editar archivos." -ForegroundColor Cyan
        Write-Host "No es necesario (ni posible) ejecutar operaciones de 'Commit' o 'Capture' aqui." -ForegroundColor Gray
        Write-Host "Simplemente desmonta la imagen para finalizar." -ForegroundColor Yellow
        Pause
        return
    }

    Write-Host "Preparando para guardar..." -ForegroundColor Cyan
    Unmount-Hives

	# 3. BLOQUEO ESD
    # Verificamos si la extension original era .esd
    $isEsd = ($Script:WIM_FILE_PATH -match '\.esd$')

    if ($isEsd -and ($Mode -match 'Commit|Append|NewWim')) {
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
        Write-Log -LogLevel ACTION -Message "Guardando cambios (Commit) en indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    } 
    elseif ($Mode -eq 'Append') {
        Clear-Host
        Write-Host "[+] Guardando cambios en un nuevo indice (Append)..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Guardando cambios (Append) en nuevo indice."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR" /append
    } 
    elseif ($Mode -eq 'NewWim') {
        Clear-Host
        Write-Host "--- Guardar como Nuevo Archivo WIM (Exportar Estado Actual) ---" -ForegroundColor Cyan
        
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
        if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; return }

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
        Write-Log -LogLevel ACTION -Message "Guardando copia en nuevo WIM: '$DEST_WIM_PATH' (Nombre: $IMAGE_NAME)"
        
        dism /Capture-Image /ImageFile:"$DEST_WIM_PATH" /CaptureDir:"$Script:MOUNT_DIR" /Name:"$IMAGE_NAME" /Description:"$IMAGE_DESC" /Compress:max /CheckIntegrity

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Copia guardada exitosamente en:" -ForegroundColor Green
            Write-Host "     $DEST_WIM_PATH" -ForegroundColor Cyan
            Write-Host "`nNOTA: La imagen original sigue montada. Debes desmontarla (sin guardar) al salir." -ForegroundColor Gray
        } else {
            Write-Host "[ERROR] Fallo al capturar la nueva imagen (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "Fallo Save-As NewWim. Codigo: $LASTEXITCODE"
        }
        Pause
        return 
    }

    # Bloque comun para Commit/Append exitoso
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Cambios guardados." -ForegroundColor Green
    } else {
        # Si llegamos aqui con un error, es un error legitimo de DISM (no por bloqueo de ESD)
        Write-Host "[ERROR] Fallo al guardar cambios (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo al guardar cambios ($Mode). Codigo: $LASTEXITCODE"
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Edicion de indices)
# =============================================
function Export-Index {
    Clear-Host
    if (-not $Script:WIM_FILE_PATH) {
        $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM de origen" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path)
		{
			Write-Warning "Operacion cancelada."
			Pause
			return
		}
        $Script:WIM_FILE_PATH = $path
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    $INDEX_TO_EXPORT = Read-Host "`nIngrese el numero de Indice que desea exportar"
    # Validar que INDEX_TO_EXPORT sea un numero valido podria añadirse aqui

    $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $wimFileObject.DirectoryName "$($wimFileObject.BaseName)_indice_$($INDEX_TO_EXPORT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Exportar indice como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; Pause; return }

    Write-Host "[+] Exportando Indice $INDEX_TO_EXPORT a '$DEST_WIM_PATH'..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Exportando Indice $INDEX_TO_EXPORT de '$($Script:WIM_FILE_PATH)' a '$DEST_WIM_PATH'."
    dism /export-image /sourceimagefile:"$Script:WIM_FILE_PATH" /sourceindex:$INDEX_TO_EXPORT /destinationimagefile:"$DEST_WIM_PATH"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Indice exportado exitosamente." -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Fallo al exportar el Indice (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo la exportacion del indice. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Delete-Index {
    Clear-Host
    if (-not $Script:WIM_FILE_PATH) {
        $path = Select-PathDialog -DialogType File -Title "Seleccione WIM para borrar indice" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) { Write-Warning "Operacion cancelada."; Pause; return }
        $Script:WIM_FILE_PATH = $path
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    $INDEX_TO_DELETE = Read-Host "`nIngrese el numero de Indice que desea eliminar"
    # Validar que INDEX_TO_DELETE sea un numero valido podria añadirse aqui

    $CONFIRM = Read-Host "Esta seguro que desea eliminar el Indice $INDEX_TO_DELETE de forma PERMANENTE? (S/N)"

    if ($CONFIRM -match '^(s|S)$') {
        Write-Host "[+] Eliminando Indice $INDEX_TO_DELETE..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Eliminando Indice $INDEX_TO_DELETE de '$($Script:WIM_FILE_PATH)'."
        dism /delete-image /imagefile:"$Script:WIM_FILE_PATH" /index:$INDEX_TO_DELETE
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Indice eliminado exitosamente." -ForegroundColor Green
        } else {
            Write-Host "[ERROR] Error al eliminar el Indice (Codigo: $LASTEXITCODE). Puede que este montado o en uso."
            Write-Log -LogLevel ERROR -Message "Fallo la eliminacion del indice. Codigo: $LASTEXITCODE"
        }
    } else {
        Write-Warning "Operacion cancelada."
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Conversion de Imagen)
# =============================================
function Convert-ESD {
    Clear-Host; Write-Host "--- Convertir ESD a WIM ---" -ForegroundColor Yellow

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo ESD a convertir" -Filter "Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if (-not $path) { Write-Warning "Operacion cancelada."; Pause; return }
    $ESD_FILE_PATH = $path

    Write-Host "[+] Obteniendo informacion de los indices del ESD..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$ESD_FILE_PATH"
    $INDEX_TO_CONVERT = Read-Host "`nIngrese el numero de indice que desea convertir"
    # Validar INDEX_TO_CONVERT

    $esdFileObject = Get-Item -Path $ESD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $esdFileObject.DirectoryName "$($esdFileObject.BaseName)_indice_$($INDEX_TO_CONVERT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Convertir ESD a WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; Pause; return }

    Write-Host "[+] Convirtiendo... Esto puede tardar varios minutos." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Convirtiendo ESD '$ESD_FILE_PATH' (Indice: $INDEX_TO_CONVERT) a WIM '$DEST_WIM_PATH'."
    dism /export-image /SourceImageFile:"$ESD_FILE_PATH" /SourceIndex:$INDEX_TO_CONVERT /DestinationImageFile:"$DEST_WIM_PATH" /Compress:max /CheckIntegrity

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Conversion completada exitosamente." -ForegroundColor Green
        Write-Host "Nuevo archivo WIM creado en: `"$DEST_WIM_PATH`"" -ForegroundColor Gray
        $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        Write-Host "La ruta del nuevo WIM ha sido cargada en el script." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "Conversion de ESD a WIM completada."
    } else {
        Write-Host "[ERROR] Error durante la conversion (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo la conversion de ESD. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Convert-VHD {
    Clear-Host
    Write-Host "--- Convertir VHD/VHDX a WIM (Auto-Mount) ---" -ForegroundColor Yellow
    
    # 1. Verificar modulo Hyper-V
    if (-not (Get-Command "Mount-Vhd" -ErrorAction SilentlyContinue)) {
        Write-Host "[ERROR] El cmdlet 'Mount-Vhd' no esta disponible."
        Write-Warning "Necesitas habilitar el modulo de Hyper-V o las herramientas de gestion de discos virtuales."
        Pause; return
    }

    # 2. Seleccion de Archivo
    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo VHD o VHDX a convertir" -Filter "Archivos VHD (*.vhd, *.vhdx)|*.vhd;*.vhdx|Todos (*.*)|*.*"
    if (-not $path) { Write-Warning "Operacion cancelada."; Pause; return }
    $VHD_FILE_PATH = $path

    # 3. Seleccion de Destino
    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; Pause; return }

    # 4. Metadatos
    Write-Host "`n--- Ingrese los metadatos para la nueva imagen WIM ---" -ForegroundColor Yellow
    $inputName = Read-Host "Ingrese el NOMBRE de la imagen (ej: Captured VHD)"
    $inputDesc = Read-Host "Ingrese la DESCRIPCION de la imagen (Enter = Auto)"
    
    if ([string]::IsNullOrWhiteSpace($inputName)) { $IMAGE_NAME = "Captured VHD" } else { $IMAGE_NAME = $inputName }
    if ([string]::IsNullOrWhiteSpace($inputDesc)) { $IMAGE_DESC = "Convertido desde VHD el $(Get-Date -Format 'yyyy-MM-dd')" } else { $IMAGE_DESC = $inputDesc }

    Write-Host "`n[+] Montando y analizando estructura del VHD..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Iniciando conversion inteligente de '$VHD_FILE_PATH'."

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
                    Write-Host "   [OK] Windows detectado en particion $DRIVE_LETTER`:" -ForegroundColor Green
                    break # ¡Encontrado! Dejamos de buscar.
                } else {
                    Write-Host "   [-] Particion $currentLet`: no contiene Windows. Ignorando." -ForegroundColor DarkGray
                }
            }
        }

        if (-not $DRIVE_LETTER) {
            throw "No se encontro ninguna instalacion de Windows valida en el VHD (se escanearon todas las particiones >3GB)."
        }

        Write-Host "   > Optimizando volumen antes de la captura (Trim)..." -ForegroundColor DarkGray
        Optimize-Volume -DriveLetter $DRIVE_LETTER -ReTrim -ErrorAction SilentlyContinue
        
		# 5. Captura (DISM)
        Write-Host "`n[+] Capturando volumen $DRIVE_LETTER`: a WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Capturando desde $DRIVE_LETTER`: a '$DEST_WIM_PATH'."

        dism /capture-image /imagefile:"$DEST_WIM_PATH" /capturedir:"$DRIVE_LETTER`:\" /name:"$IMAGE_NAME" /description:"$IMAGE_DESC" /compress:max /checkintegrity

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Captura completada exitosamente." -ForegroundColor Green
            $Script:WIM_FILE_PATH = $DEST_WIM_PATH
            Write-Log -LogLevel INFO -Message "Captura VHD->WIM finalizada OK."
        } else {
            Write-Host "[ERROR] Fallo DISM (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "Fallo captura DISM: $LASTEXITCODE"
        }

    } catch {
        Write-Host "Error critico durante la conversion: $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "Excepcion en Convert-VHD: $($_.Exception.Message)"
    } finally {
        # 6. Limpieza Final (Importante)
        if ($mountedDisk) {
            Write-Host "[+] Desmontando VHD..." -ForegroundColor Yellow
            Dismount-Vhd -Path $VHD_FILE_PATH -ErrorAction SilentlyContinue
        }
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
                Write-Log -LogLevel INFO -Message "Saliendo del menu de configuracion."
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
        Write-Host "       (Carga un .wim o .esd en $Script:MOUNT_DIR)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Desmontar Imagen (Descartar Cambios)"
        Write-Host "       (Descarga la imagen. ¡Cambios no guardados se pierden!)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Recargar Imagen (Descartar Cambios)"
        Write-Host "       (Desmonta y vuelve a montar. util para revertir)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [V] Volver al menu anterior" -ForegroundColor Red
        Write-Host ""
        $opcionMU = Read-Host "Selecciona una opcion"
        Write-Log -LogLevel INFO -Message "MENU_MOUNT: Usuario selecciono '$opcionMU'."
        switch ($opcionMU.ToUpper()) {
            "1" { Mount-Image }
            "2" { Unmount-Image }
            "3" { Reload-Image }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Log -LogLevel INFO -Message "MENU_SAVE: Usuario selecciono '$opcionSC'."
        switch ($opcionSC.ToUpper()) {
            "1" { Save-Changes -Mode 'Commit' }
            "2" { Save-Changes -Mode 'Append' }
            "3" { Save-Changes -Mode 'NewWim' }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Log -LogLevel INFO -Message "MENU_EDIT_INDEX: Usuario selecciono '$opcionEI'."
        switch ($opcionEI.ToUpper()) {
            "1" { Export-Index }
            "2" { Delete-Index }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Log -LogLevel INFO -Message "MENU_CONVERT: Usuario selecciono '$opcionCI'."
        switch ($opcionCI.ToUpper()) {
            "1" { Convert-ESD }
            "2" { Convert-VHD }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Log -LogLevel INFO -Message "MENU_IMG_MGMT: Usuario selecciono '$opcionIM'."
        switch ($opcionIM.ToUpper()) {
            "1" { Mount-Unmount-Menu }
            "2" { Save-Changes-Menu }
            "3" { Show-WimMetadata-GUI }
            "4" { Edit-Indexes-Menu }
            "5" { Convert-Image-Menu }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Host "RIESGOS:" -ForegroundColor Salmon
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
            "1" { if ($Script:IMAGE_MOUNTED) { Show-Drivers-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "2" { if ($Script:IMAGE_MOUNTED) { Show-Uninstall-Drivers-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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
        Write-Host "   [2] Caracteristicas de Windows (Features)" -ForegroundColor White
        Write-Host "       (Habilitar/Deshabilitar .NET, SMB, Hyper-V, WSL...)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Servicios del Sistema" -ForegroundColor White
        Write-Host "       (Optimizar el arranque deshabilitando servicios)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [4] Tweaks y Registro" -ForegroundColor White
        Write-Host "       (Ajustes de rendimiento, privacidad e importador .REG)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [5] Automatizacion OOBE (Unattend.xml)" -ForegroundColor Green
        Write-Host "       (Configurar usuario, saltar EULA y privacidad automaticamente)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host "   [V] Volver al Menu Principal" -ForegroundColor Red
        Write-Host ""

        $opcionCust = Read-Host "Selecciona una opcion"
        
        # Validacion global de montaje antes de llamar a las funciones
        if ($opcionCust.ToUpper() -ne "V" -and $Script:IMAGE_MOUNTED -eq 0) {
            Write-Warning "Debes montar una imagen antes de usar estas herramientas."
            Pause
            continue
        }

        switch ($opcionCust.ToUpper()) {
            "1" { Show-Bloatware-GUI }
            "2" { Show-Features-GUI }
            "3" { Show-Services-Offline-GUI }
            "4" { Show-Tweaks-Offline-GUI }
            "5" { Show-Unattend-GUI }
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
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

                $useSourceChoice = Read-Host "¿Deseas intentar la reparacion usando un archivo WIM como fuente? (S/N)"
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
                     Write-Host "No se encuentra la carpeta Windows en $sfcWin. ¿Esta montada correctamente?"
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

    # --- EVENTO SELECCIoN (Muestra Metadatos Extendidos) ---
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

                # --- 3. Aplicar Estilo Solo Lectura ---
                # Indices de las nuevas filas (5, 6, 7, 8)
                foreach ($rIndex in @($rowArch, $rowVer, $rowSize, $rowDate)) {
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
        
        $form.Cursor=[System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text="Guardando..."
        $form.Refresh()
        $btnSave.Enabled=$false
        $success = $false

        try {
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
            [System.Windows.Forms.MessageBox]::Show("Guardado Exitoso", "OK", 'OK', 'Information')

        } catch { 
            if (-not $success) {
                $lblStatus.Text="Error"
                [System.Windows.Forms.MessageBox]::Show("Error al guardar: $err", "Error", 'OK', 'Error')
            }
        } finally { 
            $form.Cursor=[System.Windows.Forms.Cursors]::Default; $btnSave.Enabled=$true 
            # Actualizamos la lista desplegable con el nuevo nombre
            if ($success) { $cmbIndex.Items[$idx - 1] = "[$idx] " + $d["Nombre"] }
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
            # Leemos las primeras 300 lineas
            $content = Get-Content $fileObj.FullName -TotalCount 300 -ErrorAction SilentlyContinue
            
            # --- CAMBIO IMPORTANTE: Iterar linea por linea para usar -match ---
            foreach ($line in $content) {
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
            }
        } catch {}

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
        if ($checkedItems.Count -eq 0) { return }

        if ([System.Windows.Forms.MessageBox]::Show("Inyectar $($checkedItems.Count) drivers?", "Confirmar", 'YesNo') -eq 'Yes') {
            $btnInstall.Enabled = $false
            
            $count = 0
            $errs = 0
            $total = $checkedItems.Count

            foreach ($item in $checkedItems) {
                $count++
                $lblStatus.Text = "Instalando ($count/$total): $($item.SubItems[1].Text)..."
                $form.Refresh()
                
                try {
                    # Comando de inyeccion
                    dism /Image:$Script:MOUNT_DIR /Add-Driver /Driver:"$($item.Tag)" /ForceUnsigned | Out-Null
                    
                    if ($LASTEXITCODE -eq 0) {
                        # Feedback Visual Inmediato
                        $item.BackColor = [System.Drawing.Color]::DarkGreen
                        $item.Text = "INSTALADO"
                        $item.Checked = $false
                    } else { 
                        throw "Error DISM Code: $LASTEXITCODE" 
                    }
                } catch { 
                    $errs++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    $item.Text = "ERROR"
                    Write-Log -LogLevel ERROR -Message "Fallo inyeccion driver $($item.SubItems[1].Text): $_"
                }
            }

            # --- RECARGA DE CACHÉ ---
            $lblStatus.Text = "Actualizando base de datos de drivers... Por favor espera."
            $form.Refresh()
            
            try {
                # Forzamos la relectura de lo que realmente quedo instalado en la imagen
                $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                if ($dismDrivers) { 
                    $script:cachedInstalledDrivers = $dismDrivers 
                    Write-Log -LogLevel INFO -Message "Drivers GUI: Cache actualizada tras instalacion."
                }
            } catch {
                Write-Warning "No se pudo actualizar la cache de drivers."
            }
            # ----------------------------------------

            $btnInstall.Enabled = $true
            $lblStatus.Text = "Proceso terminado. Errores: $errs"
            
            [System.Windows.Forms.MessageBox]::Show("Proceso terminado.`nErrores: $errs`n`nLa lista de drivers instalados se ha actualizado internamente.", "Info", 'OK', 'Information')
        }
    })
	
	# Cierre Seguro
    $form.Add_FormClosing({ 
        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "¿Seguro que quieres cerrar esta ventana?", 
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

        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a ELIMINAR PERMANENTEMENTE $($checkedItems.Count) drivers.`n¿Estas seguro?", "Confirmar Eliminacion", 'YesNo', 'Warning')
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
            "¿Seguro que quieres cerrar esta ventana?", 
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

    # Panel de Lista (ListView es mejor que Panel con Checkboxes para rendimiento)
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
    $lblStatus.Text = "Cargando catálogo..."
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
                if (-not $showSys) { continue } # Ocultar sistema si no está marcado
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
        if ($checked.Count -eq 0) { return }
        
        if ([System.Windows.Forms.MessageBox]::Show("¿Eliminar $($checked.Count) apps permanentemente?", "Confirmar", 'YesNo', 'Warning') -eq 'Yes') {
            $btnRemove.Enabled = $false
            $errs = 0
            foreach ($item in $checked) {
                $pkg = $item.Tag
                $lblStatus.Text = "Eliminando: $($item.Text)..."; $form.Refresh()
                try {
                    Remove-AppxProvisionedPackage -Path $Script:MOUNT_DIR -PackageName $pkg -ErrorAction Stop | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $item.Text += " (ELIMINADO)"
                    $item.Checked = $false
                } catch {
                    $errs++
                    $item.ForeColor = [System.Drawing.Color]::Red
                }
            }
            $btnRemove.Enabled = $true
            $lblStatus.Text = "Listo. Errores: $errs"
            # Actualizar caché
            $script:cachedApps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            & $PopulateList
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

        $allChecked = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($i in $lv.CheckedItems) { $allChecked.Add($i) }
        }

        if ($allChecked.Count -eq 0) { 
            [System.Windows.Forms.MessageBox]::Show("No hay servicios seleccionados.", "Aviso", 'OK', 'Warning')
            return 
        }

        $actionTxt = if ($Mode -eq 'Disable') { "DESHABILITAR" } else { "RESTAURAR" }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a $actionTxt $($allChecked.Count) servicios.`n¿Estas seguro?", "Confirmar", 'YesNo', 'Warning')
        if ($confirm -eq 'No') { return }

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

            # Desbloqueo preventivo
            Unlock-Single-Key -SubKeyPath ($regPath -replace "^Registry::HKLM\\", "")

            try {
                # Metodo PowerShell
                if (-not (Test-Path $regPath)) { throw "Clave no existe" }
                
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

            } catch {
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
                } else {
                    $errCount++
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $item.SubItems[1].Text = "ERROR ACCESO"
                }
            }
            Restore-KeyOwner -KeyPath $regPath
        }

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
            "¿Estas seguro de que deseas salir?", 
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
            # --- CORRECCION CRITICA AQUI ---
            # Si DisplayName esta vacio, usamos FeatureName como respaldo
            $displayName = $feat.DisplayName
            if ([string]::IsNullOrWhiteSpace($displayName)) {
                $displayName = $feat.FeatureName
            }
            # -------------------------------

            # Logica de Filtrado
            if (-not [string]::IsNullOrWhiteSpace($FilterText)) {
                if ($displayName -notmatch $FilterText -and $feat.FeatureName -notmatch $FilterText) {
                    continue 
                }
            }

            $item = New-Object System.Windows.Forms.ListViewItem($displayName)
            
            # Analisis de Estado
            $stateDisplay = $feat.State
            $color = [System.Drawing.Color]::White

            switch ($feat.State) {
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
            }

            $item.SubItems.Add($stateDisplay) | Out-Null
            $item.SubItems.Add($feat.FeatureName) | Out-Null
            
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
            # Carga unica a memoria
            # Quitamos el Sort-Object DisplayName para evitar ordenar vacios al inicio, ordenamos despues
            $script:cachedFeatures = Get-WindowsOptionalFeature -Path $Script:MOUNT_DIR
            
            # Llenar lista inicial
            & $PopulateList -FilterText ""
            
            $lblStatus.Text = "Total: $($script:cachedFeatures.Count). Listo para filtrar o aplicar."
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
            $btnApply.Enabled = $true
        } catch {
            $lblStatus.Text = "Error critico al leer features: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            Write-Log -LogLevel ERROR -Message "FEATURES_GUI: Error carga inicial: $_"
        } finally {
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # --- EVENTO DE BUSQUEDA ---
    $txtSearch.Add_TextChanged({
        & $PopulateList -FilterText $txtSearch.Text
    })

    # --- LOGICA DE APLICACION ---
    $btnApply.Add_Click({
        if ($txtSearch.Text.Length -gt 0) {
            $res = [System.Windows.Forms.MessageBox]::Show("Filtro activo. Solo se procesaran elementos visibles.`n¿Continuar?", "Advertencia", 'YesNo', 'Warning')
            if ($res -ne 'Yes') { return }
        }

        $changes = 0
        $errors = 0
        
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $btnApply.Enabled = $false

        foreach ($item in $lv.Items) {
            $feat = $item.Tag
            $originalState = $feat.State
            $isNowChecked = $item.Checked
            
            $shouldEnable = ($originalState -ne "Enabled" -and $isNowChecked)
            $shouldDisable = ($originalState -eq "Enabled" -and -not $isNowChecked)

            if ($shouldEnable -or $shouldDisable) {
                
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
    $form.Size = New-Object System.Drawing.Size(720, 700)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Sistema de Pestanas
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = "10, 10"
    $tabControl.Size = "685, 640"
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
    $grpUser.Text = " Usuario Admin Local "
    $grpUser.Location = "20, 20"
    $grpUser.Size = "620, 110"
    $grpUser.ForeColor = [System.Drawing.Color]::White
    $tabBasic.Controls.Add($grpUser)

    $chkInteractiveUser = New-Object System.Windows.Forms.CheckBox
    $chkInteractiveUser.Text = "Crear usuario interactivamente (Mostrar pantalla OOBE)"
    $chkInteractiveUser.Location = "20, 25"
	$chkInteractiveUser.AutoSize=$true
	$chkInteractiveUser.ForeColor=[System.Drawing.Color]::Yellow
    $grpUser.Controls.Add($chkInteractiveUser)

    $lblUser = New-Object System.Windows.Forms.Label
	$lblUser.Text = "Usuario:"
	$lblUser.Location = "20, 55"
	$lblUser.AutoSize=$true
	$grpUser.Controls.Add($lblUser)

    $txtUser = New-Object System.Windows.Forms.TextBox
	$txtUser.Location = "80, 53"
	$txtUser.Text="Admin"
	$grpUser.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label
	$lblPass.Text = "Clave:"
	$lblPass.Location = "250, 55"
	$lblPass.AutoSize=$true
	$grpUser.Controls.Add($lblPass)

    $txtPass = New-Object System.Windows.Forms.TextBox
	$txtPass.Location = "300, 53"
	$txtPass.Text="1234"
	$txtPass.PasswordChar="*"
	$grpUser.Controls.Add($txtPass)

    # Logica visual para el usuario interactivo
    $chkInteractiveUser.Add_CheckedChanged({
        if ($chkInteractiveUser.Checked) {
            $txtUser.Enabled = $false; $txtPass.Enabled = $false
        } else {
            $txtUser.Enabled = $true; $txtPass.Enabled = $true
        }
    })

    # --- GRUPO HACKS ---
    $grpHacks = New-Object System.Windows.Forms.GroupBox
    $grpHacks.Text = " Hacks y Bypass (Windows 11) "
    $grpHacks.Location = "20, 140"
    $grpHacks.Size = "620, 130"
    $grpHacks.ForeColor = [System.Drawing.Color]::Cyan
    $tabBasic.Controls.Add($grpHacks)

    $chkBypass = New-Object System.Windows.Forms.CheckBox
    $chkBypass.Text = "Bypass Requisitos (TPM 2.0, SecureBoot, RAM)"
    $chkBypass.Location = "20, 25"
	$chkBypass.AutoSize=$true
	$chkBypass.Checked=$true
    $grpHacks.Controls.Add($chkBypass)

    $chkNet = New-Object System.Windows.Forms.CheckBox
    $chkNet.Text = "Saltar Cuenta Microsoft (Forzar Local) + Saltar EULA"
    $chkNet.Location = "20, 55"
	$chkNet.AutoSize=$true
	$chkNet.Checked=$true
    $grpHacks.Controls.Add($chkNet)

    $chkNRO = New-Object System.Windows.Forms.CheckBox
    $chkNRO.Text = "Permitir instalacion sin Internet (BypassNRO)"
    $chkNRO.Location = "20, 85"
	$chkNRO.AutoSize=$true
	$chkNRO.Checked=$true
	$chkNRO.ForeColor=[System.Drawing.Color]::LightGreen
    $grpHacks.Controls.Add($chkNRO)

    # --- GRUPO TWEAKS ---
    $grpTweaks = New-Object System.Windows.Forms.GroupBox
    $grpTweaks.Text = " Optimizacion y Visual "
    $grpTweaks.Location = "20, 280"
    $grpTweaks.Size = "620, 200"
    $grpTweaks.ForeColor = [System.Drawing.Color]::Orange
    $tabBasic.Controls.Add($grpTweaks)

    $chkVisuals = New-Object System.Windows.Forms.CheckBox
    $chkVisuals.Text = "Estilo Win10: Barra Izquierda + Menu Contextual Clasico"
    $chkVisuals.Location = "20, 30"
	$chkVisuals.AutoSize=$true
	$chkVisuals.Checked=$true
    $grpTweaks.Controls.Add($chkVisuals)

    $chkExt = New-Object System.Windows.Forms.CheckBox
    $chkExt.Text = "Explorador: Mostrar Extensiones y Rutas Largas"
    $chkExt.Location = "20, 60"
	$chkExt.AutoSize=$true
	$chkExt.Checked=$true
    $grpTweaks.Controls.Add($chkExt)
    
    $chkBloat = New-Object System.Windows.Forms.CheckBox
    $chkBloat.Text = "Debloat: Desactivar Copilot, Widgets y Sugerencias"
    $chkBloat.Location = "20, 90"
	$chkBloat.AutoSize=$true
	$chkBloat.Checked=$true
    $grpTweaks.Controls.Add($chkBloat)

    $chkHidePS = New-Object System.Windows.Forms.CheckBox
    $chkHidePS.Text = "Ocultar cualquier ventana de PowerShell durante la instalacion"
    $chkHidePS.Location = "20, 120"
	$chkHidePS.AutoSize=$true
	$chkHidePS.Checked=$true
    $grpTweaks.Controls.Add($chkHidePS)

    $chkCtt = New-Object System.Windows.Forms.CheckBox
    $chkCtt.Text = "Extra: Anadir Menu Clic Derecho 'Optimizar Sistema' (ChrisTitus)"
    $chkCtt.Location = "20, 150"
	$chkCtt.AutoSize=$true
	$chkCtt.Checked=$true
    $chkCtt.ForeColor = [System.Drawing.Color]::LightGreen
    $grpTweaks.Controls.Add($chkCtt)

    $btnGen = New-Object System.Windows.Forms.Button
    $btnGen.Text = "GENERAR E INYECTAR XML"
    $btnGen.Location = "180, 500"
	$btnGen.Size = "300, 50"
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
    
    # Enlace Web (Restaurado)
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
        $pantherDir = Join-Path $Script:MOUNT_DIR "Windows\Panther"
        if (-not (Test-Path $pantherDir)) { New-Item -Path $pantherDir -ItemType Directory -Force | Out-Null }
        $destFile = Join-Path $pantherDir "unattend.xml"
        try {
            Set-Content -Path $destFile -Value $Content -Encoding UTF8 -Force
            [System.Windows.Forms.MessageBox]::Show("Exito: $Desc inyectado en:`n$destFile", "Completado", 'OK', 'Information')
            $form.Close()
        } catch { [System.Windows.Forms.MessageBox]::Show("Error: $_", "Error", 'OK', 'Error') }
    }

    $btnGen.Add_Click({
        # 1. Fase windowsPE (Bypass Requisitos)
        $wpeRunSync = New-Object System.Collections.Generic.List[string]
        $wpeOrder = 1

        if ($chkBypass.Checked) {
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
            $wpeRunSync.Add("<RunSynchronousCommand wcm:action=""add""><Order>$wpeOrder</Order><Path>reg.exe add ""HKLM\SYSTEM\Setup\LabConfig"" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path></RunSynchronousCommand>"); $wpeOrder++
        }

        # Construir bloque windowsPE
        $wpeBlock = ""
        if ($wpeRunSync.Count -gt 0) {
            $wpeBlock = @"
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="$detectedArch" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                $($wpeRunSync -join "`n                ")
            </RunSynchronous>
            <UserData>
                <ProductKey><Key>00000-00000-00000-00000-00000</Key><WillShowUI>OnError</WillShowUI></ProductKey>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
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

        # 3. Fase oobeSystem (Usuario y Tweaks)
        
        # A. Comandos de Logueo (FirstLogon)
        $cmds = New-Object System.Collections.Generic.List[string]
        $order = 1
        $psPrefix = "powershell.exe -NoProfile -Command"
        if ($chkHidePS.Checked) { $psPrefix = "powershell.exe -WindowStyle Hidden -NoProfile -Command" }

        # CTT Optimizar
        if ($chkCtt.Checked) {
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema"" /v ""MUIVerb"" /t REG_SZ /d ""Optimizar el sistema"" /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema"" /v ""icon"" /t REG_SZ /d ""powershell.exe"" /f</CommandLine></SynchronousCommand>"); $order++
            $cmds.Add("<SynchronousCommand wcm:action=""add""><Order>$order</Order><CommandLine>reg.exe add ""HKLM\SOFTWARE\Classes\DesktopBackground\Shell\OptimizarSistema\command"" /ve /t REG_SZ /d ""$psPrefix Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -Command irm christitus.com/win | iex' -Verb RunAs"" /f</CommandLine></SynchronousCommand>"); $order++
        }

        # Visuales
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
            $logonCommandsBlock = "<FirstLogonCommands>" + ($cmds -join "`n") + "</FirstLogonCommands>"
        }

        # B. Configuracion de Cuentas
        $userAccountsBlock = ""
        $hideLocal = "true"
        $hideOnline = "true"

        if ($chkInteractiveUser.Checked) {
            # Modo Interactivo: No definimos usuario, mostramos pantalla
            $hideLocal = "false"
        } else {
            # Modo Automatico: Definimos usuario Admin
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
                <HideOnlineAccountScreens>$hideOnline</HideOnlineAccountScreens>
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
            # Validacion simple
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
        [System.Windows.Forms.MessageBox]::Show("Error Critico: No se encuentran SYSTEM o SOFTWARE.`n¿La imagen esta corrupta o no es valida?", "Error Fatal", 'OK', 'Error')
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
    # Quitamos "Registry::" y convertimos abreviaturas a nombres completos para estandarizar
    $cleanPath = $OnlinePath -replace "^Registry::", "" 
    $cleanPath = $cleanPath -replace "^HKLM:", "HKEY_LOCAL_MACHINE"
    $cleanPath = $cleanPath -replace "^HKLM\\", "HKEY_LOCAL_MACHINE\"
    $cleanPath = $cleanPath -replace "^HKCU:", "HKEY_CURRENT_USER"
    $cleanPath = $cleanPath -replace "^HKCU\\", "HKEY_CURRENT_USER\"
    $cleanPath = $cleanPath -replace "^HKCR:", "HKEY_CLASSES_ROOT"
    $cleanPath = $cleanPath -replace "^HKCR\\", "HKEY_CLASSES_ROOT\"
    $cleanPath = $cleanPath.Trim()

    # --- Mapeo de Clases de Usuario (UsrClass.dat) ---
    # Debe ir ANTES de HKCU general, porque es mas especifico.
    if ($cleanPath -match "HKEY_CURRENT_USER\\Software\\Classes") {
        return $cleanPath -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM\OfflineUserClasses"
    }

    # USUARIO (HKCU Generico - NTUSER.DAT)
    if ($cleanPath -match "HKEY_CURRENT_USER") {
        return $cleanPath -replace "HKEY_CURRENT_USER", "HKLM\OfflineUser"
    }

    # SYSTEM (HKEY_LOCAL_MACHINE\SYSTEM)
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SYSTEM") {
        $newPath = $cleanPath -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKLM\OfflineSystem"
        
        # --- Reemplazo inteligente de CurrentControlSet ---
        if ($newPath -match "CurrentControlSet") {
            $dynamicSet = Get-OfflineControlSet
            return $newPath -replace "CurrentControlSet", $dynamicSet
        }
        # Fallback para ControlSet001 explicito si viniera en el .reg
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
    
    # 1. Asegurar Privilegios
    Enable-Privileges 

    # 2. Limpieza de Ruta
    $cleanPath = $KeyPath -replace "^Registry::", ""
    $subPath = $cleanPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|HKLM:|HKEY_LOCAL_MACHINE:)[:\\]+", ""
    
    # Mapeo a Hive .NET
    $hive = [Microsoft.Win32.Registry]::LocalMachine
    # Si es usuario, cambiamos logica (aunque OfflineUser se monta en HKLM usualmente en este script)
    if ($KeyPath -match "OfflineUser") { 
        # Nota: En tu script, OfflineUser ESTa en HKLM, asi que seguimos usando LocalMachine
    }

    $sidAdmin   = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $sidTrusted = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
    
    # Detectar si debemos devolverlo a Admin (Usuario) o TrustedInstaller (Sistema)
    $isUserHive = $subPath -match "OfflineUser"
    $targetOwner = if ($isUserHive) { $sidAdmin } else { $sidTrusted }

    try {
        # --- PASO 1: TOMAR POSESIoN A LA FUERZA (ADMINISTRADORES) ---
        # Abrimos la clave con derechos EXCLUSIVOS para cambiar el dueño.
        # Esto soluciona el "Acceso Denegado" porque el privilegio SeTakeOwnership permite esto aunque la ACL diga "Deny".
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
            $acl.SetOwner($sidAdmin) # Nos hacemos dueños primero para poder editar la ACL después
            $keyObj.SetAccessControl($acl)
            $keyObj.Close()
        }

        # --- PASO 2: RESTAURAR HERENCIA (RESET) ---
        # Ahora que somos dueños (Admin), podemos cambiar los permisos (ChangePermissions)
        $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::ChangePermissions)
        
        if ($keyObj) {
            $acl = $keyObj.GetAccessControl()
            # Habilitar herencia y limpiar reglas explicitas ($false, $false)
            # EXCEPCIoN: En claves de usuario a veces queremos mantener reglas, pero para limpieza general reset es mejor.
            if (-not $isUserHive) {
                $acl.SetAccessRuleProtection($false, $false)
            }
            $keyObj.SetAccessControl($acl)
            $keyObj.Close()
            Write-Log -LogLevel INFO -Message "Restaurado (Herencia): $subPath"
        }

        # --- PASO 3: DEVOLVER PROPIEDAD A TRUSTEDINSTALLER ---
        # Solo si no es hive de usuario
        if (-not $isUserHive) {
            $keyObj = $hive.OpenSubKey($subPath, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
            if ($keyObj) {
                $acl = $keyObj.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)
                $acl.SetOwner($targetOwner)
                $keyObj.SetAccessControl($acl)
                $keyObj.Close()
                # No logueamos esto para no saturar, asumimos éxito si paso el 2
            }
        }

    } catch {
        # Si falla, logueamos el error especifico de .NET
        Write-Log -LogLevel ERROR -Message "Fallo critico en Restore-KeyOwner ($subPath): $($_.Exception.Message)"
    }
}

# --- LA FUNCIoN DE DESBLOQUEO ---
function Unlock-Single-Key {
    param([string]$SubKeyPath)
    
    # Filtro de seguridad para raices
    if ($SubKeyPath -match "^(OfflineSystem|OfflineSoftware|OfflineUser|OfflineUserClasses|OfflineComponents)$") { return }
    
	Enable-Privileges
    $rootKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

    # --- VERIFICACIoN PREVIA ---
    # Antes de disparar REGINI, comprobamos si ya tenemos permiso de escritura.
    # Si podemos abrirla con 'WriteKey', no hace falta desbloquear nada.
    try {
        $testKey = $rootKey.OpenSubKey($SubKeyPath, [System.Security.AccessControl.RegistryRights]::WriteKey)
        if ($testKey) {
            $testKey.Close()
            $rootKey.Close()
            return # SALIR: Ya tenemos permisos, no tocamos nada.
        }
    } catch { 
        # Si falla el chequeo, continuamos con el desbloqueo...
    }

    # ... (Aqui sigue la logica de desbloqueo si fallo lo anterior) ...
    
    $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $success = $false

    # INTENTO 1: MÉTODO .NET (Rapido)
    try {
        $keyOwner = $rootKey.OpenSubKey($SubKeyPath, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($keyOwner) {
            $cleanAcl = New-Object System.Security.AccessControl.RegistrySecurity
            $cleanAcl.SetOwner($sidAdmin)
            $keyOwner.SetAccessControl($cleanAcl)
            $keyOwner.Close()
        }

        $keyPerms = $rootKey.OpenSubKey($SubKeyPath, [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor [System.Security.AccessControl.RegistryRights]::ReadPermissions)
        if ($keyPerms) {
            $newAcl = New-Object System.Security.AccessControl.RegistrySecurity
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule($sidAdmin, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
            $newAcl.SetOwner($sidAdmin)
            $newAcl.SetAccessRule($rule)
            $newAcl.SetAccessRuleProtection($true, $false)
            $keyPerms.SetAccessControl($newAcl)
            $keyPerms.Close()
            $success = $true
        }
    } catch {}
    
    $rootKey.Close()

    # INTENTO 2: MÉTODO REGINI.EXE (Solo si fallo .NET y no teniamos acceso previo)
    if (-not $success) {
        try {
            $kernelPath = "\Registry\Machine\$SubKeyPath"
            $reginiContent = "$kernelPath [1 17]"
            $tempFile = [System.IO.Path]::GetTempFileName()
            Set-Content -Path $tempFile -Value $reginiContent -Encoding Ascii
            $p = Start-Process regini.exe -ArgumentList $tempFile -PassThru -WindowStyle Hidden -Wait
            Remove-Item $tempFile -Force -ErrorAction SilentlyContinue
            
            # Solo logueamos si realmente tuvo que usar REGINI
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

    # --- EVENTO: IMPORTAR .REG ---
    $btnImport.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter = "Archivos de Registro (*.reg)|*.reg"
        
        if ($ofd.ShowDialog() -eq 'OK') {
            $file = $ofd.FileName
            
            # Vista previa
            $userConfirmed = Show-RegPreview-GUI -FilePath $file
            
            if ($userConfirmed) {
                # Definimos las variables fuera del try para usarlas en finally
                $tempReg = Join-Path $env:TEMP "gui_import_offline_$PID.reg"
                $keysToProcess = New-Object System.Collections.Generic.HashSet[string]
                $totalKeys = 0

                try {
                    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                    $lblStatus.Text = "Procesando archivo..."
                    $form.Refresh()

                    # 1. Lectura
                    $content = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::Default)
                    
                    # 2. Traduccion de Rutas (Regex optimizado)
                    $newContent = $content -replace "(?i)HKEY_LOCAL_MACHINE\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                                           -replace "(?i)HKLM\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware" `
                                           -replace "(?i)HKEY_LOCAL_MACHINE\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                                           -replace "(?i)HKLM\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem" `
                                           -replace "(?i)HKEY_CURRENT_USER\\Software\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses" `
                                           -replace "(?i)HKCU\\Software\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses" `
                                           -replace "(?i)HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE\OfflineUser" `
                                           -replace "(?i)HKCU", "HKEY_LOCAL_MACHINE\OfflineUser" `
                                           -replace "(?i)HKEY_CLASSES_ROOT", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes" `
                                           -replace "(?i)HKCR", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"

                    # 3. Analisis de Claves (Llenado de HashSet)
                    $lblStatus.Text = "Analizando claves..."
                    $form.Refresh()

                    # Regex robusto con comillas simples
                    $pattern = '\[-?(HKEY_LOCAL_MACHINE\\(OfflineSoftware|OfflineSystem|OfflineUser|OfflineUserClasses|OfflineComponents)[^\]]*)\]'
                    $matches = [regex]::Matches($newContent, $pattern)
                    
                    foreach ($m in $matches) {
                        # .Trim() es vital para quitar espacios fantasmas que rompen Test-Path
                        $keyPath = $m.Groups[1].Value.Trim()
                        if ($keyPath.StartsWith("-")) { $keyPath = $keyPath.Substring(1) }
                        $null = $keysToProcess.Add($keyPath)
                    }
                    $totalKeys = $keysToProcess.Count

                    # 4. Desbloqueo
                    $currentKey = 0
                    foreach ($targetKey in $keysToProcess) {
                        $currentKey++
                        if ($currentKey % 5 -eq 0) { 
                            $lblStatus.Text = "Desbloqueando ($currentKey / $totalKeys)..."
                            $form.Refresh()
                        }
                        Unlock-OfflineKey -KeyPath $targetKey
                    }

                    # 5. Importacion
                    $lblStatus.Text = "Importando al registro..."
                    $form.Refresh()
                    [System.IO.File]::WriteAllText($tempReg, $newContent, [System.Text.Encoding]::Unicode)

                    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pInfo.FileName = "reg.exe"
                    $pInfo.Arguments = "import `"$tempReg`""
                    $pInfo.UseShellExecute = $false
                    $pInfo.CreateNoWindow = $true
                    $process = [System.Diagnostics.Process]::Start($pInfo)
                    $process.WaitForExit()
                    
                    # Guardamos el resultado pero NO detenemos la restauracion si falla
                    $importExitCode = $process.ExitCode 

                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Error durante la preparacion: $_", "Error", 'OK', 'Error')
                } finally {
                    
                    # --- FASE CRiTICA: RESTAURACIoN DE PERMISOS ---
                    # Esto ahora esta en 'finally', se ejecuta SIEMPRE, incluso si la importacion falla.
                    
                    $lblStatus.Text = "Asegurando permisos (Restaurando)..."
                    $form.Refresh()
                    
                    $restoredCount = 0
                    foreach ($targetKey in $keysToProcess) {
                        # Convertimos a ruta PowerShell para validar existencia
                        # (HKEY_LOCAL_MACHINE\Offline... -> HKLM:\Offline...)
                        $psCheckPath = $targetKey -replace "^HKEY_LOCAL_MACHINE", "HKLM:"
                        
                        if (Test-Path $psCheckPath) {
                            Restore-KeyOwner -KeyPath $targetKey
                            $restoredCount++
                        } else {
                            # Logueamos si no encontramos la clave para saber por qué no se restauro
                            Write-Log -LogLevel WARN -Message "No se pudo restaurar (no existe): $targetKey"
                        }
                    }

                    $form.Cursor = [System.Windows.Forms.Cursors]::Default
                    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

                    # Informe Final
                    if ($importExitCode -eq 0) {
                        $lblStatus.Text = "Finalizado Correctamente."
                        [System.Windows.Forms.MessageBox]::Show("Importacion completada.`nClaves procesadas/restauradas: $restoredCount", "Exito", 'OK', 'Information')
                    } else {
                        $lblStatus.Text = "Finalizado con Advertencias."
                        [System.Windows.Forms.MessageBox]::Show("La importacion reporto un codigo de salida ($importExitCode), pero se intentaron restaurar los permisos.`nRevise el log si faltan datos.", "Advertencia", 'OK', 'Warning')
                    }
                }
            }
        }
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

        $allCheckedItems = New-Object System.Collections.Generic.List[System.Windows.Forms.ListViewItem]
        foreach ($lv in $globalListViews) {
            foreach ($item in $lv.CheckedItems) {
                $allCheckedItems.Add($item)
            }
        }

        if ($allCheckedItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No hay ajustes seleccionados.", "Aviso", 'OK', 'Warning')
            return
        }

        $msgTitle = if ($Mode -eq 'Apply') { "Aplicar Cambios" } else { "Restaurar Cambios" }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Se Aplicaran $($allCheckedItems.Count) ajustes en TOTAL.`n¿Deseas continuar?", $msgTitle, 'YesNo', 'Question')
        if ($confirm -eq 'No') { return }

        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = "Procesando registro... ($Mode)"
        $form.Refresh()

        $errors = 0
        $success = 0

        foreach ($it in $allCheckedItems) {
            $t = $it.Tag 
            $pathRaw = Translate-OfflinePath -OnlinePath $t.RegistryPath
            
            if ($pathRaw) {
                $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                
                $valToSet = $null
                $isDelete = $false

                if ($Mode -eq 'Apply') {
                    $valToSet = $t.EnabledValue
                } else {
                    $valToSet = $t.DefaultValue
                    if ($valToSet -eq "DeleteKey") { $isDelete = $true }
                }

                try {
                    if ($Mode -eq 'Apply' -and -not (Test-Path $psPath)) {
                        New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null
                    }

                    if (Test-Path $psPath) {
                        if ($isDelete) {
                             Remove-ItemProperty -Path $psPath -Name $t.RegistryKey -ErrorAction SilentlyContinue
                        } 
                        else {
                            $type = [Microsoft.Win32.RegistryValueKind]::DWord
                            if ($t.RegistryType -eq "String") { $type = [Microsoft.Win32.RegistryValueKind]::String }
                            Set-ItemProperty -Path $psPath -Name $t.RegistryKey -Value $valToSet -Type $type -Force -ErrorAction Stop
                        }

                        Restore-KeyOwner -KeyPath $psPath

                        if ($Mode -eq 'Apply') {
                             $it.SubItems[1].Text = "ACTIVO"
                             $it.ForeColor = [System.Drawing.Color]::Cyan
                        } else {
                             $it.SubItems[1].Text = "RESTAURADO"
                             $it.ForeColor = [System.Drawing.Color]::LightGray
                        }
                        $it.Checked = $false 
                        $success++
                    }
                } catch {
                    $errors++
                    $it.SubItems[1].Text = "ERROR"
                    $it.ForeColor = [System.Drawing.Color]::Red
                    Write-Log -LogLevel ERROR -Message "Fallo Tweak ($Mode): $($t.Name) - $_"
                }
            }
        }
        
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
            "¿Estas seguro de que deseas salir?`nSe guardaran y desmontaran los Hives del registro.", 
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

    # --- LOGICA CORE CORREGIDA ---
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
            if ([System.Windows.Forms.MessageBox]::Show("El VHD existe. Se borrara todo su contenido.`n¿Continuar?", "Confirmar", 'YesNo', 'Warning') -eq 'No') { return }
            try { Remove-Item $vhdPath -Force -ErrorAction Stop } catch { [System.Windows.Forms.MessageBox]::Show("No se pudo borrar el archivo. ¿Esta en uso?", "Error", 'OK', 'Error'); return }
        }

        $btnDeploy.Enabled = $false
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        try {
            $lblStatus.Text = "Creando VHD..."
            $form.Refresh()
            if ($isDynamic) { New-VHD -Path $vhdPath -SizeBytes $totalSize -Dynamic -ErrorAction Stop | Out-Null }
            else { New-VHD -Path $vhdPath -SizeBytes $totalSize -Fixed -ErrorAction Stop | Out-Null }

            $disk = Mount-VHD -Path $vhdPath -Passthru -ErrorAction Stop
            $diskNum = $disk.Number

            $partStyle = if ($isGPT) { "GPT" } else { "MBR" }
            Initialize-Disk -Number $diskNum -PartitionStyle $partStyle -ErrorAction Stop

            $driveLetterSystem = $null
            $driveLetterBoot = $null

            # --- PARTICIONADO ROBUSTO ---
            if ($isGPT) {
                # GPT: EFI + MSR + WINDOWS
                $lblStatus.Text = "Particionando GPT..."
                
                # 1. EFI
                $pEFI = New-Partition -DiskNumber $diskNum -Size ($sizeBootMB * 1MB) -GptType "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}" -ErrorAction Stop
                Format-Volume -Partition $pEFI -FileSystem FAT32 -NewFileSystemLabel "System" -Confirm:$false | Out-Null
                # Asignacion de Letra Segura
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
                # Asignacion de Letra Segura (CRiTICO: AQUI FALLABA ANTES)
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
                # Asignacion de Letra Segura
                if (-not $pBoot.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pBoot -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterBoot = "$($freeLet):"
                } else { $driveLetterBoot = "$($pBoot.DriveLetter):" }

                # 2. Windows
                $pWin = New-Partition -DiskNumber $diskNum -UseMaximumSize -ErrorAction Stop
                Format-Volume -Partition $pWin -FileSystem NTFS -NewFileSystemLabel "Windows" -Confirm:$false | Out-Null
                # Asignacion de Letra Segura
                if (-not $pWin.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Set-Partition -InputObject $pWin -NewDriveLetter $freeLet -ErrorAction Stop
                    $driveLetterSystem = "$($freeLet):"
                } else { $driveLetterSystem = "$($pWin.DriveLetter):" }
            }

            # 4. APLICACION IMAGEN
            $lblStatus.Text = "Desplegando imagen a $driveLetterSystem..."
            $form.Refresh()
            # Ahora driveLetterSystem esta garantizado que tiene letra
            Expand-WindowsImage -ImagePath $wimPath -Index $idx -ApplyPath $driveLetterSystem -ErrorAction Stop

            # 5. BOOT
            $lblStatus.Text = "Configurando arranque..."
            $fw = if ($isGPT) { "UEFI" } else { "BIOS" }
            $proc = Start-Process "bcdboot.exe" -ArgumentList "$driveLetterSystem\Windows /s $driveLetterBoot /f $fw" -Wait -NoNewWindow -PassThru
            if ($proc.ExitCode -ne 0) { throw "BCDBOOT fallo (Code: $($proc.ExitCode))" }

            # 6. FIN
            $lblStatus.Text = "Desmontando..."
            $form.Refresh()
            Dismount-VHD -Path $vhdPath -ErrorAction Stop
            
            $lblStatus.Text = "Listo."
            [System.Windows.Forms.MessageBox]::Show("Despliegue completado con exito.", "Exito", 'OK', 'Information')

        } catch {
            $lblStatus.Text = "Error Critico."
            Write-Warning "Fallo despliegue: $_"
            [System.Windows.Forms.MessageBox]::Show("Error Critico:`n$_", "Error", 'OK', 'Error')
            try { Dismount-VHD -Path $vhdPath -ErrorAction SilentlyContinue } catch {}
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
    # 1. Busqueda Inteligente de Dependencia (oscdimg.exe)
    $scriptPath = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    
    $possiblePaths = @(
        "$scriptPath\Tools\oscdimg.exe",
        "$scriptPath\..\Tools\oscdimg.exe",
        "$env:ProgramFiles(x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
        "C:\ADK\oscdimg.exe"
    )
    
    $adkSearch = Get-ChildItem -Path "$env:ProgramFiles(x86)\Windows Kits" -Filter "oscdimg.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    if ($adkSearch) { $possiblePaths += $adkSearch }

    $oscdimgExe = $null
    foreach ($p in $possiblePaths) { 
        if (Test-Path $p) { $oscdimgExe = $p; break } 
    }

    if (-not $oscdimgExe) {
        Add-Type -AssemblyName System.Windows.Forms
        $res = [System.Windows.Forms.MessageBox]::Show("No se encontro 'oscdimg.exe'.`n`n¿Deseas buscar el ejecutable manualmente?", "Falta Dependencia", 'YesNo', 'Warning')
        if ($res -eq 'Yes') {
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = "Oscdimg (oscdimg.exe)|oscdimg.exe"
            if ($ofd.ShowDialog() -eq 'OK') { $oscdimgExe = $ofd.FileName } else { return }
        } else { return }
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
        if ($fbd.ShowDialog() -eq 'OK') { $txtSrc.Text = $fbd.SelectedPath }
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

        if (-not $src -or -not $iso) { [System.Windows.Forms.MessageBox]::Show("Faltan rutas.", "Error", 'OK', 'Error'); return }
        
        $biosBoot = Join-Path $src "boot\etfsboot.com"
        $uefiBoot = Join-Path $src "efi\microsoft\boot\efisys.bin"

        if (-not (Test-Path $biosBoot)) { [System.Windows.Forms.MessageBox]::Show("No se encuentra boot\etfsboot.com.", "Error Estructural", 'OK', 'Error'); return }

        if (-not [string]::IsNullOrWhiteSpace($xmlPath) -and (Test-Path $xmlPath)) {
            try { Copy-Item -Path $xmlPath -Destination (Join-Path $src "autounattend.xml") -Force -ErrorAction Stop }
            catch { [System.Windows.Forms.MessageBox]::Show("Error copiando XML: $_", "Error", 'OK', 'Error'); return }
        }

        $btnMake.Enabled = $false; $grpCfg.Enabled = $false; $grpAuto.Enabled = $false
        $txtLog.Text = "--- INICIO DEL LOG ---`r`n"
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

        # Argumentos
        $bootArg = "-bootdata:2#p0,e,b`"{0}`"#pEF,e,b`"{1}`"" -f $biosBoot, $uefiBoot
        $allArgs = '-m -o -u2 -udfver102 -l"{0}" {1} "{2}" "{3}"' -f $label, $bootArg, $src, $iso

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
                # Leemos los streams directamente en el hilo principal.
                # Esto es 100% seguro contra crashes de threading.
                
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

                        # 1. Si es progreso normal, imprimir sin etiqueta
                        if ($errLine -match "% complete" -or $errLine -match "Scanning source") {
                            $txtLog.AppendText($errLine + "`r`n") 
                        } 
                        else {
                            # 2. Solo si es texto real desconocido, le ponemos [ERR]
                            $txtLog.AppendText("[ERR] " + $errLine + "`r`n")
                        }
                    }
                    # Mantiene la ventana viva
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
                    # Usamos la carpeta de Logs global del script
                    $logPath = Join-Path $script:logDir $logFileName
                    
                    # Guardar el contenido del TextBox al archivo
                    $txtLog.Text | Out-File -FilePath $logPath -Encoding utf8 -Force
                    
                    $txtLog.AppendText("`r`n[INFO] Log guardado en: $logFileName")
                    Write-Log -LogLevel INFO -Message "ISO Maker: Log guardado en $logPath"
                } catch {
                    $txtLog.AppendText("`r`n[WARN] No se pudo guardar el archivo de log.")
                }

                if ($exitCode -eq 0) {
                    $txtLog.AppendText("`r`n[EXITO] ISO Creada.")
                    [System.Windows.Forms.MessageBox]::Show("ISO creada en:`n$iso", "Exito", 'OK', 'Information')
                } else {
                    $txtLog.AppendText("`r`n[ERROR] Codigo: $exitCode")
                    [System.Windows.Forms.MessageBox]::Show("Fallo la creacion.", "Error", 'OK', 'Error')
                }
            } else { throw "No inicio oscdimg" }

        } catch {
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
            "La imagen montada en '$($Script:MOUNT_DIR)' parece estar danada (posible cierre inesperado).`n`n¿Quieres intentar RECUPERAR la sesion (Remount-Image)?`n`n[Si] = Intentar reconectar y salvar cambios.`n[No] = Eliminar punto de montaje (Cleanup-Wim).", 
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
                } catch { 
                    $cachedImageName = "Error Lectura"; $cachedImageVer = "--"; $cachedImageArch = "--" 
                }
            }
            # --- CASO 2: VHD / VHDX ---
            elseif ($Script:IMAGE_MOUNTED -eq 2) {
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
                    } catch { $cachedImageVer = "Error" }
                } else {
                    $cachedImageVer = "Sin Sistema"
                }
            }
            else {
                # Nada montado
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
        Write-Host "   6. Crear Medio de Instalacion (ISO / USB)"
        Write-Host ""

        Write-Host " [ INGENIERIA & AJUSTES ]" -ForegroundColor Yellow
        if ($Script:IMAGE_MOUNTED -gt 0) {
            Write-Host "   3. Drivers (Inyectar/Eliminar)" -ForegroundColor White
            Write-Host "   4. Personalizacion (Apps, Tweaks, Unattend.xml)" -ForegroundColor White
            Write-Host "   5. Limpieza y Reparacion (DISM/SFC)" -ForegroundColor White
            Write-Host "   8. Cambiar Edicion (Home -> Pro)" -ForegroundColor White
        } else {
            # Opciones deshabilitadas visualmente
            Write-Host "   3. Drivers (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   4. Personalizacion (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   5. Limpieza y Reparacion (Requiere Montaje)" -ForegroundColor DarkGray
            Write-Host "   8. Cambiar Edicion (Requiere Montaje)" -ForegroundColor DarkGray
        }
        Write-Host ""
        
        Write-Host " [ SISTEMA ]" -ForegroundColor Yellow
        Write-Host "   7. Configuracion (Rutas)"
        Write-Host "   S. Salir" -ForegroundColor Red
        Write-Host ""
        Write-Host "--------------------------------------------------------------------------------"
        
        $prompt = "Seleccione una opcion"
        if ($Script:IMAGE_MOUNTED -gt 0) { $prompt = "Comando (Imagen Lista)" }
        
        $opcionM = Read-Host " $prompt"
        
        # Manejo de Errores y Navegación
        switch ($opcionM.ToUpper()) {
            "1" { Image-Management-Menu }
            "2" { Convert-Image-Menu }
            "3" { if ($Script:IMAGE_MOUNTED) { Drivers-Menu } else { Show-Mount-Warning } }
            "4" { if ($Script:IMAGE_MOUNTED) { Customization-Menu } else { Show-Mount-Warning } }
            "5" { if ($Script:IMAGE_MOUNTED) { Limpieza-Menu } else { Show-Mount-Warning } }
            "6" { 
                Clear-Host; Write-Host "--- DESPLIEGUE ---" -ForegroundColor Cyan
                Write-Host "1. Despliegue a VHD (Instalacion Nativa Virtual)"
                Write-Host "2. Crear ISO Booteable (Instalador Clasico)"
                Write-Host "V. Volver"
                $d = Read-Host "Elige"; 
                if($d -eq 1){Show-Deploy-To-VHD-GUI} elseif($d -eq 2){Show-IsoMaker-GUI}
            } 
            "7" { Show-ConfigMenu }
            "8" { if ($Script:IMAGE_MOUNTED) { Cambio-Edicion-Menu } else { Show-Mount-Warning } }
            "S" { 
                if ($Script:IMAGE_MOUNTED -gt 0) {
                    [System.Console]::Beep(500, 300)
                    $confirmExit = Read-Host "¿Hay una imagen montada! Si sales ahora, quedara montada.`n¿Deseas desmontarla antes de salir? (S/N/Cancelar)"
                    if ($confirmExit -eq 'S') { Unmount-Image; exit }
                    elseif ($confirmExit -eq 'N') { Write-Warning "Saliendo... Recuerda ejecutar 'Limpieza' al volver."; exit }
                } else {
                    Write-Host "Hasta luego." -ForegroundColor Green
                    Start-Sleep -Seconds 1
                    exit 
                }
            }
            default { 
                # Feedback visual sutil en lugar de un Write-Warning que pausa todo
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

                # 3. HEURISTICA: ¿Es esta partición específica una instalación de Windows?
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
