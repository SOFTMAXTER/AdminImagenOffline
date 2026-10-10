# =================================================================
#  Modulo-BootSetup
#  CONTENIDO: Setup Legacy/Win10, bypass, fondos y Show-BootSetup-GUI.
#  DEPENDENCIAS: Write-Log, Enable-Privileges, Unlock-Single-File,
#                Restore-FileOwner; WinForms/System.Drawing solo al abrir la GUI.
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

# =================================================================
# Setup Legacy. El argumento /legacy se escribe en [LaunchApps].
# El respaldo vive en el mismo indice: sobrevive a Commit y desaparece
# junto con la modificacion si el usuario elige Discard.
# =================================================================
function Get-AIOBootSetupHash {
    param([AllowEmptyCollection()][byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '') }
    finally { $sha.Dispose() }
}

function Get-AIOBootEditableAttributeMask {
    # SetFileAttributes no restaura SparseFile, ReparsePoint, Compressed ni Encrypted.
    return 0x3127 # ReadOnly, Hidden, System, Archive, Temporary, Offline, NotContentIndexed
}

function Get-AIOBootFileAttributes {
    param([Parameter(Mandatory=$true)][string]$Path)
    return [int][IO.File]::GetAttributes($Path)
}

function Set-AIOBootFileAttributesRaw {
    param([Parameter(Mandatory=$true)][string]$Path, [int]$Attributes)
    [IO.File]::SetAttributes($Path, [IO.FileAttributes]$Attributes)
}

function Set-AIOBootEditableAttributes {
    param([Parameter(Mandatory=$true)][string]$Path, [int]$Attributes)
    $mask = Get-AIOBootEditableAttributeMask
    $requested = $Attributes -band $mask
    if (((Get-AIOBootFileAttributes $Path) -band $mask) -eq $requested) { return }
    $value = if ($requested -eq 0) { [int][IO.FileAttributes]::Normal } else { $requested }
    Set-AIOBootFileAttributesRaw -Path $Path -Attributes $value
    $observed = Get-AIOBootFileAttributes $Path
    if (($observed -band $mask) -ne $requested) {
        throw "Atributos editables de '$Path': esperados=$([IO.FileAttributes]$requested) (0x$('{0:X}' -f $requested)); actuales=$([IO.FileAttributes]$observed) (0x$('{0:X}' -f $observed))."
    }
}

function Assert-AIOBootFileState {
    param([string]$Path, $Expected, $Current, [string]$Context = 'Fallo la verificacion del archivo')
    $differences = @()
    $mask = Get-AIOBootEditableAttributeMask
    if ($Current.Exists -ne $Expected.Exists) { $differences += 'existencia' }
    if ($Expected.Exists -and $Current.Exists) {
        if ($Current.Hash -cne $Expected.Hash) { $differences += 'contenido SHA-256' }
        if (($Current.Attributes -band $mask) -ne ($Expected.Attributes -band $mask)) {
            $differences += "atributos editables (esperados=0x$('{0:X}' -f ($Expected.Attributes -band $mask)), actuales=0x$('{0:X}' -f ($Current.Attributes -band $mask)))"
        }
        if ($Expected.Sddl -and $Current.Sddl -cne $Expected.Sddl) { $differences += 'SDDL (propietario, grupo o DACL)' }
    }
    if ($differences.Count -gt 0) {
        # Registrar solo metadatos, nunca los bytes Base64 de los fondos.
        try {
            $detail = [ordered]@{
                Path = $Path; Differences = $differences
                ExpectedAttributes = $Expected.Attributes; CurrentAttributes = $Current.Attributes
                ExpectedSddl = $Expected.Sddl; CurrentSddl = $Current.Sddl
                ExpectedHash = $Expected.Hash; CurrentHash = $Current.Hash
            } | ConvertTo-Json -Compress
            Write-Log -LogLevel ERROR -Message "BootFileVerify: $detail"
        } catch { }
        throw "${Context}: '$Path'. Diferencias: $($differences -join '; ')."
    }
}

function Restore-AIOBootFileMetadata {
    param([string]$Path, $State)
    $failures = @()
    # Atributos primero, mientras aun puede existir el permiso temporal de escritura.
    # Una falla de atributos nunca debe impedir intentar restaurar la seguridad.
    try { Set-AIOBootEditableAttributes -Path $Path -Attributes $State.Attributes }
    catch { $failures += "Atributos: $($_.Exception.Message)" }
    if ($State.Sddl) {
        try {
            $sections = [Security.AccessControl.AccessControlSections]::Access -bor
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Group
            $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
            # No reescribir una ACL intacta: evita cambios de herencia innecesarios.
            if ($current.GetSecurityDescriptorSddlForm($sections) -cne $State.Sddl) {
                Enable-Privileges | Out-Null
                $acl = New-Object System.Security.AccessControl.FileSecurity
                # Restaurar solo las secciones respaldadas; no tocar la auditoria SACL.
                $acl.SetSecurityDescriptorSddlForm($State.Sddl, $sections)
                Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
            }
        } catch { $failures += "Seguridad: $($_.Exception.Message)" }
    }
    if ($failures.Count -gt 0) { throw "No se recuperaron los metadatos de '$Path': $($failures -join '; ')" }
}

function Initialize-AIOBootFileReparseNative {
    [CmdletBinding()]
    param()

    if ('AdminImagenOffline.AIOBootReparseNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AdminImagenOffline {
    public static class AIOBootReparseNative {
        [StructLayout(LayoutKind.Sequential)]
        public struct AttributeTagInformation {
            public uint FileAttributes;
            public uint ReparseTag;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern SafeFileHandle CreateFileW(string fileName, uint desiredAccess,
            uint shareMode, IntPtr securityAttributes, uint creationDisposition,
            uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetFileInformationByHandleEx(SafeFileHandle handle,
            int informationClass, out AttributeTagInformation information, uint bufferSize);

        public static AttributeTagInformation ReadInfo(string path) {
            string fullPath = Path.GetFullPath(path);
            if (!fullPath.StartsWith(@"\\?\", StringComparison.Ordinal)) {
                fullPath = fullPath.StartsWith(@"\\", StringComparison.Ordinal)
                    ? @"\\?\UNC\" + fullPath.Substring(2) : @"\\?\" + fullPath;
            }
            // Access=0: consultar metadatos. Compartir lectura/escritura/borrado.
            // OPEN_REPARSE_POINT evita resolver el enlace del archivo final.
            using (SafeFileHandle handle = CreateFileW(fullPath, 0, 7, IntPtr.Zero,
                3, 0x00200000 | 0x02000000, IntPtr.Zero)) {
                if (handle.IsInvalid) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "No se pudo abrir para consultar el reparse tag: " + path);
                }
                AttributeTagInformation information;
                if (!GetFileInformationByHandleEx(handle, 9, out information,
                    (uint)Marshal.SizeOf(typeof(AttributeTagInformation)))) {
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "No se pudo consultar el reparse tag: " + path);
                }
                if ((information.FileAttributes & 0x400) == 0) information.ReparseTag = 0;
                return information;
            }
        }
    }
}
'@ -ErrorAction Stop
}

function Get-AIOBootFileReparseInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    Initialize-AIOBootFileReparseNative
    $info = [AdminImagenOffline.AIOBootReparseNative]::ReadInfo($Path)
    $tag = [uint32]$info.ReparseTag
    $tagHex = '0x{0:X8}' -f $tag
    $kind = switch ($tagHex) {
        '0x00000000' { 'None' }
        '0x80000008' { 'WIM' }
        '0x80000017' { 'WOF' }
        '0xA0000003' { 'MountPoint' }
        '0xA000000C' { 'SymbolicLink' }
        default { 'Other' }
    }
    return [pscustomobject]@{
        AttributesValue = [int]$info.FileAttributes
        Tag = $tag
        TagHex = $tagHex
        Kind = $kind
    }
}


function Get-AIOBootSetupFileState {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Base64 = ''; Hash = ''; Attributes = 0; Sddl = '' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Se esperaba un archivo: $Path" }
    # Validar el tipo de reparse antes de seguir el archivo. WIM/WOF son filtros
    # de almacenamiento; symlinks/junctions y tags desconocidos no se escriben.
    $attributes = Get-AIOBootFileAttributes $Path
    if (($attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
        $storage = Get-AIOBootFileReparseInfo -Path $Path
        if ($storage.TagHex -notin @('0x00000000', '0x80000008', '0x80000017') -or
            ($storage.AttributesValue -band [int][IO.FileAttributes]::Directory) -ne 0) {
            throw "Punto de reanalisis no admitido en '$Path': $($storage.TagHex)."
        }
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    $sections = [Security.AccessControl.AccessControlSections]::Access -bor
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Group
    return [pscustomobject]@{
        Exists = $true
        Base64 = [Convert]::ToBase64String($bytes)
        Hash = Get-AIOBootSetupHash -Bytes $bytes
        Attributes = Get-AIOBootFileAttributes $Path
        Sddl = $acl.GetSecurityDescriptorSddlForm($sections)
    }
}

function Set-AIOBootSetupFileState {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$State)
    $before = Get-AIOBootSetupFileState -Path $Path
    $bytes = if ($State.Exists) { [Convert]::FromBase64String($State.Base64) } else { $null }
    try {
        try {
            if ($before.Exists) {
                Set-AIOBootEditableAttributes -Path $Path -Attributes ($before.Attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
            }
            if ($State.Exists) { [IO.File]::WriteAllBytes($Path, [byte[]]$bytes) }
            elseif ($before.Exists) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        } catch [System.UnauthorizedAccessException] {
            if (-not $before.Exists) { throw }
            Unlock-Single-File -FilePath $Path | Out-Null
            Set-AIOBootEditableAttributes -Path $Path -Attributes ($before.Attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
            if ($State.Exists) { [IO.File]::WriteAllBytes($Path, [byte[]]$bytes) }
            else { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        }
    } finally {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $metadata = if ($State.Exists) { $State } else { $before }
            if ($metadata.Exists) { Restore-AIOBootFileMetadata -Path $Path -State $metadata }
        }
    }
    $after = Get-AIOBootSetupFileState -Path $Path
    Assert-AIOBootFileState -Path $Path -Expected $State -Current $after
    # Conservar la copia de seguridad del desbloqueador hasta verificar tambien
    # los permisos y atributos; nunca retirarla en un finally previo a verificar.
    if ($null -ne $Script:FileSDDL_Backups) {
        [void]$Script:FileSDDL_Backups.Remove([IO.Path]::GetFullPath($Path).ToLowerInvariant())
    }
}

function Assert-AIOBootSetupAvailable {
    param([Parameter(Mandatory=$true)][string]$MountPath)
    # Un WinPE de herramientas o un install.wim no deben recibir este cambio.
    foreach ($relative in @('setup.exe', 'sources\setup.exe', 'Windows\System32\winpeshl.exe')) {
        $file = Join-Path $MountPath $relative
        if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
            (Get-Item -LiteralPath $file -Force -ErrorAction Stop).Length -eq 0) {
            throw "Este indice no contiene el entorno Setup requerido ($relative). Selecciona el indice de instalacion de boot.wim."
        }
    }
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo((Join-Path $MountPath 'setup.exe'))
    if ($version.FileMajorPart -ne 10 -or $version.FileBuildPart -lt 10240) {
        throw 'Esta opcion requiere el Setup de Windows 10/11 (build 10240+). No se reconocio esa version en setup.exe de la raiz del montaje.'
    }
}

function Test-AIOBootStandardShell {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    # Solo reemplazar un INI estandar de un unico lanzador; admite /legacy.
    # Conservar scripts/DaRT y otros arranques personalizados sin alterarlos.
    $lines = @([IO.File]::ReadAllLines($Path) | ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith(';') -and -not $_.StartsWith('#') })
    if ($lines.Count -ne 2) { return $false }
    $launcher = '(?:%SYSTEMDRIVE%|X:)\\(?:sources\\)?setup\.exe'
    if ($lines[0] -ieq '[LaunchApp]') { return $lines[1] -match ('(?i)^AppPath\s*=\s*"?' + $launcher + '"?\s*$') }
    if ($lines[0] -ieq '[LaunchApps]') { return $lines[1] -match ('(?i)^"?' + $launcher + '"?(?:\s*,\s*/legacy)?\s*$') }
    return $false
}

function Get-AIOBootLegacySetupStatus {
    param([Parameter(Mandatory=$true)][string]$MountPath)
    try {
        $ini = Join-Path $MountPath 'Windows\System32\winpeshl.ini' -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $ini -ErrorAction Stop)) {
            return [pscustomobject]@{ State = 'NotConfigured'; Label = '[NO CONFIGURADO]'; Color = 'DarkGray' }
        }
        # Leer el contenido del montaje cada vez que se dibuja el menu.
        # No depender del respaldo JSON ni de variables de la sesion anterior.
        $lines = @([IO.File]::ReadAllLines($ini) | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith(';') -and -not $_.StartsWith('#') })
        $launcher = '(?:"(?:%SYSTEMDRIVE%|X:)\\setup\.exe"|(?:%SYSTEMDRIVE%|X:)\\setup\.exe)'
        if ($lines.Count -eq 2 -and $lines[0] -ieq '[LaunchApps]' -and
            $lines[1] -match ('(?i)^' + $launcher + '\s*,\s*/legacy\s*$')) {
            return [pscustomobject]@{ State = 'Legacy'; Label = '[LEGACY ACTIVO]'; Color = 'Green' }
        }
        if (Test-AIOBootStandardShell -Path $ini) {
            return [pscustomobject]@{ State = 'NotConfigured'; Label = '[NO CONFIGURADO]'; Color = 'DarkGray' }
        }
        return [pscustomobject]@{ State = 'Custom'; Label = '[OTRA CONFIGURACION]'; Color = 'Yellow' }
    } catch {
        # Un error de lectura no equivale a que el archivo no exista.
        return [pscustomobject]@{ State = 'Unreadable'; Label = '[NO SE PUDO LEER]'; Color = 'Red' }
    }
}


function Get-AIOBootSetupBackup {
    param([Parameter(Mandatory=$true)][string]$Path)
    $backup = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($backup.Schema -ne 3) {
        throw 'Respaldo de Setup incompatible: esta revision solo admite el formato 3. Conserva el archivo; restaura con la version que lo creo o utiliza un medio sin personalizaciones anteriores.'
    }
    if ($backup.Owner -cne 'AdminImagenOffline.SetupLegacy' -or
        $null -eq $backup.Original -or $backup.Original.Exists -isnot [bool]) {
        throw 'Respaldo de Setup no reconocido. No se modificara la imagen.'
    }
    if ($backup.Original.Exists) {
        $bytes = [Convert]::FromBase64String($backup.Original.Base64)
        if ((Get-AIOBootSetupHash -Bytes $bytes) -cne $backup.Original.Hash -or
            [string]::IsNullOrWhiteSpace($backup.Original.Sddl) -or
            $null -eq $backup.Original.Attributes) {
            throw 'El respaldo original de winpeshl.ini esta incompleto o no coincide con su SHA-256.'
        }
    } elseif ($backup.Original.Base64 -ne '' -or $backup.Original.Hash -ne '' -or $backup.Original.Sddl -ne '') {
        throw 'El respaldo de la ausencia original de winpeshl.ini no es valido.'
    }
    return $backup
}

