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
    1.4.0
#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.4.0"

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
    
    # GitHub extrae en una subcarpeta (ej: Aegis-Phoenix-Suite-main)
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
    `$itemsToRemove = Get-ChildItem -Path "$installPath" -Exclude "Logs"
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

# --- NUEVO: Guarda la configuracion actual en el archivo JSON ---
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
        Write-Error "[ERROR] No se pudo guardar el archivo de configuracion en '$($script:configFile)'."
        Write-Log -LogLevel ERROR -Message "Fallo al guardar config.json. Error: $($_.Exception.Message)"
        Pause
    }
}

# --- NUEVO: Verifica que los directorios de trabajo existan antes de iniciar ---
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
                    Write-Error "[ERROR] No se pudo crear el directorio. Error: $($_.Exception.Message)"
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
                    Write-Error "[ERROR] No se pudo crear el directorio. Error: $($_.Exception.Message)"
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
$script:configFile = Join-Path $scriptRoot "config.json"

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
        Write-Error "No se pudo mostrar el dialogo de seleccion. Error: $($_.Exception.Message)"
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
        Write-Error "No se pudo mostrar el dialogo de guardado. Error: $($_.Exception.Message)"
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
        Pause
        return
    }

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM a montar" -Filter "Archivos WIM (*.wim)|*.wim|Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if ([string]::IsNullOrEmpty($path)) {
        Write-Warning "Operacion cancelada."
        Pause
        return
    }
    $Script:WIM_FILE_PATH = $path

    Write-Host "[+] Obteniendo informacion del WIM..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"

    $INDEX = Read-Host "`nIngrese el numero de indice a montar"
    # Validar que INDEX sea un numero podria añadirse aqui
    Write-Host "[+] Montando imagen (Indice: $INDEX)... Esto puede tardar." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Montando imagen: '$Script:WIM_FILE_PATH' (Indice: $INDEX) en '$Script:MOUNT_DIR'"
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        Write-Host "[OK] Imagen montada exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Montaje completado con exito."
    } else {
        Write-Error "[ERROR] Fallo al montar la imagen."
        Write-Log -LogLevel ERROR -Message "Fallo al montar la imagen. Codigo de salida: $LASTEXITCODE"
    }
    Pause
}

function Unmount-Image {
    Clear-Host
    if ($Script:IMAGE_MOUNTED -eq 0) {
        Write-Warning "No hay ninguna imagen montada."
        Pause
        return
    }
    Write-Host "[+] Desmontando imagen (descartando cambios)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Desmontando imagen (descartando cambios) desde '$Script:MOUNT_DIR'."
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard

    # Siempre resetear el estado, incluso si DISM falla (puede quedar corrupto)
    $Script:IMAGE_MOUNTED = 0
    $Script:WIM_FILE_PATH = $null
    $Script:MOUNTED_INDEX = $null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen desmontada." -ForegroundColor Green
    } else {
        Write-Error "[ERROR] Fallo el desmontaje (Codigo: $LASTEXITCODE). El estado de montaje puede ser inconsistente."
        Write-Log -LogLevel ERROR -Message "Fallo el desmontaje. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Reload-Image {
    param([int]$RetryCount = 0)

    Clear-Host
    if ($Script:IMAGE_MOUNTED -eq 0)
	{
		Write-Warning "No hay imagen montada para recargar."
		Pause
		return
	}
    if (-not $Script:WIM_FILE_PATH)
	{
		Write-Warning "ERROR: No se encuentra ruta WIM original."
		Pause
		return
	}
    if (-not $Script:MOUNTED_INDEX)
	{
		Write-Warning "ERROR: No se pudo determinar el Indice montado."
		Pause
		return
	}

    Write-Host "`nRuta del WIM: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Host "Indice Montado: $Script:MOUNTED_INDEX" -ForegroundColor Gray
    
	if ($RetryCount -eq 0) {
        $CONFIRM = Read-Host "`nVa a recargar la imagen descartando todos los cambios no guardados. ¿Desea continuar? (S/N)"
        if ($CONFIRM -notmatch '^(s|S)$') { Write-Warning "Operacion cancelada."; Pause; return }
    }

    Write-Host "[+] Desmontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Recargando imagen: Desmontando '$Script:WIM_FILE_PATH' (Indice: $Script:MOUNTED_INDEX)..."
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard

    if ($LASTEXITCODE -ne 0) {
        Write-Error "[ERROR] Error al intentar desmontar. Ejecutando 'dism /cleanup-wim'..."
        Write-Log -LogLevel ERROR -Message "Fallo el desmontaje en recarga. Ejecutando cleanup-wim."
        dism /cleanup-wim
        Write-Host "Limpieza completada. Reintentando en 5 segundos..."
        Start-Sleep -Seconds 5
        Reload-Image # Recursion para reintentar
        return
    }

    Write-Host "[+] Remontando imagen (Indice: $Script:MOUNTED_INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Recargando imagen: Remontando..."
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen recargada exitosamente." -ForegroundColor Green
        $Script:IMAGE_MOUNTED = 1
    } else {
        Write-Error "[ERROR] Error al remontar la imagen."
        Write-Log -LogLevel ERROR -Message "Fallo el remontaje en recarga."
        # Resetear estado si falla el remontaje
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Guardar Cambios)
# =============================================

function Save-Changes {
    param ([string]$Mode) # 'Commit' o 'Append'

    if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "No hay imagen montada para guardar."; Pause; return }

    if ($Mode -eq 'Commit') {
        Write-Host "[+] Guardando cambios en el indice $Script:MOUNTED_INDEX..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Guardando cambios (Commit) en indice $Script:MOUNTED_INDEX."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR"
    } elseif ($Mode -eq 'Append') {
        Write-Host "[+] Guardando cambios en un nuevo indice (Append)..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Guardando cambios (Append) en nuevo indice."
        dism /commit-image /mountdir:"$Script:MOUNT_DIR" /append
    } else {
        Write-Error "Modo de guardado '$Mode' no valido."
        return
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Cambios guardados." -ForegroundColor Green
    } else {
        Write-Error "[ERROR] Fallo al guardar cambios (Codigo: $LASTEXITCODE)."
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
        Write-Error "[ERROR] Fallo al exportar el Indice (Codigo: $LASTEXITCODE)."
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
            Write-Error "[ERROR] Error al eliminar el Indice (Codigo: $LASTEXITCODE). Puede que este montado o en uso."
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
        Write-Error "[ERROR] Error durante la conversion (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo la conversion de ESD. Codigo: $LASTEXITCODE"
    }
    Pause
}

function Convert-VHD {
    Clear-Host; Write-Host "--- Convertir VHD/VHDX a WIM ---" -ForegroundColor Yellow

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo VHD o VHDX a convertir" -Filter "Archivos VHD (*.vhd, *.vhdx)|*.vhd;*.vhdx|Todos (*.*)|*.*"
    if (-not $path) { Write-Warning "Operacion cancelada."; Pause; return }
    $VHD_FILE_PATH = $path

    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; Pause; return }

    Write-Host "`n--- Ingrese los metadatos para la nueva imagen WIM ---" -ForegroundColor Yellow
    $IMAGE_NAME = Read-Host "Ingrese el NOMBRE de la imagen (ej: Captured VHD)"
    $IMAGE_DESC = Read-Host "Ingrese la DESCRIPCION de la imagen"
    if ([string]::IsNullOrEmpty($IMAGE_NAME)) { $IMAGE_NAME = "Captured VHD" }

    Write-Host "`n[+] Montando el VHD..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Montando VHD '$VHD_FILE_PATH' para captura."
    $DRIVE_LETTER = $null
    try {
        $vhdObject = Mount-Vhd -Path $VHD_FILE_PATH -PassThru -ErrorAction Stop
        $DRIVE_LETTER = ($vhdObject | Get-Disk | Get-Partition | Get-Volume).DriveLetter | Select-Object -First 1
    } catch {
        Write-Error "Error al montar VHD: $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "Fallo el montaje del VHD: $($_.Exception.Message)"
    }

    if (-not $DRIVE_LETTER) {
        Write-Error "[ERROR] No se pudo montar el VHD o no se encontro una letra de unidad."
        Pause; return
    }

    Write-Host "VHD montado en la unidad: $DRIVE_LETTER`:" -ForegroundColor Gray
    Write-Host "[+] Capturando la imagen a WIM... Esto puede tardar mucho tiempo." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Capturando VHD desde unidad $DRIVE_LETTER`: a '$DEST_WIM_PATH'."

    dism /capture-image /imagefile:"$DEST_WIM_PATH" /capturedir:"$DRIVE_LETTER`:" /name:"$IMAGE_NAME" /description:"$IMAGE_DESC" /compress:max /checkintegrity

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Captura completada exitosamente." -ForegroundColor Green
        Write-Host "Nuevo archivo WIM creado en: `"$DEST_WIM_PATH`"" -ForegroundColor Gray
        $Script:WIM_FILE_PATH = $DEST_WIM_PATH
        Write-Host "La ruta del nuevo WIM ha sido cargada en el script." -ForegroundColor Cyan
        Write-Log -LogLevel INFO -Message "Captura de VHD completada."
    } else {
        Write-Error "[ERROR] Error durante la captura de la imagen (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo la captura del VHD. Codigo: $LASTEXITCODE"
    }

    Write-Host "`n[+] Desmontando el VHD..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Desmontando VHD '$VHD_FILE_PATH'."
    Dismount-Vhd -Path $VHD_FILE_PATH 2>$null
    Write-Host "VHD desmontado." -ForegroundColor Gray; Pause
}

