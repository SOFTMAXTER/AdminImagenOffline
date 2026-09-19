# =================================================================
# Metadatos de la imagen offline para el menu principal.
# Extension de AdminImagenOffline. Copyright (C) 2026 SOFTMAXTER.
# Distribuido bajo la licencia del proyecto (ver LICENSE).
# No consulta el SO anfitrion para completar datos de la imagen.
# =================================================================

function Initialize-AIODashboardNative {
    if (('AIODashboardNativePath' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AIODashboardNativePath {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);
    public static string GetNtPath(string path) {
        // OPEN_EXISTING, sin escritura; compartir lectura/escritura/borrado.
        using (SafeFileHandle file = CreateFileW(path, 0, 7, IntPtr.Zero, 3, 0, IntPtr.Zero)) {
            if (file.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            StringBuilder text = new StringBuilder(32768);
            uint size = GetFinalPathNameByHandleW(file, text, (uint)text.Capacity, 2);
            if (size == 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            if (size >= text.Capacity) throw new InvalidOperationException("Ruta de hive demasiado larga.");
            return text.ToString();
        }
    }
}
'@ -ErrorAction Stop
}

function Get-AIODashboardLoadedHive {
    param([string]$HivePath)
    Initialize-AIODashboardNative
    $target = [AIODashboardNativePath]::GetNtPath($HivePath)
    $base = $null; $list = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
        $list = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\hivelist', $false)
        if ($null -eq $list) { return }
        $prefix = '\REGISTRY\MACHINE\'
        foreach ($name in $list.GetValueNames()) {
            # La identidad se comprueba por archivo, nunca solo por nombre OfflineSoftware.
            if ($name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$list.GetValue($name), $target, [StringComparison]::OrdinalIgnoreCase)) {
                return $name.Substring($prefix.Length)
            }
        }
    } finally {
        if ($null -ne $list) { $list.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Read-AIODashboardRegistryKey {
    param([string]$SubKey)
    $base = $null; $key = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
        $key = $base.OpenSubKey(($SubKey + '\Microsoft\Windows NT\CurrentVersion'), $false)
        if ($null -eq $key) { throw 'No existe Windows NT\CurrentVersion en el SOFTWARE de la imagen.' }
        $values = [ordered]@{}
        foreach ($name in @('ProductName','EditionID','InstallationType','DisplayVersion','ReleaseId','CurrentBuildNumber','CurrentBuild','CurrentMajorVersionNumber','CurrentMinorVersionNumber','CurrentVersion','UBR','BuildLabEx')) {
            $values[$name] = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
        return [pscustomobject]$values
    } finally {
        if ($null -ne $key) { $key.Dispose() }
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Invoke-AIODashboardReg {
    param([string[]]$Arguments)
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $global:LASTEXITCODE = $null
    $lines = @(& reg.exe @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $global:LASTEXITCODE
    if ($null -eq $exitCode) { throw 'No se pudo ejecutar reg.exe.' }
    [pscustomobject]@{ ExitCode = $exitCode; Lines = $lines }
}

function Get-AIODashboardRegistryData {
    param([Parameter(Mandatory = $true)][string]$MountPath)
    $hive = Join-Path $MountPath 'Windows\System32\config\SOFTWARE'
    if (-not (Test-Path -LiteralPath $hive -PathType Leaf)) { throw "No se encontro SOFTWARE en $MountPath." }
    $loadedKey = $null
    try { $loadedKey = Get-AIODashboardLoadedHive -HivePath $hive }
    catch { Write-Log -LogLevel WARN -Message "Dashboard: No se pudo verificar un hive ya cargado: $($_.Exception.Message)" }
    if ($loadedKey) { return Read-AIODashboardRegistryKey -SubKey $loadedKey }

    $temporaryKey = 'AIO_Dash_' + [guid]::NewGuid().ToString('N')
    $load = Invoke-AIODashboardReg -Arguments @('load', "HKLM\$temporaryKey", $hive)
    if ($load.ExitCode -ne 0) { throw "No se pudo cargar SOFTWARE (reg.exe: $($load.ExitCode)). $($load.Lines -join ' ')" }
    $data = $null
    try {
        $data = Read-AIODashboardRegistryKey -SubKey $temporaryKey
    } finally {
        # Read-AIODashboardRegistryKey ya ha cerrado TODOS sus handles.
        $unloaded = $false
        for ($attempt = 0; $attempt -lt 2 -and -not $unloaded; $attempt++) {
            $unload = Invoke-AIODashboardReg -Arguments @('unload', "HKLM\$temporaryKey")
            $unloaded = $unload.ExitCode -eq 0
            if (-not $unloaded -and $attempt -eq 0) { [GC]::Collect(); Start-Sleep -Milliseconds 150 }
        }
        if (-not $unloaded) {
            throw "No se pudo descargar HKLM\$temporaryKey (codigo $($unload.ExitCode)). Revisa esta clave antes de desmontar la imagen."
        }
    }
    return $data
}

function Get-AIODashboardPeArchitecture {
    param([Parameter(Mandatory = $true)][string]$Path)
    $stream = $null; $reader = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $reader = New-Object IO.BinaryReader($stream)
        if ($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5A4D) { throw 'Cabecera DOS invalida.' }
        $stream.Position = 0x3C
        $offset = $reader.ReadUInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'Desplazamiento PE invalido.' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550) { throw 'Firma PE invalida.' }
        switch ($reader.ReadUInt16()) {
            0x014C { return 'x86' }
            0x8664 { return 'x64' }
            0xAA64 { return 'ARM64' }
            0x01C4 { return 'ARM' }
            0xA641 { return 'ARM64EC' }
            0xA64E { return 'ARM64X' }
            default { throw 'Arquitectura PE no reconocida.' }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        elseif ($null -ne $stream) { $stream.Dispose() }
    }
}

function Get-AIODashboardCurrentEdition {
    param([Parameter(Mandatory = $true)][string]$MountPath)
    if (-not (Test-Path -LiteralPath $MountPath -PathType Container)) {
        throw "No existe el directorio de la imagen: $MountPath."
    }
    # El helper de Modulo-Montaje agrega /English y comprueba la ejecucion nativa.
    # Consultar la imagen MONTADA: el XML del WIM puede preceder a un cambio de edicion.
    $query = Invoke-AIOMountDismQuery -Arguments @("/Image:$MountPath", '/Get-CurrentEdition')
    if ($null -eq $query.ExitCode -or $query.ExitCode -ne 0) {
        throw "DISM no pudo consultar la edicion offline (codigo $($query.ExitCode)). $($query.Lines -join ' ')"
    }
    $editions = @(
        foreach ($line in (($query.Lines -join "`n") -split '\r?\n')) {
            if ($line -match '^\s*Current Edition\s*:\s*([A-Za-z0-9_]+)\s*$') { $matches[1] }
        }
    )
    if ($editions.Count -ne 1) { throw 'DISM no devolvio una unica edicion actual reconocible.' }
    return $editions[0]
}

function Get-AIODashboardEditionLabel {
    param([string]$Edition, [switch]$Server)
    # Reutilizar el catalogo del proyecto, con coincidencia EXACTA del identificador.
    # No usar su busqueda por nombre parcial: podria confundir Enterprise con EnterpriseS.
    if ($null -eq $script:AIODashboardEditionCatalog) {
        $catalogPath = Join-Path $PSScriptRoot 'Catalogos\Ediciones.ps1'
        $script:AIODashboardEditionCatalog = @()
        if (Test-Path -LiteralPath $catalogPath -PathType Leaf) {
            . $catalogPath
            $script:AIODashboardEditionCatalog = @($script:EditionCatalog)
        }
    }
    $entries = @($script:AIODashboardEditionCatalog | Where-Object { $_.EditionID -eq $Edition })
    if ($entries.Count -eq 1) {
        $label = [string]$entries[0].Name
        if ($Server -and $label -match '^Windows Server\s+(.+)$') { return $matches[1] }
        if (-not $Server -and $label -match '^Windows(?: 10| 11)?\s+(?!Server\b)(.+)$') { return $matches[1] }
    }
    # Identificador desconocido: mostrarlo completo, sin adivinar otra edicion.
    return $Edition
}

function ConvertTo-AIODashboardMetadata {
    param($RegistryData, [version]$KernelVersion, [string]$Architecture = 'No disponible', [string]$CurrentEdition)
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $name = [string]$RegistryData.ProductName
    $edition = ([string]$RegistryData.EditionID).Trim()
    $editionSource = if ($edition) { 'Registro SOFTWARE offline' } else { 'No disponible' }
    if (-not [string]::IsNullOrWhiteSpace($CurrentEdition)) {
        $edition = $CurrentEdition.Trim(); $editionSource = 'DISM /Get-CurrentEdition offline'
    }
    $installationType = [string]$RegistryData.InstallationType
    $displayVersion = [string]$RegistryData.DisplayVersion
    if (-not $displayVersion) { $displayVersion = [string]$RegistryData.ReleaseId }
    $build = 0
    $buildText = [string]$RegistryData.CurrentBuildNumber
    if (-not $buildText) { $buildText = [string]$RegistryData.CurrentBuild }
    $hasBuild = [int]::TryParse($buildText, [ref]$build) -and $build -gt 0
    $versionText = 'No disponible'; $versionSource = 'No disponible'
    if ($hasBuild) {
        $major = 0; $minor = 0
        $hasMajor = [int]::TryParse([string]$RegistryData.CurrentMajorVersionNumber, [ref]$major)
        $hasMinor = [int]::TryParse([string]$RegistryData.CurrentMinorVersionNumber, [ref]$minor)
        if (-not $hasMajor -or -not $hasMinor) {
            $major = 0; $minor = 0
            if ($null -ne $KernelVersion) { $major = $KernelVersion.Major; $minor = $KernelVersion.Minor }
            elseif ([string]$RegistryData.CurrentVersion -match '^(\d+)\.(\d+)$' -and $build -lt 10240) {
                $major = [int]$matches[1]; $minor = [int]$matches[2]
            }
        }
        $versionText = if ($major -gt 0) { "$major.$minor.$build" } else { [string]$build }
        $ubr = 0
        $hasUbr = $null -ne $RegistryData.UBR -and [int]::TryParse([string]$RegistryData.UBR, [ref]$ubr) -and $ubr -ge 0
        if ($hasUbr) { $versionText += ".$ubr" }
        else { [void]$issues.Add('UBR no disponible; no se invento ni se mezclo una revision del kernel.') }
        $versionSource = 'Registro SOFTWARE offline'
    } elseif ($null -ne $KernelVersion) {
        $versionText = $KernelVersion.ToString(); $versionSource = 'Archivo del kernel (respaldo)'
        [void]$issues.Add('Build del registro no disponible; se muestra la version del archivo del kernel.')
    } else { [void]$issues.Add('Compilacion no disponible.') }

    # ProductName puede conservar Enterprise despues de convertir la imagen a Pro.
    # Nombre y Edicion deben compartir la misma edicion efectiva. El nombre original
    # se conserva en el log, sin escribir ni cambiar la edicion de la imagen.
    $nameSource = 'ProductName offline'
    $family = $null; $isServer = $installationType -match '^Server(?:\s|$)'
    if ($installationType -eq 'Client' -and $hasBuild -and $build -ge 10240) {
        $family = if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }
        $nameSource = 'Build y tipo offline + edicion efectiva'
    } elseif ($isServer) {
        $family = 'Windows Server'
        # Conservar solo la familia/ano, nunca el sufijo de edicion de ProductName.
        if ($name -match '^(Windows Server(?: \d{4}(?: R2)?)?)(?=\s|$)') { $family = $matches[1] }
        $nameSource = 'Familia Server offline + edicion efectiva'
    }
    if ($family) {
        $label = if ($edition) { Get-AIODashboardEditionLabel -Edition $edition -Server:$isServer } else { '(edicion no disponible)' }
        $name = "$family $label"
    }
    $nameAdjusted = $name -cne [string]$RegistryData.ProductName
    if (-not $name) { $name = 'Windows (nombre no disponible)'; [void]$issues.Add('ProductName no disponible.') }
    if (-not $edition) { $edition = 'No disponible'; [void]$issues.Add('Edicion no disponible.') }
    if (-not $displayVersion) { $displayVersion = 'No disponible' }
    if (-not $installationType) { $installationType = 'No disponible' }
    if (-not $Architecture -or $Architecture -eq 'No disponible') { $Architecture = 'No disponible'; [void]$issues.Add('Arquitectura no disponible.') }
    [pscustomobject]@{
        Name = $name; RawProductName = [string]$RegistryData.ProductName; NameAdjusted = $nameAdjusted
        Edition = $edition; RawEditionID = [string]$RegistryData.EditionID; EditionSource = $editionSource
        NameSource = $nameSource; DisplayVersion = $displayVersion; Version = $versionText
        Architecture = $Architecture; InstallationType = $installationType
        VersionSource = $versionSource; Issues = @($issues.ToArray())
    }
}

function Read-AIODashboardMetadata {
    param([Parameter(Mandatory = $true)][string]$MountPath)
    $issues = @(); $registry = $null; $kernelVersion = $null; $arch = 'No disponible'; $currentEdition = $null
    $kernel = Join-Path $MountPath 'Windows\System32\ntoskrnl.exe'
    try { $registry = Get-AIODashboardRegistryData -MountPath $MountPath }
    catch { $issues += $_.Exception.Message }
    # Microsoft no admite consultas de mantenimiento de edicion en Windows PE.
    if ($registry.InstallationType -ne 'WindowsPE' -and $registry.EditionID -ne 'WindowsPE') {
        try { $currentEdition = Get-AIODashboardCurrentEdition -MountPath $MountPath }
        catch { $issues += "Edicion DISM no verificada; se usa EditionID del registro si esta disponible. $($_.Exception.Message)" }
    }
    try { $arch = Get-AIODashboardPeArchitecture -Path $kernel }
    catch { $issues += "No se pudo leer la arquitectura del kernel: $($_.Exception.Message)" }
    try {
        if (Test-Path -LiteralPath $kernel -PathType Leaf) {
            $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($kernel)
            if ($info.FileMajorPart -gt 0) {
                $kernelVersion = [version]("{0}.{1}.{2}.{3}" -f $info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
            }
        }
    } catch { $issues += "No se pudo leer la version del kernel: $($_.Exception.Message)" }
    $result = ConvertTo-AIODashboardMetadata -RegistryData $registry -KernelVersion $kernelVersion -Architecture $arch -CurrentEdition $currentEdition
    $result.Issues = @($result.Issues) + $issues
    Write-Log -LogLevel INFO -Message ("Dashboard: {0} | Edicion {1} | Version {2} | Build {3} | {4} | Fuente: {5} | ProductName original: {6}" -f $result.Name, $result.Edition, $result.DisplayVersion, $result.Version, $result.Architecture, $result.VersionSource, $result.RawProductName)
    Write-Log -LogLevel INFO -Message ("Dashboard: Fuente del nombre: {0} | Fuente de edicion: {1} | EditionID original: {2}" -f $result.NameSource, $result.EditionSource, $result.RawEditionID)
    if ($currentEdition -and $result.RawEditionID -and $currentEdition -ne $result.RawEditionID) {
        Write-Log -LogLevel WARN -Message "Dashboard: DISM informa $currentEdition y el registro $($result.RawEditionID). Se muestra la edicion de DISM en nombre y edicion."
    }
    foreach ($issue in $result.Issues) { Write-Log -LogLevel WARN -Message "Dashboard: $issue" }
    return $result
}

function Get-AIODashboardCacheKey {
    param([int]$MountState, [string]$MountPath, [string]$ImagePath, $Index)
    # Identidad de la imagen, no fechas de archivos: abrir/cerrar los hives desde
    # otro modulo puede cambiar SOFTWARE sin modificar los metadatos del SO.
    $parts = @([string]$MountState, $MountPath, $ImagePath, [string]$Index)
    # JSON evita colisiones por separadores dentro de rutas.
    return ConvertTo-Json -InputObject $parts -Compress
}

function Get-AIOCachedDashboardMetadata {
    param([int]$MountState, [string]$MountPath, [string]$ImagePath, $Index, [switch]$ForceRefresh)
    if ($MountState -notin @(1,2)) { $script:AIODashboardCache = $null; return $null }
    $key = Get-AIODashboardCacheKey -MountState $MountState -MountPath $MountPath -ImagePath $ImagePath -Index $Index
    $cache = $script:AIODashboardCache
    # Los datos parciales tambien se conservan hasta un cambio de imagen o una
    # operacion que solicite refresco; volver al menu no dispara reintentos.
    if ($ForceRefresh -or $null -eq $cache -or $cache.Key -cne $key) {
        Write-Host 'Leyendo metadatos del sistema operativo...' -ForegroundColor DarkGray
        $data = Read-AIODashboardMetadata -MountPath $MountPath
        $script:AIODashboardCache = [pscustomobject]@{ Key = $key; Data = $data; ReadUtc = [DateTime]::UtcNow }
    }
    return $script:AIODashboardCache.Data
}

function Write-AIODashboardMetadata {
    param($Metadata, [string]$MountPath, [int]$Width = 80)
    foreach ($item in @(
        @('Detalles SO', $Metadata.Name), @('Edicion', $Metadata.Edition), @('Version', $Metadata.DisplayVersion),
        @('Build', $Metadata.Version), @('Arquitectura', $Metadata.Architecture), @('Tipo', $Metadata.InstallationType), @('Directorio', $MountPath)
    )) {
        $prefix = '  + {0,-12}: ' -f $item[0]
        $value = ([string]$item[1] -replace '[\x00-\x1F\x7F]', ' ').Trim()
        $available = [Math]::Max(4, $Width - $prefix.Length - 1)
        if ($value.Length -gt $available) { $value = $value.Substring(0, $available - 3) + '...' }
        Write-Host ($prefix + $value) -ForegroundColor Cyan
    }
    if ($Metadata.Issues.Count -gt 0) {
        Write-Host '  Lectura parcial. Se mantiene hasta el proximo montaje/cambio de edicion.' -ForegroundColor Yellow
    }
}