function Assert-AIOBootSetupConfiguration {
    param([Parameter(Mandatory=$true)][string]$MountPath, [Parameter(Mandatory=$true)]$Expected)
    $ini = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupLegacy.json'
    $current = Get-AIOBootSetupFileState -Path $ini
    Assert-AIOBootFileState -Path $ini -Expected $Expected.Ini -Current $current -Context 'winpeshl.ini cambio despues de configurar Setup. No se guardara automaticamente' 
    if ($Expected.Mode -in @('Legacy')) {
        Assert-AIOBootSetupAvailable -MountPath $MountPath
        $backup = Get-AIOBootSetupBackup -Path $backupPath
        if ((Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Expected.BackupHash) {
            throw 'El respaldo de Setup cambio durante la sesion.'
        }
    } elseif (Test-Path -LiteralPath $backupPath) {
        throw 'La restauracion no termino: todavia existe el respaldo de Setup.'
    }
}

function Set-AIOBootSetupMode {
    param(
        [Parameter(Mandatory=$true)][string]$MountPath,
        [Parameter(Mandatory=$true)][ValidateSet('Legacy', 'Original')][string]$Mode
    )
    $ini = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupLegacy.json'
    # Detectar un respaldo obsoleto sin interpretarlo, migrarlo ni borrarlo.
    if (Test-Path -LiteralPath (Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupClassic.json')) {
        throw 'Respaldo anterior de Setup no compatible. Utiliza un medio limpio o restaura con la version que lo creo.'
    }
    $legacyBytes = [Text.Encoding]::ASCII.GetBytes("[LaunchApps]`r`n%SYSTEMDRIVE%\setup.exe, /legacy`r`n")
    $legacyHash = Get-AIOBootSetupHash -Bytes $legacyBytes
    $current = Get-AIOBootSetupFileState -Path $ini
    $backup = $null
    if (Test-Path -LiteralPath $backupPath) { $backup = Get-AIOBootSetupBackup -Path $backupPath }
    if ($Mode -eq 'Legacy') {
        Assert-AIOBootSetupAvailable -MountPath $MountPath
        $createdBackup = $false
        if ($null -ne $backup) {
            if (-not $current.Exists -or $current.Hash -ne $legacyHash) {
                throw 'Existe un respaldo, pero el inicio actual no coincide con el Setup Legacy administrado. Restaura primero la configuracion original.'
            }
        } else {
            if (-not (Test-AIOBootStandardShell -Path $ini)) {
                throw 'winpeshl.ini contiene un inicio personalizado o no reconocido. Se conserva sin cambios para proteger sus scripts y herramientas.'
            }
            $backup = [pscustomobject]@{ Schema = 3; Owner = 'AdminImagenOffline.SetupLegacy'; Original = $current }
            $jsonBytes = [Text.Encoding]::UTF8.GetBytes(($backup | ConvertTo-Json -Depth 4))
            $stream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $createdBackup = $true
            try { $stream.Write($jsonBytes, 0, $jsonBytes.Length) } finally { $stream.Dispose() }
        }
        try {
            $null = Get-AIOBootSetupBackup -Path $backupPath
            if ($current.Hash -ne $legacyHash) {
                $legacy = [pscustomobject]@{
                    Exists = $true; Base64 = [Convert]::ToBase64String($legacyBytes); Hash = $legacyHash
                    Attributes = $current.Attributes; Sddl = $current.Sddl
                }
                Set-AIOBootSetupFileState -Path $ini -State $legacy
            }
        } catch {
            $failure = $_.Exception.Message
            try {
                Set-AIOBootSetupFileState -Path $ini -State $current
                if ($createdBackup) { Remove-Item -LiteralPath $backupPath -Force -ErrorAction Stop }
            } catch {
                throw "Fallo la activacion ($failure) y la reversion ($($_.Exception.Message)). Descarta este montaje; se conserva el respaldo disponible."
            }
            throw "No se activo Setup Legacy; se restauro el estado anterior. $failure"
        }
    } else {
        if ($null -eq $backup) { throw 'No hay un respaldo creado por esta opcion. No se eliminara ni modificara winpeshl.ini.' }
        # Acepta el estado original para reintentar una limpieza interrumpida.
        $isOriginal = $current.Exists -eq $backup.Original.Exists -and
            (-not $current.Exists -or $current.Hash -eq $backup.Original.Hash)
        if (-not $isOriginal -and (-not $current.Exists -or $current.Hash -ne $legacyHash)) {
            throw 'winpeshl.ini fue modificado por otra herramienta. Se conservan el archivo y el respaldo; no se sobrescribiran esos cambios.'
        }
        $backupState = Get-AIOBootSetupFileState -Path $backupPath
        Set-AIOBootSetupFileState -Path $ini -State $backup.Original
        Assert-AIOBootFileState -Path $ini -Expected $backup.Original -Current (Get-AIOBootSetupFileState $ini)
        Remove-AIOBootOperationBackup -Path $backupPath -Expected $backupState
    }
    $expected = [pscustomobject]@{
        Mode = $Mode; Ini = Get-AIOBootSetupFileState -Path $ini
        BackupHash = if ($Mode -eq 'Legacy') { (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash } else { '' }
    }
    Assert-AIOBootSetupConfiguration -MountPath $MountPath -Expected $expected
    $launchDescription = if ($Mode -eq 'Legacy') { 'Lanzador: %SYSTEMDRIVE%\setup.exe, /legacy.' } else { 'Inicio original recuperado.' }
    Write-Log -LogLevel INFO -Message "BootWimManager: Configuracion Setup verificada en el montaje. Modo: $Mode. $launchDescription"
    Write-Host '[OK] Configuracion preparada y verificada. Elige T y luego S para guardarla en boot.wim.' -ForegroundColor Green
    return $expected
}

# =================================================================
# Fondos Windows Setup de Windows 10/11. Los archivos externos del medio
# se preparan en memoria y solo se escriben al guardar. No se edita el indice PE.
# =================================================================
function Get-AIOBootBackgroundPaths {
    param([switch]$Media)
    if ($Media) { return @('background.bmp', 'background_cli.bmp', 'background_cli.png', 'winpe.jpg', 'spwizimg.dll') }
    return @('Windows\System32\winpe.jpg', 'Windows\System32\setup.bmp',
        'sources\background.bmp', 'sources\background_cli.bmp', 'sources\background_cli.png',
        'sources\spwizimg.dll', 'Windows\System32\spwizimg.dll')
}

function Get-AIOBootBackgroundBackup {
    param([Parameter(Mandatory=$true)][string]$Path, [switch]$Media)
    $backup = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $allowed = @(Get-AIOBootBackgroundPaths -Media:$Media)
    $owner = if ($Media) { 'AdminImagenOffline.SetupMediaBackground' } else { 'AdminImagenOffline.SetupBackground' }
    $seen = @{}
    if ($backup.Schema -ne 3) {
        throw 'Respaldo de fondo incompatible: esta revision solo admite el formato 3. Conserva el archivo; restaura con la version que lo creo o utiliza un medio sin personalizaciones anteriores.'
    }
    if ($backup.Owner -cne $owner -or
        @($backup.Files).Count -eq 0 -or @($backup.Files).Count -gt $allowed.Count) {
        throw 'Respaldo de fondo no reconocido.'
    }
    foreach ($entry in @($backup.Files)) {
        if ($entry.RelativePath -cnotin $allowed -or $seen.ContainsKey([string]$entry.RelativePath)) {
            throw 'El respaldo de fondo contiene rutas no permitidas o duplicadas.'
        }
        $seen[$entry.RelativePath] = $true
        if ($entry.Original.Exists -isnot [bool] -or -not $entry.Original.Exists -or
            (-not $Media -and [string]::IsNullOrWhiteSpace($entry.Original.Sddl)) -or $null -eq $entry.Original.Attributes -or
            -not $entry.PSObject.Properties['SkipReason'] -or
            $entry.AppliedHash -notmatch '^[A-Fa-f0-9]{64}$' -or $entry.PreviousHash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw 'El respaldo de fondo esta incompleto.'
        }
        $skipReason = Get-AIOBootBackgroundSkipReason $entry
        if ($skipReason -and ($skipReason -cne 'MissingBackground517' -or
            $entry.RelativePath -notmatch '(?i)(?:^|\\)spwizimg\.dll$' -or $entry.AppliedHash -cne $entry.PreviousHash)) {
            throw 'El respaldo contiene una omision de fondo no reconocida o incoherente.'
        }
        $bytes = [Convert]::FromBase64String($entry.Original.Base64)
        if ((Get-AIOBootSetupHash -Bytes $bytes) -cne $entry.Original.Hash) {
            throw "El respaldo de $($entry.RelativePath) no coincide con su SHA-256."
        }
    }
    return $backup
}

function Get-AIOBootBackgroundStatus {
    param([Parameter(Mandatory=$true)][string]$MountPath, [switch]$Media)
    try {
        $relative = if ($Media) { 'AdminImagenOffline.SetupMediaBackground.json' } else { 'Windows\System32\AdminImagenOffline.SetupBackground.json' }
        $path = Join-Path $MountPath $relative -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $path -ErrorAction Stop)) {
            return [pscustomobject]@{ Label = '[SIN REGISTRO]'; Color = 'DarkGray' }
        }
        $backup = Get-AIOBootBackgroundBackup -Path $path -Media:$Media
        foreach ($entry in @($backup.Files)) {
            $file = Join-Path $MountPath $entry.RelativePath
            if (-not (Test-Path -LiteralPath $file -PathType Leaf) -or
                (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash -ne $entry.AppliedHash) {
                return [pscustomobject]@{ Label = '[MODIFICADO/INCOMPLETO]'; Color = 'Yellow' }
            }
        }
        $recorded = @($backup.Files | ForEach-Object { $_.RelativePath })
        $present = @(Get-AIOBootBackgroundPaths -Media:$Media | Where-Object {
            Test-Path -LiteralPath (Join-Path $MountPath $_) -PathType Leaf
        })
        if ($present.Count -ne $recorded.Count -or @($present | Where-Object { $_ -notin $recorded }).Count -gt 0) {
            return [pscustomobject]@{ Label = '[MODIFICADO/INCOMPLETO]'; Color = 'Yellow' }
        }
        if (@($backup.Files | Where-Object { Get-AIOBootBackgroundSkipReason $_ }).Count -gt 0) {
            return [pscustomobject]@{ Label = '[PARCIAL: ASISTENTE PENDIENTE]'; Color = 'Yellow' }
        }
        return [pscustomobject]@{ Label = '[PERSONALIZADO]'; Color = 'Green' }
    } catch {
        if ($_.Exception.Message -like 'Respaldo de fondo incompatible:*') {
            return [pscustomobject]@{ Label = '[RESPALDO INCOMPATIBLE]'; Color = 'Yellow' }
        }
        return [pscustomobject]@{ Label = '[NO VERIFICABLE]'; Color = 'Red' }
    }
}

# Cargar solo datos de recursos: nunca ejecutar codigo de la DLL del medio.
function Initialize-AIOSetupResourceNative {
    if ('AIOSetupBackgroundResourcesR5' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public sealed class AIOSetupBackgroundProbeR5 {
    public Dictionary<ushort,byte[]> Images = new Dictionary<ushort,byte[]>();
    public string Inventory = "ninguno";
    public int MissingError;
}
public static class AIOSetupBackgroundResourcesR5 {
    private delegate bool EnumName(IntPtr module, IntPtr type, IntPtr name, IntPtr param);
    private delegate bool EnumLang(IntPtr module, IntPtr type, IntPtr name, ushort language, IntPtr param);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)] private static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool EnumResourceLanguagesExW(IntPtr module, IntPtr type, IntPtr name, EnumLang callback, IntPtr param, uint flags, ushort language);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool EnumResourceNamesExW(IntPtr module, IntPtr type, EnumName callback, IntPtr param, uint flags, ushort language);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern IntPtr FindResourceExW(IntPtr module, IntPtr type, IntPtr name, ushort language);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)] private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)] private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll", SetLastError=true, ExactSpelling=true)] private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern IntPtr BeginUpdateResourceW(string file, bool deleteExisting);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool UpdateResourceW(IntPtr update, IntPtr type, IntPtr name, ushort language, byte[] data, uint size);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    private static extern bool EndUpdateResourceW(IntPtr update, bool discard);
    private static Exception Error(string action) { return Error(action, Marshal.GetLastWin32Error()); }
    private static Exception Error(string action, int code) {
        return new Win32Exception(code, action + " (Win32 " + code + "): " + new Win32Exception(code).Message);
    }
    private static IntPtr ResourceType(string kind) {
        if (kind == "BITMAP") return new IntPtr(2);
        if (kind == "IMAGE") return Marshal.StringToHGlobalUni("IMAGE");
        throw new ArgumentException("Tipo de fondo no admitido: " + kind);
    }
    private static uint UInt32BE(byte[] bytes, int at) {
        return ((uint)bytes[at] << 24) | ((uint)bytes[at+1] << 16) | ((uint)bytes[at+2] << 8) | bytes[at+3];
    }
    public static void ValidatePayload(string kind, byte[] bytes) {
        if (kind == "BITMAP") { ToBitmap(bytes); return; }
        if (kind != "IMAGE") throw new ArgumentException("Tipo de fondo no admitido: " + kind);
        byte[] signature = new byte[] {137,80,78,71,13,10,26,10};
        if (bytes == null || bytes.Length < 33) throw new InvalidDataException("IMAGE 517: PNG incompleto.");
        for (int i=0; i<signature.Length; i++)
            if (bytes[i] != signature[i]) throw new InvalidDataException("IMAGE 517 no contiene un PNG reconocido.");
        if (UInt32BE(bytes,8) != 13 || bytes[12] != 73 || bytes[13] != 72 || bytes[14] != 68 || bytes[15] != 82)
            throw new InvalidDataException("IMAGE 517: encabezado PNG IHDR no valido.");
        uint width = UInt32BE(bytes,16), height = UInt32BE(bytes,20);
        if (width == 0 || height == 0 || (ulong)width * height > 64000000)
            throw new InvalidDataException("IMAGE 517: dimensiones PNG no admitidas.");
        // System.Drawing decodifica y verifica la imagen completa antes de escribir.
    }
    public static AIOSetupBackgroundProbeR5 Probe(string path, string kind) {
        IntPtr type = ResourceType(kind), module = IntPtr.Zero;
        try {
            module = LoadLibraryExW(Path.GetFullPath(path), IntPtr.Zero, 0x60); // DATAFILE_EXCLUSIVE | IMAGE_RESOURCE
            if (module == IntPtr.Zero) throw Error("No se pudo abrir spwizimg.dll como datos");
            var report = new AIOSetupBackgroundProbeR5();
            var names = new List<string>();
            bool hasBackground = false;
            EnumName nameCallback = delegate(IntPtr m, IntPtr t, IntPtr n, IntPtr p) {
                long id = n.ToInt64();
                if (id >= 0 && id <= 65535) {
                    names.Add("#" + id);
                    if (id == 517) hasBackground = true;
                } else {
                    names.Add("nombre:" + Marshal.PtrToStringUni(n));
                }
                return true;
            };
            // RESOURCE_ENUM_LN | RESOURCE_ENUM_VALIDATE: solo esta DLL, sin MUI del anfitrion.
            bool namesOk = EnumResourceNamesExW(module, type, nameCallback, IntPtr.Zero, 0x9, 0);
            int namesError = Marshal.GetLastWin32Error();
            GC.KeepAlive(nameCallback);
            if (!namesOk) {
                // Solo ausencia explicita de seccion/tipo; cualquier otro fallo es fatal.
                if (names.Count == 0 && (namesError == 1812 || namesError == 1813)) {
                    report.MissingError = namesError;
                    return report;
                }
                throw Error("EnumResourceNamesEx " + kind, namesError);
            }
            if (names.Count == 0) throw new InvalidDataException("La enumeracion " + kind + " termino sin recursos ni motivo de ausencia.");
            names.Sort(StringComparer.Ordinal);
            report.Inventory = String.Join(", ", names.ToArray());
            if (!hasBackground) {
                report.MissingError = 1814; // inventario completo: el ID numerico 517 no existe
                return report;
            }
            var languages = new List<ushort>();
            EnumLang callback = delegate(IntPtr m, IntPtr t, IntPtr n, ushort l, IntPtr p) { languages.Add(l); return true; };
            bool ok = EnumResourceLanguagesExW(module, type, new IntPtr(517), callback, IntPtr.Zero, 0x9, 0);
            int languageError = Marshal.GetLastWin32Error();
            GC.KeepAlive(callback);
            if (!ok) throw Error("EnumResourceLanguagesEx " + kind + " 517", languageError);
            if (languages.Count == 0) throw new InvalidDataException(kind + " 517 existe, pero no se pudieron enumerar sus idiomas.");
            foreach (ushort language in languages) {
                IntPtr resource = FindResourceExW(module, type, new IntPtr(517), language);
                if (resource == IntPtr.Zero) throw Error("FindResourceEx " + kind + " 517");
                uint length = SizeofResource(module, resource);
                if (length < (kind == "BITMAP" ? 40u : 33u) || length > 256000000) throw new InvalidDataException("Tamano de " + kind + " 517 no admitido.");
                IntPtr loaded = LoadResource(module, resource);
                if (loaded == IntPtr.Zero) throw Error("LoadResource " + kind + " 517");
                IntPtr data = LockResource(loaded);
                if (data == IntPtr.Zero) throw Error("LockResource " + kind + " 517");
                byte[] bytes = new byte[(int)length]; Marshal.Copy(data, bytes, 0, bytes.Length);
                ValidatePayload(kind, bytes); // los recursos presentes pero danados nunca se omiten
                report.Images.Add(language, bytes);
            }
            return report;
        } finally {
            if (module != IntPtr.Zero) FreeLibrary(module);
            if (kind == "IMAGE") Marshal.FreeHGlobal(type);
        }
    }
    public static Dictionary<ushort,byte[]> Read(string path, string kind) { return Probe(path, kind).Images; }
    public static byte[] ToBitmap(byte[] dib) {
        if (dib == null || dib.Length < 40) throw new InvalidDataException("DIB incompleto.");
        uint header = BitConverter.ToUInt32(dib,0), compression = BitConverter.ToUInt32(dib,16);
        int width = BitConverter.ToInt32(dib,4), height = BitConverter.ToInt32(dib,8);
        ushort bits = BitConverter.ToUInt16(dib,14);
        if ((header != 40 && header != 108 && header != 124) || width <= 0 || height == 0 ||
            (long)width * Math.Abs((long)height) > 64000000 || BitConverter.ToUInt16(dib,12) != 1 ||
            (bits != 1 && bits != 4 && bits != 8 && bits != 16 && bits != 24 && bits != 32) ||
            (compression != 0 && compression != 1 && compression != 2 && compression != 3) ||
            (compression == 1 && bits != 8) || (compression == 2 && bits != 4)) throw new InvalidDataException("Formato DIB del fondo no admitido.");
        uint colors = BitConverter.ToUInt32(dib,32);
        if (colors == 0 && bits <= 8) colors = (uint)(1 << bits);
        long offset = header + colors * 4L + ((header == 40 && compression == 3) ? 12 : 0);
        long stride = (((long)width * bits + 31) / 32) * 4;
        long pixels = (compression == 1 || compression == 2) ? BitConverter.ToUInt32(dib,20) : stride * Math.Abs((long)height);
        if (offset < header || pixels <= 0 || offset + pixels > dib.Length) throw new InvalidDataException("DIB truncado.");
        byte[] bmp = new byte[dib.Length+14]; bmp[0]=66; bmp[1]=77;
        Buffer.BlockCopy(BitConverter.GetBytes(bmp.Length),0,bmp,2,4);
        Buffer.BlockCopy(BitConverter.GetBytes((int)(offset+14)),0,bmp,10,4);
        Buffer.BlockCopy(dib,0,bmp,14,dib.Length); return bmp;
    }
    public static void Replace(string path, Dictionary<ushort,byte[]> images, string kind) {
        if (images == null || images.Count == 0) throw new InvalidDataException("No hay fondos para reemplazar.");
        foreach (var image in images) ValidatePayload(kind, image.Value);
        IntPtr type = ResourceType(kind), update = IntPtr.Zero;
        try {
            update = BeginUpdateResourceW(path, false); // conservar todos los demas recursos
            if (update == IntPtr.Zero) throw Error("BeginUpdateResource");
            foreach (var image in images) {
                if (!UpdateResourceW(update, type, new IntPtr(517), image.Key, image.Value, (uint)image.Value.Length))
                    throw Error("UpdateResource " + kind + " 517");
            }
            IntPtr closing = update; update = IntPtr.Zero;
            if (!EndUpdateResourceW(closing, false)) throw Error("EndUpdateResource");
        } finally {
            if (update != IntPtr.Zero) EndUpdateResourceW(update, true);
            if (kind == "IMAGE") Marshal.FreeHGlobal(type);
        }
    }
}
'@ -ErrorAction Stop
}