# =============================================
#  FUNCIONES DE MENU (Interfaz de Usuario)
# =============================================

# --- NUEVO: Menu de Configuracion de Rutas ---
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
        Write-Host "                 Guardar Cambios (Commit)              " -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Guardar cambios en el Indice actual ($($Script:MOUNTED_INDEX))"
        Write-Host "       (Sobrescribe el indice actual con los cambios)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Guardar cambios en un nuevo Indice (Append)"
        Write-Host "       (Agrega un nuevo indice al WIM con los cambios)" -ForegroundColor Gray
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
        Write-Host "   [3] Editar Indices (Exportar/Eliminar)" -ForegroundColor White
        Write-Host "       (Gestiona los indices dentro de un .wim)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [4] Convertir Imagen a WIM" -ForegroundColor White
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
            "3" { Edit-Indexes-Menu }
            "4" { Convert-Image-Menu }
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
    Write-Host "[+] Obteniendo info de version/edicion..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "CAMBIO_EDICION: Obteniendo info..."

    $WIN_PRODUCT_NAME = $null; $WIN_CURRENT_BUILD = $null; $WIN_VERSION_FRIENDLY = "Desconocida"; $CURRENT_EDITION_DETECTED = "Desconocida"
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

    if ($targetEditions.Count -lt 1)
	{
		Write-Host ""
		Write-Warning "No se encontraron ediciones de destino validas."
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
        Write-Error "[ERROR] Fallo el cambio de edicion (Codigo: $LASTEXITCODE)."
        Write-Log -LogLevel ERROR -Message "Fallo cambio edicion. Codigo: $LASTEXITCODE"
    }
    Pause
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

                # Ejecucion corregida
                SFC /scannow /offbootdir="$sfcBoot" /offwindir="$sfcWin"

                if ($LASTEXITCODE -ne 0) { Write-Warning "SFC encontro errores o no pudo completar."}
                Pause
            }
            "5" {
				Write-Host "`n[+] Analizando componentes..." -ForegroundColor Yellow; Write-Log -LogLevel ACTION -Message "LIMPIEZA: DISM /AnalyzeComponentStore..."
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
                Write-Host "`n[1/5] Verificando salud..." -FG Yellow; Write-Log -LogLevel ACTION -Message "LIMPIEZA: (1/5) CheckHealth..."
				DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /CheckHealth;
                Write-Host "`n[2/5] Escaneando..." -FG Yellow; Write-Log -LogLevel ACTION -Message "LIMPIEZA: (2/5) ScanHealth..."
				DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /ScanHealth;

                Write-Host "`n[3/5] Reparando imagen..." -ForegroundColor Yellow
                Invoke-RestoreHealthWithFallback -MountDir $Script:MOUNT_DIR -IsSequence

                Write-Host "`n[4/5] Verificando archivos (SFC)..." -FG Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: (4/5) SFC Offline..."

                # Logica dinamica corregida para la secuencia completa
                $sfcBoot = $Script:MOUNT_DIR
                if (-not $sfcBoot.EndsWith("\")) { $sfcBoot += "\" }
                $sfcWin = Join-Path -Path $Script:MOUNT_DIR -ChildPath "Windows"

                SFC /scannow /offbootdir="$sfcBoot" /offwindir="$sfcWin"
                if ($LASTEXITCODE -ne 0) { Write-Warning "SFC encontro errores o no pudo completar."}

                Write-Host "`n[5/5] Analizando/Limpiando componentes..." -FG Yellow; Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Analyze/Cleanup..."
                $cleanupRecommended = "No"
                try {
                    $analysis = DISM /Image:$Script:MOUNT_DIR /Cleanup-Image /AnalyzeComponentStore
                    $recommendLine = $analysis | Select-String "Component Store Cleanup Recommended"
                    if ($recommendLine -and ($recommendLine.Line -split ':', 2)[1].Trim() -eq "Yes") { $cleanupRecommended = "Yes" }
                } catch { Write-Warning "No se pudo analizar el almacen de componentes." }

                if ($cleanupRecommended -eq "Yes") {
                    Write-Host "Limpieza recomendada. Procediendo..." -FG Cyan;
                    Write-Log -LogLevel ACTION -Message "LIMPIEZA: (5/5) Limpieza recomendada. Ejecutando..."
                    DISM /Cleanup-Image /Image:$Script:MOUNT_DIR /StartComponentCleanup /ResetBase /ScratchDir:$Script:Scratch_DIR
                } else {
                    Write-Host "La limpieza del almacen de componentes no es necesaria." -FG Green;
                }
                Write-Host "[OK] Secuencia completada." -FG Green
				Pause
            }
            "V" { return }
            default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

# =================================================================
#  Modulo GUI de Drivers (Con Deteccion de Duplicados)
# =================================================================
function Show-Drivers-GUI {
    param()
    
    # 1. Validaciones
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    # 2. Seleccionar Carpeta Fuente
    $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderDialog.Description = "Selecciona la carpeta raiz donde tienes tus Drivers (.inf)"
    
    if ($folderDialog.ShowDialog() -ne 'OK') { return }
    $sourceDir = $folderDialog.SelectedPath

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 3. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Inyector de Drivers Inteligente - $sourceDir"
    $form.Size = New-Object System.Drawing.Size(800, 600) # Un poco mas ancho
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Comparando Drivers Locales vs Imagen..."
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Leyenda de Colores
    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Text = "Amarillo = Ya instalado en la imagen | Blanco = Nuevo"
    $lblLegend.Location = New-Object System.Drawing.Point(450, 20)
    $lblLegend.AutoSize = $true
    $lblLegend.ForeColor = [System.Drawing.Color]::Gold
    $form.Controls.Add($lblLegend)

    # ListView
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Location = New-Object System.Drawing.Point(20, 50)
    $listView.Size = New-Object System.Drawing.Size(740, 450)
    $listView.View = [System.Windows.Forms.View]::Details
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.GridLines = $true
    $listView.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $listView.ForeColor = [System.Drawing.Color]::White
    
    # Columnas
    $listView.Columns.Add("Estado", 100) | Out-Null
    $listView.Columns.Add("Archivo INF", 180) | Out-Null
    $listView.Columns.Add("Clase (Tipo)", 120) | Out-Null
    $listView.Columns.Add("Ruta Completa", 300) | Out-Null

    $form.Controls.Add($listView)

    # Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Iniciando analisis..."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 510)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
    $form.Controls.Add($lblStatus)

    # Botones
    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = "INYECTAR SELECCIONADOS"
    $btnInstall.Location = New-Object System.Drawing.Point(560, 520)
    $btnInstall.Size = New-Object System.Drawing.Size(200, 35)
    $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
    $btnInstall.ForeColor = [System.Drawing.Color]::White
    $btnInstall.FlatStyle = "Flat"
    $form.Controls.Add($btnInstall)

    $btnSelectNew = New-Object System.Windows.Forms.Button
    $btnSelectNew.Text = "Seleccionar Solo Nuevos"
    $btnSelectNew.Location = New-Object System.Drawing.Point(20, 530)
    $btnSelectNew.Size = New-Object System.Drawing.Size(150, 25)
    $btnSelectNew.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectNew.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectNew)

    # 4. Logica de Escaneo Inteligente
    $form.Add_Shown({
        $form.Refresh()
        $listView.BeginUpdate()
        
        # A) Obtener lista de drivers YA instalados en la imagen (Offline)
        $lblStatus.Text = "Leyendo drivers de la imagen montada (esto tarda un poco)..."
        $form.Refresh()
        
        $installedInfNames = @()
        try {
            # Usamos Get-WindowsDriver que es nativo y devuelve objetos limpios
            $driversInImage = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
            if ($driversInImage) {
                # Guardamos solo el nombre del archivo original (ej: nvlddmkm.inf)
                $installedInfNames = $driversInImage | ForEach-Object { 
                    [System.IO.Path]::GetFileName($_.OriginalFileName) 
                }
            }
        } catch {
            Write-Warning "No se pudo leer drivers instalados: $_"
        }

        # B) Escanear carpeta local
        $lblStatus.Text = "Comparando con carpeta local..."
        $form.Refresh()
        
        $infFiles = Get-ChildItem -Path $sourceDir -Filter "*.inf" -Recurse
        
        foreach ($file in $infFiles) {
            # 1. Leer Clase
            $classType = "Desconocido"
            try {
                $content = Get-Content $file.FullName -TotalCount 50 -ErrorAction SilentlyContinue
                $match = $content | Select-String -Pattern "^Class\s*=\s*(.*)"
                if ($match) { $classType = ($match.Line -split '=')[1].Trim() }
            } catch {}

            # 2. Verificar si existe en la lista instalada
            $isInstalled = $installedInfNames -contains $file.Name
            
            # 3. Crear Item visual
            $statusText = if ($isInstalled) { "INSTALADO" } else { "Nuevo" }
            $item = New-Object System.Windows.Forms.ListViewItem($statusText)
            $item.SubItems.Add($file.Name) | Out-Null
            $item.SubItems.Add($classType) | Out-Null
            $item.SubItems.Add($file.FullName) | Out-Null
            $item.Tag = $file.FullName
            
            if ($isInstalled) {
                # Si ya esta instalado: Color Amarillo, Desmarcado
                $item.BackColor = [System.Drawing.Color]::FromArgb(60, 50, 0) # Fondo mostaza oscuro
                $item.ForeColor = [System.Drawing.Color]::Gold
                $item.Checked = $false
            } else {
                # Si es nuevo: Marcado por defecto
                $item.Checked = $true
            }

            $listView.Items.Add($item) | Out-Null
        }
        
        $listView.EndUpdate()
        $lblTitle.Text = "Drivers encontrados (.inf)"
        $lblStatus.Text = "Analisis completado. Total: $($listView.Items.Count)"
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    # 5. Botones
    $btnSelectNew.Add_Click({
        foreach ($item in $listView.Items) {
            # Solo marca si dice "Nuevo" en la primera columna
            if ($item.Text -eq "Nuevo") { $item.Checked = $true } else { $item.Checked = $false }
        }
    })

    $btnInstall.Add_Click({
        $checkedItems = $listView.CheckedItems
        if ($checkedItems.Count -eq 0) { return }

        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a inyectar $($checkedItems.Count) drivers.`n¿Continuar?", "Confirmar", 'YesNo', 'Question')
        if ($confirm -eq 'Yes') {
            $btnInstall.Enabled = $false
            $listView.Enabled = $false
            
            $count = 0
            $total = $checkedItems.Count
            $errors = 0

            foreach ($item in $checkedItems) {
                $count++
                $infPath = $item.Tag
                $lblStatus.Text = "Inyectando ($count/$total): $($item.SubItems[1].Text)..."
                $form.Refresh()

                try {
                    dism /Image:$Script:MOUNT_DIR /Add-Driver /Driver:"$infPath" /ForceUnsigned | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Error DISM" }
                    
                    $item.BackColor = [System.Drawing.Color]::DarkGreen
                    $item.ForeColor = [System.Drawing.Color]::White
                    $item.Text = "INSTALADO" # Actualizar estado visualmente
                    $item.Checked = $false
                } catch {
                    $errors++
                    $item.BackColor = [System.Drawing.Color]::DarkRed
                    Write-Log -LogLevel ERROR -Message "Fallo driver $infPath"
                }
            }

            $btnInstall.Enabled = $true
            $listView.Enabled = $true
            $lblStatus.Text = "Proceso finalizado. Errores: $errors"
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nExitosos: $($total - $errors)`nFallidos: $errors", "Resultado", 'OK', 'Information')
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
            $listView.Enabled = $false
            
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
            $listView.Enabled = $true
            $lblStatus.Text = "Proceso finalizado. Errores: $errors"
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nEliminados: $($total - $errors)`nErrores: $errors", "Resultado", 'OK', 'Information')
        }
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
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
            "1" { Show-Drivers-GUI }           # Tu funcion de instalacion (v2.0)
            "2" { Show-Uninstall-Drivers-GUI } # La nueva funcion de desinstalacion
            "V" { return }
            default { Write-Warning "Opcion no valida."; Start-Sleep 1 }
        }
    }
}

# =================================================================
#  Modulo GUI de Bloatware (Estilo Aegis Phoenix) - FINAL
# =================================================================
function Show-Bloatware-GUI {
    param()
    
    # 1. Validaciones Previas
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 2. Configuracion de la Ventana (Form)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Gestor de Bloatware Offline - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(600, 750)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30) # Tema Oscuro
    $form.ForeColor = [System.Drawing.Color]::White

    # 3. Componentes de UI
    
    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Selecciona las aplicaciones a eliminar:"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 15)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Leyenda de Colores
    $lblLegend = New-Object System.Windows.Forms.Label
    $lblLegend.Text = "Verde: Sistema (Seguro) | Naranja: Recomendado Borrar | Blanco: Otros"
    $lblLegend.Location = New-Object System.Drawing.Point(20, 40)
    $lblLegend.AutoSize = $true
    $lblLegend.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblLegend.ForeColor = [System.Drawing.Color]::Gray
    $form.Controls.Add($lblLegend)

    # Panel con Scroll para los Checkboxes
    $panelApps = New-Object System.Windows.Forms.Panel
    $panelApps.Location = New-Object System.Drawing.Point(20, 65)
    $panelApps.Size = New-Object System.Drawing.Size(540, 535)
    $panelApps.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $panelApps.AutoScroll = $true
    $panelApps.BorderStyle = "FixedSingle"
    $form.Controls.Add($panelApps)

    # Barra de Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Escaneando imagen... por favor espera."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 615)
    $lblStatus.Size = New-Object System.Drawing.Size(400, 20)
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Botones de Accion
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Marcar Todo"
    $btnSelectAll.Location = New-Object System.Drawing.Point(20, 650)
    $btnSelectAll.Size = New-Object System.Drawing.Size(90, 30)
    $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectAll.FlatStyle = "Flat"
    
    $btnSelectNone = New-Object System.Windows.Forms.Button
    $btnSelectNone.Text = "Desmarcar"
    $btnSelectNone.Location = New-Object System.Drawing.Point(115, 650)
    $btnSelectNone.Size = New-Object System.Drawing.Size(90, 30)
    $btnSelectNone.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectNone.FlatStyle = "Flat"

    $btnSelectRec = New-Object System.Windows.Forms.Button
    $btnSelectRec.Text = "Marcar Recomendados"
    $btnSelectRec.Location = New-Object System.Drawing.Point(210, 650)
    $btnSelectRec.Size = New-Object System.Drawing.Size(140, 30)
    $btnSelectRec.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectRec.ForeColor = [System.Drawing.Color]::Orange
    $btnSelectRec.FlatStyle = "Flat"

    $btnRemove = New-Object System.Windows.Forms.Button
    $btnRemove.Text = "ELIMINAR SELECCIONADOS"
    $btnRemove.Location = New-Object System.Drawing.Point(360, 650)
    $btnRemove.Size = New-Object System.Drawing.Size(200, 30)
    $btnRemove.BackColor = [System.Drawing.Color]::Crimson
    $btnRemove.ForeColor = [System.Drawing.Color]::White
    $btnRemove.FlatStyle = "Flat"
    $btnRemove.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $form.Controls.Add($btnSelectAll)
    $form.Controls.Add($btnSelectNone)
    $form.Controls.Add($btnSelectRec)
    $form.Controls.Add($btnRemove)

    # Lista para guardar referencias a los checkboxes
    $checkBoxList = New-Object System.Collections.Generic.List[System.Windows.Forms.CheckBox]

    # 4. Evento Load (Cargar Apps y aplicar Colores)
    $form.Add_Shown({
        $form.Refresh()
        try {
            $apps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            
            # --- LISTA 1: CRiTICAS (VERDE) - NO BORRAR ---
            $safePatternRaw = "Microsoft.WindowsStore|Microsoft.WindowsCalculator|Microsoft.Windows.Photos|" +
                           "Microsoft.Windows.Camera|Microsoft.SecHealthUI|Microsoft.UI.Xaml|" +
                           "Microsoft.VCLibs|Microsoft.NET.Native|Microsoft.WebpImageExtension|" +
                           "Microsoft.HEIFImageExtension|Microsoft.VP9VideoExtensions|" +
                           "Microsoft.ScreenSketch|Microsoft.WindowsTerminal|Microsoft.Paint|" +
                           "Microsoft.WindowsNotepad"
            # Escapar puntos para Regex
            $safePattern = $safePatternRaw.Replace(".", "\.")

            # --- LISTA 2: RECOMENDADAS (NARANJA) - BLOATWARE COMuN ---
            $bloatPatternRaw = "Microsoft.Microsoft3DViewer|Microsoft.BingSearch|Microsoft.WindowsAlarms|" +
                            "Microsoft.549981C3F5F10|Microsoft.Windows.DevHome|MicrosoftCorporationII.MicrosoftFamily|" +
                            "Microsoft.WindowsFeedbackHub|Microsoft.Edge.GameAssist|Microsoft.GetHelp|" +
                            "Microsoft.Getstarted|microsoft.windowscommunicationsapps|Microsoft.WindowsMaps|" +
                            "Microsoft.MixedReality.Portal|Microsoft.BingNews|Microsoft.MicrosoftOfficeHub|" +
                            "Microsoft.Office.OneNote|Microsoft.MSPaint|Microsoft.People|" +
                            "Microsoft.PowerAutomateDesktop|Microsoft.SkypeApp|Microsoft.MicrosoftSolitaireCollection|" +
                            "Microsoft.MicrosoftStickyNotes|MicrosoftTeams|MSTeams|Microsoft.Todos|" +
                            "Microsoft.Wallet|Microsoft.BingWeather|Microsoft.Xbox.TCUI|Microsoft.XboxApp|" +
                            "Microsoft.XboxGameOverlay|Microsoft.XboxGamingOverlay|Microsoft.XboxIdentityProvider|" +
                            "Microsoft.XboxSpeechToTextOverlay|Microsoft.GamingApp|Microsoft.ZuneMusic|Microsoft.ZuneVideo"
            # Escapar puntos para Regex
            $bloatPattern = $bloatPatternRaw.Replace(".", "\.")

            $yPos = 10
            foreach ($app in $apps) {
                $chk = New-Object System.Windows.Forms.CheckBox
                $chk.Text = $app.DisplayName
                $chk.Tag = $app.PackageName 
                $chk.Location = New-Object System.Drawing.Point(10, $yPos)
                $chk.Size = New-Object System.Drawing.Size(500, 20)
                $chk.Font = New-Object System.Drawing.Font("Consolas", 10)
                
                # LoGICA DE COLORES
                if ($app.PackageName -match $safePattern -or $app.DisplayName -match $safePattern) {
                    # Caso 1: Seguras
                    $chk.ForeColor = [System.Drawing.Color]::LightGreen 
                    $chk.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
                }
                elseif ($app.PackageName -match $bloatPattern -or $app.DisplayName -match $bloatPattern) {
                    # Caso 2: Recomendadas (Bloatware)
                    $chk.ForeColor = [System.Drawing.Color]::Orange
                }
                else {
                    # Caso 3: Neutral (Blanco)
                    $chk.ForeColor = [System.Drawing.Color]::White
                }

                $panelApps.Controls.Add($chk)
                $checkBoxList.Add($chk)
                $yPos += 25
            }
            $lblStatus.Text = "Total aplicaciones encontradas: $($apps.Count)"
            $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
        }
        catch {
            $lblStatus.Text = "Error al leer apps: $_"
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
        }
    })

    # 5. Logica de Botones
    
    # Marcar TODO (Excepto las Verdes/Seguras para proteger al usuario)
    $btnSelectAll.Add_Click({
        foreach ($chk in $checkBoxList) { 
            if ($chk.ForeColor -ne [System.Drawing.Color]::LightGreen) {
                $chk.Checked = $true 
            }
        }
    })

    # Desmarcar TODO
    $btnSelectNone.Add_Click({
        foreach ($chk in $checkBoxList) { $chk.Checked = $false }
    })

    # Marcar RECOMENDADOS (Solo Naranjas)
    $btnSelectRec.Add_Click({
        foreach ($chk in $checkBoxList) {
            if ($chk.ForeColor -eq [System.Drawing.Color]::Orange) {
                $chk.Checked = $true
            }
        }
    })

    # ELIMINAR
    $btnRemove.Add_Click({
        $selectedCount = ($checkBoxList | Where-Object { $_.Checked }).Count
        if ($selectedCount -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No has seleccionado ninguna aplicacion.", "Aviso", 'OK', 'Warning')
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show("¿Estas seguro de eliminar $selectedCount aplicaciones de la imagen offline?`nEsta accion no se puede deshacer.", "Confirmar Eliminacion", 'YesNo', 'Warning')
        
        if ($confirm -eq 'Yes') {
            $btnRemove.Enabled = $false
            $btnSelectAll.Enabled = $false
            $btnSelectRec.Enabled = $false
            $panelApps.Enabled = $false
            
            $errors = 0
            $processed = 0

            foreach ($chk in $checkBoxList) {
                if ($chk.Checked) {
                    $packageName = $chk.Tag
                    $appName = $chk.Text
                    
                    $processed++
                    $lblStatus.Text = "Eliminando ($processed/$selectedCount): $appName..."
                    $form.Refresh() # Forzar repintado de UI
                    
                    try {
                        Write-Log -LogLevel ACTION -Message "BLOATWARE_GUI: Eliminando $appName"
                        Remove-AppxProvisionedPackage -Path $Script:MOUNT_DIR -PackageName $packageName -ErrorAction Stop | Out-Null
                        $chk.ForeColor = [System.Drawing.Color]::Gray
                        $chk.Checked = $false
                        $chk.Enabled = $false
                        $chk.Text += " [ELIMINADO]"
                    }
                    catch {
                        $errors++
                        Write-Log -LogLevel ERROR -Message "Fallo al eliminar $appName : $_"
                        $chk.ForeColor = [System.Drawing.Color]::Red
                        $chk.Text += " [ERROR]"
                    }
                }
            }

            $btnRemove.Enabled = $true
            $btnSelectAll.Enabled = $true
            $btnSelectRec.Enabled = $true
            $panelApps.Enabled = $true
            $lblStatus.Text = "Proceso finalizado. Errores: $errors"
            [System.Windows.Forms.MessageBox]::Show("Proceso completado.`nEliminadas: $($selectedCount - $errors)`nErrores: $errors", "Informe", 'OK', 'Information')
        }
    })

    # Mostrar Ventana
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

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # 3. Configuracion del Formulario
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Optimizador de Servicios Offline - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(1000, 700)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Titulo
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestion de Servicios por Categoria"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # --- CONTROL DE PESTAÑAS ---
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 40)
    $tabControl.Size = New-Object System.Drawing.Size(945, 520)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($tabControl)

    # Lista global para rastrear los ListViews de cada pestaña
    $globalListViews = New-Object System.Collections.Generic.List[System.Windows.Forms.ListView]

    # Barra de Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Cargando Hives... espera."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 570)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Botones
    $btnSelectAll = New-Object System.Windows.Forms.Button
    $btnSelectAll.Text = "Marcar Activos (Pestaña Actual)"
    $btnSelectAll.Location = New-Object System.Drawing.Point(20, 600)
    $btnSelectAll.Size = New-Object System.Drawing.Size(220, 35)
    $btnSelectAll.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $btnSelectAll.FlatStyle = "Flat"
    $form.Controls.Add($btnSelectAll)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "DESHABILITAR SELECCIONADOS (GLOBAL)"
    $btnApply.Location = New-Object System.Drawing.Point(600, 600)
    $btnApply.Size = New-Object System.Drawing.Size(360, 35)
    $btnApply.BackColor = [System.Drawing.Color]::Crimson
    $btnApply.ForeColor = [System.Drawing.Color]::White
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($btnApply)

    # 4. Logica de Carga Dinamica
    $form.Add_Shown({
        $form.Refresh()
        
        if (-not (Mount-Hives)) {
            $lblStatus.Text = "Error fatal al cargar Hives."
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            return
        }

        # Obtener categorias unicas del catalogo
        $categories = $script:ServiceCatalog | Select-Object -ExpandProperty Category -Unique | Sort-Object

        $tabControl.SuspendLayout()

        foreach ($cat in $categories) {
            # A. Crear Pestaña
            $tabPage = New-Object System.Windows.Forms.TabPage
            $tabPage.Text = "  $cat  "
            $tabPage.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            # B. Crear ListView
            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = [System.Windows.Forms.DockStyle]::Fill
            $lv.View = [System.Windows.Forms.View]::Details
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White
            $lv.BorderStyle = "None"
            
            # Columnas
            $lv.Columns.Add("Servicio", 200) | Out-Null
            $lv.Columns.Add("Estado Actual", 120) | Out-Null
            $lv.Columns.Add("Descripcion", 550) | Out-Null
            
            # Identificador (Tag en el TabPage para facilitar busqueda si fuera necesario)
            $tabPage.Tag = $cat
            
            $tabPage.Controls.Add($lv)
            $tabControl.TabPages.Add($tabPage)
            $globalListViews.Add($lv)
        }

        # C. Llenar Datos
        $totalServices = 0

        foreach ($svc in $script:ServiceCatalog) {
            # 1. Encontrar el ListView correcto para la categoria del servicio
            $targetLV = $null
            # Iteramos los TabPages para encontrar el que coincida con la categoria
            foreach ($tab in $tabControl.TabPages) {
                if ($tab.Tag -eq $svc.Category) {
                    $targetLV = $tab.Controls[0] # El ListView es el primer control
                    break
                }
            }

            if ($targetLV) {
                # 2. Leer Estado del Registro Offline
                $regPath = "Registry::HKLM\OfflineSystem\ControlSet001\Services\$($svc.Name)"
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

                # 3. Crear Item Visual
                $item = New-Object System.Windows.Forms.ListViewItem($svc.Name)
                $item.SubItems.Add($currentStart) | Out-Null
                $item.SubItems.Add($svc.Description) | Out-Null
                $item.Tag = $svc.Name # Guardamos el nombre tecnico para usarlo al aplicar

                # Colores y Checkboxes
                if ($isDisabled) {
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                    $item.Checked = $false # Ya esta deshabilitado
                } elseif ($currentStart -eq "No Encontrado") {
                    $item.ForeColor = [System.Drawing.Color]::Gray
                    $item.Checked = $false # No existe, no se puede tocar
                } else {
                    $item.Checked = $true # Existe y no esta deshabilitado -> Sugerir apagar
                }

                $targetLV.Items.Add($item) | Out-Null
                $totalServices++
            }
        }

        $tabControl.ResumeLayout()
        $lblStatus.Text = "Carga lista. $totalServices servicios encontrados."
        $lblStatus.ForeColor = [System.Drawing.Color]::LightGreen
    })

    # 5. Evento Cierre
    $form.Add_FormClosing({ 
        $lblStatus.Text = "Guardando Hives..."
        $form.Refresh()
        Unmount-Hives 
    })

    # 6. Botones
    
    # "Marcar Todo" (Solo pestaña actual)
    $btnSelectAll.Add_Click({
        $currentTab = $tabControl.SelectedTab
        if ($currentTab) {
            $lv = $currentTab.Controls[0]
            foreach ($item in $lv.Items) {
                # Solo marcar si no esta ya deshabilitado ni es inexistente
                if ($item.SubItems[1].Text -ne "Deshabilitado" -and $item.SubItems[1].Text -ne "No Encontrado") {
                    $item.Checked = $true
                }
            }
        }
    })

    # "Aplicar" (Global)
    $btnApply.Add_Click({
        # Contar seleccionados globales
        $totalChecked = 0
        foreach ($lv in $globalListViews) { $totalChecked += $lv.CheckedItems.Count }

        if ($totalChecked -eq 0) { 
            [System.Windows.Forms.MessageBox]::Show("No has seleccionado ningun servicio.", "Aviso", 'OK', 'Warning')
            return 
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show("Se van a deshabilitar $totalChecked servicios en la imagen.`n¿Estas seguro?", "Confirmar Cambios", 'YesNo', 'Warning')
        if ($confirm -eq 'No') { return }
        
        $btnApply.Enabled = $false
        $tabControl.Enabled = $false
        
        $successCount = 0
        $errCount = 0

        # Recorrer todas las listas
        foreach ($lv in $globalListViews) {
            foreach ($item in $lv.CheckedItems) {
                $svcName = $item.Tag
                $regPath = "Registry::HKLM\OfflineSystem\ControlSet001\Services\$svcName"
                
                $lblStatus.Text = "Deshabilitando: $svcName..."
                $form.Refresh()

                try {
                    # Valor 4 = Disabled
                    Set-ItemProperty -Path $regPath -Name "Start" -Value 4 -Type DWord -Force -ErrorAction Stop
                    
                    # Feedback Visual
                    $item.SubItems[1].Text = "Deshabilitado"
                    $item.ForeColor = [System.Drawing.Color]::LightGreen
                    $item.Checked = $false
                    $successCount++
                } catch {
                    $errCount++
                    Write-Log -LogLevel ERROR -Message "Fallo servicio $($svcName): $_"
                    $item.ForeColor = [System.Drawing.Color]::Red
                }
            }
        }
        
        $btnApply.Enabled = $true
        $tabControl.Enabled = $true
        $lblStatus.Text = "Proceso finalizado."
        
        [System.Windows.Forms.MessageBox]::Show("Servicios Deshabilitados: $successCount`nErrores: $errCount", "Informe", 'OK', 'Information')
    })

    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# =================================================================
#  UTILIDADES DE REGISTRO OFFLINE (MOTOR NECESARIO)
# =================================================================
function Mount-Hives {
    Write-Log -LogLevel INFO -Message "HIVES: Iniciando secuencia de montaje..."
    
    # 1. Definir rutas fisicas
    $sysHive = Join-Path $Script:MOUNT_DIR "Windows\System32\config\SYSTEM"
    $softHive = Join-Path $Script:MOUNT_DIR "Windows\System32\config\SOFTWARE"
    $userHive = Join-Path $Script:MOUNT_DIR "Users\Default\NTUSER.DAT"

    # 2. Validacion de archivos fisicos
    if (-not (Test-Path $sysHive)) { 
        [System.Windows.Forms.MessageBox]::Show("Error Critico: No se encuentra el archivo SYSTEM en:`n$sysHive`n`n¿La imagen esta corrupta?", "Error Fatal", 'OK', 'Error')
        return $false 
    }

    # 3. Limpieza preventiva (Forzar descarga si quedaron colgados)
    $hives = @("HKLM\OfflineSystem", "HKLM\OfflineSoftware", "HKLM\OfflineUser")
    foreach ($h in $hives) {
        reg unload $h 2>$null | Out-Null
    }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    Start-Sleep -Milliseconds 500

    try {
        # 4. Montaje con captura de errores explicita
        Write-Host "Cargando SYSTEM..." -NoNewline; 
        $p1 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSystem `"$sysHive`"" -Wait -PassThru -NoNewWindow
        if ($p1.ExitCode -ne 0) { throw "Error al cargar SYSTEM (Codigo $($p1.ExitCode))" }
        Write-Host "OK" -ForegroundColor Green

        Write-Host "Cargando SOFTWARE..." -NoNewline; 
        $p2 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineSoftware `"$softHive`"" -Wait -PassThru -NoNewWindow
        if ($p2.ExitCode -ne 0) { throw "Error al cargar SOFTWARE (Codigo $($p2.ExitCode))" }
        Write-Host "OK" -ForegroundColor Green

        Write-Host "Cargando USER..." -NoNewline; 
        $p3 = Start-Process reg.exe -ArgumentList "load HKLM\OfflineUser `"$userHive`"" -Wait -PassThru -NoNewWindow
        if ($p3.ExitCode -ne 0) { throw "Error al cargar NTUSER.DAT (Codigo $($p3.ExitCode))" }
        Write-Host "OK" -ForegroundColor Green

        return $true
    } catch {
        Write-Error "`n[FATAL] $_"
        Write-Log -LogLevel ERROR -Message "Fallo Mount-Hives: $_"
        [System.Windows.Forms.MessageBox]::Show("Error al cargar el Registro:`n$_`n`nIntenta reiniciar el PC para liberar los archivos.", "Error de Montaje", 'OK', 'Error')
        return $false
    }
}

function Unmount-Hives {
    Write-Host "Guardando y descargando Hives..." -ForegroundColor Yellow
    
    # CORRECCIoN: Solo intentamos actualizar la GUI si la etiqueta existe.
    # Si estamos en modo consola, esto se salta y evita el error.
    if ($lblStatus) { 
        try { $lblStatus.Text = "Guardando cambios en el registro..." } catch {} 
    }
    
    # Pausa de seguridad para permitir que el disco termine de escribir
    Start-Sleep -Seconds 1
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    
    $hives = @("HKLM\OfflineSystem", "HKLM\OfflineSoftware", "HKLM\OfflineUser")
    
    foreach ($hive in $hives) {
        $retries = 0; $done = $false
        while ($retries -lt 5 -and -not $done) {
            reg unload $hive 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $done = $true } 
            else { 
                $retries++
                Write-Host "." -NoNewline -ForegroundColor Yellow
                Start-Sleep -Seconds 1 
            }
        }
        if (-not $done) { Write-Error " [!] No se pudo guardar $hive. Es posible que los cambios no persistan." }
    }
    Write-Host " [OK]" -ForegroundColor Green
}

function Translate-OfflinePath {
    param([string]$OnlinePath)
    
    # 1. Limpieza inicial
    $cleanPath = $OnlinePath -replace "^Registry::", "" -replace "^HKLM:", "HKEY_LOCAL_MACHINE"
    $cleanPath = $cleanPath.Trim()

    # 2. Traducciones Directas a formato REG.EXE (Sin dos puntos)
    
    # SYSTEM
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SYSTEM") {
        $newPath = $cleanPath -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKLM\OfflineSystem"
        return $newPath -replace "CurrentControlSet", "ControlSet001"
    }

    # SOFTWARE
    if ($cleanPath -match "HKEY_LOCAL_MACHINE\\SOFTWARE") {
        return $cleanPath -replace "HKEY_LOCAL_MACHINE\\SOFTWARE", "HKLM\OfflineSoftware"
    }
    
    # USUARIO (HKCU)
    if ($cleanPath -match "HKEY_CURRENT_USER") {
        return $cleanPath -replace "HKEY_CURRENT_USER", "HKLM\OfflineUser"
    }
    
    # CLASSES
    if ($cleanPath -match "HKEY_CLASSES_ROOT") {
        return $cleanPath -replace "HKEY_CLASSES_ROOT", "HKLM\OfflineSoftware\Classes"
    }
    
    return $null
}

function Get-RegValue-Native {
    param(
        [string]$RegPath,
        [string]$ValueName
    )
    
    # Definimos archivos temporales para capturar la salida y los errores
    $outFile = Join-Path $env:TEMP "reg_q_$($PID).tmp"
    $errFile = Join-Path $env:TEMP "reg_e_$($PID).tmp"

    # CORRECCIoN: Usamos $errFile en lugar de $null para RedirectStandardError
    $proc = Start-Process -FilePath "reg.exe" -ArgumentList "query `"$RegPath`" /v `"$ValueName`"" -Wait -NoNewWindow -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    
    $result = $null

    if ($proc.ExitCode -eq 0) {
        $output = Get-Content $outFile -ErrorAction SilentlyContinue
        
        # Logica mejorada para leer el valor exacto y evitar errores de espacios
        foreach ($line in $output) {
            # Busca la linea que tenga el nombre del valor
            if ($line -match "$([regex]::Escape($ValueName))") {
                # Divide la linea usando el separador de tipo de registro conocido (REG_SZ, REG_DWORD, etc)
                if ($line -match "\s+REG_(SZ|DWORD|QWORD|MULTI_SZ|EXPAND_SZ|BINARY)\s+(.*)") {
                    $result = $matches[2] # Captura todo lo que esta despues del tipo
                    break
                }
            }
        }

        # Convertir Hexadecimal a Decimal si es necesario (para visualizacion amigable en la GUI)
        if ($result -match "^0x") {
            try { $result = [Convert]::ToInt64($result, 16).ToString() } catch { }
        }
    }
    
    # Limpieza de archivos temporales
    Remove-Item $outFile -Force -ErrorAction SilentlyContinue
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    
    return $result
}

function Show-RegPreview-GUI {
    param([string]$FilePath)

    # Configuración de la Ventana
    $pForm = New-Object System.Windows.Forms.Form
    $pForm.Text = "Vista Previa de Importacion - $([System.IO.Path]::GetFileName($FilePath))"
    $pForm.Size = New-Object System.Drawing.Size(1200, 600) # Más ancha
    $pForm.StartPosition = "CenterParent"
    $pForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $pForm.ForeColor = [System.Drawing.Color]::White
    $pForm.FormBorderStyle = "FixedDialog"
    $pForm.MaximizeBox = $false

    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Analisis de cambios: Revisa los valores antes de aplicar"
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
    
    # Truco de altura de filas
    $imgListP = New-Object System.Windows.Forms.ImageList
    $imgListP.ImageSize = New-Object System.Drawing.Size(1, 30) 
    $lvP.SmallImageList = $imgListP

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

    $pForm.Add_Shown({
        $pForm.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $lvP.BeginUpdate()
        
        $lines = Get-Content $FilePath
        $currentKeyOffline = $null

        foreach ($line in $lines) {
            $line = $line.Trim()
            
            # 1. Detectar Claves
            if ($line -match "^\[(-?)(HKEY_.*|HKLM.*|HKCU.*|HKCR.*)\]$") {
                $isDelete = $matches[1] -eq "-"
                $keyRaw = $matches[2]
                $keyOffline = $keyRaw # Copia inicial

                # --- LÓGICA DE TRADUCCIÓN ROBUSTA ---
                # 1. Classes Root (CRÍTICO para tu caso) -> Software\Classes
                if ($keyOffline -match "^HKEY_CLASSES_ROOT" -or $keyOffline -match "^HKCR") {
                     $keyOffline = $keyOffline -replace "^HKEY_CLASSES_ROOT", "HKLM:\OfflineSoftware\Classes"
                     $keyOffline = $keyOffline -replace "^HKCR", "HKLM:\OfflineSoftware\Classes"
                }
                # 2. Rutas Estándar
                else {
                    $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SOFTWARE", "HKLM:\OfflineSoftware")
                    $keyOffline = $keyOffline.Replace("HKLM\SOFTWARE", "HKLM:\OfflineSoftware")
                    $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SYSTEM", "HKLM:\OfflineSystem")
                    $keyOffline = $keyOffline.Replace("HKLM\SYSTEM", "HKLM:\OfflineSystem")
                    $keyOffline = $keyOffline.Replace("HKEY_CURRENT_USER", "HKLM:\OfflineUser")
                    $keyOffline = $keyOffline.Replace("HKCU", "HKLM:\OfflineUser")
                }

                # 3. Limpieza final para asegurar formato de unidad PowerShell
                if (-not $keyOffline.StartsWith("HKLM:\")) { 
                    $keyOffline = $keyOffline -replace "^HKLM\\", "HKLM:\" 
                }
                $currentKeyOffline = $keyOffline

                # Crear fila de CLAVE
                $item = New-Object System.Windows.Forms.ListViewItem("CLAVE")
                $item.SubItems.Add($keyRaw) | Out-Null
                
                if ($isDelete) {
                    $item.SubItems.Add("EXISTE") | Out-Null
                    $item.SubItems.Add(">>> ELIMINAR <<<") | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Salmon
                } else {
                    $exists = Test-Path $currentKeyOffline
                    $item.SubItems.Add( $(if($exists){"EXISTE"}else{"NUEVA"}) ) | Out-Null
                    $item.SubItems.Add("-") | Out-Null
                    $item.ForeColor = [System.Drawing.Color]::Yellow
                }
                $lvP.Items.Add($item) | Out-Null
            }
            # 2. Detectar Valores Nombrados ("Nombre"="Valor")
            elseif ($currentKeyOffline -and $line -match '^"(.+?)"=(.*)') {
                $valName = $matches[1]
                $newVal = $matches[2]
                $currVal = "No existe" # Valor por defecto si no se encuentra
                
                try {
                    if (Test-Path $currentKeyOffline) {
                        # Intentamos leer la propiedad
                        $p = Get-ItemProperty -Path $currentKeyOffline -Name $valName -ErrorAction SilentlyContinue
                        if ($p) { 
                            $rawVal = $p.$valName 
                            # Si existe pero es cadena vacía, lo mostramos explícitamente
                            if ($rawVal -eq "") { $currVal = "(Vacio)" } else { $currVal = $rawVal }
                        }
                    }
                } catch {}

                $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                $item.SubItems.Add($valName) | Out-Null
                $item.SubItems.Add("$currVal") | Out-Null
                $item.SubItems.Add("$newVal") | Out-Null

                if ("$currVal" -eq "$newVal") {
                    $item.ForeColor = [System.Drawing.Color]::Gray
                } else {
                    $item.ForeColor = [System.Drawing.Color]::Cyan
                    $item.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
                }
                $lvP.Items.Add($item) | Out-Null
            }
            # 3. Detectar Valor por Defecto (@="Valor")
            elseif ($currentKeyOffline -and $line -match '^@=(.*)') {
                $valName = "(Predeterminado)"
                $newVal = $matches[1]
                $currVal = "No existe"
                
                try {
                    if (Test-Path $currentKeyOffline) {
                        $p = Get-ItemProperty -Path $currentKeyOffline -Name "(default)" -ErrorAction SilentlyContinue
                        if ($p) { 
                            $rawVal = $p.'(default)' 
                            if ([string]::IsNullOrEmpty($rawVal)) { $currVal = "(Vacio)" } else { $currVal = $rawVal }
                        }
                    }
                } catch {}

                $item = New-Object System.Windows.Forms.ListViewItem("   Valor")
                $item.SubItems.Add($valName) | Out-Null
                $item.SubItems.Add("$currVal") | Out-Null
                $item.SubItems.Add("$newVal") | Out-Null
                $item.ForeColor = [System.Drawing.Color]::Cyan
                $item.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
                
                $lvP.Items.Add($item) | Out-Null
            }
        }
        $lvP.EndUpdate()
        $pForm.Cursor = [System.Windows.Forms.Cursors]::Default
    })

    return ($pForm.ShowDialog() -eq 'OK')
}

# =================================================================
#  Modulo de Tweaks Offline
# =================================================================
function Show-Tweaks-Offline-GUI {
    # 1. Validaciones Previas
    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return 
    }

    # 2. Cargar Catálogo
    $tweaksFile = Join-Path $PSScriptRoot "Catalogos\Ajustes.ps1"
    if (-not (Test-Path $tweaksFile)) { $tweaksFile = Join-Path $PSScriptRoot "Ajustes.ps1" }
    if (Test-Path $tweaksFile) { . $tweaksFile } else { Write-Warning "Falta Ajustes.ps1"; return }

    # 3. Montar Hives
    if (-not (Mount-Hives)) { return }

    # --- INICIO DE CONSTRUCCIÓN GUI ---
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Optimizacion de Registro Offline (WIM) - $Script:MOUNT_DIR"
    $form.Size = New-Object System.Drawing.Size(1200, 750)
    $form.StartPosition = "CenterScreen"
    $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false

    # Título
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Gestor de Ajustes y Registro"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = New-Object System.Drawing.Point(20, 10)
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    # Botón Importar .REG (Arriba a la derecha)
    $btnImport = New-Object System.Windows.Forms.Button
    $btnImport.Text = "IMPORTAR ARCHIVO .REG..."
    $btnImport.Location = New-Object System.Drawing.Point(950, 10)
    $btnImport.Size = New-Object System.Drawing.Size(200, 35)
    $btnImport.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnImport.ForeColor = [System.Drawing.Color]::White
    $btnImport.FlatStyle = "Flat"
    $form.Controls.Add($btnImport)

    # Control de Pestañas
    $tabControl = New-Object System.Windows.Forms.TabControl
    $tabControl.Location = New-Object System.Drawing.Point(20, 60)
    $tabControl.Size = New-Object System.Drawing.Size(1140, 600)
    $tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Controls.Add($tabControl)

    # Barra de Estado
    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = "Listo. Selecciona ajustes para aplicar."
    $lblStatus.Location = New-Object System.Drawing.Point(20, 670)
    $lblStatus.AutoSize = $true
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # --- LOGICA DE ANÁLISIS .REG (Interna para la GUI) ---
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
                
                # Traducción Secuencial (La que arreglamos)
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
            
            # 1. Llamada a la Vista Previa
            $userConfirmed = Show-RegPreview-GUI -FilePath $file
            
            if ($userConfirmed) {
                try {
                    $content = Get-Content -Path $file -Raw
                    
                    # --- TRADUCCIÓN DE RUTAS SECUENCIAL ---
                    # Usamos -replace (Insensible a mayúsculas) y escapamos barras
                    
                    $newContent = $content -replace "HKEY_LOCAL_MACHINE\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware"
                    $newContent = $newContent -replace "HKLM\\SOFTWARE", "HKLM\OfflineSoftware"
                    
                    $newContent = $newContent -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem"
                    $newContent = $newContent -replace "HKLM\\SYSTEM", "HKLM\OfflineSystem"
                    
                    $newContent = $newContent -replace "HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE\OfflineUser"
                    $newContent = $newContent -replace "HKCU", "HKLM\OfflineUser"

                    # --- NUEVO: REEMPLAZO PARA CLASES ---
                    # Esto redirige HKCR a la rama de software offline
                    $newContent = $newContent -replace "HKEY_CLASSES_ROOT", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"
                    $newContent = $newContent -replace "HKCR", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"
                    # ------------------------------------

                    $tempReg = Join-Path $env:TEMP "gui_import.reg"
                    # Guardamos en Unicode para máxima compatibilidad con reg.exe
                    $newContent | Set-Content -Path $tempReg -Encoding Unicode -Force

                    # Ejecución robusta capturando salida para depuración
                    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pInfo.FileName = "reg.exe"
                    $pInfo.Arguments = "import `"$tempReg`""
                    $pInfo.UseShellExecute = $false
                    $pInfo.CreateNoWindow = $true
                    $pInfo.RedirectStandardError = $true
                    $pInfo.RedirectStandardOutput = $true
                    
                    $process = [System.Diagnostics.Process]::Start($pInfo)
                    $process.WaitForExit()
                    
                    $stdErr = $process.StandardError.ReadToEnd()
                    $exitCode = $process.ExitCode

                    if ($exitCode -eq 0) {
                        [System.Windows.Forms.MessageBox]::Show("Archivo importado correctamente.", "Exito", 'OK', 'Information')
                    } else {
                        $errorMsg = "Fallo al importar (Codigo: $exitCode).`n`nDetalle:`n$stdErr"
                        [System.Windows.Forms.MessageBox]::Show($errorMsg, "Error de Importacion", 'OK', 'Error')
                    }
                    
                    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

                } catch {
                    [System.Windows.Forms.MessageBox]::Show("Excepcion critica: $_", "Error Script", 'OK', 'Error')
                }
            }
        }
    })

    # --- GENERAR PESTAÑAS Y LISTAS ---
    $form.Add_Shown({
        $form.Refresh()
        $cats = $script:SystemTweaks | Where { $_.Method -eq "Registry" } | Select -Expand Category -Unique | Sort
        $tabControl.SuspendLayout()

        foreach ($cat in $cats) {
            $tp = New-Object System.Windows.Forms.TabPage
            $tp.Text = "  $cat  "
            $tp.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)

            # ListView
            $lv = New-Object System.Windows.Forms.ListView
            $lv.Dock = "Fill"
            $lv.View = "Details"
            $lv.CheckBoxes = $true
            $lv.FullRowSelect = $true
            $lv.GridLines = $true
            $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
            $lv.ForeColor = [System.Drawing.Color]::White
			
			$imgList = New-Object System.Windows.Forms.ImageList
            # El segundo número (35) es la ALTURA en píxeles. Cámbialo a tu gusto (ej. 40, 50).
            $imgList.ImageSize = New-Object System.Drawing.Size(1, 25) 
            $lv.SmallImageList = $imgList
            
            $lv.Columns.Add("Ajuste", 450) | Out-Null
            $lv.Columns.Add("Estado Actual", 120) | Out-Null
            $lv.Columns.Add("Descripcion", 500) | Out-Null

            # Panel inferior
            $pn = New-Object System.Windows.Forms.Panel; $pn.Dock = "Bottom"; $pn.Height = 50; $pn.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 40)
            
            $btnApply = New-Object System.Windows.Forms.Button
            $btnApply.Text = "APLICAR CAMBIOS SELECCIONADOS"
            $btnApply.Location = New-Object System.Drawing.Point(800, 10)
            $btnApply.Size = New-Object System.Drawing.Size(300, 30)
            $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
            $btnApply.ForeColor = [System.Drawing.Color]::White
            $btnApply.FlatStyle = "Flat"
            $btnApply.Tag = $lv 
            
            $btnCheckAll = New-Object System.Windows.Forms.Button
            $btnCheckAll.Text = "Marcar Inactivos"
            $btnCheckAll.Location = New-Object System.Drawing.Point(20, 10)
            $btnCheckAll.Size = New-Object System.Drawing.Size(150, 30)
            $btnCheckAll.BackColor = [System.Drawing.Color]::Gray
            $btnCheckAll.FlatStyle = "Flat"
            $btnCheckAll.Tag = $lv

            $pn.Controls.Add($btnApply)
            $pn.Controls.Add($btnCheckAll)
            $tp.Controls.Add($pn)
            
            # Llenar datos (Lectura Nativa Segura)
            $tweaks = $script:SystemTweaks | Where { $_.Category -eq $cat -and $_.Method -eq "Registry" }
            foreach ($tw in $tweaks) {
                $pathRaw = Translate-OfflinePath -OnlinePath $tw.RegistryPath
                if ($pathRaw) {
                    $item = New-Object System.Windows.Forms.ListViewItem($tw.Name)
                    
                    # Lectura Nativa
                    $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                    $state = "INACTIVO"
                    
                    # CAMBIO: Color por defecto ahora es BLANCO para mejor lectura
                    $color = [System.Drawing.Color]::White 
                    
                    try {
                        $curr = (Get-ItemProperty -Path $psPath -Name $tw.RegistryKey -ErrorAction SilentlyContinue).($tw.RegistryKey)
                        if ("$curr" -eq "$($tw.EnabledValue)") {
                            $state = "ACTIVO"
                            $color = [System.Drawing.Color]::Cyan # Activos siguen en Cyan
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

            # EVENTOS DE BOTONES
            $btnCheckAll.Add_Click({
                $targetLv = $this.Tag 
                foreach ($i in $targetLv.Items) { 
                    if ($i.SubItems[1].Text -ne "ACTIVO") { $i.Checked = $true } 
                }
            })

            $btnApply.Add_Click({
                $targetLv = $this.Tag 
                $sel = $targetLv.CheckedItems
                
                if ($sel.Count -eq 0) { return }
                
                $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                $lblStatus.Text = "Aplicando cambios..."
                $form.Refresh()

                foreach ($it in $sel) {
                    $t = $it.Tag
                    $pathRaw = Translate-OfflinePath -OnlinePath $t.RegistryPath
                    if ($pathRaw) {
                        $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
                        try {
                            if (-not (Test-Path $psPath)) { New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null }
                            
                            $type = [Microsoft.Win32.RegistryValueKind]::DWord
                            if ($t.RegistryType -eq "String") { $type = [Microsoft.Win32.RegistryValueKind]::String }

                            Set-ItemProperty -Path $psPath -Name $t.RegistryKey -Value $t.EnabledValue -Type $type -Force -ErrorAction Stop
                            
                            # Verificación
                            $check = (Get-ItemProperty -Path $psPath -Name $t.RegistryKey -ErrorAction SilentlyContinue).($t.RegistryKey)
                            if ("$check" -eq "$($t.EnabledValue)") {
                                $it.SubItems[1].Text = "ACTIVO"
                                $it.ForeColor = [System.Drawing.Color]::Cyan
                                $it.Checked = $false
                            }
                        } catch {
                            $it.SubItems[1].Text = "ERROR"
                            $it.ForeColor = [System.Drawing.Color]::Red
                        }
                    }
                    $form.Refresh()
                }
                $form.Cursor = [System.Windows.Forms.Cursors]::Default
                $lblStatus.Text = "Proceso finalizado."
                [System.Windows.Forms.MessageBox]::Show("Ajustes aplicados correctamente.", "Listo", 'OK', 'Information')
            })
        }
        $tabControl.ResumeLayout()
    })

    # Cierre Seguro
    $form.Add_FormClosing({ 
        $lblStatus.Text = "Guardando Hives..."
        $form.Refresh()
        Unmount-Hives 
    })
    
    $form.ShowDialog() | Out-Null
    $form.Dispose()
}

# Funcion auxiliar para aplicar el cambio en consola
function Apply-Tweak-Console {
    param([PSCustomObject]$TweakObj)

    $pathRaw = Translate-OfflinePath -OnlinePath $TweakObj.RegistryPath
    if (-not $pathRaw) { Write-Error "No se pudo traducir la ruta para: $($TweakObj.Name)"; return }

    $psPath = $pathRaw -replace "^HKLM\\", "HKLM:\"
    $valToSet = $TweakObj.EnabledValue
    $type = [Microsoft.Win32.RegistryValueKind]::DWord
    if ($TweakObj.RegistryType -eq "String") { $type = [Microsoft.Win32.RegistryValueKind]::String }

    Write-Host "Aplicando: $($TweakObj.Name)... " -NoNewline

    try {
        # 1. Crear ruta si no existe
        if (-not (Test-Path $psPath)) {
            New-Item -Path $psPath -Force -ErrorAction Stop | Out-Null
        }
        # 2. Establecer valor
        Set-ItemProperty -Path $psPath -Name $TweakObj.RegistryKey -Value $valToSet -Type $type -Force -ErrorAction Stop
        
        Write-Host "[OK]" -ForegroundColor Green
        Write-Log -LogLevel ACTION -Message "TWEAK APLICADO: $($TweakObj.Name)"
    } catch {
        Write-Host "[ERROR]" -ForegroundColor Red
        Write-Warning "   $($_.Exception.Message)"
        Write-Log -LogLevel ERROR -Message "FALLO TWEAK $($TweakObj.Name): $($_.Exception.Message)"
    }
}

# :main_menu (Funcion principal que muestra el menu inicial)
function Main-Menu {
    $Host.UI.RawUI.WindowTitle = "AdminImagenOffline v$($script:Version) by SOFTMAXTER"
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "Administrador de Imagen offline v$($script:Version) by SOFTMAXTER" -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "  Ruta WIM : $Script:WIM_FILE_PATH" -ForegroundColor Gray
        Write-Host "  Montado  : $($Script:IMAGE_MOUNTED) (Indice: $($Script:MOUNTED_INDEX))" -ForegroundColor Gray
        Write-Host "  Dir Montaje: $Script:MOUNT_DIR" -ForegroundColor Gray
        Write-Host "  Dir Scratch: $Script:Scratch_DIR" -ForegroundColor Gray
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Gestionar Imagen (Montar/Guardar/Exportar)" 
        Write-Host ""
        Write-Host "   [2] Cambiar Edicion de Windows" 
        Write-Host ""
        Write-Host "   [3] Integrar Drivers (Controladores)" -ForegroundColor Green # NUEVO
        Write-Host ""
        Write-Host "   [4] Eliminar Bloatware (Apps)" -ForegroundColor Green # NUEVO
        Write-Host ""
        Write-Host "   [5] Servicios del Sistema" -ForegroundColor Magenta
        Write-Host "       (Deshabilita servicios innecesarios)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [6] Tweaks y Registro" -ForegroundColor Magenta
        Write-Host "       (Optimizacion de rendimiento, privacidad e importador REG)" -ForegroundColor Gray
		Write-Host ""
        Write-Host "   [7] Herramientas de Limpieza y Reparacion" -ForegroundColor White
        Write-Host ""
		Write-Host "   [8] Configurar Rutas de Trabajo" -ForegroundColor Yellow
        Write-Host "-------------------------------------------------------"
        Write-Host "   [S] Salir" -ForegroundColor Red
        Write-Host ""
        
        $opcionM = Read-Host "Selecciona una opcion"
        Write-Log -LogLevel INFO -Message "MENU_MAIN: Usuario selecciono '$opcionM'."
        
        switch ($opcionM.ToUpper()) {
            "1" { Image-Management-Menu }
            "2" { Cambio-Edicion-Menu }
            "3" { if ($Script:IMAGE_MOUNTED) { Show-Drivers-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "4" { if ($Script:IMAGE_MOUNTED) { Show-Bloatware-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "5" { Show-Services-Offline-GUI }
            "6" { Show-Tweaks-Offline-GUI }           
            "7" { Limpieza-Menu }
            "8" { Show-ConfigMenu }
            "S" { 
                Write-Host "Saliendo..."
                Write-Log -LogLevel INFO -Message "Script cerrado."
                exit 
            }
            default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

# =================================================================
#  Verificacion de Montaje Existente
# =================================================================
$Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null
$TEMP_DISM_OUT = Join-Path $env:TEMP "dism_check_$($RANDOM).tmp"
Write-Host "Verificando imagenes montadas..." -ForegroundColor Gray

try {
    # Capturamos la salida en un archivo temporal para evitar problemas de codificacion en consola
    dism /get-mountedimageinfo 2>$null | Out-File -FilePath $TEMP_DISM_OUT -Encoding utf8
    $mountInfo = Get-Content -Path $TEMP_DISM_OUT -Encoding utf8 -ErrorAction SilentlyContinue
    
    # --- REGEX PARA SOPORTE MULTI-IDIOMA (EN/ES) ---
    # Busca "Mount Dir :" O "Directorio de montaje :"
    $mountDirLine = $mountInfo | Select-String -Pattern "(Mount Dir|Directorio de montaje)\s*:" | Select-Object -First 1
    
    if ($mountDirLine) {
        Write-Log -LogLevel INFO -Message "Detectada imagen previamente montada."
        $Script:IMAGE_MOUNTED = 1
        
        # Extraer valor limpiamente sin importar el idioma del label
        $Script:MOUNT_DIR = ($mountDirLine.Line -split ':', 2)[1].Trim()
        
        # Busca "Image File :" O "Archivo de imagen :"
        $wimPathLine = $mountInfo | Select-String -Pattern "(Image File|Archivo de imagen)\s*:" | Select-Object -First 1
        if ($wimPathLine) {
            $Script:WIM_FILE_PATH = ($wimPathLine.Line -split ':', 2)[1].Trim()
            # Limpiar prefijo de ruta larga de Windows si existe
            if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
        }
        
        # Busca "Image Index :" O "Indice de imagen :" (El punto en Indice acepta i/I y acentos)
        $indexLine = $mountInfo | Select-String -Pattern "(Image Index|ndice de imagen)\s*:" | Select-Object -First 1
        if ($indexLine) { $Script:MOUNTED_INDEX = ($indexLine.Line -split ':', 2)[1].Trim() }
        
        Write-Host "Imagen encontrada: $($Script:WIM_FILE_PATH)" -ForegroundColor Yellow
        Write-Host "Indice: $($Script:MOUNTED_INDEX) | Montada en: $($Script:MOUNT_DIR)" -ForegroundColor Yellow
        Write-Log -LogLevel INFO -Message "Info recuperada: WIM='$($Script:WIM_FILE_PATH)', Index='$($Script:MOUNTED_INDEX)', MountDir='$($Script:MOUNT_DIR)'."
    } else {
        Write-Log -LogLevel INFO -Message "No se encontraron imagenes montadas previamente."
    }
} catch {
    Write-Warning "Error al verificar imagenes montadas: $($_.Exception.Message)"
    Write-Log -LogLevel WARN -Message "Error verificando montaje previo: $($_.Exception.Message)"
} finally {
    if (Test-Path $TEMP_DISM_OUT) { Remove-Item -Path $TEMP_DISM_OUT -Force -ErrorAction SilentlyContinue }
}

Ensure-WorkingDirectories

# =============================================
#  Punto de Entrada: Iniciar el Menu Principal
# =============================================
Main-Menu
