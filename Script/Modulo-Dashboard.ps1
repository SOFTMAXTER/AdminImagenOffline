# =================================================================
# Metadatos de la imagen offline para el menu principal.
# Extension de AdminImagenOffline. Copyright (C) 2026 SOFTMAXTER.
# Distribuido bajo la licencia del proyecto (ver LICENSE).
# No consulta el SO anfitrion para completar datos de la imagen.
# =================================================================

$script:AIODashboardMonitoredRegistryValues = @(
    'ProductName',
    'EditionID',
    'InstallationType',
    'DisplayVersion',
    'ReleaseId',
    'CurrentBuildNumber',
    'CurrentBuild',
    'CurrentMajorVersionNumber',
    'CurrentMinorVersionNumber',
    'CurrentVersion',
    'UBR',
    'BuildLabEx'
)

$script:AIODashboardBuiltInEditionLabels = @{
    'Core'                     = 'Windows Home'
    'CoreN'                    = 'Windows Home N'
    'CoreK'                    = 'Windows Home K / KN'
    'CoreSingleLanguage'       = 'Windows Home Single Language'
    'CoreCountrySpecific'      = 'Windows Home Country Specific'
    'Starter'                  = 'Windows Starter'
    'StarterN'                 = 'Windows Starter N'
    'Professional'             = 'Windows Pro'
    'ProfessionalN'            = 'Windows Pro N'
    'ProfessionalSingleLanguage' = 'Windows Pro Single Language'
    'ProfessionalCountrySpecific' = 'Windows Pro Country Specific'
    'ProfessionalWorkstation'  = 'Windows Pro for Workstations'
    'ProfessionalWorkstationN' = 'Windows Pro for Workstations N'
    'ProfessionalEducation'    = 'Windows Pro Education'
    'ProfessionalEducationN'   = 'Windows Pro Education N'
    'Enterprise'               = 'Windows Enterprise'
    'EnterpriseN'              = 'Windows Enterprise N'
    'EnterpriseEval'           = 'Windows Enterprise Evaluation'
    'EnterpriseNEval'          = 'Windows Enterprise N Evaluation'
    'EnterpriseS'              = 'Windows Enterprise LTSC'
    'EnterpriseSN'             = 'Windows Enterprise LTSC N'
    'EnterpriseSEval'          = 'Windows Enterprise LTSC Evaluation'
    'EnterpriseSNEval'         = 'Windows Enterprise LTSC N Evaluation'
    'EnterpriseG'              = 'Windows Enterprise G'
    'EnterpriseGN'             = 'Windows Enterprise G (N)'
    'ServerRdsh'               = 'Windows Enterprise Multi-Session'
    'Education'                = 'Windows Education'
    'EducationN'               = 'Windows Education N'
    'Cloud'                    = 'Windows 10 S'
    'CloudN'                   = 'Windows 10 S (N)'
    'CloudEdition'             = 'Windows 11 SE'
    'CloudEditionN'            = 'Windows 11 SE (N)'
    'WNC'                      = 'Windows Cloud PC'
    'PPIPro'                   = 'Windows Team'
    'UtilityVM'                = 'Windows Utility VM'
    'IoTEnterprise'            = 'Windows IoT Enterprise'
    'IoTEnterpriseK'           = 'Windows IoT Enterprise K'
    'IoTEnterpriseS'           = 'Windows IoT Enterprise LTSC'
    'IoTEnterpriseSK'          = 'Windows IoT Enterprise LTSC K'
    'IoTEnterpriseSEval'       = 'Windows IoT Enterprise LTSC Evaluation'
    'ServerStandard'           = 'Windows Server Standard'
    'ServerStandardCore'       = 'Windows Server Standard (Server Core)'
    'ServerStandardACor'       = 'Windows Server Standard (Server Core)'
    'ServerStandardEval'       = 'Windows Server Standard Evaluation'
    'ServerStandardCoreEval'   = 'Windows Server Standard (Server Core) Evaluation'
    'ServerStandardNano'       = 'Windows Server Standard (Nano Server)'
    'ServerDatacenter'         = 'Windows Server Datacenter'
    'ServerDatacenterCore'     = 'Windows Server Datacenter (Server Core)'
    'ServerDatacenterACor'     = 'Windows Server Datacenter (Server Core)'
    'ServerDatacenterEval'     = 'Windows Server Datacenter Evaluation'
    'ServerDatacenterCoreEval' = 'Windows Server Datacenter (Server Core) Evaluation'
    'ServerDatacenterNano'     = 'Windows Server Datacenter (Nano Server)'
    'ServerAzureCor'           = 'Windows Server Datacenter: Azure Edition (Core)'
    'ServerTurbine'            = 'Windows Server Datacenter: Azure Edition'
    'ServerTurbineCor'         = 'Windows Server Datacenter: Azure Edition (Core)'
    'ServerSolution'           = 'Windows Server Essentials'
    'ServerWeb'                = 'Windows Web Server'
}