function ConvertTo-AIOBootWizardBackgroundState {
    param([Parameter(Mandatory=$true)][string]$ImagePath, [Parameter(Mandatory=$true)]$Entry)
    Initialize-AIOSetupResourceNative
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('AIO-Setup-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temp)
    $dll = Join-Path $temp 'spwizimg.dll'
    try {
        [IO.File]::WriteAllBytes($dll, [Convert]::FromBase64String($Entry.State.Base64))
        $origin = if ($Entry.PSObject.Properties['SourcePath']) { $Entry.SourcePath } else { $Entry.RelativePath }
        Write-Log -LogLevel INFO -Message "BootBackground: Inspeccionando recursos de $origin."
        $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($dll).FileVersion
        $probes = @()
        foreach ($kind in @('BITMAP', 'IMAGE')) {
            $probe = [AIOSetupBackgroundResourcesR5]::Probe($dll, $kind)
            Write-Log -LogLevel INFO -Message "BootBackground: DLL $origin; version=$version; SHA256=$($Entry.State.Hash); $kind disponibles: $($probe.Inventory); ausencia=$($probe.MissingError)."
            $probes += [pscustomobject]@{ Kind = $kind; Result = $probe }
        }
        if (@($probes | Where-Object { $_.Result.MissingError -eq 0 }).Count -eq 0) {
            Write-Log -LogLevel WARN -Message "BootBackground: $origin no contiene BITMAP/517 ni IMAGE/517 reconocidos. DLL conservada sin escribir; personalizacion parcial del asistente."
            Write-Warning "Se conserva ${origin}: no contiene un fondo 517 reconocido. Se prepararan los recursos compatibles; el fondo de esta variante del asistente queda pendiente."
            return [pscustomobject]@{ RelativePath = $Entry.RelativePath; State = $Entry.State; SkipReason = 'MissingBackground517' }
        }
        $plans = @()
        foreach ($item in $probes) {
            if ($item.Result.MissingError -ne 0) { continue }
            $kind = $item.Kind
            $resources = $item.Result.Images
            $replacements = New-Object 'System.Collections.Generic.Dictionary[UInt16,Byte[]]'
            foreach ($language in $resources.Keys) {
                # BITMAP contiene DIB; IMAGE contiene un archivo PNG completo.
                [byte[]]$inputBytes = if ($kind -eq 'BITMAP') {
                    [AIOSetupBackgroundResourcesR5]::ToBitmap($resources[$language])
                } else { $resources[$language] }
                $extension = if ($kind -eq 'BITMAP') { 'bmp' } else { 'png' }
                $virtualFile = [pscustomobject]@{
                    RelativePath = "$($Entry.RelativePath):$kind/517/$language.$extension"
                    State = [pscustomobject]@{ Base64 = [Convert]::ToBase64String($inputBytes); Attributes = 0; Sddl = '' }
                }
                $converted = @(ConvertTo-AIOBootBackgroundStates -ImagePath $ImagePath -Files @($virtualFile))
                $bytes = [Convert]::FromBase64String($converted[0].State.Base64)
                if ($kind -eq 'BITMAP') {
                    if ($bytes.Length -lt 54 -or $bytes[0] -ne 66 -or $bytes[1] -ne 77) { throw 'La conversion no produjo un BMP valido.' }
                    $payload = New-Object byte[] ($bytes.Length - 14)
                    [Array]::Copy($bytes, 14, $payload, 0, $payload.Length)
                } else {
                    # No quitar 14 bytes: el recurso IMAGE conserva la firma y todos los chunks PNG.
                    $payload = $bytes
                }
                [AIOSetupBackgroundResourcesR5]::ValidatePayload($kind, $payload)
                $replacements.Add($language, $payload)
            }
            $plans += [pscustomobject]@{ Kind = $kind; Images = $replacements; Inventory = $item.Result.Inventory }
        }
        # Terminar ambas conversiones antes de modificar la copia temporal.
        foreach ($plan in $plans) { [AIOSetupBackgroundResourcesR5]::Replace($dll, $plan.Images, $plan.Kind) }
        foreach ($item in $probes) {
            $after = [AIOSetupBackgroundResourcesR5]::Probe($dll, $item.Kind)
            if ($after.Inventory -cne $item.Result.Inventory -or $after.MissingError -ne $item.Result.MissingError) {
                throw "Cambio el inventario de recursos $($item.Kind) del asistente."
            }
            if ($item.Result.MissingError -ne 0) { continue }
            $plan = $plans | Where-Object { $_.Kind -ceq $item.Kind } | Select-Object -First 1
            $verified = $after.Images
            if ($verified.Count -ne $plan.Images.Count) { throw 'Cambio el inventario de idiomas del fondo del asistente.' }
            foreach ($language in $plan.Images.Keys) {
                if (-not $verified.ContainsKey($language) -or
                    (Get-AIOBootSetupHash $verified[$language]) -ne (Get-AIOBootSetupHash $plan.Images[$language])) {
                    throw "No se verifico $($plan.Kind)/517, idioma $language."
                }
                Write-Log -LogLevel INFO -Message "BootBackground: $origin; recurso $($plan.Kind)/517/$language verificado tras la sustitucion."
            }
        }
        $bytes = [IO.File]::ReadAllBytes($dll)
        return [pscustomobject]@{
            RelativePath = $Entry.RelativePath
            State = [pscustomobject]@{
                Exists = $true; Base64 = [Convert]::ToBase64String($bytes); Hash = Get-AIOBootSetupHash $bytes
                Attributes = $Entry.State.Attributes; Sddl = $Entry.State.Sddl
            }
        }
    } catch {
        $origin = if ($Entry.PSObject.Properties['SourcePath']) { $Entry.SourcePath } else { $Entry.RelativePath }
        throw "No se pudo preparar $origin. $($_.Exception.GetBaseException().Message)"
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop }
}

# Las conversiones sin omision no necesitan indicar un motivo.
function Get-AIOBootBackgroundSkipReason {
    param([Parameter(Mandatory=$true)]$Entry)
    if ($Entry.PSObject.Properties['SkipReason']) { return [string]$Entry.SkipReason }
    return ''
}

function Assert-AIOBootBackgroundHasChanges {
    param([Parameter(Mandatory=$true)][object[]]$Files)
    if (@($Files | Where-Object { -not (Get-AIOBootBackgroundSkipReason $_) }).Count -eq 0) {
        throw 'No se encontraron recursos de fondo compatibles. Las DLL inspeccionadas se conservan; revisa el inventario BITMAP/IMAGE del registro.'
    }
}

function ConvertTo-AIOBootBackgroundStates {
    param([Parameter(Mandatory=$true)][string]$ImagePath, [Parameter(Mandatory=$true)][object[]]$Files)
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $source = $null
    $results = @()
    try {
        $source = [Drawing.Image]::FromFile($ImagePath)
        $formats = @([Drawing.Imaging.ImageFormat]::Jpeg.Guid, [Drawing.Imaging.ImageFormat]::Png.Guid,
            [Drawing.Imaging.ImageFormat]::Bmp.Guid)
        if ($source.RawFormat.Guid -notin $formats -or
            ([long]$source.Width * $source.Height) -gt 64000000) {
            throw 'Selecciona una imagen JPG, PNG o BMP de hasta 64 megapixeles.'
        }
        foreach ($entry in $Files) {
            if ($entry.RelativePath -match '(?i)(?:^|\\)spwizimg\.dll$') {
                $results += ConvertTo-AIOBootWizardBackgroundState -ImagePath $ImagePath -Entry $entry
                continue
            }
            $originalStream = $null; $original = $null; $bitmap = $null
            $graphics = $null; $output = $null; $verified = $null
            try {
                $originalStream = [IO.MemoryStream]::new([Convert]::FromBase64String($entry.State.Base64))
                $original = [Drawing.Image]::FromStream($originalStream)
                $width = $original.Width; $height = $original.Height
                # Algunos medios almacenan un BMP/PNG bajo el nombre winpe.jpg.
                # Mantener el formato real del archivo, no inferirlo por extension.
                $format = $original.RawFormat
                if ($format.Guid -notin $formats -or ([long]$width * $height) -gt 64000000) {
                    throw "Formato o dimensiones de fondo no admitidos: $($entry.RelativePath)."
                }
                # Un recurso de color solido puede medir pocos pixeles. No destruir
                # el detalle de la imagen elegida al reducirla a ese tamano.
                if ($width -lt 640 -or $height -lt 480) {
                    $width = 1024; $height = 768
                }
                Write-Log -LogLevel INFO -Message "BootBackground: $($entry.RelativePath): $($original.Width)x$($original.Height) -> $($width)x$($height), formato $format."
                $bitmap = [Drawing.Bitmap]::new($width, $height, [Drawing.Imaging.PixelFormat]::Format24bppRgb)
                $graphics = [Drawing.Graphics]::FromImage($bitmap)
                $graphics.Clear([Drawing.Color]::Black)
                $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                # Ajustar completa, centrada, sin deformar ni recortar logos.
                $scale = [Math]::Min($width / [double]$source.Width, $height / [double]$source.Height)
                $drawWidth = [Math]::Max(1, [int][Math]::Round($source.Width * $scale))
                $drawHeight = [Math]::Max(1, [int][Math]::Round($source.Height * $scale))
                $rect = [Drawing.Rectangle]::new([int](($width - $drawWidth) / 2),
                    [int](($height - $drawHeight) / 2), $drawWidth, $drawHeight)
                $graphics.DrawImage($source, $rect)
                $graphics.Dispose(); $graphics = $null
                $output = [IO.MemoryStream]::new()
                $bitmap.Save($output, $format)
                $bytes = $output.ToArray()
                $output.Position = 0
                $verified = [Drawing.Image]::FromStream($output)
                if ($verified.Width -ne $width -or $verified.Height -ne $height -or $verified.RawFormat.Guid -ne $format.Guid) {
                    throw "La conversion no se verifico: $($entry.RelativePath)."
                }
                $results += [pscustomobject]@{
                    RelativePath = $entry.RelativePath
                    State = [pscustomobject]@{
                        Exists = $true; Base64 = [Convert]::ToBase64String($bytes)
                        Hash = Get-AIOBootSetupHash -Bytes $bytes
                        Attributes = $entry.State.Attributes; Sddl = $entry.State.Sddl
                    }
                }
            } finally {
                foreach ($resource in @($verified, $output, $graphics, $bitmap, $original, $originalStream)) {
                    if ($null -ne $resource) { $resource.Dispose() }
                }
            }
        }
    } finally { if ($null -ne $source) { $source.Dispose() } }
    return $results
}

function Assert-AIOBootBackgroundConfiguration {
    param([Parameter(Mandatory=$true)][string]$MountPath, [Parameter(Mandatory=$true)]$Expected)
    foreach ($entry in @($Expected.Files)) {
        $current = Get-AIOBootSetupFileState -Path (Join-Path $MountPath $entry.RelativePath)
        Assert-AIOBootFileState -Path (Join-Path $MountPath $entry.RelativePath) -Expected $entry.State -Current $current -Context 'El fondo o sus permisos cambiaron. No se guardara' 
    }
    $path = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupBackground.json'
    if ($Expected.Mode -eq 'Custom') {
        $null = Get-AIOBootBackgroundBackup -Path $path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $Expected.BackupHash) {
            throw 'El respaldo del fondo cambio despues de la operacion.'
        }
    } elseif (Test-Path -LiteralPath $path) { throw 'La restauracion del fondo no termino de retirar su respaldo.' }
}

