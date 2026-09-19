# =================================================================
#  Modulo-Montaje
#
#  CONTENIDO   : Select-WindowsMediaSource, Mount-Image, 
#                Unmount-Image, Reload-Image
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - Select-PathDialog      : ui para seleccion de rutas
#    - Get-UnusedDriveLetter  : deteccion de unidades libres para VHD
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Read-MenuOption        : lectura de opcion de menu (V = Volver instantaneo)
#  CARGA       : . "$PSScriptRoot\Modulo-Montaje.ps1"
#
#  NO modificar las firmas de funcion; el nucleo las invoca por nombre.
#
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

# =============================================
#  FUNCIONES DE ACCION (Montaje/Desmontaje)
# =============================================
# Consultas DISM: conservar por separado el texto y el codigo de salida.
# /English hace que el analisis no dependa del idioma del Windows anfitrion.
function Invoke-AIOMountDismQuery {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    $lines = @(& dism.exe @Arguments /English 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { throw 'No se pudo ejecutar dism.exe.' }
    [pscustomobject]@{ ExitCode = [int]$exitCode; Lines = $lines }
}

function ConvertTo-AIOMountPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $value = $Path.Trim()
    if ($value.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) {
        $value = '\\' + $value.Substring(8)
    } elseif ($value.StartsWith('\\?\')) {
        $value = $value.Substring(4)
    }
    return [IO.Path]::GetFullPath($value).Replace('/', '\').TrimEnd('\')
}

function ConvertFrom-AIOMountedImageInfo {
    param([AllowEmptyCollection()][string[]]$Lines)
    $entry = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*Mount Dir\s*:\s*(.+?)\s*$') {
            if ($null -ne $entry) { [pscustomobject]$entry }
            $entry = [ordered]@{ MountDir = $matches[1]; ImageFile = ''; ImageIndex = 0; ReadWrite = ''; Status = '' }
        } elseif ($null -ne $entry) {
            if ($line -match '^\s*Image File\s*:\s*(.+?)\s*$') { $entry.ImageFile = $matches[1] }
            elseif ($line -match '^\s*Image Index\s*:\s*(\d+)\s*$') { $entry.ImageIndex = [int]$matches[1] }
            elseif ($line -match '^\s*Mounted Read/Write\s*:\s*(.+?)\s*$') { $entry.ReadWrite = $matches[1] }
            elseif ($line -match '^\s*Status\s*:\s*(.+?)\s*$') { $entry.Status = $matches[1] }
        }
    }
    if ($null -ne $entry) { [pscustomobject]$entry }
}

function Get-AIOMountedImages {
    $query = Invoke-AIOMountDismQuery -Arguments @('/Get-MountedImageInfo')
    if ($query.ExitCode -ne 0) {
        throw "No se pudo consultar los montajes de DISM (codigo $($query.ExitCode)).`n$($query.Lines -join [Environment]::NewLine)"
    }
    ConvertFrom-AIOMountedImageInfo -Lines $query.Lines
}

function Get-AIOMountForPath {
    param([AllowEmptyCollection()][object[]]$Mounts, [string]$Path)
    $target = ConvertTo-AIOMountPath -Path $Path
    if (-not $target) { return }
    $found = @($Mounts | Where-Object { (ConvertTo-AIOMountPath -Path $_.MountDir) -eq $target })
    if ($found.Count -gt 1) { throw "DISM devolvio varios registros para '$Path'. Revisa el estado antes de continuar." }
    if ($found.Count -eq 1) { return $found[0] }
}

function Get-AIOWimIndexes {
    param([Parameter(Mandatory = $true)][string]$ImagePath)
    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) { throw "No existe el archivo WIM: $ImagePath" }
    $query = Invoke-AIOMountDismQuery -Arguments @('/Get-WimInfo', "/WimFile:$ImagePath")
    # La lista es salida de pantalla, nunca el valor de retorno del menu.
    $query.Lines | Out-Host
    if ($query.ExitCode -ne 0) { throw "DISM no pudo leer el WIM (codigo $($query.ExitCode)). Revisa el detalle mostrado arriba y dism.log." }
    $indexes = @($query.Lines | ForEach-Object {
        if ($_ -match '^\s*Index\s*:\s*(\d+)\s*$') { [int]$matches[1] }
    } | Sort-Object -Unique)
    if ($indexes.Count -eq 0) { throw 'DISM no devolvio indices del WIM. No se solicitara un indice ni se intentara montar.' }
    return $indexes
}

