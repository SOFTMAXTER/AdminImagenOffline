<#
.SYNOPSIS
    Administra imágenes de Windows (.wim, .esd) sin conexión.
.DESCRIPTION
    Permite montar, desmontar, guardar cambios, editar índices, convertir formatos (ESD/VHD a WIM),
    cambiar ediciones de Windows y realizar tareas de limpieza y reparación en imágenes offline.
    Utiliza DISM y otras herramientas del sistema. Requiere ejecución como Administrador.
.AUTHOR
    SOFTMAXTER
.VERSION
    1.3.0
#>

# =================================================================
#  Version del Script
# =================================================================
$script:Version = "1.3.0"

# =================================================================
#  Modulo de Auto-Actualizacion (Definicion)
# =================================================================
function Invoke-FullRepoUpdater {
    # --- CONFIGURACION ---
    $repoUser = "SOFTMAXTER"; $repoName = "AdminImagenOffline"; $repoBranch = "main"
    $versionUrl = "https://raw.githubusercontent.com/$repoUser/$repoName/$repoBranch/version.txt"
    $zipUrl = "https://github.com/$repoUser/$repoName/archive/refs/heads/$repoBranch.zip"

    try {
        # Se intenta la operacion de red con un timeout corto
        $remoteVersionStr = (Invoke-WebRequest -Uri $versionUrl -UseBasicParsing -Headers @{"Cache-Control"="no-cache"} -TimeoutSec 5).Content.Trim()

        if ([System.Version]$remoteVersionStr -gt [System.Version]$script:Version) {
            # Solo si se encuentra una actualizacion, se le notifica al usuario.
            Write-Host "¡Nueva version encontrada! Local: v$($script:Version) | Remota: v$remoteVersionStr" -ForegroundColor Green
            $confirmation = Read-Host "¿Deseas descargar e instalar la actualizacion ahora? (S/N)"
            if ($confirmation.ToUpper() -eq 'S') {
                Write-Warning "El actualizador se ejecutara en una nueva ventana. NO LA CIERRES."
                $tempDir = Join-Path $env:TEMP "AdminUpdater_ImgOffline" # Usar un nombre temporal distinto
                if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
                New-Item -Path $tempDir -ItemType Directory | Out-Null
                $updaterScriptPath = Join-Path $tempDir "updater_img.ps1"
                # Asumimos que este script puede estar en /bin y Run.bat en el padre
                $installPath = $PSScriptRoot # Si está en /bin, necesitaría Split-Path -Parent
                $batchPath = Join-Path (Split-Path -Parent $installPath) "Run.bat" # Asumiendo Run.bat en el padre

                # --- El script interno ahora acepta un parámetro y tiene 6 pasos ---
                $updaterScriptContent = @"
param(`$parentPID) # Recibe el ID del proceso principal

`$ErrorActionPreference = 'Stop'
`$Host.UI.RawUI.WindowTitle = 'PROCESO DE ACTUALIZACION (AdminImagenOffline) - NO CERRAR'
try {
    `$tempDir_updater = "$tempDir"
    `$tempZip_updater = Join-Path "`$tempDir_updater" "update.zip"
    `$tempExtract_updater = Join-Path "`$tempDir_updater" "extracted"

    Write-Host "[PASO 1/6] Descargando la nueva version..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri "$zipUrl" -OutFile "`$tempZip_updater"

    Write-Host "[PASO 2/6] Descomprimiendo archivos..." -ForegroundColor Yellow
    Expand-Archive -Path "`$tempZip_updater" -DestinationPath "`$tempExtract_updater" -Force
    `$updateSourcePath = (Get-ChildItem -Path "`$tempExtract_updater" -Directory).FullName

    Write-Host "[PASO 3/6] Esperando a que el proceso principal finalice..." -ForegroundColor Yellow
    try {
        # Espera a que el PID que le pasamos termine antes de continuar
        Get-Process -Id `$parentPID -ErrorAction Stop | Wait-Process -ErrorAction Stop
    } catch {
        # Si el proceso ya cerro (fue muy rapido), no es un error.
        Write-Host "    - El proceso principal ya ha finalizado." -ForegroundColor Gray
    }

    Write-Host "[PASO 4/6] Eliminando archivos antiguos..." -ForegroundColor Yellow
    `$itemsToRemove = Get-ChildItem -Path "$installPath" -Exclude "Logs" # Ejemplo
    if (`$null -ne `$itemsToRemove) { Remove-Item -Path `$itemsToRemove.FullName -Recurse -Force }

    Write-Host "[PASO 5/6] Instalando nuevos archivos..." -ForegroundColor Yellow
    Move-Item -Path "`$updateSourcePath\bin\*" -Destination "$installPath" -Force # Asumiendo que el script está en /bin
    Get-ChildItem -Path "$installPath" -Recurse | Unblock-File

    Write-Host "[PASO 6/6] ¡Actualizacion completada! Reiniciando en 5 segundos..." -ForegroundColor Green
    Start-Sleep -Seconds 5

    Remove-Item -Path "`$tempDir_updater" -Recurse -Force
    # Podría necesitar ajustar cómo se relanza si no usa Run.bat
    if (Test-Path "$batchPath") { Start-Process -FilePath "$batchPath" } else { Write-Warning "No se encontro Run.bat para reiniciar." }
}
catch {
    Write-Error "¡LA ACTUALIZACION HA FALLADO!"
    Write-Error `$_
    Read-Host "El proceso ha fallado. Presiona Enter para cerrar esta ventana."
}
"@
                Set-Content -Path $updaterScriptPath -Value $updaterScriptContent -Encoding utf8

                # --- Se pasa el $PID actual como argumento al nuevo proceso ---
                $launchArgs = "/c start `"PROCESO DE ACTUALIZACION`" powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$updaterScriptPath`" -parentPID $PID"

                Start-Process cmd.exe -ArgumentList $launchArgs -WindowStyle Hidden
                exit # El script principal se cierra inmediatamente
            } else {
                Write-Host "Actualizacion omitida por el usuario." -ForegroundColor Yellow; Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        # Silencioso si no hay conexion (Timeout) o da error, no es un error crítico.
        Write-Host "No se pudo verificar la version remota. Continuando offline." -ForegroundColor Gray
        Start-Sleep -Seconds 1
        return
    }
}

# =================================================================
#  EJECUCION del Auto-Actualizador
# =================================================================
# Se ejecuta temprano para actualizar antes de cargar el resto.
Invoke-FullRepoUpdater

# =================================================================
#  Funciones Utilitarias (Log y Formato)
# =================================================================

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$LogLevel,

        [Parameter(Mandatory=$true)]
        [string]$Message
    )

    if (-not $script:logFile) { return } # Salir si el log no se pudo inicializar

    try {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "[$timestamp] [$LogLevel] - $Message" | Out-File -FilePath $script:logFile -Append -Encoding utf8
    }
    catch {
        # Evitar bucle infinito si falla la escritura del log
        Write-Warning "No se pudo escribir en el archivo de log: $_"
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
# --- Rutas de Log (Definidas aquí para usar Write-Log inmediatamente) ---
try {
    # Si $PSScriptRoot es null (ejecutando seleccion en ISE), usar directorio actual como fallback
    $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { $PWD.Path }
    # Determinar directorio padre (asumiendo que puede estar en /bin o no)
    $parentDir = if ((Split-Path $scriptRoot -Leaf) -eq 'bin') { Split-Path -Parent $scriptRoot } else { $scriptRoot }
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
$Script:WIM_FILE_PATH = $null
$Script:MOUNT_DIR = "C:\TEMP"
# ERROR PRESERVADO: Este directorio no se crea en ningún momento
$Script:Scratch_DIR = "C:\TEMP1"
$Script:IMAGE_MOUNTED = 0
$Script:MOUNTED_INDEX = $null

# =================================================================
#  Módulos de Diálogo GUI
# =================================================================

# --- Función para ABRIR archivos o carpetas ---
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

# --- Función para GUARDAR archivos ---
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
        Write-Warning "Operación cancelada."
        Pause
        return
    }
    $Script:WIM_FILE_PATH = $path

    Write-Host "[+] Obteniendo informacion del WIM..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"

    $INDEX = Read-Host "`nIngrese el numero de indice a montar"
    # Validar que INDEX sea un numero podría añadirse aquí

    if (-not (Test-Path -Path $Script:MOUNT_DIR)) {
        Write-Host "[+] Creando directorio de montaje: $Script:MOUNT_DIR" -ForegroundColor Gray
        try {
            New-Item -Path $Script:MOUNT_DIR -ItemType Directory -Force | Out-Null
        } catch {
            Write-Error "No se pudo crear el directorio '$Script:MOUNT_DIR'. Error: $($_.Exception.Message)"
            Write-Log -LogLevel ERROR -Message "Fallo al crear MOUNT_DIR '$Script:MOUNT_DIR': $($_.Exception.Message)"
            Pause
            return
        }
    }

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

    Write-Host "Ruta del WIM: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    Write-Host "Indice Montado: $Script:MOUNTED_INDEX" -ForegroundColor Gray
    $CONFIRM = Read-Host "`nVa a recargar la imagen descartando todos los cambios no guardados. ¿Desea continuar? (S/N)"

    if ($CONFIRM -notmatch '^(s|S)$') { Write-Warning "Operacion cancelada."; Pause; return }

    Write-Host "[+] Desmontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "Recargando imagen: Desmontando '$Script:WIM_FILE_PATH' (Indice: $Script:MOUNTED_INDEX)..."
    dism /unmount-wim /mountdir:"$Script:MOUNT_DIR%" /discard | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Error "[ERROR] Error al intentar desmontar. Ejecutando 'dism /cleanup-wim'..."
        Write-Log -LogLevel ERROR -Message "Fallo el desmontaje en recarga. Ejecutando cleanup-wim."
        dism /cleanup-wim
        Write-Host "Limpieza completada. Reintentando en 5 segundos..."
        Start-Sleep -Seconds 5
        Reload-Image # Recursión para reintentar
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
#  FUNCIONES DE ACCION (Edición de Índices)
# =============================================

function Export-Index {
    Clear-Host
    if (-not $Script:WIM_FILE_PATH) {
        $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo WIM de origen" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path)
		{
			Write-Warning "Operación cancelada."
			Pause
			return
		}
        $Script:WIM_FILE_PATH = $path
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    $INDEX_TO_EXPORT = Read-Host "`nIngrese el numero de Indice que desea exportar"
    # Validar que INDEX_TO_EXPORT sea un numero valido podría añadirse aquí

    $wimFileObject = Get-Item -Path $Script:WIM_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $wimFileObject.DirectoryName "$($wimFileObject.BaseName)_indice_$($INDEX_TO_EXPORT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Exportar índice como..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operación cancelada."; Pause; return }

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
        $path = Select-PathDialog -DialogType File -Title "Seleccione WIM para borrar índice" -Filter "Archivos WIM (*.wim)|*.wim|Todos (*.*)|*.*"
        if (-not $path) { Write-Warning "Operación cancelada."; Pause; return }
        $Script:WIM_FILE_PATH = $path
    }

    Write-Host "Archivo WIM actual: $Script:WIM_FILE_PATH" -ForegroundColor Gray
    dism /get-wiminfo /wimfile:"$Script:WIM_FILE_PATH"
    $INDEX_TO_DELETE = Read-Host "`nIngrese el número de Indice que desea eliminar"
    # Validar que INDEX_TO_DELETE sea un numero valido podría añadirse aquí

    $CONFIRM = Read-Host "Está seguro que desea eliminar el Indice $INDEX_TO_DELETE de forma PERMANENTE? (S/N)"

    if ($CONFIRM -match '^(s|S)$') {
        Write-Host "[+] Eliminando Indice $INDEX_TO_DELETE..." -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "Eliminando Indice $INDEX_TO_DELETE de '$($Script:WIM_FILE_PATH)'."
        dism /delete-image /imagefile:"$Script:WIM_FILE_PATH" /index:$INDEX_TO_DELETE
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[OK] Indice eliminado exitosamente." -ForegroundColor Green
        } else {
            Write-Error "[ERROR] Error al eliminar el Indice (Codigo: $LASTEXITCODE). Puede que esté montado o en uso."
            Write-Log -LogLevel ERROR -Message "Fallo la eliminacion del indice. Codigo: $LASTEXITCODE"
        }
    } else {
        Write-Warning "Operación cancelada."
    }
    Pause
}

# =============================================
#  FUNCIONES DE ACCION (Conversión de Imagen)
# =============================================

function Convert-ESD {
    Clear-Host; Write-Host "--- Convertir ESD a WIM ---" -ForegroundColor Yellow

    $path = Select-PathDialog -DialogType File -Title "Seleccione el archivo ESD a convertir" -Filter "Archivos ESD (*.esd)|*.esd|Todos (*.*)|*.*"
    if (-not $path) { Write-Warning "Operación cancelada."; Pause; return }
    $ESD_FILE_PATH = $path

    Write-Host "[+] Obteniendo informacion de los indices del ESD..." -ForegroundColor Yellow
    dism /get-wiminfo /wimfile:"$ESD_FILE_PATH"
    $INDEX_TO_CONVERT = Read-Host "`nIngrese el numero de indice que desea convertir"
    # Validar INDEX_TO_CONVERT

    $esdFileObject = Get-Item -Path $ESD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $esdFileObject.DirectoryName "$($esdFileObject.BaseName)_indice_$($INDEX_TO_CONVERT).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Convertir ESD a WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operación cancelada."; Pause; return }

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
    if (-not $path) { Write-Warning "Operación cancelada."; Pause; return }
    $VHD_FILE_PATH = $path

    $vhdFileObject = Get-Item -Path $VHD_FILE_PATH
    $DEFAULT_DEST_PATH = Join-Path $vhdFileObject.DirectoryName "$($vhdFileObject.BaseName).wim"

    $DEST_WIM_PATH = Select-SavePathDialog -Title "Capturar VHD como WIM..." -Filter "Archivos WIM (*.wim)|*.wim" -DefaultFileName $DEFAULT_DEST_PATH
    if (-not $DEST_WIM_PATH) { Write-Warning "Operación cancelada."; Pause; return }

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
    Dismount-Vhd -Path $VHD_FILE_PATH 2>$null | Out-Null
    Write-Host "VHD desmontado." -ForegroundColor Gray; Pause
}

# =============================================
#  FUNCIONES DE MENU (Interfaz de Usuario)
# =============================================

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
        Write-Host "       (Desmonta y vuelve a montar. Útil para revertir)" -ForegroundColor Gray
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
        Write-Host "       (Añade un nuevo indice al WIM con los cambios)" -ForegroundColor Gray
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

    # Determinar versión amigable
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

    # Obtener edición actual con DISM
    try {
        $dismEdition = dism /Image:$Script:MOUNT_DIR /Get-CurrentEdition 2>$null
        $currentEditionLine = $dismEdition | Select-String "Current Edition :"
        if ($currentEditionLine) { $CURRENT_EDITION_DETECTED = ($currentEditionLine.Line -split ':', 2)[1].Trim() }
    } catch { Write-Warning "No se pudo obtener la edición actual vía DISM." }

    # Traducir nombre de edición
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

    $targetEditions = @()
    try {
        $dismTargets = dism /Image:$Script:MOUNT_DIR /Get-TargetEditions 2>$null
        $dismTargets | Select-String "Target Edition :" | ForEach-Object {
            $line = ($_.Line -split ':', 2)[1].Trim()
            if ($line) { $targetEditions += $line }
        }
    } catch { Write-Warning "No se pudieron obtener las ediciones de destino." }

    if ($targetEditions.Count -lt 1)
	{
		Write-Warning "No se encontraron ediciones de destino validas."
		Pause
		return
	}

    $displayEditions = @(); $i = 1
    foreach ($edition in $targetEditions) {
        $displayLine = switch -Wildcard ($edition) {
             "Core" { "Home" }
			 "CoreSingleLanguage" { "Home SL" }
			 "ProfessionalCountrySpecific" { "Pro CS" }
             "ProfessionalEducation" { "Pro Edu" }
			 "ProfessionalSingleLanguage" { "Pro SL" }
			 "ProfessionalWorkstation" { "Pro WS" }
             "IoTEnterprise" { "IoT Ent" }
			 "IoTEnterpriseK" { "IoT Ent K" }
			 "IoTEnterpriseS" { "IoT Ent LTSC" }
             "EnterpriseS" { "Ent LTSC" }
			 "ServerRdsh" { "Server Rdsh" }
			 Default { $edition }
        }
        $displayEditions += "   [$i] $displayLine"
        $i++
    }
    $displayEditions | Format-Wide -Column 2

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
                [switch]$IsSequence # Para saber si estamos en la opción '7'
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
                Write-Host "`n[+] Verificando archivos (SFC)..." -ForegroundColor Yellow
                Write-Log -LogLevel ACTION -Message "LIMPIEZA: SFC /Scannow Offline..."
                SFC /scannow /offwindir:($Script:MOUNT_DIR + '\Windows')
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
                 if (-not (Test-Path $Script:Scratch_DIR)) {
                    Write-Warning "El directorio Scratch '$($Script:Scratch_DIR)' no existe. Intentando crear..."
                    try { New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force | Out-Null; Write-Host "[OK] Directorio Scratch creado." -FG Green }
                    catch { Write-Error "Fallo creacion dir Scratch. Limpieza puede fallar."
					Write-Log -LogLevel ERROR -Message "Fallo crear SCRATCH_DIR: $($_.Exception.Message)" }
                }
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

                Write-Host "`n[4/5] Verificando archivos (SFC)..." -FG Yellow; Write-Log -LogLevel ACTION -Message "LIMPIEZA: (4/5) SFC Offline..."
                SFC /scannow /offwindir:($Script:MOUNT_DIR + '\Windows')
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
                     if (-not (Test-Path $Script:Scratch_DIR)) {
                        Write-Warning "El directorio Scratch '$($Script:Scratch_DIR)' no existe. Intentando crear..."
                        try { New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force | Out-Null; Write-Host "[OK] Directorio Scratch creado." -FG Green }
                        catch { Write-Error "Fallo creacion dir Scratch. Limpieza puede fallar."; Write-Log -LogLevel ERROR -Message "Fallo crear SCRATCH_DIR: $($_.Exception.Message)" }
                    }
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

function Main-Menu {
    $Host.UI.RawUI.WindowTitle = "Admin Imagen Offline v$($script:Version) by SOFTMAXTER"
    while ($true) {
        Clear-Host
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "    Administrador de Imagen offline v$($script:Version) by SOFTMAXTER" -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host "  Ruta WIM : $Script:WIM_FILE_PATH" -ForegroundColor Gray
        Write-Host "  Montado  : $($Script:IMAGE_MOUNTED) (Indice: $($Script:MOUNTED_INDEX)) en $($Script:MOUNT_DIR)" -ForegroundColor Gray
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   [1] Gestionar Imagen (Montar/Desmontar/Guardar/Convertir)" -ForegroundColor White
        Write-Host "       (Modulo principal para cargar, guardar y gestionar la imagen)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [2] Cambiar Edicion de Windows" -ForegroundColor White
        Write-Host "       (Cambia entre ediciones Pro, Home, Enterprise, etc.)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [3] Herramientas de Limpieza y Reparacion (Offline)" -ForegroundColor White
        Write-Host "       (Ejecuta DISM y SFC en la imagen montada)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "-------------------------------------------------------"
        Write-Host ""
        Write-Host "   [L] Ver Registro de Actividad (Log)" -ForegroundColor Gray
        Write-Host ""
        Write-Host "   [S] Salir" -ForegroundColor Red
        Write-Host ""
        $opcionM = Read-Host "Selecciona una opcion"
        Write-Log -LogLevel INFO -Message "MENU_MAIN: Usuario selecciono '$opcionM'."
        switch ($opcionM.ToUpper()) {
            "1" { Image-Management-Menu }
            "2" { Cambio-Edicion-Menu }
            "3" { Limpieza-Menu }
            "L" { if (Test-Path $script:logFile)
			{
				Write-Host "`n[+] Abriendo log..." -FG Green
				Start-Process notepad.exe -ArgumentList $script:logFile
				} else {
					Write-Warning "Log no creado aun."
					Read-Host "`nEnter para continuar..."
					}
				}
            "S" {
				Write-Host "Saliendo..."
				Write-Log -LogLevel INFO -Message "Script cerrado."
				Write-Log -LogLevel INFO -Message "================================================="
				exit
			}
            default { Write-Warning "Opcion invalida."; Start-Sleep 1 }
        }
    }
}

# =================================================================
#  Verificación de Montaje Existente (Se ejecuta antes del menú)
# =================================================================
$Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null
$TEMP_DISM_OUT = Join-Path $env:TEMP "dism_check_$($RANDOM).tmp"
Write-Host "Verificando imagenes montadas..." -ForegroundColor Gray
try {
    dism /get-mountedimageinfo 2>$null | Out-File -FilePath $TEMP_DISM_OUT -Encoding utf8
    $mountInfo = Get-Content -Path $TEMP_DISM_OUT -Encoding utf8 -ErrorAction SilentlyContinue
    $mountDirLine = $mountInfo | Select-String -Pattern "Mount Dir :" | Select-Object -First 1
    if ($mountDirLine) {
        Write-Log -LogLevel INFO -Message "Detectada imagen previamente montada."
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNT_DIR = ($mountDirLine.Line -split ':', 2)[1].Trim()
        $wimPathLine = $mountInfo | Select-String -Pattern "Image File :" | Select-Object -First 1
        if ($wimPathLine) {
            $Script:WIM_FILE_PATH = ($wimPathLine.Line -split ':', 2)[1].Trim()
            if ($Script:WIM_FILE_PATH.StartsWith("\\?\")) { $Script:WIM_FILE_PATH = $Script:WIM_FILE_PATH.Substring(4) }
        }
        $indexLine = $mountInfo | Select-String -Pattern "Image Index" | Select-Object -First 1
        if ($indexLine) { $Script:MOUNTED_INDEX = ($indexLine.Line -split ':', 2)[1].Trim() }
        Write-Host "Imagen encontrada: $($Script:WIM_FILE_PATH) (Indice $($Script:MOUNTED_INDEX)) en $($Script:MOUNT_DIR)" -ForegroundColor Yellow
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


# =============================================
#  Punto de Entrada: Iniciar el Menú Principal
# =============================================
Main-Menu