function Set-AIOBootBackground {
    param(
        [Parameter(Mandatory=$true)][string]$MountPath,
        [Parameter(Mandatory=$true)][ValidateSet('Custom', 'Original')][string]$Mode,
        [string]$ImagePath
    )
    # Defensa adicional al filtro del menu. No requiere activar Setup clasico.
    foreach ($relative in @('sources\setup.exe', 'Windows\System32\winpeshl.exe')) {
        if (-not (Test-Path -LiteralPath (Join-Path $MountPath $relative) -PathType Leaf)) {
            throw 'Selecciona un indice Windows Setup que conserve sus archivos de instalacion.'
        }
    }
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupBackground.json'
    $backupBefore = Get-AIOBootSetupFileState -Path $backupPath
    $backup = $null
    if ($backupBefore.Exists) { $backup = Get-AIOBootBackgroundBackup -Path $backupPath }
    if ($Mode -eq 'Original' -and $null -eq $backup) { throw 'No hay un respaldo de fondo creado por esta opcion.' }
    $paths = @(Get-AIOBootBackgroundPaths | Where-Object {
        Test-Path -LiteralPath (Join-Path $MountPath $_) -PathType Leaf
    })
    if ($null -ne $backup) {
        $recorded = @($backup.Files | ForEach-Object { $_.RelativePath })
        if ($Mode -eq 'Custom' -and ($paths.Count -ne $recorded.Count -or
            @($paths | Where-Object { $_ -notin $recorded }).Count -gt 0)) {
            throw 'Cambio el inventario de fondos. Restaura el original antes de aplicar otra imagen.'
        }
        if ($Mode -eq 'Original') { $paths = $recorded }
    }
    if ($paths.Count -eq 0) { throw 'No se encontraron archivos de fondo compatibles en este indice.' }
    $before = @()
    foreach ($relative in $paths) {
        $state = Get-AIOBootSetupFileState -Path (Join-Path $MountPath $relative)
        if ($null -ne $backup) {
            $record = $backup.Files | Where-Object { $_.RelativePath -ceq $relative } | Select-Object -First 1
            if ($null -eq $record) { throw 'El inventario del respaldo interno esta incompleto.' }
            $validHashes = if ($Mode -eq 'Original') {
                @($record.AppliedHash, $record.PreviousHash, $record.Original.Hash)
            } else { @($record.AppliedHash) }
            if (-not $state.Exists -or $state.Hash -notin $validHashes) {
                throw "El fondo $relative cambio fuera del administrador o falta. Se conserva el respaldo sin sobrescribir cambios externos."
            }
        }
        $before += [pscustomobject]@{ RelativePath = $relative; State = $state; SourcePath = Join-Path $MountPath $relative }
    }
    if ($Mode -eq 'Custom') {
        if ([string]::IsNullOrWhiteSpace($ImagePath) -or -not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
            throw 'No se encontro la imagen seleccionada.'
        }
        # Completar toda la conversion antes de escribir el primer archivo.
        $desired = @(ConvertTo-AIOBootBackgroundStates -ImagePath $ImagePath -Files $before)
        Assert-AIOBootBackgroundHasChanges -Files $desired
        $records = @()
        foreach ($entry in $desired) {
            $prior = $before | Where-Object { $_.RelativePath -ceq $entry.RelativePath } | Select-Object -First 1
            $priorRecord = if ($null -ne $backup) { $backup.Files | Where-Object { $_.RelativePath -ceq $entry.RelativePath } | Select-Object -First 1 }
            $originalState = if ($null -ne $priorRecord) { $priorRecord.Original } else { $prior.State }
            $records += [pscustomobject]@{
                RelativePath = $entry.RelativePath; Original = $originalState
                AppliedHash = $entry.State.Hash; PreviousHash = $prior.State.Hash
                SkipReason = Get-AIOBootBackgroundSkipReason $entry
            }
        }
        $newBackup = [pscustomobject]@{ Schema = 3; Owner = 'AdminImagenOffline.SetupBackground'; Files = $records }
        $json = [Text.Encoding]::UTF8.GetBytes(($newBackup | ConvertTo-Json -Depth 6))
    } else {
        $desired = @($backup.Files | ForEach-Object { [pscustomobject]@{ RelativePath = $_.RelativePath; State = $_.Original } })
    }
    $attempted = @()
    $backupTouched = $false
    try {
        if ($Mode -eq 'Custom') {
            if ($backupBefore.Exists) {
                $backupTouched = $true
                $newBackupState = [pscustomobject]@{
                    Exists = $true; Base64 = [Convert]::ToBase64String($json); Hash = Get-AIOBootSetupHash -Bytes $json
                    Attributes = $backupBefore.Attributes; Sddl = $backupBefore.Sddl
                }
                Set-AIOBootSetupFileState -Path $backupPath -State $newBackupState
            } else {
                $stream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $backupTouched = $true
                try { $stream.Write($json, 0, $json.Length) } finally { $stream.Dispose() }
            }
            $null = Get-AIOBootBackgroundBackup -Path $backupPath
        }
        foreach ($entry in $desired) {
            # La DLL sin recurso se verifica, pero no se escribe ni se alteran sus metadatos.
            if (Get-AIOBootBackgroundSkipReason $entry) { continue }
            # Incluir el archivo actual por si la escritura falla a la mitad.
            $attempted += $entry.RelativePath
            Set-AIOBootSetupFileState -Path (Join-Path $MountPath $entry.RelativePath) -State $entry.State
        }
        if ($Mode -eq 'Original') {
            # Validar todos los recursos antes de retirar el respaldo compartido.
            foreach ($entry in $desired) {
                $path = Join-Path $MountPath $entry.RelativePath
                Assert-AIOBootFileState -Path $path -Expected $entry.State -Current (Get-AIOBootSetupFileState $path)
            }
            $backupTouched = $true
            Remove-AIOBootOperationBackup -Path $backupPath -Expected $backupBefore
        }
        $expected = [pscustomobject]@{
            Mode = $Mode; Files = $desired
            BackupHash = if ($Mode -eq 'Custom') { (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256 -ErrorAction Stop).Hash } else { '' }
        }
        Assert-AIOBootBackgroundConfiguration -MountPath $MountPath -Expected $expected
    } catch {
        $failure = $_.Exception.Message
        $rollbackErrors = @()
        [Array]::Reverse($attempted)
        foreach ($relative in $attempted) {
            try {
                $prior = $before | Where-Object { $_.RelativePath -ceq $relative } | Select-Object -First 1
                Set-AIOBootSetupFileState -Path (Join-Path $MountPath $relative) -State $prior.State
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        # Retener el respaldo original si cualquier archivo no pudo recuperarse.
        if ($backupTouched -and ($rollbackErrors.Count -eq 0 -or $Mode -eq 'Original')) {
            try { Set-AIOBootSetupFileState -Path $backupPath -State $backupBefore }
            catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count -gt 0) {
            throw "Fallo el cambio de fondo ($failure) y la reversion no termino: $($rollbackErrors -join '; '). Descarta este montaje con T y N."
        }
        throw "No se completo el cambio de fondo; el estado previo se conserva. $failure"
    }
    $skipped = @($desired | Where-Object { Get-AIOBootBackgroundSkipReason $_ })
    $prepared = @($desired | Where-Object { -not (Get-AIOBootBackgroundSkipReason $_) })
    Write-Log -LogLevel INFO -Message "BootWimManager: Recursos de fondo $Mode verificados; preparados=$($prepared.Count), DLL sin modificar=$($skipped.Count). Preparados: $($prepared.RelativePath -join ', '). Validacion visual pendiente de arranque."
    if ($skipped.Count -gt 0) {
        Write-Warning 'Personalizacion parcial: se prepararon los fondos compatibles y se conservaron DLL sin fondos BITMAP/517 o IMAGE/517 reconocidos. El fondo de esas variantes del asistente queda pendiente.'
    }
    Write-Host '[OK] Recursos compatibles preparados. Elige T y S para guardar; comprueba el resultado al arrancar.' -ForegroundColor Green
    return $expected
}


# El medio externo se identifica solo a partir del boot.wim seleccionado.
function Get-AIOBootMediaSources {
    param([Parameter(Mandatory=$true)][string]$BootPath)
    try {
        $file = Get-Item -LiteralPath $BootPath -ErrorAction Stop
        if ($file.PSIsContainer -or $file.Name -ine 'boot.wim' -or $file.Directory.Name -ine 'sources') { return $null }
        $sources = $file.Directory.FullName
        $root = $file.Directory.Parent.FullName
        if (-not (Test-Path -LiteralPath (Join-Path $root 'setup.exe') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $sources 'setup.exe') -PathType Leaf)) { return $null }
        return $sources
    } catch { return $null }
}

function Get-AIOBootMediaFileState {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ Exists = $false; Base64 = ''; Hash = ''; Attributes = 0; Sddl = '' }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Se esperaba un archivo del medio: $Path" }
    if (([IO.File]::GetAttributes($Path) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "No se admiten enlaces para los fondos externos: $Path"
    }
    $bytes = [IO.File]::ReadAllBytes($Path)
    # Escritura in situ sin cambiar propietarios/ACL; funciona tambien en FAT32/exFAT.
    return [pscustomobject]@{
        Exists = $true; Base64 = [Convert]::ToBase64String($bytes); Hash = Get-AIOBootSetupHash $bytes
        Attributes = [int][IO.File]::GetAttributes($Path); Sddl = ''
    }
}

function Set-AIOBootMediaFileState {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$State, [switch]$CreateNew)
    $before = Get-AIOBootMediaFileState $Path
    $bytes = if ($State.Exists) { [Convert]::FromBase64String($State.Base64) } else { $null }
    $created = $false
    try {
        if ($CreateNew) {
            try {
                $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $created = $true
            } catch {
                $_.Exception.Data['AIOMediaFileUntouched'] = $true
                throw
            }
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        } else {
            if ($before.Exists) {
                [IO.File]::SetAttributes($Path, ([IO.FileAttributes]$before.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            }
            if ($State.Exists) { [IO.File]::WriteAllBytes($Path, [byte[]]$bytes) }
            elseif ($before.Exists) { Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
        }
    } finally {
        if ((-not $CreateNew -or $created) -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
            $metadata = if ($State.Exists) { $State } else { $before }
            if ($metadata.Exists) { [IO.File]::SetAttributes($Path, [IO.FileAttributes]$metadata.Attributes) }
        }
    }
    $after = Get-AIOBootMediaFileState $Path
    if ($after.Exists -ne $State.Exists -or ($State.Exists -and
        ($after.Hash -ne $State.Hash -or $after.Attributes -ne $State.Attributes))) {
        throw "No se verifico el archivo externo: $Path"
    }
}

function New-AIOBootMediaBackgroundPlan {
    param([AllowNull()][string]$SourcesPath, [ValidateSet('Custom','Original')][string]$Mode, [string]$ImagePath)
    if ([string]::IsNullOrWhiteSpace($SourcesPath)) { return $null }
    $backupName = 'AdminImagenOffline.SetupMediaBackground.json'
    $backupPath = Join-Path $SourcesPath $backupName
    $backupBefore = Get-AIOBootMediaFileState $backupPath
    $backup = if ($backupBefore.Exists) { Get-AIOBootBackgroundBackup -Path $backupPath -Media } else { $null }
    if ($Mode -eq 'Original' -and $null -eq $backup) { return $null }
    $paths = @(Get-AIOBootBackgroundPaths -Media | Where-Object { Test-Path -LiteralPath (Join-Path $SourcesPath $_) -PathType Leaf })
    if ($null -ne $backup) {
        $recorded = @($backup.Files | ForEach-Object { $_.RelativePath })
        if ($Mode -eq 'Custom' -and ($paths.Count -ne $recorded.Count -or
            @($paths | Where-Object { $_ -notin $recorded }).Count -gt 0)) {
            throw 'Cambio el inventario de fondos externos. Restaura los originales antes de elegir otra imagen.'
        }
        if ($Mode -eq 'Original') { $paths = $recorded }
    }
    if ($paths.Count -eq 0) { return $null }
    $before = @()
    foreach ($relative in $paths) {
        $state = Get-AIOBootMediaFileState (Join-Path $SourcesPath $relative)
        if ($null -ne $backup) {
            $record = $backup.Files | Where-Object { $_.RelativePath -ceq $relative } | Select-Object -First 1
            if ($null -eq $record) { throw 'El inventario del respaldo externo esta incompleto.' }
            $valid = if ($Mode -eq 'Original') { @($record.AppliedHash, $record.PreviousHash, $record.Original.Hash) } else { @($record.AppliedHash) }
            if (-not $state.Exists -or $state.Hash -notin $valid) {
                throw "El fondo externo $relative falta o cambio fuera del administrador. Se conserva sin sobrescribir."
            }
        }
        $before += [pscustomobject]@{ RelativePath = $relative; State = $state; SourcePath = Join-Path $SourcesPath $relative }
    }
    if ($Mode -eq 'Custom') {
        $desired = @(ConvertTo-AIOBootBackgroundStates -ImagePath $ImagePath -Files $before)
        Assert-AIOBootBackgroundHasChanges -Files $desired
        $records = @($desired | ForEach-Object {
            $entry = $_
            $prior = $before | Where-Object { $_.RelativePath -ceq $entry.RelativePath } | Select-Object -First 1
            $priorRecord = if ($null -ne $backup) { $backup.Files | Where-Object { $_.RelativePath -ceq $entry.RelativePath } | Select-Object -First 1 }
            $original = if ($null -ne $priorRecord) { $priorRecord.Original } else { $prior.State }
            [pscustomobject]@{ RelativePath = $entry.RelativePath; Original = $original; AppliedHash = $entry.State.Hash; PreviousHash = $prior.State.Hash; SkipReason = Get-AIOBootBackgroundSkipReason $entry }
        })
        $manifest = [pscustomobject]@{ Schema = 3; Owner = 'AdminImagenOffline.SetupMediaBackground'; Files = $records }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($manifest | ConvertTo-Json -Depth 6))
        $backupDesired = [pscustomobject]@{
            Exists = $true; Base64 = [Convert]::ToBase64String($bytes); Hash = Get-AIOBootSetupHash $bytes
            Attributes = if ($backupBefore.Exists) { $backupBefore.Attributes } else { [int][IO.FileAttributes]::Normal }; Sddl = ''
        }
    } else {
        $desired = @($backup.Files | ForEach-Object { [pscustomobject]@{ RelativePath = $_.RelativePath; State = $_.Original } })
        # Conservar el respaldo hasta que DISM confirme el Commit.
        $backupDesired = $backupBefore
    }
    return [pscustomobject]@{
        SourcesPath = $SourcesPath; Mode = $Mode; Files = $desired; Before = $before
        BackupName = $backupName; BackupBefore = $backupBefore; BackupDesired = $backupDesired
        Inventory = @(Get-AIOBootBackgroundPaths -Media | Where-Object { Test-Path -LiteralPath (Join-Path $SourcesPath $_) -PathType Leaf })
        Touched = @(); Written = @{}; NeedsRollback = $false
    }
}

function Assert-AIOBootMediaBackgroundPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    $inventory = @(Get-AIOBootBackgroundPaths -Media | Where-Object { Test-Path -LiteralPath (Join-Path $Plan.SourcesPath $_) -PathType Leaf })
    if (Compare-Object $inventory $Plan.Inventory) { throw 'Cambio el inventario del medio externo. Repite la opcion de fondo.' }
    $entries = @($Plan.Before) + @([pscustomobject]@{ RelativePath = $Plan.BackupName; State = $Plan.BackupBefore })
    foreach ($entry in $entries) {
        $current = Get-AIOBootMediaFileState (Join-Path $Plan.SourcesPath $entry.RelativePath)
        if ($current.Exists -ne $entry.State.Exists -or ($current.Exists -and
            ($current.Hash -ne $entry.State.Hash -or $current.Attributes -ne $entry.State.Attributes))) {
            throw "El archivo externo $($entry.RelativePath) cambio desde la seleccion. Repite la opcion de fondo."
        }
    }
}

function Undo-AIOBootMediaBackgroundPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    $errors = @()
    $names = @($Plan.Touched)
    [Array]::Reverse($names)
    foreach ($relative in $names) {
        # El respaldo se revierte al final y solo si todos los fondos se recuperaron.
        if ($relative -eq $Plan.BackupName -and $errors.Count -gt 0) { continue }
        try {
            $path = Join-Path $Plan.SourcesPath $relative
            $current = Get-AIOBootMediaFileState $path
            $prior = if ($relative -eq $Plan.BackupName) { $Plan.BackupBefore } else {
                ($Plan.Before | Where-Object { $_.RelativePath -ceq $relative } | Select-Object -First 1).State
            }
            $written = $Plan.Written[$relative]
            if ($null -eq $written -or ($current.Exists -ne $written.Exists -or $current.Hash -ne $written.Hash)) {
                # Una reversion previa puede haber recuperado este archivo.
                if ($current.Exists -ne $prior.Exists -or $current.Hash -ne $prior.Hash) {
                    throw "El archivo externo $relative cambio durante el guardado; no se sobrescribira."
                }
            }
            Set-AIOBootMediaFileState -Path $path -State $prior
        } catch { $errors += $_.Exception.Message }
    }
    if ($errors.Count -gt 0) { throw "No se pudo revertir el medio externo. Conserva el respaldo y reconecta el medio para reintentar: $($errors -join '; ')" }
    $Plan.NeedsRollback = $false
    $Plan.Touched = @(); $Plan.Written = @{}
}

function Invoke-AIOBootMediaBackgroundPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    if ($Plan.NeedsRollback) { throw 'Recupera primero la operacion externa pendiente antes de guardar otra vez.' }
    Assert-AIOBootMediaBackgroundPlan $Plan
    $writes = @()
    if ($Plan.Mode -eq 'Custom') { $writes += [pscustomobject]@{ RelativePath = $Plan.BackupName; State = $Plan.BackupDesired } }
    $writes += @($Plan.Files | Where-Object { -not (Get-AIOBootBackgroundSkipReason $_) })
    $Plan.NeedsRollback = $true
    try {
        foreach ($entry in $writes) {
            $path = Join-Path $Plan.SourcesPath $entry.RelativePath
            $Plan.Touched += $entry.RelativePath
            try {
                $create = $entry.RelativePath -eq $Plan.BackupName -and -not $Plan.BackupBefore.Exists
                Set-AIOBootMediaFileState -Path $path -State $entry.State -CreateNew:$create
            } catch {
                if ($_.Exception.Data['AIOMediaFileUntouched']) {
                    $Plan.Touched = @($Plan.Touched | Where-Object { $_ -cne $entry.RelativePath })
                }
                throw
            } finally {
                if ($entry.RelativePath -cin $Plan.Touched) { $Plan.Written[$entry.RelativePath] = Get-AIOBootMediaFileState $path }
            }
        }
        $null = Get-AIOBootBackgroundBackup -Path (Join-Path $Plan.SourcesPath $Plan.BackupName) -Media
    } catch {
        $failure = $_.Exception.Message
        Undo-AIOBootMediaBackgroundPlan $Plan
        throw "No se guardo el fondo externo; se recupero su estado anterior. $failure"
    }
}

function Complete-AIOBootMediaBackgroundPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    # DISM ya guardo la imagen; no deshacer el medio externo desde este punto.
    $Plan.NeedsRollback = $false
    foreach ($entry in $Plan.Files) {
        $current = Get-AIOBootMediaFileState (Join-Path $Plan.SourcesPath $entry.RelativePath)
        Assert-AIOBootFileState -Path (Join-Path $Plan.SourcesPath $entry.RelativePath) -Expected $entry.State -Current $current -Context 'El fondo externo cambio durante el Commit. El respaldo se conserva'
    }
    $backupPath = Join-Path $Plan.SourcesPath $Plan.BackupName
    if ((Get-AIOBootMediaFileState $backupPath).Hash -ne $Plan.BackupDesired.Hash) {
        throw 'El respaldo externo cambio durante el Commit. Se conserva para revision.'
    }
    if ($Plan.Mode -eq 'Original') {
        Remove-AIOBootOperationBackup -Path $backupPath -Expected $Plan.BackupDesired -Media
        $Plan.BackupDesired = New-AIOBootAbsentFileState
        $Plan.Touched = @(); $Plan.Written = @{}
    }
}


# =================================================================
# Setup clasico estilo Windows 10: renombrado reversible de setupprep.exe.
# Los planes externos se preparan en memoria y se aplican antes del Commit.
# =================================================================
function Get-AIOBootOptionFileState {
    param([string]$Path, [switch]$Media)
    if ($Media) { return Get-AIOBootMediaFileState -Path $Path }
    return Get-AIOBootSetupFileState -Path $Path
}

function Set-AIOBootOptionFileState {
    param([string]$Path, $State, [switch]$Media)
    if ($Media) { Set-AIOBootMediaFileState -Path $Path -State $State }
    else { Set-AIOBootSetupFileState -Path $Path -State $State }
}

function New-AIOBootAbsentFileState {
    return [pscustomobject]@{ Exists = $false; Base64 = ''; Hash = ''; Attributes = 0; Sddl = '' }
}

# Solo retirar el archivo exacto de esta operacion despues de validar sus datos.
# Un fallo deja visible la limpieza pendiente y permite reintentar la restauracion.
function Remove-AIOBootOperationBackup {
    param([Parameter(Mandatory=$true)][string]$Path, [Parameter(Mandatory=$true)]$Expected, [switch]$Media)
    $current = Get-AIOBootOptionFileState -Path $Path -Media:$Media
    Assert-AIOBootFileState -Path $Path -Expected $Expected -Current $current -Context 'El respaldo cambio antes de limpiarlo'
    $absent = New-AIOBootAbsentFileState
    Set-AIOBootOptionFileState -Path $Path -State $absent -Media:$Media
    Assert-AIOBootFileState -Path $Path -Expected $absent -Current (Get-AIOBootOptionFileState -Path $Path -Media:$Media) -Context 'No se pudo eliminar el respaldo restaurado'
}

function New-AIOBootWin10Plan {
    param([string]$SourcesPath, [ValidateSet('Classic','Original')][string]$Mode, [switch]$Media)
    if ([string]::IsNullOrWhiteSpace($SourcesPath)) { return $null }
    if (-not (Test-Path -LiteralPath $SourcesPath -PathType Container)) { throw "No existe la carpeta sources: $SourcesPath" }
    $names = @('setupprep.exe', 'setupprep.exe.aio.bak', 'AdminImagenOffline.SetupWin10.json')
    $before = @{}
    foreach ($name in $names) { $before[$name] = Get-AIOBootOptionFileState -Path (Join-Path $SourcesPath $name) -Media:$Media }
    $original = $before[$names[0]]; $renamed = $before[$names[1]]; $manifest = $before[$names[2]]
    if ($manifest.Exists) {
        $record = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($manifest.Base64)) | ConvertFrom-Json -ErrorAction Stop
        if ($record.Schema -ne 3 -or $record.Owner -cne 'AdminImagenOffline.SetupWin10' -or
            $record.Original.Hash -notmatch '^[A-Fa-f0-9]{64}$' -or $null -eq $record.Original.Attributes -or
            (-not $Media -and [string]::IsNullOrWhiteSpace($record.Original.Sddl))) { throw 'Respaldo de Setup estilo Windows 10 no reconocido.' }
        if ($original.Exists -eq $renamed.Exists) { throw 'Se esperaba una sola copia de setupprep.exe. No se sobrescribira ningun archivo.' }
        $binary = if ($original.Exists) { $original } else { $renamed }
        Assert-AIOBootFileState -Path $SourcesPath -Expected $record.Original -Current $binary -Context 'setupprep.exe o sus permisos cambiaron fuera del administrador'
    } else {
        if ($Mode -eq 'Original') { return $null }
        if (-not $original.Exists) { throw "No se encontro $SourcesPath\setupprep.exe. Esta variante de Setup no admite el renombrado solicitado." }
        if ($renamed.Exists) { throw 'Ya existe setupprep.exe.aio.bak sin un respaldo reconocido. Se conserva sin cambios.' }
        $binary = $original
    }
    $desired = @{}
    $absent = New-AIOBootAbsentFileState
    $desired[$names[0]] = if ($Mode -eq 'Classic') { $absent } else { $binary }
    $desired[$names[1]] = if ($Mode -eq 'Classic') { $binary } else { $absent }
    if ($manifest.Exists) { $desired[$names[2]] = $manifest }
    else {
        $record = [pscustomobject]@{ Schema = 3; Owner = 'AdminImagenOffline.SetupWin10'; Original = [pscustomobject]@{
            Exists = $true; Hash = $binary.Hash; Attributes = $binary.Attributes; Sddl = $binary.Sddl
        } }
        $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 5))
        $desired[$names[2]] = [pscustomobject]@{
            Exists = $true; Hash = Get-AIOBootSetupHash $bytes; Base64 = [Convert]::ToBase64String($bytes)
            Attributes = [int][IO.FileAttributes]::Normal; Sddl = ''
        }
    }
    return [pscustomobject]@{
        SourcesPath = $SourcesPath; Mode = $Mode; Media = [bool]$Media; Names = $names
        Before = $before; Desired = $desired; NeedsRollback = $false; ManifestCreated = $false
    }
}

function Assert-AIOBootWin10Plan {
    param($Plan, [switch]$Applied)
    $states = if ($Applied) { $Plan.Desired } else { $Plan.Before }
    foreach ($name in $Plan.Names) {
        $path = Join-Path $Plan.SourcesPath $name
        $current = Get-AIOBootOptionFileState -Path $path -Media:$Plan.Media
        Assert-AIOBootFileState -Path $path -Expected $states[$name] -Current $current -Context 'Cambio el estado de Setup estilo Windows 10'
    }
}

function Move-AIOBootSetupPrep {
    param([string]$Source, [string]$Destination, $State, [switch]$Media)
    if (Test-Path -LiteralPath $Destination) { throw "Ya existe el destino de renombrado: $Destination" }
    $moved = $false
    try {
        try { [IO.File]::Move($Source, $Destination); $moved = $true }
        catch [UnauthorizedAccessException] {
            if ($Media) { throw }
            Unlock-Single-File -FilePath $Source | Out-Null
            Set-AIOBootEditableAttributes -Path $Source -Attributes ($State.Attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly))
            [IO.File]::Move($Source, $Destination); $moved = $true
        }
    } finally {
        $path = if ($moved) { $Destination } else { $Source }
        if (-not $Media -and (Test-Path -LiteralPath $path)) { Restore-AIOBootFileMetadata -Path $path -State $State }
    }
    $current = Get-AIOBootOptionFileState -Path $Destination -Media:$Media
    Assert-AIOBootFileState -Path $Destination -Expected $State -Current $current
    if ($null -ne $Script:FileSDDL_Backups) { [void]$Script:FileSDDL_Backups.Remove([IO.Path]::GetFullPath($Source).ToLowerInvariant()) }
}

function Undo-AIOBootWin10Plan {
    param($Plan)
    if (-not $Plan.NeedsRollback) { return }
    $sourceName = $Plan.Names[0]; $backupName = $Plan.Names[1]; $manifestName = $Plan.Names[2]
    $current = @{}
    foreach ($name in $Plan.Names) { $current[$name] = Get-AIOBootOptionFileState -Path (Join-Path $Plan.SourcesPath $name) -Media:$Plan.Media }
    # Nunca borrar o reemplazar una segunda copia o un archivo ajeno.
    if ($current[$sourceName].Exists -eq $current[$backupName].Exists) { throw 'No se puede revertir: el inventario de setupprep.exe cambio.' }
    $present = if ($current[$sourceName].Exists) { $sourceName } else { $backupName }
    $prior = if ($Plan.Before[$sourceName].Exists) { $sourceName } else { $backupName }
    if ($current[$present].Hash -cne $Plan.Before[$prior].Hash) { throw 'setupprep.exe cambio durante la operacion; se conserva para revision.' }
    if ($present -ne $prior) {
        Move-AIOBootSetupPrep -Source (Join-Path $Plan.SourcesPath $present) -Destination (Join-Path $Plan.SourcesPath $prior) -State $Plan.Before[$prior] -Media:$Plan.Media
    } elseif (-not $Plan.Media) { Restore-AIOBootFileMetadata -Path (Join-Path $Plan.SourcesPath $prior) -State $Plan.Before[$prior] }
    $manifestPath = Join-Path $Plan.SourcesPath $manifestName
    $currentManifest = $current[$manifestName]
    if ($Plan.ManifestCreated) {
        if ($currentManifest.Hash -cne $Plan.Desired[$manifestName].Hash) { throw 'El registro del renombrado cambio; no se eliminara.' }
        Set-AIOBootOptionFileState -Path $manifestPath -State $Plan.Before[$manifestName] -Media:$Plan.Media
    } else {
        Assert-AIOBootFileState -Path $manifestPath -Expected $Plan.Before[$manifestName] -Current $currentManifest
    }
    Assert-AIOBootWin10Plan -Plan $Plan
    $Plan.NeedsRollback = $false
    $Plan.ManifestCreated = $false
}

function Invoke-AIOBootWin10Plan {
    param($Plan)
    if ($Plan.NeedsRollback) { throw 'Revierte primero el renombrado externo pendiente.' }
    Assert-AIOBootWin10Plan -Plan $Plan
    $Plan.NeedsRollback = $true
    try {
        $manifestName = $Plan.Names[2]
        if (-not $Plan.Before[$manifestName].Exists) {
            $path = Join-Path $Plan.SourcesPath $manifestName
            $bytes = [Convert]::FromBase64String($Plan.Desired[$manifestName].Base64)
            $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $Plan.ManifestCreated = $true
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
            Set-AIOBootEditableAttributes -Path $path -Attributes $Plan.Desired[$manifestName].Attributes
        }
        $from = if ($Plan.Before[$Plan.Names[0]].Exists) { $Plan.Names[0] } else { $Plan.Names[1] }
        $to = if ($Plan.Mode -eq 'Classic') { $Plan.Names[1] } else { $Plan.Names[0] }
        if ($from -ne $to) {
            Move-AIOBootSetupPrep -Source (Join-Path $Plan.SourcesPath $from) -Destination (Join-Path $Plan.SourcesPath $to) -State $Plan.Before[$from] -Media:$Plan.Media
        }
        Assert-AIOBootWin10Plan -Plan $Plan -Applied
    } catch {
        $failure = $_.Exception.Message
        try { Undo-AIOBootWin10Plan -Plan $Plan }
        catch { throw "Fallo el renombrado ($failure) y la reversion ($($_.Exception.Message)). Conserva el respaldo." }
        throw "No se completo el renombrado; estado previo recuperado. $failure"
    }
}

function Complete-AIOBootWin10Plan {
    param($Plan)
    $Plan.NeedsRollback = $false
    Assert-AIOBootWin10Plan -Plan $Plan -Applied
    if ($Plan.Mode -eq 'Original') {
        Remove-AIOBootOperationBackup -Path (Join-Path $Plan.SourcesPath $Plan.Names[2]) -Expected $Plan.Desired[$Plan.Names[2]] -Media:$Plan.Media
        $Plan.Desired[$Plan.Names[2]] = New-AIOBootAbsentFileState
        $Plan.ManifestCreated = $false
        Assert-AIOBootWin10Plan -Plan $Plan -Applied
    }
}

function Get-AIOBootWin10Status {
    param([string]$SourcesPath, [switch]$Media)
    if (-not $SourcesPath) { return 'Medio completo no detectado' }
    try {
        $plan = New-AIOBootWin10Plan -SourcesPath $SourcesPath -Mode Original -Media:$Media
        if ($null -eq $plan) { return 'Sin cambio registrado' }
        if ($plan.Before['setupprep.exe.aio.bak'].Exists) { return 'Clasico Windows 10 activo' }
        return 'Original recuperado; limpieza de respaldo pendiente'
    } catch { return "No verificable: $($_.Exception.Message)" }
}