function Assert-AIOMountDirectoryAvailable {
    param([Parameter(Mandatory = $true)][string]$MountPath)
    $fullPath = [IO.Path]::GetFullPath($MountPath)
    if ((ConvertTo-AIOMountPath $fullPath) -eq (ConvertTo-AIOMountPath ([IO.Path]::GetPathRoot($fullPath)))) {
        throw 'La raiz de una unidad no puede usarse como carpeta de montaje.'
    }
    # Si falla la consulta, no se asume que la carpeta esta libre.
    $mounts = @(Get-AIOMountedImages)
    $registered = Get-AIOMountForPath -Mounts $mounts -Path $fullPath
    if ($null -ne $registered) { throw "La carpeta ya esta registrada en DISM (estado: $($registered.Status)). Recupera o desmonta esa sesion antes de montar otra imagen." }

    if (Test-Path -LiteralPath $fullPath) {
        $directory = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
        if (-not $directory.PSIsContainer -or ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'El punto de montaje debe ser una carpeta real, no un archivo ni un enlace.'
        }
        if ($null -ne (Get-ChildItem -LiteralPath $fullPath -Force -ErrorAction Stop | Select-Object -First 1)) {
            throw "El directorio de montaje no esta vacio: $fullPath. Selecciona una carpeta vacia en Configuracion de Rutas. No se eliminaron archivos."
        }
    } else {
        New-Item -Path $fullPath -ItemType Directory -ErrorAction Stop | Out-Null
    }
}

function ConvertFrom-AIOSkippedMountLog {
    param([AllowEmptyString()][string]$Text)
    $entry = $null
    foreach ($line in ($Text -split '\r?\n')) {
        if ($line -match 'Skipping invalid mounted image at:') {
            $entry = [ordered]@{ MountDir = ''; ImageFile = ''; ImageIndex = 0; ReadWrite = 'Unknown'; Status = 'Invalid'; Origin = 'Log DISM' }
        } elseif ($null -ne $entry) {
            if ($line -match '^\s*MountDir:\s*\[(.*)\]\s*$') { $entry.MountDir = $matches[1] }
            elseif ($line -match '^\s*WimPath:\s*\[(.*)\]\s*$') { $entry.ImageFile = $matches[1] }
            elseif ($line -match '^\s*Index:\s*\[(\d+)\]\s*$') { $entry.ImageIndex = [int]$matches[1] }
            elseif ($line -match '^\s*Mount Flags:') {
                if ($entry.MountDir -and $entry.ImageFile -and $entry.ImageIndex -gt 0) { [pscustomobject]$entry }
                $entry = $null
            } elseif ($line -match '^\d{4}-\d{2}-\d{2}\s') { $entry = $null }
        }
    }
}

