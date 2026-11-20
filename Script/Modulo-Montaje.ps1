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
# dism.exe nativo del anfitrion. En un proceso de 32 bits sobre Windows de 64 bits,
# System32 se redirige a SysWOW64; Sysnative evita ese redireccionamiento.
function Get-AIOMountNativeDismPath {
    $systemFolder = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) { 'Sysnative' } else { 'System32' }
    if (-not [string]::IsNullOrWhiteSpace($env:SystemRoot)) {
        $exe = Join-Path $env:SystemRoot "$systemFolder\dism.exe"
        if (Test-Path -LiteralPath $exe -PathType Leaf) { return $exe }
    }
    return 'dism.exe'
}

# Consultas DISM: conservar por separado el texto y el codigo de salida.
# /English hace que el analisis no dependa del idioma del Windows anfitrion.
function Invoke-AIOMountDismQuery {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    $dismExe = Get-AIOMountNativeDismPath
    $lines = @(& $dismExe @Arguments /English 2>&1 | ForEach-Object { $_.ToString() })
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
        $dismExe = Get-AIOMountNativeDismPath
        & $dismExe /Cleanup-Mountpoints /English "/LogPath:$(Join-Path $reportDir 'Limpieza.log')" 2>&1 | ForEach-Object {
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


# Identidad del archivo abierto y ruta efectiva. Dos letras o un enlace pueden nombrar el mismo objeto.
function Get-AIOFileIdentity {
    param([Parameter(Mandatory)][string]$Path)
    if (-not ('AIOFileIdentityV1' -as [type])) {
        Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public sealed class AIOFileIdentityV1 {
    public string Path, Id;
    [StructLayout(LayoutKind.Sequential)]
    struct FileInfo {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern uint GetFinalPathNameByHandle(SafeFileHandle handle, StringBuilder buffer, uint capacity, uint flags);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    public static AIOFileIdentityV1 Read(string path) {
        using (var handle=CreateFile(path,0,7,IntPtr.Zero,3,0x02000000,IntPtr.Zero)) {
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            var buf=new StringBuilder(32768);
            uint n=GetFinalPathNameByHandle(handle,buf,(uint)buf.Capacity,1);
            if (n==0) n=GetFinalPathNameByHandle(handle,buf,(uint)buf.Capacity,0);
            FileInfo info;
            if (n==0 || n>=buf.Capacity || !GetFileInformationByHandle(handle,out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return new AIOFileIdentityV1 {Path=buf.ToString(),Id=String.Format("{0:X8}:{1:X8}{2:X8}",info.Volume,info.IndexHigh,info.IndexLow)};
        }
    }
}
'@
    }
    [AIOFileIdentityV1]::Read([IO.Path]::GetFullPath($Path))
}

function Test-AIOPathWithin {
    param([string]$Path,[string]$Root)
    $separator = [IO.Path]::DirectorySeparatorChar
    $base = $Root.TrimEnd($separator)
    return ($Path.TrimEnd($separator) -ieq $base -or $Path.StartsWith($base + $separator,[StringComparison]::OrdinalIgnoreCase))
}

function Get-AIOOutputSnapshot {
    param([string]$Destination)
    if (Test-Path -LiteralPath $Destination -ErrorAction Stop) {
        $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "El destino debe ser un archivo ordinario: $Destination"
        }
        return [pscustomobject]@{Id=(Get-AIOFileIdentity $Destination).Id; Size=$item.Length; Written=$item.LastWriteTimeUtc.Ticks}
    }
}

function Publish-AIOVerifiedFile {
    param([string]$Pending,[string]$Destination,$Previous)
    if ($null -eq $Previous) {
        [IO.File]::Move($Pending,$Destination)
        return
    }
    $current = Get-AIOOutputSnapshot $Destination
    if (-not $current -or $current.Id -ne $Previous.Id -or $current.Size -ne $Previous.Size -or $current.Written -ne $Previous.Written) {
        throw "El destino ha cambiado desde la confirmacion: $Destination"
    }
    # Todos los archivos estan en el mismo volumen. Conservar el respaldo hasta completar Replace.
    $backup = "$Pending.anterior"
    [IO.File]::Replace($Pending,$Destination,$backup)
    try { Remove-Item -LiteralPath $backup -Force -ErrorAction Stop }
    catch { Write-Warning "Copia anterior conservada en $backup" }
}

function Get-AIOVerifiedVhdDisk {
    param([string]$Path)
    $vhd = Get-VHD -Path $Path -ErrorAction Stop
    if (-not $vhd.Attached -or $null -eq $vhd.DiskNumber -or [int]$vhd.DiskNumber -lt 0) { throw 'El archivo VHD no esta adjunto a un disco identificable.' }
    $disk = Get-Disk -Number $vhd.DiskNumber -ErrorAction Stop
    $backing = Get-VHD -DiskNumber $disk.Number -ErrorAction Stop
    $hostPartition = Get-Partition -DriveLetter $env:SystemDrive[0] -ErrorAction Stop
    if ($null -eq $hostPartition.DiskNumber -or $disk.IsBoot -ne $false -or $disk.IsSystem -ne $false -or $disk.Number -eq $hostPartition.DiskNumber -or
        -not $disk.UniqueId -or (Get-AIOFileIdentity $backing.Path).Id -ne (Get-AIOFileIdentity $Path).Id) {
        throw 'No se puede asociar el VHD a un disco offline distinto del Windows activo.'
    }
    return $disk
}

function Get-AIOVerifiedVhdPartition {
    param($Disk,[int]$Number)
    $part = Get-Partition -DiskNumber $Disk.Number -PartitionNumber $Number -ErrorAction Stop
    if (-not $part.DriveLetter -or $part.IsBoot -or $part.IsSystem) { throw 'Particion sin letra o protegida.' }
    $byLetter = Get-Partition -DriveLetter $part.DriveLetter -ErrorAction Stop
    if ($byLetter.DiskNumber -ne $Disk.Number -or $byLetter.PartitionNumber -ne $Number -or "$($part.DriveLetter):" -ieq $env:SystemDrive) {
        throw 'La letra ya no corresponde a la particion seleccionada.'
    }
    return $part
}

function Restore-AIOVhdSession {
    $record = Join-Path (Split-Path -Parent $script:configFile) 'vhd-session.json'
    if (-not (Test-Path -LiteralPath $record -PathType Leaf)) { return }
    try {
        $saved = Get-Content -LiteralPath $record -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        $disk = Get-AIOVerifiedVhdDisk $saved.Path
        $part = Get-AIOVerifiedVhdPartition $disk $saved.Partition
        if ($saved.FileId -ne (Get-AIOFileIdentity $saved.Path).Id -or $saved.DiskId -ne $disk.UniqueId -or
            [string]$saved.Offset -ne [string]$part.Offset -or $saved.VolumeId -ne (Get-AIOFileIdentity "$($part.DriveLetter):\").Id) {
            throw 'La identidad guardada no coincide.'
        }
        $Script:WIM_FILE_PATH = $saved.Path
        $Script:MOUNTED_INDEX = $part.PartitionNumber
        $Script:MOUNT_DIR = "$($part.DriveLetter):\"
        $Script:IMAGE_MOUNTED = 2
        Write-Log -LogLevel INFO -Message "Sesion VHD verificada: $($saved.Path) en $Script:MOUNT_DIR."
    } catch { Write-Warning "Sesion VHD sin recuperar: $($_.Exception.Message)" }
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

    Expand-AIOSelectedIso -IsoPath $IsoPath -ExtractDir $ExtractDir -ProgramDir $parentDir
}

function Expand-AIOSelectedIso {
    param([string]$IsoPath,[string]$ExtractDir,[string]$ProgramDir)
    $mountedHere = $false
    $progState = @{ Active = $false; LastWidth = 0; LastDrawMs = -500L }
    try {
        $base = [IO.Path]::GetFullPath($ExtractDir)
        if (-not (Test-Path -LiteralPath $base)) {
            $null = New-Item -Path $base -ItemType Directory -ErrorAction Stop
        }
        $baseId = Get-AIOFileIdentity $base
        $toolId = Get-AIOFileIdentity $ProgramDir
        $isoId = Get-AIOFileIdentity $IsoPath
        $rootId = Get-AIOFileIdentity ([IO.Path]::GetPathRoot($base))
        if ($baseId.Id -eq $rootId.Id -or (Test-AIOPathWithin $toolId.Path $baseId.Path) -or (Test-AIOPathWithin $isoId.Path $baseId.Path)) {
            throw 'Elige una carpeta de extraccion distinta de la raiz y separada del programa y de la ISO.'
        }
        $mountResult = Get-DiskImage -ImagePath $IsoPath -ErrorAction Stop
        if (-not $mountResult.Attached) {
            $mountResult = Mount-DiskImage -ImagePath $IsoPath -PassThru -StorageType ISO -ErrorAction Stop
            $mountedHere = $true
        }
        $isoBase = ([IO.Path]::GetFileNameWithoutExtension($IsoPath) -replace '[^A-Za-z0-9._-]', '_').Trim(' ._-')
        if ([string]::IsNullOrWhiteSpace($isoBase) -or $isoBase -match '^(?i)(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') {
            $isoBase = 'ISO'
        }
        if ($isoBase.Length -gt 20) { $isoBase = $isoBase.Substring(0, 20).TrimEnd(' ._-') }
        $folderStem = "{0}_{1}" -f $isoBase, (Get-Date -Format 'yyMMdd_HHmm')
        $ExtractDir = Join-Path $base $folderStem
        $suffix = 2
        while (Test-Path -LiteralPath $ExtractDir) {
            $ExtractDir = Join-Path $base ("{0}_{1}" -f $folderStem, $suffix)
            $suffix++
        }
        $null = New-Item -Path $ExtractDir -ItemType Directory -ErrorAction Stop
        # Pausa tactica de veterano
        Start-Sleep -Seconds 2

        $vol = $mountResult | Get-Volume -ErrorAction Stop
        if (@($vol).Count -ne 1 -or -not $vol.DriveLetter) { throw "No se pudo obtener la letra de la unidad montada." }

        $driveRoot = "$($vol.DriveLetter):\"

        # Inventario rapido previo para calcular porcentaje real por bytes (incluye install.wim/esd).
        $totalFiles = 0
        $totalBytes = 0L
        try {
            Get-ChildItem -LiteralPath $driveRoot -Recurse -File -Force -ErrorAction SilentlyContinue | ForEach-Object {
                $totalFiles++
                $totalBytes += $_.Length
            }
        } catch {}

        Write-Host ""
        Write-Host "  >> Copiando archivos de la ISO ($totalFiles archivos, $([Math]::Round($totalBytes / 1GB, 2)) GB)..." -ForegroundColor Cyan
        Write-Log -LogLevel ACTION -Message "SourceSelector: Copiando contenido de $driveRoot a $ExtractDir via Robocopy (/A-:R /R:2 /W:2). Total=$totalFiles archivos, $totalBytes bytes."

        $barWidth = 24
        $swCopy = [Diagnostics.Stopwatch]::StartNew()
        $renderProgress = {
            param([long]$BytesDone, [int]$FilesDone, [string]$CurrentFile, [switch]$Force)
            if (-not $Force -and ($swCopy.ElapsedMilliseconds - $progState.LastDrawMs) -lt 120) { return }
            $progState.LastDrawMs = $swCopy.ElapsedMilliseconds

            $pct = if ($totalBytes -gt 0) {
                [Math]::Min(100.0, [Math]::Max(0.0, ($BytesDone * 100.0) / $totalBytes))
            } elseif ($totalFiles -gt 0) {
                [Math]::Min(100.0, [Math]::Max(0.0, ($FilesDone * 100.0) / $totalFiles))
            } else { 0.0 }

            $filled = [int][Math]::Floor(($pct / 100.0) * $barWidth)
            if ($filled -gt $barWidth) { $filled = $barWidth }
            $barStr = ('#' * $filled) + ('-' * ($barWidth - $filled))
            $doneGB  = [Math]::Round($BytesDone / 1GB, 2)
            $totalGB = [Math]::Round($totalBytes / 1GB, 2)
            $elapsed = $swCopy.Elapsed.ToString('mm\:ss')
            $filesPart = if ($totalFiles -gt 0) { "$FilesDone/$totalFiles" } else { "$FilesDone" }
            $sizePart  = if ($totalBytes -gt 0) { ("{0:N2}/{1:N2} GB" -f $doneGB, $totalGB) } else { ("{0:N2} GB" -f $doneGB) }
            $fileSuffix = if ($CurrentFile) { " | $CurrentFile" } else { '' }
            $line = ("  [{0}] {1,5:N1}% | {2} | {3} arch. | {4}{5}" -f $barStr, $pct, $sizePart, $filesPart, $elapsed, $fileSuffix)

            $availableWidth = 79
            try {
                $cw = $Host.UI.RawUI.WindowSize.Width
                if ($cw -gt 1) { $availableWidth = $cw - 1 }
            } catch {}
            if ($line.Length -gt $availableWidth) {
                $line = if ($availableWidth -gt 3) { $line.Substring(0, $availableWidth - 3) + '...' } else { $line.Substring(0, $availableWidth) }
            }
            $padWidth = [Math]::Min($availableWidth, [Math]::Max($progState.LastWidth, $line.Length))
            Write-Host ("`r" + $line.PadRight($padWidth)) -NoNewline
            $progState.LastWidth = $padWidth
            $progState.Active = $true
        }

        $completedBytes = 0L
        $currentFileSize = 0L
        $currentFileName = ''
        $currentFileAccounted = $true
        $copiedFiles = 0

        if (-not ('AIOMountProcReaderV1' -as [type])) {
            Add-Type -ErrorAction Stop -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
public sealed class AIOMountProcReaderV1 : IDisposable {
    private readonly Process process;
    public readonly ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public AIOMountProcReaderV1(string fileName, string arguments) {
        process = new Process();
        process.StartInfo = new ProcessStartInfo {
            FileName = fileName, Arguments = arguments,
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true
        };
        process.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        process.ErrorDataReceived  += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
    }
    public void Start() {
        if (!process.Start()) throw new InvalidOperationException("No se pudo iniciar robocopy.exe.");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
    }
    public bool WaitForExit(int ms) { return process.WaitForExit(ms); }
    public void WaitForExit() { process.WaitForExit(); }
    public int ExitCode { get { return process.ExitCode; } }
    public void Dispose() { process.Dispose(); }
}
'@
        }

        # /A-:R retira Solo Lectura al vuelo; /R:2 /W:2 evita reintentos infinitos;
        # lector asincrono para actualizar el reloj cada ~250 ms aunque Windows vacie cache.
        $liveBytes = 0L
        $dstQuoted = '"' + $ExtractDir.TrimEnd('\') + '"'
        $roboArgLine = "$driveRoot $dstQuoted /E /XJ /A-:R /R:2 /W:2 /BYTES /NC /NDL /NJH /NJS"
        $roboExit = $null
        $reader = New-Object AIOMountProcReaderV1('robocopy.exe', $roboArgLine)
        try {
            $reader.Start()
            $drainQueue = {
                $rawLine = $null
                while ($reader.Lines.TryDequeue([ref]$rawLine)) {
                    foreach ($seg in ($rawLine -split "`r`n|`r|`n")) {
                        if ([string]::IsNullOrWhiteSpace($seg)) { continue }
                        if ($seg -match '^\s*(\d+(?:[.,]\d+)?)%\s*$') {
                            $filePct = 0.0
                            $pctText = $Matches[1].Replace(',', '.')
                            if ([double]::TryParse($pctText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$filePct)) {
                                if ($filePct -ge 100.0 -and -not $currentFileAccounted) {
                                    $completedBytes += $currentFileSize
                                    $liveBytes = $completedBytes
                                    $currentFileAccounted = $true
                                } elseif (-not $currentFileAccounted) {
                                    $liveBytes = $completedBytes + [long][Math]::Floor($currentFileSize * ($filePct / 100.0))
                                }
                            }
                        } elseif ($seg -match '^\s*(\d+)\s+(.+)$') {
                            if (-not $currentFileAccounted) {
                                $completedBytes += $currentFileSize
                                $currentFileAccounted = $true
                            }
                            $fileSize = 0L
                            [void][long]::TryParse($Matches[1], [ref]$fileSize)
                            $copiedFiles++
                            $currentFileSize = $fileSize
                            $currentFileName = [IO.Path]::GetFileName($Matches[2].Trim())
                            $currentFileAccounted = $false
                            $liveBytes = $completedBytes
                        }
                    }
                }
            }

            while (-not $reader.WaitForExit(250)) {
                . $drainQueue
                & $renderProgress -BytesDone $liveBytes -FilesDone $copiedFiles -CurrentFile $currentFileName
            }
            $reader.WaitForExit()
            . $drainQueue
            $roboExit = $reader.ExitCode
        } finally {
            $reader.Dispose()
        }
        if (-not $currentFileAccounted) {
            $completedBytes += $currentFileSize
            $currentFileAccounted = $true
        }
        $swCopy.Stop()
        if ($roboExit -in (0..7)) {
            $finalBytes = if ($totalBytes -gt 0) { $totalBytes } else { $completedBytes }
            $finalFiles = if ($totalFiles -gt 0) { $totalFiles } else { $copiedFiles }
            & $renderProgress -BytesDone $finalBytes -FilesDone $finalFiles -CurrentFile 'Completado' -Force
        }
        if ($progState.Active) { Write-Host ''; $progState.Active = $false }
        if ($null -eq $roboExit -or $roboExit -notin (0..7)) {
            throw "Error al copiar la ISO (Robocopy $roboExit). Carpeta parcial: $ExtractDir"
        }
        $SelectedPath = $ExtractDir
        Write-Host ("  [OK] ISO extraida ({0} archivos, {1:N2} GB en {2}). Atributos de solo lectura retirados." -f $copiedFiles, ($completedBytes / 1GB), $swCopy.Elapsed.ToString('mm\:ss')) -ForegroundColor Green
        Write-Log -LogLevel INFO -Message "SourceSelector: Extraccion completada. Archivos=$copiedFiles, Bytes=$completedBytes, Tiempo=$($swCopy.Elapsed.ToString('mm\:ss')), Destino='$ExtractDir'."

    } catch {
        if ($progState.Active) { Write-Host ''; $progState.Active = $false }
        Write-Log -LogLevel ERROR -Message "SourceSelector: Fallo al procesar la ISO - $($_.Exception.Message)"
        Write-Warning "No se pudo extraer la ISO: $($_.Exception.Message)"

        return $null
    } finally {
        if ($mountedHere) { Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Continue | Out-Null }
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

        $attachedHere = $false
        try {
            Write-Host "[+] Montando VHD..." -ForegroundColor Yellow
            Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando Mount-VHD para adjuntar el disco virtual."
            $vhdInfo = Get-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
            if (-not $vhdInfo.Attached) {
                Mount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
                $attachedHere = $true
            }
            
            # --- CORRECCIÓN: Pausa táctica (Respiración del bus virtual) ---
            Write-Log -LogLevel INFO -Message "MountManager: Esperando 2 segundos para inicializacion logica del disco..."
            Start-Sleep -Seconds 2

            # 1. Escaneo Inteligente de Particiones
            Write-Log -LogLevel INFO -Message "MountManager: Escaneando tabla de particiones del disco virtual montado."
            $disk = Get-AIOVerifiedVhdDisk $Script:WIM_FILE_PATH
            $windowsParts = @()
            $partitions = Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object { $_.Size -gt 1GB } # Filtramos EFI/MSR

            foreach ($part in $partitions) {
                # Auto-Asignar letra si falta
                if (-not $part.DriveLetter) {
                    $freeLet = Get-UnusedDriveLetter
                    Write-Log -LogLevel INFO -Message "MountManager: Asignando letra temporal [$freeLet] a particion sin montar."
                    Set-Partition -InputObject $part -NewDriveLetter $freeLet -ErrorAction Stop

                    # --- CORRECCIÓN: Active Polling (Max 5 segundos) ---
                    $timeout = 50
                    while (-not (Test-Path -LiteralPath "$($freeLet):\") -and $timeout -gt 0) {
                        Start-Sleep -Milliseconds 100
                        $timeout--
                    }
                    $part = Get-AIOVerifiedVhdPartition $disk $part.PartitionNumber
                }
                
                # Verificar si es Windows
                if (Test-Path "$($part.DriveLetter):\Windows\System32\config\SYSTEM") {
                    $windowsParts += $part
                    Write-Log -LogLevel INFO -Message "MountManager: Instalacion de Windows detectada automaticamente en particion [$($part.DriveLetter):]."
                }
            }

            # 2. Seleccion (Automatica o Manual)
            if ($windowsParts.Count -eq 1) {
                $targetPart = $windowsParts[0]
                Write-Host "[AUTO] Windows detectado en particion $($targetPart.DriveLetter):" -ForegroundColor Green
                $selectedPart = $targetPart
            } else {
                # Fallback: Menu manual si no detectamos Windows
                Write-Log -LogLevel INFO -Message "MountManager: Seleccion manual. Instalaciones Windows detectadas: $($windowsParts.Count)."
                Write-Host "Instalaciones Windows detectadas: $($windowsParts.Count)."
                Write-Host "Seleccione la particion manualmente:" -ForegroundColor Cyan
                
                $menuItems = @{}
                $i = 1
                $allParts = if ($windowsParts.Count) { $windowsParts } else {
                    Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Where-Object { $_.DriveLetter }
                }
                
                foreach ($p in $allParts) {
                    $gb = [math]::Round($p.Size / 1GB, 2)
                    Write-Host "   [$i] Unidad $($p.DriveLetter): ($gb GB)"
                    $menuItems[$i] = $p
                    $i++
                }
                
                $choice = Read-Host "Numero de particion"
                $number = 0
                if ([int]::TryParse($choice, [ref]$number) -and $menuItems.ContainsKey($number)) { 
                    $selectedPart = $menuItems[$number] 
                    Write-Log -LogLevel INFO -Message "MountManager: El usuario selecciono manualmente la particion [$($selectedPart.DriveLetter):]."
                } else { 
                    throw "Seleccion invalida." 
                }
            }

            # 3. Configurar Entorno Global
            $disk = Get-AIOVerifiedVhdDisk $Script:WIM_FILE_PATH
            $confirmed = Get-AIOVerifiedVhdPartition $disk $selectedPart.PartitionNumber
            if ($confirmed.DiskNumber -ne $selectedPart.DiskNumber -or $confirmed.Offset -ne $selectedPart.Offset) {
                throw 'La particion ha cambiado desde la seleccion.'
            }
            $selectedPart = $confirmed
            $driveLetter = "$($selectedPart.DriveLetter):\"
            $record = Join-Path (Split-Path -Parent $script:configFile) 'vhd-session.json'
            $entry = @{Path=$Script:WIM_FILE_PATH; FileId=(Get-AIOFileIdentity $Script:WIM_FILE_PATH).Id
                DiskId=$disk.UniqueId; Partition=$selectedPart.PartitionNumber; Offset=[string]$selectedPart.Offset
                VolumeId=(Get-AIOFileIdentity $driveLetter).Id}
            $oldRecord = Get-AIOOutputSnapshot $record
            $pendingRecord = "$record.$([Guid]::NewGuid().ToString('N')).tmp"
            try {
                $entry | ConvertTo-Json | Set-Content -LiteralPath $pendingRecord -Encoding UTF8 -ErrorAction Stop
                Publish-AIOVerifiedFile $pendingRecord $record $oldRecord
            } finally {
                if ([IO.File]::Exists($pendingRecord)) { Remove-Item -LiteralPath $pendingRecord -ErrorAction Continue }
            }
            $Script:MOUNT_DIR = $driveLetter
            $Script:IMAGE_MOUNTED = 2         # Estado 2 = VHD
            $Script:MOUNTED_INDEX = $selectedPart.PartitionNumber
            $Script:CachedControlSet = $null
            $Script:AIODashboardCache = $null
            $Script:ForceMenuRefresh = $false
            
            Write-Host "[OK] VHD Montado en: $Script:MOUNT_DIR" -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "MountManager: VHD Montado y vinculado exitosamente. Entorno local redireccionado a $Script:MOUNT_DIR"

        } catch {
            Write-Host "Error VHD: $_"
            Write-Log -LogLevel ERROR -Message "MountManager: Fallo critico durante montaje/escaneo VHD: $($_.Exception.Message)"
            if ($attachedHere) { Dismount-VHD -Path $Script:WIM_FILE_PATH -ErrorAction SilentlyContinue }
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

    Write-Host ""
    Write-Host "[+] Montando (Indice: $INDEX)..." -ForegroundColor Yellow
    Write-Log -LogLevel ACTION -Message "MountManager: Ejecutando DISM /Mount-Wim para adjuntar indice $INDEX en $Script:MOUNT_DIR."
    
    dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$INDEX /mountdir:"$Script:MOUNT_DIR"

    if ($LASTEXITCODE -eq 0) {
        $Script:IMAGE_MOUNTED = 1
        $Script:MOUNTED_INDEX = $INDEX
        $Script:CachedControlSet = $null
        $Script:AIODashboardCache = $null
        $Script:ForceMenuRefresh = $false
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
            Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $script:configFile) 'vhd-session.json') -ErrorAction SilentlyContinue
            
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
    if ($Script:IMAGE_MOUNTED -ne 1) {
        Write-Warning 'Recargar y descartar requiere un WIM montado. Los cambios en un VHD son inmediatos.'
        Pause
        return $false
    }
    try {
        $mounted = Get-AIOMountForPath -Mounts @(Get-AIOMountedImages) -Path $Script:MOUNT_DIR
        if (-not $mounted -or $mounted.Status -ne 'OK' -or $mounted.ImageIndex -ne $Script:MOUNTED_INDEX -or
            (Get-AIOFileIdentity $mounted.ImageFile).Id -ne (Get-AIOFileIdentity $Script:WIM_FILE_PATH).Id) {
            throw 'La sesion registrada en DISM ya no coincide con el WIM seleccionado.'
        }
        Unmount-Hives | Out-Host
        $result = Invoke-AIOConsoleSystemTool -Tool dism.exe -Arguments @('/Unmount-Image',"/MountDir:$Script:MOUNT_DIR",'/Discard')
        if ($result.ExitCode -ne 0) { throw "Error al desmontar el WIM: $($result.ExitCode)" }
        $Script:IMAGE_MOUNTED = 0
        $Script:AIODashboardCache = $null
        $Script:CachedControlSet = $null
        $Script:ForceMenuRefresh = $false
        $result = Invoke-AIOConsoleSystemTool -Tool dism.exe -Arguments @('/Mount-Image',"/ImageFile:$Script:WIM_FILE_PATH","/Index:$Script:MOUNTED_INDEX","/MountDir:$Script:MOUNT_DIR")
        if ($result.ExitCode -ne 0) { throw "Error al volver a montar el WIM: $($result.ExitCode)" }
        $Script:IMAGE_MOUNTED = 1
        Write-Host '[OK] WIM recargado.' -ForegroundColor Green
        return $true
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel ERROR -Message "Recarga WIM: $($_.Exception.Message)"
        Pause
        return $false
    }
}
