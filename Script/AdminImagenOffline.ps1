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
    1.4.3
#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.4.3"

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
        Write-Error "[ERROR] No se pudo guardar el archivo de configuracion en '$($script:configFile)'."
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
        Pause; return
    }

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM a montar" -Filter "Archivos WIM (*.wim)|*.wim|Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if ([string]::IsNullOrEmpty($path)) { Write-Warning "Operacion cancelada."; Pause; return }
    $Script:WIM_FILE_PATH = $path

    # --- [INICIO] BLOQUE DE SEGURIDAD ESD MEJORADO ---
    if ($Script:WIM_FILE_PATH -match '\.esd$') {
        Clear-Host
        Write-Warning "======================================================="
        Write-Warning "         !!! ALERTA DE FORMATO ESD DETECTADA !!!       "
        Write-Warning "======================================================="
        Write-Host ""
        Write-Host "Has seleccionado una imagen .ESD (Solo Lectura / Comprimida)." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "IMPORTANTE:" -ForegroundColor Cyan
        Write-Host "1. Si haces cambios, el 'Guardar Cambios (Commit)' FALLARA." -ForegroundColor Red
        Write-Host "2. Para salvar tu trabajo, tendras que usar OBLIGATORIAMENTE:" -ForegroundColor White
        Write-Host "   -> Menú 'Guardar Cambios' > Opción [3] 'Guardar como Nuevo Archivo WIM'" -ForegroundColor Green
        Write-Host ""
        Write-Host "RECOMENDACION IDEAL: Usa 'Convertir ESD a WIM' en el menu principal antes de montar." -ForegroundColor Gray
        Write-Host ""
        
        $confirmEsd = Read-Host "Escribe 'SI' para montar de todos modos (bajo tu riesgo) o Enter para salir"
        if ($confirmEsd.ToUpper() -ne 'SI') {
            Write-Warning "Operacion cancelada. Convierte a WIM primero."
            $Script:WIM_FILE_PATH = $null
            Pause
            return
        }
        Write-Host "Procediendo... Recuerda usar 'Guardar como Nuevo WIM' al finalizar." -ForegroundColor DarkGray
    }

    Write-Host "[+] Obteniendo informacion del WIM..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"

    $INDEX = Read-Host "`nIngrese el numero de indice a montar"
    
    # --- INICIO DE LA MEJORA ---
    # Verificar si el directorio de montaje está sucio antes de empezar
    if ((Get-ChildItem $Script:MOUNT_DIR -Force | Measure-Object).Count -gt 0) {
        Write-Warning "El directorio de montaje ($Script:MOUNT_DIR) NO esta vacio."
        Write-Warning "Esto suele causar el error 0xc1420116 o 0xc1420117."
        $cleanParams = Read-Host "¿Deseas intentar limpiarlo y desmontar residuos previos? (S/N)"
        if ($cleanParams -match 'S') {
            Write-Host "Ejecutando limpieza (DISM /Cleanup-Wim)..." -ForegroundColor Cyan
            dism /cleanup-wim
            Write-Host "Forzando eliminacion de archivos basura..." -ForegroundColor Cyan
            Remove-Item "$Script:MOUNT_DIR\*" -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    # --- FIN DE LA MEJORA ---

    Write-Host "[+] Montando imagen (Indice: $INDEX)... Esto puede tardar." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Montando imagen: '$Script:WIM_FILE_PATH' (Indice: $INDEX) en '$Script:MOUNT_DIR'"
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        Write-Host "[OK] Imagen montada exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Montaje completado con exito."
    } else {
        # Captura especifica del error tras el intento
        Write-Error "[ERROR] Fallo al montar la imagen (Codigo: $LASTEXITCODE)."
        if ($LASTEXITCODE.ToString("X") -match "C1420116|C1420117") {
            Write-Warning "CONSEJO: Este error indica que la carpeta de montaje tiene archivos bloqueados."
            Write-Warning "Reinicia el PC y ejecuta la opción 'Limpieza' en el menú principal."
        }
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

    Write-Host "[+] Preparando desmontaje..." -ForegroundColor Yellow
    
    # --- CORRECCION: Descargar Hives antes de DISM ---
    # Si tenemos hives cargados (para tweaks o limpieza), hay que bajarlos OBLIGATORIAMENTE
    # de lo contrario DISM fallara porque los archivos estan bloqueados.
    Unmount-Hives
    
    # Pequeña pausa para asegurar que el sistema de archivos libere los handles
    Start-Sleep -Seconds 2 
    # -----------------------------------------------------------

    Write-Host "[+] Desmontando imagen (descartando cambios)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Desmontando imagen (descartando cambios) desde '$Script:MOUNT_DIR'."
    
    # Ejecutamos el desmontaje
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR" /discard
    $dismExitCode = $LASTEXITCODE 

    if ($dismExitCode -eq 0) {
        $Script:IMAGE_MOUNTED = 0
        $Script:WIM_FILE_PATH = $null
        $Script:MOUNTED_INDEX = $null
        
        Write-Host "[OK] Imagen desmontada correctamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "Desmontaje exitoso."
    } else {
        Write-Error "[ERROR] Fallo el desmontaje (Codigo: $dismExitCode)."
        Write-Warning "La imagen sigue montada o bloqueada. Cierre carpetas/archivos abiertos e intente de nuevo."
        Write-Log -LogLevel ERROR -Message "Fallo el desmontaje. Codigo: $dismExitCode. Estado mantenido como MONTADO."
    }
    Pause
}

function Reload-Image {
    param([int]$RetryCount = 0)

    Clear-Host
    # Seguridad anti-bucle: Maximo 3 intentos
    if ($RetryCount -ge 3) {
        Write-Error "[ERROR FATAL] Se ha intentado recargar la imagen 3 veces sin exito."
        Write-Error "Es posible que un archivo este bloqueado por un Antivirus o el Explorador."
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
        Write-Error "[ERROR] Error al desmontar. Ejecutando limpieza profunda..."
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
        Write-Error "[ERROR] Error al remontar la imagen."
        $Script:IMAGE_MOUNTED = 0
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Guardar Cambios)
# =============================================
function Save-Changes {
    param ([string]$Mode) # 'Commit', 'Append' o 'NewWim'

    if ($Script:IMAGE_MOUNTED -eq 0) { Write-Warning "No hay imagen montada para guardar."; Pause; return }

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
        Write-Host "Nota: Esto creara un nuevo archivo WIM basado en lo que hay en la carpeta de montaje actualmente." -ForegroundColor Gray
        
        # 1. Seleccionar destino
        $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
        $DEFAULT_DEST_PATH = Join-Path $wimFileObject.DirectoryName "$($wimFileObject.BaseName)_MOD.wim"
        
        $DEST_WIM_PATH = Select-SavePathDialog -Title "Guardar copia como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
        if (-not $DEST_WIM_PATH) { Write-Warning "Operacion cancelada."; return }

        # --- MEJORA: OBTENER NOMBRE DEL iNDICE ACTUAL ---
        $defaultName = "Custom Image"
        try {
            # Usamos el cmdlet nativo de DISM para leer el nombre del indice origen
            $info = Get-WindowsImage -ImagePath $Script:WIM_FILE_PATH -Index $Script:MOUNTED_INDEX -ErrorAction SilentlyContinue
            if ($info -and $info.ImageName) {
                $defaultName = $info.ImageName
            }
        } catch {
            # Si falla, se mantiene "Custom Image" como fallback
        }
        # ------------------------------------------------

        # 2. Metadatos (Con default dinámico)
        $IMAGE_NAME = Read-Host "Ingrese el NOMBRE para la imagen interna (Enter = '$defaultName')"
        if ([string]::IsNullOrWhiteSpace($IMAGE_NAME)) { $IMAGE_NAME = $defaultName }
        
        Write-Host "`n[+] Capturando estado actual a nuevo WIM..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Guardando copia en nuevo WIM: '$DEST_WIM_PATH' con nombre '$IMAGE_NAME'"
        
        dism /Capture-Image /ImageFile:"$DEST_WIM_PATH" /CaptureDir:"$Script:MOUNT_DIR" /Name:"$IMAGE_NAME" /Compress:max /CheckIntegrity

        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Copia guardada exitosamente en:" -ForegroundColor Green
            Write-Host "     $DEST_WIM_PATH" -ForegroundColor Cyan
            Write-Host "`nLa imagen original ($Script:WIM_FILE_PATH) sigue montada y sin cambios confirmados." -ForegroundColor Gray
        } else {
            Write-Error "[ERROR] Fallo al capturar la nueva imagen (Codigo: $LASTEXITCODE)."
            Write-Log -LogLevel ERROR -Message "Fallo Save-As NewWim. Codigo: $LASTEXITCODE"
        }
        Pause
        return 
    } 
    else {
        Write-Error "Modo de guardado '$Mode' no valido."
        return
    }

    # Bloque común para Commit/Append
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
    Clear-Host
	Write-Host "--- Convertir VHD/VHDX a WIM ---" -ForegroundColor Yellow
	
	if (-not (Get-Command "Mount-Vhd" -ErrorAction SilentlyContinue)) {
        Write-Error "[ERROR] El cmdlet 'Mount-Vhd' no esta disponible."
        Write-Warning "Necesitas habilitar el modulo de Hyper-V o las herramientas de gestion de discos virtuales."
        Write-Warning "En Windows Pro/Ent: Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V-Management-PowerShell"
        Pause; return
    }

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
                    [System.Windows.Forms.MessageBox]::Show("La imagen está en estado 'NonRepairable'.`nLa secuencia se detendrá.", "Error Fatal", 'OK', 'Error')
                    Pause; return
                }
                elseif ($imageState -eq "Healthy") {
                    # CASO OPTIMO: SALTAR REPARACIÓN
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

    # 3. Compilación
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

    # Aumentamos tamaño del Grid
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

    # --- EVENTO SELECCIÓN (Muestra Metadatos Extendidos) ---
    $cmbIndex.Add_SelectedIndexChanged({
        if ($txtPath.Text) {
            $idx = $cmbIndex.SelectedIndex + 1; $dgv.Rows.Clear()
            try {
                $xml = [System.Xml.Linq.XDocument]::Parse([WimMasterEngine]::GetImageXml($txtPath.Text, $idx))
                $img = $xml.Root
                
                # --- Función Helper Interna ---
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

                # B) Versión
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

                # C) Tamaño (Bytes -> GB)
                $bytesStr = Get-NodeVal $img "TOTALBYTES"
                $sizeDisplay = ""
                if ($bytesStr -match "^\d+$") {
                    $gb = [math]::Round([long]$bytesStr / 1GB, 2)
                    $sizeDisplay = "$gb GB"
                }
                $rowSize = $dgv.Rows.Add("Size", $sizeDisplay)

                # D) Fecha Creación
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

    # 2. Configuración del Formulario
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
                # Buscar Versión (DriverVer = fecha, version)
                if ($line -match "DriverVer\s*=\s*.*?,([0-9\.\s]+)") {
                    $localVersion = $matches[1].Trim()
                }

                # Optimización: Si ya encontramos ambos, salimos del bucle
                if ($classType -ne "Desconocido" -and $localVersion -ne "---") { break }
            }
        } catch {}

        # Lógica de Comparación
        $foundByName = $script:cachedInstalledDrivers | Where-Object { [System.IO.Path]::GetFileName($_.OriginalFileName) -eq $fileObj.Name }
        
        if ($foundByName) {
            $isInstalled = $true; $statusText = "INSTALADO"
        } 
        elseif ($localVersion -ne "---") {
            # Comparar versión exacta + clase
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

    # Resto de lógica
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
                    # Comando de inyección
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
                # Forzamos la relectura de lo que realmente quedó instalado en la imagen
                $dismDrivers = Get-WindowsDriver -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                if ($dismDrivers) { 
                    $script:cachedInstalledDrivers = $dismDrivers 
                    Write-Log -LogLevel INFO -Message "Drivers GUI: Cache actualizada tras instalación."
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
    $lblLegend.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $lblLegend.ForeColor = [System.Drawing.Color]::Silver
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
    $btnRemove.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

    $form.Controls.Add($btnSelectAll)
    $form.Controls.Add($btnSelectNone)
    $form.Controls.Add($btnSelectRec)
    $form.Controls.Add($btnRemove)

    # Lista para guardar referencias a los checkboxes
    $checkBoxList = New-Object System.Collections.Generic.List[System.Windows.Forms.CheckBox]

    # 4. Evento Load (Cargar Apps y aplicar Colores)
    $form.Add_Shown({
        $form.Refresh()
        
        # --- CARGAR CATALOGO EXTERNO ---
        $appsFile = Join-Path $PSScriptRoot "Catalogos\Bloatware.ps1"
        if (-not (Test-Path $appsFile)) { $appsFile = Join-Path $PSScriptRoot "Bloatware.ps1" }
        
        # Listas por defecto (Fallback) por si no existe el archivo
        $safeList = @("Microsoft.WindowsStore", "Microsoft.WindowsCalculator", "Microsoft.Windows.Photos", "Microsoft.SecHealthUI", "Microsoft.UI.Xaml", "Microsoft.VCLibs", "Microsoft.NET.Native")
        $bloatList = @("Microsoft.BingNews", "Microsoft.GetHelp", "Microsoft.Getstarted", "Microsoft.SkypeApp", "Microsoft.MicrosoftSolitaireCollection", "Microsoft.ZuneMusic", "Microsoft.ZuneVideo")

        if (Test-Path $appsFile) {
            try {
                . $appsFile
                if ($script:AppLists) {
                    $safeList = $script:AppLists.Safe
                    $bloatList = $script:AppLists.Bloat
                }
            } catch {
                Write-Log -LogLevel WARN -Message "Error al cargar Apps.ps1. Usando lista minima por defecto."
            }
        }

        # CONVERTIR ARRAYS A REGEX (Unir con pipe | y escapar puntos)
        # Esto transforma la lista legible en lo que el script necesita para comparar
        $safePattern = ($safeList -join "|").Replace(".", "\.")
        $bloatPattern = ($bloatList -join "|").Replace(".", "\.")

        try {
            $apps = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR | Sort-Object DisplayName
            
            $yPos = 10
            foreach ($app in $apps) {
                $chk = New-Object System.Windows.Forms.CheckBox
                $chk.Text = $app.DisplayName
                $chk.Tag = $app.PackageName 
                $chk.Location = New-Object System.Drawing.Point(10, $yPos)
                $chk.Size = New-Object System.Drawing.Size(500, 20)
                $chk.Font = New-Object System.Drawing.Font("Consolas", 10)
                
                # LOGICA DE COLORES (Usando los patrones generados arriba)
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

    # 3. Check preventivo: Si SYSTEM ya está montado, asumimos que todo está listo.
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
        Write-Error "`n[FATAL] $_"
        Write-Log -LogLevel ERROR -Message "Fallo Mount-Hives: $_"
        # Intento de limpieza de emergencia
        Unmount-Hives
        return $false
    }
}

function Unmount-Hives {
    Write-Host "Guardando y descargando Hives..." -ForegroundColor Yellow
    
    # Garbage Collection forzada antes de desmontar para soltar handles
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    Start-Sleep -Seconds 1
    
    # Lista ampliada de Hives a descargar
    $hives = @(
        "HKLM\OfflineSystem", 
        "HKLM\OfflineSoftware", 
        "HKLM\OfflineComponents", # Agregado
        "HKLM\OfflineUser", 
        "HKLM\OfflineUserClasses"
    )
    
    foreach ($hive in $hives) {
        # Solo intentamos descargar si la clave existe en el registro
        if (Test-Path "Registry::$hive") {
            $retries = 0; $done = $false
            while ($retries -lt 5 -and -not $done) {
                reg unload $hive 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { 
                    $done = $true 
                } else { 
                    $retries++
                    Write-Host "." -NoNewline -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 500 
                }
            }
            if (-not $done) { 
                Write-Warning "`n [!] No se pudo desmontar $hive. Puede estar en uso."
                Write-Log -LogLevel WARN -Message "Fallo al desmontar $hive"
            }
        }
    }
    Write-Host " [Proceso Finalizado]" -ForegroundColor Green
}

function Translate-OfflinePath {
    param([string]$OnlinePath)
    
    # 1. Limpieza inicial y normalización
    # Quitamos "Registry::" y convertimos abreviaturas a nombres completos para estandarizar
    $cleanPath = $OnlinePath -replace "^Registry::", "" 
    $cleanPath = $cleanPath -replace "^HKLM:", "HKEY_LOCAL_MACHINE"
    $cleanPath = $cleanPath -replace "^HKLM\\", "HKEY_LOCAL_MACHINE\"
    $cleanPath = $cleanPath -replace "^HKCU:", "HKEY_CURRENT_USER"
    $cleanPath = $cleanPath -replace "^HKCU\\", "HKEY_CURRENT_USER\"
    $cleanPath = $cleanPath -replace "^HKCR:", "HKEY_CLASSES_ROOT"
    $cleanPath = $cleanPath -replace "^HKCR\\", "HKEY_CLASSES_ROOT\"
    $cleanPath = $cleanPath.Trim()

    # --- CORRECCION: Mapeo de Clases de Usuario (UsrClass.dat) ---
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
        # Offline suele ser ControlSet001, no CurrentControlSet
        return $newPath -replace "CurrentControlSet", "ControlSet001"
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
    
    # --- CORRECCIÓN: Agregados OfflineComponents y OfflineUserClasses ---
    if ($hiveName -in @("OfflineUser", "OfflineSoftware", "OfflineSystem", "OfflineComponents", "OfflineUserClasses")) {
        $rootHivePath = $hiveName
        
        # DESBLOQUEAR LA RAiZ PRIMERO
        Unlock-Single-Key -SubKeyPath $rootHivePath
    }

    # 4. Ahora intentamos desbloquear el ancestro más cercano de la clave destino
    # (Igual que antes, para casos especificos profundos)
    $finalSubKey = $psPath
    $rootHive = [Microsoft.Win32.Registry]::LocalMachine
    
    while ($true) {
        try {
            # Check rápido de existencia
            $check = $rootHive.OpenSubKey($finalSubKey, [System.Security.AccessControl.RegistryRights]::ReadPermissions)
            if ($check) { $check.Close(); break }
        } catch { break } # Si existe pero está bloqueada, break para desbloquearla
        
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
    
    $cleanPath = $KeyPath -replace "^Registry::", ""
    $subKeyPath = $cleanPath -replace "^(HKEY_LOCAL_MACHINE|HKLM|HKLM:|HKEY_LOCAL_MACHINE:)[:\\]+", ""

    $targetSid = $null
    $isUserHive = $subKeyPath -match "^(OfflineUser|OfflineUserClasses)"

    if ($isUserHive) {
        $targetSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    } else {
        $targetSid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464")
    }

    Enable-Privileges

    try {
        $rootHive = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

        # CASO A: SI ES USUARIO (OfflineUser)
        if ($isUserHive) {
            try {
                # Intentamos abrir DIRECTAMENTE para tomar posesión
                $keyOwner = $rootHive.OpenSubKey($subKeyPath, [System.Security.AccessControl.RegistryRights]::TakeOwnership)
                
                if ($keyOwner) {
                    $aclOnlyOwner = New-Object System.Security.AccessControl.RegistrySecurity
                    $aclOnlyOwner.SetOwner($targetSid)
                    $keyOwner.SetAccessControl($aclOnlyOwner)
                    $keyOwner.Close()
                    
                    # LOG DE ÉXITO (Ahora si deberia verse)
                    Write-Log -LogLevel INFO -Message "Restaurado (Solo Dueno): $subKeyPath"
                } else {
                    # DIAGNÓSTICO: Si entra aqui, la clave existe pero no se pudo abrir ni para TakeOwnership
                    Write-Log -LogLevel WARN -Message "No se pudo abrir para TakeOwnership: $subKeyPath"
                }
            } catch {
                Write-Log -LogLevel ERROR -Message "Excepcion en Caso A (User) en ($subKeyPath): $_"
            }
        }
        # CASO B: SI ES SISTEMA (System/Software)
        else {
            $key = $null
            try {
                $flagsFull = [System.Security.AccessControl.RegistryRights]::TakeOwnership -bor `
                             [System.Security.AccessControl.RegistryRights]::ChangePermissions -bor `
                             [System.Security.AccessControl.RegistryRights]::ReadPermissions
                $key = $rootHive.OpenSubKey($subKeyPath, $flagsFull)
            } catch {}

            if ($key) {
                try {
                    $acl = $key.GetAccessControl()
                    $acl.SetOwner($targetSid)
                    $acl.SetAccessRuleProtection($false, $false) 
                    $key.SetAccessControl($acl)
                    
                    # LOG DE ÉXITO CASO B
                    # Write-Log -LogLevel INFO -Message "Restaurado (Full): $subKeyPath"
                } catch {
                    try {
                        # Fallback silencioso
                        $acl.SetAccessRuleProtection($true, $false)
                        $key.SetAccessControl($acl)
                    } catch {}
                }
                $key.Close()
            }
        }
        
        $rootHive.Close()
    } catch {
        Write-Log -LogLevel ERROR -Message "Error Estructural en Restore-KeyOwner: $_"
    }
}

# --- LA FUNCIÓN DE DESBLOQUEO ---
function Unlock-Single-Key {
    param([string]$SubKeyPath)
    
    # Filtro de seguridad para raices
    if ($SubKeyPath -match "^(OfflineSystem|OfflineSoftware|OfflineUser|OfflineUserClasses|OfflineComponents)$") { return }
    
	Enable-Privileges
    $rootKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)

    # --- VERIFICACIÓN PREVIA ---
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

    # ... (Aqui sigue la lógica de desbloqueo si falló lo anterior) ...
    
    $sidAdmin = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $success = $false

    # INTENTO 1: MÉTODO .NET (Rápido)
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

    # INTENTO 2: MÉTODO REGINI.EXE (Solo si falló .NET y no teniamos acceso previo)
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
                # 1. Classes Root (Global) -> OfflineSoftware\Classes
                if ($keyOffline -match "^HKEY_CLASSES_ROOT" -or $keyOffline -match "^HKCR") {
                     $keyOffline = $keyOffline -replace "^HKEY_CLASSES_ROOT", "HKLM:\OfflineSoftware\Classes"
                     $keyOffline = $keyOffline -replace "^HKCR", "HKLM:\OfflineSoftware\Classes"
                }
                # 2. Clases de Usuario (HKCU\Software\Classes) -> OfflineUserClasses
                # IMPORTANTE: Este elseif captura las clases de usuario antes que el HKCU general
                elseif ($keyOffline -match "HKEY_CURRENT_USER\\Software\\Classes" -or $keyOffline -match "HKCU\\Software\\Classes") {
                     $keyOffline = $keyOffline -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKLM:\OfflineUserClasses"
                     $keyOffline = $keyOffline -replace "HKCU\\Software\\Classes", "HKLM:\OfflineUserClasses"
                }
                # 3. Rutas Estándar (System, Software y resto de Usuario)
                else {
                    $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SOFTWARE", "HKLM:\OfflineSoftware")
                    $keyOffline = $keyOffline.Replace("HKLM\SOFTWARE", "HKLM:\OfflineSoftware")
                    $keyOffline = $keyOffline.Replace("HKEY_LOCAL_MACHINE\SYSTEM", "HKLM:\OfflineSystem")
                    $keyOffline = $keyOffline.Replace("HKLM\SYSTEM", "HKLM:\OfflineSystem")
                    
                    # Al haber filtrado ya las Classes en el paso 2, esto captura solo el resto de NTUSER.DAT
                    $keyOffline = $keyOffline.Replace("HKEY_CURRENT_USER", "HKLM:\OfflineUser")
                    $keyOffline = $keyOffline.Replace("HKCU", "HKLM:\OfflineUser")
                }

                # 4. Limpieza final para asegurar formato de unidad PowerShell
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
                            # Si existe pero es cadena vacia, lo mostramos explicitamente
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
            
            # Vista previa
            $userConfirmed = Show-RegPreview-GUI -FilePath $file
            
            if ($userConfirmed) {
                try {
                    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
                    $lblStatus.Text = "Aplicando parches de seguridad..."
                    $form.Refresh()

                    $content = Get-Content -Path $file -Raw
                    
                    # --- A. TRADUCCIÓN DE RUTAS ---
                    # 1. HKLM (Software y System)
                    $newContent = $content -replace "HKEY_LOCAL_MACHINE\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware"
                    $newContent = $newContent -replace "HKLM\\SOFTWARE", "HKEY_LOCAL_MACHINE\OfflineSoftware"
                    $newContent = $newContent -replace "HKEY_LOCAL_MACHINE\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem"
                    $newContent = $newContent -replace "HKLM\\SYSTEM", "HKEY_LOCAL_MACHINE\OfflineSystem"

                    # 2. Clases de Usuario (CRiTICO: ANTES de HKCU General)
                    # Redirige HKCU\Software\Classes -> OfflineUserClasses (UsrClass.dat)
                    $newContent = $newContent -replace "HKEY_CURRENT_USER\\Software\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses"
                    $newContent = $newContent -replace "HKCU\\Software\\Classes", "HKEY_LOCAL_MACHINE\OfflineUserClasses"

                    # 3. Usuario General (El resto de HKCU -> OfflineUser / NTUSER.DAT)
                    $newContent = $newContent -replace "HKEY_CURRENT_USER", "HKEY_LOCAL_MACHINE\OfflineUser"
                    $newContent = $newContent -replace "HKCU", "HKEY_LOCAL_MACHINE\OfflineUser"
                    
                    # 4. Classes Root (Global) -> OfflineSoftware\Classes
                    $newContent = $newContent -replace "HKEY_CLASSES_ROOT", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"
                    $newContent = $newContent -replace "HKCR", "HKEY_LOCAL_MACHINE\OfflineSoftware\Classes"

                    # --- B. DESBLOQUEO INTELIGENTE (Recursivo) ---
                    $lines = $newContent -split "`r`n"
                    foreach ($line in $lines) {
                        # Captura rutas de claves en el archivo .REG
                        if ($line -match "^\[HKEY_LOCAL_MACHINE\\(OfflineSoftware|OfflineSystem|OfflineUser)(.*)\]") {
                            $targetKey = $line.Trim().TrimStart('[').TrimEnd(']')
                            if ($targetKey.StartsWith("-")) { $targetKey = $targetKey.Substring(1) }
                            
                            # La nueva función se encargará de buscar el padre si la clave no existe
                            Unlock-OfflineKey -KeyPath $targetKey
                        }
                    }

                    # --- C. EJECUCIÓN ---
                    $tempReg = Join-Path $env:TEMP "gui_import_offline.reg"
                    $newContent | Set-Content -Path $tempReg -Encoding Unicode -Force

                    $pInfo = New-Object System.Diagnostics.ProcessStartInfo
                    $pInfo.FileName = "reg.exe"
                    $pInfo.Arguments = "import `"$tempReg`""
                    $pInfo.UseShellExecute = $false
                    $pInfo.CreateNoWindow = $true
                    $pInfo.RedirectStandardError = $true
                    $pInfo.RedirectStandardOutput = $true
                    
                    $process = [System.Diagnostics.Process]::Start($pInfo)
                    $process.WaitForExit()
                    $exitCode = $process.ExitCode

					# RESTAURACION: "LIMPIAR LA ESCENA DEL CRIMEN"
                    if ($exitCode -eq 0) {
                        $lblStatus.Text = "Restaurando permisos de seguridad (TrustedInstaller)..."
                        $form.Refresh()

                        # Reutilizamos el contenido ya traducido ($newContent) para saber qué claves se tocaron
                        $linesToRestore = $newContent -split "`r`n"
                        
                        foreach ($line in $linesToRestore) {
                            # Buscacmos las mismas claves que desbloqueamos antes
                            if ($line -match "^\[HKEY_LOCAL_MACHINE\\(OfflineSoftware|OfflineSystem|OfflineUser)(.*)\]") {
                                $targetKey = $line.Trim().TrimStart('[').TrimEnd(']')
                                
                                # Si es una clave de borrado (empieza con -), no hay nada que restaurar porque ya no existe
                                if (-not $targetKey.StartsWith("-")) {
                                    # Restaurar propietario
                                    Restore-KeyOwner -KeyPath $targetKey
                                }
                            }
                        }
                    }

                    $form.Cursor = [System.Windows.Forms.Cursors]::Default

                    if ($exitCode -eq 0 -or $exitCode -eq 1) {
                        [System.Windows.Forms.MessageBox]::Show("Importacion exitosa.", "Listo", 'OK', 'Information')
                    } else {
                        $stdErr = $process.StandardError.ReadToEnd()
                        [System.Windows.Forms.MessageBox]::Show("El proceso reporto un codigo $exitCode, pero se aplicaron los permisos.`nVerifica si los cambios aparecen.`n`nError tecnico: $stdErr", "Aviso de Importacion", 'OK', 'Warning')
                    }
                    
                    Remove-Item $tempReg -Force -ErrorAction SilentlyContinue

                } catch {
                    $form.Cursor = [System.Windows.Forms.Cursors]::Default
                    [System.Windows.Forms.MessageBox]::Show("Error critico: $_", "Error", 'OK', 'Error')
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

function Check-And-Repair-Mounts {
    Write-Host "Verificando consistencia del entorno WIM..." -ForegroundColor DarkGray
    
    # 1. Obtener información de DISM
    $dismInfo = dism /Get-MountedImageInfo 2>$null
    
    # 2. Detectar si nuestra carpeta de montaje está en estado "Needs Remount" o "Invalid"
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
        
        # MENSAJE ESTILO DISM++ (Reparar sesión existente)
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
                Write-Error "Fallo la recuperacion (Codigo: $LASTEXITCODE)."
                [System.Windows.Forms.MessageBox]::Show("No se pudo recuperar la sesion. Se recomienda limpiar.", "Error", 'OK', 'Error')
            }
        }
        elseif ($msgResult -eq 'No') {
            # Opción Nuclear (Lo que tenias antes)
            Write-Host ">>> LIMPIANDO PUNTO DE MONTAJE (Cleanup-Wim)..." -ForegroundColor Red
            Unmount-Hives # Asegurar que el registro no estorbe
            dism /Cleanup-Wim
            $Script:IMAGE_MOUNTED = 0
            [System.Windows.Forms.MessageBox]::Show("Limpieza completada. Debes montar la imagen de nuevo.", "Limpieza", 'OK', 'Information')
        }
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
            "2" { if ($Script:IMAGE_MOUNTED) { Cambio-Edicion-Menu } else { Write-Warning "Monta una imagen primero."; Pause } }
            "3" { Drivers-Menu }
            "4" { if ($Script:IMAGE_MOUNTED) { Show-Bloatware-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "5" { if ($Script:IMAGE_MOUNTED) { Show-Services-Offline-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
            "6" { if ($Script:IMAGE_MOUNTED) { Show-Tweaks-Offline-GUI } else { Write-Warning "Monta una imagen primero."; Pause } }
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
		
        if ($Script:IMAGE_MOUNTED -eq 1) {
            # Write-Host "Saneando estado del Registro (Hives)..." -ForegroundColor DarkGray
            Unmount-Hives
			[GC]::Collect()
        }
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

Check-And-Repair-Mounts

# =============================================
#  Punto de Entrada: Iniciar el Menu Principal
# =============================================
Main-Menu