function Get-AIOMountSnapshot {
    param([Parameter(Mandatory = $true)][string]$LogPath)
    $query = Invoke-AIOMountDismQuery -Arguments @('/Get-MountedImageInfo', "/LogPath:$LogPath")
    if ($query.ExitCode -ne 0) { throw "Fallo el inventario DISM (codigo $($query.ExitCode)): $($query.Lines -join ' ')" }
    $entries = @(ConvertFrom-AIOMountedImageInfo -Lines $query.Lines)
    $logRead = $false; $logComplete = $false
    if (Test-Path -LiteralPath $LogPath -PathType Leaf) {
        $logText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction Stop
        $logRead = $true
        $skippedEntries = @(ConvertFrom-AIOSkippedMountLog -Text $logText)
        $markers = [regex]::Matches([string]$logText, 'Skipping invalid mounted image at:', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count
        $logComplete = -not [string]::IsNullOrWhiteSpace($logText) -and $markers -eq $skippedEntries.Count
        foreach ($skipped in $skippedEntries) {
            if ($null -eq (Get-AIOMountForPath -Mounts $entries -Path $skipped.MountDir)) { $entries += $skipped }
        }
    }
    [pscustomobject]@{ Mounts = $entries; LogRead = $logRead; LogComplete = $logComplete; LogPath = $LogPath; Output = $query.Lines }
}

function Compare-AIOMountSnapshots {
    param([AllowEmptyCollection()][object[]]$Before, [AllowEmptyCollection()][object[]]$After)
    $gone = @(); $changed = @()
    foreach ($entry in $Before) {
        $current = Get-AIOMountForPath -Mounts $After -Path $entry.MountDir
        $sameImage = $null -ne $current -and $current.ImageIndex -eq $entry.ImageIndex -and
                     (ConvertTo-AIOMountPath $current.ImageFile) -eq (ConvertTo-AIOMountPath $entry.ImageFile)
        if (-not $sameImage) { $gone += $entry }
        if ($entry.Status -in @('OK', 'Needs Remount') -and
            (-not $sameImage -or $current.Status -ne $entry.Status -or $current.ReadWrite -ne $entry.ReadWrite)) {
            $changed += $entry
        }
    }
    [pscustomobject]@{
        NoLongerListed = $gone
        ProtectedChanged = $changed
        Pending = @($After | Where-Object { $_.Status -ne 'OK' })
    }
}

function Repair-InvalidMounts {
    # Elegir [8] autoriza la limpieza global de DISM. No se descartan sesiones.
    $report = [ordered]@{
        StartedUtc = [DateTime]::UtcNow.ToString('o'); FinishedUtc = $null
        Status = 'NoEjecutada'; CleanupExitCode = $null; Error = $null
        Before = @(); After = @(); Comparison = $null; BeforeLogRead = $false; AfterLogRead = $false; BeforeLogComplete = $false; AfterLogComplete = $false
    }
    $reportDir = $null
    try {
        $root = if ($script:logDir) { $script:logDir } else { Join-Path (Split-Path -Parent $PSScriptRoot) 'Logs' }
        $reportDir = Join-Path $root ('Montajes_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N'))
        New-Item -Path $reportDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Write-Host "`n[1/3] Consultando montajes y avisos de DISM..." -ForegroundColor Yellow
        $before = Get-AIOMountSnapshot -LogPath (Join-Path $reportDir 'Antes.log')
        $report.Before = @($before.Mounts); $report.BeforeLogRead = $before.LogRead; $report.BeforeLogComplete = $before.LogComplete
        $before.Mounts | Format-Table MountDir, ImageFile, ImageIndex, Status -AutoSize | Out-Host
        if (-not $before.LogComplete) { Write-Warning 'El log no se pudo comprobar por completo; puede haber montajes omitidos del inventario.' }

        Write-Host '[2/3] Limpiando recursos corruptos no recuperables del equipo...' -ForegroundColor Yellow
        Write-Host 'DISM conserva montajes validos y recuperables. No se ejecuta Discard.' -ForegroundColor Gray
        Write-Log -LogLevel ACTION -Message "MountRepair: Cleanup-Mountpoints. Diagnostico: $reportDir"
        $global:LASTEXITCODE = $null
        $PSNativeCommandUseErrorActionPreference = $false
        $cleanupOutput = New-Object 'System.Collections.Generic.List[string]'
        & dism.exe /Cleanup-Mountpoints /English "/LogPath:$(Join-Path $reportDir 'Limpieza.log')" 2>&1 | ForEach-Object {
            $line = $_.ToString(); [void]$cleanupOutput.Add($line); Write-Host $line
        }
        $report.CleanupExitCode = $global:LASTEXITCODE
        $cleanupOutput | Set-Content -LiteralPath (Join-Path $reportDir 'Salida_Limpieza.txt') -Encoding UTF8 -ErrorAction Stop
        if ($null -eq $report.CleanupExitCode) { throw 'No se pudo ejecutar dism.exe. No se dispone de un codigo de salida.' }
        if ($report.CleanupExitCode -ne 0) { throw "La limpieza fallo (codigo $($report.CleanupExitCode)). Se conserva el estado de la sesion." }

        Write-Host '[3/3] Verificando el resultado...' -ForegroundColor Yellow
        $report.Status = 'VerificacionPendiente'
        $after = Get-AIOMountSnapshot -LogPath (Join-Path $reportDir 'Despues.log')
        $report.After = @($after.Mounts); $report.AfterLogRead = $after.LogRead; $report.AfterLogComplete = $after.LogComplete
        $comparison = Compare-AIOMountSnapshots -Before $before.Mounts -After $after.Mounts
        $report.Comparison = $comparison
        $current = Get-AIOMountForPath -Mounts $after.Mounts -Path $Script:MOUNT_DIR
        $oldCurrent = Get-AIOMountForPath -Mounts $before.Mounts -Path $Script:MOUNT_DIR
        $selectedChanged = @($comparison.ProtectedChanged | Where-Object {
            (ConvertTo-AIOMountPath $_.MountDir) -eq (ConvertTo-AIOMountPath $Script:MOUNT_DIR)
        }).Count -gt 0
        if ($Script:IMAGE_MOUNTED -eq 1 -and $selectedChanged) {
            # Conservar archivo/indice para diagnostico, pero bloquear nuevas ediciones
            # sobre una sesion que desaparecio o fue sustituida por otro proceso.
            $Script:IMAGE_MOUNTED = 0; $Script:CachedControlSet = $null
            $Script:AIODashboardCache = $null; $Script:ForceMenuRefresh = $false
            Write-Warning 'La sesion seleccionada cambio durante la limpieza. Se deshabilito su edicion; se conservan la ruta y el indice para revisarlos.'
        } elseif ($Script:IMAGE_MOUNTED -eq 1 -and $null -eq $current -and $after.LogComplete -and
            ($null -eq $oldCurrent -or $oldCurrent.Status -eq 'Invalid')) {
            $Script:IMAGE_MOUNTED = 0; $Script:WIM_FILE_PATH = $null; $Script:MOUNTED_INDEX = $null
            $Script:CachedControlSet = $null
            $Script:AIODashboardCache = $null; $Script:ForceMenuRefresh = $false
        }
        $report.Status = 'Completada'
        if ($comparison.Pending.Count -gt 0 -or $comparison.ProtectedChanged.Count -gt 0 -or -not $before.LogComplete -or -not $after.LogComplete) {
            $report.Status = 'RequiereRevision'
            Write-Warning 'DISM termino, pero quedan registros pendientes, cambios en montajes protegidos o una verificacion parcial. Revisa el informe.'
        } else {
            Write-Host '[OK] Limpieza completada; inventario y log comprobados.' -ForegroundColor Green
        }
        Write-Host ("Registros anteriores que ya no aparecen: {0}. Pendientes: {1}." -f $comparison.NoLongerListed.Count, $comparison.Pending.Count)
        if ($comparison.ProtectedChanged.Count -gt 0) {
            Write-Warning 'Un montaje valido o recuperable cambio durante la operacion. Puede haber actividad de otro proceso; su ausencia no se presenta como una limpieza correcta.'
        }
        $after.Mounts | Format-Table MountDir, ImageFile, ImageIndex, ReadWrite, Status -AutoSize | Out-Host
        foreach ($pending in $comparison.Pending) {
            if ($pending.Status -eq 'Needs Remount') {
                Write-Host ("Recuperable: {0}. Requiere Remount-Image sobre esa ruta." -f $pending.MountDir) -ForegroundColor Yellow
            } else {
                Write-Host ("Pendiente: {0} ({1}). Consulta Despues.log." -f $pending.MountDir, $pending.Status) -ForegroundColor Yellow
            }
        }
    } catch {
        $report.Error = $_.Exception.Message
        if ($report.Status -ne 'VerificacionPendiente') { $report.Status = 'Fallida' }
        Write-Warning $report.Error
        Write-Log -LogLevel ERROR -Message "MountRepair: $($report.Status): $($report.Error)"
    } finally {
        $report.FinishedUtc = [DateTime]::UtcNow.ToString('o')
        if ($reportDir) {
            try {
                $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $reportDir 'Informe.json') -Encoding UTF8 -ErrorAction Stop
                Write-Host "Diagnostico guardado en: $reportDir" -ForegroundColor Gray
                Write-Log -LogLevel INFO -Message "MountRepair: Resultado $($report.Status). Informe: $reportDir"
            } catch { Write-Warning "No se pudo guardar el informe: $($_.Exception.Message)" }
        }
    }
}