# =================================================================
# Bypass Win11: solo tres valores LabConfig en el SYSTEM del indice Setup.
# Se edita una COPIA temporal del hive. Nunca HKLM\SYSTEM del equipo anfitrion.
# =================================================================
function Get-AIOBootBypassNames { return @('BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck') }

function Get-AIOBootLabSnapshot {
    param($Root)
    $key = $Root.OpenSubKey('Setup\LabConfig', $false)
    try {
        $values = @(foreach ($name in (Get-AIOBootBypassNames)) {
            $exists = $null -ne $key -and $name -in $key.GetValueNames()
            $kind = ''; $data = $null
            if ($exists) {
                $kind = [string]$key.GetValueKind($name)
                $data = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            }
            [pscustomobject]@{ Name = $name; Exists = $exists; Kind = $kind; Data = $data }
        })
        return [pscustomobject]@{ KeyExists = ($null -ne $key); Values = $values }
    } finally { if ($null -ne $key) { $key.Dispose() } }
}

function Test-AIOBootLabValuesEqual {
    param($Left, $Right)
    # No comparar KeyExists: otros valores/subclaves ajenos pueden mantener LabConfig.
    return (ConvertTo-Json -InputObject @($Left.Values) -Depth 6 -Compress) -ceq (ConvertTo-Json -InputObject @($Right.Values) -Depth 6 -Compress)
}

function Assert-AIOBootLabSnapshot {
    param($Snapshot)
    $names = @(Get-AIOBootBypassNames)
    if ($Snapshot.KeyExists -isnot [bool] -or @($Snapshot.Values).Count -ne $names.Count) { throw 'Respaldo LabConfig incompleto.' }
    for ($i = 0; $i -lt $names.Count; $i++) {
        $entry = $Snapshot.Values[$i]
        if ($entry.Name -cne $names[$i] -or $entry.Exists -isnot [bool]) { throw 'El respaldo LabConfig contiene valores no permitidos.' }
        if ($entry.Exists -and $entry.Kind -notin @('DWord','QWord','String','ExpandString','MultiString','Binary','None')) { throw 'Tipo de registro LabConfig no reconocido.' }
    }
}

function Set-AIOBootLabSnapshot {
    param($Root, $Snapshot)
    Assert-AIOBootLabSnapshot $Snapshot
    $key = $Root.CreateSubKey('Setup\LabConfig')
    try {
        foreach ($entry in $Snapshot.Values) {
            if (-not $entry.Exists) { $key.DeleteValue($entry.Name, $false); continue }
            $data = switch ($entry.Kind) {
                'DWord' { [int]$entry.Data }
                'QWord' { [long]$entry.Data }
                'Binary' { ,([byte[]]$entry.Data) }
                'None' { ,([byte[]]$entry.Data) }
                'MultiString' { ,([string[]]$entry.Data) }
                default { [string]$entry.Data }
            }
            $key.SetValue($entry.Name, $data, [Microsoft.Win32.RegistryValueKind]$entry.Kind)
        }
        $empty = $key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0
        $key.Flush()
    } finally { $key.Dispose() }
    if (-not $Snapshot.KeyExists -and $empty) { $Root.DeleteSubKey('Setup\LabConfig', $false) }
    $Root.Flush()
}