function Initialize-AIODashboardNative {
    if (('AIODashboardNativePath' -as [type])) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
public static class AIODashboardNativePath {
    const uint FILE_SHARE_ALL = 7;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
    const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
    const uint VOLUME_NAME_NT = 2;

    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true, ExactSpelling=true)]
    static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

    static string QueryHandleNtPath(string path, uint openFlags, bool throwOnError) {
        using (SafeFileHandle file = CreateFileW(path, 0, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, openFlags, IntPtr.Zero)) {
            if (file.IsInvalid) {
                if (throwOnError) throw new Win32Exception(Marshal.GetLastWin32Error());
                return null;
            }
            StringBuilder text = new StringBuilder(32768);
            uint size = GetFinalPathNameByHandleW(file, text, (uint)text.Capacity, VOLUME_NAME_NT);
            if (size == 0) {
                if (throwOnError) throw new Win32Exception(Marshal.GetLastWin32Error());
                return null;
            }
            if (size >= text.Capacity) throw new InvalidOperationException("Ruta de hive demasiado larga.");
            return text.ToString();
        }
    }

    public static string GetNtPath(string path) {
        return QueryHandleNtPath(path, 0, true);
    }

    public static string[] GetCandidateNtPaths(string path) {
        List<string> candidates = new List<string>();
        // 1. Ruta final resuelta (ej. redirigida por wimmount/WOF hacia Scratch).
        string resolved = QueryHandleNtPath(path, 0, false);
        if (!string.IsNullOrEmpty(resolved)) candidates.Add(resolved);
        // 2. Ruta directa del punto de reanalisis dentro del directorio de montaje.
        string rawReparse = QueryHandleNtPath(path, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, false);
        if (!string.IsNullOrEmpty(rawReparse) && !candidates.Contains(rawReparse)) candidates.Add(rawReparse);
        if (candidates.Count == 0) {
            candidates.Add(QueryHandleNtPath(path, 0, true));
        }
        return candidates.ToArray();
    }
}
'@ -ErrorAction Stop
}

function Normalize-AIODashboardNtPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace "`0", '').Trim().TrimEnd('\')
}