function Select-WindowsMediaSource {
	param(
        [string]$ExtractDir = ""
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

        if ([string]::IsNullOrWhiteSpace($ExtractDir)) {
            $ExtractDir = Join-Path $parentDir "ISO_Extract"
            Write-Host "`nCarpeta de extraccion por defecto: " -NoNewline; Write-Host $ExtractDir -ForegroundColor Cyan
            
            if ((Read-Host "Deseas elegir una carpeta destino diferente para la extraccion? (S/N)").ToUpper() -eq 'S') {
                $customExtract = Select-PathDialog -DialogType Folder -Title "Selecciona la carpeta destino para extraer la ISO"
                if ($customExtract) { 
                    $ExtractDir = $customExtract 
                    Write-Host "Nueva ruta establecida: $ExtractDir" -ForegroundColor Green
                    Write-Log -LogLevel INFO -Message "SourceSelector: El usuario cambio la ruta de extraccion a -> $ExtractDir"
                } else {
                    Write-Host "Manteneniendo ruta por defecto: $ExtractDir" -ForegroundColor Gray
                }
            }
        }

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

    if ($Script:IMAGE_MOUNTED -gt 0) {
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
    
    $sourceType = Read-MenuOption "Elige una opcion"

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
                    
                    # --- CORRECCIÓN: Active Polling (Max 5 segundos) ---
                    $timeout = 50
                    while (-not (Test-Path -LiteralPath "$($freeLet):\") -and $timeout -gt 0) {
                        Start-Sleep -Milliseconds 100
                        $timeout--
                    }
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
            $Script:ForceMenuRefresh = $true
            
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
    if ($extension -ne '.WIM') {
        Write-Warning 'Selecciona un archivo .wim, .vhd o .vhdx. Convierte un .esd a WIM antes de montarlo.'
        Pause; return
    }
    Write-Host "`n[+] Leyendo estructura del WIM..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "MountManager: Consultando indices de '$Script:WIM_FILE_PATH'."
    try {
        $availableIndexes = @(Get-AIOWimIndexes -ImagePath $Script:WIM_FILE_PATH)
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel ERROR -Message "MountManager: No se puede seleccionar un indice: $($_.Exception.Message)"
        Pause; return
    }

    while ($true) {
        $selection = (Read-Host "`nNumero de indice a montar (V = Volver)").Trim()
        if ($selection -eq 'V') { return }
        $INDEX = 0
        if ([int]::TryParse($selection, [ref]$INDEX) -and $INDEX -gt 0 -and $INDEX -in $availableIndexes) { break }
        Write-Warning "Indice no valido. Elige uno de los indices mostrados: $($availableIndexes -join ', ')."
    }
    Write-Log -LogLevel INFO -Message "MountManager: Indice validado -> [$INDEX]"

    try {
        Assert-AIOMountDirectoryAvailable -MountPath $Script:MOUNT_DIR
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel WARN -Message "MountManager: Montaje cancelado: $($_.Exception.Message)"
        Pause; return
    }

    Write-Host "[+] Montando (Indice: $INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando DISM /Mount-Wim para adjuntar indice $INDEX en $Script:MOUNT_DIR."
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        $Script:CachedControlSet = $null
        $Script:ForceMenuRefresh = $true
        Write-Host "[OK] Imagen montada." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "MountManager: Montaje WIM completado exitosamente. Entorno listo para personalizacion."
    } else {
        Write-Host "[ERROR] Fallo montaje (Code: $LASTEXITCODE)."
        # DISM puede devolver HRESULT con signo; el cast directo a uint32 lanza otra excepcion.
        $exitCodeHex = ([int64]$LASTEXITCODE -band 0xFFFFFFFFL).ToString("X8")
        if ($exitCodeHex -match "C1420116|C1420117") {
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
            $Script:AIODashboardCache = $null
            $Script:ForceMenuRefresh = $false
            Load-Config
			$Script:CachedControlSet = $null
			$Script:OfflineUserClassesPresent = $null
			
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
        $Script:OfflineUserClassesPresent = $null
        $Script:AIODashboardCache = $null
        $Script:ForceMenuRefresh = $false

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

    # La sesion anterior ya termino, aunque el nuevo montaje use la misma ruta.
    $Script:AIODashboardCache = $null
    $Script:ForceMenuRefresh = $false

    Write-Host "[+] Remontando imagen..." -ForegroundColor Yellow
    Write-Log -LogLevel INFO -Message "ImageReloader: Imagen desmontada. Ejecutando DISM /Mount-Wim para restaurar el estado original."
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        Write-Host "[OK] Imagen recargada exitosamente." -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "ImageReloader: Recarga completada exitosamente. El entorno esta listo para seguir trabajando."
        $Script:IMAGE_MOUNTED = 1
		$Script:CachedControlSet = $null
        $Script:ForceMenuRefresh = $true
    } else {
        Write-Host "[ERROR] Error al remontar la imagen."
        Write-Log -LogLevel ERROR -Message "ImageReloader: Fallo critico al remontar la imagen. El entorno ha quedado desmontado. LASTEXITCODE: $LASTEXITCODE"
        $Script:IMAGE_MOUNTED = 0
    }
    Pause
}