function Invoke-AIOBootBypassHive {
    param([byte[]]$Bytes, $Desired = $null, $Expected = $null)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('AIO-LabConfig-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($temp)
    $path = Join-Path $temp 'SYSTEM'
    $keyName = 'AIO_LabConfig_' + [guid]::NewGuid().ToString('N')
    $loaded = $false; $root = $null; $base = $null
    try {
        [IO.File]::WriteAllBytes($path, $Bytes)
        $reg = Join-Path $env:SystemRoot 'System32\reg.exe'
        $output = & $reg load "HKLM\$keyName" $path 2>&1
        if ($LASTEXITCODE -ne 0) { throw "No se pudo cargar la copia SYSTEM: $output" }
        $loaded = $true
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
        $root = $base.OpenSubKey($keyName, $true)
        if ($null -eq $root) { throw 'No se abrio el hive temporal de Setup.' }
        $snapshot = Get-AIOBootLabSnapshot -Root $root
        if ($null -ne $Expected -and -not (Test-AIOBootLabValuesEqual $snapshot $Expected)) { throw 'LabConfig cambio antes de aplicar la operacion.' }
        if ($null -ne $Desired) {
            Set-AIOBootLabSnapshot -Root $root -Snapshot $Desired
            $snapshot = Get-AIOBootLabSnapshot -Root $root
            if (-not (Test-AIOBootLabValuesEqual $snapshot $Desired)) { throw 'No se verificaron los valores LabConfig.' }
        }
        $root.Dispose(); $root = $null
        $base.Dispose(); $base = $null
        $output = & $reg unload "HKLM\$keyName" 2>&1
        if ($LASTEXITCODE -ne 0) { throw "No se pudo descargar el hive temporal HKLM\${keyName}: $output" }
        $loaded = $false
        return [pscustomobject]@{ Snapshot = $snapshot; Bytes = [IO.File]::ReadAllBytes($path) }
    } finally {
        if ($null -ne $root) { $root.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
        if ($loaded) {
            $null = & $reg unload "HKLM\$keyName" 2>&1
            $loaded = $LASTEXITCODE -ne 0
        }
        if (-not $loaded) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop }
        else { Write-Log -LogLevel ERROR -Message "LabConfig: hive temporal retenido HKLM\$keyName ($path). La imagen no se reemplaza." }
    }
}

function Get-AIOBootLabSnapshotHash {
    param($Snapshot)
    return Get-AIOBootSetupHash -Bytes ([Text.Encoding]::UTF8.GetBytes(($Snapshot | ConvertTo-Json -Depth 8 -Compress)))
}

function Get-AIOBootBypassBackup {
    param([string]$Path)
    $record = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ($record.Schema -ne 3 -or $record.Owner -cne 'AdminImagenOffline.SetupBypass') { throw 'Respaldo de bypass no reconocido.' }
    Assert-AIOBootLabSnapshot $record.Original
    if ($record.OriginalHash -cne (Get-AIOBootLabSnapshotHash $record.Original)) { throw 'El respaldo LabConfig no coincide con su SHA-256.' }
    return $record
}

function Get-AIOBootBypassDesired {
    return [pscustomobject]@{ KeyExists = $true; Values = @(foreach ($name in (Get-AIOBootBypassNames)) {
        [pscustomobject]@{ Name = $name; Exists = $true; Kind = 'DWord'; Data = 1 }
    }) }
}

function Set-AIOBootBypass {
    param([string]$MountPath, [ValidateSet('Enabled','Original')][string]$Mode)
    Assert-AIOBootSetupAvailable -MountPath $MountPath
    $hivePath = Join-Path $MountPath 'Windows\System32\config\SYSTEM'
    $backupPath = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupBypass.json'
    $before = Get-AIOBootSetupFileState -Path $hivePath
    if (-not $before.Exists) { throw 'No se encontro SYSTEM en el indice Setup.' }
    $backupBefore = Get-AIOBootSetupFileState -Path $backupPath
    $read = Invoke-AIOBootBypassHive -Bytes ([Convert]::FromBase64String($before.Base64))
    $original = $read.Snapshot
    $enabled = Get-AIOBootBypassDesired
    if ($backupBefore.Exists) {
        $record = Get-AIOBootBypassBackup -Path $backupPath
        $original = $record.Original
        if (-not (Test-AIOBootLabValuesEqual $read.Snapshot $enabled) -and
            -not (Test-AIOBootLabValuesEqual $read.Snapshot $original)) { throw 'Los bypass cambiaron fuera del administrador. Se conserva el respaldo.' }
    } elseif ($Mode -eq 'Original') { throw 'No existe un respaldo de bypass para restaurar.' }
    $desired = if ($Mode -eq 'Enabled') { $enabled } else { $original }
    $edited = Invoke-AIOBootBypassHive -Bytes ([Convert]::FromBase64String($before.Base64)) -Expected $read.Snapshot -Desired $desired
    $next = [pscustomobject]@{ Exists = $true; Base64 = [Convert]::ToBase64String($edited.Bytes)
        Hash = Get-AIOBootSetupHash $edited.Bytes; Attributes = $before.Attributes; Sddl = $before.Sddl }
    $backupCreated = $false; $hiveTouched = $false
    try {
        Assert-AIOBootFileState -Path $hivePath -Expected $before -Current (Get-AIOBootSetupFileState $hivePath)
        if ($Mode -eq 'Enabled' -and -not $backupBefore.Exists) {
            $record = [pscustomobject]@{ Schema = 3; Owner = 'AdminImagenOffline.SetupBypass'; Original = $original; OriginalHash = Get-AIOBootLabSnapshotHash $original }
            $bytes = [Text.Encoding]::UTF8.GetBytes(($record | ConvertTo-Json -Depth 8))
            $stream = [IO.File]::Open($backupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
            $backupCreated = $true
            try { $stream.Write($bytes, 0, $bytes.Length) } finally { $stream.Dispose() }
        }
        $hiveTouched = $true
        Set-AIOBootSetupFileState -Path $hivePath -State $next
        $expected = [pscustomobject]@{ Mode = $Mode; Values = $desired
            Backup = Get-AIOBootSetupFileState -Path $backupPath }
        # Reabrir el SYSTEM escrito y validar antes de borrar los datos de recuperacion.
        Assert-AIOBootBypassConfiguration -MountPath $MountPath -Expected $expected
        if ($Mode -eq 'Original') {
            Remove-AIOBootOperationBackup -Path $backupPath -Expected $backupBefore
            $expected.Backup = New-AIOBootAbsentFileState
        }
    } catch {
        $failure = $_.Exception.Message
        try {
            if ($hiveTouched) { Set-AIOBootSetupFileState -Path $hivePath -State $before }
            if ($backupCreated -or ($Mode -eq 'Original' -and $hiveTouched)) { Set-AIOBootSetupFileState -Path $backupPath -State $backupBefore }
        } catch { throw "Fallo el bypass ($failure) y la reversion ($($_.Exception.Message)). Descarta el montaje." }
        throw "No se aplico el bypass; estado anterior recuperado. $failure"
    }
    Write-Log -LogLevel INFO -Message "BootSetup: LabConfig $Mode preparado y verificado en el SYSTEM offline."
    return $expected
}

function Assert-AIOBootBypassConfiguration {
    param([string]$MountPath, $Expected)
    $bytes = [IO.File]::ReadAllBytes((Join-Path $MountPath 'Windows\System32\config\SYSTEM'))
    $read = Invoke-AIOBootBypassHive -Bytes $bytes
    if (-not (Test-AIOBootLabValuesEqual $read.Snapshot $Expected.Values)) { throw 'LabConfig cambio despues de configurar los bypass. No se guardara.' }
    $path = Join-Path $MountPath 'Windows\System32\AdminImagenOffline.SetupBypass.json'
    Assert-AIOBootFileState -Path $path -Expected $Expected.Backup -Current (Get-AIOBootSetupFileState -Path $path)
}

function Get-AIOBootBypassStatus {
    param([string]$MountPath)
    try {
        $read = Invoke-AIOBootBypassHive -Bytes ([IO.File]::ReadAllBytes((Join-Path $MountPath 'Windows\System32\config\SYSTEM')))
        $count = @($read.Snapshot.Values | Where-Object { $_.Exists -and $_.Kind -eq 'DWord' -and $_.Data -eq 1 }).Count
        return "$count de 3 bypass activos (TPM, Secure Boot y RAM)"
    } catch { return "No verificable: $($_.Exception.Message)" }
}

# =================================================================
# Sesion compartida con Environments. Se muta el mismo objeto para conservar
# expectativas, errores y plan externo entre aperturas y eventos WinForms.
# =================================================================
function New-AIOBootSetupSession {
    param(
        [Parameter(Mandatory=$true)][string]$MountPath,
        [Parameter(Mandatory=$true)][string]$BootPath,
        [switch]$IsSetupIndex
    )
    return [pscustomobject]@{
        MountPath = $MountPath; BootPath = $BootPath; IsSetupIndex = [bool]$IsSetupIndex
        MediaSources = if ($IsSetupIndex) { Get-AIOBootMediaSources -BootPath $BootPath } else { $null }
        SetupExpected = $null; BackgroundExpected = $null; MediaBackgroundPlan = $null
        SetupEditFailed = $false; BackgroundEditFailed = $false
        SetupError = ''; BackgroundError = ''; SelectedImagePath = ''
        Win10Expected = $null; MediaWin10Plan = $null; Win10EditFailed = $false; Win10Error = ''
        BypassExpected = $null; BypassEditFailed = $false; BypassError = ''
    }
}

function Assert-AIOBootSetupSessionEditable {
    param([Parameter(Mandatory=$true)]$Session)
    if (-not $Session.IsSetupIndex -or -not (Test-Path -LiteralPath $Session.MountPath -PathType Container)) {
        throw 'Selecciona y monta el indice de instalacion de boot.wim desde Modulo-Environments.'
    }
}

function Set-AIOBootSetupSessionMode {
    param([Parameter(Mandatory=$true)]$Session, [ValidateSet('Legacy','Original')][string]$Mode)
    try {
        Assert-AIOBootSetupSessionEditable -Session $Session
        $Session.SetupExpected = Set-AIOBootSetupMode -MountPath $Session.MountPath -Mode $Mode
        $Session.SetupEditFailed = $false
        $Session.SetupError = ''
    } catch {
        $Session.SetupEditFailed = $true
        $Session.SetupError = $_.Exception.Message
        throw
    }
}

function Set-AIOBootSetupSessionBackground {
    param(
        [Parameter(Mandatory=$true)]$Session,
        [ValidateSet('Custom','Original')][string]$Mode,
        [string]$ImagePath
    )
    try {
        Assert-AIOBootSetupSessionEditable -Session $Session
        Undo-AIOBootSetupExternalChanges -Session $Session
        # Validar el externo antes de tocar el montaje. Publicar el nuevo plan
        # solo despues del exito interno; un fallo bloquea el Commit.
        $nextMediaPlan = New-AIOBootMediaBackgroundPlan -SourcesPath $Session.MediaSources -Mode $Mode -ImagePath $ImagePath
        if ($Mode -eq 'Original' -and $null -ne $nextMediaPlan -and
            -not (Test-Path -LiteralPath (Join-Path $Session.MountPath 'Windows\System32\AdminImagenOffline.SetupBackground.json'))) {
            $nextExpected = $null
        } else {
            $nextExpected = Set-AIOBootBackground -MountPath $Session.MountPath -Mode $Mode -ImagePath $ImagePath
        }
        $Session.BackgroundExpected = $nextExpected
        $Session.MediaBackgroundPlan = $nextMediaPlan
        $Session.BackgroundEditFailed = $false
        $Session.BackgroundError = ''
        if ($Mode -eq 'Original') { $Session.SelectedImagePath = '' }
        else { $Session.SelectedImagePath = $ImagePath }
    } catch {
        $Session.BackgroundEditFailed = $true
        $Session.BackgroundError = $_.Exception.Message
        throw
    }
}

function Set-AIOBootSetupSessionWin10 {
    param($Session, [ValidateSet('Classic','Original')][string]$Mode)
    try {
        Assert-AIOBootSetupSessionEditable -Session $Session
        Assert-AIOBootSetupAvailable -MountPath $Session.MountPath
        if ($Mode -eq 'Classic' -and -not $Session.MediaSources) {
            throw 'Selecciona sources\boot.wim desde el medio completo para renombrar setupprep.exe en ambas ubicaciones.'
        }
        Undo-AIOBootSetupExternalChanges -Session $Session
        $media = New-AIOBootWin10Plan -SourcesPath $Session.MediaSources -Mode $Mode -Media
        $internal = New-AIOBootWin10Plan -SourcesPath (Join-Path $Session.MountPath 'sources') -Mode $Mode
        if ($null -eq $internal -and $null -eq $media) { throw 'No hay renombrados registrados para restaurar.' }
        $expected = $null
        if ($null -ne $internal) {
            Invoke-AIOBootWin10Plan -Plan $internal
            Complete-AIOBootWin10Plan -Plan $internal
            $expected = $internal
        }
        $Session.Win10Expected = $expected
        $Session.MediaWin10Plan = $media
        $Session.Win10EditFailed = $false
        $Session.Win10Error = ''
        Write-Log -LogLevel INFO -Message "BootSetup: Renombrado estilo Windows 10 $Mode preparado; externo pendiente de Commit."
    } catch {
        $Session.Win10EditFailed = $true
        $Session.Win10Error = $_.Exception.Message
        throw
    }
}

function Set-AIOBootSetupSessionBypass {
    param($Session, [ValidateSet('Enabled','Original')][string]$Mode)
    try {
        Assert-AIOBootSetupSessionEditable -Session $Session
        $Session.BypassExpected = Set-AIOBootBypass -MountPath $Session.MountPath -Mode $Mode
        $Session.BypassEditFailed = $false
        $Session.BypassError = ''
    } catch {
        $Session.BypassEditFailed = $true
        $Session.BypassError = $_.Exception.Message
        throw
    }
}

function Invoke-AIOBootSetupPreCommit {
    param([Parameter(Mandatory=$true)]$Session)
    if ($Session.SetupEditFailed -or $Session.BackgroundEditFailed -or $Session.Win10EditFailed -or $Session.BypassEditFailed) {
        throw 'Hay una operacion de Setup, bypass o fondo fallida. Abre la GUI y repite la operacion correctamente, o elige N para descartar.'
    }
    if ($null -ne $Session.SetupExpected) { Assert-AIOBootSetupConfiguration -MountPath $Session.MountPath -Expected $Session.SetupExpected }
    if ($null -ne $Session.BackgroundExpected) { Assert-AIOBootBackgroundConfiguration -MountPath $Session.MountPath -Expected $Session.BackgroundExpected }
    if ($null -ne $Session.Win10Expected) { Assert-AIOBootWin10Plan -Plan $Session.Win10Expected -Applied }
    if ($null -ne $Session.BypassExpected) { Assert-AIOBootBypassConfiguration -MountPath $Session.MountPath -Expected $Session.BypassExpected }
    # Validar TODOS los planes antes de la primera escritura externa.
    if ($null -ne $Session.MediaWin10Plan) { Assert-AIOBootWin10Plan -Plan $Session.MediaWin10Plan }
    if ($null -ne $Session.MediaBackgroundPlan) { Assert-AIOBootMediaBackgroundPlan -Plan $Session.MediaBackgroundPlan }
    try {
        if ($null -ne $Session.MediaWin10Plan) { Invoke-AIOBootWin10Plan -Plan $Session.MediaWin10Plan }
        if ($null -ne $Session.MediaBackgroundPlan) { Invoke-AIOBootMediaBackgroundPlan -Plan $Session.MediaBackgroundPlan }
    } catch {
        $failure = $_.Exception.Message
        try { Undo-AIOBootSetupExternalChanges -Session $Session }
        catch { throw "No se prepararon los externos ($failure). Reversion pendiente: $($_.Exception.Message)" }
        throw $failure
    }
}

function Complete-AIOBootSetupCommit {
    param([Parameter(Mandatory=$true)]$Session)
    # DISM ya confirmo: ninguna falla de limpieza puede revertir un externo.
    foreach ($plan in @($Session.MediaWin10Plan, $Session.MediaBackgroundPlan)) {
        if ($null -ne $plan) { $plan.NeedsRollback = $false }
    }
    $failures = @()
    if ($null -ne $Session.MediaWin10Plan) {
        try { Complete-AIOBootWin10Plan -Plan $Session.MediaWin10Plan } catch { $failures += $_.Exception.Message }
    }
    if ($null -ne $Session.MediaBackgroundPlan) {
        try { Complete-AIOBootMediaBackgroundPlan -Plan $Session.MediaBackgroundPlan } catch { $failures += $_.Exception.Message }
    }
    if ($failures.Count -gt 0) { throw ($failures -join '; ') }
    # Ya no quedan planes pendientes ni copias de recuperacion de esta sesion.
    foreach ($name in @('SetupExpected','BackgroundExpected','Win10Expected','BypassExpected','MediaWin10Plan','MediaBackgroundPlan')) {
        $Session.$name = $null
    }
    $Session.SelectedImagePath = ''
}

function Undo-AIOBootSetupExternalChanges {
    param([Parameter(Mandatory=$true)]$Session)
    $failures = @()
    if ($null -ne $Session.MediaBackgroundPlan -and $Session.MediaBackgroundPlan.NeedsRollback) {
        try { Undo-AIOBootMediaBackgroundPlan -Plan $Session.MediaBackgroundPlan }
        catch {
            $Session.BackgroundEditFailed = $true
            $Session.BackgroundError = $_.Exception.Message
            $failures += $_.Exception.Message
        }
    }
    if ($null -ne $Session.MediaWin10Plan -and $Session.MediaWin10Plan.NeedsRollback) {
        try { Undo-AIOBootWin10Plan -Plan $Session.MediaWin10Plan }
        catch {
            $Session.Win10EditFailed = $true
            $Session.Win10Error = $_.Exception.Message
            $failures += $_.Exception.Message
        }
    }
    if ($failures.Count -gt 0) { throw ($failures -join '; ') }
}

function Get-AIOBootSetupSessionSummary {
    param([Parameter(Mandatory=$true)]$Session)
    $lines = @()
    if ($null -ne $Session.SetupExpected) {
        $mode = if ($Session.SetupExpected.Mode -in @('Legacy')) { 'Legacy' } else { 'original' }
        $lines += "Setup $mode preparado, pendiente de guardar."
    }
    if ($null -ne $Session.BackgroundExpected) {
        $mode = if ($Session.BackgroundExpected.Mode -eq 'Custom') { 'personalizado' } else { 'original' }
        $lines += "Fondo interno $mode preparado, pendiente de guardar."
        $skipped = @($Session.BackgroundExpected.Files | Where-Object { Get-AIOBootBackgroundSkipReason $_ }).Count
        if ($skipped -gt 0) { $lines += "Personalizacion parcial: $skipped DLL internas sin fondo 517 reconocido; conservadas." }
    }
    if ($null -ne $Session.MediaBackgroundPlan) {
        $skipped = @($Session.MediaBackgroundPlan.Files | Where-Object { Get-AIOBootBackgroundSkipReason $_ }).Count
        $prepared = @($Session.MediaBackgroundPlan.Files).Count - $skipped
        $lines += "Medio externo: $prepared archivo(s) preparados, pendientes de guardar."
        if ($skipped -gt 0) { $lines += "Personalizacion parcial: $skipped DLL externas sin fondo 517 reconocido; conservadas." }
        if ($Session.MediaBackgroundPlan.NeedsRollback) { $lines += 'El medio externo requiere reversion antes de continuar.' }
    }
    if ($null -ne $Session.Win10Expected -or $null -ne $Session.MediaWin10Plan) {
        $plan = if ($null -ne $Session.Win10Expected) { $Session.Win10Expected } else { $Session.MediaWin10Plan }
        $label = if ($plan.Mode -eq 'Classic') { 'renombrado' } else { 'restauracion' }
        $lines += "Setup estilo Windows 10: $label preparado; pendiente de guardar."
    }
    if ($null -ne $Session.BypassExpected) {
        $label = if ($Session.BypassExpected.Mode -eq 'Enabled') { 'activados' } else { 'restaurados' }
        $lines += "Bypass TPM, Secure Boot y RAM: $label en el montaje; pendiente de guardar."
    }
    if ($Session.Win10EditFailed) { $lines += "ERROR estilo Windows 10 (guardado bloqueado): $($Session.Win10Error)" }
    if ($Session.BypassEditFailed) { $lines += "ERROR de bypass (guardado bloqueado): $($Session.BypassError)" }
    if ($Session.SetupEditFailed) { $lines += "ERROR de Setup (guardado bloqueado): $($Session.SetupError)" }
    if ($Session.BackgroundEditFailed) { $lines += "ERROR de fondo (guardado bloqueado): $($Session.BackgroundError)" }
    if ($lines.Count -eq 0) { $lines += 'Sin cambios de Setup, bypass o fondo preparados en esta sesion.' }
    return ($lines -join "`r`n")
}

# =================================================================
# Interfaz WinForms. Cerrar solo vuelve al menu; nunca guarda ni descarta.
# =================================================================
function Show-BootSetup-GUI {
    param([Parameter(Mandatory=$true)]$Session)
    Assert-AIOBootSetupSessionEditable -Session $Session
    if ($Script:IMAGE_MOUNTED -ne 1 -or $Script:MOUNT_DIR -ne $Session.MountPath -or $Script:WIM_FILE_PATH -ne $Session.BootPath) {
        throw 'La sesion de Setup no corresponde al boot.wim actualmente montado.'
    }
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
    Add-Type -AssemblyName System.Drawing -ErrorAction Stop
    $view = [pscustomobject]@{ Busy = $false }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Setup Legacy, clasico Windows 10 y fondos - boot.wim'
    $form.AutoScaleDimensions = New-Object Drawing.SizeF(96,96)
    $form.AutoScaleMode = 'Dpi'
    $form.ClientSize = New-Object Drawing.Size(1080,720)
    $form.MinimumSize = $form.Size
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [Drawing.Color]::FromArgb(30,30,30)
    $form.ForeColor = [Drawing.Color]::WhiteSmoke
    $uiFont = New-Object Drawing.Font('Segoe UI',9)
    $titleFont = New-Object Drawing.Font('Segoe UI',14,[Drawing.FontStyle]::Bold)
    $form.Font = $uiFont
    $tips = New-Object Windows.Forms.ToolTip
    $tips.AutoPopDelay = 14000
    $tips.InitialDelay = 350
    $tips.ReshowDelay = 100
    $tips.ShowAlways = $true

    function New-SetupLabel {
        param($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height)
        $control = New-Object Windows.Forms.Label
        $control.Text = $Text
        $control.Location = New-Object Drawing.Point($X,$Y)
        $control.Size = New-Object Drawing.Size($Width,$Height)
        $Parent.Controls.Add($control)
        return $control
    }
    function New-SetupButton {
        param($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[string]$Tip,[switch]$Primary)
        $control = New-Object Windows.Forms.Button
        $control.Text = $Text
        $control.Location = New-Object Drawing.Point($X,$Y)
        $control.Size = New-Object Drawing.Size($Width,34)
        $control.FlatStyle = 'Flat'
        $control.FlatAppearance.BorderSize = 0
        $control.BackColor = if ($Primary) { [Drawing.Color]::RoyalBlue } else { [Drawing.Color]::FromArgb(65,65,68) }
        $control.ForeColor = [Drawing.Color]::White
        $tips.SetToolTip($control,$Tip)
        $Parent.Controls.Add($control)
        return $control
    }
    function New-SetupGroup {
        param($Parent,[string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height)
        $control = New-Object Windows.Forms.GroupBox
        $control.Text = $Text
        $control.Location = New-Object Drawing.Point($X,$Y)
        $control.Size = New-Object Drawing.Size($Width,$Height)
        $control.ForeColor = $form.ForeColor
        $Parent.Controls.Add($control)
        return $control
    }

    $title = New-SetupLabel $form 'Personalizar Windows Setup' 18 12 1040 30
    $title.Font = $titleFont
    $target = New-SetupLabel $form ("boot.wim: $($Session.BootPath)`r`nMontaje: $($Session.MountPath)") 18 45 1040 32
    $target.Anchor = 'Top,Left,Right'
    $target.AutoEllipsis = $true
    $target.ForeColor = [Drawing.Color]::Silver
    $tips.SetToolTip($target,$target.Text)

    $tabs = New-Object Windows.Forms.TabControl
    $tabs.Location = New-Object Drawing.Point(18,84)
    $tabs.Size = New-Object Drawing.Size(520,490)
    $tabs.Anchor = 'Top,Bottom,Left'
    $form.Controls.Add($tabs)
    $pageSetup = New-Object Windows.Forms.TabPage
    $pageSetup.Text = 'Inicio y requisitos'
    $pageBackground = New-Object Windows.Forms.TabPage
    $pageBackground.Text = 'Fondo de instalacion'
    foreach ($page in @($pageSetup,$pageBackground)) {
        $page.BackColor = $form.BackColor
        $page.ForeColor = $form.ForeColor
        $page.AutoScroll = $true
        $tabs.TabPages.Add($page)
    }
    $tips.SetToolTip($tabs,'Configura el inicio y los requisitos, o abre la pestana Fondo de instalacion.')
    if (Get-Command Set-AIOTabControlStyle -ErrorAction SilentlyContinue) { Set-AIOTabControlStyle -TabControl $tabs }

    $legacyGroup = New-SetupGroup $pageSetup 'Setup Legacy' 10 10 488 130
    $legacyStatus = New-SetupLabel $legacyGroup '' 12 23 464 20
    $null = New-SetupLabel $legacyGroup 'Inicia el instalador con /legacy. El cambio conserva el inicio original para poder restaurarlo.' 12 46 464 34
    $btnLegacy = New-SetupButton $legacyGroup 'Activar Setup Legacy' 12 87 222 'Configura winpeshl.ini: [LaunchApps] seguido de %SYSTEMDRIVE%\setup.exe, /legacy. No cambia BIOS/UEFI.' -Primary
    $btnOriginal = New-SetupButton $legacyGroup 'Restaurar inicio original' 247 87 228 'Recupera el inicio original y elimina su respaldo al verificar la restauracion.'

    $win10Group = New-SetupGroup $pageSetup 'Setup clasico estilo Windows 10' 10 150 488 152
    $win10Status = New-SetupLabel $win10Group '' 12 22 464 32
    $win10Status.AutoEllipsis = $true
    $null = New-SetupLabel $win10Group 'Renombra setupprep.exe en sources del indice y del medio. Necesita el medio completo; permite restaurar ambos.' 12 60 464 36
    $btnWin10 = New-SetupButton $win10Group 'Activar estilo Windows 10' 12 106 222 'Renombra a setupprep.exe.aio.bak. El indice cambia al preparar; el medio externo cambia al guardar. Esta opcion es independiente de Legacy.' -Primary
    $btnRestoreWin10 = New-SetupButton $win10Group 'Restaurar setupprep.exe' 247 106 228 'Devuelve el nombre original en ambas ubicaciones y conserva cualquier archivo ajeno al respaldo.'

    $bypassGroup = New-SetupGroup $pageSetup 'Requisitos de Windows 11' 10 312 488 134
    $bypassStatus = New-SetupLabel $bypassGroup '' 12 22 464 20
    $bypassStatus.AutoEllipsis = $true
    $null = New-SetupLabel $bypassGroup 'Integra los bypass de TPM, Secure Boot y RAM para instalar al arrancar desde este medio.' 12 47 464 32
    $btnBypass = New-SetupButton $bypassGroup 'Integrar bypass Win11' 12 89 222 'Activa los tres valores LabConfig en el SYSTEM offline del indice. No modifica el registro del equipo anfitrion ni elimina limites fisicos de CPU.' -Primary
    $btnRestoreBypass = New-SetupButton $bypassGroup 'Restaurar requisitos' 247 89 228 'Restaura los valores previos de TPM, Secure Boot y RAM; si no existian, los elimina. Respeta otros valores del registro.'

    $backgroundStatus = New-SetupLabel $pageBackground '' 14 18 480 24
    $mediaStatus = New-SetupLabel $pageBackground '' 14 50 480 56
    $mediaStatus.AutoEllipsis = $true
    $null = New-SetupLabel $pageBackground 'Elige un PNG, JPG o BMP de hasta 64 megapixeles. Recomendado: 1024 x 768 (4:3).' 14 116 480 38
    $imagePath = New-Object Windows.Forms.TextBox
    $imagePath.Location = New-Object Drawing.Point(14,165)
    $imagePath.Size = New-Object Drawing.Size(480,25)
    $imagePath.ReadOnly = $true
    $imagePath.BackColor = [Drawing.Color]::FromArgb(45,45,48)
    $imagePath.ForeColor = $form.ForeColor
    $pageBackground.Controls.Add($imagePath)
    $tips.SetToolTip($imagePath,'Ruta de la imagen elegida. Seleccionarla solo actualiza la vista previa; pulsa Preparar fondo para aplicarla al montaje.')
    $btnBrowse = New-SetupButton $pageBackground 'Elegir imagen...' 14 204 200 'Selecciona la imagen y muestra su vista previa. Cancelar conserva la seleccion anterior.'
    $btnBackground = New-SetupButton $pageBackground 'Preparar fondo elegido' 14 254 230 'Convierte y prepara los fondos compatibles, conservando formato, permisos y respaldos. El externo se escribe al guardar.' -Primary
    $btnRestoreBackground = New-SetupButton $pageBackground 'Restaurar fondo original' 258 254 236 'Restaura los fondos internos y externos respaldados. No modifica las opciones de inicio ni los bypass.'
    $null = New-SetupLabel $pageBackground 'La imagen se ajusta completa y centrada, sin deformar. Las DLL sin recurso de fondo compatible se conservan y aparecen en el resumen.' 14 308 480 53
    $null = New-SetupLabel $pageBackground 'La silueta de la derecha es una referencia visual. No forma parte de la imagen que se integra.' 14 383 480 42

    $previewGroup = New-SetupGroup $form 'Vista previa ampliada' 553 84 509 490
    $previewGroup.Anchor = 'Top,Bottom,Left,Right'
    $preview = New-Object Windows.Forms.PictureBox
    $preview.Location = New-Object Drawing.Point(14,32)
    $preview.Size = New-Object Drawing.Size(480,360)
    $preview.Anchor = 'Top,Bottom,Left,Right'
    $preview.BackColor = [Drawing.Color]::Black
    $preview.BorderStyle = 'FixedSingle'
    $preview.SizeMode = 'Zoom'
    $previewGroup.Controls.Add($preview)
    $tips.SetToolTip($preview,'Vista orientativa en 4:3. El aspecto final depende de la version de Setup, la resolucion y los recursos del medio.')
    $chkWizard = New-Object Windows.Forms.CheckBox
    $chkWizard.Text = 'Mostrar silueta del asistente (simulacion)'
    $chkWizard.Location = New-Object Drawing.Point(14,407)
    $chkWizard.Size = New-Object Drawing.Size(480,25)
    $chkWizard.Anchor = 'Bottom,Left,Right'
    $chkWizard.Checked = $true
    $previewGroup.Controls.Add($chkWizard)
    $tips.SetToolTip($chkWizard,'Superpone una silueta dibujada del asistente para valorar el fondo. Se puede ocultar y nunca se guarda dentro de la imagen.')
    $previewCaption = New-SetupLabel $previewGroup '' 14 441 480 36
    $previewCaption.Anchor = 'Bottom,Left,Right'
    $previewCaption.ForeColor = [Drawing.Color]::Silver

    $summary = New-Object Windows.Forms.TextBox
    $summary.Location = New-Object Drawing.Point(18,586)
    $summary.Size = New-Object Drawing.Size(1044,82)
    $summary.Anchor = 'Bottom,Left,Right'
    $summary.Multiline = $true; $summary.ReadOnly = $true; $summary.ScrollBars = 'Vertical'
    $summary.BackColor = [Drawing.Color]::FromArgb(40,40,43)
    $summary.ForeColor = [Drawing.Color]::LightBlue
    $form.Controls.Add($summary)
    $tips.SetToolTip($summary,'Cambios pendientes, omisiones y errores. Un error de operacion bloquea guardar hasta corregirlo o descartar el montaje.')
    $saveHint = New-SetupLabel $form 'Al volver: T y S para guardar, o T y N para descartar.' 18 685 655 22
    $saveHint.Anchor = 'Bottom,Left,Right'
    $btnRefresh = New-SetupButton $form 'Actualizar estado' 702 677 158 'Vuelve a leer el estado de los archivos, respaldos y bypass del montaje.'
    $btnRefresh.Anchor = 'Bottom,Right'
    $btnClose = New-SetupButton $form 'Volver al menu' 875 677 187 'Cierra la ventana y conserva los cambios pendientes. Desde el menu puedes guardar o descartar.' -Primary
    $btnClose.Anchor = 'Bottom,Right'; $btnClose.DialogResult = 'Cancel'; $form.CancelButton = $btnClose

    function Update-SetupView {
        $state = Get-AIOBootLegacySetupStatus -MountPath $Session.MountPath
        $legacyStatus.Text = $state.Label
        $legacyStatus.ForeColor = if ($state.Color -eq 'Green') { [Drawing.Color]::LightGreen } else { [Drawing.Color]::Silver }
        $btnOriginal.Enabled = Test-Path -LiteralPath (Join-Path $Session.MountPath 'Windows\System32\AdminImagenOffline.SetupLegacy.json')
        $tips.SetToolTip($legacyStatus,'Indica si winpeshl.ini inicia Setup con /legacy o conserva otro lanzador.')
        $internal = Get-AIOBootWin10Status -SourcesPath (Join-Path $Session.MountPath 'sources')
        $external = Get-AIOBootWin10Status -SourcesPath $Session.MediaSources -Media
        $win10Status.Text = "Indice: $internal`r`nMedio: $external"
        $tips.SetToolTip($win10Status,$win10Status.Text)
        $btnWin10.Enabled = -not [string]::IsNullOrWhiteSpace($Session.MediaSources)
        $hasWin10 = Test-Path -LiteralPath (Join-Path $Session.MountPath 'sources\AdminImagenOffline.SetupWin10.json')
        if ($Session.MediaSources) { $hasWin10 = $hasWin10 -or (Test-Path -LiteralPath (Join-Path $Session.MediaSources 'AdminImagenOffline.SetupWin10.json')) }
        $btnRestoreWin10.Enabled = $hasWin10
        $bypassStatus.Text = Get-AIOBootBypassStatus -MountPath $Session.MountPath
        $tips.SetToolTip($bypassStatus,$bypassStatus.Text)
        $btnRestoreBypass.Enabled = Test-Path -LiteralPath (Join-Path $Session.MountPath 'Windows\System32\AdminImagenOffline.SetupBypass.json')
        $state = Get-AIOBootBackgroundStatus -MountPath $Session.MountPath
        $backgroundStatus.Text = "Fondo interno: $($state.Label)"
        $hasBackground = Test-Path -LiteralPath (Join-Path $Session.MountPath 'Windows\System32\AdminImagenOffline.SetupBackground.json')
        if ($Session.MediaSources) {
            $state = Get-AIOBootBackgroundStatus -MountPath $Session.MediaSources -Media
            $mediaStatus.Text = "Fondo externo: $($state.Label)`r`n$($Session.MediaSources)"
            $hasBackground = $hasBackground -or (Test-Path -LiteralPath (Join-Path $Session.MediaSources 'AdminImagenOffline.SetupMediaBackground.json'))
        } else { $mediaStatus.Text = 'boot.wim aislado: los fondos se modifican solo dentro del indice. Para estilo Windows 10 abre sources\boot.wim del medio completo.' }
        $tips.SetToolTip($mediaStatus,$mediaStatus.Text)
        $tips.SetToolTip($backgroundStatus,'Estado verificado de los fondos internos. PARCIAL indica DLL conservadas sin recurso 517 compatible.')
        $btnRestoreBackground.Enabled = $hasBackground
        $btnBackground.Enabled = -not [string]::IsNullOrWhiteSpace($Session.SelectedImagePath)
        $imagePath.Text = $Session.SelectedImagePath
        $summary.Text = Get-AIOBootSetupSessionSummary -Session $Session
        $hasError = $Session.SetupEditFailed -or $Session.BackgroundEditFailed -or $Session.Win10EditFailed -or $Session.BypassEditFailed
        $summary.ForeColor = if ($hasError) { [Drawing.Color]::Salmon } else { [Drawing.Color]::LightBlue }
    }

    function Set-SetupPreview {
        param([string]$Path)
        $source = $null; $bitmap = $null; $graphics = $null
        try {
            $bitmap = [Drawing.Bitmap]::new(1024,768)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $graphics.Clear([Drawing.Color]::FromArgb(32,35,74))
            $caption = 'Fondo de referencia. Elige una imagen en Fondo de instalacion.'
            if ($Path) {
                $source = [Drawing.Image]::FromFile($Path)
                $formats = @([Drawing.Imaging.ImageFormat]::Jpeg.Guid,[Drawing.Imaging.ImageFormat]::Png.Guid,[Drawing.Imaging.ImageFormat]::Bmp.Guid)
                if ($source.RawFormat.Guid -notin $formats -or ([long]$source.Width * $source.Height) -gt 64000000) { throw 'Selecciona PNG, JPG o BMP de hasta 64 megapixeles.' }
                $graphics.Clear([Drawing.Color]::Black)
                $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $scale = [Math]::Min(1024.0/$source.Width,768.0/$source.Height)
                $width = [int][Math]::Round($source.Width*$scale); $height = [int][Math]::Round($source.Height*$scale)
                $graphics.DrawImage($source,[Drawing.Rectangle]::new([int]((1024-$width)/2),[int]((768-$height)/2),$width,$height))
                $caption = "Imagen: $($source.Width) x $($source.Height) px. Simulacion en 4:3."
            }
            $old = $preview.Image; $preview.Image = $bitmap; $bitmap = $null
            if ($null -ne $old) { $old.Dispose() }
            $previewCaption.Text = $caption
            $preview.Invalidate()
        } finally {
            if ($null -ne $graphics) { $graphics.Dispose() }
            if ($null -ne $bitmap) { $bitmap.Dispose() }
            if ($null -ne $source) { $source.Dispose() }
        }
    }

    $preview.Add_Paint({
        param($sender,$eventArgs)
        if (-not $chkWizard.Checked) { return }
        $g = $eventArgs.Graphics; $saved = $g.Save(); $resources = @()
        try {
            $scale = [Math]::Min($sender.ClientSize.Width/1024.0,$sender.ClientSize.Height/768.0)
            if ($scale -le 0) { return }
            $g.TranslateTransform([single](($sender.ClientSize.Width-1024*$scale)/2),[single](($sender.ClientSize.Height-768*$scale)/2))
            $g.ScaleTransform([single]$scale,[single]$scale)
            $body = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(200,245,247,252))
            $header = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(230,37,53,89))
            $ink = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(28,38,58))
            $white = [Drawing.SolidBrush]::new([Drawing.Color]::White)
            $blue = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(0,120,215))
            $border = [Drawing.Pen]::new([Drawing.Color]::FromArgb(220,230,238,250),2)
            $font = [Drawing.Font]::new('Segoe UI',22,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            $large = [Drawing.Font]::new('Segoe UI',36,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            $resources = @($body,$header,$ink,$white,$blue,$border,$font,$large)
            $g.FillRectangle($body,154,115,716,522)
            $g.FillRectangle($header,154,115,716,48)
            $g.DrawRectangle($border,154,115,716,522)
            $g.DrawString('Programa de instalacion de Windows',$font,$white,174,124)
            $g.DrawString('x',$font,$white,835,124)
            foreach ($point in @(@(354,225),@(395,225),@(354,266),@(395,266))) { $g.FillRectangle($blue,[int]$point[0],[int]$point[1],35,35) }
            $g.DrawString('Windows',$large,$ink,446,241)
            $g.FillRectangle($blue,365,380,294,64)
            $g.DrawString('Instalar ahora',$font,$white,432,397)
            $g.DrawString('Reparar el equipo',$font,$ink,187,578)
            $g.DrawString('Silueta orientativa',$font,$ink,637,578)
        } finally {
            foreach ($resource in $resources) { $resource.Dispose() }
            $g.Restore($saved)
        }
    })
    $chkWizard.Add_CheckedChanged({ $preview.Invalidate() })

    function Invoke-SetupUIAction {
        param([scriptblock]$Action,[string]$Description)
        if ($view.Busy) { return }
        $view.Busy = $true; $form.UseWaitCursor = $true
        foreach ($control in @($tabs,$btnRefresh,$btnClose)) { $control.Enabled = $false }
        $summary.Text = "$Description..."; $form.Refresh()
        try { $ErrorActionPreference = 'Stop'; & $Action }
        catch {
            Write-Log -LogLevel ERROR -Message "BootSetupGUI: ${Description}: $($_.Exception.Message)"
            [void][Windows.Forms.MessageBox]::Show($form,($_.Exception.Message + "`r`n`r`nRevisa el resumen. Para descartar: vuelve al menu y elige T y N."),'Setup y fondos','OK','Error')
        } finally {
            try { Update-SetupView }
            finally {
                $view.Busy = $false; $form.UseWaitCursor = $false
                foreach ($control in @($tabs,$btnRefresh,$btnClose)) { $control.Enabled = $true }
            }
        }
    }
    $btnLegacy.Add_Click({ Invoke-SetupUIAction -Description 'Preparando Setup Legacy' -Action { Set-AIOBootSetupSessionMode -Session $Session -Mode Legacy } })
    $btnOriginal.Add_Click({ Invoke-SetupUIAction -Description 'Restaurando inicio' -Action { Set-AIOBootSetupSessionMode -Session $Session -Mode Original } })
    $btnWin10.Add_Click({ Invoke-SetupUIAction -Description 'Preparando estilo Windows 10' -Action { Set-AIOBootSetupSessionWin10 -Session $Session -Mode Classic } })
    $btnRestoreWin10.Add_Click({ Invoke-SetupUIAction -Description 'Restaurando setupprep.exe' -Action { Set-AIOBootSetupSessionWin10 -Session $Session -Mode Original } })
    $btnBypass.Add_Click({ Invoke-SetupUIAction -Description 'Integrando bypass Win11' -Action { Set-AIOBootSetupSessionBypass -Session $Session -Mode Enabled } })
    $btnRestoreBypass.Add_Click({ Invoke-SetupUIAction -Description 'Restaurando requisitos' -Action { Set-AIOBootSetupSessionBypass -Session $Session -Mode Original } })
    $btnBackground.Add_Click({ Invoke-SetupUIAction -Description 'Preparando fondo' -Action { Set-AIOBootSetupSessionBackground -Session $Session -Mode Custom -ImagePath $Session.SelectedImagePath } })
    $btnRestoreBackground.Add_Click({ Invoke-SetupUIAction -Description 'Restaurando fondo' -Action { Set-AIOBootSetupSessionBackground -Session $Session -Mode Original; Set-SetupPreview '' } })
    $btnBrowse.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Selecciona el fondo de Windows Setup'
        $dialog.Filter = 'Imagenes PNG, JPG o BMP|*.png;*.jpg;*.jpeg;*.bmp'
        $dialog.CheckFileExists = $true; $dialog.Multiselect = $false; $dialog.RestoreDirectory = $true
        try {
            if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) {
                Set-SetupPreview -Path $dialog.FileName
                $Session.SelectedImagePath = $dialog.FileName
                $imagePath.Text = $dialog.FileName
                $btnBackground.Enabled = $true
            }
        } catch { [void][Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'No se pudo abrir la imagen','OK','Error') }
        finally { $dialog.Dispose() }
    })
    $btnRefresh.Add_Click({ Invoke-SetupUIAction -Description 'Leyendo estado' -Action { } })
    $btnClose.Add_Click({ if (-not $view.Busy) { $form.Close() } })
    $form.Add_FormClosing({ param($sender,$eventArgs); if ($view.Busy) { $eventArgs.Cancel = $true } })
    try {
        Update-SetupView
        try { Set-SetupPreview -Path $Session.SelectedImagePath }
        catch { Set-SetupPreview ''; $previewCaption.Text = 'Imagen anterior no disponible. Elige otra en Fondo de instalacion.' }
        [void]$form.ShowDialog()
    } finally {
        if ($null -ne $preview.Image) { $preview.Image.Dispose(); $preview.Image = $null }
        $tips.Dispose(); $form.Dispose(); $titleFont.Dispose(); $uiFont.Dispose()
    }
}