function Get-AIODashboardLoadedHive {
    param([string]$HivePath)
    Initialize-AIODashboardNative
    $candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        foreach ($candidate in @([AIODashboardNativePath]::GetCandidateNtPaths($HivePath))) {
            $norm = Normalize-AIODashboardNtPath -Path $candidate
            if ($norm) { [void]$candidates.Add($norm) }
        }
    } catch {
        # Si el archivo esta bloqueado exclusivamente o falla el handle directo,
        # intentamos reconstruir la ruta NT a partir de la carpeta padre.
        $parentDir = Split-Path -Parent $HivePath
        $leafName = Split-Path -Leaf $HivePath
        if ($parentDir -and $leafName) {
            try {
                foreach ($parentNt in @([AIODashboardNativePath]::GetCandidateNtPaths($parentDir))) {
                    $normParent = Normalize-AIODashboardNtPath -Path $parentNt
                    if ($normParent) { [void]$candidates.Add("$normParent\$leafName") }
                }
            } catch {}
        }
        if ($candidates.Count -eq 0) { throw }
    }

    $base = $null; $list = $null
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Default)
        $list = $base.OpenSubKey('SYSTEM\CurrentControlSet\Control\hivelist', $false)
        if ($null -eq $list) { return }
        $prefix = '\REGISTRY\MACHINE\'
        foreach ($name in $list.GetValueNames()) {
            if (-not $name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $mapped = Normalize-AIODashboardNtPath -Path ([string]$list.GetValue($name))
            # La identidad se comprueba por ruta NT (incluyendo redireccion WIM/Scratch),
            # nunca asumiendo a ciegas el nombre OfflineSoftware.
            if ($mapped -and $candidates.Contains($mapped)) {
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
        foreach ($name in $script:AIODashboardMonitoredRegistryValues) {
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
    if ($load.ExitCode -ne 0) {
        # Si reg.exe falla porque otro hilo o Mount-Hives acaba de montar la colmena,
        # reintentar la deteccion en hivelist antes de abortar.
        try { $loadedKey = Get-AIODashboardLoadedHive -HivePath $hive } catch {}
        if ($loadedKey) { return Read-AIODashboardRegistryKey -SubKey $loadedKey }
        throw "No se pudo cargar SOFTWARE (reg.exe: $($load.ExitCode)). $($load.Lines -join ' ')"
    }
    $data = $null
    try {
        $data = Read-AIODashboardRegistryKey -SubKey $temporaryKey
    } finally {
        # Read-AIODashboardRegistryKey ya ha cerrado TODOS sus handles.
        $unloaded = $false
        for ($attempt = 0; $attempt -lt 3 -and -not $unloaded; $attempt++) {
            $unload = Invoke-AIODashboardReg -Arguments @('unload', "HKLM\$temporaryKey")
            $unloaded = $unload.ExitCode -eq 0
            if (-not $unloaded -and $attempt -lt 2) {
                [GC]::Collect()
                [GC]::WaitForPendingFinalizers()
                Start-Sleep -Milliseconds 150
            }
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

function Get-AIODashboardServerFamilyFromBuild {
    param([int]$Build)
    if ($Build -ge 26000) { return 'Windows Server 2025' }
    if ($Build -ge 20348) { return 'Windows Server 2022' }
    if ($Build -ge 17763) { return 'Windows Server 2019' }
    if ($Build -ge 14393) { return 'Windows Server 2016' }
    if ($Build -eq 9600)  { return 'Windows Server 2012 R2' }
    if ($Build -eq 9200)  { return 'Windows Server 2012' }
    if ($Build -in @(7600, 7601)) { return 'Windows Server 2008 R2' }
    return 'Windows Server'
}

function Get-AIODashboardClientFamilyFromBuild {
    param([int]$Build)
    if ($Build -ge 22000) { return 'Windows 11' }
    if ($Build -ge 10240) { return 'Windows 10' }
    if ($Build -eq 9600)  { return 'Windows 8.1' }
    if ($Build -eq 9200)  { return 'Windows 8' }
    if ($Build -in @(7600, 7601)) { return 'Windows 7' }
    return $null
}

function Get-AIODashboardEditionLabel {
    param([string]$Edition, [switch]$Server)
    if ([string]::IsNullOrWhiteSpace($Edition)) { return $Edition }
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
    $label = $null
    $entries = @($script:AIODashboardEditionCatalog | Where-Object { $_.EditionID -ieq $Edition })
    if ($entries.Count -ge 1) {
        $label = [string]$entries[0].Name
    } else {
        foreach ($key in $script:AIODashboardBuiltInEditionLabels.Keys) {
            if ([string]::Equals($key, $Edition, [StringComparison]::OrdinalIgnoreCase)) {
                $label = [string]$script:AIODashboardBuiltInEditionLabels[$key]
                break
            }
        }
    }
    if ($label) {
        if ($Server -and $label -match '^Windows(?: Server)?\s+(.+)$') { return $matches[1] }
        if (-not $Server -and $label -match '^Windows(?: 10| 11)?\s+(?!Server\b)(.+)$') { return $matches[1] }
        return $label
    }
    # Identificador desconocido: mostrarlo completo, sin adivinar otra edicion.
    return $Edition
}

function ConvertTo-AIODashboardMetadata {
    param([AllowNull()]$RegistryData, [version]$KernelVersion, [string]$Architecture = 'No disponible', [string]$CurrentEdition)
    $issues = New-Object 'System.Collections.Generic.List[string]'
    $rawProductName = if ($null -ne $RegistryData -and $null -ne $RegistryData.ProductName) { [string]$RegistryData.ProductName } else { '' }
    $rawEditionId = if ($null -ne $RegistryData -and $null -ne $RegistryData.EditionID) { ([string]$RegistryData.EditionID).Trim() } else { '' }
    $name = $rawProductName
    $edition = $rawEditionId
    $editionSource = if ($edition) { 'Registro SOFTWARE offline' } else { 'No disponible' }
    if (-not [string]::IsNullOrWhiteSpace($CurrentEdition)) {
        $edition = $CurrentEdition.Trim(); $editionSource = 'DISM /Get-CurrentEdition offline'
    }
    $installationType = if ($null -ne $RegistryData -and $null -ne $RegistryData.InstallationType) { [string]$RegistryData.InstallationType } else { '' }
    $displayVersion = if ($null -ne $RegistryData -and $null -ne $RegistryData.DisplayVersion) { [string]$RegistryData.DisplayVersion } else { '' }
    if (-not $displayVersion -and $null -ne $RegistryData -and $null -ne $RegistryData.ReleaseId) {
        $displayVersion = [string]$RegistryData.ReleaseId
    }
    $build = 0
    $buildText = if ($null -ne $RegistryData -and $null -ne $RegistryData.CurrentBuildNumber) { [string]$RegistryData.CurrentBuildNumber } else { '' }
    if (-not $buildText -and $null -ne $RegistryData -and $null -ne $RegistryData.CurrentBuild) {
        $buildText = [string]$RegistryData.CurrentBuild
    }
    $hasBuild = [int]::TryParse($buildText, [ref]$build) -and $build -gt 0
    $versionText = 'No disponible'; $versionSource = 'No disponible'
    if ($hasBuild) {
        $major = 0; $minor = 0
        $majorRaw = if ($null -ne $RegistryData) { [string]$RegistryData.CurrentMajorVersionNumber } else { '' }
        $minorRaw = if ($null -ne $RegistryData) { [string]$RegistryData.CurrentMinorVersionNumber } else { '' }
        $hasMajor = [int]::TryParse($majorRaw, [ref]$major)
        $hasMinor = [int]::TryParse($minorRaw, [ref]$minor)
        if (-not $hasMajor -or -not $hasMinor) {
            $major = 0; $minor = 0
            if ($null -ne $KernelVersion) { $major = $KernelVersion.Major; $minor = $KernelVersion.Minor }
            elseif ($null -ne $RegistryData -and [string]$RegistryData.CurrentVersion -match '^(\d+)\.(\d+)$' -and $build -lt 10240) {
                $major = [int]$matches[1]; $minor = [int]$matches[2]
            }
        }
        $versionText = if ($major -gt 0) { "$major.$minor.$build" } else { [string]$build }
        $ubr = 0
        $hasUbr = $null -ne $RegistryData -and $null -ne $RegistryData.UBR -and [int]::TryParse([string]$RegistryData.UBR, [ref]$ubr) -and $ubr -ge 0
        if ($hasUbr) { $versionText += ".$ubr" }
        else { [void]$issues.Add('UBR no disponible; no se invento ni se mezclo una revision del kernel.') }
        $versionSource = 'Registro SOFTWARE offline'
    } elseif ($null -ne $KernelVersion) {
        $versionText = $KernelVersion.ToString(); $versionSource = 'Archivo del kernel (respaldo)'
        $build = $KernelVersion.Build
        $hasBuild = $build -gt 0
        [void]$issues.Add('Build del registro no disponible; se muestra la version del archivo del kernel.')
    } else { [void]$issues.Add('Compilacion no disponible.') }

    # ProductName puede conservar Enterprise despues de convertir la imagen a Pro,
    # o decir Windows 10 en imagenes Windows 11. Nombre y Edicion comparten la misma
    # edicion efectiva; el nombre original se conserva en el log.
    $nameSource = 'ProductName offline'
    $family = $null
    $isServer = ($installationType -match '^Server(?:\s|$)') -or ($edition -match '^Server(?!Rdsh\b)')
    if ($installationType -eq 'Client' -and $hasBuild) {
        $family = Get-AIODashboardClientFamilyFromBuild -Build $build
        if ($family) { $nameSource = 'Build y tipo offline + edicion efectiva' }
    } elseif ($isServer) {
        # Conservar el ano si figura en ProductName; de lo contrario deducirlo del build CBS.
        if ($name -match '^(Windows Server(?: \d{4}(?: R2)?)?)(?=\s|$)' -and $matches[1] -ne 'Windows Server') {
            $family = $matches[1]
        } elseif ($hasBuild) {
            $family = Get-AIODashboardServerFamilyFromBuild -Build $build
        } else {
            $family = 'Windows Server'
        }
        $nameSource = 'Familia Server offline + edicion efectiva'
    }
    if ($family) {
        $label = if ($edition) { Get-AIODashboardEditionLabel -Edition $edition -Server:$isServer } else { '(edicion no disponible)' }
        $name = "$family $label"
    }
    $nameAdjusted = $name -cne $rawProductName
    if (-not $name) { $name = 'Windows (nombre no disponible)'; [void]$issues.Add('ProductName no disponible.') }
    if (-not $edition) { $edition = 'No disponible'; [void]$issues.Add('Edicion no disponible.') }
    if (-not $displayVersion) { $displayVersion = 'No disponible' }
    if (-not $installationType) { $installationType = 'No disponible' }
    if (-not $Architecture -or $Architecture -eq 'No disponible') { $Architecture = 'No disponible'; [void]$issues.Add('Arquitectura no disponible.') }
    [pscustomobject]@{
        Name = $name; RawProductName = $rawProductName; NameAdjusted = $nameAdjusted
        Edition = $edition; RawEditionID = $rawEditionId; EditionSource = $editionSource
        NameSource = $nameSource; DisplayVersion = $displayVersion; Version = $versionText
        Architecture = $Architecture; InstallationType = $installationType
        VersionSource = $versionSource; Issues = @($issues.ToArray())
    }
}

function Test-AIODashboardIsWinPE {
    param([Parameter(Mandatory = $true)][string]$MountPath, [AllowNull()]$RegistryData)
    if ($null -ne $RegistryData) {
        if ($RegistryData.InstallationType -eq 'WindowsPE' -or $RegistryData.EditionID -eq 'WindowsPE') {
            return $true
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$RegistryData.InstallationType)) {
            return $false
        }
    }
    # Si el registro no estuvo disponible, comprobar marcadores exclusivos de WinPE/WinRE
    # para no ejecutar DISM /Get-CurrentEdition sobre un entorno PE.
    $peMarker1 = Join-Path $MountPath 'Windows\System32\winpeshl.ini'
    $peMarker2 = Join-Path $MountPath 'Windows\System32\startnet.cmd'
    $explorer = Join-Path $MountPath 'Windows\explorer.exe'
    if (((Test-Path -LiteralPath $peMarker1 -PathType Leaf) -or (Test-Path -LiteralPath $peMarker2 -PathType Leaf)) -and
        -not (Test-Path -LiteralPath $explorer -PathType Leaf)) {
        return $true
    }
    return $false
}

function Read-AIODashboardMetadata {
    param([Parameter(Mandatory = $true)][string]$MountPath)
    $issues = @(); $registry = $null; $kernelVersion = $null; $arch = 'No disponible'; $currentEdition = $null
    $kernel = Join-Path $MountPath 'Windows\System32\ntoskrnl.exe'
    try { $registry = Get-AIODashboardRegistryData -MountPath $MountPath }
    catch { $issues += $_.Exception.Message }
    # Microsoft no admite consultas de mantenimiento de edicion en Windows PE.
    if (-not (Test-AIODashboardIsWinPE -MountPath $MountPath -RegistryData $registry)) {
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
    $result.Issues = @(@($result.Issues) + $issues | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
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
    # Identidad normalizada de la imagen montada, no fechas de archivos: abrir/cerrar
    # los hives desde otro modulo puede cambiar SOFTWARE sin modificar los metadatos del SO.
    $normMount = if ([string]::IsNullOrWhiteSpace($MountPath)) { '' } else { [IO.Path]::GetFullPath($MountPath).Replace('/', '\').TrimEnd('\').ToLowerInvariant() }
    $normImage = if ([string]::IsNullOrWhiteSpace($ImagePath)) { '' } else { $ImagePath.Trim().Replace('/', '\').ToLowerInvariant() }
    $parts = @([string]$MountState, $normMount, $normImage, [string]$Index)
    # JSON evita colisiones por separadores dentro de rutas.
    return ConvertTo-Json -InputObject $parts -Compress
}

function Test-AIODashboardHasIssues {
    $cache = $script:AIODashboardCache
    if ($null -eq $cache -or $null -eq $cache.Data) { return $true }
    return (@($cache.Data.Issues).Count -gt 0)
}

function Request-AIODashboardRefreshIfDegraded {
    # Solo solicita refresco tras operaciones de reparacion (RestoreHealth / SFC)
    # si la lectura previa del Dashboard habia registrado incidencias o estaba vacia.
    if (Test-AIODashboardHasIssues) {
        $Script:ForceMenuRefresh = $true
    }
}

function Test-AIODashboardRegistryMutationAffectsMetadata {
    param(
        [AllowNull()][string]$KeyPath,
        [AllowNull()][string]$Action,
        [AllowNull()][string]$ValueName
    )
    if ([string]::IsNullOrWhiteSpace($KeyPath)) { return $false }
    $dashboardKey = 'OfflineSoftware\Microsoft\Windows NT\CurrentVersion'
    $normKey = $KeyPath.Trim().TrimEnd('\')
    if ($Action -eq 'DeleteKey') {
        return (
            [string]::Equals($normKey, $dashboardKey, [StringComparison]::OrdinalIgnoreCase) -or
            $dashboardKey.StartsWith($normKey + '\', [StringComparison]::OrdinalIgnoreCase)
        )
    }
    if ($Action -eq 'CreateKey') { return $false }
    if (-not [string]::Equals($normKey, $dashboardKey, [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($ValueName)) { return $false }
    foreach ($monitored in $script:AIODashboardMonitoredRegistryValues) {
        if ([string]::Equals($monitored, $ValueName.Trim(), [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
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
    if ($null -eq $Metadata) { return }
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
    if (@($Metadata.Issues).Count -gt 0) {
        Write-Host '  Lectura parcial. Se mantiene hasta el proximo montaje/cambio de edicion.' -ForegroundColor Yellow
    }
}
