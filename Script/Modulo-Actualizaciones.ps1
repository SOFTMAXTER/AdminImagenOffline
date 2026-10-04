<#
.SYNOPSIS
    Integra actualizaciones offline en medios de Windows 10/11 y ramas posteriores compatibles por CBS.
.DESCRIPTION
    Modulo complementario para AdminImagenOffline. Implementa en PowerShell
    un flujo de mantenimiento:

      - Detecta medios extraidos con install.wim y boot.wim.
      - Acepta un repositorio plano o subcarpetas por categoria.
      - Clasifica CAB/MSU por identidades y contenido interno, sin listas KB.
      - Detecta MSU modernos con firma WIM y extrae metadatos con wimlib, wimgapi.dll y respaldo DISM.
      - Normaliza versiones CBS cortas BUILD.REVISION.MAJOR.MINOR a 10.0.BUILD.REVISION.
      - Extrae el SSU integrado en la LCU y lo reutiliza en WinRE/WinPE.
      - Procesa SSU, Enablement y ESU antes de la LCU final.
      - Actualiza winre.wim por separado y lo reinyecta en install.wim.
      - Puede actualizar opcionalmente todos los indices de boot.wim.
      - Puede aplicar opcionalmente Setup Dynamic Update al directorio sources.
      - Si se selecciona un solo indice, exporta install.wim con esa unica edicion.
      - Aplica SetupDU antes de sincronizar Setup y archivos de arranque.
      - Sincroniza archivos de arranque sin degradar versiones existentes.
      - Permite activar/desactivar con una sola opcion las verificaciones completas Pre/Post-Commit; conserva la verificacion estructural final.
      - Conserva el mantenimiento nativo de DISM; para MSU reemplaza solo la etiqueta visual Expand por la identidad CBS detectada.
      - Tolera lineas vacias de DISM y, si falla la captura tras iniciar el proceso, espera su finalizacion antes de continuar.
      - Tolera la consolidacion normal de paquetes superseded durante una LCU.
      - Filtra arquitectura y familia de Windows; aprende relaciones de build desde Enablement y deja la aplicabilidad general a CBS.
      - Detecta paquetes ya presentes antes de invocar DISM.
      - Reaplica automaticamente los paquetes CBS ya presentes sin desinstalarlos.
      - Integra SetupDU dentro del indice Setup de boot.wim y sincroniza sources.
      - Actualiza Defender mediante plataforma/firmas, no como paquete CBS generico.
      - Maneja WinPE-Rejuv cuando la identidad esta presente y archivos UEFI CA 2023.
      - Verifica la retirada de WinPE-Rejuv por identidad exacta y consolida sus avisos.
      - Distingue claramente la familia CBS observada de la version final de la imagen.
      - Evita duplicar la arquitectura cuando el nombre WIM ya la incluye.
      - Restaura automaticamente un medio desde un respaldo Preflight validado.
      - Ordena paquetes por identidades CBS propias; ignora prerrequisitos externos compartidos.
      - Registra por separado el orden planeado y el orden realmente ejecutado.
      - Genera un paquete ZIP de diagnostico ante errores antes de limpiar la sesion.
      - Exporta reportes estructurados JSON y HTML al completar o fallar.
      - Crea y verifica un respaldo previo antes del primer montaje o modificacion.
      - Valida espacio libre del area de trabajo antes del primer montaje.
      - Reutiliza Preflight como respaldo maestro y evita duplicar WIM/Setup durante la misma sesion.
      - Puede reconstruir todos los WIM y ajustar su fecha interna de creacion.
      - Busca herramientas compartidas en AdminImagenOffline\Tools y, como respaldo, en el PATH del sistema.
      - La politica WinRE prioriza SafeOS y verifica CBS; no confunde actualizar SSU con actualizar recuperacion.
      - Aplaza limpieza/ResetBase con operaciones pendientes o estado CBS desconocido.
      - Repara solo dependencias conocidas de recuperacion desde ubicaciones acotadas, con igual version binaria y SHA-256; registra otras importaciones para validacion en ejecucion.
      - Optimiza enumeracion, hashes, metadatos CBS, escritura atomica y deduplicacion sin paralelizar WIM.
      - Detecta automaticamente AdminImagenOffline\Actualizaciones como repositorio predeterminado.
      - Detecta Windows ADK y usa el mismo DISM nativo para consultas, montajes y mantenimiento.
      - Conserva el firmante UEFI del medio por defecto y verifica cualquier conversion explicita a CA 2023/2011.
      - Entrega la cadena MSU al resolvedor nativo de DISM; no reconstruye payloads para forzar su instalacion.
      - Verifica despues de SetupDU que boot.wim conserve lang.ini y los recursos MUI de todos los TrustedLocales.

    Estructura opcional recomendada:

        Actualizaciones\
        |-- SSU\
        |-- LCU\
        |-- SafeOS\
        |-- SecureBoot\
        |-- SetupDU\
        |-- ESU\
        |-- Enablement\
        |-- OS\
        |-- DotNet\
        |-- WinPE\
        `-- Defender\

    Tambien puede seleccionarse una carpeta plana. El modulo intentara
    clasificar cada CAB/MSU por nombre y metadatos internos.
.NOTES
    Implementacion original para AdminImagenOffline.
    Referencias de mantenimiento (consultadas el 01/10/2026):
    https://learn.microsoft.com/windows/deployment/update/media-dynamic-update
    https://learn.microsoft.com/windows/deployment/update/catalog-checkpoint-cumulative-updates
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/winpe-create-usb-bootable-drive
    Sintaxis de consultas revisada el 02/10/2026:
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-global-options-for-command-line-syntax
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/dism-image-management-command-line-options-s14
    Firmas incorporadas EFI revisadas el 02/10/2026:
    https://learn.microsoft.com/windows/win32/seccrypto/example-c-program--verifying-the-signature-of-a-pe-file
    https://learn.microsoft.com/powershell/module/microsoft.powershell.security/get-authenticodesignature
    El examen PE es diagnostico; no reproduce los contextos de carga/SxS de Windows.
	No modifica ni omite comprobaciones de licencia ESU.
.AUTHOR
    SOFTMAXTER

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

$script:AIOUpdateNativeSystemDirectory = if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { Join-Path $env:SystemRoot 'Sysnative' } else { Join-Path $env:SystemRoot 'System32' }
$script:AIOUpdateSystemDismPath = Join-Path $script:AIOUpdateNativeSystemDirectory 'dism.exe'
$script:AIOUpdateDismPath = $script:AIOUpdateSystemDismPath
$script:AIOUpdateDismSource = 'Sistema'
$script:AIOUpdateAdkInfo = $null
$script:AIOUpdateExpandPath = Join-Path $script:AIOUpdateNativeSystemDirectory 'expand.exe'
$script:AIOUpdateSessionRoot = $null
$script:AIOUpdateMaintenanceResults = New-Object System.Collections.ArrayList
$script:AIOUpdateBootSignatureResults = New-Object System.Collections.ArrayList
$script:AIOUpdateMountedPaths = New-Object System.Collections.ArrayList
$script:AIOUpdateDismTranscript = $null
$script:AIOUpdatePackagePathMap = @{}
$script:AIOUpdateLcuStageRoot = $null
$script:AIOUpdateEmbeddedSsuPackages = @()
$script:AIOUpdateWimlibPath = $null
$script:AIOUpdateServicingBuildRelations = @{}
$script:AIOUpdatePreflightContext = $null
$script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
$script:AIOUpdateExecutionPositionByContext = @{}
$script:AIOUpdateLastDiagnosticPath = $null
$script:AIOUpdateLastPersistentLogPath = $null
$script:AIOUpdateLastTerminalState = $null
$script:AIOUpdateCurrentPhase = 'Inicializacion'
$script:AIOUpdateStructuredReport = $null
$script:AIOUpdatePreflightPathIndex = @{}
$script:AIOUpdatePreflightLocalesBySurface = @{}
$script:AIOUpdateSessionCreatedPathIndex = @{}
$script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
$script:AIOUpdateTrustedLocales = @{}
$script:AIOUpdateApplicationRoot = Split-Path -Parent $PSScriptRoot
$script:AIOUpdateReportsRoot = Join-Path $script:AIOUpdateApplicationRoot 'Reportes\Actualizaciones'
$script:AIOUpdateDiagnosticsRoot = Join-Path $script:AIOUpdateApplicationRoot 'Reportes\Diagnosticos\Actualizaciones'
$script:AIOUpdateFileHashCache = @{}
$script:AIOUpdateCbsFactsCache = @{}
$script:AIOUpdateRepositoryInventoryCache = @{}
$script:AIOUpdateInstalledNameCache = @{}
$script:AIOUpdateWimEntryCache = @{}
$script:AIOUpdateExtractedFileCache = @{}
$script:AIOUpdateWimApiReady = $false
$script:AIOUpdateOptimizationStats = [ordered]@{
    HashCacheHits = 0
    HashCacheMisses = 0
    CbsCacheHits = 0
    RepositoryCacheHits = 0
    DuplicatePackagesSkipped = 0
}


# Politicas historicas y catalogos centralizados. Los numeros de build que
# permanecen aqui son fronteras historicas estables (no la 'base' operativa del
# modulo). Las decisiones que pueden cambiar entre versiones se resuelven por
# metadatos/presencia real y no mediante umbrales dispersos.
$script:AIOUpdatePolicy = [ordered]@{
    MinimumRecognizedCbsBuild          = 7600
    Windows11FirstBuild                = 22000
    CheckpointLcuCapabilityFirstBuild  = 26100
    Windows10EsuCbsBuild               = 19041
    Windows10EsuFirstSecurityRevision  = 6575
}

$script:AIOUpdateCategoryOrder = @(
    'SSU', 'LCU', 'SafeOS', 'SecureBoot', 'SetupDU', 'ESU', 'Enablement',
    'OS', 'DotNet', 'WinPE', 'Defender', 'Auxiliary', 'Unknown'
)
$script:AIOUpdateMetadataCategories = @('SSU', 'LCU', 'SafeOS', 'SecureBoot', 'ESU', 'Enablement', 'OS', 'DotNet', 'WinPE')
$script:AIOUpdateProductNeutralCategories = @('SSU', 'LCU', 'SafeOS', 'SecureBoot', 'SetupDU', 'ESU', 'Enablement', 'DotNet', 'WinPE', 'Defender')
$script:AIOUpdateInstallCategoryOrder = @('SSU', 'SecureBoot', 'OS', 'Enablement', 'ESU', 'LCU', 'DotNet')
$script:AIOUpdateBootCategoryOrder = @('WinPE', 'Enablement', 'LCU')
$script:AIOUpdatePackageOrderRanks = [ordered]@{
    SSU = 10
    SecureBoot = 20
    OS = 30
    WinPE = 30
    Enablement = 40
    ESU = 50
    LCU = 60
    DotNet = 70
    SafeOS = 80
    Defender = 90
    SetupDU = 100
    LCUCheckpoint = 55
    Default = 500
}
$script:AIOUpdateDisplayIdentityNames = @{
    LCU = @('Package_for_RollupFix', 'Package_for_RevisedFix')
    DotNet = @('Package_for_DotNetRollup')
    SSU = @('Package_for_ServicingStack')
    SafeOS = @('Package_for_SafeOSDU')
}
$script:AIOUpdateDisplayIdentityNamesDefault = @('Package_for_RollupFix', 'Package_for_RevisedFix', 'Package_for_DotNetRollup', 'Package_for_ServicingStack', 'Package_for_SafeOSDU')

$script:AIOUpdateIdentityPatterns = [ordered]@{
    LCU = '(?i)Package_for_(?:RollupFix|RevisedFix)'
    DotNet = '(?i)(?:Package_for_DotNetRollup|DotNetRollup)'
    SafeOS = '(?i)(?:Package_for_SafeOSDU|SafeOSDU)'
    SSU = '(?i)(?:Package_for_ServicingStack|ServicingStack)'
}
$script:AIOUpdateSemanticFamilyPatterns = [ordered]@{
    SSU = $script:AIOUpdateIdentityPatterns.SSU
    LCU = $script:AIOUpdateIdentityPatterns.LCU
    SafeOS = '(?i)(?:Package_for_SafeOSDU|SafeOSDU|SafeOS)'
    SecureBoot = '(?i)(?:SecureBoot|FirmwareUpdate|DBX)'
    Enablement = '(?i)Enablement-Package'
    DotNet = '(?i)(?:Package_for_DotNetRollup|DotNetRollup|NetFx)'
    WinPE = '(?i)WinPE-'
    ESU = '(?i)(?:ExtendedSecurity|ESU)'
    Defender = '(?i)(?:Defender|Security-Intelligence|MpEngine)'
}
$script:AIOUpdateNameFallbackClassifiers = @(
    [pscustomobject]@{ Pattern = '(?i)NDP\d|DotNet|NetFx';                   Category = 'DotNet';     Reason = 'Nombre de paquete .NET; metadatos internos no concluyentes' },
    [pscustomobject]@{ Pattern = '(?i)SafeOS|SafeOSDU|WinRE.*Update';          Category = 'SafeOS';     Reason = 'Nombre de paquete SafeOS/WinRE; metadatos internos no concluyentes' },
    [pscustomobject]@{ Pattern = '(?i)^SSU[-_.]|Servicing[ _-]?Stack';         Category = 'SSU';        Reason = 'Nombre de paquete de pila de mantenimiento' },
    [pscustomobject]@{ Pattern = '(?i)Enablement|Feature.?Update';              Category = 'Enablement'; Reason = 'Nombre de paquete de habilitacion' },
    [pscustomobject]@{ Pattern = '(?i)defender-dism|mpam-fe|mpam-d';           Category = 'Defender';   Reason = 'Nombre de paquete de Microsoft Defender' },
    [pscustomobject]@{ Pattern = '(?i)SetupDU|Setup.*Dynamic|Dynamic.*Setup';  Category = 'SetupDU';    Reason = 'Nombre de Setup Dynamic Update' },
    [pscustomobject]@{ Pattern = '(?i)SecureBoot|FirmwareUpdate|DBXUpdate';    Category = 'SecureBoot'; Reason = 'Nombre de actualizacion Secure Boot' }
)
$script:AIOUpdateAuxiliaryNamePatterns = @(
    '(?i)AggregatedMetadata.*\.cab$',
    '(?i)^DesktopDeployment(?:_x86)?\.cab$',
    '(?i)CompDB.*\.cab$'
)
$script:AIOUpdateArchitectureCatalog = @(
    [pscustomobject]@{ Name = 'x86';   Numeric = @('0');  Aliases = @('x86', 'i386', 'i686');       AdkFolder = 'x86';   EfiBootName = 'bootia32.efi' },
    [pscustomobject]@{ Name = 'x64';   Numeric = @('9');  Aliases = @('x64', 'amd64', 'x86_64');    AdkFolder = 'amd64'; EfiBootName = 'bootx64.efi' },
    [pscustomobject]@{ Name = 'arm64'; Numeric = @('12'); Aliases = @('arm64', 'aarch64');           AdkFolder = 'arm64'; EfiBootName = 'bootaa64.efi' },
    [pscustomobject]@{ Name = 'arm';   Numeric = @('5');  Aliases = @('arm');                        AdkFolder = 'arm';   EfiBootName = 'bootarm.efi' }
)
$script:AIOUpdateCanonicalPackageArchitecturePattern = '(?:x86|x64|arm64|arm)'
$script:AIOUpdateLegacyEnablementTargets = @(
    # Compatibilidad historica para EKB cuyos nombres no exponen el build destino.
    # Las ramas modernas con '<build>-Version-Enablement-Package' se detectan
    # dinamicamente y no deben agregarse a esta tabla.
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-1909Enablement-Package';          TargetBuild = 18363 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-20H2Enablement-Package';          TargetBuild = 19042 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-21H1Enablement-Package';          TargetBuild = 19043 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-21H2Enablement-Package';          TargetBuild = 19044 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-22H2Enablement-Package';          TargetBuild = 19045 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-ASOSFe22H2Enablement-Package';    TargetBuild = 20349 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-SV2Moment4Enablement-Package';    TargetBuild = 22631 },
    [pscustomobject]@{ Pattern = '(?i)Microsoft-Windows-23H2Enablement-Package';           TargetBuild = 22631 }
)

$script:AIOUpdateModernMsuPayloadPatterns = @(
    'SSU-*.cab', '*ServicingStack*.cab', '*AggregatedMetadata*.cab',
    # El inventario lee CAB/WIM; los PSF son payload y no se analizan aqui.
    '*Windows*.wim', 'RCU-*.wim', 'RCU-*.cab', '*Windows*.cab'
)
$script:AIOUpdateSsuCabPatterns = @('SSU-*.cab', '*SSU*.cab', '*ServicingStack*.cab', '*Servicing-Stack*.cab')
$script:AIOUpdateMetadataWimPatterns = @(
    'update.mum', '*enablement-package*.mum',
    '*_microsoft-windows-sysreset_*.manifest',
    '*_microsoft-windows-winpe_tools_*.manifest',
    '*_microsoft-windows-winre-tools_*.manifest',
    '*rejuvenation*.manifest',
    '*_microsoft-windows-servicingstack_*.manifest',
    '*_microsoft-updatetargeting-*os_*.manifest',
    '*_netfx4*.manifest'
)
$script:AIOUpdateMetadataCabPatterns = @($script:AIOUpdateMetadataWimPatterns + @('*.mum', '*.manifest'))
$script:AIOUpdateSetupSignalPatterns = @(
    '(?i)setupplatform\.(?:dll|exe)',
    '(?i)setuphost\.exe',
    '(?i)setupcore\.dll',
    '(?i)setupmgr\.dll',
    '(?i)(?:^|[\\/])sources[\\/](?:replacementmanifests|dlmanifests|compatresources|appraiser)'
)
$script:AIOUpdateSetupDependencySpecs = @(
    [pscustomobject]@{ Key = 'ServicingCommonDll'; Name = 'ServicingCommon.dll'; Candidates = @('sources\ServicingCommon.dll', 'Windows\System32\ServicingCommon.dll') },
    [pscustomobject]@{ Key = 'UnbclDll'; Name = 'unbcl.dll'; Candidates = @('sources\unbcl.dll', 'Windows\System32\migwiz\unbcl.dll') }
)
$script:AIOUpdateSetupCoreMuiCandidates = @('setup.exe.mui', 'setupplatform.exe.mui', 'w32uires.dll.mui', 'winsetup.dll.mui', 'spwizres.dll.mui')
$script:AIOUpdateMediaRootSetupFiles = @('setup.exe', 'bootmgr', 'bootmgr.efi', 'autorun.inf')
$script:AIOUpdateBootCaptureFileSpecs = @(
    [pscustomobject]@{ Key = 'SourcesSetupExe';     Candidates = @('sources\setup.exe') },
    [pscustomobject]@{ Key = 'SourcesSetupHostExe'; Candidates = @('sources\setuphost.exe') },
    [pscustomobject]@{ Key = 'BootMgfwEfi';         Candidates = @('Windows\Boot\EFI\bootmgfw.efi') },
    [pscustomobject]@{ Key = 'BootMgrEfi';          Candidates = @('Windows\Boot\EFI\bootmgr.efi') },
    [pscustomobject]@{ Key = 'MemtestEfi';          Candidates = @('Windows\Boot\EFI\memtest.efi') },
    [pscustomobject]@{ Key = 'BootStl';             Candidates = @('Windows\Boot\EFI\boot.stl') },
    [pscustomobject]@{ Key = 'BootPndStl';          Candidates = @('Windows\Boot\EFI\boot.pnd.stl') },
    [pscustomobject]@{ Key = 'EfiSys';              Candidates = @('Windows\Boot\DVD\EFI\en-US\efisys.bin', 'Windows\Boot\DVD\EFI\*\efisys.bin') },
    [pscustomobject]@{ Key = 'EfiSysNoPrompt';      Candidates = @('Windows\Boot\DVD\EFI\en-US\efisys_noprompt.bin', 'Windows\Boot\DVD\EFI\*\efisys_noprompt.bin') },
    [pscustomobject]@{ Key = 'BootMgfwExEfi';       Candidates = @('Windows\Boot\EFI_EX\bootmgfw_EX.efi') },
    [pscustomobject]@{ Key = 'BootMgrExEfi';        Candidates = @('Windows\Boot\EFI_EX\bootmgr_EX.efi') },
    [pscustomobject]@{ Key = 'EfiSysEx';            Candidates = @('Windows\Boot\DVD_EX\EFI\en-US\efisys_EX.bin', 'Windows\Boot\DVD_EX\EFI\*\efisys_EX.bin') },
    [pscustomobject]@{ Key = 'EfiSysNoPromptEx';    Candidates = @('Windows\Boot\DVD_EX\EFI\en-US\efisys_noprompt_EX.bin', 'Windows\Boot\DVD_EX\EFI\*\efisys_noprompt_EX.bin') }
)
$script:AIOUpdateBootCaptureDirectorySpecs = @(
    [pscustomobject]@{ Key = 'FontsExDirectory'; RelativePath = 'Windows\Boot\FONTS_EX' }
)
$script:AIOUpdateSetupMediaSyncSpecs = @(
    [pscustomobject]@{ Key = 'SourcesSetupExe';     RelativePath = 'sources\setup.exe' },
    [pscustomobject]@{ Key = 'SourcesSetupHostExe'; RelativePath = 'sources\setuphost.exe' }
)
$script:AIOUpdateBootMediaStaticSyncSpecs = @(
    [pscustomobject]@{ Key = 'BootStl';    RelativePath = 'efi\microsoft\boot\boot.stl' },
    [pscustomobject]@{ Key = 'BootPndStl'; RelativePath = 'efi\microsoft\boot\boot.pnd.stl' },
    [pscustomobject]@{ Key = 'MemtestEfi'; RelativePath = 'efi\microsoft\boot\memtest.efi' }
)
$script:AIOUpdateCapacityPolicy = [ordered]@{
    WimMultiplier = 2.5
    PackageMultiplier = 3.0
    ContingencyBytes = [int64](5GB)
}
$script:AIOUpdateMetadataPolicy = [ordered]@{
    MaxMetadataFiles = 500
    MaxMetadataTextBytes = 1048576
    MinimumSetupSignals = 2
}


function Test-AIOUpdateCheckpointLcuCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages
    )

    $items = @($Packages | Where-Object { $null -ne $_ -and $_.Category -eq 'LCU' -and $_.Extension -eq '.msu' })
    if ($items.Count -eq 0) { return $false }

    # Una evidencia explicita de Baseline/Checkpoint siempre gana.
    if (@($items | Where-Object { $_.IsCheckpoint }).Count -gt 0) { return $true }

    # Microsoft introdujo checkpoint cumulative updates con Windows 11 24H2 y
    # Windows Server 2025. Esta es una frontera historica de capacidad, no una
    # build base del modulo. Las familias se agrupan por su build CBS real, por
    # lo que futuras ramas (p. ej. 28xxx) nunca se mezclan con 26100.
    $builds = @(
        $items |
            Where-Object { $_.VersionReliable -and $_.VersionBuild -gt 0 } |
            ForEach-Object { [int]$_.VersionBuild } |
            Sort-Object -Unique
    )
    if ($builds.Count -ne 1) { return $false }
    if ($builds[0] -lt [int]$script:AIOUpdatePolicy.CheckpointLcuCapabilityFirstBuild) { return $false }

    $products = @($items | ForEach-Object { [string]$_.ProductHint } | Where-Object { $_ } | Sort-Object -Unique)
    if ($products -contains 'Windows10') { return $false }
    return $true
}

function Test-AIOUpdateWindows10EsuEraLcu {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    if ([string]$Package.Category -ne 'LCU') { return $false }

    # Preferir evidencia declarativa del propio paquete. El umbral historico
    # se conserva solo como respaldo para paquetes que no exponen la dependencia
    # ESU de forma legible en los metadatos extraidos.
    $esuProbe = @(
        $Package.CbsOwnIdentities
        $Package.CbsDependencies
        $Package.CbsParents
    ) -join "`n"
    if ($esuProbe -match '(?i)(?:ExtendedSecurityUpdates|ExtendedSecurity|ESU[-_. ]?(?:Licens|Preparation)|Package_for_ESU)') {
        return $true
    }

    try {
        $version = [version]$Package.Version
        return (
            $version.Build -eq [int]$script:AIOUpdatePolicy.Windows10EsuCbsBuild -and
            $version.Revision -ge [int]$script:AIOUpdatePolicy.Windows10EsuFirstSecurityRevision
        )
    }
    catch { return $false }
}

function Get-AIOUpdateExecutableVersion {
    [CmdletBinding()]
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $versionInfo = (Get-Item -LiteralPath $Path -ErrorAction Stop).VersionInfo
        foreach ($candidate in @($versionInfo.FileVersion, $versionInfo.ProductVersion)) {
            if ([string]$candidate -match '(\d+\.\d+\.\d+\.\d+)') {
                try { return [version]$matches[1] } catch {}
            }
        }
    }
    catch {}
    return $null
}

function Get-AIOUpdateRegistryKitsRoots {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $subKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $subKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows Kits\Installed Roots')
            if ($subKey) {
                $root = [string]$subKey.GetValue('KitsRoot10')
                if (-not [string]::IsNullOrWhiteSpace($root)) {
                    [void]$results.Add([pscustomobject]@{
                        Path   = [Environment]::ExpandEnvironmentVariables($root.Trim().Trim('"'))
                        Source = "Registro $view"
                    })
                }
            }
        }
        catch {}
        finally {
            if ($subKey) { $subKey.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
    }

    return [object[]]($results.ToArray() | Group-Object Path | ForEach-Object { $_.Group[0] })
}

function Get-AIOUpdateAdkUninstallLocations {
    [CmdletBinding()]
    param()

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64, [Microsoft.Win32.RegistryView]::Registry32)) {
        $baseKey = $null
        $uninstallKey = $null
        try {
            $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $uninstallKey = $baseKey.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
            if (-not $uninstallKey) { continue }

            foreach ($subKeyName in $uninstallKey.GetSubKeyNames()) {
                $itemKey = $null
                try {
                    $itemKey = $uninstallKey.OpenSubKey($subKeyName)
                    if (-not $itemKey) { continue }
                    $displayName = [string]$itemKey.GetValue('DisplayName')
                    if ($displayName -notmatch '(?i)Assessment and Deployment Kit|Windows Preinstallation Environment.*Add-ons?|Windows PE.*Add-on') { continue }
                    $installLocation = [string]$itemKey.GetValue('InstallLocation')
                    if (-not [string]::IsNullOrWhiteSpace($installLocation)) {
                        [void]$results.Add([pscustomobject]@{
                            Path        = [Environment]::ExpandEnvironmentVariables($installLocation.Trim().Trim('"'))
                            Source      = "Programas instalados $view"
                            DisplayName = $displayName
                        })
                    }
                }
                catch {}
                finally { if ($itemKey) { $itemKey.Dispose() } }
            }
        }
        catch {}
        finally {
            if ($uninstallKey) { $uninstallKey.Dispose() }
            if ($baseKey) { $baseKey.Dispose() }
        }
    }

    return [object[]]($results.ToArray() | Group-Object Path | ForEach-Object { $_.Group[0] })
}

function Get-AIOUpdateArchitectureCatalogEntry {
    [CmdletBinding()]
    param([AllowNull()] [object]$Architecture)

    $value = ([string]$Architecture).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }

    foreach ($entry in @($script:AIOUpdateArchitectureCatalog)) {
        $tokens = @($entry.Name) + @($entry.Numeric) + @($entry.Aliases) + @($entry.AdkFolder)
        if (@($tokens | Where-Object { ([string]$_).ToLowerInvariant() -eq $value }).Count -gt 0) {
            return $entry
        }
    }
    return $null
}

function Find-AIOUpdateAdkDismPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$DeploymentToolsRoot)

    $nativeArchitecture = if ($env:PROCESSOR_ARCHITEW6432) { [string]$env:PROCESSOR_ARCHITEW6432 } else { [string]$env:PROCESSOR_ARCHITECTURE }
    $nativeEntry = Get-AIOUpdateArchitectureCatalogEntry -Architecture $nativeArchitecture
    $folders = New-Object System.Collections.Generic.List[string]
    if ($nativeEntry -and $nativeEntry.AdkFolder) { [void]$folders.Add([string]$nativeEntry.AdkFolder) }
    if (-not $folders.Contains('x86')) { [void]$folders.Add('x86') }
    foreach ($folder in $folders) {
        $candidate = Join-Path $DeploymentToolsRoot "$folder\DISM\dism.exe"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
    }
    return $null
}

function Get-AIOUpdateAdkInfo {
    [CmdletBinding()]
    param()

    $candidateMap = @{}
    $addCandidate = {
        param([AllowNull()] [string]$CandidatePath, [string]$Source)
        if ([string]::IsNullOrWhiteSpace($CandidatePath)) { return }
        $expanded = [Environment]::ExpandEnvironmentVariables($CandidatePath.Trim().Trim('"')).TrimEnd('\')
        if ([string]::IsNullOrWhiteSpace($expanded)) { return }

        $possibleRoots = New-Object System.Collections.Generic.List[string]
        $leaf = Split-Path -Leaf $expanded
        if ($leaf -in @('Deployment Tools', 'Windows Preinstallation Environment')) {
            [void]$possibleRoots.Add((Split-Path -Parent $expanded))
        }
        elseif ($leaf -eq 'Assessment and Deployment Kit') {
            [void]$possibleRoots.Add($expanded)
        }
        else {
            [void]$possibleRoots.Add((Join-Path $expanded 'Assessment and Deployment Kit'))
            [void]$possibleRoots.Add($expanded)
        }

        foreach ($possibleRoot in $possibleRoots) {
            if (-not (Test-Path -LiteralPath $possibleRoot -PathType Container)) { continue }
            try { $resolved = (Resolve-Path -LiteralPath $possibleRoot -ErrorAction Stop).Path.TrimEnd('\') }
            catch { continue }
            if (-not $candidateMap.ContainsKey($resolved)) { $candidateMap[$resolved] = $Source }
        }
    }

    foreach ($entry in Get-AIOUpdateRegistryKitsRoots) { & $addCandidate $entry.Path $entry.Source }
    foreach ($entry in Get-AIOUpdateAdkUninstallLocations) { & $addCandidate $entry.Path $entry.Source }

    foreach ($environmentPath in @(
        $env:WindowsSdkDir,
        $env:KitsRoot10,
        $env:ADK_PATH,
        $env:ADKPath,
        $env:WINPEPATH,
        $env:WinPEPath
    )) {
        & $addCandidate $environmentPath 'Variable de entorno'
    }

    foreach ($standardPath in @(
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10' }),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Windows Kits\10' }),
        'C:\Program Files (x86)\Windows Kits\10',
        'C:\Program Files\Windows Kits\10',
        (Join-Path $script:AIOUpdateApplicationRoot 'WinPE'),
        (Join-Path $script:AIOUpdateApplicationRoot 'Tools\WinPE')
    )) {
        & $addCandidate $standardPath 'Ruta estandar'
    }

    $records = New-Object System.Collections.Generic.List[object]
    foreach ($adkRoot in $candidateMap.Keys) {
        $deploymentToolsRoot = Join-Path $adkRoot 'Deployment Tools'
        $winPeRoot = Join-Path $adkRoot 'Windows Preinstallation Environment'
        if (-not (Test-Path -LiteralPath $winPeRoot -PathType Container)) {
            $directWinPE = @($script:AIOUpdateArchitectureCatalog | ForEach-Object { [string]$_.AdkFolder }) | Where-Object {
                Test-Path -LiteralPath (Join-Path $adkRoot "$_\WinPE_OCs") -PathType Container
            }
            if (@($directWinPE).Count -gt 0) { $winPeRoot = $adkRoot }
        }
        $dismPath = if (Test-Path -LiteralPath $deploymentToolsRoot -PathType Container) {
            Find-AIOUpdateAdkDismPath -DeploymentToolsRoot $deploymentToolsRoot
        }
        else { $null }

        $architectures = New-Object System.Collections.Generic.List[string]
        # El modulo de Actualizaciones solo necesita localizar DISM y conocer
        # que arquitecturas WinPE existen. No requiere contar todos los CAB del
        # Add-on; omitir ese recorrido reduce notablemente el arranque.
        $packageCount = -1
        if (Test-Path -LiteralPath $winPeRoot -PathType Container) {
            foreach ($architecture in @($script:AIOUpdateArchitectureCatalog)) {
                $ocRoot = Join-Path $winPeRoot "$($architecture.AdkFolder)\WinPE_OCs"
                if (Test-Path -LiteralPath $ocRoot -PathType Container) {
                    [void]$architectures.Add([string]$architecture.Name)
                }
            }
        }

        if ($dismPath -or $architectures.Count -gt 0) {
            [void]$records.Add([pscustomobject]@{
                Root                = $adkRoot
                Source              = $candidateMap[$adkRoot]
                DeploymentToolsRoot = $(if ($dismPath) { $deploymentToolsRoot } else { $null })
                DismPath            = $dismPath
                DismVersion         = Get-AIOUpdateExecutableVersion -Path $dismPath
                WinPERoot           = $(if ($architectures.Count -gt 0) { $winPeRoot } else { $null })
                WinPEArchitectures  = [string[]]$architectures.ToArray()
                WinPEPackageCount   = $packageCount
            })
        }
    }

    $recordArray = [object[]]$records.ToArray()
    $bestDism = @($recordArray | Where-Object { $_.DismPath } | Sort-Object @{ Expression = {
        if ($_.DismVersion) { $_.DismVersion } else { [version]'0.0.0.0' }
    }; Descending = $true }, Root | Select-Object -First 1)
    $bestWinPE = @($recordArray | Where-Object { $_.WinPERoot } | Sort-Object @{ Expression = { @($_.WinPEArchitectures).Count }; Descending = $true }, Root | Select-Object -First 1)

    $dismRecord = if ($bestDism.Count -gt 0) { $bestDism[0] } else { $null }
    $winPeRecord = if ($bestWinPE.Count -gt 0) { $bestWinPE[0] } else { $null }
    $primary = if ($dismRecord) { $dismRecord } elseif ($winPeRecord) { $winPeRecord } else { $null }

    return [pscustomobject]@{
        Detected             = ($null -ne $primary)
        Root                 = $(if ($primary) { $primary.Root } else { $null })
        DetectionSources     = [string[]]@($recordArray | Select-Object -ExpandProperty Source -Unique)
        DeploymentToolsRoot  = $(if ($dismRecord) { $dismRecord.DeploymentToolsRoot } else { $null })
        DismPath             = $(if ($dismRecord) { $dismRecord.DismPath } else { $null })
        DismVersion          = $(if ($dismRecord) { $dismRecord.DismVersion } else { $null })
        WinPERoot            = $(if ($winPeRecord) { $winPeRecord.WinPERoot } else { $null })
        WinPEArchitectures   = $(if ($winPeRecord) { [string[]]$winPeRecord.WinPEArchitectures } else { [string[]]@() })
        WinPEPackageCount    = $(if ($winPeRecord) { [int]$winPeRecord.WinPEPackageCount } else { 0 })
        ActiveDismPath       = $null
        ActiveDismVersion    = $null
        ActiveDismSource     = $null
    }
}

function Initialize-AIOUpdateServicingEnvironment {
    [CmdletBinding()]
    param()

    $adkInfo = Get-AIOUpdateAdkInfo
    $systemVersion = Get-AIOUpdateExecutableVersion -Path $script:AIOUpdateSystemDismPath
    $selectedPath = $script:AIOUpdateSystemDismPath
    $selectedVersion = $systemVersion
    $selectedSource = 'Sistema'

    if ($adkInfo.DismPath) {
        $preferAdk = -not (Test-Path -LiteralPath $selectedPath -PathType Leaf)
        if (-not $preferAdk) {
            if ($adkInfo.DismVersion -and $systemVersion) { $preferAdk = ($adkInfo.DismVersion -gt $systemVersion) }
            elseif ($adkInfo.DismVersion -and -not $systemVersion) { $preferAdk = $true }
        }
        if ($preferAdk) {
            $selectedPath = $adkInfo.DismPath
            $selectedVersion = $adkInfo.DismVersion
            $selectedSource = 'ADK'
        }
    }

    if (-not (Test-Path -LiteralPath $selectedPath -PathType Leaf)) {
        throw 'No se encontro una herramienta DISM valida en Windows ni en el ADK.'
    }

    $script:AIOUpdateDismPath = $selectedPath
    $script:AIOUpdateDismSource = $selectedSource
    $adkInfo.ActiveDismPath = $selectedPath
    $adkInfo.ActiveDismVersion = $selectedVersion
    $adkInfo.ActiveDismSource = $selectedSource
    $script:AIOUpdateAdkInfo = $adkInfo

    # /English no es compatible con /?. Una consulta de montajes es de solo
    # lectura y devuelve la version nativa sin depender del idioma del host.
    $probe = Invoke-AIOUpdateDism -Arguments @('/Get-MountedImageInfo') -Context 'Comprobar DISM activo' -SuccessCodes @(0) -Quiet
    $nativeVersion = $null
    foreach ($line in $probe.Output) { if ([string]$line -match '^Version:\s*(\d+\.\d+\.\d+\.\d+)') { $nativeVersion = [version]$Matches[1]; break } }
    if (-not $nativeVersion) { throw "No se pudo confirmar la version nativa del DISM seleccionado. Registro DISM: $($probe.LogPath)" }
    $adkInfo | Add-Member -NotePropertyName ExecutableFileVersion -NotePropertyValue $selectedVersion -Force
    $adkInfo.ActiveDismVersion = $nativeVersion
    $selectedVersion = $nativeVersion
    Write-AIOUpdateLog -Level INFO -Message ("ADK detectado={0}; DISM activo={1} {2}; Ruta={3}." -f $adkInfo.Detected, $selectedSource, $selectedVersion, $selectedPath)
    return $adkInfo
}

function Show-AIOUpdateAdkStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$AdkInfo)

    Write-Host ''
    Write-Host ' Herramientas de mantenimiento:' -ForegroundColor Yellow
    if ($AdkInfo.Detected) {
        Write-Host ' ADK          : Detectado' -ForegroundColor Green
        if ($AdkInfo.Root) { Write-Host " Ruta ADK     : $($AdkInfo.Root)" -ForegroundColor White }
    }
    else {
        Write-Host ' ADK          : No detectado' -ForegroundColor Yellow
    }

    $versionText = if ($AdkInfo.ActiveDismVersion) { [string]$AdkInfo.ActiveDismVersion } else { 'N/D' }
    Write-Host " DISM activo  : $($AdkInfo.ActiveDismSource) | $versionText" -ForegroundColor White
    Write-Host " Ruta DISM    : $($AdkInfo.ActiveDismPath)" -ForegroundColor DarkGray
}

function Write-AIOUpdateLog {
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'ACTION', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        try {
            Write-Log -LogLevel $Level -Message "Updates: $Message"
        }
        catch {}
    }
}

function Wait-AIOUpdateUser {
    [CmdletBinding()]
    param(
        [string]$Message = 'Presiona ENTER para volver al menu principal'
    )

    try {
        [void](Read-Host "`n$Message")
    }
    catch {
        Start-Sleep -Seconds 2
    }
}

function Initialize-AIOUpdateTerminalState {
    [CmdletBinding()]
    param()

    $script:AIOUpdateLastTerminalState = [pscustomobject]@{
        Status               = 'NotStarted'
        Phase                = 'Inicializacion'
        Message              = $null
        MediaRoot            = $null
        BackupRoot           = $null
        ReportJson           = $null
        ReportHtml           = $null
        DiagnosticPath       = $null
        LogPath              = $null
        MediaMutationStarted = $false
        RestorationStatus    = 'No requerida'
        CompletedTargets     = [object[]]@()
        ErrorLine            = $null
        ErrorCode            = $null
    }
    return $script:AIOUpdateLastTerminalState
}

function Show-AIOUpdateTerminalSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Cancelled', 'Restored')]
        [string]$Status,
        [AllowNull()] [string]$Message
    )

    $state = $script:AIOUpdateLastTerminalState
    if (-not $state) { $state = Initialize-AIOUpdateTerminalState }
    $state.Status = $Status
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $state.Message = $Message }

    $title = switch ($Status) {
        'Success'   { 'INTEGRACION COMPLETADA Y VERIFICADA' }
        'Failed'    { 'INTEGRACION FINALIZADA CON ERROR' }
        'Cancelled' { 'OPERACION CANCELADA' }
        'Restored'  { 'RESTAURACION COMPLETADA Y VERIFICADA' }
    }
    $color = switch ($Status) {
        'Success'   { 'Green' }
        'Failed'    { 'Red' }
        'Cancelled' { 'Yellow' }
        'Restored'  { 'Green' }
    }

    Write-Host "`n=======================================================" -ForegroundColor $color
    Write-Host (" {0}" -f $title) -ForegroundColor $color
    Write-Host '=======================================================' -ForegroundColor $color
    if ($state.Message) { Write-Host " Mensaje          : $($state.Message)" -ForegroundColor White }
    if ($state.Phase) { Write-Host " Fase             : $($state.Phase)" -ForegroundColor White }
    if ($state.MediaRoot) { Write-Host " Medio            : $($state.MediaRoot)" -ForegroundColor White }
    Write-Host " Cambios iniciados: $([bool]$state.MediaMutationStarted)" -ForegroundColor White
    if ($Status -eq 'Failed' -or $state.RestorationStatus -ne 'No requerida') {
        $restoreColor = if ($state.RestorationStatus -like 'Restaurado*') { 'Green' } elseif ($state.RestorationStatus -like 'Fallo*') { 'Red' } else { 'Yellow' }
        Write-Host " Restauracion     : $($state.RestorationStatus)" -ForegroundColor $restoreColor
    }
    if ($state.BackupRoot) { Write-Host " Respaldo         : $($state.BackupRoot)" -ForegroundColor Gray }
    if ($state.ReportJson) { Write-Host " Reporte JSON     : $($state.ReportJson)" -ForegroundColor Gray }
    if ($state.ReportHtml) { Write-Host " Reporte HTML     : $($state.ReportHtml)" -ForegroundColor Gray }
    if ($state.DiagnosticPath) { Write-Host " Diagnostico      : $($state.DiagnosticPath)" -ForegroundColor Yellow }
    if ($state.LogPath) { Write-Host " Registro DISM    : $($state.LogPath)" -ForegroundColor DarkGray }
    if ($state.ErrorLine) { Write-Host " Linea            : $($state.ErrorLine)" -ForegroundColor DarkRed }
    if ($state.ErrorCode) { Write-Host " Codigo           : $($state.ErrorCode)" -ForegroundColor DarkRed }

    $completed = @($state.CompletedTargets | Where-Object { $null -ne $_ })
    if ($completed.Count -gt 0) {
        Write-Host "`n Operaciones completadas:" -ForegroundColor Cyan
        foreach ($item in @($completed | Select-Object -First 10)) {
            Write-Host "   [OK] $item" -ForegroundColor Green
        }
        if ($completed.Count -gt 10) {
            Write-Host "   ... y $($completed.Count - 10) operacion(es) adicional(es)." -ForegroundColor DarkGray
        }
    }
}

function Select-AIOUpdateFolder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    if (Get-Command Select-PathDialog -ErrorAction SilentlyContinue) {
        return Select-PathDialog -DialogType Folder -Title $Title
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = $Title
        $dialog.ShowNewFolderButton = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    }
    catch {
        Write-Warning "No se pudo abrir el selector de carpetas: $($_.Exception.Message)"
    }

    return $null
}

function Test-AIOUpdateAdministrator {
    [CmdletBinding()]
    param()

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Convert-AIOUpdateExitCodeToUInt32 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    return [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes($ExitCode), 0)
}

function Get-AIOUpdateExitCodeText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [int]$ExitCode
    )

    $unsigned = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $ExitCode
    switch ($unsigned) {
        0          { return 'Operacion completada.' }
        3010       { return 'Operacion completada; reinicio requerido.' }
        2148468766 { return 'El paquete no es aplicable a esta imagen.' }
        2148468771 { return 'El paquete requiere una pila de mantenimiento mas reciente.' }
        2148468785 { return 'Falta un manifiesto o paquete prerrequisito.' }
        2148468992 { return 'CBS no pudo procesar el paquete.' }
        2147956499 { return 'El almacen de componentes quedo en un estado no mantenible (0x80073713). Revisa el orden y los prerrequisitos de los paquetes.' }
        552        { return 'El MSU no pudo aplicar su archivo Unattend.xml (0x80070228). Puede ocurrir al procesar una LCU checkpoint desde una carpeta mezclada con otros MSU.' }
        87         { return 'Parametro incorrecto. Revisa la salida y el registro de DISM para identificar la opcion o combinacion rechazada.' }
        2147942487 { return 'Parametro incorrecto (HRESULT 0x80070057). Revisa la salida y el registro de DISM para identificar la opcion o combinacion rechazada.' }
        2147942512 { return 'No hay espacio suficiente en el disco.' }
        3242328343 { return 'El directorio de montaje ya esta en uso.' }
        default    { return 'Error DISM no clasificado por el modulo.' }
    }
}

function Initialize-AIOUpdateDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [switch]$Empty
    )

    if ($Empty -and (Test-Path -LiteralPath $Path)) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
}



function Get-AIOUpdateFileCacheKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    return ('{0}|{1}|{2}' -f $item.FullName.ToLowerInvariant(), [int64]$item.Length, [int64]$item.LastWriteTimeUtc.Ticks)
}

function Clear-AIOUpdateFileHashCache {
    [CmdletBinding()]
    param([AllowNull()] [string]$Path)

    if ([string]::IsNullOrWhiteSpace([string]$Path)) {
        $script:AIOUpdateFileHashCache = @{}
        return
    }
    try {
        $full = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant() + '|'
        foreach ($key in @($script:AIOUpdateFileHashCache.Keys)) {
            if ([string]$key -like "$full*") { $script:AIOUpdateFileHashCache.Remove($key) }
        }
    }
    catch {}
}

function Write-AIOUpdateAtomicText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [AllowEmptyString()] [string]$Text
    )

    $parent = Split-Path -Parent $Path
    Initialize-AIOUpdateDirectory -Path $parent
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Path) + '.tmp-' + [guid]::NewGuid().ToString('N'))
    $encoding = New-Object System.Text.UTF8Encoding($true)
    try {
        [System.IO.File]::WriteAllText($temporary, $Text, $encoding)
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Path, $null)
        }
        else {
            [System.IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Write-AIOUpdateAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$InputObject,
        [int]$Depth = 12
    )

    $json = $InputObject | ConvertTo-Json -Depth $Depth
    Write-AIOUpdateAtomicText -Path $Path -Text $json
}

function Copy-AIOUpdateFileVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction Stop
    $parent = Split-Path -Parent $Destination
    Initialize-AIOUpdateDirectory -Path $parent
    $temporary = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($Destination) + '.copy-' + [guid]::NewGuid().ToString('N'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $sourceStream = $null
    $destinationStream = $null
    try {
        $sourceStream = New-Object -TypeName System.IO.FileStream -ArgumentList @($sourceItem.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read, 1048576, [System.IO.FileOptions]::SequentialScan)
        $destinationStream = New-Object -TypeName System.IO.FileStream -ArgumentList @($temporary, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 1048576, [System.IO.FileOptions]::SequentialScan)
        $buffer = New-Object byte[] 1048576
        [int64]$length = 0
        while (($read = $sourceStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            [void]$sha.TransformBlock($buffer, 0, $read, $buffer, 0)
            $destinationStream.Write($buffer, 0, $read)
            $length += $read
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $destinationStream.Flush($true)
        $destinationStream.Dispose(); $destinationStream = $null
        $sourceStream.Dispose(); $sourceStream = $null
        if ($length -ne [int64]$sourceItem.Length) { throw "La copia de '$Source' no coincide en tamano." }

        if (Test-Path -LiteralPath $Destination -PathType Leaf) {
            [System.IO.File]::Replace($temporary, $Destination, $null)
        }
        else {
            [System.IO.File]::Move($temporary, $Destination)
        }
        [System.IO.File]::SetLastWriteTimeUtc($Destination, $sourceItem.LastWriteTimeUtc)
        Clear-AIOUpdateFileHashCache -Path $Destination
        $sourceHash = ([System.BitConverter]::ToString($sha.Hash)).Replace('-', '').ToUpperInvariant()
        $sourceKey = Get-AIOUpdateFileCacheKey -Path $Source
        $script:AIOUpdateFileHashCache[$sourceKey] = $sourceHash
        $destinationHash = Get-AIOUpdateFileSha256 -Path $Destination
        if ($sourceHash -ne $destinationHash) { throw "La copia de '$Source' no coincide por SHA-256." }
        return [pscustomobject]@{ SHA256 = $sourceHash; Length = $length; Destination = $Destination }
    }
    finally {
        if ($destinationStream) { $destinationStream.Dispose() }
        if ($sourceStream) { $sourceStream.Dispose() }
        $sha.Dispose()
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
    }
}

function Get-AIOUpdateRepositoryPackageFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$RepositoryRoot)

    $resolved = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $list = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($path in [System.IO.Directory]::EnumerateFiles($resolved, '*', [System.IO.SearchOption]::AllDirectories)) {
        $extension = [System.IO.Path]::GetExtension($path)
        if ($extension -ieq '.cab' -or $extension -ieq '.msu') {
            [void]$list.Add((New-Object -TypeName System.IO.FileInfo -ArgumentList $path))
        }
    }
    return [System.IO.FileInfo[]]@($list.ToArray() | Sort-Object FullName)
}

function Get-AIOUpdateUniquePackages {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyCollection()] [object[]]$Packages)

    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $unique = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages)) {
        $identity = [string](@($package.IdentityHints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)[0])
        $architecture = @($package.Architectures | Sort-Object) -join ','
        if ([string]::IsNullOrWhiteSpace([string]$package.KB) -and [string]::IsNullOrWhiteSpace($identity)) {
            $key = [string]$package.FullName
        }
        else {
            $key = '{0}|{1}|{2}|{3}|{4}|{5}' -f [string]$package.Category, [string]$package.KB, [string]$package.Version, [bool]$package.IsCheckpoint, $architecture, $identity
        }
        if ($seen.Add($key)) { [void]$unique.Add($package) }
        else {
            $script:AIOUpdateOptimizationStats.DuplicatePackagesSkipped++
            Write-AIOUpdateLog -Level WARN -Message "Paquete duplicado omitido antes de DISM: $($package.Name). Clave=$key"
        }
    }
    return [object[]]$unique.ToArray()
}

function Get-AIOUpdateTextSha256 {
    [CmdletBinding()]
    param([AllowEmptyString()] [string]$Text = '')

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}


function Get-AIOUpdateFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $key = Get-AIOUpdateFileCacheKey -Path $Path
    if ($script:AIOUpdateFileHashCache.ContainsKey($key)) {
        $script:AIOUpdateOptimizationStats.HashCacheHits++
        return [string]$script:AIOUpdateFileHashCache[$key]
    }
    $script:AIOUpdateOptimizationStats.HashCacheMisses++
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    if ([string]::IsNullOrWhiteSpace([string]$hash) -or $hash -notmatch '^[A-Fa-f0-9]{64}$') {
        throw "No se pudo obtener un SHA-256 valido para '$Path'."
    }
    $normalized = $hash.ToUpperInvariant()
    $script:AIOUpdateFileHashCache[$key] = $normalized
    return $normalized
}

function Get-AIOUpdateFilesIndexSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Records)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($record in @($Records | Sort-Object { ([string]$_.RelativePath).ToLowerInvariant() })) {
        $relative = ([string]$record.RelativePath).Replace('/', '\').TrimStart('\').ToLowerInvariant()
        $length = [int64]$record.Length
        $hash = ([string]$record.SHA256).ToUpperInvariant()
        [void]$lines.Add(('{0}|{1}|{2}' -f $relative, $length, $hash))
    }
    return Get-AIOUpdateTextSha256 -Text (($lines -join "`n") + "`n")
}

function Get-AIOUpdateLocalesFromLangIniPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $locales = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        $clean = ([string]$line).Trim()
        if ([string]::IsNullOrWhiteSpace($clean) -or $clean.StartsWith(';') -or $clean.StartsWith('#')) { continue }
        foreach ($pattern in @(
            '^\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*=',
            '=\s*([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)\s*$'
        )) {
            if ($clean -match $pattern) { [void]$locales.Add($Matches[1]) }
        }
    }
    return [string[]]@($locales | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
}


function Get-AIOUpdatePreflightBackupFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [switch]$IncludeSetupSurface
    )

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

    $addFile = {
        param([string]$Candidate)
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return }
        $item = Get-Item -LiteralPath $Candidate -Force -ErrorAction Stop
        if ($item.FullName -match '(?i)[\\/]AdminImagenOffline_Backup[\\/]') { return }
        if ($seen.Add($item.FullName)) { [void]$files.Add($item) }
    }

    foreach ($relative in @('sources\install.wim', 'sources\boot.wim')) {
        & $addFile (Join-Path $media $relative)
    }

    if ($IncludeSetupSurface) {
        foreach ($relativeDirectory in @('sources', 'boot', 'efi')) {
            $directory = Join-Path $media $relativeDirectory
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
            foreach ($path in [System.IO.Directory]::EnumerateFiles($directory, '*', [System.IO.SearchOption]::AllDirectories)) {
                & $addFile $path
            }
        }
        foreach ($relativeFile in $script:AIOUpdateMediaRootSetupFiles) {
            & $addFile (Join-Path $media $relativeFile)
        }
    }

    return [System.IO.FileInfo[]]@($files.ToArray() | Sort-Object FullName)
}

function Assert-AIOUpdateWorkspaceCapacity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$SessionRoot,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [switch]$IncludeBootWim
    )

    try {
        $installWim = Join-Path $MediaRoot 'sources\install.wim'
        $bootWim = Join-Path $MediaRoot 'sources\boot.wim'

        [int64]$wimBytes = 0
        if (Test-Path -LiteralPath $installWim -PathType Leaf) {
            $wimBytes += [int64](Get-Item -LiteralPath $installWim -ErrorAction Stop).Length
        }
        if ($IncludeBootWim -and (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            $wimBytes += [int64](Get-Item -LiteralPath $bootWim -ErrorAction Stop).Length
        }

        [int64]$packageBytes = 0
        $seen = @{}
        foreach ($package in @($Inventory | Where-Object { $_.Installable -and -not $_.Auxiliary })) {
            $path = [string]$package.FullName
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $key = $path.ToLowerInvariant()
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                $packageBytes += [int64](Get-Item -LiteralPath $path -ErrorAction Stop).Length
            }
        }

        # Margen conservador para montaje, WinRE, extracción de MSU/WIM,
        # reconstrucción y archivos temporales. Es deliberadamente mayor que
        # el tamaño comprimido para abortar antes de un commit por falta de disco.
        [double]$estimate = ([double]$wimBytes * [double]$script:AIOUpdateCapacityPolicy.WimMultiplier) + ([double]$packageBytes * [double]$script:AIOUpdateCapacityPolicy.PackageMultiplier) + [double]$script:AIOUpdateCapacityPolicy.ContingencyBytes
        [int64]$required = [int64][math]::Ceiling($estimate)

        $driveRoot = [System.IO.Path]::GetPathRoot($SessionRoot)
        if ([string]::IsNullOrWhiteSpace($driveRoot)) { return }

        $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $driveRoot
        $available = [int64]$drive.AvailableFreeSpace
        Write-AIOUpdateLog -Level INFO -Message (
            "Preflight de espacio: requerido aprox. {0:N2} GB; disponible {1:N2} GB en {2}. WIM={3:N2} GB, paquetes={4:N2} GB." -f
            ($required / 1GB), ($available / 1GB), $driveRoot, ($wimBytes / 1GB), ($packageBytes / 1GB)
        )

        if ($available -lt $required) {
            throw ((
                "Espacio insuficiente para la integracion offline. Requerido aproximado: {0:N2} GB; disponible: {1:N2} GB en {2}. " +
                ("Estimacion usada: (WIM x {0}) + (actualizaciones x {1}) + {2:N2} GB de contingencia." -f $script:AIOUpdateCapacityPolicy.WimMultiplier, $script:AIOUpdateCapacityPolicy.PackageMultiplier, ([double]$script:AIOUpdateCapacityPolicy.ContingencyBytes / 1GB))
            ) -f ($required / 1GB), ($available / 1GB), $driveRoot)
        }
    }
    catch {
        if ($_.Exception.Message -match '^Espacio insuficiente para la integracion offline') { throw }
        Write-AIOUpdateLog -Level WARN -Message "No se pudo completar el preflight de espacio de trabajo: $($_.Exception.Message)"
    }
}

function New-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [string]$BackupRoot,
        [switch]$IncludeSetupSurface
    )

    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    $preflightRoot = Join-Path $BackupRoot 'Preflight'
    $mirrorRoot = Join-Path $preflightRoot 'Media'
    $manifestPath = Join-Path $preflightRoot 'manifest.json'
    $incompletePath = Join-Path $preflightRoot 'BACKUP_INCOMPLETO.txt'

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' RESPALDO PREVIO OBLIGATORIO' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan

    Initialize-AIOUpdateDirectory -Path $preflightRoot -Empty
    Initialize-AIOUpdateDirectory -Path $mirrorRoot
    Set-Content -LiteralPath $incompletePath -Value 'El respaldo no se completo. No utilizar como restauracion.' -Encoding UTF8

    $files = @(Get-AIOUpdatePreflightBackupFiles -MediaRoot $media -IncludeSetupSurface:$IncludeSetupSurface)
    if ($files.Count -eq 0) {
        throw 'No se encontraron archivos del medio para crear el respaldo previo.'
    }

    [int64]$totalBytes = 0
    foreach ($file in $files) { $totalBytes += [int64]$file.Length }

    $driveRoot = [System.IO.Path]::GetPathRoot($BackupRoot)
    if (-not [string]::IsNullOrWhiteSpace($driveRoot)) {
        try {
            $drive = New-Object -TypeName System.IO.DriveInfo -ArgumentList $driveRoot
            [int64]$criticalBytes = 0
            foreach ($critical in @($files | Where-Object { $_.FullName -match '(?i)[\\/]sources[\\/](install|boot)\.wim$' })) {
                $criticalBytes += [int64]$critical.Length
            }
            [int64]$reserve = [math]::Max([int64](2GB), [int64]($criticalBytes + ($totalBytes * 0.20)))
            [int64]$required = $totalBytes + $reserve
            if ($drive.AvailableFreeSpace -lt $required) {
                throw ("Espacio insuficiente para el respaldo previo. Requerido aproximado: {0:N2} GB; disponible: {1:N2} GB." -f ($required / 1GB), ($drive.AvailableFreeSpace / 1GB))
            }
        }
        catch {
            if ($_.Exception.Message -match 'Espacio insuficiente') { throw }
            Write-AIOUpdateLog -Level WARN -Message "No se pudo comprobar el espacio libre del respaldo previo: $($_.Exception.Message)"
        }
    }

    Write-Host (" Archivos a respaldar : {0}" -f $files.Count) -ForegroundColor White
    Write-Host (" Tamano aproximado    : {0:N2} GB" -f ($totalBytes / 1GB)) -ForegroundColor White
    Write-Host " Destino              : $preflightRoot" -ForegroundColor White
    Write-Host ' Hash                 : SHA-256 para todos los archivos' -ForegroundColor DarkGray

    $records = New-Object System.Collections.Generic.List[object]
    $criticalNames = @('sources\install.wim', 'sources\boot.wim')
    $position = 0
    Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("0/{0} archivos verificados (0%)" -f $files.Count) -PercentComplete 0

    try {
        foreach ($file in $files) {
            $position++
            $relative = $file.FullName.Substring($media.Length).TrimStart('\')
            $destination = Join-Path $mirrorRoot $relative
            Initialize-AIOUpdateDirectory -Path (Split-Path -Parent $destination)

            if ($relative -in $criticalNames) {
                Write-Host "   [$position/$($files.Count)] Copiando y verificando $relative..." -ForegroundColor Gray
            }

            $copyResult = Copy-AIOUpdateFileVerified -Source $file.FullName -Destination $destination
            $sourceHash = [string]$copyResult.SHA256
            if ($relative -in $criticalNames) {
                Write-Host '      [VERIFICADO] SHA-256 coincide.' -ForegroundColor DarkGray
            }

            $percent = if ($files.Count -gt 0) { [math]::Min(100, [math]::Floor(($position * 100.0) / $files.Count)) } else { 100 }
            Write-Progress -Activity 'Respaldo previo obligatorio' -Status ("{0}/{1} archivos verificados ({2}%)" -f $position, $files.Count, $percent) -PercentComplete $percent

            [void]$records.Add([pscustomobject]@{
                RelativePath     = $relative
                Length           = [int64]$file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc
                SHA256           = $sourceHash
            })
        }
    }
    finally {
        Write-Progress -Activity 'Respaldo previo obligatorio' -Completed
    }

    $filesIndexSha256 = Get-AIOUpdateFilesIndexSha256 -Records ([object[]]$records.ToArray())
    $trustedLocales = @(Get-AIOUpdateLocalesFromLangIniPath -Path (Join-Path $media 'sources\lang.ini'))
    if ($IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
        throw 'No se pudo derivar una lista confiable de idiomas desde sources\lang.ini; no se continuara con una superficie Setup modificable.'
    }
    $manifest = [pscustomobject]@{
        SchemaVersion       = 3
        FormatVersion       = 3
        Structure           = 'Preflight\Media'
        CreatedAt           = (Get-Date).ToString('o')
        MediaRoot           = $media
        IncludeSetupSurface = [bool]$IncludeSetupSurface
        HashAlgorithm       = 'SHA256'
        HashCoverage        = 'AllFiles'
        LocalePolicy        = 'LangIni'
        TrustedLocales      = [string[]]$trustedLocales
        HashedFileCount     = $records.Count
        FilesIndexSha256    = $filesIndexSha256
        FileCount           = $records.Count
        TotalBytes          = $totalBytes
        Files               = [object[]]($records.ToArray())
    }
    Write-AIOUpdateAtomicJson -Path $manifestPath -InputObject $manifest -Depth 6

    # Releer inmediatamente evita aceptar un JSON truncado o no serializable.
    $writtenManifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    if ([int]$writtenManifest.SchemaVersion -ne 3 -or
        [int]$writtenManifest.FormatVersion -ne 3 -or
        [string]$writtenManifest.FilesIndexSha256 -ne $filesIndexSha256 -or
        [int]$writtenManifest.HashedFileCount -ne $records.Count) {
        throw 'El manifest.json del respaldo no supero la verificacion posterior a escritura.'
    }

    Remove-Item -LiteralPath $incompletePath -Force -ErrorAction Stop

    Write-AIOUpdateLog -Level INFO -Message ("Respaldo previo completado y verificado: {0} archivo(s), {1:N2} GB, {2} hashes SHA-256, indice={3}, destino '{4}'." -f $records.Count, ($totalBytes / 1GB), $records.Count, $filesIndexSha256, $preflightRoot)
    Write-Host " [OK] Respaldo previo completado y verificado ($($records.Count) hashes SHA-256)." -ForegroundColor Green

    return [pscustomobject]@{
        Success             = $true
        MediaRoot           = $media
        Root                = $preflightRoot
        MirrorRoot          = $mirrorRoot
        ManifestPath        = $manifestPath
        FileCount           = $records.Count
        TotalBytes          = $totalBytes
        IncludeSetupSurface = [bool]$IncludeSetupSurface
        SchemaVersion       = 3
        FormatVersion       = 3
        HashAlgorithm       = 'SHA256'
        TrustedLocales      = [string[]]$trustedLocales
        HashedFileCount     = $records.Count
        FilesIndexSha256    = $filesIndexSha256
    }
}

function Get-AIOUpdatePreflightBackupPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$context.MediaRoot) -or
        [string]::IsNullOrWhiteSpace([string]$context.MirrorRoot)) {
        return $null
    }

    try {
        $mediaRoot = [System.IO.Path]::GetFullPath([string]$context.MediaRoot).TrimEnd('\')
        $destinationPath = [System.IO.Path]::GetFullPath($Destination)
        $prefix = $mediaRoot + '\'
        if (-not $destinationPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }

        $relative = $destinationPath.Substring($prefix.Length)
        $candidate = Join-Path ([string]$context.MirrorRoot) $relative
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo resolver la copia Preflight de '$Destination': $($_.Exception.Message)"
    }

    return $null
}

function Initialize-AIOUpdatePreflightRuntimeIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$Context
    )

    $script:AIOUpdatePreflightPathIndex = @{}
    $script:AIOUpdatePreflightLocalesBySurface = @{
        Sources = @{}
        Boot    = @{}
        EfiBoot = @{}
    }
    $script:AIOUpdateSessionCreatedPathIndex = @{}
    $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
    $script:AIOUpdateTrustedLocales = @{}

    if ($null -eq $Context -or -not $Context.Success -or
        [string]::IsNullOrWhiteSpace([string]$Context.ManifestPath) -or
        -not (Test-Path -LiteralPath $Context.ManifestPath -PathType Leaf)) {
        return
    }

    try {
        $manifest = Get-Content -LiteralPath $Context.ManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        foreach ($record in @($manifest.Files)) {
            $relative = [string]$record.RelativePath
            if ([string]::IsNullOrWhiteSpace($relative)) { continue }
            $key = $relative.Replace('/', '\').TrimStart('\').ToLowerInvariant()
            $script:AIOUpdatePreflightPathIndex[$key] = $true

            foreach ($surface in @(
                @{ Name = 'Sources'; Pattern = '^(?i)sources[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' },
                @{ Name = 'Boot';    Pattern = '^(?i)boot[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' },
                @{ Name = 'EfiBoot'; Pattern = '^(?i)efi[\\/]microsoft[\\/]boot[\\/]([a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?)(?:[\\/]|$)' }
            )) {
                if ($relative -match $surface.Pattern) {
                    $locale = $Matches[1].ToLowerInvariant()
                    $script:AIOUpdatePreflightLocalesBySurface[$surface.Name][$locale] = $true
                }
            }
        }

        if ([int]$manifest.SchemaVersion -ne 3 -or [int]$manifest.FormatVersion -ne 3) {
            throw 'El indice de ejecucion solo admite manifiestos Preflight 3/3.'
        }
        $trustedLocales = @($manifest.TrustedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        if ([bool]$Context.IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
            throw 'El manifiesto Preflight 3/3 no contiene TrustedLocales para filtrar SetupDU.'
        }
        foreach ($locale in $trustedLocales) { $script:AIOUpdateTrustedLocales[$locale] = $true }
        foreach ($surfaceName in @('Sources', 'Boot', 'EfiBoot')) {
            $script:AIOUpdatePreflightLocalesBySurface[$surfaceName] = @{}
            foreach ($locale in $trustedLocales) {
                $script:AIOUpdatePreflightLocalesBySurface[$surfaceName][$locale] = $true
            }
        }
        if ($trustedLocales.Count -gt 0) {
            Write-AIOUpdateLog -Level INFO -Message "Politica de idiomas confiable leida del manifiesto Preflight 3/3: $($trustedLocales -join ', ')."
        }
    }
    catch {
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        Write-AIOUpdateLog -Level ERROR -Message "No se pudo crear el indice runtime del Preflight 3/3: $($_.Exception.Message)"
        throw
    }
}

function Get-AIOUpdatePreflightAllowedLocales {
    [CmdletBinding()]
    param(
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$Surface = 'Sources'
    )

    if (-not $script:AIOUpdatePreflightLocalesBySurface.ContainsKey($Surface)) { return @() }
    return [string[]]@($script:AIOUpdatePreflightLocalesBySurface[$Surface].Keys | Sort-Object)
}

function Get-AIOUpdateMediaRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success -or
        [string]::IsNullOrWhiteSpace([string]$context.MediaRoot)) { return $null }

    $mediaRoot = [System.IO.Path]::GetFullPath([string]$context.MediaRoot).TrimEnd('\')
    $candidate = [System.IO.Path]::GetFullPath($Path)
    $prefix = $mediaRoot + '\'
    if (-not $candidate.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $candidate.Substring($prefix.Length).Replace('/', '\').TrimStart('\')
}

function Register-AIOUpdateSessionCreatedPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [AllowNull()] [string]$Source,
        [string]$Reason = 'Creado por el modulo'
    )

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Path
        if ([string]::IsNullOrWhiteSpace([string]$relative)) { return $false }
        $key = $relative.ToLowerInvariant()
        if ($script:AIOUpdatePreflightPathIndex.ContainsKey($key)) { return $false }
        if (-not $script:AIOUpdateSessionCreatedPathIndex.ContainsKey($key)) {
            $event = [pscustomobject]@{
                RelativePath = $relative
                Destination  = [System.IO.Path]::GetFullPath($Path)
                Source       = $Source
                Reason       = $Reason
                CreatedAt    = (Get-Date).ToString('o')
            }
            $script:AIOUpdateSessionCreatedPathIndex[$key] = $event
            [void]$script:AIOUpdateSessionCreatedPathEvents.Add($event)
            Write-AIOUpdateLog -Level INFO -Message "Archivo registrado explicitamente como creado por la sesion: '$relative'."
        }
        return $true
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo registrar como creado por la sesion '$Path': $($_.Exception.Message)"
        return $false
    }
}

function Test-AIOUpdateSessionCreatedPath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Path
        if ([string]::IsNullOrWhiteSpace([string]$relative)) { return $false }
        return $script:AIOUpdateSessionCreatedPathIndex.ContainsKey($relative.ToLowerInvariant())
    }
    catch { return $false }
}

function Get-AIOUpdatePreflightPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $context = $script:AIOUpdatePreflightContext
    if ($null -eq $context -or -not $context.Success -or
        [string]::IsNullOrWhiteSpace([string]$context.MediaRoot)) {
        return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
    }

    try {
        $relative = Get-AIOUpdateMediaRelativePath -Path $Destination
        if ([string]::IsNullOrWhiteSpace([string]$relative)) {
            return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
        }
        $key = $relative.ToLowerInvariant()
        $tracked = $script:AIOUpdatePreflightPathIndex.ContainsKey($key)
        $criticalWim = $relative -match '^(?i)sources[\\/](install|boot)\.wim$'
        $setupSurface = [bool]$context.IncludeSetupSurface -and (
            $relative -match '^(?i)(sources|boot|efi)[\\/]' -or
            $relative -match '^(?i)(setup\.exe|bootmgr|bootmgr\.efi|autorun\.inf)$'
        )
        $covered = $criticalWim -or $setupSurface
        $knownNew = $covered -and -not $tracked -and (Test-AIOUpdateSessionCreatedPath -Path $Destination)

        return [pscustomobject]@{
            InsideMedia    = $true
            RelativePath   = $relative
            Tracked        = $tracked
            CoveredSurface = $covered
            KnownNew       = $knownNew
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo evaluar la cobertura Preflight de '$Destination': $($_.Exception.Message)"
        return [pscustomobject]@{ InsideMedia = $false; RelativePath = ''; Tracked = $false; CoveredSurface = $false; KnownNew = $false }
    }
}

function Test-AIOUpdateLocaleRelativePathAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RelativePath,
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$Surface = 'Sources'
    )

    $parts = @($RelativePath -split '[\\/]')
    if ($parts.Count -eq 0) { return $true }
    $candidate = [string]$parts[0]
    if ($candidate -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { return $true }

    $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $Surface)
    if ($allowed.Count -eq 0) { return $true }
    return ($candidate.ToLowerInvariant() -in $allowed)
}

function Remove-AIOUpdateUnexpectedMediaLocaleDirectories {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot
    )

    $removed = New-Object System.Collections.Generic.List[object]
    foreach ($surface in @(
        @{ Name = 'Sources'; Relative = 'sources' },
        @{ Name = 'Boot';    Relative = 'boot' },
        @{ Name = 'EfiBoot'; Relative = 'efi\microsoft\boot' }
    )) {
        $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $surface.Name)
        if ($allowed.Count -eq 0) { continue }

        $root = Join-Path $MediaRoot $surface.Relative
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($directory.Name -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { continue }
            $locale = $directory.Name.ToLowerInvariant()
            if ($locale -in $allowed) { continue }

            foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Recurse -Force -ErrorAction SilentlyContinue)) {
                Clear-AIOUpdateFileProtectionAttributes -Path $item.FullName
            }
            Clear-AIOUpdateFileProtectionAttributes -Path $directory.FullName
            Remove-Item -LiteralPath $directory.FullName -Recurse -Force -ErrorAction Stop
            [void]$removed.Add([pscustomobject]@{
                Surface = $surface.Name
                Locale  = $directory.Name
                Path    = $directory.FullName
            })
            Write-AIOUpdateLog -Level WARN -Message "Idioma no presente en Preflight eliminado de la superficie $($surface.Name): '$($directory.Name)' ($($directory.FullName))."
        }
    }

    return [object[]]($removed.ToArray())
}

function Test-AIOUpdateMediaLocalePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot)

    $unexpected = New-Object System.Collections.Generic.List[object]
    foreach ($surface in @(
        @{ Name = 'Sources'; Relative = 'sources' },
        @{ Name = 'Boot';    Relative = 'boot' },
        @{ Name = 'EfiBoot'; Relative = 'efi\microsoft\boot' }
    )) {
        $allowed = @(Get-AIOUpdatePreflightAllowedLocales -Surface $surface.Name)
        if ($allowed.Count -eq 0) { continue }
        $root = Join-Path $MediaRoot $surface.Relative
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if ($directory.Name -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') { continue }
            if ($directory.Name.ToLowerInvariant() -notin $allowed) {
                [void]$unexpected.Add([pscustomobject]@{ Surface = $surface.Name; Locale = $directory.Name; Path = $directory.FullName })
            }
        }
    }
    return [pscustomobject]@{
        Success            = ($unexpected.Count -eq 0)
        AllowedLocales     = [string[]]@($script:AIOUpdateTrustedLocales.Keys | Sort-Object)
        UnexpectedLocales  = [object[]]$unexpected.ToArray()
    }
}

function Invoke-AIOUpdateAtomicReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$MoveSource,
        [scriptblock]$Verifier
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        throw "${Context}: no existe el archivo de reemplazo '$Source'."
    }
    $destinationDirectory = Split-Path -Parent $Destination
    Initialize-AIOUpdateDirectory -Path $destinationDirectory
    $hadDestination = Test-Path -LiteralPath $Destination -PathType Leaf
    $original = if ($hadDestination) { Get-AIOUpdateFileAccessSnapshot -Path $Destination } else { $null }
    $rollbackPath = $null
    $originalMoved = $false
    $replacementStarted = $false
    try {
        if ($hadDestination) {
            $rollbackName = '.aio-rollback-' + [guid]::NewGuid().ToString('N') + '-' + [System.IO.Path]::GetFileName($Destination)
            $rollbackPath = Join-Path $destinationDirectory $rollbackName
            Clear-AIOUpdateFileProtectionAttributes -Path $Destination
            Move-Item -LiteralPath $Destination -Destination $rollbackPath -Force -ErrorAction Stop
            $originalMoved = $true
        }
        $replacementStarted = $true
        if ($MoveSource) {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        }
        else {
            Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
        }
        if ($Verifier) { & $Verifier $Destination }
        if ($rollbackPath -and (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) {
            Remove-Item -LiteralPath $rollbackPath -Force -ErrorAction Stop
        }
        return [pscustomobject]@{
            Success = $true; Destination = $Destination
            HadOriginal = $hadDestination; RollbackUsed = [bool]$rollbackPath
        }
    }
    catch {
        $replacementError = $_
        $restoreErrors = New-Object System.Collections.Generic.List[string]
        if ($replacementStarted -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            try { Remove-Item -LiteralPath $Destination -Force -ErrorAction Stop }
            catch { [void]$restoreErrors.Add($_.Exception.Message) }
        }
        if ($originalMoved) {
            try {
                if (-not (Test-Path -LiteralPath $rollbackPath -PathType Leaf)) { throw "No se encontro el original '$rollbackPath'." }
                Move-Item -LiteralPath $rollbackPath -Destination $Destination -Force -ErrorAction Stop
                $originalMoved = $false
            }
            catch { [void]$restoreErrors.Add($_.Exception.Message) }
        }
        if ($hadDestination -and -not $originalMoved -and $null -ne $original.AttributesValue -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
            try { Set-AIOUpdateCopyFileAttributes -Path $Destination -Attributes ([System.IO.FileAttributes]$original.AttributesValue) }
            catch { [void]$restoreErrors.Add($_.Exception.Message) }
        }
        $message = "${Context}: $($replacementError.Exception.Message)"
        if ($restoreErrors.Count -gt 0) { $message += " Restauracion incompleta; respaldo '$rollbackPath': $($restoreErrors -join ' | ')" }
        Write-AIOUpdateFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'AtomicReplacementFailed' -Message $message -OriginalDestination $original
        if ($restoreErrors.Count -gt 0) { throw $message }
        throw $replacementError
    }
}

function Resolve-AIOUpdatePreflightRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path.TrimEnd('\')
    if ((Split-Path -Leaf $resolved) -ine 'Preflight') {
        throw "Selecciona directamente la carpeta 'Preflight' del respaldo actual."
    }

    $manifestPath = Join-Path $resolved 'manifest.json'
    $mirrorRoot = Join-Path $resolved 'Media'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "La carpeta seleccionada no contiene el manifest.json actual: '$resolved'."
    }
    if (-not (Test-Path -LiteralPath $mirrorRoot -PathType Container)) {
        throw "La carpeta seleccionada no contiene la estructura actual 'Preflight\Media': '$resolved'."
    }

    return $resolved
}

function Read-AIOUpdatePreflightManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot
    )

    $root = Resolve-AIOUpdatePreflightRoot -Path $PreflightRoot
    $manifestPath = Join-Path $root 'manifest.json'
    $incomplete = Join-Path $root 'BACKUP_INCOMPLETO.txt'

    if (Test-Path -LiteralPath $incomplete -PathType Leaf) {
        throw "El respaldo Preflight esta marcado como incompleto: '$root'."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $requiredProperties = @(
        'SchemaVersion', 'FormatVersion', 'Structure', 'CreatedAt', 'MediaRoot',
        'IncludeSetupSurface', 'HashAlgorithm', 'HashCoverage', 'LocalePolicy',
        'TrustedLocales', 'HashedFileCount', 'FilesIndexSha256', 'FileCount',
        'TotalBytes', 'Files'
    )
    foreach ($propertyName in $requiredProperties) {
        if (-not $manifest.PSObject.Properties[$propertyName]) {
            throw "El manifiesto Preflight no contiene la propiedad obligatoria '$propertyName'."
        }
    }

    $schema = [int]$manifest.SchemaVersion
    $format = [int]$manifest.FormatVersion
    if ($schema -ne 3 -or $format -ne 3) {
        throw "Respaldo no compatible: se requiere SchemaVersion/FormatVersion 3/3 y se recibio $schema/$format. Los respaldos anteriores deben recrearse."
    }
    if ([string]$manifest.Structure -cne 'Preflight\Media') {
        throw "La estructura del respaldo no es valida: se requiere 'Preflight\Media'."
    }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.MediaRoot)) {
        throw 'El manifiesto Preflight no contiene MediaRoot.'
    }
    $createdAt = [datetimeoffset]::MinValue
    if (-not [datetimeoffset]::TryParse([string]$manifest.CreatedAt, [ref]$createdAt)) {
        throw 'El manifiesto Preflight contiene una fecha CreatedAt invalida.'
    }
    if (-not $manifest.Files -or @($manifest.Files).Count -eq 0) {
        throw 'El manifiesto Preflight no contiene archivos.'
    }
    if ([int]$manifest.FileCount -ne @($manifest.Files).Count) {
        throw 'FileCount no coincide con la lista Files del manifiesto Preflight.'
    }
    if ([string]$manifest.HashAlgorithm -cne 'SHA256' -or [string]$manifest.HashCoverage -cne 'AllFiles') {
        throw 'El manifiesto no declara cobertura SHA256 para todos los archivos.'
    }
    if ([string]$manifest.LocalePolicy -cne 'LangIni') {
        throw 'El manifiesto no declara la politica de idiomas LangIni.'
    }

    $trustedLocales = @($manifest.TrustedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($locale in $trustedLocales) {
        if ($locale -notmatch '^(?i)[a-z]{2,3}-[a-z0-9]{2,8}(?:-[a-z0-9]{2,8})?$') {
            throw "El manifiesto contiene un idioma confiable invalido: '$locale'."
        }
    }
    if ([bool]$manifest.IncludeSetupSurface -and $trustedLocales.Count -eq 0) {
        throw 'El manifiesto no contiene idiomas confiables para la superficie Setup.'
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    [int64]$declaredBytes = 0
    foreach ($record in @($manifest.Files)) {
        foreach ($propertyName in @('RelativePath', 'Length', 'LastWriteTimeUtc', 'SHA256')) {
            if (-not $record.PSObject.Properties[$propertyName]) {
                throw "Un registro de archivos no contiene la propiedad obligatoria '$propertyName'."
            }
        }
        $relative = [string]$record.RelativePath
        if ([string]::IsNullOrWhiteSpace($relative) -or [System.IO.Path]::IsPathRooted($relative) -or
            (@($relative -split '[\\/]' | Where-Object { $_ -eq '..' }).Count -gt 0)) {
            throw "El manifiesto Preflight contiene una ruta invalida: '$relative'."
        }
        if (-not $seen.Add($relative)) {
            throw "El manifiesto Preflight contiene una ruta duplicada: '$relative'."
        }
        if ($null -eq $record.Length -or [int64]$record.Length -lt 0) {
            throw "El registro '$relative' no contiene una longitud valida."
        }
        $hash = [string]$record.SHA256
        if ($hash -notmatch '^[A-Fa-f0-9]{64}$') {
            throw "El registro '$relative' no contiene un SHA-256 valido."
        }
        $declaredBytes += [int64]$record.Length
    }

    if ([int64]$manifest.TotalBytes -ne $declaredBytes) {
        throw 'TotalBytes no coincide con la suma de los registros Files.'
    }
    if ([int]$manifest.HashedFileCount -ne @($manifest.Files).Count) {
        throw 'HashedFileCount no coincide con la lista Files.'
    }
    $indexHash = Get-AIOUpdateFilesIndexSha256 -Records @($manifest.Files)
    if ($indexHash -ne [string]$manifest.FilesIndexSha256) {
        throw 'FilesIndexSha256 no coincide con el contenido del manifiesto.'
    }

    $mirrorRoot = Join-Path $root 'Media'
    if (-not (Test-Path -LiteralPath $mirrorRoot -PathType Container)) {
        throw "No existe la carpeta Media del respaldo: '$mirrorRoot'."
    }

    return [pscustomobject]@{
        Root         = $root
        ManifestPath = $manifestPath
        MirrorRoot   = $mirrorRoot
        Manifest     = $manifest
    }
}

function Test-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot,
        [ValidateSet('All', 'InstallWim', 'BootWim', 'Setup')]
        [string]$Scope = 'All'
    )

    $context = Read-AIOUpdatePreflightManifest -PreflightRoot $PreflightRoot
    $records = @($context.Manifest.Files)

    switch ($Scope) {
        'InstallWim' { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\install.wim' }) }
        'BootWim'    { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\boot.wim' }) }
        'Setup'      { $records = @($records | Where-Object { $_.RelativePath -notin @('sources\install.wim', 'sources\boot.wim') }) }
    }

    $errors = New-Object System.Collections.Generic.List[string]
    [int64]$validatedBytes = 0
    [int]$validatedHashes = 0
    foreach ($record in $records) {
        $source = Join-Path $context.MirrorRoot ([string]$record.RelativePath)
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            [void]$errors.Add("Falta '$($record.RelativePath)'.")
            continue
        }

        $file = Get-Item -LiteralPath $source -ErrorAction Stop
        if ([int64]$file.Length -ne [int64]$record.Length) {
            [void]$errors.Add("Tamano incorrecto en '$($record.RelativePath)'.")
            continue
        }
        $validatedBytes += [int64]$file.Length

        $expectedHash = [string]$record.SHA256
        if ($expectedHash -notmatch '^[A-Fa-f0-9]{64}$') {
            [void]$errors.Add("SHA-256 ausente o invalido en '$($record.RelativePath)'.")
            continue
        }
        $hash = Get-AIOUpdateFileSha256 -Path $source
        $validatedHashes++
        if ($hash -ne $expectedHash) {
            [void]$errors.Add("SHA-256 incorrecto en '$($record.RelativePath)'.")
        }
    }

    if ($Scope -eq 'All' -and [int64]$context.Manifest.TotalBytes -ne $validatedBytes) {
        [void]$errors.Add('TotalBytes no coincide con los archivos validados.')
    }
    if ($Scope -eq 'All' -and [int]$context.Manifest.HashedFileCount -ne $validatedHashes) {
        [void]$errors.Add('HashedFileCount no coincide con los hashes verificados.')
    }

    return [pscustomobject]@{
        Success          = ($errors.Count -eq 0)
        Root             = $context.Root
        MirrorRoot       = $context.MirrorRoot
        Manifest         = $context.Manifest
        Scope            = $Scope
        RecordCount      = $records.Count
        ValidatedBytes   = $validatedBytes
        ValidatedHashes  = $validatedHashes
        Errors           = [string[]]($errors.ToArray())
    }
}

function Restore-AIOUpdatePreflightBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$PreflightRoot,
        [AllowNull()] [string]$TargetMediaRoot,
        [ValidateSet('All', 'InstallWim', 'BootWim', 'Setup')]
        [string]$Scope = 'All'
    )

    Assert-AIOUpdateNoMountedImages

    $validation = Test-AIOUpdatePreflightBackup -PreflightRoot $PreflightRoot -Scope $Scope
    if (-not $validation.Success) {
        throw "El respaldo Preflight no supero la validacion: $($validation.Errors -join ' ')"
    }

    $manifest = $validation.Manifest
    $target = if (-not [string]::IsNullOrWhiteSpace($TargetMediaRoot)) {
        (Resolve-Path -LiteralPath $TargetMediaRoot -ErrorAction Stop).Path.TrimEnd('\')
    }
    elseif (Test-Path -LiteralPath ([string]$manifest.MediaRoot) -PathType Container) {
        (Resolve-Path -LiteralPath ([string]$manifest.MediaRoot) -ErrorAction Stop).Path.TrimEnd('\')
    }
    else {
        throw 'El medio original ya no existe. Especifica TargetMediaRoot.'
    }

    if (-not (Test-AIOUpdateMediaWritable -MediaRoot $target)) {
        throw "El destino de restauracion no es escribible: '$target'."
    }

    $records = @($manifest.Files)
    switch ($Scope) {
        'InstallWim' { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\install.wim' }) }
        'BootWim'    { $records = @($records | Where-Object { $_.RelativePath -ieq 'sources\boot.wim' }) }
        'Setup'      { $records = @($records | Where-Object { $_.RelativePath -notin @('sources\install.wim', 'sources\boot.wim') }) }
    }
    if ($records.Count -eq 0) {
        throw "El respaldo no contiene archivos para el alcance '$Scope'."
    }

    $started = Get-Date
    $restored = New-Object System.Collections.Generic.List[object]
    $expected = @{}
    foreach ($record in $records) {
        $expected[[string]$record.RelativePath.ToLowerInvariant()] = $true
    }

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' RESTAURANDO RESPALDO PREFLIGHT' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan
    Write-Host " Origen  : $($validation.Root)" -ForegroundColor White
    Write-Host " Destino : $target" -ForegroundColor White
    Write-Host " Alcance : $Scope" -ForegroundColor White
    Write-Host " Archivos: $($records.Count)" -ForegroundColor White

    $position = 0
    Write-Progress -Activity 'Restaurando respaldo Preflight' -Status "0/$($records.Count) archivos restaurados (0%)" -PercentComplete 0

    try {
        foreach ($record in $records) {
            $position++
            $relative = [string]$record.RelativePath
            $source = Join-Path $validation.MirrorRoot $relative
            $destination = Join-Path $target $relative
            $expectedLength = [int64]$record.Length
            $expectedHash = [string]$record.SHA256

            if ($relative -match '(?i)^sources[\\/](install|boot)\.wim$') {
                Write-Host "   [$position/$($records.Count)] Restaurando $relative..." -ForegroundColor Gray
            }

            $verifier = {
                param($path)
                $file = Get-Item -LiteralPath $path -ErrorAction Stop
                if ([int64]$file.Length -ne $expectedLength) {
                    throw "La restauracion de '$relative' no coincide en tamano."
                }
                if (-not [string]::IsNullOrWhiteSpace($expectedHash)) {
                    $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($hash -ne $expectedHash) {
                        throw "La restauracion de '$relative' no coincide por SHA-256."
                    }
                }
            }.GetNewClosure()

            [void](Invoke-AIOUpdateAtomicReplacement -Source $source -Destination $destination -Context "Restaurando $relative" -Verifier $verifier)
            try {
                (Get-Item -LiteralPath $destination -ErrorAction Stop).LastWriteTimeUtc = [datetime]$record.LastWriteTimeUtc
            }
            catch {}

            [void]$restored.Add([pscustomobject]@{
                RelativePath = $relative
                Length       = $expectedLength
                SHA256       = $expectedHash
            })
            
            $percent = if ($records.Count -gt 0) { [math]::Min(100, [math]::Floor(($position * 100.0) / $records.Count)) } else { 100 }
            Write-Progress -Activity 'Restaurando respaldo Preflight' -Status ("{0}/{1} archivos restaurados ({2}%)" -f $position, $records.Count, $percent) -PercentComplete $percent
        }
    } finally {
        Write-Progress -Activity 'Restaurando respaldo Preflight' -Completed
    }

    $removedExtras = New-Object System.Collections.Generic.List[string]
    if ($Scope -in @('All', 'Setup')) {
        $protected = @{}
        if ($Scope -eq 'Setup') {
            $protected['sources\install.wim'] = $true
            $protected['sources\boot.wim'] = $true
        }

        foreach ($relativeDirectory in @('sources', 'boot', 'efi')) {
            $directory = Join-Path $target $relativeDirectory
            if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }

            foreach ($file in @(Get-ChildItem -LiteralPath $directory -Recurse -File -Force -ErrorAction SilentlyContinue)) {
                $relative = $file.FullName.Substring($target.Length).TrimStart('\')
                $key = $relative.ToLowerInvariant()
                if ($protected.ContainsKey($key)) { continue }
                if (-not $expected.ContainsKey($key)) {
                    Clear-AIOUpdateFileProtectionAttributes -Path $file.FullName
                    Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                    [void]$removedExtras.Add($relative)
                }
            }

            foreach ($folder in @(Get-ChildItem -LiteralPath $directory -Recurse -Directory -Force -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)) {
                if (@(Get-ChildItem -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
                    Remove-Item -LiteralPath $folder.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }

        foreach ($relative in $script:AIOUpdateMediaRootSetupFiles) {
            $key = $relative.ToLowerInvariant()
            $candidate = Join-Path $target $relative
            if (-not $expected.ContainsKey($key) -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
                Clear-AIOUpdateFileProtectionAttributes -Path $candidate
                Remove-Item -LiteralPath $candidate -Force -ErrorAction Stop
                [void]$removedExtras.Add($relative)
            }
        }
    }

    $ended = Get-Date
    $result = [pscustomobject]@{
        Success          = $true
        Status           = 'Restored'
        MediaRoot        = $target
        Scope            = $Scope
        PreflightRoot    = $validation.Root
        StartedAt        = $started
        EndedAt          = $ended
        DurationSeconds  = [math]::Round(($ended - $started).TotalSeconds, 2)
        RestoredFiles    = [object[]]($restored.ToArray())
        RemovedExtraFiles = [string[]]($removedExtras.ToArray())
    }

    $reportRoot = Join-Path $script:AIOUpdateReportsRoot 'Restauracion'
    $report = Export-AIOUpdateStructuredReport -Status 'Restored' -OutputDirectory $reportRoot -MediaRoot $target -StartedAt $started -EndedAt $ended -CompletedTargets @("Restauracion $Scope completada") -PreflightBackup ([pscustomobject]@{ Root = $validation.Root; ManifestPath = Join-Path $validation.Root 'manifest.json'; FileCount = $records.Count; TotalBytes = [int64]$manifest.TotalBytes }) -Options ([pscustomobject]@{ Scope = $Scope; RemovedExtraFiles = $removedExtras.Count })
    $result | Add-Member -NotePropertyName StructuredReport -NotePropertyValue $report

    Write-AIOUpdateLog -Level INFO -Message "Restauracion Preflight completada. Alcance=$Scope; archivos=$($restored.Count); extras eliminados=$($removedExtras.Count); destino='$target'."
    Write-Host " [OK] Restauracion completada y verificada." -ForegroundColor Green
    Write-Host " Reporte JSON: $($report.JsonPath)" -ForegroundColor DarkGray
    Write-Host " Reporte HTML: $($report.HtmlPath)" -ForegroundColor DarkGray
    return $result
}

function ConvertTo-AIOUpdateNativeArgument {
    [CmdletBinding()]
    param(
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($null -eq $Argument -or $Argument.Length -eq 0) { return '""' }
    if ($Argument -notmatch '[\s"]') { return $Argument }

    # Reglas de escape de CommandLineToArgvW: duplica las barras que
    # preceden comillas y las barras finales cuando el argumento va citado.
    $builder = New-Object System.Text.StringBuilder
    $backslash = [char]92
    [void]$builder.Append('"')
    $slashes = 0

    foreach ($character in $Argument.ToCharArray()) {
        if ($character -eq $backslash) {
            $slashes++
            continue
        }

        if ($character -eq '"') {
            if ($slashes -gt 0) {
                [void]$builder.Append(($backslash.ToString() * ($slashes * 2)))
            }
            [void]$builder.Append($backslash)
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }

        if ($slashes -gt 0) {
            [void]$builder.Append(($backslash.ToString() * $slashes))
            $slashes = 0
        }
        [void]$builder.Append($character)
    }

    if ($slashes -gt 0) {
        [void]$builder.Append(($backslash.ToString() * ($slashes * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Add-AIOUpdateDismTranscriptLine {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Line
    )

    if (-not $script:AIOUpdateDismTranscript) { return }
    if ($null -eq $Line) { $Line = '' }
    try {
        ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Line) |
            Out-File -LiteralPath $script:AIOUpdateDismTranscript -Append -Encoding utf8
    }
    catch {}
}

function ConvertTo-AIOUpdateDismDisplayLine {
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string]$Line,
        [AllowNull()] [string]$DisplayIdentity
    )
    if ([string]::IsNullOrWhiteSpace($DisplayIdentity)) { return $Line }
    $match = [regex]::Match([string]$Line, '^(?<prefix>\s*Processing\s+\d+\s+of\s+\d+\s+-)(?<label>.*)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success -and $match.Groups['label'].Value.Trim() -in @('', 'Expand')) {
        return ($match.Groups['prefix'].Value + ' ' + $DisplayIdentity.Trim())
    }
    # Conservar las identidades reales y cualquier otro mensaje de DISM.
    return $Line
}

function Invoke-AIOUpdateDism {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$Context,

        [int[]]$SuccessCodes = @(0, 3010),

        [switch]$AllowNotApplicable,

        [switch]$NoThrow,

        [switch]$Quiet,

        [AllowNull()]
        [string]$DisplayIdentity
    )

    if (-not (Test-Path -LiteralPath $script:AIOUpdateDismPath -PathType Leaf)) {
        throw "No se encontro DISM en '$script:AIOUpdateDismPath'."
    }

    $safeContext = ($Context -replace '[^A-Za-z0-9_.-]', '_')
    if ($safeContext.Length -gt 70) { $safeContext = $safeContext.Substring(0, 70) }
    $dismLog = if ($script:AIOUpdateSessionRoot) {
        Join-Path $script:AIOUpdateSessionRoot ("DISM_{0}_{1}.log" -f (Get-Date -Format 'HHmmssfff'), $safeContext)
    }
    else {
        Join-Path $env:TEMP ("AIO_DISM_{0}.log" -f [guid]::NewGuid().ToString('N'))
    }

    # Microsoft no admite /English junto a /? o su alias /Get-Help.
    # Mantener ingles en las consultas que se analizan; la ayuda usa el idioma nativo.
    $helpRequested = (@($Arguments | Where-Object { $_ -in @('/?', '/Get-Help') }).Count -gt 0)
    $effectiveArguments = @($Arguments)
    if ($helpRequested) {
        $effectiveArguments = @($effectiveArguments | Where-Object { $_ -ine '/English' })
    }
    elseif ('/English' -notin $effectiveArguments) {
        $effectiveArguments = @('/English') + $effectiveArguments
    }
    $explicitLogPaths = @($effectiveArguments | Where-Object { $_ -match '^/LogPath:' })
    if ($explicitLogPaths.Count -gt 0) {
        $dismLog = ([string]$explicitLogPaths[-1]).Substring(9)
    }
    else {
        $effectiveArguments += "/LogPath:$dismLog"
    }

    Write-AIOUpdateLog -Level ACTION -Message "$Context | dism.exe $($effectiveArguments -join ' ')"
    Add-AIOUpdateDismTranscriptLine -Line ("INICIO | {0} | dism.exe {1}" -f $Context, ($effectiveArguments -join ' '))

    if (-not $Quiet) {
        Write-Host "`n>> $Context" -ForegroundColor Cyan
    }

    $captured = New-Object System.Collections.Generic.List[string]
    $nativeArgumentLine = (@($effectiveArguments | ForEach-Object { ConvertTo-AIOUpdateNativeArgument -Argument ([string]$_) }) -join ' ')
    $process = $null
    $processStarted = $false
    $recoveredAfterCaptureError = $false

    try { 
        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $script:AIOUpdateDismPath
        $startInfo.Arguments = $nativeArgumentLine
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $false

        $rewritePackageIdentity = (-not $Quiet -and -not [string]::IsNullOrWhiteSpace($DisplayIdentity))
        if ($Quiet -or $rewritePackageIdentity) {
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.CreateNoWindow = $true
        }

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $startInfo

        if (-not $process.Start()) {
            throw 'System.Diagnostics.Process.Start() devolvio False.'
        }
        $processStarted = $true

        $stdoutTask = $null
        $stderrTask = $null
        if ($Quiet) {
            # Lectura asincrona de ambos canales para evitar interbloqueos
            # si alguno llena su buffer antes de finalizar dism.exe.
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
        }
        elseif ($rewritePackageIdentity) {
            # Para MSU modernos DISM puede mostrar "Processing ... - Expand"
            # o dejar vacia la etiqueta mientras procesa el contenedor. El mantenimiento real no cambia:
            # solo se sustituye esa etiqueta visual por la identidad CBS que ya
            # fue obtenida de update.mum durante el inventario.
            #
            # DISM actualiza la barra de porcentaje con retornos de carro (CR).
            # StreamReader.ReadLine() convierte cada refresco en una entrada
            # separada; por eso no debemos usar Write-Host normal para esas
            # entradas o cada porcentaje termina en una linea nueva.
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $progressActive = $false
            $lastProgressLine = $null

            while (($line = $process.StandardOutput.ReadLine()) -ne $null) {
                $rawLine = [string]$line
                [void]$captured.Add($rawLine)
                Add-AIOUpdateDismTranscriptLine -Line $rawLine

                $displayLine = ConvertTo-AIOUpdateDismDisplayLine -Line $rawLine -DisplayIdentity $DisplayIdentity

                # Barra nativa de DISM: [=====      12.3%      ]
                # Se redibuja sobre la misma linea y se omiten refrescos
                # consecutivos identicos solo en la consola.
                $isProgressLine = [regex]::IsMatch(
                    $displayLine,
                    '^\s*\[[=\s]*\d{1,3}(?:\.\d+)?%[=\s]*\]\s*$',
                    [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
                )

                if ($isProgressLine) {
                    if ($displayLine -ne $lastProgressLine) {
                        Write-Host ("`r" + $displayLine) -NoNewline
                        $lastProgressLine = $displayLine
                    }
                    $progressActive = $true
                    continue
                }

                # DISM usa retornos de carro para refrescar la barra. Al pasar
                # por StreamReader.ReadLine(), Windows PowerShell 5.1 puede
                # entregar una cadena vacia entre dos porcentajes. Esa linea
                # vacia NO marca el fin del progreso: se conserva arriba en el
                # transcript, pero no se imprime ni reinicia el estado visual.
                if ($progressActive -and [string]::IsNullOrWhiteSpace($displayLine)) {
                    continue
                }

                if ($progressActive) {
                    # Solo una linea real posterior al porcentaje cierra la barra.
                    Write-Host ''
                    $progressActive = $false
                    $lastProgressLine = $null
                }

                Write-Host $displayLine
            }

            if ($progressActive) {
                Write-Host ''
            }
        }

        $process.WaitForExit()
        $exitCode = [int]$process.ExitCode

        if ($Quiet) {
            $quietBlocks = @()
            if ($stdoutTask) { $quietBlocks += [string]$stdoutTask.GetAwaiter().GetResult() }
            if ($stderrTask) { $quietBlocks += [string]$stderrTask.GetAwaiter().GetResult() }

            foreach ($block in $quietBlocks) {
                if ([string]::IsNullOrWhiteSpace($block)) { continue }
                foreach ($line in @($block -split "\r?\n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$captured.Add([string]$line)
                    Add-AIOUpdateDismTranscriptLine -Line ([string]$line)
                }
            }
        }
        elseif ($rewritePackageIdentity -and $stderrTask) {
            $stderrBlock = [string]$stderrTask.GetAwaiter().GetResult()
            if (-not [string]::IsNullOrWhiteSpace($stderrBlock)) {
                foreach ($line in @($stderrBlock -split "\r?\n")) {
                    if ([string]::IsNullOrWhiteSpace($line)) { continue }
                    [void]$captured.Add([string]$line)
                    Add-AIOUpdateDismTranscriptLine -Line ([string]$line)
                    Write-Host ([string]$line) -ForegroundColor DarkYellow
                }
            }
        }
    }
    catch {
        $captureException = $_
        if ($processStarted) {
            # Un fallo de la capa de captura/presentacion no debe convertir una
            # operacion DISM ya iniciada en un falso FailedToStart ni permitir
            # que el llamador desmonte la imagen mientras dism.exe sigue vivo.
            try {
                if ($startInfo.RedirectStandardOutput -and -not $process.HasExited) {
                    try {
                        $remainingStdout = [string]$process.StandardOutput.ReadToEnd()
                        if (-not [string]::IsNullOrEmpty($remainingStdout)) {
                            foreach ($recoveryLine in @($remainingStdout -split "\r?\n")) {
                                [void]$captured.Add([string]$recoveryLine)
                                Add-AIOUpdateDismTranscriptLine -Line ([string]$recoveryLine)
                            }
                        }
                    }
                    catch {}
                }

                $process.WaitForExit()
                $exitCode = [int]$process.ExitCode

                if ($stderrTask) {
                    try {
                        $stderrBlock = [string]$stderrTask.GetAwaiter().GetResult()
                        if (-not [string]::IsNullOrEmpty($stderrBlock)) {
                            foreach ($recoveryLine in @($stderrBlock -split "\r?\n")) {
                                [void]$captured.Add([string]$recoveryLine)
                                Add-AIOUpdateDismTranscriptLine -Line ([string]$recoveryLine)
                            }
                        }
                    }
                    catch {}
                }

                $recoveredAfterCaptureError = $true
                $recoveryMessage = "La captura/presentacion de DISM produjo un error despues de iniciar el proceso, pero se espero su finalizacion y se recupero el codigo real: $($captureException.Exception.Message)"
                Write-AIOUpdateLog -Level WARN -Message $recoveryMessage
                Add-AIOUpdateDismTranscriptLine -Line ("WARN | {0}" -f $recoveryMessage)
            }
            catch {
                $recoveredAfterCaptureError = $false
            }
        }

        if (-not $recoveredAfterCaptureError) {
            $prefix = if ($processStarted) { 'Error durante la ejecucion/captura de DISM' } else { 'No se pudo iniciar DISM' }
            $message = "$prefix para '$Context': $($captureException.Exception.Message). Registro DISM: $dismLog"
            Write-AIOUpdateLog -Level ERROR -Message $message
            Add-AIOUpdateDismTranscriptLine -Line ("ERROR | {0}" -f $message)
            if (-not $NoThrow) { throw $message }
            return [pscustomobject]@{
                Success       = $false
                State         = if ($processStarted) { 'ExecutionCaptureFailed' } else { 'FailedToStart' }
                ErrorMessage  = $message
                ExitCode      = -1
                UnsignedCode  = [uint32]4294967295
                Output        = [string[]]($captured.ToArray())
                LogPath       = $dismLog
                Context       = $Context
            }
        }
    }
    finally {
        if ($process) {
            try { $process.Dispose() } catch {}
        }
    }

    $unsigned = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $exitCode
    $notApplicable = ($unsigned -eq [uint32]2148468766)
    $success = ($SuccessCodes -contains $exitCode) -or ($AllowNotApplicable -and $notApplicable)
    Add-AIOUpdateDismTranscriptLine -Line ("FIN | {0} | Codigo={1} | Hex=0x{2}" -f $Context, $exitCode, ('{0:X8}' -f $unsigned))

    if ($success) {
        $state = if ($notApplicable) { 'NotApplicable' } else { 'Success' }
        $level = if ($notApplicable) { 'WARN' } else { 'INFO' }
        Write-AIOUpdateLog -Level $level -Message "$Context finalizo con codigo $exitCode (0x$('{0:X8}' -f $unsigned))."
        return [pscustomobject]@{
            Success       = $true
            State         = $state
            ExitCode      = $exitCode
            UnsignedCode  = $unsigned
            Output        = [string[]]($captured.ToArray())
            LogPath       = $dismLog
            Context       = $Context
        }
    }

    $hexCode = '0x{0:X8}' -f $unsigned
    $description = Get-AIOUpdateExitCodeText -ExitCode $exitCode
    $message = "$Context fallo. Codigo DISM: $exitCode ($hexCode). $description"
    # Las consultas Quiet pueden fallar antes de crear la sesion/diagnostico ZIP.
    # Conservar su detalle nativo tambien en Registro.log y en la excepcion.
    $nativeDetail = @($captured.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 12)
    if ($nativeDetail.Count -gt 0) {
        $message += "`nSalida DISM:`n" + ($nativeDetail -join "`n")
    }
    $message += "`nRegistro DISM: $dismLog"
    Write-AIOUpdateLog -Level ERROR -Message $message

    if (-not $NoThrow) { throw $message }

    return [pscustomobject]@{
        Success       = $false
        State         = 'Failed'
        ErrorMessage  = $message
        ExitCode      = $exitCode
        UnsignedCode  = $unsigned
        Output        = [string[]]($captured.ToArray())
        LogPath       = $dismLog
        Context       = $Context
    }
}


function Initialize-AIOUpdateWimApi {
    [CmdletBinding()]
    param()

    if ($script:AIOUpdateWimApiReady -and ('AIOUpdate.WimNative' -as [type])) {
        return $true
    }

    try {
        if (-not ('AIOUpdate.WimNative' -as [type])) {
            $typeDefinition = @'
using System;
using System.Runtime.InteropServices;

namespace AIOUpdate {
    public static class WimNative {
        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        private static extern IntPtr WIMCreateFile(
            string pszWimPath,
            uint dwDesiredAccess,
            uint dwCreationDisposition,
            uint dwFlagsAndAttributes,
            uint dwCompressionType,
            out uint pdwCreationResult);

        [DllImport("wimgapi.dll", SetLastError = true, ExactSpelling = true)]
        public static extern IntPtr WIMLoadImage(IntPtr hWim, uint dwImageIndex);

        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        public static extern int WIMSetTemporaryPath(IntPtr hWim, string pszPath);

        [DllImport("wimgapi.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
        public static extern int WIMExtractImagePath(
            IntPtr hImage,
            string pszImagePath,
            string pszDestinationPath,
            uint dwExtractFlags);

        [DllImport("wimgapi.dll", SetLastError = true, ExactSpelling = true)]
        public static extern int WIMCloseHandle(IntPtr hObject);

        public static IntPtr OpenRead(string path, out uint creationResult) {
            // Primero usa los flags documentados. Algunos MSU-WIM modernos
            // requieren el flag de compatibilidad 0x20000000 que usa W10UI,
            // por lo que se reintenta solo si la apertura normal falla.
            IntPtr handle = WIMCreateFile(path, 0x80000000u, 3u, 0u, 0u, out creationResult);
            if (handle == IntPtr.Zero) {
                handle = WIMCreateFile(path, 0x80000000u, 3u, 0x20000000u, 0u, out creationResult);
            }
            return handle;
        }

        public static int LastError {
            get { return Marshal.GetLastWin32Error(); }
        }
    }
}
'@
            Add-Type -TypeDefinition $typeDefinition -Language CSharp -ErrorAction Stop
        }

        $script:AIOUpdateWimApiReady = $true
        return $true
    }
    catch {
        $script:AIOUpdateWimApiReady = $false
        Write-AIOUpdateLog -Level WARN -Message "No se pudo inicializar wimgapi.dll: $($_.Exception.Message)"
        return $false
    }
}

function Test-AIOUpdateWimContainerSignature {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($stream.Length -lt 8) { return $false }
        $buffer = New-Object byte[] 8
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -lt 8) { return $false }
        $signature = [System.Text.Encoding]::ASCII.GetString($buffer, 0, 5)
        return ($signature -eq 'MSWIM')
    }
    catch {
        return $false
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
}

function Invoke-AIOUpdateWimlibRead {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string[]]$Arguments)
    $wimlib = Find-AIOUpdateWimlib
    if (-not $wimlib) { return [pscustomobject]@{ Success = $false; Output = @(); ExitCode = -1 } }
    # Invocacion directa con argumentos separados; compatible con Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $global:LASTEXITCODE = -1
        $output = @(& $wimlib @Arguments 2>&1 | ForEach-Object { [string]$_ })
        $code = $global:LASTEXITCODE
        return [pscustomobject]@{ Success = ($code -eq 0); Output = [string[]]$output; ExitCode = $code }
    }
    catch { return [pscustomobject]@{ Success = $false; Output = @($_.Exception.Message); ExitCode = -1 } }
}

function Get-AIOUpdateCachedWimFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$StagingRoot
    )
    $file = Get-Item -LiteralPath $WimPath -ErrorAction Stop
    # Cache de esta sesion, invalidada al cambiar el WIM o el indice donante.
    $identity = '{0}|{1}|{2}|{3}' -f $file.FullName.ToLowerInvariant(), $file.Length, $file.LastWriteTimeUtc.Ticks, $Index
    $root = Join-Path (Join-Path $StagingRoot 'RecoveryDependencyCache') (Get-AIOUpdateTextSha256 -Text $identity)
    $relative = $ImagePath.Replace('/', '\').TrimStart('\')
    if ($relative -match '(^|\\)\.{1,2}(\\|$)' -or $relative -match '[:*?"<>|\x00-\x1f]' -or -not $relative) { throw 'Ruta interna WIM no valida.' }
    $destination = Join-Path $root $relative
    if (-not $script:AIOUpdateExtractedFileCache) { $script:AIOUpdateExtractedFileCache = @{} }
    if ($script:AIOUpdateExtractedFileCache.ContainsKey($destination) -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
        $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($hash -eq $script:AIOUpdateExtractedFileCache[$destination]) { return $destination }
    }
    # Una copia alterada nunca puede volver a aparecer como donante tras un fallo.
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Force -ErrorAction Stop }
    if (Invoke-AIOUpdateWimExtractPath -WimPath $WimPath -Index $Index -ImagePath $relative -DestinationPath $destination -TemporaryPath $ScratchPath) {
        $script:AIOUpdateExtractedFileCache[$destination] = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        return $destination
    }
    return $null
}


function Get-AIOUpdateWimImageEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath
    )

    if (-not (Test-Path -LiteralPath $WimPath -PathType Leaf)) { return @() }
    if (-not (Test-AIOUpdateWimContainerSignature -Path $WimPath)) { return @() }

    $file = Get-Item -LiteralPath $WimPath -ErrorAction Stop
    $cacheKey = ('{0}|{1}|{2}' -f $file.FullName.ToLowerInvariant(), [int64]$file.Length, [int64]$file.LastWriteTimeUtc.Ticks)
    if ($script:AIOUpdateWimEntryCache.ContainsKey($cacheKey)) {
        return [string[]]$script:AIOUpdateWimEntryCache[$cacheKey]
    }

    $result = Invoke-AIOUpdateWimlibRead -Arguments @('dir', $file.FullName, '1')
    if (-not $result.Success) {
        $result = Invoke-AIOUpdateDism -Arguments @('/List-Image', "/ImageFile:$($file.FullName)", '/Index:1') -Context "Enumerando contenedor WIM $($file.Name)" -SuccessCodes @(0) -NoThrow -Quiet
    }

    if (-not $result.Success) {
        return @()
    }

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($line in @($result.Output)) {
        $value = ([string]$line).Trim().Replace('/', '\')
        if ([string]::IsNullOrWhiteSpace($value)) { continue }

        $candidate = $null
        if ($value -match '^\\(.+)$') {
            $candidate = $matches[1].Trim()
        }
        elseif ($value -match '^(?!Deployment Image Servicing|Version:|Image File:|Image Index:|The operation completed)(.+\.(?:cab|wim|psf|mum|manifest))$') {
            $candidate = $matches[1].Trim()
        }

        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            [void]$entries.Add($candidate.TrimStart('\'))
        }
    }

    $unique = [string[]]@($entries.ToArray() | Sort-Object -Unique)
    $script:AIOUpdateWimEntryCache[$cacheKey] = $unique
    return $unique
}

function Invoke-AIOUpdateWimExtractPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [string]$DestinationPath,
        [Parameter(Mandatory = $true)] [string]$TemporaryPath,
        [ValidateRange(1, 2147483647)] [int]$Index = 1
    )
    $relative = $ImagePath.Replace('\', '/').TrimStart('/')
    if (-not $relative -or $relative -match '(^|/)\.{1,2}(/|$)' -or $relative -match '[:*?"<>|\x00-\x1f]') { throw 'Ruta interna WIM no valida.' }
    $work = Join-Path $TemporaryPath ('WimExtract_' + [guid]::NewGuid().ToString('N'))
    Initialize-AIOUpdateDirectory -Path $work
    Initialize-AIOUpdateDirectory -Path (Split-Path -Parent $DestinationPath)
    $leaf = ($relative -split '/')[-1]
    $extracted = Join-Path $work $leaf
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    [uint32]$creationResult = 0
    $hWim = [IntPtr]::Zero
    $hImage = [IntPtr]::Zero
    try {
        $result = Invoke-AIOUpdateWimlibRead -Arguments @('extract', $WimPath, [string]$Index, ('/' + $relative), "--dest-dir=$work", '--no-acls', '--no-attributes', '--no-globs')
        if ($result.Success -and (Test-Path -LiteralPath $extracted -PathType Leaf) -and
            -not ((Get-Item -LiteralPath $extracted).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Move-Item -LiteralPath $extracted -Destination $DestinationPath -Force -ErrorAction Stop
            Write-AIOUpdateLog -Level INFO -Message ("Extraccion selectiva wimlib: indice={0}; ruta={1}; segundos={2:N2}." -f $Index, $ImagePath, $timer.Elapsed.TotalSeconds)
            return $true
        }
        Remove-Item -LiteralPath $extracted -Force -ErrorAction SilentlyContinue
        if (-not (Initialize-AIOUpdateWimApi)) { return $false }
        $hWim = [AIOUpdate.WimNative]::OpenRead($WimPath, [ref]$creationResult)
        if ($hWim -eq [IntPtr]::Zero) { throw "WIMCreateFile fallo con Win32=$([AIOUpdate.WimNative]::LastError)." }
        if ([AIOUpdate.WimNative]::WIMSetTemporaryPath($hWim, $work) -eq 0) { throw "WIMSetTemporaryPath fallo con Win32=$([AIOUpdate.WimNative]::LastError)." }
        $hImage = [AIOUpdate.WimNative]::WIMLoadImage($hWim, [uint32]$Index)
        if ($hImage -eq [IntPtr]::Zero) { throw "WIMLoadImage fallo con Win32=$([AIOUpdate.WimNative]::LastError)." }
        foreach ($candidate in @($relative.Replace('/', '\'), ('\' + $relative.Replace('/', '\')))) {
            Remove-Item -LiteralPath $extracted -Force -ErrorAction SilentlyContinue
            if ([AIOUpdate.WimNative]::WIMExtractImagePath($hImage, $candidate, $extracted, 0) -ne 0 -and
                (Test-Path -LiteralPath $extracted -PathType Leaf) -and
                -not ((Get-Item -LiteralPath $extracted).Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                Move-Item -LiteralPath $extracted -Destination $DestinationPath -Force -ErrorAction Stop
                Write-AIOUpdateLog -Level INFO -Message ("Extraccion selectiva wimgapi: indice={0}; ruta={1}; segundos={2:N2}." -f $Index, $ImagePath, $timer.Elapsed.TotalSeconds)
                return $true
            }
        }
        Write-AIOUpdateLog -Level INFO -Message "No se pudo extraer selectivamente '$ImagePath' del indice $Index; se usara el respaldo nativo si es necesario."
        return $false
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "Extraccion selectiva WIM fallo para '$ImagePath': $($_.Exception.Message)"
        return $false
    }
    finally {
        if ($hImage -ne [IntPtr]::Zero) { try { [void][AIOUpdate.WimNative]::WIMCloseHandle($hImage) } catch {} }
        if ($hWim -ne [IntPtr]::Zero) { try { [void][AIOUpdate.WimNative]::WIMCloseHandle($hWim) } catch {} }
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}


function Expand-AIOUpdateWimContainerEntries {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot,
        [Parameter(Mandatory = $true)] [string[]]$Pattern,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot,
        [switch]$AllowFullApplyFallback
    )

    Initialize-AIOUpdateDirectory -Path $DestinationRoot
    $entries = @(Get-AIOUpdateWimImageEntries -WimPath $WimPath)

    $selected = @(
        $entries |
            Where-Object {
                $entry = [string]$_
                $leaf = [System.IO.Path]::GetFileName($entry)
                foreach ($wildcard in $Pattern) {
                    if ($entry -like $wildcard -or $leaf -like $wildcard) { return $true }
                }
                return $false
            } |
            Sort-Object -Unique
    )

    # Algunos WIM de LCU contienen mas de un archivo llamado update.mum en
    # rutas internas. La identidad autoritativa del paquete esta en el
    # update.mum de la raiz del WIM. Si existe, nunca debemos dejar que un
    # update.mum anidado lo sustituya al aplanar las rutas de extraccion.
    if ($Pattern -contains 'update.mum') {
        $rootUpdateMum = @(
            $entries | Where-Object { ([string]$_).TrimStart('\') -ieq 'update.mum' } | Select-Object -First 1
        )
        if ($rootUpdateMum.Count -gt 0) {
            $selected = @(
                $selected | Where-Object {
                    $leaf = [System.IO.Path]::GetFileName([string]$_)
                    if ($leaf -ieq 'update.mum') {
                        return (([string]$_).TrimStart('\') -ieq 'update.mum')
                    }
                    return $true
                }
            )
        }
    }

    $extracted = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $failedSelective = $false
    $position = 0
    foreach ($entry in $selected) {
        $position++
        $leaf = [System.IO.Path]::GetFileName([string]$entry)
        if ([string]::IsNullOrWhiteSpace($leaf)) { continue }
        $destination = Join-Path $DestinationRoot $leaf
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($leaf)
            $extension = [System.IO.Path]::GetExtension($leaf)
            $destination = Join-Path $DestinationRoot ("{0}_{1:D3}{2}" -f $stem, $position, $extension)
        }

        $temp = Join-Path $ScratchRoot ('WimApi_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $temp
        try {
            if (Invoke-AIOUpdateWimExtractPath -WimPath $WimPath -ImagePath ([string]$entry) -DestinationPath $destination -TemporaryPath $temp) {
                [void]$extracted.Add((Get-Item -LiteralPath $destination -ErrorAction Stop))
            }
            else {
                $failedSelective = $true
            }
        }
        finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (($selected.Count -eq 0 -or $failedSelective) -and $AllowFullApplyFallback) {
        $applyRoot = Join-Path $ScratchRoot ('WimApply_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $applyRoot -Empty
        try {
            $applyResult = Invoke-AIOUpdateDism -Arguments @(
                '/Apply-Image',
                "/ImageFile:$WimPath",
                '/Index:1',
                "/ApplyDir:$applyRoot",
                '/NoAcl:all'
            ) -Context "Extraccion de respaldo del contenedor WIM $([System.IO.Path]::GetFileName($WimPath))" -SuccessCodes @(0) -NoThrow -Quiet

            if (-not $applyResult.Success) {
                Initialize-AIOUpdateDirectory -Path $applyRoot -Empty
                $applyResult = Invoke-AIOUpdateDism -Arguments @(
                    '/Apply-Image',
                    "/ImageFile:$WimPath",
                    '/Index:1',
                    "/ApplyDir:$applyRoot"
                ) -Context "Extraccion de respaldo WIM sin /NoAcl $([System.IO.Path]::GetFileName($WimPath))" -SuccessCodes @(0) -NoThrow -Quiet
            }

            if ($applyResult.Success) {
                $rootAppliedUpdateMum = Join-Path $applyRoot 'update.mum'
                $hasRootAppliedUpdateMum = (($Pattern -contains 'update.mum') -and (Test-Path -LiteralPath $rootAppliedUpdateMum -PathType Leaf))

                foreach ($candidate in @(Get-ChildItem -LiteralPath $applyRoot -Recurse -File -ErrorAction SilentlyContinue)) {
                    $relative = $candidate.FullName.Substring($applyRoot.Length).TrimStart('\')
                    $matchesPattern = $false
                    foreach ($wildcard in $Pattern) {
                        if ($relative -like $wildcard -or $candidate.Name -like $wildcard) {
                            $matchesPattern = $true
                            break
                        }
                    }
                    if (-not $matchesPattern) { continue }

                    if ($hasRootAppliedUpdateMum -and $candidate.Name -ieq 'update.mum' -and
                        -not [string]::Equals($candidate.FullName, $rootAppliedUpdateMum, [System.StringComparison]::OrdinalIgnoreCase)) {
                        continue
                    }

                    $destination = Join-Path $DestinationRoot $candidate.Name
                    Copy-Item -LiteralPath $candidate.FullName -Destination $destination -Force -ErrorAction Stop
                    [void]$extracted.Add((Get-Item -LiteralPath $destination -ErrorAction Stop))
                }
            }
        }
        finally {
            Remove-Item -LiteralPath $applyRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [System.IO.FileInfo[]]@($extracted.ToArray() | Sort-Object FullName -Unique)
}

function Assert-AIOUpdateNoMountedImages {
    [CmdletBinding()]
    param()
    $mounted = @(Get-AIOUpdateNativeMountedImages)
    if ($mounted.Count) { throw "Hay imagenes montadas por DISM: $(($mounted.Path) -join ', '). Desmonta esos montajes antes de continuar." }
}

function Test-AIOUpdateMediaWritable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaRoot
    )

    $probe = Join-Path $MediaRoot ('.aio_write_' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllText($probe, 'test', [System.Text.Encoding]::ASCII)
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $false
    }
}

function Get-AIOUpdateKbId {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, '(?i)KB\d{6,8}')
    if ($match.Success) { return $match.Value.ToUpperInvariant() }
    return $null
}

function Get-AIOUpdateVersionFromText {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return [version]'0.0.0.0' }
    $matches = [regex]::Matches($Text, '(?<!\d)(\d+)\.(\d+)\.(\d+)\.(\d+)(?!\d)')
    for ($i = $matches.Count - 1; $i -ge 0; $i--) {
        $candidate = $null
        if ([version]::TryParse($matches[$i].Value, [ref]$candidate) -and
            (($candidate.Major -in @(6, 10) -and $candidate.Build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) -or
             $candidate.Major -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild)) {
            return $candidate
        }
    }
    return [version]'0.0.0.0'
}

function Get-AIOUpdatePackageVersionInfo {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$FileName,
        [AllowNull()] [string]$UpdateMumText
    )

    # Autoridad principal: update.mum. Se aceptan dos formas de version CBS:
    #   10.0.BUILD.REVISION
    #   BUILD.REVISION.MAJOR.MINOR  (formato de Package_for_RollupFix moderno)
    # La segunda se normaliza a 10.0.BUILD.REVISION.
    $sources = @(
        [pscustomobject]@{ Name = 'update.mum'; Text = [string]$UpdateMumText },
        [pscustomobject]@{ Name = 'Nombre';     Text = [string]$FileName }
    )

    foreach ($source in $sources) {
        if ([string]::IsNullOrWhiteSpace($source.Text)) { continue }

        $candidates = New-Object System.Collections.Generic.List[System.Version]
        foreach ($match in [regex]::Matches($source.Text, '(?<!\d)(\d+)\.(\d+)\.(\d{4,9})\.(\d+)(?!\d)')) {
            try {
                $candidate = [version]$match.Value
                $isWindowsVersion = (
                    ($candidate.Major -eq 10 -and $candidate.Minor -eq 0 -and $candidate.Build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) -or
                    ($candidate.Major -eq 6 -and $candidate.Minor -ge 0 -and $candidate.Minor -le 3 -and $candidate.Build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild)
                )
                if ($isWindowsVersion) { [void]$candidates.Add($candidate) }
            }
            catch {}
        }

        if ($candidates.Count -gt 0) {
            $selected = $candidates.ToArray() |
                Sort-Object @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Revision }; Descending = $true } |
                Select-Object -First 1
            return [pscustomobject]@{
                Version  = [version]$selected
                Build    = [int]$selected.Build
                Reliable = $true
                Source   = [string]$source.Name
            }
        }

        if ($source.Name -eq 'update.mum') {
            $cbsShort = New-Object System.Collections.Generic.List[System.Version]

            foreach ($tagMatch in [regex]::Matches($source.Text, '(?is)<assemblyIdentity\b[^>]*>')) {
                $tag = $tagMatch.Value
                $nameMatch = [regex]::Match($tag, '(?i)\bname\s*=\s*"([^"]+)"')
                $versionMatch = [regex]::Match($tag, '(?i)\bversion\s*=\s*"(\d{4,9})\.(\d{1,9})\.(\d+)\.(\d+)"')
                if (-not $versionMatch.Success) { continue }

                $name = if ($nameMatch.Success) { $nameMatch.Groups[1].Value } else { '' }
                if ($name -notmatch '(?i)Package_for_(?:RollupFix|RevisedFix|ServicingStack|SafeOSDU)|Enablement') { continue }

                try {
                    $build = [int]$versionMatch.Groups[1].Value
                    $revision = [int]$versionMatch.Groups[2].Value
                    if ($build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild -and $revision -ge 0) {
                        [void]$cbsShort.Add([version]("10.0.$build.$revision"))
                    }
                }
                catch {}
            }

            if ($cbsShort.Count -eq 0) {
                foreach ($match in [regex]::Matches($source.Text, '(?is)Package_for_(?:RollupFix|RevisedFix|ServicingStack|SafeOSDU).{0,600}?(\d{4,9})\.(\d{1,9})\.(\d+)\.(\d+)')) {
                    try {
                        $build = [int]$match.Groups[1].Value
                        $revision = [int]$match.Groups[2].Value
                        if ($build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild -and $revision -ge 0) {
                            [void]$cbsShort.Add([version]("10.0.$build.$revision"))
                        }
                    }
                    catch {}
                }
            }

            if ($cbsShort.Count -gt 0) {
                $selected = $cbsShort.ToArray() |
                    Sort-Object @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Revision }; Descending = $true } |
                    Select-Object -First 1
                return [pscustomobject]@{
                    Version  = [version]$selected
                    Build    = [int]$selected.Build
                    Reliable = $true
                    Source   = 'update.mum CBS build.revision.major.minor'
                }
            }
        }

        if ($source.Name -eq 'Nombre') {
            $shortMatches = [regex]::Matches($source.Text, '(?<!\d)(\d{4,9})\.(\d{1,9})(?!\d)')
            $shortCandidates = New-Object System.Collections.Generic.List[System.Version]
            foreach ($match in $shortMatches) {
                try {
                    $build = [int]$match.Groups[1].Value
                    $revision = [int]$match.Groups[2].Value
                    if ($build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) {
                        [void]$shortCandidates.Add([version]("10.0.$build.$revision"))
                    }
                }
                catch {}
            }
            if ($shortCandidates.Count -gt 0) {
                $selected = $shortCandidates.ToArray() |
                    Sort-Object @{ Expression = { $_.Build }; Descending = $true }, @{ Expression = { $_.Revision }; Descending = $true } |
                    Select-Object -First 1
                return [pscustomobject]@{
                    Version  = [version]$selected
                    Build    = [int]$selected.Build
                    Reliable = $true
                    Source   = 'Nombre build.revision'
                }
            }
        }
    }

    return [pscustomobject]@{
        Version  = [version]'0.0.0.0'
        Build    = 0
        Reliable = $false
        Source   = 'No determinada'
    }
}

function Add-AIOUpdateServicingBuildRelation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$First,
        [Parameter(Mandatory = $true)] [int]$Second
    )

    if ($First -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild -or $Second -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) { return }
    foreach ($build in @($First, $Second)) {
        if (-not $script:AIOUpdateServicingBuildRelations.ContainsKey($build)) {
            $script:AIOUpdateServicingBuildRelations[$build] = New-Object System.Collections.ArrayList
        }
    }
    if ($Second -notin @($script:AIOUpdateServicingBuildRelations[$First])) {
        [void]$script:AIOUpdateServicingBuildRelations[$First].Add($Second)
    }
    if ($First -notin @($script:AIOUpdateServicingBuildRelations[$Second])) {
        [void]$script:AIOUpdateServicingBuildRelations[$Second].Add($First)
    }
}

function Get-AIOUpdateEnablementTargetBuilds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package
    )

    $values = New-Object System.Collections.Generic.List[int]
    $probe = @(
        $Package.Name
        $Package.IdentityHints
        if ($Package.Metadata) { $Package.Metadata.UpdateMumIdentityNames }
        if ($Package.Metadata) { $Package.Metadata.UpdateMumPackageIdentifiers }
        if ($Package.Metadata) { $Package.Metadata.MetadataNames }
    ) -join "`n"

    # Identidades modernas incluyen el build objetivo, por ejemplo:
    # Microsoft-Windows-Ge-Client-Server-<build>-Version-Enablement-Package.
    foreach ($match in [regex]::Matches($probe, '(?i)(?<!\d)(\d{4,9})(?!\d)(?=[^~\r\n]{0,80}(?:Version[-_ ]+)?Enablement[-_ ]+Package)')) {
        $build = [int]$match.Groups[1].Value
        if ($build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) { [void]$values.Add($build) }
    }

    # EKB historicos: algunos nombres opacos no incluyen el build destino.
    # Se resuelven mediante una tabla legacy centralizada; nunca se deduce el
    # destino mediante una suma base+N porque esa convencion no es estable.
    foreach ($legacy in $script:AIOUpdateLegacyEnablementTargets) {
        if ($probe -match [string]$legacy.Pattern) {
            [void]$values.Add([int]$legacy.TargetBuild)
        }
    }

    return [int[]]@($values.ToArray() | Sort-Object -Unique)
}

function Initialize-AIOUpdateServicingBuildRelations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    $script:AIOUpdateServicingBuildRelations = @{}
    foreach ($package in @($Inventory | Where-Object { $_.Category -eq 'Enablement' })) {
        $baseBuild = if ($package.VersionReliable) { [int]$package.VersionBuild } else { 0 }
        if ($baseBuild -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) { continue }
        foreach ($targetBuild in @(Get-AIOUpdateEnablementTargetBuilds -Package $package)) {
            Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second $targetBuild
            Write-AIOUpdateLog -Level INFO -Message "Relacion de mantenimiento detectada dinamicamente: $baseBuild <-> $targetBuild ($($package.Name))."
        }
    }
}

function Get-AIOUpdateServicingBuildFamily {
    [CmdletBinding()]
    param([int]$Build)

    if ($Build -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild -or -not $script:AIOUpdateServicingBuildRelations.ContainsKey($Build)) {
        return $Build
    }

    $pending = New-Object System.Collections.ArrayList
    $visited = @{}
    [void]$pending.Add($Build)
    while ($pending.Count -gt 0) {
        $current = [int]$pending[0]
        $pending.RemoveAt(0)
        if ($visited.ContainsKey($current)) { continue }
        $visited[$current] = $true
        if ($script:AIOUpdateServicingBuildRelations.ContainsKey($current)) {
            foreach ($related in @($script:AIOUpdateServicingBuildRelations[$current])) {
                if (-not $visited.ContainsKey([int]$related)) { [void]$pending.Add([int]$related) }
            }
        }
    }

    return [int](($visited.Keys | ForEach-Object { [int]$_ } | Sort-Object | Select-Object -First 1))
}

function Test-AIOUpdateAuxiliaryPackageName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $leaf = [System.IO.Path]::GetFileName($Name)
    return (@($script:AIOUpdateAuxiliaryNamePatterns | Where-Object { $leaf -match $_ }).Count -gt 0)
}

function Get-AIOUpdateExplicitCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot
    )

    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path.TrimEnd('\')
    $relative = $File.FullName.Substring($root.Length).TrimStart('\')
    $first = ($relative -split '[\\/]', 2)[0]

    # Las subcarpetas validas se derivan del catalogo central. Al agregar una
    # categoria instalable nueva no hay que mantener otro switch separado.
    foreach ($category in @($script:AIOUpdateCategoryOrder | Where-Object { $_ -notin @('Auxiliary', 'Unknown') })) {
        if ([string]$first -ieq [string]$category) { return [string]$category }
    }
    return $null
}

function Get-AIOUpdateCbsRootIdentity {
    [CmdletBinding()]
    param([AllowNull()] [string]$XmlText)

    if ([string]::IsNullOrWhiteSpace($XmlText)) { return $null }
    $inputReader = New-Object System.IO.StringReader -ArgumentList $XmlText
    $reader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.IgnoreWhitespace = $true
        $reader = [System.Xml.XmlReader]::Create($inputReader, $settings)
        [void]$reader.MoveToContent()
        if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.LocalName -ne 'assembly') {
            throw 'El manifiesto CBS no comienza con assembly.'
        }
        $rootDepth = $reader.Depth
        while ($reader.Read()) {
            if ($reader.NodeType -eq [System.Xml.XmlNodeType]::EndElement -and $reader.Depth -eq $rootDepth) { break }
            if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element -or $reader.Depth -ne ($rootDepth + 1) -or $reader.LocalName -ne 'assemblyIdentity') { continue }
            $version = $null
            $name = [string]$reader.GetAttribute('name')
            $token = [string]$reader.GetAttribute('publicKeyToken')
            $architecture = [string]$reader.GetAttribute('processorArchitecture')
            if (-not $name -or -not $token -or -not $architecture -or -not [version]::TryParse($reader.GetAttribute('version'), [ref]$version)) {
                throw 'La identidad raiz CBS no tiene nombre, token, arquitectura o version validos.'
            }
            $language = [string]$reader.GetAttribute('language')
            if ($language -in @('neutral', '*')) { $language = '' }
            # Solo se necesita la cabecera propia. No leer ni validar aqui el
            # cuerpo del payload, que puede superar el limite de texto guardado.
            return [pscustomobject]@{ Prefix = (@($name, $token, $architecture, $language) -join '~'); Version = $version }
        }
        return $null
    }
    finally {
        if ($reader) { $reader.Dispose() }
        $inputReader.Dispose()
    }
}

function Get-AIOUpdateCbsManifestFacts {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$XmlText
    )

    $cacheKey = Get-AIOUpdateTextSha256 -Text ([string]$XmlText)
    if ($script:AIOUpdateCbsFactsCache.ContainsKey($cacheKey)) {
        $script:AIOUpdateOptimizationStats.CbsCacheHits++
        return $script:AIOUpdateCbsFactsCache[$cacheKey]
    }

    $own = New-Object System.Collections.Generic.List[string]
    $dependencies = New-Object System.Collections.Generic.List[string]
    $parents = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($XmlText)) {
        $emptyResult = [pscustomobject]@{
            OwnIdentities = [string[]]@()
            Dependencies  = [string[]]@()
            Parents       = [string[]]@()
        }
        $script:AIOUpdateCbsFactsCache[$cacheKey] = $emptyResult
        return $emptyResult
    }

    try {
        $document = New-Object System.Xml.XmlDocument
        $document.PreserveWhitespace = $false
        $document.LoadXml($XmlText)

        foreach ($node in @($document.SelectNodes("//*[local-name()='assemblyIdentity']"))) {
            $name = [string]$node.GetAttribute('name')
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $name = $name.Trim()

            $ancestorNames = New-Object System.Collections.Generic.List[string]
            $ancestor = $node.ParentNode
            while ($ancestor) {
                if ($ancestor.LocalName) { [void]$ancestorNames.Add([string]$ancestor.LocalName) }
                $ancestor = $ancestor.ParentNode
            }

            if ($ancestorNames -contains 'parent') {
                [void]$parents.Add($name)
            }
            elseif ($ancestorNames -contains 'dependency' -or $ancestorNames -contains 'dependentAssembly') {
                [void]$dependencies.Add($name)
            }
            else {
                [void]$own.Add($name)
            }
        }

        foreach ($package in @($document.SelectNodes("//*[local-name()='package']"))) {
            $identifier = [string]$package.GetAttribute('identifier')
            if (-not [string]::IsNullOrWhiteSpace($identifier)) {
                [void]$own.Add($identifier.Trim())
            }
        }
    }
    catch {
        $matches = [regex]::Matches($XmlText, '(?is)<assemblyIdentity\b[^>]*\bname\s*=\s*"([^"]+)"')
        $first = $true
        foreach ($match in $matches) {
            $name = $match.Groups[1].Value.Trim()
            if (-not $name) { continue }
            if ($first) {
                [void]$own.Add($name)
                $first = $false
            }
            else {
                [void]$dependencies.Add($name)
            }
        }
    }

    $result = [pscustomobject]@{
        OwnIdentities = [string[]]@($own.ToArray() | Sort-Object -Unique)
        Dependencies  = [string[]]@($dependencies.ToArray() | Sort-Object -Unique)
        Parents       = [string[]]@($parents.ToArray() | Sort-Object -Unique)
    }
    $script:AIOUpdateCbsFactsCache[$cacheKey] = $result
    return $result
}

function Expand-AIOUpdatePackageMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$ScratchRoot
    )

    $metadataRoot = Join-Path $ScratchRoot ('Meta_' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    Initialize-AIOUpdateDirectory -Path $metadataRoot -Empty

    $text = New-Object System.Text.StringBuilder
    $updateMumText = New-Object System.Text.StringBuilder
    $listedNames = New-Object System.Collections.Generic.List[string]
    $identityNames = New-Object System.Collections.Generic.List[string]
    $packageIdentifiers = New-Object System.Collections.Generic.List[string]
    $updateMumIdentityNames = New-Object System.Collections.Generic.List[string]
    $updateMumPackageIdentifiers = New-Object System.Collections.Generic.List[string]
    $metadataNames = New-Object System.Collections.Generic.List[string]
    $cbsOwnIdentities = New-Object System.Collections.Generic.List[string]
    $cbsRootIdentities = New-Object System.Collections.Generic.List[object]
    $cbsDependencies = New-Object System.Collections.Generic.List[string]
    $cbsParents = New-Object System.Collections.Generic.List[string]
    $hasMum = $false
    $hasManifest = $false
    $hasUpdateMum = $false

    try {
        $containers = New-Object System.Collections.Generic.List[string]

        if ($File.Extension -ieq '.msu') {
            $innerRoot = Join-Path $metadataRoot 'Inner'
            Initialize-AIOUpdateDirectory -Path $innerRoot
            $isModernMsu = Test-AIOUpdateWimContainerSignature -Path $File.FullName

            if (-not $isModernMsu) {
                # MSU clasico: contenedor CAB.
                if (Test-Path -LiteralPath $script:AIOUpdateExpandPath -PathType Leaf) {
                    & $script:AIOUpdateExpandPath '-F:*.cab' $File.FullName $innerRoot *> $null
                }

                foreach ($inner in @(Get-ChildItem -LiteralPath $innerRoot -Filter '*.cab' -File -ErrorAction SilentlyContinue)) {
                    [void]$containers.Add($inner.FullName)
                    [void]$listedNames.Add($inner.Name)
                }
            }
            else {
                # MSU moderno: el propio .msu lleva firma MSWIM. No se intenta
                # abrir con expand.exe; se usa la ruta WIM desde el principio.
                $modernItems = @(
                    Expand-AIOUpdateWimContainerEntries `
                        -WimPath $File.FullName `
                        -DestinationRoot $innerRoot `
                        -Pattern $script:AIOUpdateModernMsuPayloadPatterns `
                        -ScratchRoot $metadataRoot `
                        -AllowFullApplyFallback
                )

                foreach ($entry in @(Get-AIOUpdateWimImageEntries -WimPath $File.FullName)) {
                    [void]$listedNames.Add([System.IO.Path]::GetFileName([string]$entry))
                }

                foreach ($inner in $modernItems) {
                    if ($inner.Extension -in @('.cab', '.wim')) {
                        [void]$containers.Add($inner.FullName)
                    }
                    [void]$listedNames.Add($inner.Name)
                }

                Write-AIOUpdateLog -Level INFO -Message "MSU WIM moderno detectado para metadatos: $($File.Name)."
            }
        }
        else {
            [void]$containers.Add($File.FullName)
        }

        $counter = 0
        foreach ($container in @($containers.ToArray() | Sort-Object -Unique)) {
            $counter++
            $mumRoot = Join-Path $metadataRoot ("Mum_$counter")
            Initialize-AIOUpdateDirectory -Path $mumRoot

            $isWimContainer = Test-AIOUpdateWimContainerSignature -Path $container
            $containerEntries = if ($isWimContainer) { @(Get-AIOUpdateWimImageEntries -WimPath $container) } else { @() }

            if ($isWimContainer) {
                foreach ($entry in $containerEntries) {
                    [void]$listedNames.Add([System.IO.Path]::GetFileName([string]$entry))
                }

                # En WIM modernos no se extraen cientos de manifiestos. update.mum
                # y los manifiestos de clasificacion son suficientes y evitan
                # aplicar/descomprimir el payload completo durante el inventario.
                [void](
                    Expand-AIOUpdateWimContainerEntries `
                        -WimPath $container `
                        -DestinationRoot $mumRoot `
                        -Pattern $script:AIOUpdateMetadataWimPatterns `
                        -ScratchRoot $metadataRoot `
                        -AllowFullApplyFallback
                )
            }
            elseif (Test-Path -LiteralPath $script:AIOUpdateExpandPath -PathType Leaf) {
                foreach ($pattern in $script:AIOUpdateMetadataCabPatterns) {
                    & $script:AIOUpdateExpandPath ("-F:$pattern") $container $mumRoot *> $null
                }

                $listOutput = & $script:AIOUpdateExpandPath '-D' $container 2>$null
                foreach ($line in @($listOutput)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$line)) {
                        [void]$listedNames.Add(([string]$line).Trim())
                    }
                }
            }

            foreach ($meta in @(
                Get-ChildItem -LiteralPath $mumRoot -Recurse -File -ErrorAction SilentlyContinue |
                    Sort-Object @{
                        Expression = {
                            if ($_.Name -ieq 'update.mum') { 0 }
                            elseif ($_.Name -match '(?i)enablement-package.*\.mum$') { 1 }
                            elseif ($_.Extension -ieq '.mum') { 2 }
                            elseif ($_.Name -match '(?i)(sysreset|winpe_tools|winre-tools|rejuvenation|servicingstack|updatetargeting|netfx4)') { 3 }
                            else { 4 }
                        }
                    }, Name |
                    Select-Object -First ([int]$script:AIOUpdateMetadataPolicy.MaxMetadataFiles)
            )) {
                try {
                    [void]$metadataNames.Add($meta.Name)
                    if ($meta.Extension -ieq '.mum') { $hasMum = $true }
                    if ($meta.Extension -ieq '.manifest') { $hasManifest = $true }

                    $content = Get-Content -LiteralPath $meta.FullName -Raw -ErrorAction Stop
                    $isUpdateMum = ($meta.Name -ieq 'update.mum')
                    if ($isUpdateMum) {
                        # Extraer de cada documento original antes de recortarlo
                        # o concatenarlo. El corte de 1 MiB puede caer en mitad
                        # de un atributo XML y no debe invalidar su identidad.
                        try {
                            $rootIdentity = Get-AIOUpdateCbsRootIdentity -XmlText $content
                            if ($rootIdentity) { [void]$cbsRootIdentities.Add($rootIdentity) }
                        }
                        catch { Write-AIOUpdateLog -Level WARN -Message "No se pudo leer la cabecera CBS de '$($meta.FullName)': $($_.Exception.Message)" }
                    }
                    if ($content.Length -gt [int]$script:AIOUpdateMetadataPolicy.MaxMetadataTextBytes) { $content = $content.Substring(0, [int]$script:AIOUpdateMetadataPolicy.MaxMetadataTextBytes) }
                    [void]$text.AppendLine($content)

                    if ($isUpdateMum) {
                        $hasUpdateMum = $true
                        [void]$updateMumText.AppendLine($content)
                        $cbsFacts = Get-AIOUpdateCbsManifestFacts -XmlText $content
                        foreach ($value in @($cbsFacts.OwnIdentities)) { [void]$cbsOwnIdentities.Add([string]$value) }
                        foreach ($value in @($cbsFacts.Dependencies)) { [void]$cbsDependencies.Add([string]$value) }
                        foreach ($value in @($cbsFacts.Parents)) { [void]$cbsParents.Add([string]$value) }
                    }

                    foreach ($match in [regex]::Matches($content, '(?is)<assemblyIdentity\b[^>]*\bname\s*=\s*"([^"]+)"')) {
                        $value = $match.Groups[1].Value.Trim()
                        if ($value) {
                            [void]$identityNames.Add($value)
                            if ($isUpdateMum) { [void]$updateMumIdentityNames.Add($value) }
                        }
                    }

                    foreach ($match in [regex]::Matches($content, '(?is)<package\b[^>]*\bidentifier\s*=\s*"([^"]+)"')) {
                        $value = $match.Groups[1].Value.Trim()
                        if ($value) {
                            [void]$packageIdentifiers.Add($value)
                            if ($isUpdateMum) { [void]$updateMumPackageIdentifiers.Add($value) }
                        }
                    }
                }
                catch {}
            }
        }

        $combined = $text.ToString()
        $updateCombined = $updateMumText.ToString()
        $allNamesProbe = @(
            $listedNames.ToArray()
            $metadataNames.ToArray()
        ) -join "`n"
        $versionInfo = Get-AIOUpdatePackageVersionInfo -FileName $File.Name -UpdateMumText $updateCombined

        return [pscustomobject]@{
            Text                        = $combined
            UpdateMumText               = $updateCombined
            Names                       = [string[]]@($listedNames.ToArray() | Sort-Object -Unique)
            IdentityNames               = [string[]]@($identityNames.ToArray() | Sort-Object -Unique)
            PackageIdentifiers          = [string[]]@($packageIdentifiers.ToArray() | Sort-Object -Unique)
            UpdateMumIdentityNames      = [string[]]@($updateMumIdentityNames.ToArray() | Sort-Object -Unique)
            UpdateMumPackageIdentifiers = [string[]]@($updateMumPackageIdentifiers.ToArray() | Sort-Object -Unique)
            MetadataNames               = [string[]]@($metadataNames.ToArray() | Sort-Object -Unique)
            CbsOwnIdentities            = [string[]]@($cbsOwnIdentities.ToArray() | Sort-Object -Unique)
            CbsRootIdentities           = [object[]]@($cbsRootIdentities.ToArray() | Sort-Object Prefix, Version -Unique)
            CbsDependencies             = [string[]]@($cbsDependencies.ToArray() | Sort-Object -Unique)
            CbsParents                  = [string[]]@($cbsParents.ToArray() | Sort-Object -Unique)
            Version                     = [version]$versionInfo.Version
            VersionBuild                = [int]$versionInfo.Build
            VersionReliable             = [bool]$versionInfo.Reliable
            VersionSource               = [string]$versionInfo.Source
            HasMum                      = [bool]$hasMum
            HasManifest                 = [bool]$hasManifest
            HasUpdateMum                = [bool]$hasUpdateMum
            HasEnablementMum            = [bool]($allNamesProbe -match '(?i)enablement-package.*\.mum')
            HasBaseline                 = [bool](
                $combined -match '(?i)\b(?:Baseline|Checkpoint)\b' -or
                $allNamesProbe -match '(?i)(?:Baseline|Checkpoint)'
            )
        }
    }
    finally {
        Remove-Item -LiteralPath $metadataRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-AIOUpdatePackageCategory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.FileInfo]$File,

        [Parameter(Mandatory = $true)]
        [string]$RepositoryRoot,

        [Parameter(Mandatory = $true)]
        [string]$ScratchRoot
    )

    if (Test-AIOUpdateAuxiliaryPackageName -Name $File.Name) {
        return [pscustomobject]@{ Category = 'Auxiliary'; Reason = 'Archivo auxiliar de UUP/CompDB'; Metadata = $null }
    }

    # Las subcarpetas conservan el papel de anulacion manual. En una carpeta
    # plana, la clasificacion se basa primero en los metadatos del paquete.
    $explicit = Get-AIOUpdateExplicitCategory -File $File -RepositoryRoot $RepositoryRoot
    if ($explicit) {
        $metadata = $null
        if ($explicit -in $script:AIOUpdateMetadataCategories) {
            $metadata = Expand-AIOUpdatePackageMetadata -File $File -ScratchRoot $ScratchRoot
        }
        return [pscustomobject]@{ Category = $explicit; Reason = "Subcarpeta $explicit (anulacion manual)"; Metadata = $metadata }
    }

    $metadata = Expand-AIOUpdatePackageMetadata -File $File -ScratchRoot $ScratchRoot
    $identityProbe = @(
        $metadata.IdentityNames
        $metadata.PackageIdentifiers
        $metadata.MetadataNames
    ) -join "`n"
    $updateMumProbe = @(
        $metadata.UpdateMumIdentityNames
        $metadata.UpdateMumPackageIdentifiers
        $metadata.UpdateMumText
    ) -join "`n"
    $nameProbe = @(
        $metadata.Names
        $metadata.MetadataNames
    ) -join "`n"
    $contentProbe = @(
        $File.Name
        $nameProbe
        $identityProbe
        $metadata.Text
    ) -join "`n"

    # Las identidades especificas tienen prioridad sobre componentes secundarios
    # incluidos en el mismo contenedor.
    if ($metadata.HasEnablementMum -or
        $identityProbe -match '(?i)(?:Microsoft-Windows-[^\r\n]*Enablement(?:-Package)?|Enablement[-_. ]?Package|Package_for_(?:Feature_?)?Enablement|Feature[-_. ]?Update[-_. ]?Enablement)') {
        return [pscustomobject]@{ Category = 'Enablement'; Reason = 'MUM/identidad interna de paquete de habilitacion'; Metadata = $metadata }
    }

    # La identidad principal declarada por update.mum es autoritativa. Una LCU
    # contiene miles de identidades de componentes (incluidos NetFx), por lo que
    # esas dependencias nunca deben reclasificar el paquete principal como .NET.
    $primaryCbsProbe = @(
        $metadata.CbsOwnIdentities
        $metadata.UpdateMumPackageIdentifiers
    ) -join "`n"

    $hasLcuIdentity = (
        $primaryCbsProbe -match $script:AIOUpdateIdentityPatterns.LCU -or
        $updateMumProbe -match $script:AIOUpdateIdentityPatterns.LCU
    )
    $hasDotNetRollupIdentity = (
        $primaryCbsProbe -match $script:AIOUpdateIdentityPatterns.DotNet -or
        $updateMumProbe -match $script:AIOUpdateIdentityPatterns.DotNet
    )
    $isRollup = $hasLcuIdentity

    $hasSafeOsManifest = ($nameProbe -match '(?i)(?:_microsoft-windows-(?:sysreset|winpe_tools|winre-tools)_|rejuvenation).*\.manifest')
    if ($updateMumProbe -match $script:AIOUpdateIdentityPatterns.SafeOS -or
        ($hasSafeOsManifest -and -not $hasLcuIdentity)) {
        return [pscustomobject]@{ Category = 'SafeOS'; Reason = 'update.mum o manifiestos exclusivos de SafeOS/WinRE'; Metadata = $metadata }
    }

    # RollupFix/RevisedFix gana sobre cualquier manifiesto de componente que
    # tambien viaje dentro de la acumulativa (NetFx, SecureBoot, etc.).
    if ($hasLcuIdentity) {
        return [pscustomobject]@{ Category = 'LCU'; Reason = 'Identidad principal Package_for_RollupFix/RevisedFix en update.mum'; Metadata = $metadata }
    }

    # Una identidad Package_for_DotNetRollup si es autoritativa para .NET.
    if ($hasDotNetRollupIdentity) {
        return [pscustomobject]@{ Category = 'DotNet'; Reason = 'Identidad principal Package_for_DotNetRollup en update.mum'; Metadata = $metadata }
    }

    # Respaldo fuerte para Combined UUP/LCU modernos: Microsoft publica los
    # acumulativos monoliticos con este nombre canonico. Los paquetes .NET
    # llevan normalmente un sufijo adicional (p. ej. -NDP481), por lo que no
    # deben perder frente a componentes NetFx incluidos dentro de una LCU.
    $isCanonicalWindowsLcuMsu = (
        $File.Extension -ieq '.msu' -and
        $File.Name -match ("(?i)^Windows\d+\.0-KB\d+-$($script:AIOUpdateCanonicalPackageArchitecturePattern)\.msu$")
    )
    if ($isCanonicalWindowsLcuMsu) {
        return [pscustomobject]@{ Category = 'LCU'; Reason = 'MSU acumulativo de Windows con nombre canonico; sin identidad principal de otra familia'; Metadata = $metadata }
    }

    # Evidencias de componente NetFx solo se consideran cuando no existe una
    # identidad autoritativa LCU ni el patron canonico de un MSU acumulativo.
    if (($nameProbe -match '(?i)_netfx4.*\.manifest') -or
        ($identityProbe -match '(?i)Microsoft-Windows-NetFx|NDP\d')) {
        return [pscustomobject]@{ Category = 'DotNet'; Reason = 'Evidencias internas de paquete .NET sin identidad LCU'; Metadata = $metadata }
    }

    if ($contentProbe -match '(?i)(?:ExtendedSecurityUpdates|ESU[-_. ]?(?:Licens|Preparation)|Licens[^\r\n]*ESU|Package_for_ESU)') {
        return [pscustomobject]@{ Category = 'ESU'; Reason = 'Identidad interna de preparacion/licenciamiento ESU'; Metadata = $metadata }
    }

    if (($nameProbe -match '(?i)_microsoft-windows-s.*boot-firmwareupdate_.*\.manifest') -and -not $hasLcuIdentity) {
        return [pscustomobject]@{ Category = 'SecureBoot'; Reason = 'Manifiesto interno de actualizacion de firmware Secure Boot'; Metadata = $metadata }
    }

    if ($updateMumProbe -match '(?i)LCUCompDB|PSFX|CumulativeUpdate') {
        return [pscustomobject]@{ Category = 'LCU'; Reason = 'Metadatos internos de actualizacion acumulativa'; Metadata = $metadata }
    }

    if ($updateMumProbe -match $script:AIOUpdateIdentityPatterns.SSU -or
        $nameProbe -match '(?i)_microsoft-windows-servicingstack_.*\.manifest') {
        return [pscustomobject]@{ Category = 'SSU'; Reason = 'Identidad interna de pila de mantenimiento'; Metadata = $metadata }
    }

    if ($contentProbe -match '(?i)defender-dism|mpam-fe|mpam-d|Microsoft-Windows-Defender') {
        return [pscustomobject]@{ Category = 'Defender'; Reason = 'Contenido de Microsoft Defender'; Metadata = $metadata }
    }

    # WinPE se evalua despues de las familias mas especificas. Solo se acepta
    # cuando update.mum declara WinPE y no presenta una lista de ediciones OS.
    if ($updateMumProbe -match '(?i)WinPE' -and $updateMumProbe -notmatch '(?i)Edition\s*=|Edition"') {
        return [pscustomobject]@{ Category = 'WinPE'; Reason = 'update.mum especifico de WinPE'; Metadata = $metadata }
    }

    if (-not $metadata.HasMum -and $contentProbe -match '(?i)CompDB|AggregatedMetadata|DesktopDeployment') {
        return [pscustomobject]@{ Category = 'Auxiliary'; Reason = 'Metadatos auxiliares de UUP/CompDB'; Metadata = $metadata }
    }

    # Un solo bloque de respaldo por nombre cubre contenedores cuyos metadatos
    # estan encapsulados en WIM/PSF. Nunca tiene prioridad sobre CBS/update.mum.
    foreach ($classifier in $script:AIOUpdateNameFallbackClassifiers) {
        if ($File.Name -match [string]$classifier.Pattern) {
            return [pscustomobject]@{ Category = [string]$classifier.Category; Reason = [string]$classifier.Reason; Metadata = $metadata }
        }
    }

    # Si un MSU llega hasta aqui, no tuvo identidad CBS suficiente ni coincide
    # con el patron canonico de acumulativa evaluado antes.
    if ($File.Extension -ieq '.msu') {
        return [pscustomobject]@{ Category = 'Unknown'; Reason = 'MSU sin metadatos ni nombre suficientes para clasificacion segura'; Metadata = $metadata }
    }

    # Un CAB sin update.mum solo se considera SetupDU cuando contiene varias
    # superficies caracteristicas de Windows Setup. La sola ausencia de MUM no
    # basta, porque tambien existen CAB de datos y auxiliares no instalables.
    if (-not $metadata.HasUpdateMum) {
        $setupProbe = @(
            $metadata.Names
            $metadata.MetadataNames
        ) -join "`n"
        $setupSignalCount = @(
            $script:AIOUpdateSetupSignalPatterns | Where-Object { $setupProbe -match $_ }
        ).Count
        if ($setupSignalCount -ge [int]$script:AIOUpdateMetadataPolicy.MinimumSetupSignals) {
            return [pscustomobject]@{ Category = 'SetupDU'; Reason = "CAB sin update.mum con $setupSignalCount evidencias de Windows Setup"; Metadata = $metadata }
        }
        return [pscustomobject]@{ Category = 'Unknown'; Reason = 'CAB sin update.mum y sin evidencias suficientes de SetupDU'; Metadata = $metadata }
    }

    if ($metadata.HasMum) {
        return [pscustomobject]@{ Category = 'OS'; Reason = 'Paquete CBS general de sistema operativo'; Metadata = $metadata }
    }

    return [pscustomobject]@{ Category = 'Unknown'; Reason = 'No se encontraron metadatos suficientes para clasificar el paquete'; Metadata = $metadata }
}


function Find-AIOUpdateWimlib {
    [CmdletBinding()]
    param()

    if ($script:AIOUpdateWimlibPath -and (Test-Path -LiteralPath $script:AIOUpdateWimlibPath -PathType Leaf)) {
        return $script:AIOUpdateWimlibPath
    }

    # Directorio compartido de herramientas de AdminImagenOffline:
    #   <AdminImagenOffline>\Tools\wimlib\wimlib-imagex.exe
    $applicationRoot = Split-Path -Parent $PSScriptRoot
    $candidates = New-Object System.Collections.Generic.List[string]
    [void]$candidates.Add((Join-Path $applicationRoot 'Tools\wimlib\wimlib-imagex.exe'))

    try {
        $command = Get-Command wimlib-imagex.exe -ErrorAction Stop
        if ($command.Source) { [void]$candidates.Add([string]$command.Source) }
    }
    catch {}

    foreach ($programRoot in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ([string]::IsNullOrWhiteSpace($programRoot)) { continue }
        [void]$candidates.Add((Join-Path $programRoot 'wimlib\wimlib-imagex.exe'))
        [void]$candidates.Add((Join-Path $programRoot 'wimlib-imagex\wimlib-imagex.exe'))
    }

    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $script:AIOUpdateWimlibPath = (Resolve-Path -LiteralPath $candidate).Path
            return $script:AIOUpdateWimlibPath
        }
    }

    return $null
}

function Assert-AIOUpdateRepositorySupport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot
    )

    $root = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $psf = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.psf' -File -ErrorAction SilentlyContinue)
    $updateWims = @(
        Get-ChildItem -LiteralPath $root -Recurse -Filter '*.wim' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '(?i)Windows\d+(?:\.\d+)?[^\r\n]*KB|LCU|Cumulative' }
    )
    $metadata = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*AggregatedMetadata*.cab' -File -ErrorAction SilentlyContinue)
    $completeMsu = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.msu' -File -ErrorAction SilentlyContinue)

    if (($psf.Count -gt 0 -or $updateWims.Count -gt 0) -and $metadata.Count -gt 0 -and $completeMsu.Count -eq 0) {
        $message = @"
Se detecto un repositorio UUP dividido (WIM/PSF/CompDB) sin un MSU reconstruido.
Este modulo no intenta aplicar esos fragmentos directamente porque produciria
una imagen incompleta. Reconstruye primero la LCU como MSU con W10UI o coloca
el MSU completo en el repositorio.
"@
        throw $message.Trim()
    }
}

function Get-AIOUpdatePackageArchitectureInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [AllowNull()] [psobject]$Metadata,
        [string]$Category = ''
    )

    $roots = @()
    if ($Metadata) {
        if ($Metadata.PSObject.Properties['CbsRootIdentities']) {
            $roots = @($Metadata.CbsRootIdentities | Where-Object { $_ })
        }
        if ($roots.Count -eq 0 -and $Metadata.UpdateMumText) {
            foreach ($fragment in [regex]::Split([string]$Metadata.UpdateMumText, '(?i)(?=<\?xml\s)')) {
                if ([string]::IsNullOrWhiteSpace($fragment)) { continue }
                try {
                    $root = Get-AIOUpdateCbsRootIdentity -XmlText $fragment
                    if ($root) { $roots += $root }
                }
                catch { } # El nombre propio sigue disponible si el XML esta incompleto.
            }
        }
    }

    # Elegir la identidad del payload pedido, no SSU/parent/wrappers incluidos
    # en el mismo MSU. Las arquitecturas de componentes WOW64 no son destinos.
    if ($Category -and $script:AIOUpdateIdentityPatterns.Contains($Category)) {
        $pattern = [string]$script:AIOUpdateIdentityPatterns[$Category]
        $roots = @($roots | Where-Object {
            $parts = ([string]$_.Prefix) -split '~'
            $parts.Count -eq 4 -and $parts[0] -match $pattern -and
                $parts[1] -ieq '31bf3856ad364e35' -and -not $parts[3]
        })
    }
    $architectures = @($roots | ForEach-Object {
        $parts = ([string]$_.Prefix) -split '~'
        if ($parts.Count -eq 4) { Convert-AIOUpdateArchitectureName -Architecture $parts[2] }
    } | Where-Object { $_ -in @($script:AIOUpdateArchitectureCatalog.Name) } | Sort-Object -Unique)
    if ($architectures.Count -gt 0) {
        return [pscustomobject]@{ Architectures = [string[]]$architectures; Source = 'Identidad raiz CBS propia' }
    }

    $tokens = @($script:AIOUpdateArchitectureCatalog | ForEach-Object { @($_.Name) + @($_.Aliases) + @($_.AdkFolder) } | ForEach-Object { $_ } | Sort-Object -Unique)
    $tokenPattern = ($tokens | ForEach-Object { [regex]::Escape([string]$_) }) -join '|'
    $architectures = @([regex]::Matches($File.Name, "(?i)(?:^|[-_.])($tokenPattern)(?:[-_.]|$)") | ForEach-Object {
        Convert-AIOUpdateArchitectureName -Architecture $_.Groups[1].Value
    } | Where-Object { $_ -in @($script:AIOUpdateArchitectureCatalog.Name) } | Sort-Object -Unique)
    return [pscustomobject]@{
        Architectures = [string[]]$architectures
        Source = $(if ($architectures.Count -gt 0) { 'Nombre del paquete' } else { 'No determinada' })
    }
}

function Get-AIOUpdatePackageArchitectureHints {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [AllowNull()] [psobject]$Metadata,
        [string]$Category = ''
    )
    return [string[]](Get-AIOUpdatePackageArchitectureInfo -File $File -Metadata $Metadata -Category $Category).Architectures
}

function Get-AIOUpdateLcuFamilyKey {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [psobject]$Package)

    $info = Get-AIOUpdatePackageArchitectureInfo -File ([System.IO.FileInfo]$Package.FullName) -Metadata $Package.Metadata -Category 'LCU'
    $architectures = @($info.Architectures)
    if ($architectures.Count -eq 0) {
        # Compatibilidad con inventarios construidos por otros llamadores:
        # aceptar solo un destino concreto, nunca la union de pistas ambiguas.
        $architectures = @($Package.Architectures | Where-Object { $_ } | ForEach-Object {
            Convert-AIOUpdateArchitectureName -Architecture $_
        } | Where-Object { $_ -in @($script:AIOUpdateArchitectureCatalog.Name) } | Sort-Object -Unique)
        $info.Source = 'Arquitectura declarada en inventario'
    }
    if ($architectures.Count -ne 1) {
        throw "No se puede preparar la cadena LCU de '$($Package.Name)': falta una arquitectura objetivo unica y fiable."
    }
    $version = $null
    if (-not $Package.VersionReliable -or -not [version]::TryParse([string]$Package.Version, [ref]$version) -or $version.Build -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) {
        throw "No se puede preparar la cadena LCU de '$($Package.Name)': falta una version CBS fiable."
    }
    $Package | Add-Member -NotePropertyName Architectures -NotePropertyValue ([string[]]$architectures) -Force
    $Package | Add-Member -NotePropertyName ArchitectureSource -NotePropertyValue $info.Source -Force
    $Package | Add-Member -NotePropertyName VersionBuild -NotePropertyValue ([int]$version.Build) -Force
    $product = if ($Package.ProductHint) { ([string]$Package.ProductHint).ToLowerInvariant() } else { 'any' }
    return ('{0}|{1}|{2}' -f $version.Build, $architectures[0], $product)
}

function Set-AIOUpdateLcuTargets {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Inventory)

    $packages = @($Inventory | Where-Object { $_.Category -eq 'LCU' -and $_.Extension -eq '.msu' -and $_.Installable })
    foreach ($package in $packages) {
        $family = Get-AIOUpdateLcuFamilyKey -Package $package
        $package | Add-Member -NotePropertyName LcuFamily -NotePropertyValue $family -Force
        $package | Add-Member -NotePropertyName IsLcuTarget -NotePropertyValue $true -Force
        $package | Add-Member -NotePropertyName IsLcuPrerequisiteCandidate -NotePropertyValue $false -Force
    }
    foreach ($group in @($packages | Group-Object -Property LcuFamily)) {
        $items = @($group.Group | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, @{ Expression = { $_.Size }; Descending = $true }, Name)
        $target = $items[0]
        $checkpointCapable = Test-AIOUpdateCheckpointLcuCapability -Packages $items
        foreach ($item in $items) {
            $item | Add-Member -NotePropertyName LcuTargetName -NotePropertyValue $target.Name -Force
            if ($item.FullName -ieq $target.FullName) { continue }
            $item.IsLcuTarget = $false
            if ($checkpointCapable) {
                $item.IsLcuPrerequisiteCandidate = $true
            }
            else {
                $item.Installable = $false
                $script:AIOUpdateOptimizationStats.DuplicatePackagesSkipped++
            }
        }
        Write-AIOUpdateLog -Level INFO -Message "Cadena LCU $($group.Name): objetivo=$($target.Name); MSU anteriores disponibles=$([math]::Max(0, $items.Count - 1)); solo el objetivo se programa para Add-Package."
    }
}

function Get-AIOUpdatePackageEditionHints {
    [CmdletBinding()]
    param(
        [AllowNull()] [psobject]$Metadata
    )

    if (-not $Metadata) { return @() }
    $probe = [string]$Metadata.UpdateMumText
    if ([string]::IsNullOrWhiteSpace($probe)) { return @() }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($probe, '(?i)\bEdition(?:ID)?\s*=\s*"([^"]*)"')) {
        $raw = $match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $value = ($raw -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($value -and $value -notin @('all', 'any', 'neutral', 'client', 'windows')) {
            [void]$values.Add($value)
        }
    }
    foreach ($match in [regex]::Matches($probe, '(?i)Microsoft-Windows-([A-Za-z0-9-]+)Edition(?:Pack|~|\b)')) {
        $value = ($match.Groups[1].Value -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($value -and $value -notin @('client', 'server', 'windows')) {
            [void]$values.Add($value)
        }
    }

    return [string[]]@($values.ToArray() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
}

function Get-AIOUpdatePackageExplicitEditionHints {
    [CmdletBinding()]
    param([AllowNull()] [psobject]$Metadata)

    if (-not $Metadata) { return @() }
    $probe = [string]$Metadata.UpdateMumText
    if ([string]::IsNullOrWhiteSpace($probe)) { return @() }

    $values = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($probe, '(?i)\bEdition(?:ID)?\s*=\s*"([^"]*)"')) {
        $raw = $match.Groups[1].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $value = ($raw -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($value -and $value -notin @('all', 'any', 'neutral', 'client', 'windows')) {
            [void]$values.Add($value)
        }
    }
    return [string[]]@($values.ToArray() | Sort-Object -Unique)
}

function Get-AIOUpdateImageEditionHints {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$ImageName,
        [AllowNull()] [string]$EditionId
    )

    $values = New-Object System.Collections.Generic.List[string]

    # EditionId de DISM es la fuente preferida y evita mantener alias por cada
    # nueva edicion. Se conserva la traduccion por nombre solo como respaldo.
    if (-not [string]::IsNullOrWhiteSpace($EditionId)) {
        $normalizedEditionId = ($EditionId -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
        if ($normalizedEditionId) { [void]$values.Add($normalizedEditionId) }
    }

    if (-not [string]::IsNullOrWhiteSpace($ImageName)) {
        $name = $ImageName.ToLowerInvariant()
        if ($name -match 'home single language') { foreach ($v in @('coresinglelanguage','home','core')) { [void]$values.Add($v) } }
        elseif ($name -match 'home n') { foreach ($v in @('coren','homen')) { [void]$values.Add($v) } }
        elseif ($name -match 'home') { foreach ($v in @('core','home')) { [void]$values.Add($v) } }

        if ($name -match 'pro for workstations') { foreach ($v in @('professionalworkstation','professionalworkstations','proworkstation')) { [void]$values.Add($v) } }
        elseif ($name -match 'pro education') { foreach ($v in @('professionaleducation','proeducation')) { [void]$values.Add($v) } }
        elseif ($name -match 'pro n') { foreach ($v in @('professionaln','pron')) { [void]$values.Add($v) } }
        elseif ($name -match '\bpro\b') { foreach ($v in @('professional','pro')) { [void]$values.Add($v) } }

        if ($name -match 'enterprise') { [void]$values.Add('enterprise') }
        if ($name -match 'education') { [void]$values.Add('education') }
        if ($name -match 'server') { [void]$values.Add('server') }
    }

    return [string[]]@($values.ToArray() | Sort-Object -Unique)
}

function Get-AIOUpdatePackageProductHint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.IO.FileInfo]$File,
        [AllowNull()] [psobject]$Metadata,
        [AllowNull()] [string]$Category
    )

    # El nombre externo es una pista mas fiable para la familia de Windows que
    # los cientos de dependencias internas. Paquetes cliente pueden contener
    # componentes compartidos con "Server" y no deben marcarse como Server-only.
    if ($File.Name -match '(?i)Windows(\d+)\.0') {
        $clientFamily = [int]$Matches[1]
        if ($clientFamily -eq 10) { return 'Windows10' }
        if ($clientFamily -eq 11) { return 'Windows11' }
        # Familia cliente futura: no se bloquea preventivamente; CBS/DISM
        # determinara aplicabilidad exacta hasta que exista una regla necesaria.
        return 'WindowsClient'
    }
    if ($File.Name -match '(?i)(?:WindowsServer|Server20\d{2}|AzureStackHCI)') { return 'Server' }

    # Las familias amplias usan reglas CBS de aplicabilidad. No se intenta
    # deducir Client/Server a partir de identidades secundarias incluidas en el
    # paquete, porque eso produce falsos positivos en LCU, .NET, SafeOS y EP.
    if ($Category -in $script:AIOUpdateProductNeutralCategories) {
        return 'Any'
    }

    if ($Metadata) {
        $topLevel = @(
            $Metadata.UpdateMumPackageIdentifiers
            $Metadata.UpdateMumIdentityNames
        ) -join "`n"
        $serverSpecific = ($topLevel -match '(?i)Microsoft-Windows-(?:ServerCore|NanoServer|ServerDatacenter|ServerStandard).*Edition')
        $clientSpecific = ($topLevel -match '(?i)Microsoft-Windows-(?:Core|Professional|Enterprise|Education).*Edition')
        if ($serverSpecific -and -not $clientSpecific) { return 'Server' }
    }

    return 'Any'
}

function Test-AIOUpdatePackageCompatibility {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowNull()] [string]$ImageName,
        [AllowNull()] [string]$EditionId
    )

    if ($Package.Auxiliary) {
        return [pscustomobject]@{ Compatible = $false; Reason = 'Archivo auxiliar' }
    }
    if ($Package.PSObject.Properties['Installable'] -and -not [bool]$Package.Installable) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete no instalable: $($Package.Reason)" }
    }

    $targetArch = Convert-AIOUpdateArchitectureName -Architecture $Architecture
    # @($null) contiene un elemento: no representa una arquitectura real.
    # Normalizar alias y descartar valores vacios antes de filtrar candidatos.
    $hints = @($Package.Architectures | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    } | ForEach-Object { Convert-AIOUpdateArchitectureName -Architecture $_ } | Sort-Object -Unique)
    if ($hints.Count -gt 0 -and $targetArch -notin $hints) {
        return [pscustomobject]@{
            Compatible = $false
            Reason = "Arquitectura del paquete: $($hints -join ', '); destino: $targetArch"
        }
    }

    $product = [string]$Package.ProductHint
    if ($product -eq 'Windows10' -and $Build -ge [int]$script:AIOUpdatePolicy.Windows11FirstBuild) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete Windows 10 para una imagen build $Build" }
    }
    if ($product -eq 'Windows11' -and $Build -lt [int]$script:AIOUpdatePolicy.Windows11FirstBuild) {
        return [pscustomobject]@{ Compatible = $false; Reason = "Paquete Windows 11 para una imagen build $Build" }
    }
    if ($product -eq 'Server' -and $ImageName -and $ImageName -notmatch '(?i)Server|Azure Stack HCI') {
        return [pscustomobject]@{ Compatible = $false; Reason = 'Paquete orientado a Windows Server' }
    }

    $explicitEditionHints = @(
        if ($Package.PSObject.Properties['ExplicitEditions']) { $Package.ExplicitEditions }
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

    # Solo los atributos Edition/EditionID declarados explicitamente por
    # update.mum se usan como restriccion. No se aplica un limite arbitrario de
    # cantidad ni se confunden identidades internas de componentes con una
    # exclusividad real de edicion.
    if ($Package.Category -eq 'OS' -and $explicitEditionHints.Count -gt 0 -and $ImageName) {
        $targetEditions = @(Get-AIOUpdateImageEditionHints -ImageName $ImageName -EditionId $EditionId)
        if ($targetEditions.Count -gt 0 -and @($explicitEditionHints | Where-Object { $_ -in $targetEditions }).Count -eq 0) {
            return [pscustomobject]@{
                Compatible = $false
                Reason = "Edicion no aplicable: paquete $($explicitEditionHints -join ', '); imagen $ImageName"
            }
        }
    }

    # El build no se usa como bloqueo previo. Las ramas visibles pueden cambiar
    # mediante Enablement mientras la base CBS permanece en otra build. Mantener
    # una tabla de equivalencias obliga a modificar el modulo en cada version.
    # Arquitectura y producto se validan aqui; CBS/DISM decide la aplicabilidad
    # exacta y devuelve NotApplicable sin modificar la imagen cuando corresponde.
    # Las relaciones dinamicas de Enablement se conservan para verificar la
    # version final, pero nunca para descartar preventivamente un paquete valido.

    return [pscustomobject]@{ Compatible = $true; Reason = 'Compatible' }
}

function Get-AIOUpdateCompatiblePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string[]]$Category,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [AllowNull()] [string]$ImageName,
        [AllowNull()] [string]$EditionId,
        [switch]$Quiet
    )

    $compatible = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(Get-AIOUpdatePackages -Inventory $Inventory -Category $Category)) {
        if ($package.Category -eq 'LCU' -and $package.Extension -eq '.msu' -and $package.PSObject.Properties['IsLcuTarget'] -and -not $package.IsLcuTarget) { continue }
        $test = Test-AIOUpdatePackageCompatibility -Package $package -Architecture $Architecture -Build $Build -ImageName $ImageName -EditionId $EditionId
        if ($test.Compatible) {
            [void]$compatible.Add($package)
        }
        elseif (-not $Quiet) {
            Write-Host "   [INCOMPATIBLE] $($package.Name): $($test.Reason)" -ForegroundColor DarkYellow
            Write-AIOUpdateLog -Level WARN -Message "Paquete omitido por incompatibilidad: $($package.Name). $($test.Reason)"
        }
    }

    return [object[]]($compatible.ToArray())
}

function Test-AIOUpdatePackageInstalled {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    return [bool](Get-AIOUpdatePackageCbsEvidence -Package $Package -Inventory $InstalledInventory).Success
}


function Copy-AIOUpdateDirectoryWithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot,
        [string[]]$ExcludePatterns = @(),
        [switch]$OnlyExisting,
        [switch]$OnlyIfNewer,
        [ValidateSet('Sources', 'Boot', 'EfiBoot')]
        [string]$LocaleSurface
    )

    $results = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $SourceRoot -PathType Container)) {
        return @()
    }

    foreach ($file in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart('\')
        if ($LocaleSurface -and -not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface $LocaleSurface)) {
            Write-AIOUpdateLog -Level INFO -Message "Se omitio recurso de idioma no presente en Preflight: $LocaleSurface\$relative"
            continue
        }
        $skip = $false
        foreach ($pattern in $ExcludePatterns) {
            if ($relative -match $pattern) { $skip = $true; break }
        }
        if ($skip) { continue }

        $destination = Join-Path $DestinationRoot $relative
        if ($OnlyExisting -and -not (Test-Path -LiteralPath $destination -PathType Leaf)) { continue }

        $copyArgs = @{
            Source      = $file.FullName
            Destination = $destination
        }
        if ($OnlyIfNewer) { $copyArgs.OnlyIfNewer = $true }
        $result = Copy-AIOUpdateFileWithBackup @copyArgs
        if ($result) { [void]$results.Add($result) }
    }

    return [object[]]($results.ToArray())
}

function Clear-AIOUpdateFileProtectionAttributes {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $original = Get-AIOUpdateFileAccessSnapshot -Path $Path
    try {
        if ($null -eq $original.AttributesValue) { throw "No se pudieron leer los atributos de '$Path'." }
        if (($original.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Assert-AIOUpdateFileReparsePolicy -Path $Path -Snapshot $original
        }
        $mask = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden
        Set-AIOUpdateCopyFileAttributes -Path $Path -Attributes ([System.IO.FileAttributes]($original.AttributesValue -band (-bnot [int]$mask)))
    }
    catch {
        Write-AIOUpdateFileCopyDiagnostic -Source $Path -Destination $Path -Phase 'AttributesFailed' -Message $_.Exception.Message -OriginalDestination $original
        throw
    }
}

function Initialize-AIOUpdateFileReparseNative {
    [CmdletBinding()]
    param()

    if ('AdminImagenOffline.AIOUpdateReparseNative' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace AdminImagenOffline {
    public static class AIOUpdateReparseNative {
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

function Get-AIOUpdateFileReparseInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    Initialize-AIOUpdateFileReparseNative
    $info = [AdminImagenOffline.AIOUpdateReparseNative]::ReadInfo($Path)
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

function Assert-AIOUpdateFileReparsePolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$Snapshot
    )

    if (($Snapshot.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -eq 0) { return }
    if ($null -eq $Snapshot.ReparseTag) {
        throw "No se pudo identificar el punto de reanalisis de '${Path}': $($Snapshot.Errors -join ' | ')"
    }
    # WIM y WOF son filtros de almacenamiento, no enlaces que redirigen a
    # otra ruta. El filtro gestiona su materializacion durante la escritura.
    # No borrar el reparse point ni modificar las ACL de su carpeta padre.
    $tagHex = '0x{0:X8}' -f [uint32]$Snapshot.ReparseTag
    $isDirectory = ($Snapshot.AttributesValue -band [int][System.IO.FileAttributes]::Directory) -ne 0
    if ($isDirectory -or $tagHex -notin @('0x80000008', '0x80000017')) {
        throw "Punto de reanalisis no admitido para escritura: '$Path' (tag $tagHex)."
    }
    Write-AIOUpdateLog -Level INFO -Message "Archivo respaldado por WIM/WOF admitido para copia: '$Path' (tag $tagHex)."
}


function Get-AIOUpdateFileAccessSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    $state = [ordered]@{
        Path = $Path; Exists = $false; Attributes = $null; AttributesValue = $null
        OwnerSid = $null; Sddl = $null; AccessSddl = $null; Errors = @()
        ReparseTag = $null; ReparseTagHex = $null; ReparseKind = $null
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $state.Exists = $true
        $state.Attributes = [string]$item.Attributes
        $state.AttributesValue = [int]$item.Attributes
    }
    catch { $state.Errors += $_.Exception.Message }
    if ($state.Exists -and ($state.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        try {
            $reparse = Get-AIOUpdateFileReparseInfo -Path $Path
            # Leer atributos y tag del mismo handle. Si el filtro materializo
            # el archivo desde Get-Item, aceptar su nuevo estado sin reparse.
            $state.AttributesValue = $reparse.AttributesValue
            $state.Attributes = [string][System.IO.FileAttributes]$reparse.AttributesValue
            $state.ReparseTag = $reparse.Tag
            $state.ReparseTagHex = $reparse.TagHex
            $state.ReparseKind = $reparse.Kind
        }
        catch { $state.Errors += "ReparseTag: $($_.Exception.Message)" }
    }
    if ($state.Exists) {
        try {
            $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
            $sections = [System.Security.AccessControl.AccessControlSections]::Access -bor [System.Security.AccessControl.AccessControlSections]::Owner
            $state.OwnerSid = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            $state.Sddl = $acl.GetSecurityDescriptorSddlForm($sections)
            $state.AccessSddl = $acl.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access)
        }
        catch { $state.Errors += $_.Exception.Message }
    }
    return [pscustomobject]$state
}

function Write-AIOUpdateFileCopyDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [Parameter(Mandatory = $true)] [string]$Message,
        [AllowNull()] [object]$OriginalDestination
    )

    # Se captura antes del desmontaje de emergencia; el paquete de diagnostico
    # ya recoge los .log de la sesion, incluso cuando el WIM fue descartado.
    try {
        $record = [ordered]@{
            Timestamp = (Get-Date).ToString('o'); Phase = $Phase; Message = $Message
            OriginalDestination = $OriginalDestination
            Source = Get-AIOUpdateFileAccessSnapshot -Path $Source
            Destination = Get-AIOUpdateFileAccessSnapshot -Path $Destination
            Parent = Get-AIOUpdateFileAccessSnapshot -Path (Split-Path -Parent $Destination)
        }
        $json = $record | ConvertTo-Json -Depth 8 -Compress
        Write-AIOUpdateLog -Level WARN -Message "SetupDU/acceso: $json"
        if ($script:AIOUpdateSessionRoot -and (Test-Path -LiteralPath $script:AIOUpdateSessionRoot -PathType Container)) {
            Add-Content -LiteralPath (Join-Path $script:AIOUpdateSessionRoot 'SetupDU_FileAccess.log') -Value $json -Encoding UTF8 -ErrorAction Stop
        }
    }
    catch { Write-AIOUpdateLog -Level WARN -Message "No se pudo registrar el acceso de SetupDU a '${Destination}': $($_.Exception.Message)" }
}

function Invoke-AIOUpdateFileSecurityCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet('takeown.exe', 'icacls.exe')] [string]$Name,
        [Parameter(Mandatory = $true)] [string[]]$Arguments
    )

    $executable = Join-Path $script:AIOUpdateNativeSystemDirectory $Name
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "No se encontro '$executable'." }
    # En Windows PowerShell 5.1 stderr nativo puede producir ErrorRecord.
    # Capturarlo no debe impedir leer y comprobar el codigo real del proceso.
    $ErrorActionPreference = 'Continue'
    # El proceso nativo actualiza la variable global, no una copia local.
    $global:LASTEXITCODE = $null
    $output = & $executable @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $detail = ($output | Out-String).Trim()
    Write-AIOUpdateLog -Level INFO -Message "SetupDU: $Name; codigo=$exitCode; $detail"
    if ($null -eq $exitCode -or $exitCode -ne 0) { throw "SetupDU: $Name fallo con codigo '${exitCode}': $detail" }
}

function Set-AIOUpdateCopyFileAttributes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [System.IO.FileAttributes]$Attributes
    )

    # File.SetAttributes solo admite estos atributos basicos. SparseFile,
    # Compressed, Encrypted, Directory y ReparsePoint requieren otras APIs
    # o describen el almacenamiento/tipo del archivo. No se restauran aqui.
    # Al sobrescribir un archivo disperso de un WIM, SparseFile puede cambiar
    # sin alterar los bytes; su integridad se verifica por SHA-256 en la copia.
    $settableMask = [System.IO.FileAttributes]::ReadOnly -bor
        [System.IO.FileAttributes]::Hidden -bor
        [System.IO.FileAttributes]::System -bor
        [System.IO.FileAttributes]::Archive -bor
        [System.IO.FileAttributes]::Temporary -bor
        [System.IO.FileAttributes]::Offline -bor
        [System.IO.FileAttributes]::NotContentIndexed
    $requested = [System.IO.FileAttributes]([int]$Attributes -band [int]$settableMask)
    $current = [System.IO.File]::GetAttributes($Path)
    if (([int]$current -band [int]$settableMask) -eq [int]$requested) { return }

    # Normal es el valor para quitar todos los atributos editables; no se
    # combina con otros bits ni se compara como un indicador independiente.
    $toSet = if ([int]$requested -eq 0) { [System.IO.FileAttributes]::Normal } else { $requested }
    [System.IO.File]::SetAttributes($Path, $toSet)
    $observed = [System.IO.File]::GetAttributes($Path)
    if (([int]$observed -band [int]$settableMask) -ne [int]$requested) {
        throw "No se pudieron establecer los atributos editables '$requested' en '$Path'. Atributos observados: '$observed'."
    }
}

function Restore-AIOUpdateCopyFileSecurity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [object]$Original
    )

    $failures = New-Object System.Collections.Generic.List[string]
    # Devolver el propietario mientras el permiso temporal aun permite WRITE_DAC.
    # El SID permite restaurarlo sin depender del idioma del sistema.
    try {
        $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($current.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $Original.OwnerSid) {
            Invoke-AIOUpdateFileSecurityCommand -Name 'icacls.exe' -Arguments @($Path, '/setowner', ('*' + $Original.OwnerSid), '/Q')
        }
    }
    catch { [void]$failures.Add("Propietario: $($_.Exception.Message)") }
    # Restaurar solo la DACL; no cambiar grupo ni auditoria, ni inventar un
    # propietario TrustedInstaller como alternativa a la identidad original.
    try {
        $current = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if ($current.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Access) -cne $Original.AccessSddl) {
            $restoreAcl = New-Object System.Security.AccessControl.FileSecurity
            $restoreAcl.SetSecurityDescriptorSddlForm($Original.Sddl, [System.Security.AccessControl.AccessControlSections]::Access)
            Set-Acl -LiteralPath $Path -AclObject $restoreAcl -ErrorAction Stop
        }
    }
    catch { [void]$failures.Add("DACL: $($_.Exception.Message)") }
    try {
        $restored = Get-AIOUpdateFileAccessSnapshot -Path $Path
        if ($restored.OwnerSid -ne $Original.OwnerSid -or $restored.Sddl -cne $Original.Sddl) {
            throw 'La comprobacion de propietario/DACL no coincide con el respaldo original.'
        }
    }
    catch { [void]$failures.Add($_.Exception.Message) }
    if ($failures.Count -gt 0) { throw "No se pudo restaurar la seguridad de '${Path}': $($failures -join ' | ')" }
}

function Copy-AIOUpdateSetupDUFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    $original = $null
    $securityTouched = $false
    $attributesTouched = $false
    $copyError = $null
    try {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf -ErrorAction Stop)) { throw "No existe el archivo SetupDU '$Source'." }
        if (Test-Path -LiteralPath $Destination -PathType Container -ErrorAction Stop) { throw "El destino SetupDU es un directorio: '$Destination'." }
        $hadDestination = Test-Path -LiteralPath $Destination -PathType Leaf -ErrorAction Stop
        if ($hadDestination) {
            $original = Get-AIOUpdateFileAccessSnapshot -Path $Destination
            if ($null -eq $original.AttributesValue) { throw "No se pudieron respaldar los atributos de '$Destination'." }
            if (($original.AttributesValue -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                Assert-AIOUpdateFileReparsePolicy -Path $Destination -Snapshot $original
            }
            $mask = [System.IO.FileAttributes]::ReadOnly -bor [System.IO.FileAttributes]::System -bor [System.IO.FileAttributes]::Hidden
            $writableAttributes = [System.IO.FileAttributes]($original.AttributesValue -band (-bnot [int]$mask))
        }

        try {
            try {
                if ($hadDestination) {
                    $attributesTouched = $true
                    Set-AIOUpdateCopyFileAttributes -Path $Destination -Attributes $writableAttributes
                }
                Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            }
            catch {
                $accessDenied = $false
                $exception = $_.Exception
                while ($null -ne $exception) {
                    if ($exception -is [System.UnauthorizedAccessException] -or (($exception.HResult -band 0xFFFF) -eq 5)) { $accessDenied = $true; break }
                    $exception = $exception.InnerException
                }
                if (-not $hadDestination -or -not $accessDenied) { throw }
                Write-AIOUpdateFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'BeforePermissionRetry' -Message $_.Exception.Message -OriginalDestination $original
                # No alterar seguridad sin poder restaurar exactamente lo leido
                # antes del primer intento. No se usa Unlock-Single-File porque
                # su contrato no propaga todas las fallas.
                if (-not $original.Sddl -or -not $original.OwnerSid -or -not $original.AccessSddl) {
                    throw "No se puede reintentar '$Destination': no se pudo respaldar su propietario/DACL. $($original.Errors -join ' | ')"
                }
                $securityTouched = $true
                Invoke-AIOUpdateFileSecurityCommand -Name 'takeown.exe' -Arguments @('/F', $Destination, '/A')
                Invoke-AIOUpdateFileSecurityCommand -Name 'icacls.exe' -Arguments @($Destination, '/grant', '*S-1-5-32-544:F', '/Q')
                Set-AIOUpdateCopyFileAttributes -Path $Destination -Attributes $writableAttributes
                Copy-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
                Write-AIOUpdateLog -Level INFO -Message "SetupDU: copia recuperada tras ajustar permisos de '$Destination'."
            }
            $sourceHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
            $destinationHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash
            if ($sourceHash -ne $destinationHash) { throw "Verificacion SHA-256 fallida para el archivo SetupDU '$Destination'." }
        }
        catch {
            $copyError = $_
            Write-AIOUpdateFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'CopyFailed' -Message $_.Exception.Message -OriginalDestination $original
            throw
        }
        finally {
            $restoreErrors = New-Object System.Collections.Generic.List[string]
            # Atributos primero: todavia contamos con el permiso temporal.
            if ($attributesTouched) {
                try { Set-AIOUpdateCopyFileAttributes -Path $Destination -Attributes ([System.IO.FileAttributes]$original.AttributesValue) }
                catch { [void]$restoreErrors.Add("Atributos: $($_.Exception.Message)") }
            }
            if ($securityTouched) {
                try { Restore-AIOUpdateCopyFileSecurity -Path $Destination -Original $original }
                catch { [void]$restoreErrors.Add($_.Exception.Message) }
            }
            if ($restoreErrors.Count -gt 0) {
                $copyDetail = if ($copyError) { " Error de copia: $($copyError.Exception.Message)." } else { '' }
                # Una restauracion fallida impide commit aunque la copia funciono.
                throw "SetupDU: fallo la restauracion de '${Destination}': $($restoreErrors -join ' | ').$copyDetail"
            }
        }
    }
    catch {
        Write-AIOUpdateFileCopyDiagnostic -Source $Source -Destination $Destination -Phase 'FinalFailure' -Message $_.Exception.Message -OriginalDestination $original
        throw
    }
}

function Merge-AIOUpdateSetupDUIntoDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ExtractRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot
    )

    if (-not (Test-Path -LiteralPath $ExtractRoot -PathType Container)) { return 0 }
    Initialize-AIOUpdateDirectory -Path $DestinationRoot
    $count = 0
    foreach ($file in @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($ExtractRoot.Length).TrimStart('\')
        if ($relative -match '^(?i)sources[\\/](.+)$') { $relative = $Matches[1] }
        if ($relative -match '(?i)(?:^|[\\/])(update\.mum|update\.cat|WSUSSCAN\.cab)$') { continue }
        if (-not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface Sources)) {
            Write-AIOUpdateLog -Level INFO -Message "SetupDU/boot.wim: se omitio idioma ausente del Preflight: $relative"
            continue
        }
        $destination = Join-Path $DestinationRoot $relative
        Initialize-AIOUpdateDirectory -Path (Split-Path -Parent $destination)
        Copy-AIOUpdateSetupDUFile -Source $file.FullName -Destination $destination
        $count++
    }
    return $count
}

function Remove-AIOUpdateWinPERejuv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    # No se usa una build minima: si WinPE-Rejuv existe y esta activo, se
    # retira; si no existe, la funcion no hace nada. Esto evita mantener un
    # umbral de version cuando Microsoft cambie la composicion de WinPE.
    $packages = @(
        $InstalledInventory |
            Where-Object {
                $_.PackageName -match '(?i)WinPE-Rejuv-Package' -and
                $_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
            } |
            Select-Object -ExpandProperty PackageName -Unique
    )
    if ($packages.Count -eq 0) { return @() }

    $results = New-Object System.Collections.Generic.List[object]
    foreach ($packageName in $packages) {
        Write-Host "   [WINPE] Retirando $packageName antes de la LCU..." -ForegroundColor DarkYellow
        $result = Invoke-AIOUpdateDism -Arguments @(
            "/Image:$MountPath",
            '/Remove-Package',
            "/PackageName:$packageName",
            "/ScratchDir:$ScratchPath"
        ) -Context "Boot: retirando WinPE-Rejuv" -AllowNotApplicable

        $postRemovalInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $MountPath -Strict)
        $exactEntries = @(
            $postRemovalInventory |
                Where-Object { [string]$_.PackageName -ieq $packageName }
        )
        $states = @(
            $exactEntries |
                ForEach-Object { [string]$_.PackageState } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $blockingStates = @(
            $exactEntries |
                Where-Object {
                    [string]$_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
                }
        )
        $removalVerified = ($blockingStates.Count -eq 0)
        $stateText = if ($states.Count -eq 0) { 'Ausente' } else { $states -join ', ' }

        $rejuvArchitecturePattern = (@($script:AIOUpdateArchitectureCatalog | ForEach-Object { [regex]::Escape([string]$_.AdkFolder) }) | Sort-Object -Unique) -join '|'
        $isNeutralRejuv = ($packageName -match ("(?i)~(?:$rejuvArchitecturePattern)~~"))
        $advisoryOnly = (-not $removalVerified -and $isNeutralRejuv)

        if ($removalVerified) {
            Write-Host "      [VERIFICADO] Estado inmediato posterior: $stateText" -ForegroundColor DarkGray
        }
        elseif ($advisoryOnly) {
            Write-Host "      [PENDIENTE] CBS aun informa '$stateText'; se confirmara despues de la LCU y la limpieza." -ForegroundColor DarkYellow
            Write-Host '      [INFORMATIVO] Es el componente neutro de Rejuv; no bloqueara el mantenimiento si CBS lo conserva o restablece.' -ForegroundColor DarkGray
        }
        else {
            Write-Host "      [AVISO] La identidad localizada sigue activa: $stateText" -ForegroundColor Yellow
        }

        [void]$results.Add([pscustomobject]@{
            Package = [pscustomobject]@{
                Name                    = $packageName
                Category                = 'WinPE-Rejuv'
                RemovalVerified         = $removalVerified
                RemovalState            = $stateText
                RemovalCheckedBeforeLcu = $true
                IsNeutralRejuv          = $isNeutralRejuv
                AdvisoryOnly            = $advisoryOnly
            }
            Result  = $result
        })
    }
    return [object[]]($results.ToArray())
}

function Test-AIOUpdateDirectoryHashMirror {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceRoot,
        [Parameter(Mandatory = $true)] [string]$DestinationRoot,
        [string[]]$ExcludeNames = @()
    )

    $verified = 0
    foreach ($sourceFile in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -ErrorAction Stop)) {
        if ($sourceFile.Name -in $ExcludeNames) { continue }
        $relative = $sourceFile.FullName.Substring($SourceRoot.Length).TrimStart('\')
        $destination = Join-Path $DestinationRoot $relative
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            throw "Falta el archivo copiado '$destination'."
        }
        $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -ne $destinationHash) {
            throw "El archivo '$destination' no coincide por SHA-256."
        }
        $verified++
    }
    return $verified
}

function Apply-AIOUpdateDefenderPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot,
        [Parameter(Mandatory = $true)] [string]$DismScratch,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )

    if (@($Packages).Count -eq 0) { return @() }
    $results = New-Object System.Collections.Generic.List[object]
    $defenderRoot = Join-Path $MountPath 'ProgramData\Microsoft\Windows Defender'

    foreach ($package in $Packages) {
        $extractRoot = Join-Path $ScratchRoot ('Defender_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $extractRoot -Empty
        try {
            $verifiedFiles = 0
            & $script:AIOUpdateExpandPath '-R' '-F:*' $package.FullName $extractRoot *> $null
            $definitions = @(
                Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -match '(?i)Definition Updates[\\/]Updates$' } |
                    Select-Object -First 1
            )
            $platform = @(
                Get-ChildItem -LiteralPath $extractRoot -Recurse -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'Platform' -and @(Get-ChildItem -LiteralPath $_.FullName -Directory -ErrorAction SilentlyContinue).Count -gt 0 } |
                    Select-Object -First 1
            )

            if ($definitions.Count -eq 0 -and $platform.Count -eq 0) {
                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $MountPath -Packages @($package) -ScratchPath $DismScratch -Context 'Install: Defender CBS' -AllowNotApplicable -InstalledInventory $InstalledInventory)) {
                    [void]$results.Add($entry)
                }
                continue
            }

            if ($definitions.Count -gt 0) {
                $destination = Join-Path $defenderRoot 'Definition Updates\Updates'
                Initialize-AIOUpdateDirectory -Path $destination
                Copy-Item -Path (Join-Path $definitions[0].FullName '*') -Destination $destination -Recurse -Force -ErrorAction Stop
                Remove-Item -LiteralPath (Join-Path $destination 'MpSigStub.exe') -Force -ErrorAction SilentlyContinue
                $verifiedFiles += Test-AIOUpdateDirectoryHashMirror -SourceRoot $definitions[0].FullName -DestinationRoot $destination -ExcludeNames @('MpSigStub.exe')
            }

            if ($platform.Count -gt 0) {
                $destination = Join-Path $defenderRoot 'Platform'
                Initialize-AIOUpdateDirectory -Path $destination
                Copy-Item -Path (Join-Path $platform[0].FullName '*') -Destination $destination -Recurse -Force -ErrorAction Stop
                Get-ChildItem -LiteralPath $destination -Recurse -Filter 'MpSigStub.exe' -File -ErrorAction SilentlyContinue |
                    Remove-Item -Force -ErrorAction SilentlyContinue
                $verifiedFiles += Test-AIOUpdateDirectoryHashMirror -SourceRoot $platform[0].FullName -DestinationRoot $destination -ExcludeNames @('MpSigStub.exe')
            }

            $result = [pscustomobject]@{
                Success      = $true
                State        = 'Success'
                ExitCode     = 0
                UnsignedCode = [uint32]0
                Context      = "Defender - $($package.Name)"
                VerifiedFiles = [int]$verifiedFiles
            }
            [void]$results.Add([pscustomobject]@{ Package = $package; Result = $result })
            Write-AIOUpdateLog -Level INFO -Message "Defender actualizado mediante copia de plataforma/firmas: $($package.Name)"
        }
        finally {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    return [object[]]($results.ToArray())
}

function Save-AIOUpdateBootDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$RelativePath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [hashtable]$CaptureTable
    )

    $source = Join-Path $MountPath $RelativePath
    if (-not (Test-Path -LiteralPath $source -PathType Container)) { return }
    $destination = Join-Path $CaptureRoot $Key
    Initialize-AIOUpdateDirectory -Path $destination -Empty
    Copy-Item -Path (Join-Path $source '*') -Destination $destination -Recurse -Force -ErrorAction Stop
    $CaptureTable[$Key] = $destination
}

function Rebuild-AIOUpdateWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [switch]$Bootable
    )

    $images = @(Get-AIOUpdateImageMetadata -ImagePath $WimPath | Sort-Object ImageIndex)
    if ($images.Count -eq 0) { throw "No hay indices para reconstruir '$WimPath'." }

    $leaf = [System.IO.Path]::GetFileName($WimPath)
    $temp = Join-Path $StagingRoot ($leaf + '.rebuild.wim')
    Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

    foreach ($image in $images) {
        $arguments = @(
            '/Export-Image',
            "/SourceImageFile:$WimPath",
            "/SourceIndex:$($image.ImageIndex)",
            "/DestinationImageFile:$temp",
            '/Compress:max',
            '/CheckIntegrity',
            "/ScratchDir:$ScratchPath"
        )
        [void](Invoke-AIOUpdateDism -Arguments $arguments -Context "Reconstruyendo $leaf indice $($image.ImageIndex)")
    }

    $rebuilt = @(Get-AIOUpdateImageMetadata -ImagePath $temp | Sort-Object ImageIndex)
    if ($rebuilt.Count -ne $images.Count) {
        throw "La reconstruccion de '$leaf' cambio el numero de indices."
    }

    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $WimPath
    if (-not $preflightPath) {
        throw "No se encontro la copia Preflight de '$leaf'; no se reemplazara el WIM original."
    }

    $expectedCount = $images.Count
    $verifier = {
        param($candidate)
        $verifiedImages = @(Get-AIOUpdateImageMetadata -ImagePath $candidate | Sort-Object ImageIndex)
        if ($verifiedImages.Count -ne $expectedCount) {
            throw "La verificacion posterior de '$leaf' devolvio $($verifiedImages.Count) indices; se esperaban $expectedCount."
        }
    }.GetNewClosure()

    [void](Invoke-AIOUpdateAtomicReplacement -Source $temp -Destination $WimPath -Context "Reemplazando $leaf reconstruido" -MoveSource -Verifier $verifier)
    Write-AIOUpdateLog -Level INFO -Message "$leaf reconstruido y optimizado. Restauracion maestra: $preflightPath"

    return [pscustomobject]@{
        Applied       = $true
        WimPath       = $WimPath
        BackupPath    = $preflightPath
        BackupType    = 'Preflight'
        ImageCount    = $rebuilt.Count
        DuplicateCopy = $false
    }
}

function Set-AIOUpdateWimCreationTime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$WimPath,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot
    )

    $wimlib = Find-AIOUpdateWimlib
    if (-not $wimlib) {
        throw 'No se encontro wimlib-imagex.exe. Copialo en AdminImagenOffline\Tools\wimlib o agregalo al PATH del sistema para modificar la fecha interna del WIM.'
    }

    $xmlPath = Join-Path $ScratchRoot ([System.IO.Path]::GetFileName($WimPath) + '.xml')
    $verifyPath = Join-Path $ScratchRoot ([System.IO.Path]::GetFileName($WimPath) + '.verify.xml')
    Remove-Item -LiteralPath $xmlPath, $verifyPath -Force -ErrorAction SilentlyContinue

    & $wimlib info $WimPath --extract-xml $xmlPath *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $xmlPath -PathType Leaf)) {
        throw "wimlib no pudo extraer los metadatos de '$WimPath'."
    }

    [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
    $expected = @{}
    foreach ($image in @($xml.WIM.IMAGE)) {
        $index = [int]$image.INDEX
        $high = [string]$image.LASTMODIFICATIONTIME.HIGHPART
        $low = [string]$image.LASTMODIFICATIONTIME.LOWPART
        if ([string]::IsNullOrWhiteSpace($high) -or [string]::IsNullOrWhiteSpace($low)) { continue }

        & $wimlib info $WimPath $index `
            --image-property "CREATIONTIME/HIGHPART=$high" `
            --image-property "CREATIONTIME/LOWPART=$low" *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "wimlib no pudo modificar CREATIONTIME del indice $index en '$WimPath'."
        }
        $expected[$index] = "$high|$low"
    }

    & $wimlib info $WimPath --extract-xml $verifyPath *> $null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $verifyPath -PathType Leaf)) {
        throw "No se pudo verificar CREATIONTIME en '$WimPath'."
    }

    [xml]$verifyXml = Get-Content -LiteralPath $verifyPath -Raw -ErrorAction Stop
    foreach ($image in @($verifyXml.WIM.IMAGE)) {
        $index = [int]$image.INDEX
        if (-not $expected.ContainsKey($index)) { continue }
        $actual = "$([string]$image.CREATIONTIME.HIGHPART)|$([string]$image.CREATIONTIME.LOWPART)"
        if ($actual -ne $expected[$index]) {
            throw "CREATIONTIME no coincide con LASTMODIFICATIONTIME en el indice $index de '$WimPath'."
        }
    }

    $file = Get-Item -LiteralPath $WimPath -ErrorAction Stop
    $file.CreationTimeUtc = $file.LastWriteTimeUtc
    Remove-Item -LiteralPath $xmlPath, $verifyPath -Force -ErrorAction SilentlyContinue
    Write-AIOUpdateLog -Level INFO -Message "Fecha CREATIONTIME igualada a LASTMODIFICATIONTIME en '$WimPath'."
    return $true
}


function Get-AIOUpdatePackageInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$RepositoryRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchRoot
    )

    Write-Host ' Leyendo metadatos del repositorio de actualizaciones...' -ForegroundColor DarkCyan
    $resolvedRoot = (Resolve-Path -LiteralPath $RepositoryRoot -ErrorAction Stop).Path
    $files = @(Get-AIOUpdateRepositoryPackageFiles -RepositoryRoot $resolvedRoot)
    $signatureLines = New-Object System.Collections.Generic.List[string]
    foreach ($file in $files) { [void]$signatureLines.Add(('{0}|{1}|{2}' -f $file.FullName.ToLowerInvariant(), [int64]$file.Length, [int64]$file.LastWriteTimeUtc.Ticks)) }
    $inventoryCacheKey = Get-AIOUpdateTextSha256 -Text (($signatureLines -join "`n") + "`n")
    if ($script:AIOUpdateRepositoryInventoryCache.ContainsKey($inventoryCacheKey)) {
        $script:AIOUpdateOptimizationStats.RepositoryCacheHits++
        return [object[]]$script:AIOUpdateRepositoryInventoryCache[$inventoryCacheKey]
    }

    $inventory = New-Object System.Collections.Generic.List[object]
    $position = 0
    try {
        foreach ($file in $files) {
            Write-Progress -Activity 'Clasificando actualizaciones' -Status "$position de $($files.Count) procesados; actual: $($file.Name)" -PercentComplete ([int][math]::Floor(($position * 100.0) / [math]::Max(1, $files.Count)))
            $metadataTimer = [System.Diagnostics.Stopwatch]::StartNew()
            Write-AIOUpdateLog -Level INFO -Message "Iniciando lectura de metadatos: $($file.Name)."
            $classification = Get-AIOUpdatePackageCategory -File $file -RepositoryRoot $resolvedRoot -ScratchRoot $ScratchRoot
            Write-AIOUpdateLog -Level INFO -Message ("Metadatos leidos: {0}; segundos={1:N2}." -f $file.Name, $metadataTimer.Elapsed.TotalSeconds)
            $metadata = $classification.Metadata
            $versionInfo = if ($metadata) {
                [pscustomobject]@{
                    Version  = [version]$metadata.Version
                    Build    = [int]$metadata.VersionBuild
                    Reliable = [bool]$metadata.VersionReliable
                    Source   = [string]$metadata.VersionSource
                }
            }
            else {
                Get-AIOUpdatePackageVersionInfo -FileName $file.Name -UpdateMumText $null
            }
            $version = [version]$versionInfo.Version
			$isCheckpoint = $false
            if ($classification.Category -eq 'LCU' -and $file.Extension -ieq '.msu' -and $metadata) {
                $checkpointProbe = @(
                    $metadata.IdentityNames
                    $metadata.PackageIdentifiers
                    $metadata.MetadataNames
                    $metadata.Names
                    $metadata.Text
                ) -join "`n"
                $isCheckpoint = (
                    $metadata.HasBaseline -or
                    $checkpointProbe -match '(?i)(?:Checkpoint|Baseline)(?:[-_. ]?(?:LCU|Cumulative|Package|Update))?'
                )
            }

            $identityHints = @()
            if ($metadata) {
                $identityHints = @(
                    $metadata.UpdateMumPackageIdentifiers
                    $metadata.PackageIdentifiers
                    $metadata.UpdateMumIdentityNames
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique
            }

            $architectureInfo = Get-AIOUpdatePackageArchitectureInfo -File $file -Metadata $metadata -Category $classification.Category
            [void]$inventory.Add([pscustomobject]@{
                File          = $file
                FullName      = $file.FullName
                Name          = $file.Name
                Extension     = $file.Extension.ToLowerInvariant()
                Category      = $classification.Category
                Reason        = $classification.Reason
                KB            = Get-AIOUpdateKbId -Text $file.Name
                Version       = $version
                VersionBuild  = [int]$versionInfo.Build
                VersionReliable = [bool]$versionInfo.Reliable
                VersionSource = [string]$versionInfo.Source
                Size          = [long]$file.Length
                Auxiliary     = ($classification.Category -eq 'Auxiliary')
                Installable   = ($classification.Category -notin @('Auxiliary', 'Unknown'))
                IsCheckpoint  = [bool]$isCheckpoint
                IsLcuTarget   = $true
                IsLcuPrerequisiteCandidate = $false
                Metadata      = $metadata
                Architectures = [string[]]$architectureInfo.Architectures
                ArchitectureSource = [string]$architectureInfo.Source
                Editions      = [string[]](Get-AIOUpdatePackageEditionHints -Metadata $metadata)
                ExplicitEditions = [string[]](Get-AIOUpdatePackageExplicitEditionHints -Metadata $metadata)
                ProductHint   = Get-AIOUpdatePackageProductHint -File $file -Metadata $metadata -Category $classification.Category
                IdentityHints = [string[]]$identityHints
            })
            $position++
            Write-Progress -Activity 'Clasificando actualizaciones' -Status "$position de $($files.Count) procesados: $($file.Name)" -PercentComplete ([int][math]::Floor(($position * 100.0) / [math]::Max(1, $files.Count)))
        }
    } finally {
        Write-Progress -Activity 'Clasificando actualizaciones' -Completed
    }

    # La misma identidad de familia gobierna la seleccion y el staging.
    Set-AIOUpdateLcuTargets -Inventory ([object[]]$inventory.ToArray())

    $resultInventory = [object[]]($inventory.ToArray())
    Initialize-AIOUpdateServicingBuildRelations -Inventory $resultInventory
    $script:AIOUpdateRepositoryInventoryCache[$inventoryCacheKey] = $resultInventory
    return $resultInventory
}

function Get-AIOUpdatePackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory,

        [Parameter(Mandatory = $true)]
        [string[]]$Category
    )

    return @(
        $Inventory |
            Where-Object { $_.Category -in $Category -and $_.Installable } |
            Sort-Object @{ Expression = { $_.Version }; Ascending = $true }, Name
    )
}

function Get-AIOUpdateInventorySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Inventory
    )

    $categories = $script:AIOUpdateCategoryOrder
    foreach ($category in $categories) {
        $items = @($Inventory | Where-Object { $_.Category -eq $category })
        [pscustomobject]@{
            Category = $category
            Count    = $items.Count
            Size     = [long](($items | Measure-Object -Property Size -Sum).Sum)
            Items    = $items
        }
    }
}

function Format-AIOUpdateByteSize {
    [CmdletBinding()]
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Get-AIOUpdateImageMetadata {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ImagePath)
    $summary = Invoke-AIOUpdateDism -Arguments @('/Get-ImageInfo', "/ImageFile:$ImagePath") -Context 'Consultar indices WIM' -SuccessCodes @(0) -Quiet
    $indexes = @($summary.Output | ForEach-Object { if ([string]$_ -match '^\s*Index\s*:\s*(\d+)\s*$') { [int]$Matches[1] } } | Sort-Object -Unique)
    if (-not $indexes.Count) { throw "DISM no devolvio indices reconocibles para '$ImagePath'." }
    foreach ($index in $indexes) {
        $result = Invoke-AIOUpdateDism -Arguments @('/Get-ImageInfo', "/ImageFile:$ImagePath", "/Index:$index") -Context "Consultar metadatos WIM indice $index" -SuccessCodes @(0) -Quiet
        $fields = @{}
        foreach ($line in $result.Output) {
            if ([string]$line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') { $fields[$Matches[1].Trim()] = $Matches[2] }
        }
        $version = $null
        if (-not [version]::TryParse([string]$fields['Version'], [ref]$version) -or -not $fields['Architecture'] -or -not $fields['Name']) {
            throw "DISM no devolvio Version, Architecture y Name validos para el indice $index."
        }
        $revision = 0
        if ($fields.ContainsKey('ServicePack Build') -and -not [int]::TryParse($fields['ServicePack Build'], [ref]$revision)) { throw 'ServicePack Build no reconocido.' }
        if ($version.Revision -lt 0) { $version = New-Object version($version.Major, $version.Minor, $version.Build, $revision) }
        [pscustomobject]@{
            ImageIndex = $index; ImageName = $fields['Name']; ImageDescription = $fields['Description']
            Version = $version; Architecture = $fields['Architecture']; EditionId = $fields['Edition']
            InstallationType = $fields['Installation']; ServicePackBuild = $revision
        }
    }
}

function Select-AIOUpdateInstallIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Images
    )

    Write-Host ''
    Write-Host ' Indices disponibles en install.wim:' -ForegroundColor Yellow
    foreach ($image in $Images) {
        $version = if ($image.Version) { $image.Version } else { 'N/D' }
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        Write-Host ("   [{0}] {1} | {2} | {3}" -f $image.ImageIndex, $image.ImageName, $version, $architecture) -ForegroundColor White
    }

    while ($true) {
        $answer = (Read-Host "`nIndices a actualizar separados por coma/espacio, o T para todos").Trim()
        if ($answer -eq 'T') {
            return @($Images | ForEach-Object { [int]$_.ImageIndex })
        }

        $requested = @(
            $answer -split '[,; ]+' |
                Where-Object { $_ -match '^\d+$' } |
                ForEach-Object { [int]$_ } |
                Sort-Object -Unique
        )
        $valid = @($Images | ForEach-Object { [int]$_.ImageIndex })
        $invalid = @($requested | Where-Object { $_ -notin $valid })
        if ($requested.Count -gt 0 -and $invalid.Count -eq 0) {
            return $requested
        }

        Write-Host 'Seleccion invalida. Usa indices existentes o T.' -ForegroundColor Red
    }
}

function Convert-AIOUpdateArchitectureName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Architecture
    )

    $value = ([string]$Architecture).Trim().ToLowerInvariant()
    if ([string]::IsNullOrWhiteSpace($value)) { return 'Unknown' }
    $entry = Get-AIOUpdateArchitectureCatalogEntry -Architecture $value
    if ($entry) { return [string]$entry.Name }
    return $value
}

function Format-AIOUpdateImageDisplayName {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$ImageName,
        [AllowNull()] [object]$Architecture
    )

    $name = ([string]$ImageName).Trim()
    $architectureName = Convert-AIOUpdateArchitectureName -Architecture $Architecture

    if ([string]::IsNullOrWhiteSpace($name)) {
        return $architectureName
    }
    if ([string]::IsNullOrWhiteSpace($architectureName) -or $architectureName -eq 'Unknown') {
        return $name
    }

    $architectureEntry = Get-AIOUpdateArchitectureCatalogEntry -Architecture $architectureName
    $aliases = if ($architectureEntry) {
        @($architectureEntry.Name) + @($architectureEntry.Aliases) + @($architectureEntry.AdkFolder)
    }
    else { @($architectureName) }

    foreach ($alias in $aliases) {
        $escaped = [regex]::Escape([string]$alias)
        if ($name -match "(?i)(?:^|[\s\(\[\-_])$escaped(?:$|[\s\)\]\-_])") {
            return $name
        }
    }

    return "$name ($architectureName)"
}

function Assert-AIOUpdateCompatibleIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Images,

        [Parameter(Mandatory = $true)]
        [int[]]$Indexes
    )

    $selected = @($Images | Where-Object { [int]$_.ImageIndex -in $Indexes })
    $architectures = @($selected | ForEach-Object { Convert-AIOUpdateArchitectureName -Architecture $_.Architecture } | Sort-Object -Unique)
    $builds = @($selected | ForEach-Object { ([version]$_.Version).Build } | Sort-Object -Unique)

    if ($architectures.Count -gt 1) {
        throw "Los indices seleccionados tienen arquitecturas diferentes: $($architectures -join ', ')."
    }
    if ($builds.Count -gt 1) {
        throw "Los indices seleccionados tienen builds diferentes: $($builds -join ', ')."
    }

    return [pscustomobject]@{
        Images       = $selected
        Architecture = $architectures[0]
        Build        = [int]$builds[0]
        Version      = [version]$selected[0].Version
    }
}

function Assert-AIOUpdateEsuPrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [psobject]$Compatibility
    )

    # Detecta la etapa ESU por la version interna de la LCU. No se modifican
    # ni se omiten comprobaciones de licencia. En imagenes cliente no LTSC,
    # el paquete de preparacion no equivale a una licencia ESU activa para
    # mantenimiento offline.
    $esuEraLcus = @($Inventory | Where-Object { Test-AIOUpdateWindows10EsuEraLcu -Package $_ })
    if ($esuEraLcus.Count -eq 0) { return }

    $nonLtsc = @($Compatibility.Images | Where-Object {
        [string]$_.ImageName -notmatch '(?i)LTSC|Long.Term.Servicing'
    })
    if ($nonLtsc.Count -eq 0) { return }

    $targets = @($esuEraLcus | ForEach-Object { $_.Name }) -join ', '
    $message = @"
Se detecto una LCU de la etapa ESU para Windows 10 cliente no LTSC:
$targets

El modulo no suprime comprobaciones de licencia ESU. El paquete de preparacion
puede integrarse, pero no concede por si solo el derecho ESU a una imagen
offline. Despliega la imagen, activa ESU por el metodo autorizado y aplica la
LCU en el sistema en linea, o utiliza un medio LTSC compatible.
"@
    throw $message.Trim()
}


function Mount-AIOUpdateImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$ImagePath,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ReadOnly
    )

    if ($MountPath -in $script:AIOUpdateMountedPaths) {
        throw "El montaje '$MountPath' sigue pendiente; no se vaciara ni reutilizara."
    }
    Initialize-AIOUpdateDirectory -Path $MountPath -Empty
    [void]$script:AIOUpdateMountedPaths.Add($MountPath)
    $arguments = @(
        '/Mount-Image',
        "/ImageFile:$ImagePath",
        "/Index:$Index",
        "/MountDir:$MountPath",
        "/ScratchDir:$ScratchPath"
    )
    if ($ReadOnly) { $arguments += '/ReadOnly' }
    [void](Invoke-AIOUpdateDism -Arguments $arguments -Context $Context)
}

function Dismount-AIOUpdateImage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [ValidateSet('Commit', 'Discard')] [string]$Mode,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$NoThrow
    )

    $action = if ($Mode -eq 'Commit') { '/Commit' } else { '/Discard' }
    $arguments = @('/Unmount-Image', "/MountDir:$MountPath", $action)
    if ($Mode -eq 'Commit') { $arguments += '/CheckIntegrity' }
    $result = Invoke-AIOUpdateDism -Arguments $arguments -Context $Context -NoThrow:$NoThrow

    if ($result.Success) { [void]$script:AIOUpdateMountedPaths.Remove($MountPath) }
    if ($result.Success -and (Test-Path -LiteralPath $MountPath)) {
        Get-ChildItem -LiteralPath $MountPath -Force -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $result
}

function Clear-AIOUpdateMountedImages {
    [CmdletBinding()]
    param()

    foreach ($mountPath in @($script:AIOUpdateMountedPaths | Select-Object -Unique)) {
        try {
            $result = Dismount-AIOUpdateImage -MountPath $mountPath -Mode Discard -Context "Descartar montaje pendiente $mountPath" -NoThrow
            if ($result.Success) { continue }
        }
        catch { Write-AIOUpdateLog -Level WARN -Message "No se pudo desmontar '${mountPath}': $($_.Exception.Message)" }

        # Si /Mount-Image fallo antes de crear el montaje, solo liberar la
        # ruta cuando DISM confirme que ya no figura en su registro.
        try {
            $mounted = @(Get-AIOUpdateNativeMountedImages)
            $pending = @($mounted | Where-Object {
                ([string]$_.Path).TrimEnd('\', '/') -ieq $mountPath.TrimEnd('\', '/')
            })
            if ($pending.Count -eq 0) {
                [void]$script:AIOUpdateMountedPaths.Remove($mountPath)
                continue
            }
        }
        catch { Write-AIOUpdateLog -Level WARN -Message "No se pudo comprobar el estado de '${mountPath}': $($_.Exception.Message)" }
        Write-AIOUpdateLog -Level WARN -Message "Se conserva el montaje pendiente '$mountPath' y su carpeta de trabajo."
    }
    return ($script:AIOUpdateMountedPaths.Count -eq 0)
}

function ConvertFrom-AIOUpdateDismRecords {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]]$Lines, [Parameter(Mandatory = $true)] [string]$StartKey)
    $record = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*([^:]+?)\s*:\s*(.*?)\s*$') {
            $key = $Matches[1].Trim(); $value = $Matches[2]
            if ($key -eq $StartKey) {
                if ($null -ne $record) { [pscustomobject]$record }
                $record = [ordered]@{}
            }
            if ($null -ne $record) { $record[$key] = $value }
        }
    }
    if ($null -ne $record) { [pscustomobject]$record }
}

function Get-AIOUpdateNativeMountedImages {
    [CmdletBinding()]
    param()
    $result = Invoke-AIOUpdateDism -Arguments @('/Get-MountedImageInfo') -Context 'Consultar montajes DISM' -SuccessCodes @(0) -Quiet
    $records = @(ConvertFrom-AIOUpdateDismRecords -Lines $result.Output -StartKey 'Mount Dir')
    if (-not $records.Count -and ($result.Output -join "`n") -notmatch '(?i)No mounted images found') {
        throw 'DISM no confirmo un registro de montajes reconocible; se detiene antes de modificar el medio.'
    }
    foreach ($record in $records) {
        [pscustomobject]@{ Path = $record.'Mount Dir'; MountStatus = $record.Status; ImagePath = $record.'Image File'; ImageIndex = $record.'Image Index' }
    }
}

function Get-AIOUpdateMountedPackageInventory {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MountPath, [switch]$Strict)
    try {
        $result = Invoke-AIOUpdateDism -Arguments @("/Image:$MountPath", '/Get-Packages', '/Format:List') -Context 'Consultar inventario CBS' -SuccessCodes @(0) -Quiet
        $records = @(ConvertFrom-AIOUpdateDismRecords -Lines $result.Output -StartKey 'Package Identity')
        if (-not $records.Count) { throw 'La imagen no devolvio identidades CBS; no se aceptara un inventario vacio.' }
        foreach ($record in $records) {
            if (-not $record.State -or $record.'Package Identity' -notmatch '^[^~]+~[^~]+~[^~]+~[^~]*~\d+\.\d+\.\d+\.\d+$') { throw 'Registro CBS incompleto o no reconocido.' }
            [pscustomobject]@{
                PackageName = [string]$record.'Package Identity'
                PackageState = ([string]$record.State -replace '\s','')
                ReleaseType = ([string]$record.'Release Type' -replace '\s','')
                InstallTime = [string]$record.'Install Time'
            }
        }
    }
    catch {
        $message = "No se pudo obtener inventario de paquetes en '$MountPath': $($_.Exception.Message)"
        Write-AIOUpdateLog -Level WARN -Message $message
        if ($Strict) { throw $message }
        return @()
    }
}

function Initialize-AIOUpdateLcuMsuStaging {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object[]]$Inventory, [Parameter(Mandatory = $true)] [string]$StagingRoot)
    Set-AIOUpdateLcuTargets -Inventory $Inventory
    $script:AIOUpdatePackagePathMap = @{}
    $script:AIOUpdateLcuStageRoot = Join-Path $StagingRoot 'LCU_MSU'
    Initialize-AIOUpdateDirectory -Path $script:AIOUpdateLcuStageRoot -Empty
    $groups = @($Inventory | Where-Object { $_.Category -eq 'LCU' -and $_.Extension -eq '.msu' -and $_.Installable } | Group-Object -Property {
        Get-AIOUpdateLcuFamilyKey -Package $_
    })
    foreach ($group in $groups) {
        $key = (Get-AIOUpdateTextSha256 -Text $group.Name).Substring(0,16)
        $folder = Join-Path $script:AIOUpdateLcuStageRoot $key
        Initialize-AIOUpdateDirectory -Path $folder
        foreach ($package in $group.Group) {
            # Retain the original filename. DISM resolves the chain from the target.
            $path = Join-Path $folder $package.Name
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $package.FullName -Algorithm SHA256).Hash) { throw "MSU diferentes con el mismo nombre: $($package.Name)." }
            }
            else { Copy-Item -LiteralPath $package.FullName -Destination $path -ErrorAction Stop }
            $script:AIOUpdatePackagePathMap[$package.FullName] = $path
        }
        Write-AIOUpdateLog -Level INFO -Message "Cadena MSU aislada por familia/arquitectura/producto: $($group.Name); $($group.Count) archivo(s). DISM determina los requisitos aplicables."
    }
}

function Get-AIOUpdateEffectivePackagePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package
    )

    if ($script:AIOUpdatePackagePathMap -and $script:AIOUpdatePackagePathMap.ContainsKey($Package.FullName)) {
        return [string]$script:AIOUpdatePackagePathMap[$Package.FullName]
    }
    return [string]$Package.FullName
}


function Get-AIOUpdateServicingVersionFromName {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [string]$Text
    )

    $version = Get-AIOUpdateVersionFromText -Text $Text
    if ($version -ne [version]'0.0.0.0') { return $version }

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        $matches = [regex]::Matches($Text, '(?<!\d)(\d{4,9})\.(\d{2,9})(?!\d)')
        if ($matches.Count -gt 0) {
            $match = $matches[$matches.Count - 1]
            try {
                return [version]("10.0.{0}.{1}" -f $match.Groups[1].Value, $match.Groups[2].Value)
            }
            catch {}
        }
    }

    return [version]'0.0.0.0'
}

function Initialize-AIOUpdateEmbeddedSsuStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$StagingRoot
    )

    $script:AIOUpdateEmbeddedSsuPackages = @()
    $lcuPackages = @(
        Get-AIOUpdatePackages -Inventory $Inventory -Category @('LCU') |
            Sort-Object @{ Expression = { [version]$_.Version }; Ascending = $true }, Name
    )
    if ($lcuPackages.Count -eq 0) { return @() }

    $root = Join-Path $StagingRoot 'Embedded_SSU'
    Initialize-AIOUpdateDirectory -Path $root -Empty
    $candidates = New-Object System.Collections.Generic.List[object]
    $knownHashes = @{}
    $packagePosition = 0

    foreach ($package in $lcuPackages) {
        $packagePosition++
        $packageRoot = Join-Path $root ("Source_{0:D2}" -f $packagePosition)
        Initialize-AIOUpdateDirectory -Path $packageRoot -Empty

        $packageIsWim = Test-AIOUpdateWimContainerSignature -Path $package.FullName

        if (-not $packageIsWim) {
            # Contenedor CAB clasico.
            if (Test-Path -LiteralPath $script:AIOUpdateExpandPath -PathType Leaf) {
                foreach ($pattern in $script:AIOUpdateSsuCabPatterns) {
                    & $script:AIOUpdateExpandPath ("-F:$pattern") $package.FullName $packageRoot *> $null
                }

                if (-not @(Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue).Count) {
                    $listing = @(& $script:AIOUpdateExpandPath '-D' $package.FullName 2>$null)
                    foreach ($line in $listing) {
                        $value = ([string]$line).Trim()
                        $match = [regex]::Match($value, '(?i)([^\\/:*?"<>|\r\n]*(?:SSU|Servicing(?:-|_)?Stack)[^\\/:*?"<>|\r\n]*\.cab)')
                        if ($match.Success) {
                            & $script:AIOUpdateExpandPath ("-F:$($match.Groups[1].Value)") $package.FullName $packageRoot *> $null
                        }
                    }
                }
            }
        }
        else {
            # Contenedor WIM moderno: wimgapi primero, DISM /Apply-Image despues.
            [void](
                Expand-AIOUpdateWimContainerEntries `
                    -WimPath $package.FullName `
                    -DestinationRoot $packageRoot `
                    -Pattern $script:AIOUpdateSsuCabPatterns `
                    -ScratchRoot $StagingRoot `
                    -AllowFullApplyFallback
            )
        }

        foreach ($cab in @(
            Get-ChildItem -LiteralPath $packageRoot -Recurse -Filter '*.cab' -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '(?i)(?:^SSU[-_.]|Servicing(?:-|_)?Stack)' }
        )) {
            try { $hash = (Get-FileHash -LiteralPath $cab.FullName -Algorithm SHA256 -ErrorAction Stop).Hash }
            catch { $hash = $cab.FullName.ToLowerInvariant() }
            if ($knownHashes.ContainsKey($hash)) { continue }
            $knownHashes[$hash] = $true

            # El SSU extraido debe tener los mismos datos de seleccion y
            # evidencia que un paquete del repositorio. No heredar identidad,
            # version ni arquitectura de la LCU que lo contiene.
            $metadata = Expand-AIOUpdatePackageMetadata -File $cab -ScratchRoot $StagingRoot
            $roots = @($metadata.CbsRootIdentities | Where-Object { $_ })
            $ssuRoots = @($roots | Where-Object {
                $parts = ([string]$_.Prefix) -split '~'
                $parts.Count -eq 4 -and $parts[0] -match $script:AIOUpdateIdentityPatterns.SSU -and
                    $parts[1] -ieq '31bf3856ad364e35' -and -not $parts[3]
            })
            if ($roots.Count -gt 0 -and $ssuRoots.Count -eq 0) {
                Write-AIOUpdateLog -Level WARN -Message "SSU extraido omitido: $($cab.Name); su identidad CBS propia no corresponde a una pila de mantenimiento."
                continue
            }
            $version = Get-AIOUpdateServicingVersionFromName -Text $cab.Name
            $versionSource = 'Nombre del CAB SSU'
            $architectures = @(Get-AIOUpdatePackageArchitectureHints -File $cab -Metadata $null)
            if ($ssuRoots.Count -gt 0) {
                $version = @($ssuRoots | ForEach-Object {
                    ConvertTo-AIOUpdateServicingVersion -Version ([version]$_.Version)
                } | Sort-Object -Descending | Select-Object -First 1)[0]
                $versionSource = 'Identidad raiz CBS del SSU'
                $architectures = @($ssuRoots | ForEach-Object {
                    Convert-AIOUpdateArchitectureName -Architecture (([string]$_.Prefix -split '~')[2])
                } | Sort-Object -Unique)
            }
            $architectures = @($architectures | Where-Object { $_ -in @($script:AIOUpdateArchitectureCatalog.Name) })
            if ($architectures.Count -eq 0 -or $version -eq [version]'0.0.0.0') {
                Write-AIOUpdateLog -Level WARN -Message "SSU extraido omitido: $($cab.Name); no se pudo acreditar su arquitectura o version. Se conserva la alternativa LCU."
                continue
            }
            $identityHints = @($ssuRoots | ForEach-Object { "$($_.Prefix)~$($_.Version)" })
            $safeSource = ([System.IO.Path]::GetFileNameWithoutExtension($package.Name) -replace '[^A-Za-z0-9_.-]', '_')
            $destination = Join-Path $root ("{0}_{1}" -f $safeSource, $cab.Name)
            Copy-Item -LiteralPath $cab.FullName -Destination $destination -Force -ErrorAction Stop
            $file = Get-Item -LiteralPath $destination -ErrorAction Stop

            [void]$candidates.Add([pscustomobject]@{
                File          = $file
                FullName      = $file.FullName
                Name          = $file.Name
                Extension     = '.cab'
                Category      = 'SSU'
                Reason        = "SSU integrado extraido de $($package.Name)"
                Version       = $version
                VersionBuild  = [int]$version.Build
                VersionReliable = $true
                VersionSource = $versionSource
                KB            = $null
                Size          = [long]$file.Length
                IsCheckpoint  = $false
                Auxiliary     = $false
                Installable   = $true
                Metadata      = $metadata
                Architectures = [string[]]$architectures
                Editions      = [string[]]@()
                ExplicitEditions = [string[]]@()
                ProductHint   = 'Any'
                IdentityHints = [string[]]$identityHints
                Embedded      = $true
                SourcePackage = $package.Name
            })
        }
    }

    $script:AIOUpdateEmbeddedSsuPackages = [object[]]($candidates.ToArray())
    if ($script:AIOUpdateEmbeddedSsuPackages.Count -gt 0) {
        Write-AIOUpdateLog -Level INFO -Message "Se extrajeron $($script:AIOUpdateEmbeddedSsuPackages.Count) SSU integrado(s) desde las LCU."
    }
    else {
        Write-AIOUpdateLog -Level INFO -Message 'Las LCU no exponen un CAB SSU independiente extraible; se usaran SSU independientes si existen. Esto no impide procesar SafeOS/LCU.'
    }

    return [object[]]($script:AIOUpdateEmbeddedSsuPackages)
}

function Get-AIOUpdateEffectiveSsuPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [string]$Architecture,
        [int]$Build = 0,
        [string]$ImageName = 'WinPE'
    )

    $all = New-Object System.Collections.Generic.List[object]
    foreach ($package in @(Get-AIOUpdatePackages -Inventory $Inventory -Category @('SSU'))) {
        [void]$all.Add($package)
    }
    foreach ($package in @($script:AIOUpdateEmbeddedSsuPackages)) {
        [void]$all.Add($package)
    }
    $eligible = @(
        foreach ($package in $all) {
            if ($null -eq $package) { continue }
            if ($Architecture) {
                $test = Test-AIOUpdatePackageCompatibility -Package $package -Architecture $Architecture -Build $Build -ImageName $ImageName
                if (-not $test.Compatible) {
                    Write-AIOUpdateLog -Level INFO -Message "SSU omitido para ${ImageName}: $($package.Name); $($test.Reason)."
                    continue
                }
            }
            $package
        }
    )
    if ($eligible.Count -eq 0) { return @() }

    # Mantener la revision mas reciente de CADA base CBS/arquitectura.
    # Una build ajena mas alta no debe ocultar el SSU correcto del repositorio.
    # La aplicabilidad final sigue siendo decision de CBS en el montaje.
    $selected = @(
        $eligible | Group-Object -Property {
            $version = ConvertTo-AIOUpdateServicingVersion -Version ([version]$_.Version)
            $arches = @($_.Architectures | Sort-Object -Unique) -join ','
            if ($version.Build -gt 0) { "$arches|$($version.Build)" } else { "$arches|$($_.FullName)|$($_.Name)" }
        } | ForEach-Object {
            $_.Group | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true },
                                  @{ Expression = { if ($_.Embedded) { 1 } else { 0 } }; Descending = $true }, Name | Select-Object -First 1
        } | Sort-Object Version, Name
    )
    foreach ($candidate in $selected) {
        Write-AIOUpdateLog -Level INFO -Message "SSU candidato para WinRE/WinPE: $($candidate.Name); la aplicabilidad se verifica en la imagen."
    }
    return [object[]]$selected
}



function Normalize-AIOUpdateCbsIdentityName {
    [CmdletBinding()]
    param([AllowNull()] [string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return $Name.Trim().ToLowerInvariant()
}

function Get-AIOUpdatePackageOrderRank {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $category = [string]$Package.Category
    if ($category -eq 'LCU' -and $Package.IsCheckpoint) { return [int]$script:AIOUpdatePackageOrderRanks.LCUCheckpoint }
    if ($script:AIOUpdatePackageOrderRanks.Contains($category)) {
        return [int]$script:AIOUpdatePackageOrderRanks[$category]
    }
    return [int]$script:AIOUpdatePackageOrderRanks.Default
}

function Resolve-AIOUpdateCbsPackageOrder {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $nodes = @(
        $Packages |
            Where-Object { $null -ne $_ } |
            Group-Object { ([string]$_.FullName).ToLowerInvariant() } |
            ForEach-Object { $_.Group[0] }
    )
    if ($nodes.Count -eq 0) { return @() }

    $nodeById = @{}
    $identityMap = @{}
    $incoming = @{}
    $outgoing = @{}
    $matchedDependencies = @{}
    $orderingConstraints = @{}

    foreach ($package in $nodes) {
        $id = ([string]$package.FullName).ToLowerInvariant()
        $nodeById[$id] = $package
        $incoming[$id] = New-Object System.Collections.Generic.HashSet[string]
        $outgoing[$id] = New-Object System.Collections.Generic.HashSet[string]
        $matchedDependencies[$id] = New-Object System.Collections.Generic.List[string]
        $orderingConstraints[$id] = New-Object System.Collections.Generic.List[string]

        # Una dependencia solo puede ser satisfecha por una identidad PROPIA
        # de otro paquete del conjunto. IdentityHints puede incluir ediciones o
        # prerrequisitos externos y no debe convertirse en proveedor CBS.
        $identities = @(
            if ($package.Metadata) { $package.Metadata.CbsOwnIdentities }
            if (-not [string]::IsNullOrWhiteSpace([string]$package.KB)) { [string]$package.KB }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

        foreach ($identity in $identities) {
            $key = Normalize-AIOUpdateCbsIdentityName -Name ([string]$identity)
            if (-not $key) { continue }
            if (-not $identityMap.ContainsKey($key)) {
                $identityMap[$key] = New-Object System.Collections.Generic.List[string]
            }
            if (-not $identityMap[$key].Contains($id)) {
                [void]$identityMap[$key].Add($id)
            }
        }
    }

    foreach ($package in $nodes) {
        $targetId = ([string]$package.FullName).ToLowerInvariant()
        $dependencies = @(
            if ($package.Metadata) { $package.Metadata.CbsDependencies }
            if ($package.Metadata) { $package.Metadata.CbsParents }
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique

        foreach ($dependency in $dependencies) {
            $key = Normalize-AIOUpdateCbsIdentityName -Name ([string]$dependency)
            if (-not $key -or -not $identityMap.ContainsKey($key)) { continue }

            $providers = @(
                $identityMap[$key] |
                    Where-Object { $_ -ne $targetId } |
                    ForEach-Object { $nodeById[$_] } |
                    Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, Name
            )
            if ($providers.Count -eq 0) { continue }

            $provider = $providers[0]
            $providerId = ([string]$provider.FullName).ToLowerInvariant()
            if ($incoming[$targetId].Add($providerId)) {
                [void]$outgoing[$providerId].Add($targetId)
                [void]$matchedDependencies[$targetId].Add([string]$dependency)
            }
        }
    }

    # En install.wim un paquete Enablement debe quedar después de la cadena
    # LCU que aporta su nivel CBS requerido. Es una política segura explícita,
    # no una dependencia inventada a partir de ediciones compartidas.
    if ($Context -match '(?i)^install\.wim\s+indice\s+\d+$') {
        $lcuNodes = @($nodes | Where-Object { $_.Category -eq 'LCU' })
        $enablementNodes = @($nodes | Where-Object { $_.Category -eq 'Enablement' })
        foreach ($enablement in $enablementNodes) {
            $targetId = ([string]$enablement.FullName).ToLowerInvariant()
            foreach ($lcu in $lcuNodes) {
                $providerId = ([string]$lcu.FullName).ToLowerInvariant()
                if ($providerId -eq $targetId) { continue }
                if ($incoming[$targetId].Add($providerId)) {
                    [void]$outgoing[$providerId].Add($targetId)
                }
            }
            if ($lcuNodes.Count -gt 0) {
                [void]$orderingConstraints[$targetId].Add('Politica segura: cadena LCU antes de Enablement')
            }
        }
    }

    $available = New-Object System.Collections.Generic.List[object]
    foreach ($id in $nodeById.Keys) {
        if ($incoming[$id].Count -eq 0) { [void]$available.Add($nodeById[$id]) }
    }

    $ordered = New-Object System.Collections.Generic.List[object]
    while ($available.Count -gt 0) {
        $next = @(
            $available |
                Sort-Object `
                    @{ Expression = { Get-AIOUpdatePackageOrderRank -Package $_ }; Ascending = $true },
                    @{ Expression = { [version]$_.Version }; Ascending = $true },
                    @{ Expression = { [string]$_.Name }; Ascending = $true } |
                Select-Object -First 1
        )[0]
        [void]$available.Remove($next)
        [void]$ordered.Add($next)

        $nextId = ([string]$next.FullName).ToLowerInvariant()
        foreach ($dependentId in @($outgoing[$nextId])) {
            [void]$incoming[$dependentId].Remove($nextId)
            if ($incoming[$dependentId].Count -eq 0) {
                [void]$available.Add($nodeById[$dependentId])
            }
        }
    }

    $hadAmbiguity = ($ordered.Count -lt $nodes.Count)
    if ($hadAmbiguity) {
        $orderedIds = @{}
        foreach ($package in $ordered) { $orderedIds[([string]$package.FullName).ToLowerInvariant()] = $true }
        $remaining = @(
            $nodes |
                Where-Object { -not $orderedIds.ContainsKey(([string]$_.FullName).ToLowerInvariant()) } |
                Sort-Object `
                    @{ Expression = { Get-AIOUpdatePackageOrderRank -Package $_ }; Ascending = $true },
                    @{ Expression = { [version]$_.Version }; Ascending = $true },
                    Name
        )
        foreach ($package in $remaining) { [void]$ordered.Add($package) }
        Write-AIOUpdateLog -Level WARN -Message "Orden CBS '$Context': existe un ciclo real entre identidades propias; se completo usando el orden seguro por categoria."
    }

    $planEntries = New-Object System.Collections.Generic.List[object]
    $position = 0
    foreach ($package in $ordered) {
        $position++
        $id = ([string]$package.FullName).ToLowerInvariant()
        [void]$planEntries.Add([pscustomobject]@{
            Position             = $position
            PlannedPosition      = $position
            ExecutedPosition     = $null
            ExecutionState       = 'Pending'
            ExitCode             = $null
            FullName             = [string]$package.FullName
            Category             = [string]$package.Category
            Name                 = [string]$package.Name
            Version              = [string]$package.Version
            IsCheckpoint         = [bool]$package.IsCheckpoint
            MatchedDependencies  = [string[]]@($matchedDependencies[$id].ToArray() | Sort-Object -Unique)
            OrderingConstraints  = [string[]]@($orderingConstraints[$id].ToArray() | Sort-Object -Unique)
            MetadataDependencies = [string[]]@(
                if ($package.Metadata) { $package.Metadata.CbsDependencies }
                if ($package.Metadata) { $package.Metadata.CbsParents }
            )
        })
    }

    $plan = [pscustomobject]@{
        Context      = $Context
        Resolution   = if ($hadAmbiguity) { 'SafeCategoryFallback' } else { 'ExactIdentityGraph' }
        HadAmbiguity = $hadAmbiguity
        Packages     = [object[]]($planEntries.ToArray())
    }
    [void]$script:AIOUpdateDependencyPlans.Add($plan)

    $summary = @($ordered | ForEach-Object { "$($_.Category):$($_.Name)" }) -join ' -> '
    Write-AIOUpdateLog -Level INFO -Message "Orden CBS planeado para '$Context': $summary"
    Write-Host "   Orden CBS planeado: $(@($ordered | ForEach-Object { $_.Category }) -join ' -> ')" -ForegroundColor DarkGray

    return [object[]]($ordered.ToArray())
}

function Update-AIOUpdateDependencyPlanExecution {
    [CmdletBinding()]
    param(
        [AllowNull()] [string]$Context,
        [Parameter(Mandatory = $true)] [object]$Package,
        [Parameter(Mandatory = $true)] [object]$Result
    )

    if ([string]::IsNullOrWhiteSpace($Context)) { return }
    $plans = @($script:AIOUpdateDependencyPlans | Where-Object { [string]$_.Context -eq $Context })
    if ($plans.Count -eq 0) { return }
    $plan = $plans[-1]
    $fullName = [string]$Package.FullName
    $entry = @($plan.Packages | Where-Object { [string]$_.FullName -eq $fullName } | Select-Object -First 1)
    if ($entry.Count -eq 0) { return }

    $state = [string]$Result.State
    $executionState = if ($state -in @('AlreadyPresent', 'CheckpointSatisfied')) {
        'AlreadyPresent'
    }
    elseif ($state -eq 'Reapplied') {
        'Reapplied'
    }
    elseif ($state -eq 'ReapplyNotApplicable') {
        'ReapplyNotApplicable'
    }
    elseif ($state -eq 'NotApplicable') {
        'NotApplicable'
    }
    elseif ($state -eq 'SkippedCheckpointUnavailable') {
        'Skipped'
    }
    elseif ($Result.Success) {
        'Applied'
    }
    else {
        'Failed'
    }

    $entry[0].ExecutionState = $executionState
    if ($Result.PSObject.Properties['ExitCode']) {
        $entry[0].ExitCode = [int]$Result.ExitCode
    }

    if ($executionState -ne 'AlreadyPresent') {
        if (-not $script:AIOUpdateExecutionPositionByContext.ContainsKey($Context)) {
            $script:AIOUpdateExecutionPositionByContext[$Context] = 0
        }
        $script:AIOUpdateExecutionPositionByContext[$Context]++
        $entry[0].ExecutedPosition = [int]$script:AIOUpdateExecutionPositionByContext[$Context]
    }
}

function Get-AIOUpdatePackageDisplayIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Package
    )

    $metadata = $Package.Metadata
    # Preferir la identidad propia ya analizada: no depende de que el texto
    # completo de update.mum siga disponible o haya sido truncado.
    $category = [string]$Package.Category
    if ($metadata -and $metadata.PSObject.Properties['CbsRootIdentities'] -and $script:AIOUpdateIdentityPatterns.Contains($category)) {
        $root = @($metadata.CbsRootIdentities | Where-Object {
            $parts = ([string]$_.Prefix) -split '~'
            $parts.Count -eq 4 -and $parts[0] -match $script:AIOUpdateIdentityPatterns[$category] -and
                $parts[1] -ieq '31bf3856ad364e35' -and -not $parts[3]
        } | Sort-Object @{ Expression = { [version]$_.Version }; Descending = $true }, Prefix | Select-Object -First 1)
        if ($root.Count -gt 0) { return ("$($root[0].Prefix)~$($root[0].Version)") }
    }
    $updateMumText = if ($metadata) { [string]$metadata.UpdateMumText } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($updateMumText)) {
        $category = [string]$Package.Category
        if ($script:AIOUpdateDisplayIdentityNames.ContainsKey($category)) {
            $preferredNames = @($script:AIOUpdateDisplayIdentityNames[$category])
        }
        else {
            $preferredNames = $script:AIOUpdateDisplayIdentityNamesDefault
        }

        $tags = @([regex]::Matches($updateMumText, '(?is)<assemblyIdentity\b[^>]*>'))
        foreach ($preferredName in $preferredNames) {
            foreach ($tagMatch in $tags) {
                $tag = [string]$tagMatch.Value
                $nameMatch = [regex]::Match($tag, '(?i)\bname\s*=\s*"([^"]+)"')
                if (-not $nameMatch.Success -or $nameMatch.Groups[1].Value -ine $preferredName) { continue }

                $name = $nameMatch.Groups[1].Value
                $versionMatch = [regex]::Match($tag, '(?i)\bversion\s*=\s*"([^"]+)"')
                $tokenMatch = [regex]::Match($tag, '(?i)\bpublicKeyToken\s*=\s*"([^"]+)"')
                $archMatch = [regex]::Match($tag, '(?i)\bprocessorArchitecture\s*=\s*"([^"]+)"')
                $languageMatch = [regex]::Match($tag, '(?i)\blanguage\s*=\s*"([^"]+)"')

                $version = if ($versionMatch.Success) { $versionMatch.Groups[1].Value } else { '' }
                $token = if ($tokenMatch.Success) { $tokenMatch.Groups[1].Value } else { '' }
                $arch = if ($archMatch.Success) { $archMatch.Groups[1].Value } else { '' }
                $language = if ($languageMatch.Success) { $languageMatch.Groups[1].Value } else { '' }
                if ($language -match '^(?i:neutral|none)$') { $language = '' }

                if ($token -and $arch -and $version) {
                    return ('{0}~{1}~{2}~{3}~{4}' -f $name, $token, $arch, $language, $version)
                }
                if ($version) { return ("$name [$version]") }
                return $name
            }
        }
    }

    $kb = [string]$Package.KB
    $version = [string]$Package.Version
    if ($kb -and $version -and $version -ne '0.0.0.0') {
        return ("$($Package.Category) $kb [$version]")
    }
    if ($kb) { return ("$($Package.Category) $kb") }
    return [string]$Package.Name
}


function Add-AIOUpdatePackageList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$AllowNotApplicable,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$InstalledInventory,
        [AllowNull()] [string]$DependencyContext
    )

    $Packages = @(Get-AIOUpdateUniquePackages -Packages $Packages)
    $results = New-Object System.Collections.Generic.List[object]
    if (@($Packages).Count -eq 0) {
        Write-Host "   [OMITIDO] ${Context}: no hay paquetes." -ForegroundColor DarkGray
        return @()
    }

    $position = 0
    foreach ($package in $Packages) {
        $position++
        Write-Host ("`n   [{0}/{1}] {2}" -f $position, $Packages.Count, $package.Name) -ForegroundColor Yellow

        $alreadyPresent = Test-AIOUpdatePackageInstalled -Package $package -InstalledInventory $InstalledInventory
        $reapplyAttempt = $alreadyPresent

        if ($reapplyAttempt) {
            Write-Host '      [REAPLICAR] El paquete ya esta presente; se enviara nuevamente a DISM sin desinstalarlo.' -ForegroundColor Yellow
            Write-AIOUpdateLog -Level WARN -Message "$Context - $($package.Name): reaplicacion automatica para un paquete Installed/InstallPending/Superseded."
        }

        $effectivePath = Get-AIOUpdateEffectivePackagePath -Package $package
        $effectiveContext = "$Context - $($package.Name)"
        if ($effectivePath -ne $package.FullName) {
            $mode = 'objetivo de cadena LCU MSU'
            Write-Host "      Staging: $mode" -ForegroundColor DarkGray
            $effectiveContext = "$effectiveContext [$mode]"
        }

        if ($reapplyAttempt) {
            $effectiveContext = "$effectiveContext [reaplicacion automatica]"
        }

        $displayIdentity = if ($package.Extension -eq '.msu') { Get-AIOUpdatePackageDisplayIdentity -Package $package } else { $null }
        try {
            $result = Invoke-AIOUpdateDism -Arguments @(
                "/Image:$MountPath",
                '/Add-Package',
                "/PackagePath:$effectivePath",
                "/ScratchDir:$ScratchPath"
            ) -Context $effectiveContext -AllowNotApplicable:($AllowNotApplicable -or $reapplyAttempt) -NoThrow -DisplayIdentity $displayIdentity
        }
        catch {
            $failedResult = [pscustomobject]@{
                Success      = $false
                State        = 'Failed'
                ExitCode     = -1
                UnsignedCode = [uint32]4294967295
                Context      = $effectiveContext
            }
            Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $failedResult
            throw
        }

        if (-not $result.Success) {
            Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $result
            $hexCode = '0x{0:X8}' -f $result.UnsignedCode
            if ($result.PSObject.Properties['ErrorMessage'] -and $result.ErrorMessage) { throw $result.ErrorMessage }
            $description = Get-AIOUpdateExitCodeText -ExitCode $result.ExitCode
            throw "$effectiveContext fallo. Codigo DISM: $($result.ExitCode) ($hexCode). $description"
        }

        # Una LCU no puede darse por integrada solo por un codigo 0 o por
        # NotApplicable. Esta comprobacion minima rige incluso al desactivar
        # los informes completos Pre/Post-Commit.
        if ($package.Category -eq 'LCU') {
            $afterLcu = @(Get-AIOUpdateMountedPackageInventory -MountPath $MountPath -Strict)
            Update-AIOUpdateServicingBuildRelationsFromInventory -Inventory $afterLcu
            $lcuEvidence = Get-AIOUpdatePackageCbsEvidence -Package $package -Inventory $afterLcu
            if (-not $lcuEvidence.Success) {
                $result.Success = $false
                $result.State = 'MissingCbsEvidence'
                Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $result
                throw "$effectiveContext no quedo verificado en CBS: $($lcuEvidence.Reason). Codigo DISM: $($result.ExitCode)."
            }
            $result | Add-Member -NotePropertyName CbsEvidence -NotePropertyValue $lcuEvidence -Force
        }

        if ($reapplyAttempt) {
            $dismState = [string]$result.State
            $result | Add-Member -NotePropertyName DismState -NotePropertyValue $dismState -Force
            $result | Add-Member -NotePropertyName ReapplyAutomatic -NotePropertyValue $true -Force
            $result.State = if ($dismState -eq 'NotApplicable') { 'ReapplyNotApplicable' } else { 'Reapplied' }

            if ($result.State -eq 'ReapplyNotApplicable') {
                Write-Host '      [SIN CAMBIOS] CBS determino que la reaplicacion no era necesaria o aplicable.' -ForegroundColor DarkYellow
            }
            else {
                Write-Host '      [REAPLICADO] DISM acepto nuevamente el paquete.' -ForegroundColor Green
            }
        }

        Update-AIOUpdateDependencyPlanExecution -Context $DependencyContext -Package $package -Result $result
        [void]$results.Add([pscustomobject]@{ Package = $package; Result = $result })
    }

    return [object[]]($results.ToArray())
}

function Get-AIOUpdatePendingServicingState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MountPath)
    try {
        if (Test-Path -LiteralPath (Join-Path $MountPath 'Windows\WinSxS\pending.xml') -PathType Leaf -ErrorAction Stop) {
            return [pscustomobject]@{ Known = $true; Pending = $true; Reason = 'pending.xml presente; la limpieza requiere completar las operaciones pendientes.' }
        }
        $packages = @(Get-AIOUpdateMountedPackageInventory -MountPath $MountPath -Strict)
        $pending = @($packages | Where-Object { ([string]$_.PackageState -replace '\s', '') -in @('InstallPending', 'UninstallPending', 'PartiallyInstalled') })
        return [pscustomobject]@{ Known = $true; Pending = ($pending.Count -gt 0); Reason = $(if ($pending.Count) { 'CBS tiene paquetes pendientes: ' + (($pending | ForEach-Object { $_.PackageName }) -join ', ') } else { 'Sin operaciones CBS pendientes.' }) }
    }
    catch {
        return [pscustomobject]@{ Known = $false; Pending = $false; Reason = "No se pudo comprobar el estado CBS: $($_.Exception.Message)" }
    }
}

function Add-AIOUpdateMaintenanceRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Context,
        [Parameter(Mandatory = $true)] [string]$State,
        [Parameter(Mandatory = $true)] [string]$Reason,
        [bool]$Performed = $false
    )
    if ($null -eq $script:AIOUpdateMaintenanceResults) { $script:AIOUpdateMaintenanceResults = New-Object System.Collections.ArrayList }
    [void]$script:AIOUpdateMaintenanceResults.Add([pscustomobject]@{
        Context = $Context; State = $State; Performed = $Performed; Reason = $Reason
    })
    Write-AIOUpdateLog -Level INFO -Message "${Context}: $State; $Reason"
}

function Invoke-AIOUpdateCleanup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Context,
        [switch]$ResetBase,
        [switch]$WarningOnly
    )

    $state = Get-AIOUpdatePendingServicingState -MountPath $MountPath
    if (-not $state.Known -or $state.Pending) {
        $status = if ($state.Pending) { 'SkippedPendingActions' } else { 'SkippedUnknownServicingState' }
        Write-Host "   [APLAZADO] ${Context}: $($state.Reason)" -ForegroundColor Yellow
        Add-AIOUpdateMaintenanceRecord -Context $Context -State $status -Reason $state.Reason
        return [pscustomobject]@{ Success = $true; State = $status; Performed = $false; ExitCode = $null; Context = $Context; Reason = $state.Reason }
    }
    $arguments = @("/Image:$MountPath", '/Cleanup-Image', '/StartComponentCleanup', "/ScratchDir:$ScratchPath")
    if ($ResetBase) { $arguments += '/ResetBase' }
    $result = Invoke-AIOUpdateDism -Arguments $arguments -Context $Context -NoThrow
    Add-AIOUpdateMaintenanceRecord -Context $Context -State $result.State -Performed ([bool]$result.Success) -Reason "DISM: $($result.ExitCode); ResetBase=$([bool]$ResetBase)."
    if (-not $result.Success) {
        $code = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $result.ExitCode
        if ($code -eq [uint32]2148468742) { # 0x800F0806 CBS_E_PENDING
            Add-AIOUpdateMaintenanceRecord -Context $Context -State 'SkippedPendingActions' -Reason 'DISM confirmo operaciones pendientes; limpieza aplazada.'
            return [pscustomobject]@{ Success = $true; State = 'SkippedPendingActions'; Performed = $false; ExitCode = $result.ExitCode; Context = $Context }
        }
        throw "$Context fallo con codigo $($result.ExitCode). No se guardara una imagen tras un fallo de limpieza no previsto."
    }
    return $result
}

function Update-AIOUpdateServicingBuildRelationsFromInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Inventory
    )

    foreach ($item in @($Inventory | Where-Object { $_.PackageState -match '(?i)Installed|Install ?Pending|Superseded' })) {
        $name = [string]$item.PackageName
        if ($name -notmatch '(?i)Enablement[-_ ]+Package') { continue }
        $parsed = ConvertTo-AIOUpdateServicingVersion -Version (Get-AIOUpdateVersionFromText -Text $name)
        $baseBuild = [int]$parsed.Build
        if ($baseBuild -lt [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) { continue }

        foreach ($match in [regex]::Matches($name, '(?i)(?<!\d)(\d{4,9})(?!\d)(?=[^~\r\n]{0,80}(?:Version[-_ ]+)?Enablement[-_ ]+Package)')) {
            $targetBuild = [int]$match.Groups[1].Value
            if ($targetBuild -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) {
                Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second $targetBuild
            }
        }
        foreach ($match in [regex]::Matches($name, '(?i)SV2Moment(\d+)Enablement[-_ ]+Package')) {
            $offset = [int]$match.Groups[1].Value
            if ($offset -gt 0 -and $offset -lt 100) {
                Add-AIOUpdateServicingBuildRelation -First $baseBuild -Second ($baseBuild + $offset)
            }
        }
    }
}

function ConvertTo-AIOUpdateServicingVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [version]$Version
    )

    if ($Version.Major -in @(6, 10) -and $Version.Build -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) {
        return [version]("10.0.{0}.{1}" -f $Version.Build, [math]::Max(0, $Version.Revision))
    }
    if ($Version.Major -ge [int]$script:AIOUpdatePolicy.MinimumRecognizedCbsBuild) {
        return [version]("10.0.{0}.{1}" -f $Version.Major, [math]::Max(0, $Version.Minor))
    }
    return [version]'0.0.0.0'
}

function Get-AIOUpdateObservedServicingVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Inventory,
        [string[]]$Patterns = @($script:AIOUpdateIdentityPatterns.LCU, $script:AIOUpdateIdentityPatterns.SafeOS)
    )

    $versions = New-Object System.Collections.Generic.List[System.Version]
    foreach ($item in @($Inventory | Where-Object { $_.PackageState -match '(?i)Installed|Install ?Pending|Superseded' })) {
        $name = [string]$item.PackageName
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if (@($Patterns | Where-Object { $name -match $_ }).Count -eq 0) { continue }
        $parsed = ConvertTo-AIOUpdateServicingVersion -Version (Get-AIOUpdateVersionFromText -Text $name)
        if ($parsed -ne [version]'0.0.0.0') { [void]$versions.Add($parsed) }
    }
    if ($versions.Count -eq 0) { return [version]'0.0.0.0' }
    return [version]($versions.ToArray() | Sort-Object -Descending | Select-Object -First 1)
}

function Test-AIOUpdateServicingVersionAtLeast {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [version]$Actual,
        [Parameter(Mandatory = $true)] [version]$Expected
    )

    $actualNormalized = ConvertTo-AIOUpdateServicingVersion -Version $Actual
    $expectedNormalized = ConvertTo-AIOUpdateServicingVersion -Version $Expected
    if ($expectedNormalized -eq [version]'0.0.0.0') { return $true }
    if ($actualNormalized -eq [version]'0.0.0.0') { return $false }

    $actualFamily = Get-AIOUpdateServicingBuildFamily -Build $actualNormalized.Build
    $expectedFamily = Get-AIOUpdateServicingBuildFamily -Build $expectedNormalized.Build
    if ($actualFamily -eq $expectedFamily) {
        return ($actualNormalized.Revision -ge $expectedNormalized.Revision)
    }

    # No se adivinan relaciones entre builds mediante una distancia numerica.
    # Si son familias diferentes debe existir una relacion de Enablement leida
    # de los propios paquetes; de lo contrario la verificacion es conservadora.
    return $false
}

function Get-AIOUpdatePackageCbsEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object]$Package,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Inventory
    )

    $expected = $null
    [void][version]::TryParse([string]$Package.Version, [ref]$expected)
    $knownVersion = ($null -ne $expected -and $expected -ne [version]'0.0.0.0')
    if ($Package.PSObject.Properties['VersionReliable'] -and -not $Package.VersionReliable) { $knownVersion = $false }
    $servicingCategory = ([string]$Package.Category -in @('LCU', 'SSU', 'SafeOS'))
    if ($servicingCategory -and $knownVersion -and (ConvertTo-AIOUpdateServicingVersion -Version $expected) -eq [version]'0.0.0.0') { $knownVersion = $false }
    $pattern = if ($script:AIOUpdateSemanticFamilyPatterns.Contains([string]$Package.Category)) { [string]$script:AIOUpdateSemanticFamilyPatterns[[string]$Package.Category] } else { $null }
    $ownNames = @()
    if ($Package.Metadata) { $ownNames = @($Package.Metadata.CbsOwnIdentities | Where-Object { $_ }) }
    $hints = @($Package.IdentityHints | Where-Object { $_ })
    $manifestIdentities = @()
    if ($Package.Metadata -and $Package.Metadata.PSObject.Properties['CbsRootIdentities']) {
        $manifestIdentities = @($Package.Metadata.CbsRootIdentities | Where-Object { $_ })
    }
    elseif ($Package.Metadata -and $Package.Metadata.UpdateMumText) {
        # Compatibilidad con inventarios anteriores: cada declaracion XML
        # delimita su documento. Leer solo su identidad propia, sin intentar
        # cerrar/reparar cuerpos truncados ni confundir padres con paquetes.
        foreach ($fragment in [regex]::Split([string]$Package.Metadata.UpdateMumText, '(?i)(?=<\?xml\s)')) {
            if ([string]::IsNullOrWhiteSpace($fragment)) { continue }
            try {
                $rootIdentity = Get-AIOUpdateCbsRootIdentity -XmlText $fragment
                if ($rootIdentity) { $manifestIdentities += $rootIdentity }
            }
            catch { Write-AIOUpdateLog -Level WARN -Message "No se pudo leer la cabecera CBS de $($Package.Name): $($_.Exception.Message)" }
        }
    }
    $architectures = @($Package.Architectures | Where-Object { $_ } | ForEach-Object { Convert-AIOUpdateArchitectureName -Architecture $_ } | Where-Object { $_ -ne 'Unknown' })
    foreach ($hint in $hints) {
        $parts = ([string]$hint) -split '~'
        if ($parts.Count -eq 5) { $architectures += Convert-AIOUpdateArchitectureName -Architecture $parts[2] }
    }
    $architectures = @($architectures | Where-Object { $_ -ne 'Unknown' } | Sort-Object -Unique)

    foreach ($entry in @($Inventory)) {
        $state = ([string]$entry.PackageState -replace '\s', '')
        if ($state -notin @('Installed', 'InstallPending', 'Superseded')) { continue }
        $name = [string]$entry.PackageName
        $parts = $name -split '~'
        if ($parts.Count -ne 5) { continue }
        $actual = $null
        if (-not [version]::TryParse($parts[4], [ref]$actual)) { continue }
        $arch = Convert-AIOUpdateArchitectureName -Architecture $parts[2]
        if ($architectures.Count -gt 0 -and $arch -notin $architectures -and $parts[2] -ine 'neutral') { continue }
        $entryExpected = $expected
        $entryKnownVersion = $knownVersion
        $manifestMatch = @($manifestIdentities | Where-Object { $_.Prefix -ieq ($parts[0..3] -join '~') } | Sort-Object Version -Descending | Select-Object -First 1)
        if ($manifestMatch.Count -gt 0) {
            $entryExpected = [version]$manifestMatch[0].Version
            $entryKnownVersion = ($entryExpected -ne [version]'0.0.0.0')
        }

        # Nunca usar un prerrequisito auxiliar como prueba de la LCU/SSU pedida.
        if ($servicingCategory -and ($parts[0] -notmatch $pattern -or $parts[3] -or $parts[1] -ine '31bf3856ad364e35')) { continue }
        $kbMatch = ($Package.KB -and $parts[0] -match ('(?i)(?<![a-z0-9])' + [regex]::Escape([string]$Package.KB) + '(?!\d)'))
        $ownMatch = ($parts[0] -in $ownNames -and (-not $pattern -or $parts[0] -match $pattern))
        if ($manifestIdentities.Count -gt 0) { $ownMatch = ($manifestMatch.Count -gt 0) }
        $exactHint = $false
        foreach ($hint in $hints) {
            $hintParts = ([string]$hint) -split '~'
            if ($hintParts.Count -eq 5 -and ($hintParts[0..3] -join '~') -ieq ($parts[0..3] -join '~')) {
                if ($ownNames.Count -eq 0 -or $parts[0] -in $ownNames) { $exactHint = $true; break }
            }
        }
        # LCU, SSU y SafeOS permiten sustitucion dentro de su propia familia
        # de mantenimiento, con version y arquitectura conocidas. No equivale
        # a cualquier componente WinPE, .NET o SecureBoot de la imagen.
        $cumulativeFamily = ($servicingCategory -and $knownVersion -and $architectures.Count -gt 0 -and $parts[0] -match $pattern)
        if (-not ($kbMatch -or $ownMatch -or $exactHint -or $cumulativeFamily)) { continue }
        if (-not $entryKnownVersion) {
            if (-not $kbMatch -and $name -notin $hints) { continue }
            if ($state -eq 'Superseded') { continue }
        }
        else {
            if ($servicingCategory) {
                if ((ConvertTo-AIOUpdateServicingVersion -Version $entryExpected) -eq [version]'0.0.0.0') { continue }
                if (-not (Test-AIOUpdateServicingVersionAtLeast -Actual $actual -Expected $entryExpected)) { continue }
                $equalVersion = ((ConvertTo-AIOUpdateServicingVersion -Version $actual) -eq (ConvertTo-AIOUpdateServicingVersion -Version $entryExpected))
            }
            else {
                if ($actual.Major -ne $entryExpected.Major -or $actual.Minor -ne $entryExpected.Minor -or $actual.Build -ne $entryExpected.Build -or $actual -lt $entryExpected) { continue }
                $equalVersion = ($actual -eq $entryExpected)
            }
            # Un paquete retirado no prueba que exista una version activa que
            # lo sustituya. Buscar siempre esa version en el inventario actual.
            if ($state -eq 'Superseded') { continue }
        }
        $status = if ($entryKnownVersion -and -not $equalVersion) { 'SupersededByInstalled' } else { 'IdentityAndVersion' }
        return [pscustomobject]@{
            Success = $true; Status = $status; Identity = $name; PackageState = $state
            Reason = "CBS $state confirma $name (version solicitada: $entryExpected)"
        }
    }
    return [pscustomobject]@{
        Success = $false; Status = 'Missing'; Identity = $null; PackageState = $null
        Reason = "No hay identidad activa de la version solicitada $($Package.Version) ni sustitucion compatible demostrada para $($Package.Name)"
    }
}

function Get-AIOUpdateSemanticPackageEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [psobject]$Operation,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$AfterInventory
    )

    $package = $Operation.Package
    $result = $Operation.Result
    $name = if ($package -and $package.Name) { [string]$package.Name } else { [string]$result.Context }
    $category = if ($package -and $package.Category) { [string]$package.Category } else { 'Desconocida' }
    $state = if ($result -and $result.State) { [string]$result.State } else { 'Unknown' }

    if (-not $result -or -not $result.Success -or $state -eq 'SkippedCheckpointUnavailable') {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $false; Status = 'Failed'; Reason = 'La operacion fallo o fue omitida sin evidencia CBS' }
    }
    if ($state -in @('NotApplicable', 'ReapplyNotApplicable') -and $category -ne 'LCU') {
        $status = if ($state -eq 'ReapplyNotApplicable') { 'ReapplyNotApplicable' } else { 'NotApplicable' }
        $reason = if ($state -eq 'ReapplyNotApplicable') { 'CBS determino que la reaplicacion no era necesaria o aplicable' } else { 'CBS determino que no era aplicable' }
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = $status; Reason = $reason }
    }
    if ($category -eq 'SetupDU') {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'External'; Reason = 'Verificado por mezcla y SHA-256 fuera del catalogo CBS' }
    }
    if ($category -eq 'Defender' -and $result.PSObject.Properties['VerifiedFiles'] -and [int]$result.VerifiedFiles -gt 0) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'External'; Reason = "Plataforma/firmas verificadas por SHA-256: $($result.VerifiedFiles) archivo(s)" }
    }

    if ($category -eq 'WinPE-Rejuv') {
        if ($package -and
            $package.PSObject.Properties['RemovalCheckedBeforeLcu'] -and
            [bool]$package.RemovalCheckedBeforeLcu) {

            $verified = [bool]$package.RemovalVerified
            $stateText = [string]$package.RemovalState
            $advisoryOnly = (
                $package.PSObject.Properties['AdvisoryOnly'] -and
                [bool]$package.AdvisoryOnly
            )

            if ($advisoryOnly) {
                return [pscustomobject]@{
                    Package = $name
                    Category = $category
                    Success = $true
                    Status = 'NeutralRejuvPreserved'
                    Reason = "CBS conservo o restablecio el componente neutro; estado inmediato: $stateText. La LCU y la limpieza terminaron correctamente."
                }
            }

            return [pscustomobject]@{
                Package = $name
                Category = $category
                Success = $verified
                Status = if ($verified) { 'RemovedBeforeLcu' } else { 'MissingRemoval' }
                Reason = if ($verified) {
                    "Retirada confirmada inmediatamente antes de la LCU; estado exacto: $stateText"
                }
                else {
                    "La identidad localizada seguia activa inmediatamente despues de Remove-Package; estado: $stateText"
                }
            }
        }

        # Fallback para registros antiguos: se evalua solo la identidad exacta.
        # Una identidad WinPE-Rejuv nueva agregada por la LCU no invalida la
        # retirada preventiva de la version anterior.
        $exactEntries = @(
            $AfterInventory |
                Where-Object { [string]$_.PackageName -ieq $name }
        )
        $blocking = @(
            $exactEntries |
                Where-Object {
                    [string]$_.PackageState -match '(?i)^Installed$|^Install ?Pending$|^Staged$|^Partially ?Installed$'
                }
        )
        $states = @(
            $exactEntries |
                ForEach-Object { [string]$_.PackageState } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique
        )
        $stateText = if ($states.Count -eq 0) { 'Ausente' } else { $states -join ', ' }
        $verified = ($blocking.Count -eq 0)
        return [pscustomobject]@{
            Package = $name
            Category = $category
            Success = $verified
            Status = if ($verified) { 'Removed' } else { 'MissingRemoval' }
            Reason = if ($verified) {
                "Identidad exacta retirada o inactiva; estado final: $stateText"
            }
            else {
                "La identidad exacta que debia retirarse sigue activa; estado final: $stateText"
            }
        }
    }

    if ($package) {
        $evidence = Get-AIOUpdatePackageCbsEvidence -Package $package -Inventory $AfterInventory
        if ($evidence.Success) {
            return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = $evidence.Status; Reason = $evidence.Reason }
        }
    }

    # Para un OS generico sin KB/identidad verificable no se inventa una prueba.
    # La operacion DISM sigue siendo valida, pero queda marcada como indeterminada.
    if ($category -eq 'OS' -and $state -in @('Success', 'AlreadyPresent', 'Reapplied')) {
        return [pscustomobject]@{ Package = $name; Category = $category; Success = $true; Status = 'Indeterminate'; Reason = 'Operacion correcta; el paquete OS no expone una identidad estable para correlacion' }
    }

    return [pscustomobject]@{ Package = $name; Category = $category; Success = $false; Status = 'Missing'; Reason = 'No se encontro evidencia CBS posterior del paquete o su familia' }
}

function New-AIOUpdateWimStructureReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [object[]]$BeforeImages,
        [Parameter(Mandatory = $true)] [object[]]$AfterImages,
        [Parameter(Mandatory = $true)] [int[]]$SelectedIndexes,
        [switch]$SingleIndex,
        [version]$ExpectedServicingVersion = [version]'0.0.0.0'
    )

    $issues = New-Object System.Collections.Generic.List[string]
    $details = New-Object System.Collections.Generic.List[string]
    $expectedCount = if ($SingleIndex) { 1 } else { $BeforeImages.Count }
    if ($AfterImages.Count -ne $expectedCount) {
        [void]$issues.Add("Cantidad de indices: esperada $expectedCount, obtenida $($AfterImages.Count)")
    }

    if ($SingleIndex) {
        $source = @($BeforeImages | Where-Object { $_.ImageIndex -eq $SelectedIndexes[0] } | Select-Object -First 1)
        $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq 1 } | Select-Object -First 1)
        if ($source.Count -eq 0 -or $destination.Count -eq 0) {
            [void]$issues.Add('No se pudo correlacionar el indice unico exportado')
        }
        else {
            if ([string]$source[0].ImageName -ne [string]$destination[0].ImageName) { [void]$issues.Add('El nombre de la edicion exportada cambio') }
            if ((Convert-AIOUpdateArchitectureName -Architecture $source[0].Architecture) -ne (Convert-AIOUpdateArchitectureName -Architecture $destination[0].Architecture)) { [void]$issues.Add('La arquitectura del indice exportado cambio') }
            if ([version]$destination[0].Version -lt [version]$source[0].Version) { [void]$issues.Add('La version del indice exportado disminuyo') }
            if ($ExpectedServicingVersion -ne [version]'0.0.0.0' -and -not (Test-AIOUpdateServicingVersionAtLeast -Actual ([version]$destination[0].Version) -Expected $ExpectedServicingVersion)) {
                [void]$issues.Add("Version final $($destination[0].Version) inferior a la evidencia CBS $ExpectedServicingVersion")
            }
            $displayName = Format-AIOUpdateImageDisplayName -ImageName ([string]$destination[0].ImageName) -Architecture $destination[0].Architecture
            [void]$details.Add("Indice final 1: $displayName")
            [void]$details.Add("Version final de imagen: $($destination[0].Version)")
            if ($ExpectedServicingVersion -ne [version]'0.0.0.0') {
                [void]$details.Add("Familia CBS validada    : $ExpectedServicingVersion")
            }
        }
    }
    else {
        foreach ($source in $BeforeImages) {
            $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq $source.ImageIndex } | Select-Object -First 1)
            if ($destination.Count -eq 0) { [void]$issues.Add("Falta el indice $($source.ImageIndex)"); continue }
            if ([string]$source.ImageName -ne [string]$destination[0].ImageName) { [void]$issues.Add("Cambio de nombre en indice $($source.ImageIndex)") }
            if ((Convert-AIOUpdateArchitectureName -Architecture $source.Architecture) -ne (Convert-AIOUpdateArchitectureName -Architecture $destination[0].Architecture)) { [void]$issues.Add("Cambio de arquitectura en indice $($source.ImageIndex)") }
            if ([version]$destination[0].Version -lt [version]$source.Version) { [void]$issues.Add("La version disminuyo en indice $($source.ImageIndex)") }
            $displayName = Format-AIOUpdateImageDisplayName -ImageName ([string]$destination[0].ImageName) -Architecture $destination[0].Architecture
            [void]$details.Add("Indice $($source.ImageIndex): $displayName | Version final de imagen: $($destination[0].Version)")
        }
        if ($ExpectedServicingVersion -ne [version]'0.0.0.0') {
            foreach ($index in $SelectedIndexes) {
                $destination = @($AfterImages | Where-Object { $_.ImageIndex -eq $index } | Select-Object -First 1)
                if ($destination.Count -gt 0 -and -not (Test-AIOUpdateServicingVersionAtLeast -Actual ([version]$destination[0].Version) -Expected $ExpectedServicingVersion)) {
                    [void]$issues.Add("Indice ${index}: version $($destination[0].Version) inferior a la evidencia CBS $ExpectedServicingVersion")
                }
            }
        }
    }

    return [pscustomobject]@{
        Kind            = 'WimStructure'
        Target          = $Target
        Phase           = 'Final'
        Success         = ($issues.Count -eq 0)
        Reason          = if ($issues.Count -eq 0) { 'Estructura, ediciones, arquitectura y version final verificadas' } else { $issues -join '; ' }
        BeforeCount     = $BeforeImages.Count
        AfterCount      = $AfterImages.Count
        BeforeActive    = 0
        AfterActive     = 0
        NewPackages     = @()
        RetiredPackages = @()
        Failed          = $issues.Count
        Details         = [string[]]($details.ToArray())
        ExpectedServicingVersion = $ExpectedServicingVersion
        Timestamp       = Get-Date
    }
}

function New-AIOUpdateVerificationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Before,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$After,
        [AllowNull()] [object[]]$OperationResults
    )

    $beforeAllNames = @($Before | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })
    $afterAllNames = @($After | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })
    $beforeActive = @($Before | Where-Object { $_.PackageState -match '(?i)^Installed$|^Install ?Pending$' })
    $afterActive = @($After | Where-Object { $_.PackageState -match '(?i)^Installed$|^Install ?Pending$' })
    $afterActiveNames = @($afterActive | ForEach-Object { [string]$_.PackageName } | Where-Object { $_ })

    $newPackages = @($afterActiveNames | Where-Object { $_ -notin $beforeAllNames } | Sort-Object -Unique)
    $retiredPackages = @($beforeAllNames | Where-Object { $_ -notin $afterAllNames } | Sort-Object -Unique)
    $operations = @($OperationResults)
    $failedOps = @($operations | Where-Object { $_ -and $_.Result -and -not $_.Result.Success })
    $inventoryReadable = ($Before.Count -eq 0 -or $After.Count -gt 0)

    Update-AIOUpdateServicingBuildRelationsFromInventory -Inventory $After
    $semanticEvidence = @(
        $operations |
            Where-Object { $_ -and $_.Result -and $_.Result.Success } |
            ForEach-Object { Get-AIOUpdateSemanticPackageEvidence -Operation $_ -AfterInventory $After }
    )
    $missingExpected = @($semanticEvidence | Where-Object { -not $_.Success })
    $indeterminate = @($semanticEvidence | Where-Object { $_.Status -eq 'Indeterminate' })
    $rejuvWarnings = @($semanticEvidence | Where-Object { $_.Status -eq 'NeutralRejuvPreserved' })
    $verifiedExpected = @($semanticEvidence | Where-Object { $_.Success -and $_.Status -notin @('NotApplicable', 'Indeterminate') })
    $observedVersion = Get-AIOUpdateObservedServicingVersion -Inventory $After

    $success = ($failedOps.Count -eq 0 -and $inventoryReadable -and $missingExpected.Count -eq 0)
    $reason = if ($failedOps.Count -gt 0) {
        "$($failedOps.Count) operacion(es) DISM fallaron"
    }
    elseif (-not $inventoryReadable) {
        'El inventario posterior esta vacio o no pudo leerse'
    }
    elseif ($missingExpected.Count -gt 0) {
        "$($missingExpected.Count) paquete(s) sin evidencia semantica posterior"
    }
    elseif ($indeterminate.Count -gt 0) {
        'Operaciones correctas; algunas identidades OS no permiten correlacion exacta'
    }
    elseif ($rejuvWarnings.Count -gt 0) {
        'Operaciones, identidades esperadas e inventario verificados'
    }
    elseif ($retiredPackages.Count -gt 0) {
        'Operaciones, identidades esperadas e inventario verificados; hubo supersedencia normal'
    }
    else {
        'Operaciones, identidades esperadas e inventario verificados'
    }

    return [pscustomobject]@{
        Kind             = 'PackageInventory'
        Target           = $Target
        Phase            = $Phase
        Success          = $success
        Reason           = $reason
        BeforeCount      = $Before.Count
        AfterCount       = $After.Count
        BeforeActive     = $beforeActive.Count
        AfterActive      = $afterActive.Count
        NewPackages      = $newPackages
        RetiredPackages  = $retiredPackages
        SemanticEvidence = $semanticEvidence
        VerifiedExpected = $verifiedExpected
        MissingExpected  = $missingExpected
        Indeterminate    = $indeterminate
        RejuvWarnings    = $rejuvWarnings
        ObservedServicingVersion = $observedVersion
        Failed           = $failedOps.Count
        Timestamp        = Get-Date
    }
}

function Write-AIOUpdateVerificationReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Report
    )

    $status = if ($Report.Success) { 'VERIFICADO' } else { 'ERROR' }
    $color = if ($Report.Success) { 'Green' } else { 'Red' }
    if ($Report.PSObject.Properties['Kind'] -and $Report.Kind -eq 'WimStructure') {
        Write-Host ("   [{0}] {1} - {2}: indices {3} -> {4}" -f $status, $Report.Target, $Report.Phase, $Report.BeforeCount, $Report.AfterCount) -ForegroundColor $color
        Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
        foreach ($detail in @($Report.Details)) { Write-Host "      $detail" -ForegroundColor DarkGray }
        return
    }

    if ($Report.PSObject.Properties['Kind'] -and $Report.Kind -eq 'SetupLanguagePreservation') {
        Write-Host ("   [{0}] {1} - {2}: idiomas de Windows Setup" -f $status, $Report.Target, $Report.Phase) -ForegroundColor $color
        Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
        foreach ($detail in @($Report.Details)) { Write-Host "      $detail" -ForegroundColor DarkGray }
        return
    }

    $summary = "   [{0}] {1} - {2}: catalogo {3} -> {4} | activos {5} -> {6}" -f $status, $Report.Target, $Report.Phase, $Report.BeforeCount, $Report.AfterCount, $Report.BeforeActive, $Report.AfterActive
    Write-Host $summary -ForegroundColor $color
    Write-Host "      $($Report.Reason)" -ForegroundColor DarkGray
    if ($Report.PSObject.Properties['VerifiedExpected']) {
        Write-Host "      Evidencias semanticas confirmadas: $(@($Report.VerifiedExpected).Count)" -ForegroundColor DarkGray
    }
    if ($Report.PSObject.Properties['MissingExpected'] -and @($Report.MissingExpected).Count -gt 0) {
        foreach ($missing in @($Report.MissingExpected)) {
            Write-Host "      [FALTA] $($missing.Package): $($missing.Reason)" -ForegroundColor Red
        }
    }
    if ($Report.PSObject.Properties['ObservedServicingVersion'] -and $Report.ObservedServicingVersion -ne [version]'0.0.0.0') {
        Write-Host "      Familia CBS observada      : $($Report.ObservedServicingVersion)" -ForegroundColor DarkGray
    }
    if ($Report.NewPackages.Count -gt 0) {
        Write-Host "      Paquetes nuevos detectados: $($Report.NewPackages.Count)" -ForegroundColor DarkGray
    }
    if ($Report.RetiredPackages.Count -gt 0) {
        Write-Host "      Paquetes retirados/consolidados por supersedencia: $($Report.RetiredPackages.Count)" -ForegroundColor DarkGray
    }
}


function Write-AIOUpdateConsolidatedRejuvSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Reports
    )

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($report in @($Reports | Where-Object {
        $_.Kind -eq 'PackageInventory' -and
        $_.Phase -eq 'PostCommit' -and
        $_.Target -like 'boot.wim*'
    })) {
        foreach ($warning in @($report.RejuvWarnings)) {
            [void]$entries.Add([pscustomobject]@{
                Package = [string]$warning.Package
                Target  = [string]$report.Target
            })
        }
    }

    if ($entries.Count -eq 0) { return }

    $uniquePackages = @($entries | Select-Object -ExpandProperty Package -Unique | Sort-Object)
    $uniqueTargets = @($entries | Select-Object -ExpandProperty Target -Unique | Sort-Object)

    Write-Host ''
    Write-Host '   [AVISO CONSOLIDADO] WinPE-Rejuv neutro' -ForegroundColor Yellow
    Write-Host ("      CBS conservo o restablecio {0} identidad(es) neutra(s) en {1} indice(s)." -f $uniquePackages.Count, $uniqueTargets.Count) -ForegroundColor DarkGray
    Write-Host ("      Destinos: {0}" -f ($uniqueTargets -join ', ')) -ForegroundColor DarkGray
    foreach ($package in $uniquePackages) {
        Write-Host "      - $package" -ForegroundColor DarkGray
    }

    Write-AIOUpdateLog -Level WARN -Message ("Aviso consolidado WinPE-Rejuv: {0} identidad(es) neutra(s) conservadas/restablecidas en {1}." -f $uniquePackages.Count, ($uniqueTargets -join ', '))
}

function Copy-AIOUpdateFileWithBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Source,
        [Parameter(Mandatory = $true)] [string]$Destination,
        [switch]$OnlyIfNewer
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { return $null }

    $copy = $true
    if ($OnlyIfNewer -and (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        try {
            $sourceInfo = Get-Item -LiteralPath $Source
            $destinationInfo = Get-Item -LiteralPath $Destination
            $sourceVersionText = [string]$sourceInfo.VersionInfo.FileVersion
            $destinationVersionText = [string]$destinationInfo.VersionInfo.FileVersion
            $sourceVersion = $null
            $destinationVersion = $null

            if (-not [string]::IsNullOrWhiteSpace($sourceVersionText)) {
                $normalized = ($sourceVersionText -replace '[^0-9.]', '').Trim('.')
                if ($normalized) { [void][version]::TryParse($normalized, [ref]$sourceVersion) }
            }
            if (-not [string]::IsNullOrWhiteSpace($destinationVersionText)) {
                $normalized = ($destinationVersionText -replace '[^0-9.]', '').Trim('.')
                if ($normalized) { [void][version]::TryParse($normalized, [ref]$destinationVersion) }
            }

            if ($null -ne $sourceVersion -and $null -ne $destinationVersion -and $sourceVersion -ne $destinationVersion) {
                $copy = ($sourceVersion -gt $destinationVersion)
            }
            else {
                $copy = ($sourceInfo.LastWriteTimeUtc -gt $destinationInfo.LastWriteTimeUtc)
            }
        }
        catch {
            $copy = $true
        }
    }

    if (-not $copy) {
        return [pscustomobject]@{
            Source = $Source
            Destination = $Destination
            Copied = $false
            Reason = 'Destino igual o mas reciente'
        }
    }

    $sourceHash = Get-AIOUpdateFileSha256 -Path $Source
    $destinationExisted = Test-Path -LiteralPath $Destination -PathType Leaf
    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $Destination
    $preflightState = Get-AIOUpdatePreflightPathState -Destination $Destination

    if ($destinationExisted -and -not $preflightPath -and -not $preflightState.KnownNew) {
        throw "El archivo existente '$Destination' no esta cubierto por Preflight ni fue registrado explicitamente como creado por esta sesion; no se reemplazara."
    }

    $verifier = {
        param($candidate)
        $destinationHash = Get-AIOUpdateFileSha256 -Path $candidate
        if ($destinationHash -ne $sourceHash) {
            throw "La copia no coincide por SHA-256: '$candidate'."
        }
    }.GetNewClosure()

    [void](Invoke-AIOUpdateAtomicReplacement -Source $Source -Destination $Destination -Context "Copiando $([System.IO.Path]::GetFileName($Destination))" -Verifier $verifier)
    $destinationHash = Get-AIOUpdateFileSha256 -Path $Destination

    $registeredAsSessionCreated = $false
    if (-not $destinationExisted -and -not $preflightPath) {
        $registeredAsSessionCreated = Register-AIOUpdateSessionCreatedPath -Path $Destination -Source $Source -Reason 'Creado por Copy-AIOUpdateFileWithBackup'
        if ($preflightState.CoveredSurface -and -not $registeredAsSessionCreated) {
            throw "El archivo nuevo '$Destination' fue copiado, pero no pudo registrarse como creado por la sesion."
        }
    }

    return [pscustomobject]@{
        Source          = $Source
        Destination     = $Destination
        Copied          = $true
        Hash            = $destinationHash
        SourceHash      = $sourceHash
        DestinationHash = $destinationHash
        Verified        = $true
        BackupPath      = $preflightPath
        BackupType      = if ($preflightPath) { 'Preflight' } elseif ($destinationExisted -and $preflightState.KnownNew) { 'SessionCreated' } elseif ($registeredAsSessionCreated) { 'SessionCreated' } else { 'NotRequired' }
        DuplicateCopy   = $false
        Reason          = if ($preflightPath) {
            'Copiado y verificado; restauracion cubierta por Preflight'
        }
        elseif ($destinationExisted -and $preflightState.KnownNew) {
            'Archivo previamente registrado como creado por esta sesion; reemplazo permitido'
        }
        elseif ($registeredAsSessionCreated) {
            'Archivo nuevo registrado explicitamente como creado por esta sesion'
        }
        else {
            'Archivo nuevo fuera de la superficie cubierta por Preflight'
        }
    }
}

function Initialize-AIOUpdateWinRECombinedStack {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [AllowEmptyCollection()] [object[]]$Before
    )
    $family = Get-AIOUpdateServicingBuildFamily -Build $Build
    $targets = @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('LCU') -Architecture $Architecture -Build $Build -ImageName 'WinRE' | Where-Object {
        $_.VersionReliable -and (Get-AIOUpdateServicingBuildFamily -Build ([version]$_.Version).Build) -eq $family
    } | Sort-Object Version -Descending | Select-Object -First 1)
    if (-not $targets.Count) { throw 'WinRE: falta un SSU utilizable o un MSU combinado de su familia de mantenimiento.' }
    $package = $targets[0]
    $path = Get-AIOUpdateEffectivePackagePath -Package $package
    $result = Invoke-AIOUpdateDism -Arguments @("/Image:$MountPath", '/Add-Package', "/PackagePath:$path", "/ScratchDir:$ScratchPath") -Context "WinRE: preparar SOLO la pila desde $($package.Name)" -NoThrow -DisplayIdentity (Get-AIOUpdatePackageDisplayIdentity -Package $package)
    $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $MountPath -Strict)
    $ssus = @($after | Where-Object {
        $_.PackageState -eq 'Installed' -and $_.PackageName -match '^Package_for_ServicingStack[^~]*~31bf3856ad364e35~[^~]+~~'
    })
    $verified = $false
    foreach ($root in @($package.Metadata.CbsRootIdentities | Where-Object { $_.Prefix -match '^Package_for_ServicingStack[^~]*~31bf3856ad364e35~[^~]+~$' })) {
        $candidate = [pscustomobject]@{
            Name = $package.Name; Category = 'SSU'; Version = [version]$root.Version; VersionReliable = $true
            Architectures = @($Architecture); IdentityHints = @(); KB = $null
            Metadata = [pscustomobject]@{ CbsRootIdentities = @($root); CbsOwnIdentities = @() }
        }
        if ((Get-AIOUpdatePackageCbsEvidence -Package $candidate -Inventory $ssus).Success) { $verified = $true }
    }
    # If no SSU root was available in metadata, require an observed native SSU change.
    foreach ($ssu in $ssus) {
        $parts = $ssu.PackageName -split '~'
        $v = ConvertTo-AIOUpdateServicingVersion -Version ([version]$parts[4])
        if ((Convert-AIOUpdateArchitectureName -Architecture $parts[2]) -eq $Architecture -and
            (Get-AIOUpdateServicingBuildFamily -Build $v.Build) -eq $family -and
            $ssu.PackageName -notin @($Before | Where-Object PackageState -eq 'Installed' | ForEach-Object PackageName)) { $verified = $true }
    }
    $code = Convert-AIOUpdateExitCodeToUInt32 -ExitCode $result.ExitCode
    # Microsoft's combined-package exception is limited to 0x8007007e and
    # must still leave demonstrable SSU evidence; never exempt other errors.
    if (-not $result.Success -and -not ($code -eq [uint32]2147942526 -and $verified)) {
        throw "WinRE: fallo al preparar la pila con el MSU combinado. Codigo $($result.ExitCode)."
    }
    Add-AIOUpdateMaintenanceRecord -Context 'WinRE SSU combinado' -State $(if ($verified) { 'ServicingStackVerified' } else { 'StackVersionUnconfirmed' }) -Performed $verified -Reason "MSU=$($package.Name); DISM=$($result.ExitCode); la actualizacion de recuperacion se acreditara exclusivamente con SafeOS Installed."
    [pscustomobject]@{ Inventory = [object[]]$after; Verified = $verified }
}

function Get-AIOUpdateWinREPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [int]$Build,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [string]$Architecture
    )
    $safeOS = @(Get-AIOUpdatePackages -Inventory $Inventory -Category @('SafeOS') | Where-Object {
        -not $Architecture -or (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $Architecture -Build $Build -ImageName 'WinRE').Compatible
    })
    $ssu = @(Get-AIOUpdateEffectiveSsuPackages -Inventory $Inventory -Architecture $Architecture -Build $Build -ImageName 'WinRE')
    $lcu = @(Get-AIOUpdatePackages -Inventory $Inventory -Category @('LCU') | Where-Object {
        -not $Architecture -or (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $Architecture -Build $Build -ImageName 'WinRE').Compatible
    })
    [pscustomobject]@{
        IncludeLCU = $false; HasSafeOS = ($safeOS.Count -gt 0); HasEffectiveSsu = ($ssu.Count -gt 0); HasLCU = ($lcu.Count -gt 0)
        PrepareStackFromCombined = ($safeOS.Count -gt 0 -and $ssu.Count -eq 0 -and $lcu.Count -gt 0)
        BuildObserved = $Build; Architecture = $Architecture; Mode = 'ServicingStackThenSafeOS'
        Reason = $(if ($safeOS.Count) { 'Preparar SSU y aplicar SafeOS; la LCU combinada solo puede aportar la pila, no sustituye SafeOS.' } else { 'Sin SafeOS compatible: solo se puede mantener la pila; WinRE no se declarara actualizado.' })
    }
}

function Get-AIOUpdateWinREFromInstallWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int]$Index,
        [Parameter(Mandatory = $true)] [string]$InstallMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Write-Host "   Extrayendo winre.wim del indice $Index sin montar install.wim..." -ForegroundColor DarkCyan
    if (Invoke-AIOUpdateWimExtractPath -WimPath $InstallWim -Index $Index -ImagePath 'Windows\System32\Recovery\winre.wim' -DestinationPath $Destination -TemporaryPath $ScratchPath) {
        if (Test-AIOUpdateWimContainerSignature -Path $Destination) { return $Destination }
        Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
    }
    Write-AIOUpdateLog -Level WARN -Message 'Extraccion directa de WinRE no disponible; se utiliza el montaje de respaldo.'
    $mounted = $false
    try {
        Mount-AIOUpdateImage -ImagePath $InstallWim -Index $Index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Extrayendo winre.wim del indice $Index" -ReadOnly
        $mounted = $true
        $source = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "El indice $Index no contiene Windows\System32\Recovery\winre.wim."
        }
        Copy-Item -LiteralPath $source -Destination $Destination -Force -ErrorAction Stop
        [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context 'Cierre del montaje usado para extraer WinRE')
        $mounted = $false
        return $Destination
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context 'Descarte de emergencia al extraer WinRE' -NoThrow)
        }
    }
}


function Get-AIOUpdateWinRERecoveryEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$InstalledInventory
    )
    $evidence = New-Object System.Collections.Generic.List[object]
    foreach ($package in @($Packages | Where-Object { $_.Category -eq 'SafeOS' })) {
        $match = Get-AIOUpdatePackageCbsEvidence -Package $package -Inventory $InstalledInventory
        if ($match.Success -and $match.PackageState -eq 'Installed') { [void]$evidence.Add([pscustomobject]@{ Package = $package.Name; Category = $package.Category; Evidence = $match }) }
    }
    return [object[]]$evidence.ToArray()
}

function Update-AIOUpdateWinRE {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$SourceWinRE,
        [Parameter(Mandatory = $true)] [string]$DestinationWinRE,
        [Parameter(Mandatory = $true)] [string]$WinREMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [psobject]$Policy,
        [bool]$OptimizeWim = $true,
        [bool]$VerifyPrePostCommit = $true,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    Copy-Item -LiteralPath $SourceWinRE -Destination $DestinationWinRE -Force -ErrorAction Stop
    $image = @(Get-AIOUpdateImageMetadata -ImagePath $DestinationWinRE | Select-Object -First 1)[0]
    $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
    $build = ([version]$image.Version).Build
    $mounted = $false

    try {
        Mount-AIOUpdateImage -ImagePath $DestinationWinRE -Index 1 -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'Montando winre.wim para mantenimiento'
        $mounted = $true
        $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        Update-AIOUpdateServicingBuildRelationsFromInventory -Inventory $baseline
        $Policy = Get-AIOUpdateWinREPolicy -Build $build -Inventory $Inventory -Architecture $architecture
        $operations = New-Object System.Collections.Generic.List[object]

        # Preparar primero CBS y verificar si algun SSU candidato realmente
        # quedo satisfecho. La existencia de un archivo SSU no es evidencia.
        $ssuCandidates = @(Get-AIOUpdateEffectiveSsuPackages -Inventory $Inventory -Architecture $architecture -Build $build -ImageName 'WinRE')
        $currentInventory = $baseline
        $orderedSsu = @(Resolve-AIOUpdateCbsPackageOrder -Packages $ssuCandidates -Context 'WinRE SSU')
        foreach ($package in $orderedSsu) {
            foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $WinREMount -Packages @($package) -ScratchPath $ScratchPath -Context 'WinRE: preparar pila de mantenimiento' -AllowNotApplicable -InstalledInventory $currentInventory -DependencyContext 'WinRE SSU')) {
                [void]$operations.Add($entry)
            }
            $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        }
        $verifiedSsu = @($ssuCandidates | Where-Object { (Get-AIOUpdatePackageCbsEvidence -Package $_ -Inventory $currentInventory).Success })
        $Policy | Add-Member -NotePropertyName SsuVerified -NotePropertyValue ($verifiedSsu.Count -gt 0) -Force
        if ($Policy.HasSafeOS -and $Policy.HasLCU -and $verifiedSsu.Count -eq 0) {
            $stack = Initialize-AIOUpdateWinRECombinedStack -MountPath $WinREMount -Inventory $Inventory -Architecture $architecture -Build $build -ScratchPath $ScratchPath -Before $currentInventory
            $currentInventory = @($stack.Inventory)
            $Policy.SsuVerified = [bool]$stack.Verified
        }
        Write-AIOUpdateLog -Level INFO -Message "WinRE $architecture build ${build}: SSU acreditado=$($Policy.SsuVerified); SafeOS=$($Policy.HasSafeOS). $($Policy.Reason)"
        $winrePackages = New-Object System.Collections.Generic.List[object]
        foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('SafeOS') -Architecture $architecture -Build $build -ImageName 'WinRE')) {
            [void]$winrePackages.Add($package)
        }

        $orderedWinRE = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($winrePackages.ToArray())) -Context 'WinRE'
        foreach ($package in $orderedWinRE) {
            foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $WinREMount -Packages @($package) -ScratchPath $ScratchPath -Context "WinRE: integrando $($package.Category)" -AllowNotApplicable -InstalledInventory $currentInventory -DependencyContext 'WinRE')) {
                [void]$operations.Add($entry)
            }
            $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
        }
        $recoveryCandidates = @($winrePackages.ToArray())
        $recoveryEvidence = @(Get-AIOUpdateWinRERecoveryEvidence -Packages $recoveryCandidates -InstalledInventory $currentInventory)
        if ($recoveryCandidates.Count -gt 0 -and $recoveryEvidence.Count -eq 0) {
            throw 'WinRE: SafeOS no quedo Installed ni fue sustituido por un SafeOS instalado compatible; un SSU o una LCU no prueban la actualizacion de recuperacion.'
        }
        $recoveryUpdated = $recoveryEvidence.Count -gt 0
        $recoveryState = if ($recoveryUpdated) { 'RecoveryVerified' } elseif ($Policy.SsuVerified) { 'ServicingStackOnly' } else { 'NoApplicableUpdates' }
        $recoveryReason = if ($recoveryUpdated) { 'Paquetes de recuperacion acreditados: ' + (($recoveryEvidence | ForEach-Object { $_.Package }) -join ', ') } elseif ($Policy.SsuVerified) { 'Solo se acredito la pila de mantenimiento; no hay actualizacion de recuperacion.' } else { 'No se acredito ninguna actualizacion aplicable a WinRE.' }
        Add-AIOUpdateMaintenanceRecord -Context 'WinRE' -State $recoveryState -Performed $recoveryUpdated -Reason $recoveryReason

        [void](Invoke-AIOUpdateCleanup -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'WinRE: limpieza y ResetBase' -ResetBase -WarningOnly)
        if ($VerifyPrePostCommit) {
            $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
            $preReport = New-AIOUpdateVerificationReport -Target 'winre.wim' -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($preReport)
            Write-AIOUpdateVerificationReport -Report $preReport
            if (-not $preReport.Success) { throw 'Fallo la verificacion previa al commit de winre.wim.' }
        }
        else {
            Write-AIOUpdateLog -Level INFO -Message 'WinRE: verificaciones Pre/Post-Commit omitidas por configuracion.'
        }

        [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Commit -Context 'Guardando winre.wim actualizado')
        $mounted = $false

        if ($OptimizeWim) {
            $optimized = [System.IO.Path]::ChangeExtension($DestinationWinRE, '.optimized.wim')
            Remove-Item -LiteralPath $optimized -Force -ErrorAction SilentlyContinue
            [void](Invoke-AIOUpdateDism -Arguments @(
                '/Export-Image',
                "/SourceImageFile:$DestinationWinRE",
                '/SourceIndex:1',
                "/DestinationImageFile:$optimized",
                '/Compress:max',
                '/CheckIntegrity',
                '/Bootable',
                "/ScratchDir:$ScratchPath"
            ) -Context 'Optimizando winre.wim actualizado')
            Move-Item -LiteralPath $optimized -Destination $DestinationWinRE -Force
        }
        else {
            Write-AIOUpdateLog -Level INFO -Message 'WinRE: exportacion y optimizacion omitidas por configuracion.'
        }

        if ($VerifyPrePostCommit) {
            Mount-AIOUpdateImage -ImagePath $DestinationWinRE -Index 1 -MountPath $WinREMount -ScratchPath $ScratchPath -Context 'Verificando winre.wim guardado' -ReadOnly
            $mounted = $true
            $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $WinREMount -Strict)
            if ($recoveryUpdated -and @(Get-AIOUpdateWinRERecoveryEvidence -Packages $recoveryCandidates -InstalledInventory $post).Count -eq 0) { throw 'El SafeOS verificado no se conservo en winre.wim tras commit/exportacion.' }
            $postReport = New-AIOUpdateVerificationReport -Target 'winre.wim' -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
            [void]$VerificationReports.Add($postReport)
            Write-AIOUpdateVerificationReport -Report $postReport
            if (-not $postReport.Success) { throw 'Fallo la verificacion posterior al commit de winre.wim.' }
            [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Discard -Context 'Cerrando verificacion de winre.wim')
            $mounted = $false
        }

        return [pscustomobject]@{
            Path   = $DestinationWinRE
            Hash   = (Get-FileHash -LiteralPath $DestinationWinRE -Algorithm SHA256).Hash
            Policy = $Policy
            RecoveryUpdated = $recoveryUpdated
            ServicingStackVerified = [bool]$Policy.SsuVerified
            RecoveryEvidence = [object[]]$recoveryEvidence
        }
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $WinREMount -Mode Discard -Context 'Descarte de emergencia de winre.wim' -NoThrow)
        }
    }
}


function Update-AIOUpdateInstallWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int[]]$Indexes,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$InstallMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [AllowNull()] [psobject]$ServicedWinRE,
        [AllowNull()] [hashtable]$ServicedWinREByIndex,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [bool]$VerifyPrePostCommit = $true,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    $imageMetadata = @(Get-AIOUpdateImageMetadata -ImagePath $InstallWim)
    $position = 0
    foreach ($index in $Indexes) {
        $position++
        $indexWinRE = $ServicedWinRE
        if ($ServicedWinREByIndex -and $ServicedWinREByIndex.Count -gt 0) {
            if (-not $ServicedWinREByIndex.ContainsKey([string]$index)) { throw "Falta WinRE actualizado para el indice $index." }
            $indexWinRE = $ServicedWinREByIndex[[string]$index]
        }
        elseif ($indexWinRE -and $Indexes.Count -gt 1 -and -not $indexWinRE.SourceHash) {
            throw 'Se requiere verificar el WinRE original de cada indice antes de reutilizar una copia.'
        }
        $image = $imageMetadata | Where-Object { [int]$_.ImageIndex -eq [int]$index } | Select-Object -First 1
        if (-not $image) { throw "No se encontro metadata del indice $index." }
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        $build = ([version]$image.Version).Build
        $editionId = if ($image.PSObject.Properties['EditionId']) { [string]$image.EditionId } else { '' }
        $mounted = $false

        try {
            Write-Host "`n=======================================================" -ForegroundColor DarkCyan
            Write-Host " INSTALL.WIM $position/$($Indexes.Count) - INDICE $index" -ForegroundColor Cyan
            Write-Host "=======================================================" -ForegroundColor DarkCyan

            Mount-AIOUpdateImage -ImagePath $InstallWim -Index $index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Montando install.wim indice $index"
            $mounted = $true
            $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
            $operations = New-Object System.Collections.Generic.List[object]

            if ($indexWinRE) {
                $winreTarget = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
                if ($indexWinRE.SourceHash) {
                    $originalHash = (Get-FileHash -LiteralPath $winreTarget -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($originalHash -ne $indexWinRE.SourceHash) { throw "WinRE del indice $index no coincide con el original usado para actualizarlo." }
                }
                Copy-AIOUpdateSetupDUFile -Source $indexWinRE.Path -Destination $winreTarget
            }

            $installPackages = New-Object System.Collections.Generic.List[object]
            foreach ($category in $script:AIOUpdateInstallCategoryOrder) {
                foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @($category) -Architecture $architecture -Build $build -ImageName $image.ImageName -EditionId $editionId)) {
                    [void]$installPackages.Add($package)
                }
            }
            $orderedInstallPackages = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($installPackages.ToArray())) -Context "install.wim indice $index"
            foreach ($package in $orderedInstallPackages) {
                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $InstallMount -Packages @($package) -ScratchPath $ScratchPath -Context "Install indice ${index}: $($package.Category)" -AllowNotApplicable -InstalledInventory $baseline -DependencyContext "install.wim indice $index")) {
                    [void]$operations.Add($entry)
                }
            }

            $defender = Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @('Defender') -Architecture $architecture -Build $build -ImageName $image.ImageName -EditionId $editionId
            foreach ($entry in @(Apply-AIOUpdateDefenderPackages -MountPath $InstallMount -Packages $defender -ScratchRoot $script:AIOUpdateSessionRoot -DismScratch $ScratchPath -InstalledInventory $baseline)) {
                [void]$operations.Add($entry)
            }

            if ($Cleanup) {
                [void](Invoke-AIOUpdateCleanup -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Install indice ${index}: limpieza de componentes" -ResetBase:$ResetBase -WarningOnly)
            }

            if ($VerifyPrePostCommit) {
                $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
                $preReport = New-AIOUpdateVerificationReport -Target "install.wim indice $index" -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
                [void]$VerificationReports.Add($preReport)
                Write-AIOUpdateVerificationReport -Report $preReport
                if (-not $preReport.Success) { throw "Fallo la verificacion previa al commit del indice $index." }
            }
            else {
                Write-AIOUpdateLog -Level INFO -Message "Install indice ${index}: verificaciones Pre/Post-Commit omitidas por configuracion."
            }

            [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Commit -Context "Guardando install.wim indice $index")
            $mounted = $false

            if ($VerifyPrePostCommit) {
                Mount-AIOUpdateImage -ImagePath $InstallWim -Index $index -MountPath $InstallMount -ScratchPath $ScratchPath -Context "Verificando install.wim indice $index" -ReadOnly
                $mounted = $true
                $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $InstallMount -Strict)
                $postReport = New-AIOUpdateVerificationReport -Target "install.wim indice $index" -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
                [void]$VerificationReports.Add($postReport)
                Write-AIOUpdateVerificationReport -Report $postReport
                if (-not $postReport.Success) { throw "Fallo la verificacion posterior al commit del indice $index." }

                if ($indexWinRE) {
                    $embeddedWinRE = Join-Path $InstallMount 'Windows\System32\Recovery\winre.wim'
                    $embeddedHash = (Get-FileHash -LiteralPath $embeddedWinRE -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($embeddedHash -ne $indexWinRE.Hash) {
                        throw "El hash de winre.wim reinyectado no coincide en el indice $index."
                    }
                    Write-Host '   [VERIFICADO] winre.wim reinyectado coincide por SHA-256.' -ForegroundColor Green
                }

                [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context "Cerrando verificacion del indice $index")
                $mounted = $false
            }
        }
        finally {
            if ($mounted) {
                [void](Dismount-AIOUpdateImage -MountPath $InstallMount -Mode Discard -Context "Descarte de emergencia de install.wim indice $index" -NoThrow)
            }
        }
    }
}

function Export-AIOUpdateSingleInstallIndex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$InstallWim,
        [Parameter(Mandatory = $true)] [int]$SourceIndex,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [Parameter(Mandatory = $true)] [string]$ScratchPath
    )

    $exportPath = Join-Path $StagingRoot ("install.single.{0}.wim" -f $SourceIndex)
    if (Test-Path -LiteralPath $exportPath) {
        Remove-Item -LiteralPath $exportPath -Force -ErrorAction Stop
    }

    Write-Host "`nExportando el indice $SourceIndex como install.wim de indice unico..." -ForegroundColor Cyan
    [void](Invoke-AIOUpdateDism -Arguments @(
        '/Export-Image',
        "/SourceImageFile:$InstallWim",
        "/SourceIndex:$SourceIndex",
        "/DestinationImageFile:$exportPath",
        '/Compress:max',
        '/CheckIntegrity',
        "/ScratchDir:$ScratchPath"
    ) -Context "Exportando install.wim con el unico indice $SourceIndex")

    $exportedImages = @(Get-AIOUpdateImageMetadata -ImagePath $exportPath)
    if ($exportedImages.Count -ne 1 -or [int]$exportedImages[0].ImageIndex -ne 1) {
        throw 'La verificacion del install.wim exportado no devolvio exactamente un indice.'
    }

    $preflightPath = Get-AIOUpdatePreflightBackupPath -Destination $InstallWim
    if (-not $preflightPath) {
        throw 'No se encontro la copia Preflight de install.wim; no se reemplazara el WIM original.'
    }

    $verifier = {
        param($candidate)
        $finalImages = @(Get-AIOUpdateImageMetadata -ImagePath $candidate)
        if ($finalImages.Count -ne 1 -or [int]$finalImages[0].ImageIndex -ne 1) {
            throw 'El install.wim final no contiene exactamente un indice.'
        }
    }

    [void](Invoke-AIOUpdateAtomicReplacement -Source $exportPath -Destination $InstallWim -Context 'Reemplazando install.wim por la exportacion de indice unico' -MoveSource -Verifier $verifier)
    $finalImages = @(Get-AIOUpdateImageMetadata -ImagePath $InstallWim)

    Write-AIOUpdateLog -Level INFO -Message "install.wim reducido al indice seleccionado $SourceIndex; indice final 1. Restauracion maestra: $preflightPath"
    return [pscustomobject]@{
        Applied       = $true
        OriginalIndex = $SourceIndex
        FinalIndex    = 1
        ImageName     = [string]$finalImages[0].ImageName
        Version       = [string]$finalImages[0].Version
        Architecture  = (Convert-AIOUpdateArchitectureName -Architecture $finalImages[0].Architecture)
        BackupPath    = $preflightPath
        BackupType    = 'Preflight'
        DuplicateCopy = $false
    }
}

function Save-AIOUpdateBootFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string[]]$Candidates,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$Key,
        [Parameter(Mandatory = $true)] [hashtable]$CaptureTable
    )

    foreach ($relative in $Candidates) {
        $source = $null
        $candidatePath = Join-Path $MountPath $relative
        if ([System.Management.Automation.WildcardPattern]::ContainsWildcardCharacters($relative)) {
            $source = @(Get-ChildItem -Path $candidatePath -File -ErrorAction SilentlyContinue | Sort-Object FullName | Select-Object -First 1)
            if (@($source).Count -gt 0) { $source = [string]$source[0].FullName } else { $source = $null }
        }
        elseif (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $source = $candidatePath
        }

        if ($source) {
            $destination = Join-Path $CaptureRoot ($Key + '_' + [System.IO.Path]::GetFileName($source))
            Copy-Item -LiteralPath $source -Destination $destination -Force -ErrorAction Stop
            $CaptureTable[$Key] = $destination
            return
        }
    }
}


function Get-AIOUpdateBootSetupIndex {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object[]]$Images)

    $items = @($Images | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) { return 0 }

    # Preferir semantica de la imagen frente al numero de indice. El indice 2
    # es el layout estandar de medios Microsoft, pero WIM personalizados pueden
    # reordenar o eliminar indices.
    $setupImage = @(
        $items |
            Where-Object {
                ([string]$_.ImageName -match '(?i)\bWindows\s+Setup\b|Microsoft\s+Windows\s+Setup') -or
                ($_.PSObject.Properties['ImageDescription'] -and [string]$_.ImageDescription -match '(?i)\bWindows\s+Setup\b')
            } |
            Sort-Object ImageIndex |
            Select-Object -First 1
    )
    if ($setupImage.Count -gt 0) { return [int]$setupImage[0].ImageIndex }

    $standard = @($items | Where-Object { [int]$_.ImageIndex -eq 2 } | Select-Object -First 1)
    if ($standard.Count -gt 0) { return 2 }

    return [int](($items | Sort-Object ImageIndex -Descending | Select-Object -First 1).ImageIndex)
}

function Get-AIOUpdateBootSetupDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [Parameter(Mandatory = $true)] [string]$BootMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot
    )

    $captured = @{}
    if (-not (Test-Path -LiteralPath $BootWim -PathType Leaf)) { return $captured }

    $images = @(Get-AIOUpdateImageMetadata -ImagePath $BootWim)
    if ($images.Count -eq 0) { return $captured }
    $setupIndex = Get-AIOUpdateBootSetupIndex -Images $images
    if ($setupIndex -le 0) { return $captured }

    $mounted = $false
    try {
        Mount-AIOUpdateImage -ImagePath $BootWim -Index $setupIndex -MountPath $BootMount -ScratchPath $ScratchPath -Context 'Leyendo dependencias SetupDU desde boot.wim' -ReadOnly
        $mounted = $true
        Initialize-AIOUpdateDirectory -Path $CaptureRoot
        foreach ($spec in $script:AIOUpdateSetupDependencySpecs) {
            Save-AIOUpdateBootFile -MountPath $BootMount -Candidates $spec.Candidates -CaptureRoot $CaptureRoot -Key $spec.Key -CaptureTable $captured
        }
    }
    finally {
        if ($mounted) {
            [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context 'Cerrando lectura de dependencias SetupDU')
        }
    }

    return $captured
}

function Get-AIOUpdatePeDependencyInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)

    # Leer tablas PE normales y diferidas; no cargar ni ejecutar el binario.
    # Formato Microsoft PE/COFF, independiente de la build o del nombre de DLL.
    if (-not ('AIOUpdate.PeDependencyReaderV1' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
namespace AIOUpdate {
    public sealed class PeDependencyInfoV1 {
        public ushort Machine;
        public string[] Imports;
        public string[] DelayImports;
    }
    public sealed class PeDependencyReaderV1 {
        private byte[] data;
        private int sections, count, optional, optionalSize, directories, directoryCount;
        private uint headersSize;
        private ulong imageBase;
        private void Range(long offset, long size) {
            if (offset < 0 || size < 0 || offset > data.LongLength - size)
                throw new InvalidDataException("PE truncado o desplazamiento fuera del archivo.");
        }
        private ushort U16(long p) { Range(p, 2); return BitConverter.ToUInt16(data, (int)p); }
        private uint U32(long p) { Range(p, 4); return BitConverter.ToUInt32(data, (int)p); }
        private ulong U64(long p) { Range(p, 8); return BitConverter.ToUInt64(data, (int)p); }
        private int Rva(uint rva, int size) {
            if (rva < headersSize) { Range(rva, size); return (int)rva; }
            for (int i = 0; i < count; i++) {
                int s = sections + i * 40;
                uint start = U32(s + 12), rawSize = U32(s + 16), raw = U32(s + 20);
                if (rva >= start && (ulong)rva - start < rawSize) {
                    long delta = (long)rva - start;
                    if (delta + size > rawSize) throw new InvalidDataException("RVA fuera de su seccion.");
                    long offset = raw + delta; Range(offset, size); return (int)offset;
                }
            }
            throw new InvalidDataException("RVA PE sin datos fisicos.");
        }
        private string Name(uint rva) {
            var bytes = new List<byte>();
            for (uint i = 0; i < 260; i++) {
                if ((ulong)rva + i > UInt32.MaxValue) break;
                byte c = data[Rva(rva + i, 1)];
                if (c == 0) {
                    string value = Encoding.ASCII.GetString(bytes.ToArray());
                    if (value.Length == 0 || value.IndexOfAny(new char[] {'\\','/',':','*','?','"','<','>','|'}) >= 0 ||
                        !value.EndsWith(".dll", StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Nombre de dependencia PE no admitido.");
                    return value;
                }
                if (c < 32 || c > 126) throw new InvalidDataException("Nombre PE no ASCII.");
                bytes.Add(c);
            }
            throw new InvalidDataException("Nombre PE sin terminador.");
        }
        private string[] ReadImports(int directory, bool delayed) {
            var result = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (directory >= directoryCount) return new string[0];
            uint start = U32(directories + directory * 8), size = U32(directories + directory * 8 + 4);
            if (start == 0 && size == 0) return new string[0];
            int stride = delayed ? 32 : 20;
            if (start == 0 || size < stride || size > 1024 * 1024) throw new InvalidDataException("Tabla de importacion PE invalida.");
            for (uint delta = 0; (ulong)delta + (uint)stride <= size; delta += (uint)stride) {
                if ((ulong)start + delta > UInt32.MaxValue) throw new InvalidDataException("RVA PE desbordada.");
                int p = Rva(start + delta, stride);
                bool empty = true;
                for (int j = 0; j < stride; j += 4) if (U32(p + j) != 0) empty = false;
                if (empty) break;
                uint name = U32(p + (delayed ? 4 : 12));
                if (delayed && (U32(p) & 1) == 0) {
                    if ((ulong)name < imageBase || (ulong)name - imageBase > UInt32.MaxValue)
                        throw new InvalidDataException("Direccion diferida PE invalida.");
                    name = (uint)((ulong)name - imageBase);
                }
                if (name == 0) throw new InvalidDataException("Descriptor PE sin nombre.");
                result.Add(Name(name));
                if (result.Count > 4096) throw new InvalidDataException("Demasiadas dependencias PE.");
            }
            var names = new string[result.Count]; result.CopyTo(names); Array.Sort(names, StringComparer.OrdinalIgnoreCase); return names;
        }
        public static PeDependencyInfoV1 Read(string path) {
            var reader = new PeDependencyReaderV1();
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
                if (stream.Length < 64 || stream.Length > 128L * 1024 * 1024) throw new InvalidDataException("Tamano PE no admitido.");
                reader.data = new byte[(int)stream.Length];
                int offset = 0, read;
                while (offset < reader.data.Length && (read = stream.Read(reader.data, offset, reader.data.Length - offset)) > 0) offset += read;
                if (offset != reader.data.Length) throw new EndOfStreamException();
            }
            if (reader.U16(0) != 0x5a4d) throw new InvalidDataException("Falta cabecera MZ.");
            uint peValue = reader.U32(0x3c);
            reader.Range(peValue, 24); int pe = (int)peValue;
            if (reader.U32(pe) != 0x4550) throw new InvalidDataException("Firma PE invalida.");
            reader.count = reader.U16(pe + 6);
            if (reader.count < 1 || reader.count > 96) throw new InvalidDataException("Numero de secciones PE invalido.");
            reader.optionalSize = reader.U16(pe + 20); reader.optional = pe + 24;
            reader.Range(reader.optional, reader.optionalSize);
            ushort magic = reader.U16(reader.optional);
            int prefix = magic == 0x20b ? 112 : magic == 0x10b ? 96 : 0;
            if (prefix == 0 || reader.optionalSize < prefix) throw new InvalidDataException("Formato PE no admitido.");
            reader.headersSize = reader.U32(reader.optional + 60);
            reader.imageBase = magic == 0x20b ? reader.U64(reader.optional + 24) : reader.U32(reader.optional + 28);
            uint num = reader.U32(reader.optional + prefix - 4);
            if (num > (reader.optionalSize - prefix) / 8) throw new InvalidDataException("Directorios PE fuera de cabecera.");
            reader.directoryCount = (int)num; reader.directories = reader.optional + prefix;
            reader.sections = reader.optional + reader.optionalSize; reader.Range(reader.sections, reader.count * 40);
            return new PeDependencyInfoV1 { Machine = reader.U16(pe + 4), Imports = reader.ReadImports(1, false), DelayImports = reader.ReadImports(13, true) };
        }
    }
}
'@ -ErrorAction Stop
    }
    return [AIOUpdate.PeDependencyReaderV1]::Read($Path)
}

function Test-AIOUpdatePeMachineMatch {
    [CmdletBinding()]
    param([int]$Expected, [int]$Actual)
    # ARM64X contiene la vista nativa ARM64. No aceptar x86/x64 por emulacion
    # para reparar un componente nativo de WinPE.
    return ($Expected -eq $Actual -or ($Expected -in @(0xAA64, 0xA64E) -and $Actual -in @(0xAA64, 0xA64E)))
}

function Get-AIOUpdateRecoveryDependencyLocations {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Name)
    # Stable component locations, not rules per KB/build. Unknown imports are
    # diagnostic evidence only; this is not a replacement for the Windows loader.
    switch ($Name.ToLowerInvariant()) {
        'unbcl.dll' { @('Windows\System32\migwiz\unbcl.dll', 'Windows\System32\unbcl.dll') }
        'wlanapi.dll' { @('Windows\System32\wlanapi.dll') }
        'mobilenetworking.dll' { @('Windows\System32\mobilenetworking.dll') }
    }
}

function Get-AIOUpdateMissingRecoveryDependencies {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MountPath, [AllowEmptyCollection()] [string[]]$AdditionalFiles = @())
    $system32 = Join-Path $MountPath 'Windows\System32'
    $files = @(
        foreach ($relative in @('sources\recovery','Windows\System32\Recovery')) {
            $root = Join-Path $MountPath $relative
            if (Test-Path -LiteralPath $root -PathType Container) {
                Get-ChildItem -LiteralPath $root -File -ErrorAction Stop | Where-Object Extension -in @('.exe','.dll') | ForEach-Object FullName
            }
        }
        $AdditionalFiles
    ) | Sort-Object -Unique
    $missing = @{}
    foreach ($file in $files) {
        $info = Get-AIOUpdatePeDependencyInfo -Path $file
        foreach ($name in @($info.Imports) + @($info.DelayImports)) {
            if ($name -match '(?i)^(api|ext)-ms-') { continue }
            if ($name -match '[\\/:*?"<>|\x00-\x1f]' -or $name -notmatch '(?i)\.dll$') { throw "Importacion PE invalida en '$file': '$name'." }
            $found = $false; $wrongMachine = $false
            foreach ($directory in @((Split-Path -Parent $file),$system32) | Select-Object -Unique) {
                $candidate = Join-Path $directory $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    $candidateInfo = Get-AIOUpdatePeDependencyInfo -Path $candidate
                    if (Test-AIOUpdatePeMachineMatch -Expected $info.Machine -Actual $candidateInfo.Machine) { $found = $true }
                    else { $wrongMachine = $true }
                    # The first file in the effective local search must be correct.
                    break
                }
            }
            if ($found) { continue }
            # A filename somewhere in WinSxS is not proof of manifest redirection.
            # Do not traverse WinSxS or protected log directories to infer resolution.
            $required = $name -in @($info.Imports)
            if ($missing.ContainsKey($name)) {
                if (-not (Test-AIOUpdatePeMachineMatch -Expected $missing[$name].Machine -Actual $info.Machine)) { throw "Dependencia '$name' solicitada por arquitecturas distintas." }
                $missing[$name].Required = $missing[$name].Required -or $required
                $missing[$name].WrongArchitecture = $missing[$name].WrongArchitecture -or $wrongMachine
            }
            else {
                $missing[$name] = [pscustomobject]@{
                    Name = $name; Machine = [int]$info.Machine; Required = $required; RequestedBy = $file
                    WrongArchitecture = $wrongMachine; RepairSupported = (@(Get-AIOUpdateRecoveryDependencyLocations -Name $name).Count -gt 0)
                }
            }
        }
    }
    [object[]]@($missing.Values | Sort-Object Name)
}

function Find-AIOUpdateRecoveryDependencySource {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$ImageRoot, [Parameter(Mandatory = $true)] [string]$Name, [Parameter(Mandatory = $true)] [int]$Machine)
    if ($Name -match '[\\/:*?"<>|\x00-\x1f]' -or $Name -notmatch '(?i)\.dll$') { throw "Nombre de dependencia invalido: '$Name'." }
    foreach ($relative in @(Get-AIOUpdateRecoveryDependencyLocations -Name $Name)) {
        $candidate = Join-Path $ImageRoot $relative
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $info = Get-AIOUpdatePeDependencyInfo -Path $candidate
        if (Test-AIOUpdatePeMachineMatch -Expected $Machine -Actual $info.Machine) { return $candidate }
    }
    return $null
}

function Repair-AIOUpdateRecoveryDependencies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [AllowNull()] [string]$InstallWim,
        [AllowEmptyCollection()] [int[]]$InstallIndexes = @(),
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$StagingRoot
    )
    $missing = @(Get-AIOUpdateMissingRecoveryDependencies -MountPath $MountPath)
    $copied = New-Object System.Collections.Generic.List[object]
    $reported = @{}
    $mounted = $false
    $sourceRoot = $null
    $donorMount = Join-Path $StagingRoot 'RecoveryDependencySource'
    $system32 = Join-Path $MountPath 'Windows\System32'
    try {
        while ($missing.Count) {
            $supported = @()
            foreach ($dependency in $missing) {
                if (-not $dependency.RepairSupported -or -not $dependency.Required) {
                    if (-not $reported.ContainsKey($dependency.Name)) {
                        $reported[$dependency.Name] = $true
                        $state = if ($dependency.Required) { 'DependencyNeedsRuntimeValidation' } else { 'OptionalDependencyNotCopied' }
                        Add-AIOUpdateMaintenanceRecord -Context 'Dependencias de recuperacion' -State $state -Reason "Importacion $($dependency.Name); requerido por $($dependency.RequestedBy). No se infiere resolucion SxS ni se copia automaticamente una dependencia no verificada."
                        if ($dependency.Required) { Write-Host "   [AVISO] Dependencia para validar al arrancar WinPE: $($dependency.Name). Consulta el reporte." -ForegroundColor Yellow }
                    }
                    continue
                }
                if ($dependency.WrongArchitecture) { throw "Arquitectura incorrecta en una dependencia existente: $($dependency.Name). No se sustituira automaticamente." }
                $supported += $dependency
            }
            if (-not $supported.Count) { break }
            if (-not $sourceRoot) {
                if (-not $InstallWim -or -not $InstallIndexes.Count) { throw 'Falta install.wim para las dependencias de recuperacion conocidas.' }
                $targetVersion = Get-AIOUpdateExecutableVersion -Path (Join-Path $system32 'ntdll.dll')
                if (-not $targetVersion) { throw 'No se pudo verificar la version binaria de WinPE.' }
                foreach ($donor in @(Get-AIOUpdateImageMetadata -ImagePath $InstallWim | Where-Object {
                    [int]$_.ImageIndex -in $InstallIndexes -and (Convert-AIOUpdateArchitectureName -Architecture $_.Architecture) -eq $Architecture
                })) {
                    $cachedNtdll = Get-AIOUpdateCachedWimFile -WimPath $InstallWim -Index $donor.ImageIndex -ImagePath 'Windows\System32\ntdll.dll' -ScratchPath $ScratchPath -StagingRoot $StagingRoot
                    if ($cachedNtdll) {
                        $sourceVersion = Get-AIOUpdateExecutableVersion -Path $cachedNtdll
                        $nativeInfo = Get-AIOUpdatePeDependencyInfo -Path $cachedNtdll
                        if ($sourceVersion -and $sourceVersion -eq $targetVersion -and
                            (Test-AIOUpdatePeMachineMatch -Expected $supported[0].Machine -Actual $nativeInfo.Machine)) {
                            $sourceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $cachedNtdll))
                            break
                        }
                        continue
                    }
                    Mount-AIOUpdateImage -ImagePath $InstallWim -Index $donor.ImageIndex -MountPath $donorMount -ScratchPath $ScratchPath -Context 'Leer fuente de dependencias de recuperacion' -ReadOnly
                    $mounted = $true
                    $sourceVersion = Get-AIOUpdateExecutableVersion -Path (Join-Path $donorMount 'Windows\System32\ntdll.dll')
                    if ($sourceVersion -and $sourceVersion -eq $targetVersion) { $sourceRoot = $donorMount; break }
                    [void](Dismount-AIOUpdateImage -MountPath $donorMount -Mode Discard -Context 'Cerrar fuente de distinta version binaria')
                    $mounted = $false
                }
                if (-not $sourceRoot) { throw 'No hay fuente de dependencias con la misma arquitectura y version binaria que WinPE.' }
            }
            foreach ($dependency in $supported) {
                if (@($copied | Where-Object Name -eq $dependency.Name).Count) { throw "La copia de $($dependency.Name) no resolvio su ubicacion; requiere revision." }
                if (-not $mounted) {
                    foreach ($location in @(Get-AIOUpdateRecoveryDependencyLocations -Name $dependency.Name)) {
                        $cachedFile = Get-AIOUpdateCachedWimFile -WimPath $InstallWim -Index $donor.ImageIndex -ImagePath $location -ScratchPath $ScratchPath -StagingRoot $StagingRoot
                        if ($cachedFile -and (Test-AIOUpdatePeMachineMatch -Expected $dependency.Machine -Actual (Get-AIOUpdatePeDependencyInfo -Path $cachedFile).Machine)) { break }
                    }
                }
                $source = Find-AIOUpdateRecoveryDependencySource -ImageRoot $sourceRoot -Name $dependency.Name -Machine $dependency.Machine
                if (-not $source -and -not $mounted) {
                    Mount-AIOUpdateImage -ImagePath $InstallWim -Index $donor.ImageIndex -MountPath $donorMount -ScratchPath $ScratchPath -Context 'Leer fuente de dependencias de recuperacion (respaldo)' -ReadOnly
                    $mounted = $true
                    $sourceVersion = Get-AIOUpdateExecutableVersion -Path (Join-Path $donorMount 'Windows\System32\ntdll.dll')
                    if (-not $sourceVersion -or $sourceVersion -ne $targetVersion) { throw 'La fuente de respaldo no coincide con la version binaria de WinPE.' }
                    $sourceRoot = $donorMount
                    $source = Find-AIOUpdateRecoveryDependencySource -ImageRoot $sourceRoot -Name $dependency.Name -Machine $dependency.Machine
                }
                if (-not $source) {
                    $reason = "Dependencia requerida '$($dependency.Name)' no disponible en sus ubicaciones de componente conocidas. Solicitada por '$($dependency.RequestedBy)'."
                    Add-AIOUpdateMaintenanceRecord -Context 'Dependencias de recuperacion' -State 'RequiredDependencyUnavailable' -Reason $reason
                    throw $reason
                }
                $destination = Join-Path $system32 $dependency.Name
                if (Test-Path -LiteralPath $destination) { throw "La dependencia $($dependency.Name) ya existe; no se sobrescribira." }
                [void](Copy-AIOUpdateSetupDUFile -Source $source -Destination $destination)
                $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256 -ErrorAction Stop).Hash
                if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $hash) { throw "Fallo SHA-256 de $($dependency.Name)." }
                $relative = $source.Substring($sourceRoot.Length).TrimStart('\','/')
                [void]$copied.Add([pscustomobject]@{ Name = $dependency.Name; RelativePath = ('Windows\System32\'+$dependency.Name); SHA256 = $hash; SourceIndex = $donor.ImageIndex; SourceVersion = [string]$sourceVersion; SourceRelativePath = $relative; RequestedBy = $dependency.RequestedBy })
                Add-AIOUpdateMaintenanceRecord -Context 'Dependencias de recuperacion' -State 'CopiedMissingDependency' -Performed $true -Reason "$($dependency.Name); origen=$relative; indice=$($donor.ImageIndex); SHA256=$hash; requerido por $($dependency.RequestedBy)."
            }
            $missing = @(Get-AIOUpdateMissingRecoveryDependencies -MountPath $MountPath -AdditionalFiles @($copied | ForEach-Object { Join-Path $MountPath $_.RelativePath }))
        }
        [object[]]$copied.ToArray()
    }
    finally {
        if ($mounted) { [void](Dismount-AIOUpdateImage -MountPath $donorMount -Mode Discard -Context 'Cerrar lectura de dependencias de recuperacion') }
    }
}

function Assert-AIOUpdateRecoveryDependencyCopies {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [AllowEmptyCollection()] [object[]]$Copies
    )
    foreach ($copy in $Copies) {
        $path = Join-Path $MountPath $copy.RelativePath
        if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash -ne $copy.SHA256) {
            throw "La dependencia '$($copy.Name)' no se conservo correctamente tras guardar boot.wim."
        }
    }
}


function Update-AIOUpdateBootWim {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$BootWim,
        [string]$InstallWim,
        [AllowEmptyCollection()] [int[]]$InstallIndexes = @(),
        [Parameter(Mandatory = $true)] [object[]]$Images,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [string]$BootMount,
        [Parameter(Mandatory = $true)] [string]$ScratchPath,
        [Parameter(Mandatory = $true)] [string]$CaptureRoot,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$SetupDUPackages,
        [switch]$IntegrateSetupDU,
        [bool]$VerifyPrePostCommit = $true,
        [Parameter(Mandatory = $true)] [System.Collections.IList]$VerificationReports
    )

    Initialize-AIOUpdateDirectory -Path $CaptureRoot -Empty
    $setupIndex = Get-AIOUpdateBootSetupIndex -Images $Images
    $captured = @{}
    $setupExtractRoot = $null

    if ($IntegrateSetupDU -and @($SetupDUPackages).Count -gt 0) {
        $setupExtractRoot = Join-Path $StagingRoot 'SetupDU_Boot'
        Expand-AIOUpdateSetupDU -Packages $SetupDUPackages -Destination $setupExtractRoot
    }

    $position = 0
    foreach ($image in $Images) {
        $position++
        $index = [int]$image.ImageIndex
        $architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
        $build = ([version]$image.Version).Build
        $mounted = $false

        try {
            Write-Host "`n=======================================================" -ForegroundColor DarkCyan
            Write-Host " BOOT.WIM $position/$($Images.Count) - INDICE $index" -ForegroundColor Cyan
            Write-Host "=======================================================" -ForegroundColor DarkCyan

            Mount-AIOUpdateImage -ImagePath $BootWim -Index $index -MountPath $BootMount -ScratchPath $ScratchPath -Context "Montando boot.wim indice $index"
            $mounted = $true
            $baseline = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
            $operations = New-Object System.Collections.Generic.List[object]

            $bootPackages = New-Object System.Collections.Generic.List[object]
            foreach ($package in @(
                Get-AIOUpdateEffectiveSsuPackages -Inventory $Inventory -Architecture $architecture -Build $build |
                    Where-Object { (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $architecture -Build $build -ImageName $image.ImageName).Compatible }
            )) { [void]$bootPackages.Add($package) }

            foreach ($category in $script:AIOUpdateBootCategoryOrder) {
                foreach ($package in @(Get-AIOUpdateCompatiblePackages -Inventory $Inventory -Category @($category) -Architecture $architecture -Build $build -ImageName $image.ImageName)) {
                    [void]$bootPackages.Add($package)
                }
            }

            $orderedBootPackages = Resolve-AIOUpdateCbsPackageOrder -Packages ([object[]]($bootPackages.ToArray())) -Context "boot.wim indice $index"
            $rejuvPrepared = $false
            $currentInventory = $baseline
            foreach ($package in $orderedBootPackages) {
                if ($package.Category -eq 'LCU' -and -not $rejuvPrepared) {
                    $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                    foreach ($entry in @(Remove-AIOUpdateWinPERejuv -MountPath $BootMount -ScratchPath $ScratchPath -InstalledInventory $currentInventory)) {
                        [void]$operations.Add($entry)
                    }
                    $currentInventory = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                    $rejuvPrepared = $true
                }

                foreach ($entry in @(Add-AIOUpdatePackageList -MountPath $BootMount -Packages @($package) -ScratchPath $ScratchPath -Context "Boot indice ${index}: $($package.Category)" -AllowNotApplicable -InstalledInventory $currentInventory -DependencyContext "boot.wim indice $index")) {
                    [void]$operations.Add($entry)
                }
            }

            if ($index -eq $setupIndex -and $setupExtractRoot) {
                # Dependencias opcionales de SetupDU: se detectan por presencia
                # real en WinPE y por ausencia en el payload, nunca por build.
                foreach ($dependency in $script:AIOUpdateSetupDependencySpecs) {
                    $alreadyIncluded = @(Get-ChildItem -LiteralPath $setupExtractRoot -Recurse -File -Filter $dependency.Name -ErrorAction SilentlyContinue).Count -gt 0
                    if ($alreadyIncluded) { continue }
                    $sourceDependency = $null
                    foreach ($relative in $dependency.Candidates) {
                        $candidate = Join-Path $BootMount $relative
                        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                            $sourceDependency = $candidate
                            break
                        }
                    }
                    if ($sourceDependency) {
                        Copy-Item -LiteralPath $sourceDependency -Destination (Join-Path $setupExtractRoot $dependency.Name) -Force -ErrorAction Stop
                        Write-AIOUpdateLog -Level INFO -Message "SetupDU: dependencia agregada desde WinPE por presencia real: $($dependency.Name)."
                    }
                }
                $merged = Merge-AIOUpdateSetupDUIntoDirectory -ExtractRoot $setupExtractRoot -DestinationRoot (Join-Path $BootMount 'sources')
                $duResult = [pscustomobject]@{ Success = $true; State = 'Success'; ExitCode = 0; UnsignedCode = [uint32]0; Context = 'SetupDU integrado en boot.wim Setup' }
                [void]$operations.Add([pscustomobject]@{
                    Package = [pscustomobject]@{ Name = "SetupDU ($merged archivos)"; Category = 'SetupDU' }
                    Result  = $duResult
                })
                Write-AIOUpdateLog -Level INFO -Message "SetupDU integrado en boot.wim indice ${index}: $merged archivo(s)."
            }

            $recoveryCopies = @(Repair-AIOUpdateRecoveryDependencies -MountPath $BootMount -InstallWim $InstallWim -InstallIndexes $InstallIndexes -Architecture $architecture -ScratchPath $ScratchPath -StagingRoot $StagingRoot)

            [void](Invoke-AIOUpdateCleanup -MountPath $BootMount -ScratchPath $ScratchPath -Context "Boot indice ${index}: limpieza WinPE" -ResetBase -WarningOnly)

            if ($index -eq $setupIndex) {
                # Capturar solo los ejecutables de Setup que deben coincidir
                # entre boot.wim y el medio. La carpeta sources del WinPE incluye
                # contenido interno (como recovery) que no debe exportarse entero.
                # Catalogo centralizado: si Microsoft agrega/cambia un binario
                # sincronizable, se mantiene una sola lista en la cabecera.
                foreach ($spec in $script:AIOUpdateBootCaptureFileSpecs) {
                    Save-AIOUpdateBootFile -MountPath $BootMount -Candidates $spec.Candidates -CaptureRoot $CaptureRoot -Key $spec.Key -CaptureTable $captured
                }
                foreach ($spec in $script:AIOUpdateSetupDependencySpecs) {
                    Save-AIOUpdateBootFile -MountPath $BootMount -Candidates $spec.Candidates -CaptureRoot $CaptureRoot -Key $spec.Key -CaptureTable $captured
                }
                foreach ($spec in $script:AIOUpdateBootCaptureDirectorySpecs) {
                    Save-AIOUpdateBootDirectory -MountPath $BootMount -RelativePath $spec.RelativePath -CaptureRoot $CaptureRoot -Key $spec.Key -CaptureTable $captured
                }
            }

            if ($VerifyPrePostCommit) {
                $after = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                $preReport = New-AIOUpdateVerificationReport -Target "boot.wim indice $index" -Phase 'PreCommit' -Before $baseline -After $after -OperationResults ([object[]]($operations.ToArray()))
                [void]$VerificationReports.Add($preReport)
                Write-AIOUpdateVerificationReport -Report $preReport
                if (-not $preReport.Success) { throw "Fallo la verificacion previa al commit de boot.wim indice $index." }
            }
            else {
                Write-AIOUpdateLog -Level INFO -Message "Boot indice ${index}: verificaciones Pre/Post-Commit omitidas por configuracion."
            }

            [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Commit -Context "Guardando boot.wim indice $index")
            $mounted = $false

            if ($VerifyPrePostCommit) {
                Mount-AIOUpdateImage -ImagePath $BootWim -Index $index -MountPath $BootMount -ScratchPath $ScratchPath -Context "Verificando boot.wim indice $index" -ReadOnly
                $mounted = $true
                Assert-AIOUpdateRecoveryDependencyCopies -MountPath $BootMount -Copies $recoveryCopies
                $post = @(Get-AIOUpdateMountedPackageInventory -MountPath $BootMount -Strict)
                $postReport = New-AIOUpdateVerificationReport -Target "boot.wim indice $index" -Phase 'PostCommit' -Before $baseline -After $post -OperationResults ([object[]]($operations.ToArray()))
                [void]$VerificationReports.Add($postReport)
                Write-AIOUpdateVerificationReport -Report $postReport
                if (-not $postReport.Success) { throw "Fallo la verificacion posterior al commit de boot.wim indice $index." }

                if ($index -eq $setupIndex) {
                    try {
                        $localeVerification = Assert-AIOUpdateSetupLanguagesPreserved -MountPath $BootMount -AllowedLocales @($script:AIOUpdateTrustedLocales.Keys) -Context "Verificacion de idiomas de Setup en boot.wim indice $index"
                        $localeReport = New-AIOUpdateSetupLanguageReport -Target "boot.wim indice $index" -Phase 'PostCommit' -Verification $localeVerification
                        [void]$VerificationReports.Add($localeReport)
                        Write-AIOUpdateVerificationReport -Report $localeReport
                    }
                    catch {
                        $localeReport = New-AIOUpdateSetupLanguageReport -Target "boot.wim indice $index" -Phase 'PostCommit' -ErrorMessage $_.Exception.Message
                        [void]$VerificationReports.Add($localeReport)
                        Write-AIOUpdateVerificationReport -Report $localeReport
                        throw
                    }
                }
                [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context "Cerrando verificacion de boot.wim indice $index")
                $mounted = $false
            }
        }
        finally {
            if ($mounted) {
                [void](Dismount-AIOUpdateImage -MountPath $BootMount -Mode Discard -Context "Descarte de emergencia de boot.wim indice $index" -NoThrow)
            }
        }
    }

    return $captured
}


function New-AIOUpdateSetupLanguageReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Target,
        [Parameter(Mandatory = $true)] [string]$Phase,
        [AllowNull()] [psobject]$Verification,
        [AllowNull()] [string]$ErrorMessage
    )

    $success = $null -ne $Verification -and [bool]$Verification.Success -and [string]::IsNullOrWhiteSpace($ErrorMessage)
    $details = New-Object System.Collections.Generic.List[string]
    $verified = New-Object System.Collections.Generic.List[object]
    $missing = New-Object System.Collections.Generic.List[object]

    if ($success) {
        $locales = @($Verification.Locales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        $langIniLocales = @($Verification.LangIniLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
        [void]$details.Add("TrustedLocales preservados: $($locales -join ', ')")
        [void]$details.Add("sources\lang.ini: $($langIniLocales -join ', ')")

        foreach ($check in @($Verification.ResourceChecks | Where-Object { $null -ne $_ })) {
            $coreFiles = @($check.CoreFiles | ForEach-Object { [string]$_ } | Where-Object { $_ })
            [void]$details.Add("$($check.Locale): $($check.MuiCount) MUI; esenciales: $($coreFiles -join ', ')")
            [void]$verified.Add([pscustomobject]@{
                Package  = "Recursos de Windows Setup $($check.Locale)"
                Category = 'SetupLanguageResources'
                Success  = $true
                Status   = 'Verified'
                Reason   = 'lang.ini y recursos MUI presentes despues del mantenimiento'
            })
        }

        $reason = "TrustedLocales, lang.ini y recursos MUI de Windows Setup preservados: $($locales -join ', ')"
    }
    else {
        $message = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { 'La verificacion de idiomas de Windows Setup no produjo evidencia valida.' } else { $ErrorMessage }
        [void]$details.Add($message)
        [void]$missing.Add([pscustomobject]@{
            Package  = 'TrustedLocales de Windows Setup'
            Category = 'SetupLanguageResources'
            Success  = $false
            Status   = 'Missing'
            Reason   = $message
        })
        $reason = $message
    }

    return [pscustomobject]@{
        Kind                     = 'SetupLanguagePreservation'
        Target                   = $Target
        Phase                    = $Phase
        Success                  = $success
        Reason                   = $reason
        BeforeCount              = 0
        AfterCount               = 0
        BeforeActive             = 0
        AfterActive              = 0
        NewPackages              = [object[]]@()
        RetiredPackages          = [object[]]@()
        SemanticEvidence         = [object[]]$verified.ToArray()
        VerifiedExpected         = [object[]]$verified.ToArray()
        MissingExpected          = [object[]]$missing.ToArray()
        Indeterminate            = [object[]]@()
        RejuvWarnings            = [object[]]@()
        ObservedServicingVersion = [version]'0.0.0.0'
        Failed                   = if ($success) { 0 } else { 1 }
        Details                  = [string[]]$details.ToArray()
        Timestamp                = Get-Date
    }
}


function Assert-AIOUpdateSetupLanguagesPreserved {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MountPath,
        [Parameter(Mandatory = $true)] [string[]]$AllowedLocales,
        [Parameter(Mandatory = $true)] [string]$Context
    )

    $normalizedLocales = @($AllowedLocales | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    if ($normalizedLocales.Count -eq 0) { throw "${Context}: no hay TrustedLocales para verificar." }

    $langIni = Join-Path $MountPath 'sources\lang.ini'
    $langIniLocales = @(Get-AIOUpdateLocalesFromLangIniPath -Path $langIni | ForEach-Object { ([string]$_).ToLowerInvariant() })
    $missingLangIni = @($normalizedLocales | Where-Object { $_ -notin $langIniLocales })
    if ($missingLangIni.Count -gt 0) {
        throw "${Context}: boot.wim perdio idiomas en sources\lang.ini: $($missingLangIni -join ', ')."
    }

    $checks = New-Object System.Collections.Generic.List[object]
    foreach ($locale in $normalizedLocales) {
        $localeRoot = Join-Path $MountPath "sources\$locale"
        $muiFiles = if (Test-Path -LiteralPath $localeRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $localeRoot -File -Filter '*.mui' -ErrorAction SilentlyContinue)
        }
        else { @() }
        $coreCandidates = $script:AIOUpdateSetupCoreMuiCandidates
        $coreFiles = @($coreCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $localeRoot $_) -PathType Leaf })
        if ($muiFiles.Count -eq 0 -or $coreFiles.Count -eq 0) {
            throw "${Context}: faltan recursos MUI esenciales de Setup para $locale despues de aplicar actualizaciones."
        }
        [void]$checks.Add([pscustomobject]@{ Locale = $locale; MuiCount = $muiFiles.Count; CoreFiles = [string[]]$coreFiles })
    }

    Write-AIOUpdateLog -Level INFO -Message "${Context}: lang.ini y recursos MUI preservados para $($normalizedLocales -join ', ')."
    return [pscustomobject]@{
        Context = $Context
        Locales = [string[]]$normalizedLocales
        LangIniLocales = [string[]]$langIniLocales
        ResourceChecks = [object[]]$checks.ToArray()
        Success = $true
    }
}

function Invoke-AIOUpdateSetupDUExpand {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string[]]$Arguments)

    $ErrorActionPreference = 'Continue'
    $global:LASTEXITCODE = $null
    $output = & $script:AIOUpdateExpandPath @Arguments 2>&1
    $exitCode = $global:LASTEXITCODE
    $detail = ($output | Out-String).Trim()
    Write-AIOUpdateLog -Level INFO -Message "SetupDU/expand.exe: codigo=$exitCode; $detail"
    if ($null -eq $exitCode -or $exitCode -ne 0) {
        throw "No se pudo extraer SetupDU (codigo '${exitCode}'): $detail"
    }
}

function Expand-AIOUpdateSetupDU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$Destination
    )

    Initialize-AIOUpdateDirectory -Path $Destination -Empty
    foreach ($package in @($Packages | Where-Object { $null -ne $_ })) {
        if (-not (Test-Path -LiteralPath $package.FullName -PathType Leaf)) { throw "No existe SetupDU '$($package.FullName)'." }
        if ($package.Extension -eq '.cab') {
            Invoke-AIOUpdateSetupDUExpand -Arguments @('-R', '-F:*', $package.FullName, $Destination)
        }
        elseif ($package.Extension -eq '.msu') {
            $inner = Join-Path $Destination ('MSU_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Initialize-AIOUpdateDirectory -Path $inner
            Invoke-AIOUpdateSetupDUExpand -Arguments @('-F:*.cab', $package.FullName, $inner)
            $cabs = @(Get-ChildItem -LiteralPath $inner -Filter '*.cab' -File -ErrorAction Stop | Where-Object { $_.Name -ine 'WSUSSCAN.cab' })
            if ($cabs.Count -eq 0) { throw "SetupDU '$($package.Name)' no contiene CAB de contenido." }
            foreach ($cab in $cabs) {
                Invoke-AIOUpdateSetupDUExpand -Arguments @('-R', '-F:*', $cab.FullName, $Destination)
            }
            Remove-Item -LiteralPath $inner -Recurse -Force -ErrorAction Stop
        }
        else { throw "Formato SetupDU no compatible: '$($package.Name)'." }
    }
    if (@($Packages | Where-Object { $null -ne $_ }).Count -gt 0) {
        $payload = @(Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction Stop | Where-Object {
            $_.Name -notin @('update.mum', 'update.cat', 'WSUSSCAN.cab')
        })
        if ($payload.Count -eq 0) { throw 'La extraccion SetupDU no produjo archivos de contenido.' }
    }
}

function Apply-AIOUpdateSetupDU {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [AllowNull()] [AllowEmptyCollection()] [object[]]$Packages,
        [Parameter(Mandatory = $true)] [string]$StagingRoot,
        [AllowNull()] [hashtable]$DependencyFiles
    )

    if (@($Packages).Count -eq 0) {
        return [pscustomobject]@{ Applied = $false; Copied = @(); Verified = $true }
    }

    Write-Host "`n=======================================================" -ForegroundColor DarkCyan
    Write-Host ' APLICANDO SETUP DYNAMIC UPDATE' -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor DarkCyan

    $extractRoot = Join-Path $StagingRoot 'SetupDU_Media'
    Expand-AIOUpdateSetupDU -Packages $Packages -Destination $extractRoot

    if ($DependencyFiles) {
        foreach ($entry in $script:AIOUpdateSetupDependencySpecs) {
            if (-not $DependencyFiles.ContainsKey($entry.Key)) { continue }
            $alreadyIncluded = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -Filter $entry.Name -ErrorAction SilentlyContinue).Count -gt 0
            if (-not $alreadyIncluded -and (Test-Path -LiteralPath $DependencyFiles[$entry.Key] -PathType Leaf)) {
                Copy-Item -LiteralPath $DependencyFiles[$entry.Key] -Destination (Join-Path $extractRoot $entry.Name) -Force -ErrorAction Stop
                Write-AIOUpdateLog -Level INFO -Message "SetupDU del medio: dependencia agregada: $($entry.Name)."
            }
        }
    }

    $sourcesRoot = Join-Path $MediaRoot 'sources'
    $copied = New-Object System.Collections.Generic.List[object]

    foreach ($file in @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -ErrorAction Stop)) {
        $relative = $file.FullName.Substring($extractRoot.Length).TrimStart('\')
        if ($relative -match '^(?i)sources[\\/](.+)$') { $relative = $Matches[1] }
        if ($relative -match '(?i)(?:^|[\\/])(update\.mum|update\.cat|WSUSSCAN\.cab)$') { continue }
        if (-not (Test-AIOUpdateLocaleRelativePathAllowed -RelativePath $relative -Surface Sources)) {
            Write-AIOUpdateLog -Level INFO -Message "SetupDU/medio: se omitio idioma ausente del Preflight: $relative"
            continue
        }
        $destination = Join-Path $sourcesRoot $relative
        $copyArgs = @{
            Source      = $file.FullName
            Destination = $destination
        }
        # fuerza los INI; para binarios se evita degradar una version mas nueva.
        if ($file.Extension -ine '.ini') { $copyArgs.OnlyIfNewer = $true }
        $result = Copy-AIOUpdateFileWithBackup @copyArgs
        if ($result) { [void]$copied.Add($result) }
    }

    $failures = @(
        $copied | Where-Object {
            $_.Copied -and (
                -not $_.Verified -or
                -not (Test-Path -LiteralPath $_.Destination -PathType Leaf) -or
                ((Get-FileHash -LiteralPath $_.Destination -Algorithm SHA256).Hash -ne $_.SourceHash)
            )
        }
    )
    if ($failures.Count -gt 0) { throw 'Fallo la verificacion SHA-256 de archivos SetupDU.' }

    return [pscustomobject]@{
        Applied  = $true
        Copied   = [object[]]($copied.ToArray())
        Verified = $true
    }
}


function Initialize-AIOUpdateEmbeddedSignatureApi {
    [CmdletBinding()]
    param()
    if ('AIOUpdates.EmbeddedSignatureV1' -as [type]) { return }
    # WTD_CHOICE_FILE checks the embedded PE signature. The catalog-first
    # Get-AuthenticodeSignature cmdlet cannot identify the UEFI signing family.
    # Keep the certificate tied to the same WinVerifyTrust state that was verified.
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;

namespace AIOUpdates {
    public sealed class EmbeddedSignatureResult {
        public int Code;
        public string Subject = "";
        public string Issuer = "";
        public string Thumbprint = "";
        public string CertificateError = "";
    }

    public static class EmbeddedSignatureV1 {
        [StructLayout(LayoutKind.Sequential)]
        private struct FileInfo {
            public uint Size;
            public IntPtr Path;
            public IntPtr File;
            public IntPtr KnownSubject;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct TrustData {
            public uint Size;
            public IntPtr PolicyCallback;
            public IntPtr SipClient;
            public uint UIChoice;
            public uint RevocationChecks;
            public uint UnionChoice;
            public IntPtr File;
            public uint StateAction;
            public IntPtr State;
            public IntPtr Url;
            public uint ProviderFlags;
            public uint UIContext;
            public IntPtr SignatureSettings;
        }
        // Only the leading fields are read; the provider owns the full structure.
        [StructLayout(LayoutKind.Sequential)]
        private struct ProviderCertificateHead {
            public uint Size;
            public IntPtr Certificate;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct CertificateContext {
            public uint Encoding;
            public IntPtr Encoded;
            public uint EncodedSize;
            public IntPtr Info;
            public IntPtr Store;
        }

        [DllImport("wintrust.dll", ExactSpelling = true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref TrustData data);
        [DllImport("wintrust.dll", ExactSpelling = true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern IntPtr WTHelperProvDataFromStateData(IntPtr state);
        [DllImport("wintrust.dll", ExactSpelling = true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern IntPtr WTHelperGetProvSignerFromChain(IntPtr provider, uint index,
            [MarshalAs(UnmanagedType.Bool)] bool counterSigner, uint counterIndex);
        [DllImport("wintrust.dll", ExactSpelling = true)]
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        private static extern IntPtr WTHelperGetProvCertFromChain(IntPtr signer, uint index);

        public static EmbeddedSignatureResult Verify(string path) {
            var result = new EmbeddedSignatureResult();
            var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            var data = new TrustData();
            IntPtr pathBuffer = IntPtr.Zero;
            IntPtr fileBuffer = IntPtr.Zero;
            bool verifyCalled = false;
            try {
                pathBuffer = Marshal.StringToCoTaskMemUni(System.IO.Path.GetFullPath(path));
                var file = new FileInfo();
                file.Size = (uint)Marshal.SizeOf(typeof(FileInfo));
                file.Path = pathBuffer;
                fileBuffer = Marshal.AllocHGlobal((int)file.Size);
                Marshal.StructureToPtr(file, fileBuffer, false);
                data.Size = (uint)Marshal.SizeOf(typeof(TrustData));
                data.UIChoice = 2; // WTD_UI_NONE
                data.UnionChoice = 1; // WTD_CHOICE_FILE, never WTD_CHOICE_CATALOG
                data.File = fileBuffer;
                data.StateAction = 1; // WTD_STATEACTION_VERIFY
                // Default Authenticode policy; no custom roots, hash-only mode,
                // ignored trust errors or changes to the certificate store.
                verifyCalled = true;
                result.Code = WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                try {
                    IntPtr provider = data.State == IntPtr.Zero ? IntPtr.Zero : WTHelperProvDataFromStateData(data.State);
                    IntPtr signer = provider == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvSignerFromChain(provider, 0, false, 0);
                    IntPtr certPointer = signer == IntPtr.Zero ? IntPtr.Zero : WTHelperGetProvCertFromChain(signer, 0);
                    if (certPointer == IntPtr.Zero) {
                        result.CertificateError = "El proveedor no devolvio el certificado del firmante incorporado.";
                    } else {
                        var head = (ProviderCertificateHead)Marshal.PtrToStructure(certPointer, typeof(ProviderCertificateHead));
                        if (head.Size < Marshal.SizeOf(typeof(ProviderCertificateHead)) || head.Certificate == IntPtr.Zero)
                            throw new InvalidDataException("Contexto del certificado incorporado incompleto.");
                        var cert = (CertificateContext)Marshal.PtrToStructure(head.Certificate, typeof(CertificateContext));
                        if (cert.Encoded == IntPtr.Zero || cert.EncodedSize == 0 || cert.EncodedSize > 1048576)
                            throw new InvalidDataException("Longitud del certificado incorporado no valida.");
                        var bytes = new byte[(int)cert.EncodedSize];
                        Marshal.Copy(cert.Encoded, bytes, 0, bytes.Length);
                        using (var certificate = new X509Certificate2(bytes)) {
                            result.Subject = certificate.Subject;
                            result.Issuer = certificate.Issuer;
                            result.Thumbprint = certificate.Thumbprint;
                        }
                    }
                } catch (Exception ex) {
                    result.CertificateError = ex.Message;
                }
                return result;
            } finally {
                try {
                    if (verifyCalled) {
                        data.StateAction = 2; // WTD_STATEACTION_CLOSE, also after failure
                        WinVerifyTrust(new IntPtr(-1), ref action, ref data);
                    }
                } finally {
                    if (fileBuffer != IntPtr.Zero) Marshal.FreeHGlobal(fileBuffer);
                    if (pathBuffer != IntPtr.Zero) Marshal.FreeCoTaskMem(pathBuffer);
                }
            }
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
}

function Invoke-AIOUpdateEmbeddedSignatureVerification {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)
    Initialize-AIOUpdateEmbeddedSignatureApi
    return [AIOUpdates.EmbeddedSignatureV1]::Verify($Path)
}

function Get-AIOUpdateBootSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)
    $result = [pscustomobject]@{
        Path = $Path
        Source = 'Embedded/WinVerifyTrust'
        Status = 'Missing'
        NativeCode = $null
        NativeCodeHex = ''
        Signer = 'Missing'
        Subject = ''
        Issuer = ''
        Thumbprint = ''
        Message = 'El archivo no existe.'
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $result.Signer = 'Unknown'
        try {
            $native = Invoke-AIOUpdateEmbeddedSignatureVerification -Path $Path
            $result.NativeCode = [int]$native.Code
            $result.NativeCodeHex = '0x{0:X8}' -f (Convert-AIOUpdateExitCodeToUInt32 -ExitCode $native.Code)
            $result.Subject = [string]$native.Subject
            $result.Issuer = [string]$native.Issuer
            $result.Thumbprint = [string]$native.Thumbprint
            $result.Status = 'VerificationFailed'
            $result.Message = 'Windows no pudo validar la firma incorporada.'
            switch ($result.NativeCodeHex) {
                '0x00000000' { $result.Status = 'Valid'; $result.Message = 'Firma incorporada validada por Windows.' }
                '0x80096010' { $result.Status = 'HashMismatch'; $result.Message = 'El contenido no coincide con la firma incorporada.' }
                '0x800B0100' { $result.Status = 'NotSigned'; $result.Message = 'No hay una firma incorporada verificable.' }
                '0x800B0109' { $result.Status = 'UntrustedRoot'; $result.Message = 'El equipo anfitrion no confia en la raiz del certificado.' }
                '0x800B010A' { $result.Status = 'IncompleteChain'; $result.Message = 'Windows no pudo construir la cadena de confianza.' }
                '0x800B0101' { $result.Status = 'Expired'; $result.Message = 'Windows rechazo la vigencia de la firma o de su certificado.' }
                '0x800B010C' { $result.Status = 'Revoked'; $result.Message = 'Windows rechazo un certificado revocado.' }
                '0x800B0111' { $result.Status = 'ExplicitDistrust'; $result.Message = 'Windows rechaza explicitamente esta firma.' }
            }
            if ($native.CertificateError) {
                $result.Message += ' ' + [string]$native.CertificateError
                if ($result.Status -eq 'Valid') { $result.Status = 'MissingSignerCertificate' }
            }
            if ($result.Status -eq 'Valid' -and -not [string]::IsNullOrWhiteSpace($result.Thumbprint)) {
                if ($result.Issuer -match '(?i)(?:^|,\s*)CN=Windows UEFI CA 2023(?:,|$)') { $result.Signer = 'CA2023' }
                elseif ($result.Issuer -match '(?i)(?:^|,\s*)CN=Microsoft Windows Production PCA 2011(?:,|$)') { $result.Signer = 'CA2011' }
            }
        }
        catch {
            $result.Status = 'VerifierError'
            $result.Signer = 'Unknown'
            $result.Message = $_.Exception.Message
        }
    }
    if ($null -eq $script:AIOUpdateBootSignatureResults) { $script:AIOUpdateBootSignatureResults = New-Object System.Collections.ArrayList }
    [void]$script:AIOUpdateBootSignatureResults.Add($result)
    $detail = Format-AIOUpdateBootSignature -Signature $result
    Write-AIOUpdateLog -Level INFO -Message "Firma de arranque: $detail"
    return $result
}

function Format-AIOUpdateBootSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Signature)
    return "Archivo='$($Signature.Path)'; origen=$($Signature.Source); estado=$($Signature.Status); codigo=$($Signature.NativeCodeHex); familia=$($Signature.Signer); emisor='$($Signature.Issuer)'; sujeto='$($Signature.Subject)'; huella=$($Signature.Thumbprint); $($Signature.Message)"
}

function Get-AIOUpdateBootSigner {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)
    return [string](Get-AIOUpdateBootSignature -Path $Path).Signer
}

function Assert-AIOUpdateBootSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path,
        [Parameter(Mandatory = $true)] [ValidateSet('CA2011','CA2023')] [string]$Policy)
    $signature = Get-AIOUpdateBootSignature -Path $Path
    if ($signature.Signer -ne $Policy) {
        throw "No se pudo acreditar la firma incorporada $Policy. $(Format-AIOUpdateBootSignature -Signature $signature)"
    }
}


function Assert-AIOUpdateMicrosoftBootSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$Path)
    # El bootmgr_EX.efi opcional no requiere Windows UEFI CA 2023.
    # Exigir una firma incorporada valida de Microsoft, sin equiparar roles.
    $signature = Get-AIOUpdateBootSignature -Path $Path
    if ($signature.Status -ne 'Valid' -or [string]::IsNullOrWhiteSpace($signature.Thumbprint) -or
        $signature.Subject -notmatch '(?i)(?:^|,\s*)O="?Microsoft Corporation"?(?:,|$)') {
        throw "No se pudo acreditar la firma Microsoft del archivo de arranque. $(Format-AIOUpdateBootSignature -Signature $signature)"
    }
}

function Resolve-AIOUpdateBootSigningPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot, [Parameter(Mandatory = $true)] [string]$EfiBootName,
        [ValidateSet('Preserve','CA2023','CA2011')] [string]$Policy = 'Preserve')
    if ($Policy -ne 'Preserve') { return $Policy }
    $signers = @()
    # bootmgr.efi en la raiz no determina la familia del cargador UEFI.
    foreach ($relative in @("efi\boot\$EfiBootName",'efi\boot\bootmgfw.efi')) {
        $path = Join-Path $MediaRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $signature = Get-AIOUpdateBootSignature -Path $path
        if ($signature.Signer -notin @('CA2011','CA2023')) {
            throw "No se pudo verificar la firma incorporada de '$relative'. $(Format-AIOUpdateBootSignature -Signature $signature)"
        }
        $signers += $signature.Signer
    }
    $unique = @($signers | Sort-Object -Unique)
    if ($unique.Count -ne 1) { throw 'El medio no tiene una familia UEFI unica verificable. Revisa sus cargadores EFI antes de continuar.' }
    return [string]$unique[0]
}

function Sync-AIOUpdateMediaBootFiles {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [hashtable]$CapturedFiles,
        [Parameter(Mandatory = $true)] [string]$Architecture,
        [ValidateSet('Preserve','CA2023','CA2011')] [string]$BootSigningPolicy = 'Preserve')
    if (-not $CapturedFiles.Count) { return @() }
    $architectureEntry = Get-AIOUpdateArchitectureCatalogEntry -Architecture $Architecture
    if (-not $architectureEntry -or -not $architectureEntry.EfiBootName) { throw 'Arquitectura sin nombre de arranque EFI definido.' }
    $efiBootName = [string]$architectureEntry.EfiBootName
    $policy = Resolve-AIOUpdateBootSigningPolicy -MediaRoot $MediaRoot -EfiBootName $efiBootName -Policy $BootSigningPolicy
    $is2023 = $policy -eq 'CA2023'
    $mgfw = if ($is2023) { 'BootMgfwExEfi' } else { 'BootMgfwEfi' }
    $mgr = if ($is2023) { 'BootMgrExEfi' } else { 'BootMgrEfi' }
    $efi = if ($is2023) { 'EfiSysEx' } else { 'EfiSys' }
    $noPrompt = if ($is2023) { 'EfiSysNoPromptEx' } else { 'EfiSysNoPrompt' }
    # El cargador UEFI y las imagenes de arranque optico mantienen la familia
    # elegida. Microsoft Make2023BootableMedia trata bootmgr_EX.efi como opcional
    # y aclara que no exige esa CA; nunca sustituirlo por bootmgfw_EX.efi.
    $map = @(
        [pscustomobject]@{ Key = $mgfw; Relative = "efi\boot\$efiBootName"; Signed = $true; MicrosoftSigned = $false }
    )
    if ($CapturedFiles.ContainsKey($mgr)) {
        $map += [pscustomobject]@{ Key = $mgr; Relative = 'bootmgr.efi'; Signed = $false; MicrosoftSigned = $true }
    }
    else {
        Add-AIOUpdateMaintenanceRecord -Context 'Arranque UEFI' -State 'OptionalBootFilePreserved' -Reason "$mgr no esta presente; se conserva bootmgr.efi conforme al tratamiento opcional de Microsoft."
    }
    foreach ($pair in @(
        [pscustomobject]@{ Key = $efi; Relative = 'efi\microsoft\boot\efisys.bin'; Signed = $false },
        [pscustomobject]@{ Key = $noPrompt; Relative = 'efi\microsoft\boot\efisys_noprompt.bin'; Signed = $false },
        [pscustomobject]@{ Key = $mgfw; Relative = 'efi\boot\bootmgfw.efi'; Signed = $true }
    )) { if (Test-Path -LiteralPath (Join-Path $MediaRoot $pair.Relative) -PathType Leaf) { $map += $pair } }
    foreach ($entry in $map) {
        if (-not $CapturedFiles.ContainsKey($entry.Key) -or -not (Test-Path -LiteralPath $CapturedFiles[$entry.Key] -PathType Leaf)) { throw "Falta $($entry.Key) para sincronizar el conjunto de arranque $policy." }
        if ($entry.Signed) { Assert-AIOUpdateBootSignature -Path $CapturedFiles[$entry.Key] -Policy $policy }
        elseif ($entry.MicrosoftSigned) { Assert-AIOUpdateMicrosoftBootSignature -Path $CapturedFiles[$entry.Key] }
        if ($entry.Signed -or $entry.MicrosoftSigned) {
            $sourceVersion = Get-AIOUpdateExecutableVersion -Path $CapturedFiles[$entry.Key]
            $destination = Join-Path $MediaRoot $entry.Relative
            $targetVersion = Get-AIOUpdateExecutableVersion -Path $destination
            if (-not $sourceVersion -or ($targetVersion -and $sourceVersion -lt $targetVersion)) { throw "El conjunto de arranque $policy tiene version desconocida o anterior al medio: $($entry.Key)." }
        }
    }
    # All checks above happen before the first replacement. Preflight covers
    # rollback if a later write fails. Force the coherent set, regardless of dates.
    $results = New-Object System.Collections.Generic.List[object]
    foreach ($spec in $script:AIOUpdateSetupMediaSyncSpecs) {
        if ($CapturedFiles.ContainsKey($spec.Key)) {
            $result = Copy-AIOUpdateFileWithBackup -Source $CapturedFiles[$spec.Key] -Destination (Join-Path $MediaRoot $spec.RelativePath)
            if ($result) { [void]$results.Add($result) }
        }
    }
    foreach ($entry in $map) {
        $destination = Join-Path $MediaRoot $entry.Relative
        $result = Copy-AIOUpdateFileWithBackup -Source $CapturedFiles[$entry.Key] -Destination $destination
        if ($result) { [void]$results.Add($result) }
        if ($entry.Signed) { Assert-AIOUpdateBootSignature -Path $destination -Policy $policy }
        elseif ($entry.MicrosoftSigned) { Assert-AIOUpdateMicrosoftBootSignature -Path $destination }
    }
    foreach ($spec in $script:AIOUpdateBootMediaStaticSyncSpecs) {
        if (-not $CapturedFiles.ContainsKey($spec.Key)) { continue }
        if ($spec.Key -eq 'MemtestEfi' -and (Get-AIOUpdateBootSigner -Path $CapturedFiles[$spec.Key]) -ne $policy) {
            Add-AIOUpdateMaintenanceRecord -Context 'Arranque UEFI' -State 'OptionalBootFilePreserved' -Reason 'memtest.efi no tiene la firma elegida; se conserva el existente.'
            continue
        }
        $result = Copy-AIOUpdateFileWithBackup -Source $CapturedFiles[$spec.Key] -Destination (Join-Path $MediaRoot $spec.RelativePath)
        if ($result) { [void]$results.Add($result) }
    }
    if ($is2023 -and $CapturedFiles.ContainsKey('FontsExDirectory')) {
        foreach ($file in @(Get-ChildItem -LiteralPath $CapturedFiles['FontsExDirectory'] -File -Filter '*.ttf' -ErrorAction Stop)) {
            $name = $file.Name -replace '(?i)_EX(?=\.ttf$)', ''
            $result = Copy-AIOUpdateFileWithBackup -Source $file.FullName -Destination (Join-Path $MediaRoot "efi\microsoft\boot\fonts\$name")
            if ($result) { [void]$results.Add($result) }
        }
    }
    Add-AIOUpdateMaintenanceRecord -Context 'Arranque UEFI' -State 'BootSigningVerified' -Performed $true -Reason "Politica solicitada=$BootSigningPolicy; firmante del cargador UEFI=$policy; archivos aplicables sincronizados y SHA-256 verificado. La confianza del firmware del equipo de destino requiere validacion en ese equipo."
    [object[]]$results.ToArray()
}

function ConvertTo-AIOUpdateCompactPackage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Package)

    $architectures = @(
        $Package.Architectures |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $editions = @(
        $Package.Editions |
            Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Sort-Object -Unique
    )
    $cbsOwn = @()
    $cbsDependencies = @()
    if ($Package.Metadata) {
        $cbsOwn = @(
            $Package.Metadata.CbsOwnIdentities |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )
        $cbsDependencies = @(
            @(
                $Package.Metadata.CbsDependencies
                $Package.Metadata.CbsParents
            ) |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ } |
                Sort-Object -Unique
        )
    }

    return [pscustomobject]@{
        Name             = [string]$Package.Name
        FullName         = [string]$Package.FullName
        Category         = [string]$Package.Category
        KB               = [string]$Package.KB
        Version          = [string]$Package.Version
        VersionSource    = [string]$Package.VersionSource
        Embedded         = [bool]$Package.Embedded
        SourcePackage    = [string]$Package.SourcePackage
        Size             = [int64]$Package.Size
        IsCheckpoint     = [bool]$Package.IsCheckpoint
        IsLcuTarget      = $(if ($Package.PSObject.Properties['IsLcuTarget']) { [bool]$Package.IsLcuTarget } else { $null })
        IsLcuPrerequisiteCandidate = $(if ($Package.PSObject.Properties['IsLcuPrerequisiteCandidate']) { [bool]$Package.IsLcuPrerequisiteCandidate } else { $false })
        Architectures    = [string[]]$architectures
        ArchitectureSource = [string]$Package.ArchitectureSource
        LcuFamily        = [string]$Package.LcuFamily
        LcuTargetName    = [string]$Package.LcuTargetName
        CbsRootIdentities = $(if ($Package.Metadata -and $Package.Metadata.PSObject.Properties['CbsRootIdentities']) { [object[]]@($Package.Metadata.CbsRootIdentities) } else { [object[]]@() })
        Editions         = [string[]]$editions
        CbsOwnIdentities = [string[]]$cbsOwn
        CbsDependencies  = [string[]]$cbsDependencies
    }
}

function ConvertTo-AIOUpdateCompactVerification {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Report)

    $summary = ''
    if ($Report.PSObject.Properties['Summary'] -and -not [string]::IsNullOrWhiteSpace([string]$Report.Summary)) {
        $summary = [string]$Report.Summary
    }
    elseif ($Report.PSObject.Properties['Reason']) {
        $summary = [string]$Report.Reason
    }

    $missingExpected = @()
    if ($Report.PSObject.Properties['MissingExpected']) {
        $missingExpected = @($Report.MissingExpected | Where-Object { $null -ne $_ })
    }
    $rejuvWarnings = @()
    if ($Report.PSObject.Properties['RejuvWarnings']) {
        $rejuvWarnings = @($Report.RejuvWarnings | Where-Object { $null -ne $_ })
    }
    $details = @()
    if ($Report.PSObject.Properties['Details']) {
        $details = @(
            $Report.Details |
                Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } |
                ForEach-Object { [string]$_ }
        )
    }

    $observed = ''
    if ($Report.PSObject.Properties['ObservedServicingVersion']) {
        $observed = [string]$Report.ObservedServicingVersion
        if ($observed -eq '0.0.0.0') { $observed = '' }
    }

    return [pscustomobject]@{
        Kind                     = [string]$Report.Kind
        Target                   = [string]$Report.Target
        Phase                    = [string]$Report.Phase
        Success                  = [bool]$Report.Success
        Summary                  = $summary
        CbsFamilyVersion         = $observed
        ObservedServicingVersion = $observed
        EvidenceCount            = @($Report.VerifiedExpected | Where-Object { $null -ne $_ }).Count
        NewPackageCount          = @($Report.NewPackages | Where-Object { $null -ne $_ }).Count
        RetiredPackageCount      = @($Report.RetiredPackages | Where-Object { $null -ne $_ }).Count
        MissingExpected          = [object[]]$missingExpected
        RejuvWarnings            = [object[]]$rejuvWarnings
        Details                  = [string[]]$details
    }
}

function ConvertTo-AIOUpdateCompactDependencyPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [object]$Plan)

    $entries = @(
        foreach ($entry in @($Plan.Packages | Where-Object { $null -ne $_ })) {
            $matched = @($entry.MatchedDependencies | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            $constraints = @($entry.OrderingConstraints | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            $metadata = @($entry.MetadataDependencies | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { [string]$_ })
            [pscustomobject]@{
                Position             = [int]$entry.PlannedPosition
                PlannedPosition      = [int]$entry.PlannedPosition
                ExecutedPosition     = if ($null -ne $entry.ExecutedPosition) { [int]$entry.ExecutedPosition } else { $null }
                ExecutionState       = [string]$entry.ExecutionState
                ExitCode             = if ($null -ne $entry.ExitCode) { [int]$entry.ExitCode } else { $null }
                Category             = [string]$entry.Category
                Name                 = [string]$entry.Name
                Version              = [string]$entry.Version
                IsCheckpoint         = [bool]$entry.IsCheckpoint
                MatchedDependencies  = [string[]]$matched
                OrderingConstraints  = [string[]]$constraints
                MetadataDependencies = [string[]]$metadata
            }
        }
    )
    $executed = @($entries | Where-Object { $null -ne $_.ExecutedPosition } | Sort-Object ExecutedPosition)
    $skipped = @($entries | Where-Object { $_.ExecutionState -eq 'AlreadyPresent' } | Sort-Object PlannedPosition)

    return [pscustomobject]@{
        Context       = [string]$Plan.Context
        Resolution    = [string]$Plan.Resolution
        HadAmbiguity  = [bool]$Plan.HadAmbiguity
        PlannedOrder  = [object[]]$entries
        ExecutedOrder = [object[]]$executed
        SkippedOrder  = [object[]]$skipped
        Packages      = [object[]]$entries
    }
}

function Export-AIOUpdateStructuredReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failed', 'Restored')]
        [string]$Status,
        [Parameter(Mandatory = $true)] [string]$OutputDirectory,
        [AllowNull()] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [datetime]$StartedAt,
        [Parameter(Mandatory = $true)] [datetime]$EndedAt,
        [AllowNull()] [object]$Options,
        [AllowNull()] [object]$PreflightBackup,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Inventory,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$VerificationReports,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$CompletedTargets,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$FinalInstallImages,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$FinalBootImages,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$DependencyPlans,
        [AllowNull()] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()] [string]$Phase
    )

    Initialize-AIOUpdateDirectory -Path $OutputDirectory
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $jsonPath = Join-Path $OutputDirectory "Resultado_AIOU_$stamp.json"
    $htmlPath = Join-Path $OutputDirectory "Resultado_AIOU_$stamp.html"

    $packages = @(
        $Inventory |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactPackage -Package $_ }
    )
    $verification = @(
        $VerificationReports |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactVerification -Report $_ }
    )
    $dependencyPlanReports = @(
        $DependencyPlans |
            Where-Object { $null -ne $_ } |
            ForEach-Object { ConvertTo-AIOUpdateCompactDependencyPlan -Plan $_ }
    )
    $images = @(
        foreach ($image in @($FinalInstallImages)) {
            [pscustomobject]@{
                ImageFile = 'install.wim'
                Index     = [int]$image.ImageIndex
                Name      = [string]$image.ImageName
                Version   = [string]$image.Version
                Architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
            }
        }
        foreach ($image in @($FinalBootImages)) {
            [pscustomobject]@{
                ImageFile = 'boot.wim'
                Index     = [int]$image.ImageIndex
                Name      = [string]$image.ImageName
                Version   = [string]$image.Version
                Architecture = Convert-AIOUpdateArchitectureName -Architecture $image.Architecture
            }
        }
    )

    $errorInfo = $null
    if ($ErrorRecord) {
        $errorInfo = [pscustomobject]@{
            Message          = [string]$ErrorRecord.Exception.Message
            ExceptionType    = [string]$ErrorRecord.Exception.GetType().FullName
            ScriptLineNumber = [int]$ErrorRecord.InvocationInfo.ScriptLineNumber
            Line             = [string]$ErrorRecord.InvocationInfo.Line
            PositionMessage  = [string]$ErrorRecord.InvocationInfo.PositionMessage
            FullyQualifiedErrorId = [string]$ErrorRecord.FullyQualifiedErrorId
            StackTrace       = [string]$ErrorRecord.ScriptStackTrace
        }
    }

    $report = [pscustomobject]@{
        SchemaVersion      = 3
        OfflineValidationOnly = $true
        RuntimeValidationRequired = @($script:AIOUpdateMaintenanceResults | Where-Object State -eq 'DependencyNeedsRuntimeValidation').Count -gt 0
        Status             = $Status
        MediaRoot          = [string]$MediaRoot
        Phase              = [string]$Phase
        StartedAt          = $StartedAt.ToString('o')
        EndedAt            = $EndedAt.ToString('o')
        DurationSeconds    = [math]::Round(($EndedAt - $StartedAt).TotalSeconds, 2)
        Host               = [pscustomobject]@{
            ComputerName   = $env:COMPUTERNAME
            UserName       = $env:USERNAME
            PowerShell     = [string]$PSVersionTable.PSVersion
            Is64BitProcess = [Environment]::Is64BitProcess
            OSVersion      = [Environment]::OSVersion.VersionString
            DismPath       = $script:AIOUpdateDismPath
            DismSource     = $script:AIOUpdateDismSource
            DismVersion    = $(if ($script:AIOUpdateAdkInfo) { [string]$script:AIOUpdateAdkInfo.ActiveDismVersion } else { [string](Get-AIOUpdateExecutableVersion -Path $script:AIOUpdateDismPath) })
            AdkDetected    = [bool]$(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.Detected } else { $false })
            AdkRoot        = $(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.Root } else { $null })
            WinPERoot      = $(if ($script:AIOUpdateAdkInfo) { $script:AIOUpdateAdkInfo.WinPERoot } else { $null })
            WinPEArchitectures = $(if ($script:AIOUpdateAdkInfo) { [string[]]$script:AIOUpdateAdkInfo.WinPEArchitectures } else { [string[]]@() })
        }
        Options            = $Options
        PreflightBackup    = $PreflightBackup
        CompletedTargets   = [object[]]@($CompletedTargets)
        Packages           = [object[]]$packages
        EmbeddedSsuPackages = [object[]]@($script:AIOUpdateEmbeddedSsuPackages | Where-Object { $_ } | ForEach-Object { ConvertTo-AIOUpdateCompactPackage -Package $_ })
        DependencyPlans    = [object[]]$dependencyPlanReports
        Maintenance        = [object[]]@($script:AIOUpdateMaintenanceResults)
        BootSignatures     = [object[]]@($script:AIOUpdateBootSignatureResults | Where-Object { $null -ne $_ })
        Verification       = [object[]]$verification
        FinalImages        = [object[]]$images
        Error              = $errorInfo
    }

    Write-AIOUpdateAtomicJson -Path $jsonPath -InputObject $report -Depth 12

    $summary = [pscustomobject]@{
        Estado          = $Status
        Medio           = [string]$MediaRoot
        Fase            = [string]$Phase
        Inicio          = $StartedAt
        Fin             = $EndedAt
        DuracionSegundos = $report.DurationSeconds
        Paquetes        = $packages.Count
        Verificaciones  = $verification.Count
        Respaldo        = if ($PreflightBackup) { [string]$PreflightBackup.Root } else { '' }
    }

    $summaryHtml = ($summary | ConvertTo-Html -Fragment -PreContent '<h2>Resumen</h2>') -join "`n"
    $packagesHtml = if ($packages.Count -gt 0) {
        ($packages | Select-Object Category, Name, KB, Version, IsCheckpoint, Size | ConvertTo-Html -Fragment -PreContent '<h2>Paquetes</h2>') -join "`n"
    }
    else { '<h2>Paquetes</h2><p>Sin datos.</p>' }
    $verificationHtml = if ($verification.Count -gt 0) {
        $verificationRows = @(
            $verification | ForEach-Object {
                [pscustomobject]@{
                    Objetivo            = $_.Target
                    Fase                = $_.Phase
                    Correcto            = $_.Success
                    Resumen             = $_.Summary
                    FamiliaCBS          = $_.CbsFamilyVersion
                    Evidencias          = $_.EvidenceCount
                    PaquetesNuevos      = $_.NewPackageCount
                    PaquetesRetirados   = $_.RetiredPackageCount
                    Detalles            = @($_.Details) -join '; '
                }
            }
        )
        ($verificationRows | ConvertTo-Html -Fragment -PreContent '<h2>Verificaciones</h2>') -join "`n"
    }
    else { '<h2>Verificaciones</h2><p>Sin datos.</p>' }
    $imagesHtml = if ($images.Count -gt 0) {
        ($images | ConvertTo-Html -Fragment -PreContent '<h2>Imagenes finales</h2>') -join "`n"
    }
    else { '<h2>Imagenes finales</h2><p>Sin datos.</p>' }
    $dependencyRows = @(
        foreach ($plan in @($dependencyPlanReports)) {
            foreach ($entry in @($plan.PlannedOrder)) {
                [pscustomobject]@{
                    Contexto          = [string]$plan.Context
                    Resolucion        = [string]$plan.Resolution
                    PosicionPlaneada  = [int]$entry.PlannedPosition
                    PosicionEjecutada = if ($null -ne $entry.ExecutedPosition) { [int]$entry.ExecutedPosition } else { '' }
                    EstadoEjecucion   = [string]$entry.ExecutionState
                    Categoria         = [string]$entry.Category
                    Paquete           = [string]$entry.Name
                    DependenciasCBS   = @($entry.MatchedDependencies) -join '; '
                    Restricciones     = @($entry.OrderingConstraints) -join '; '
                }
            }
        }
    )
    $dependenciesHtml = if ($dependencyRows.Count -gt 0) {
        ($dependencyRows | ConvertTo-Html -Fragment -PreContent '<h2>Orden CBS</h2>') -join "`n"
    }
    else { '<h2>Orden CBS</h2><p>No se resolvieron planes.</p>' }

    $maintenanceHtml = if (@($script:AIOUpdateMaintenanceResults).Count -gt 0) { (@($script:AIOUpdateMaintenanceResults) | ConvertTo-Html -Fragment -PreContent '<h2>Mantenimiento y dependencias</h2>') -join "`n" } else { '' }
    $bootSignaturesHtml = if ($report.BootSignatures.Count -gt 0) { ($report.BootSignatures | ConvertTo-Html -Fragment -PreContent '<h2>Firmas incorporadas de arranque</h2>') -join "`n" } else { '' }
    $errorHtml = ''
    if ($errorInfo) {
        $encodedMessage = [System.Net.WebUtility]::HtmlEncode([string]$errorInfo.Message)
        $encodedPosition = [System.Net.WebUtility]::HtmlEncode([string]$errorInfo.PositionMessage)
        $errorHtml = "<h2>Error</h2><pre>$encodedMessage`n$encodedPosition</pre>"
    }

    $html = @"
<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<title>AdminImagenOffline - Resultado $Status</title>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:24px;background:#f5f5f5;color:#202020}
main{max-width:1400px;margin:auto;background:white;padding:24px;border-radius:8px;box-shadow:0 2px 12px rgba(0,0,0,.12)}
table{border-collapse:collapse;width:100%;margin:12px 0 28px}
th,td{border:1px solid #ccc;padding:7px;text-align:left;vertical-align:top}
th{background:#ececec}
h1{margin-top:0}
pre{white-space:pre-wrap;background:#f0f0f0;padding:12px;border-radius:4px}
.ok{color:#167217}.failed{color:#a31515}
</style>
</head>
<body><main>
<h1>AdminImagenOffline - Modulo de Actualizaciones</h1>
$summaryHtml
$errorHtml
$imagesHtml
$packagesHtml
$dependenciesHtml
$maintenanceHtml
$bootSignaturesHtml
$verificationHtml
</main></body></html>
"@
    Write-AIOUpdateAtomicText -Path $htmlPath -Text $html

    return [pscustomobject]@{
        JsonPath = $jsonPath
        HtmlPath = $htmlPath
        Report   = $report
    }
}

function New-AIOUpdateDiagnosticBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowNull()] [string]$MediaRoot,
        [AllowNull()] [string]$BackupRoot,
        [AllowNull()] [string]$SessionRoot,
        [AllowNull()] [string]$DismTranscript,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$Inventory,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$VerificationReports,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$CompletedTargets,
        [AllowNull()] [AllowEmptyCollection()] [object[]]$DependencyPlans,
        [AllowNull()] [object]$Options,
        [Parameter(Mandatory = $true)] [datetime]$StartedAt,
        [Parameter(Mandatory = $true)] [datetime]$EndedAt,
        [AllowNull()] [string]$Phase,
        [AllowNull()] [object]$PreflightBackup
    )

    $diagnosticBase = if (-not [string]::IsNullOrWhiteSpace([string]$script:AIOUpdateDiagnosticsRoot)) {
        $script:AIOUpdateDiagnosticsRoot
    }
    else {
        Join-Path $env:TEMP 'AdminImagenOffline_Diagnosticos'
    }
    Initialize-AIOUpdateDirectory -Path $diagnosticBase

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $folder = Join-Path $diagnosticBase "Diagnostico_AIOU_$stamp"
    Initialize-AIOUpdateDirectory -Path $folder -Empty
    $logsRoot = Join-Path $folder 'Logs'
    Initialize-AIOUpdateDirectory -Path $logsRoot

    $errorText = @(
        "Fecha: $($EndedAt.ToString('o'))"
        "Fase: $Phase"
        "Medio: $MediaRoot"
        "Mensaje: $($ErrorRecord.Exception.Message)"
        "Tipo: $($ErrorRecord.Exception.GetType().FullName)"
        "Linea: $($ErrorRecord.InvocationInfo.ScriptLineNumber)"
        "Codigo: $($ErrorRecord.InvocationInfo.Line)"
        "PositionMessage: $($ErrorRecord.InvocationInfo.PositionMessage)"
        "StackTrace:"
        [string]$ErrorRecord.ScriptStackTrace
    )
    Set-Content -LiteralPath (Join-Path $folder 'Error.txt') -Value $errorText -Encoding UTF8

    try {
        & $script:AIOUpdateDismPath '/English' '/Get-MountedImageInfo' *> (Join-Path $folder 'DISM_MountedImageInfo.txt')
    }
    catch {}

    if ($SessionRoot -and (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
        $counter = 0
        foreach ($file in @(
            # Native DISM logs live at session root. Include them regardless
            # of size; do not recurse into mounted images/protected OS folders.
            Get-ChildItem -LiteralPath $SessionRoot -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension.ToLowerInvariant() -in @('.log', '.txt', '.json') }
        )) {
            $counter++
            $safeName = ('{0:D4}_{1}' -f $counter, $file.Name)
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $logsRoot $safeName) -Force -ErrorAction SilentlyContinue
        }
    }
    if ($DismTranscript -and (Test-Path -LiteralPath $DismTranscript -PathType Leaf)) {
        Copy-Item -LiteralPath $DismTranscript -Destination (Join-Path $logsRoot 'DISM_Consola.log') -Force -ErrorAction SilentlyContinue
    }

    if ($PreflightBackup -and $PreflightBackup.ManifestPath -and (Test-Path -LiteralPath $PreflightBackup.ManifestPath -PathType Leaf)) {
        Copy-Item -LiteralPath $PreflightBackup.ManifestPath -Destination (Join-Path $folder 'Preflight_manifest.json') -Force -ErrorAction SilentlyContinue
    }

    $logVariable = Get-Variable -Name logFile -Scope Script -ErrorAction SilentlyContinue
    if ($logVariable -and (Test-Path -LiteralPath ([string]$logVariable.Value) -PathType Leaf)) {
        Copy-Item -LiteralPath ([string]$logVariable.Value) -Destination (Join-Path $logsRoot 'AdminImagenOffline.log') -Force -ErrorAction SilentlyContinue
    }

    $report = Export-AIOUpdateStructuredReport -Status 'Failed' -OutputDirectory $folder -MediaRoot $MediaRoot -StartedAt $StartedAt -EndedAt $EndedAt -Options $Options -PreflightBackup $PreflightBackup -Inventory $Inventory -VerificationReports $VerificationReports -CompletedTargets $CompletedTargets -DependencyPlans $DependencyPlans -ErrorRecord $ErrorRecord -Phase $Phase

    $zipPath = "$folder.zip"
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    try {
        $diagnosticFiles = @(Get-ChildItem -LiteralPath $folder -Force -ErrorAction Stop)
        if ($diagnosticFiles.Count -eq 0) {
            throw 'La carpeta de diagnostico no contiene archivos.'
        }

        if (Get-Command Compress-Archive -ErrorAction SilentlyContinue) {
            Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zipPath -CompressionLevel Optimal -Force -ErrorAction Stop
        }
        else {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::CreateFromDirectory($folder, $zipPath, [System.IO.Compression.CompressionLevel]::Optimal, $false)
        }

        if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf) -or (Get-Item -LiteralPath $zipPath).Length -eq 0) {
            throw 'El archivo ZIP de diagnostico no fue creado correctamente.'
        }
    }
    catch {
        Write-AIOUpdateLog -Level WARN -Message "No se pudo comprimir el diagnostico: $($_.Exception.Message)"
        $zipPath = $null
    }

    return [pscustomobject]@{
        FolderPath = $folder
        ZipPath    = $zipPath
        Report     = $report
    }
}

function Invoke-AIOUpdateMediaIntegration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$MediaRoot,
        [Parameter(Mandatory = $true)] [object[]]$Inventory,
        [Parameter(Mandatory = $true)] [int[]]$InstallIndexes,
        [Parameter(Mandatory = $true)] [psobject]$Compatibility,
        [switch]$UpdateWinRE,
        [switch]$UpdateBootWim,
        [switch]$ApplySetupDU,
        [switch]$Cleanup,
        [switch]$ResetBase,
        [switch]$OptimizeWims,
        [switch]$UpdateWimCreationTime,
        [ValidateSet('Preserve','CA2023','CA2011')] [string]$BootSigningPolicy = 'Preserve',
        [bool]$VerifyPrePostCommit = $true
    )

    if ($script:AIOUpdateMountedPaths.Count -gt 0 -and -not (Clear-AIOUpdateMountedImages)) {
        throw "Hay montajes pendientes de una sesion anterior: $($script:AIOUpdateMountedPaths -join ', ')."
    }
    $media = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $installWim = Join-Path $media 'sources\install.wim'
    $bootWim = Join-Path $media 'sources\boot.wim'
    $initialInstallImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)
    $initialBootImages = if (Test-Path -LiteralPath $bootWim -PathType Leaf) { @(Get-AIOUpdateImageMetadata -ImagePath $bootWim) } else { @() }
    $compatibilityEditionId = if ($Compatibility.Images[0].PSObject.Properties['EditionId']) { [string]$Compatibility.Images[0].EditionId } else { '' }

    $effectiveInventory = @(
        $Inventory |
            Where-Object {
                $_.Auxiliary -or
                ($_.Installable -and (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $Compatibility.Architecture -Build $Compatibility.Build -ImageName $Compatibility.Images[0].ImageName -EditionId $compatibilityEditionId).Compatible)
            }
    )
    if (@($effectiveInventory | Where-Object { $_.Installable }).Count -eq 0) {
        throw 'Ningun paquete instalable del repositorio es compatible con los indices seleccionados.'
    }

    $script:AIOUpdateMaintenanceResults = New-Object System.Collections.ArrayList
    $script:AIOUpdateBootSignatureResults = New-Object System.Collections.ArrayList
    $baseWork = if ($Script:Scratch_DIR -and (Test-Path -LiteralPath $Script:Scratch_DIR)) { $Script:Scratch_DIR } else { $env:TEMP }
    $script:AIOUpdateSessionRoot = Join-Path $baseWork ('AIOU_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Initialize-AIOUpdateDirectory -Path $script:AIOUpdateSessionRoot -Empty
    $script:AIOUpdateDismTranscript = Join-Path $script:AIOUpdateSessionRoot 'DISM_Consola.log'

    $dismScratch = Join-Path $script:AIOUpdateSessionRoot 'S'
    $installMount = Join-Path $script:AIOUpdateSessionRoot 'I'
    $winreMount = Join-Path $script:AIOUpdateSessionRoot 'R'
    $bootMount = Join-Path $script:AIOUpdateSessionRoot 'B'
    $stagingRoot = Join-Path $script:AIOUpdateSessionRoot 'T'
    $captureRoot = Join-Path $stagingRoot 'BootCapture'
    foreach ($path in @($dismScratch, $installMount, $winreMount, $bootMount, $stagingRoot)) {
        Initialize-AIOUpdateDirectory -Path $path
    }

    Assert-AIOUpdateWorkspaceCapacity `
        -MediaRoot $media `
        -SessionRoot $script:AIOUpdateSessionRoot `
        -Inventory $effectiveInventory `
        -IncludeBootWim:$UpdateBootWim

    # El respaldo se guarda fuera de la raíz del medio para impedir que una
    # creación posterior de ISO incorpore accidentalmente las copias.
    $mediaParent = Split-Path -Parent $media
    $mediaLeaf = Split-Path -Leaf $media
    if ([string]::IsNullOrWhiteSpace($mediaLeaf)) { $mediaLeaf = 'MediaWindows' }
    $backupBase = Join-Path $mediaParent 'AdminImagenOffline_Backup'
    $backupRoot = Join-Path (Join-Path $backupBase $mediaLeaf) (Get-Date -Format 'yyyyMMdd_HHmmss')
    $verificationReports = New-Object System.Collections.ArrayList
    $completed = New-Object System.Collections.ArrayList
    $integrationStartedAt = Get-Date
    $integrationOptions = [pscustomobject]@{
        InstallIndexes        = [int[]]$InstallIndexes
        UpdateWinRE           = [bool]$UpdateWinRE
        UpdateBootWim         = [bool]$UpdateBootWim
        ApplySetupDU          = [bool]$ApplySetupDU
        Cleanup               = [bool]$Cleanup
        ResetBase             = [bool]$ResetBase
        OptimizeWims          = [bool]$OptimizeWims
        UpdateWimCreationTime = [bool]$UpdateWimCreationTime
        VerifyPrePostCommit   = [bool]$VerifyPrePostCommit
        ReapplyPresent        = $true
        ReapplyMode           = 'Automatic'
        SingleIndexExportRequired = ($InstallIndexes.Count -eq 1 -and $initialInstallImages.Count -gt 1)
        BootSigningPolicy     = $BootSigningPolicy
        RecoveryCleanup       = 'WinRE/WinPE: StartComponentCleanup + ResetBase; aplazar solo si hay operaciones pendientes'
        RuntimeValidation     = 'El analisis offline no sustituye pruebas de arranque, Setup y recuperacion' 
    }
    $script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
    $script:AIOUpdateExecutionPositionByContext = @{}
    $script:AIOUpdateLastDiagnosticPath = $null
    $script:AIOUpdateLastPersistentLogPath = $null
    if (-not $script:AIOUpdateLastTerminalState) { [void](Initialize-AIOUpdateTerminalState) }
    $script:AIOUpdateLastTerminalState.Status = 'Running'
    $script:AIOUpdateLastTerminalState.Phase = 'Inicializacion'
    $script:AIOUpdateLastTerminalState.MediaRoot = $media
    $script:AIOUpdateStructuredReport = $null
    Write-AIOUpdateLog -Level WARN -Message 'Reaplicacion automatica habilitada: los paquetes CBS ya presentes se enviaran nuevamente a DISM sin desinstalarlos.'
    $preflightBackup = $null
    $servicedWinREByIndex = @{}
    $setupDUWasApplied = $false
    $setupPackages = @()
    $finalInstallImages = @()
    $finalBootImages = @()
    $mediaMutationStarted = $false
    $restorationStatus = 'No requerida'

    try {
        # El respaldo se completa antes de preparar paquetes, montar imagenes o
        # modificar cualquier archivo del medio.
        $script:AIOUpdateCurrentPhase = 'Respaldo Preflight'
        $script:AIOUpdatePreflightContext = $null
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        $preflightBackup = New-AIOUpdatePreflightBackup `
            -MediaRoot $media `
            -BackupRoot $backupRoot `
            -IncludeSetupSurface:($ApplySetupDU -or $UpdateBootWim)
        $script:AIOUpdatePreflightContext = $preflightBackup
        Initialize-AIOUpdatePreflightRuntimeIndex -Context $preflightBackup
        $script:AIOUpdateLastTerminalState.BackupRoot = $preflightBackup.Root
        [void]$completed.Add("respaldo previo verificado: $($preflightBackup.FileCount) archivo(s)")

        if ($UpdateBootWim) {
            $entry = Get-AIOUpdateArchitectureCatalogEntry -Architecture $Compatibility.Architecture
            $effectiveBootPolicy = Resolve-AIOUpdateBootSigningPolicy -MediaRoot $media -EfiBootName $entry.EfiBootName -Policy $BootSigningPolicy
            $integrationOptions | Add-Member -NotePropertyName EffectiveBootSigningPolicy -NotePropertyValue $effectiveBootPolicy -Force
            Write-AIOUpdateLog -Level INFO -Message "Politica UEFI efectiva: $effectiveBootPolicy. No se infiere la confianza del firmware del destino."
        }
        $script:AIOUpdateCurrentPhase = 'Staging de paquetes' 
        Initialize-AIOUpdateLcuMsuStaging -Inventory $effectiveInventory -StagingRoot $stagingRoot
        if ($UpdateWinRE -or $UpdateBootWim) {
            [void](Initialize-AIOUpdateEmbeddedSsuStaging -Inventory $effectiveInventory -StagingRoot $stagingRoot)
        }

        $setupPackages = @(Get-AIOUpdatePackages -Inventory $effectiveInventory -Category @('SetupDU'))
        if ($UpdateWinRE) {
            $script:AIOUpdateCurrentPhase = 'Mantenimiento de winre.wim'
            $winreCache = @{}
            foreach ($winreIndex in $InstallIndexes) {
                $sourceWinRE = Join-Path $stagingRoot ("winre.original.{0}.wim" -f $winreIndex)
                [void](Get-AIOUpdateWinREFromInstallWim -InstallWim $installWim -Index $winreIndex -InstallMount $installMount -ScratchPath $dismScratch -Destination $sourceWinRE)
                $originalHash = (Get-FileHash -LiteralPath $sourceWinRE -Algorithm SHA256 -ErrorAction Stop).Hash
                if (-not $winreCache.ContainsKey($originalHash)) {
                    $updatedWinRE = Join-Path $stagingRoot ("winre.updated.{0}.wim" -f $originalHash)
                    $winreMetadata = @(Get-AIOUpdateImageMetadata -ImagePath $sourceWinRE)
                    if ($winreMetadata.Count -ne 1) { throw "WinRE del indice $winreIndex no contiene una unica imagen." }
                    $policy = Get-AIOUpdateWinREPolicy -Build ([version]$winreMetadata[0].Version).Build -Inventory $effectiveInventory
                    Write-Host "`nPolitica WinRE indice ${winreIndex}: $($policy.Reason)" -ForegroundColor Gray
                    $updated = Update-AIOUpdateWinRE -SourceWinRE $sourceWinRE -DestinationWinRE $updatedWinRE -WinREMount $winreMount -ScratchPath $dismScratch -Inventory $effectiveInventory -Policy $policy -OptimizeWim ([bool]$OptimizeWims) -VerifyPrePostCommit $VerifyPrePostCommit -VerificationReports $verificationReports
                    $updated | Add-Member -NotePropertyName SourceHash -NotePropertyValue $originalHash -Force
                    $winreCache[$originalHash] = $updated
                }
                $servicedWinREByIndex[[string]$winreIndex] = $winreCache[$originalHash]
                if (-not $servicedWinREByIndex[[string]$winreIndex].RecoveryUpdated) {
                    $stackStatus = if ($servicedWinREByIndex[[string]$winreIndex].ServicingStackVerified) { 'solo pila de mantenimiento verificada' } else { 'sin actualizaciones aplicables acreditadas' }
                    [void]$completed.Add("winre.wim del indice ${winreIndex}: $stackStatus; sin actualizacion de recuperacion")
                }
                elseif ($VerifyPrePostCommit) {
                    [void]$completed.Add("winre.wim del indice $winreIndex actualizado y verificado")
                }
                else {
                    [void]$completed.Add("winre.wim del indice $winreIndex actualizado; verificacion Pre/Post-Commit omitida")
                }
            }
        }

        $script:AIOUpdateCurrentPhase = 'Mantenimiento de install.wim'
        $mediaMutationStarted = $true
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = $true
        Update-AIOUpdateInstallWim -InstallWim $installWim -Indexes $InstallIndexes -Inventory $effectiveInventory -InstallMount $installMount -ScratchPath $dismScratch -ServicedWinREByIndex $servicedWinREByIndex -Cleanup:$Cleanup -ResetBase:$ResetBase -VerifyPrePostCommit $VerifyPrePostCommit -VerificationReports $verificationReports
        if ($VerifyPrePostCommit) {
            [void]$completed.Add('install.wim actualizado y verificado')
        }
        else {
            [void]$completed.Add('install.wim actualizado; verificacion Pre/Post-Commit omitida')
        }

        $captured = @{}
        $setupDependencyFiles = @{}
        if ($UpdateBootWim) {
            $script:AIOUpdateCurrentPhase = 'Mantenimiento de boot.wim'
            if (-not (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
                throw 'Se solicito actualizar boot.wim, pero no existe sources\boot.wim.'
            }
            $bootImages = @(Get-AIOUpdateImageMetadata -ImagePath $bootWim)
            $captured = Update-AIOUpdateBootWim -BootWim $bootWim -InstallWim $installWim -InstallIndexes $InstallIndexes -Images $bootImages -Inventory $effectiveInventory -BootMount $bootMount -ScratchPath $dismScratch -CaptureRoot $captureRoot -StagingRoot $stagingRoot -SetupDUPackages $setupPackages -IntegrateSetupDU:$ApplySetupDU -VerifyPrePostCommit $VerifyPrePostCommit -VerificationReports $verificationReports
            foreach ($spec in $script:AIOUpdateSetupDependencySpecs) {
                if ($captured.ContainsKey($spec.Key)) { $setupDependencyFiles[$spec.Key] = $captured[$spec.Key] }
            }
            if ($VerifyPrePostCommit) {
                [void]$completed.Add('boot.wim actualizado y verificado')
            }
            else {
                [void]$completed.Add('boot.wim actualizado; verificacion Pre/Post-Commit omitida')
            }
        }

        if ($ApplySetupDU -and $setupPackages.Count -gt 0 -and $setupDependencyFiles.Count -eq 0 -and (Test-Path -LiteralPath $bootWim -PathType Leaf)) {
            $dependencyCapture = Join-Path $stagingRoot 'SetupDependencies_ReadOnly'
            $setupDependencyFiles = Get-AIOUpdateBootSetupDependencies -BootWim $bootWim -BootMount $bootMount -ScratchPath $dismScratch -CaptureRoot $dependencyCapture
        }

        if ($ApplySetupDU) {
            $script:AIOUpdateCurrentPhase = 'Aplicacion de Setup Dynamic Update'
            if ($setupPackages.Count -eq 0) {
                Write-Host ' [OMITIDO] SetupDU solicitado, pero no se encontraron paquetes de esa categoria.' -ForegroundColor DarkGray
            }
            else {
                $setupResult = Apply-AIOUpdateSetupDU -MediaRoot $media -Packages $setupPackages -StagingRoot $stagingRoot -DependencyFiles $setupDependencyFiles
                if ($setupResult.Applied) {
                    $setupDUWasApplied = $true
                    [void]$completed.Add('SetupDU aplicado al medio y verificado')
                }
            }
        }

        if ($ApplySetupDU -or $UpdateBootWim) {
            $removedLocales = @(Remove-AIOUpdateUnexpectedMediaLocaleDirectories -MediaRoot $media)
            if ($removedLocales.Count -gt 0) {
                [void]$completed.Add("idiomas ajenos al Preflight eliminados: $($removedLocales.Count)")
            }
        }

        if ($UpdateBootWim) {
            $script:AIOUpdateCurrentPhase = 'Sincronizacion de archivos de arranque'
            $bootSync = @(Sync-AIOUpdateMediaBootFiles -MediaRoot $media -CapturedFiles $captured -Architecture $Compatibility.Architecture -BootSigningPolicy $effectiveBootPolicy)
            if ($bootSync.Count -gt 0) { [void]$completed.Add('Windows Setup, sources y binarios de arranque sincronizados') }

            $removedAfterSync = @(Remove-AIOUpdateUnexpectedMediaLocaleDirectories -MediaRoot $media)
            if ($removedAfterSync.Count -gt 0) {
                [void]$completed.Add("idiomas ajenos al Preflight eliminados tras sincronizacion: $($removedAfterSync.Count)")
            }
        }

        if ($ApplySetupDU -or $UpdateBootWim) {
            $localeAudit = Test-AIOUpdateMediaLocalePolicy -MediaRoot $media
            if (-not $localeAudit.Success) {
                $details = @($localeAudit.UnexpectedLocales | ForEach-Object { "$($_.Surface):$($_.Locale)" }) -join ', '
                throw "La auditoria final detecto idiomas fuera de la politica lang.ini: $details"
            }
            [void]$completed.Add("politica final de idiomas verificada: $(@($localeAudit.AllowedLocales) -join ', ')")
        }

        $script:AIOUpdateCurrentPhase = 'Exportacion y optimizacion final de WIM'
        $singleIndexExport = $null
        if ($InstallIndexes.Count -eq 1 -and $initialInstallImages.Count -gt 1) {
            # Exportar es necesario para entregar solo la edicion seleccionada,
            # aunque la optimizacion opcional este desactivada.
            $singleIndexExport = Export-AIOUpdateSingleInstallIndex -InstallWim $installWim -SourceIndex $InstallIndexes[0] -StagingRoot $stagingRoot -ScratchPath $dismScratch
            [void]$completed.Add("install.wim exportado con una sola edicion: $($singleIndexExport.ImageName) (indice final 1)")
        }
        elseif ($OptimizeWims) {
            [void](Rebuild-AIOUpdateWim -WimPath $installWim -StagingRoot $stagingRoot -ScratchPath $dismScratch)
            [void]$completed.Add('install.wim reconstruido y optimizado')
        }

        if ($UpdateBootWim -and $OptimizeWims) {
            [void](Rebuild-AIOUpdateWim -WimPath $bootWim -StagingRoot $stagingRoot -ScratchPath $dismScratch -Bootable)
            [void]$completed.Add('boot.wim reconstruido y optimizado')
        }

        if ($UpdateWimCreationTime) {
            [void](Set-AIOUpdateWimCreationTime -WimPath $installWim -ScratchRoot $stagingRoot)
            if ($UpdateBootWim) { [void](Set-AIOUpdateWimCreationTime -WimPath $bootWim -ScratchRoot $stagingRoot) }
            [void]$completed.Add('fecha interna CREATIONTIME igualada a LASTMODIFICATIONTIME')
        }

        $script:AIOUpdateCurrentPhase = 'Verificacion estructural final'
        $finalInstallImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)
        $finalBootImages = if ($UpdateBootWim) { @(Get-AIOUpdateImageMetadata -ImagePath $bootWim) } else { @() }

        $expectedServicingVersion = [version]'0.0.0.0'
        $observedCandidates = @(
            $verificationReports |
                Where-Object { $_.Kind -eq 'PackageInventory' -and $_.Target -like 'install.wim*' -and $_.Phase -eq 'PostCommit' -and $_.ObservedServicingVersion -ne [version]'0.0.0.0' } |
                ForEach-Object { [version]$_.ObservedServicingVersion }
        )
        if ($observedCandidates.Count -gt 0) {
            $expectedServicingVersion = [version]($observedCandidates | Sort-Object -Descending | Select-Object -First 1)
        }

        $installStructure = New-AIOUpdateWimStructureReport -Target 'install.wim estructura final' -BeforeImages $initialInstallImages -AfterImages $finalInstallImages -SelectedIndexes $InstallIndexes -SingleIndex:($InstallIndexes.Count -eq 1) -ExpectedServicingVersion $expectedServicingVersion
        [void]$verificationReports.Add($installStructure)
        if ($UpdateBootWim) {
            $bootIndexes = [int[]]@($initialBootImages | ForEach-Object { [int]$_.ImageIndex })
            $bootStructure = New-AIOUpdateWimStructureReport -Target 'boot.wim estructura final' -BeforeImages $initialBootImages -AfterImages $finalBootImages -SelectedIndexes $bootIndexes
            [void]$verificationReports.Add($bootStructure)
        }

        $failed = @($verificationReports | Where-Object { -not $_.Success })
        Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host '             RESUMEN FINAL DE VERIFICACION' -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor DarkCyan
        foreach ($report in $verificationReports) { Write-AIOUpdateVerificationReport -Report $report }
        Write-AIOUpdateConsolidatedRejuvSummary -Reports ([object[]]($verificationReports.ToArray()))
        Write-Host ''
        foreach ($item in $completed) { Write-Host " [OK] $item" -ForegroundColor Green }

        if ($failed.Count -gt 0) {
            throw "La integracion termino con $($failed.Count) verificaciones fallidas."
        }

        $script:AIOUpdateCurrentPhase = 'Generacion del reporte final'
        $integrationEndedAt = Get-Date
        $finalInstallIndexes = if ($InstallIndexes.Count -eq 1) { [int[]]@(1) } else { [int[]]$InstallIndexes }
        $resultObject = [pscustomobject]@{
            Success               = $true
            MediaRoot             = $media
            InstallIndexes        = $InstallIndexes
            FinalInstallIndexes   = $finalInstallIndexes
            SingleIndexExport     = $singleIndexExport
            BootWimUpdated        = [bool]$UpdateBootWim
            SetupDUApplied        = [bool]$setupDUWasApplied
            WimsOptimized         = [bool]$OptimizeWims
            WimCreationTimeUpdated = [bool]$UpdateWimCreationTime
            ReapplyPresent         = $true
            CompletedTargets      = [object[]]($completed.ToArray())
            VerificationReports   = [object[]]($verificationReports.ToArray())
            DependencyPlans       = [object[]]($script:AIOUpdateDependencyPlans.ToArray())
            PreflightBackup       = $preflightBackup
            BackupRoot            = if (Test-Path -LiteralPath $backupRoot) { $backupRoot } else { $null }
            FinalInstallImages    = [object[]]$finalInstallImages
            FinalBootImages       = [object[]]$finalBootImages
            WorkLog               = $script:AIOUpdateDismTranscript
            StartedAt             = $integrationStartedAt
            EndedAt               = $integrationEndedAt
        }
        $reportRoot = $script:AIOUpdateReportsRoot
        $structuredReport = Export-AIOUpdateStructuredReport -Status 'Success' -OutputDirectory $reportRoot -MediaRoot $media -StartedAt $integrationStartedAt -EndedAt $integrationEndedAt -Options $integrationOptions -PreflightBackup $preflightBackup -Inventory $effectiveInventory -VerificationReports ([object[]]($verificationReports.ToArray())) -CompletedTargets ([object[]]($completed.ToArray())) -FinalInstallImages $finalInstallImages -FinalBootImages $finalBootImages -DependencyPlans ([object[]]($script:AIOUpdateDependencyPlans.ToArray())) -Phase $script:AIOUpdateCurrentPhase
        $resultObject | Add-Member -NotePropertyName StructuredReport -NotePropertyValue $structuredReport
        $script:AIOUpdateStructuredReport = $structuredReport

        Write-AIOUpdateLog -Level INFO -Message "Integracion completada y verificada. Reporte JSON='$($structuredReport.JsonPath)'; HTML='$($structuredReport.HtmlPath)'."
        Write-AIOUpdateLog -Level INFO -Message ("Optimizacion: HashCacheHits={0}; HashCacheMisses={1}; CbsCacheHits={2}; RepositoryCacheHits={3}; DuplicadosOmitidos={4}." -f $script:AIOUpdateOptimizationStats.HashCacheHits, $script:AIOUpdateOptimizationStats.HashCacheMisses, $script:AIOUpdateOptimizationStats.CbsCacheHits, $script:AIOUpdateOptimizationStats.RepositoryCacheHits, $script:AIOUpdateOptimizationStats.DuplicatePackagesSkipped)
        Write-Host " Reporte JSON: $($structuredReport.JsonPath)" -ForegroundColor DarkGray
        Write-Host " Reporte HTML: $($structuredReport.HtmlPath)" -ForegroundColor DarkGray
        $script:AIOUpdateLastTerminalState.Status = 'Success'
        $script:AIOUpdateLastTerminalState.Phase = 'Finalizacion'
        $script:AIOUpdateLastTerminalState.Message = 'La integracion de actualizaciones termino correctamente.'
        $script:AIOUpdateLastTerminalState.MediaRoot = $media
        $script:AIOUpdateLastTerminalState.BackupRoot = $(if ($preflightBackup) { $preflightBackup.Root } else { $null })
        $script:AIOUpdateLastTerminalState.ReportJson = $structuredReport.JsonPath
        $script:AIOUpdateLastTerminalState.ReportHtml = $structuredReport.HtmlPath
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOUpdateLastTerminalState.RestorationStatus = 'No requerida'
        $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]($completed.ToArray())
        return $resultObject
    }
    catch {
        $capturedError = $_
        $failedPhase = $script:AIOUpdateCurrentPhase
        $integrationEndedAt = Get-Date
        $errorLine = $capturedError.InvocationInfo.ScriptLineNumber
        $errorCode = if ($capturedError.InvocationInfo.Line) { $capturedError.InvocationInfo.Line.Trim() } else { '' }
        Write-AIOUpdateLog -Level ERROR -Message "Integracion interrumpida en '$($script:AIOUpdateCurrentPhase)': $($capturedError.Exception.Message). Completado: $($completed -join ', ')."
        if ($errorLine) {
            Write-AIOUpdateLog -Level ERROR -Message "Linea ${errorLine}: $($capturedError.Exception.Message) | $errorCode"
        }

        try {
            $diagnostic = New-AIOUpdateDiagnosticBundle -ErrorRecord $capturedError -MediaRoot $media -BackupRoot $backupRoot -SessionRoot $script:AIOUpdateSessionRoot -DismTranscript $script:AIOUpdateDismTranscript -Inventory $effectiveInventory -VerificationReports ([object[]]($verificationReports.ToArray())) -CompletedTargets ([object[]]($completed.ToArray())) -DependencyPlans ([object[]]($script:AIOUpdateDependencyPlans.ToArray())) -Options $integrationOptions -StartedAt $integrationStartedAt -EndedAt $integrationEndedAt -Phase $script:AIOUpdateCurrentPhase -PreflightBackup $preflightBackup
            $script:AIOUpdateLastDiagnosticPath = if ($diagnostic.ZipPath) { $diagnostic.ZipPath } else { $diagnostic.FolderPath }
            if ($diagnostic.Report) {
                $script:AIOUpdateStructuredReport = $diagnostic.Report
            }
            Write-AIOUpdateLog -Level ERROR -Message "Diagnostico automatico: $($script:AIOUpdateLastDiagnosticPath)"
            Write-Host "`n Diagnostico automatico: $($script:AIOUpdateLastDiagnosticPath)" -ForegroundColor Yellow
        }
        catch {
            Write-AIOUpdateLog -Level WARN -Message "No se pudo generar el diagnostico automatico: $($_.Exception.Message)"
        }

        $mountsCleared = Clear-AIOUpdateMountedImages
        if ($preflightBackup -and $mediaMutationStarted -and -not $mountsCleared) {
            $restorationStatus = 'Pendiente: no se pudieron desmontar todas las imagenes'
            Write-AIOUpdateLog -Level WARN -Message "Restauracion aplazada. Se conserva el respaldo '$($preflightBackup.Root)' y la sesion '$script:AIOUpdateSessionRoot'."
        }
        elseif ($preflightBackup -and $mediaMutationStarted) {
            Write-Host "`nLa operacion fallo despues de iniciar cambios en el medio." -ForegroundColor Yellow
            if (Read-AIOUpdateYesNo -Prompt 'Restaurar automaticamente el medio al estado inicial' -Default $true) {
                try {
                    $script:AIOUpdateCurrentPhase = 'Recuperacion'
                    [void](Restore-AIOUpdatePreflightBackup -PreflightRoot $preflightBackup.Root -TargetMediaRoot $media -Scope All)
                    $restorationStatus = 'Restaurado y verificado'
                    Write-Host 'El medio fue restaurado y verificado correctamente.' -ForegroundColor Green
                    Write-AIOUpdateLog -Level INFO -Message "Medio restaurado desde '$($preflightBackup.Root)' despues del error."
                }
                catch {
                    $restorationStatus = "Fallo: $($_.Exception.Message)"
                    Write-Host "[ERROR] No se pudo completar la restauracion automatica: $($_.Exception.Message)" -ForegroundColor Red
                    Write-AIOUpdateLog -Level ERROR -Message "Fallo la restauracion automatica: $($_.Exception.Message)"
                }
            }
            else {
                $restorationStatus = 'No solicitada por el usuario'
            }
        }
        elseif ($preflightBackup) {
            $restorationStatus = 'No requerida; el medio no fue modificado'
        }

        $script:AIOUpdateLastTerminalState.Status = 'Failed'
        $script:AIOUpdateLastTerminalState.Phase = $failedPhase
        $script:AIOUpdateLastTerminalState.Message = $capturedError.Exception.Message
        $script:AIOUpdateLastTerminalState.MediaRoot = $media
        $script:AIOUpdateLastTerminalState.BackupRoot = $(if ($preflightBackup) { $preflightBackup.Root } else { $null })
        $script:AIOUpdateLastTerminalState.DiagnosticPath = $script:AIOUpdateLastDiagnosticPath
        $script:AIOUpdateLastTerminalState.ReportJson = $(if ($diagnostic -and $diagnostic.Report) { $diagnostic.Report.JsonPath } else { $null })
        $script:AIOUpdateLastTerminalState.ReportHtml = $(if ($diagnostic -and $diagnostic.Report) { $diagnostic.Report.HtmlPath } else { $null })
        $script:AIOUpdateLastTerminalState.MediaMutationStarted = [bool]$mediaMutationStarted
        $script:AIOUpdateLastTerminalState.RestorationStatus = $restorationStatus
        $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]($completed.ToArray())
        $script:AIOUpdateLastTerminalState.ErrorLine = $capturedError.InvocationInfo.ScriptLineNumber
        $script:AIOUpdateLastTerminalState.ErrorCode = $(if ($capturedError.InvocationInfo.Line) { $capturedError.InvocationInfo.Line.Trim() } else { $null })

        throw $capturedError
    }
    finally {
        $mountsCleared = Clear-AIOUpdateMountedImages

        if ($script:AIOUpdateSessionRoot -and (Test-Path -LiteralPath $script:AIOUpdateSessionRoot)) {
            $persistentLog = $null
            if ($script:logDir -and (Test-Path -LiteralPath $script:logDir)) {
                $persistentLog = Join-Path $script:logDir ("Actualizaciones_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
                if (Test-Path -LiteralPath $script:AIOUpdateDismTranscript) {
                    Copy-Item -LiteralPath $script:AIOUpdateDismTranscript -Destination $persistentLog -Force -ErrorAction SilentlyContinue
                }
            }
            if ($mountsCleared) {
                Remove-Item -LiteralPath $script:AIOUpdateSessionRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
            else {
                Write-Host "Se conserva la sesion para recuperar los montajes pendientes: $script:AIOUpdateSessionRoot" -ForegroundColor Yellow
                Write-AIOUpdateLog -Level WARN -Message "Limpieza aplazada: $script:AIOUpdateSessionRoot"
            }
            if ($persistentLog) {
                $script:AIOUpdateLastPersistentLogPath = $persistentLog
                if ($script:AIOUpdateLastTerminalState) { $script:AIOUpdateLastTerminalState.LogPath = $persistentLog }
                Write-Host "Log de actualizaciones: $persistentLog" -ForegroundColor DarkGray
            }
        }

        if ($mountsCleared) {
            $script:AIOUpdateSessionRoot = $null
            $script:AIOUpdateDismTranscript = $null
        }
        $script:AIOUpdatePackagePathMap = @{}
        $script:AIOUpdateLcuStageRoot = $null
        $script:AIOUpdateEmbeddedSsuPackages = @()
        $script:AIOUpdatePreflightContext = $null
        $script:AIOUpdatePreflightPathIndex = @{}
        $script:AIOUpdatePreflightLocalesBySurface = @{}
        $script:AIOUpdateSessionCreatedPathIndex = @{}
        $script:AIOUpdateSessionCreatedPathEvents = New-Object System.Collections.ArrayList
        $script:AIOUpdateTrustedLocales = @{}
        $script:AIOUpdateDependencyPlans = New-Object System.Collections.ArrayList
        $script:AIOUpdateExecutionPositionByContext = @{}
        $script:AIOUpdateCurrentPhase = 'Finalizado'
    }
}

function Read-AIOUpdateYesNo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string]$Prompt,
        [Nullable[bool]]$Default = $null
    )

    # El parametro Default solo comunica la recomendacion visual. Nunca se
    # utiliza como respuesta implicita: ENTER, entrada vacia o cualquier valor
    # distinto de S/Si/N/No obliga a responder nuevamente.
    $recommendation = if ($null -eq $Default) {
        ''
    }
    elseif ([bool]$Default) {
        ' (recomendado: S)'
    }
    else {
        ' (recomendado: N)'
    }

    while ($true) {
        $answer = (Read-Host "$Prompt [S/N]$recommendation").Trim().ToUpperInvariant()
        if ($answer -in @('S', 'SI', 'SÍ', 'Y', 'YES')) { return $true }
        if ($answer -in @('N', 'NO')) { return $false }

        if ([string]::IsNullOrWhiteSpace($answer)) {
            Write-Host 'Se requiere confirmacion explicita. Escribe S o N; ENTER no selecciona una opcion.' -ForegroundColor Yellow
        }
        else {
            Write-Host 'Respuesta invalida. Escribe S o N.' -ForegroundColor Red
        }
    }
}

function Show-AIOUpdateInventorySummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [object[]]$Inventory
    )

    foreach ($entry in @(Get-AIOUpdateInventorySummary -Inventory $Inventory)) {
        $color = if ($entry.Count -gt 0) { 'Green' } else { 'DarkGray' }
        Write-Host (" {0,-11}: {1,3} paquete(s) | {2}" -f $entry.Category, $entry.Count, (Format-AIOUpdateByteSize -Bytes $entry.Size)) -ForegroundColor $color
    }
}


function Show-AIOUpdatePreflightRestoreMenu {
    [CmdletBinding()]
    param()

    Clear-Host
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host '              Restaurador de respaldo Preflight' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ''

    $selected = Select-AIOUpdateFolder -Title 'Selecciona directamente la carpeta Preflight del respaldo actual'
    if (-not $selected) { return }

    $context = Read-AIOUpdatePreflightManifest -PreflightRoot $selected
    $manifest = $context.Manifest
    $target = [string]$manifest.MediaRoot
    if (-not (Test-Path -LiteralPath $target -PathType Container)) {
        $target = Select-AIOUpdateFolder -Title 'Selecciona el medio de Windows que deseas restaurar'
        if (-not $target) { return }
    }

    Write-Host " Respaldo : $($context.Root)" -ForegroundColor White
    Write-Host " Creado   : $($manifest.CreatedAt)" -ForegroundColor White
    Write-Host " Archivos : $($manifest.FileCount)" -ForegroundColor White
    Write-Host " Destino  : $target" -ForegroundColor White
    Write-Host ''
    Write-Host ' [1] Restaurar todo el medio respaldado' -ForegroundColor White
    Write-Host ' [2] Restaurar solamente install.wim' -ForegroundColor White
    Write-Host ' [3] Restaurar solamente boot.wim' -ForegroundColor White
    Write-Host ' [4] Restaurar Setup, sources y archivos de arranque' -ForegroundColor White
    Write-Host ' [V] Volver' -ForegroundColor DarkGray

    $selection = (Read-MenuOption 'Seleccion').Trim().ToUpperInvariant()
    $scope = switch ($selection) {
        '1' { 'All' }
        '2' { 'InstallWim' }
        '3' { 'BootWim' }
        '4' { 'Setup' }
        default { return }
    }

    $validation = Test-AIOUpdatePreflightBackup -PreflightRoot $context.Root -Scope $scope
    if (-not $validation.Success) {
        throw "El respaldo no es valido: $($validation.Errors -join ' ')"
    }

    Write-Host "`nLa restauracion reemplazara archivos del medio seleccionado." -ForegroundColor Yellow
    $confirmation = (Read-Host 'Escribe RESTAURAR para confirmar').Trim().ToUpperInvariant()
    if ($confirmation -ne 'RESTAURAR') {
        Write-Host 'Restauracion cancelada.' -ForegroundColor Yellow
        return
    }

    $restoreResult = Restore-AIOUpdatePreflightBackup -PreflightRoot $context.Root -TargetMediaRoot $target -Scope $scope
    [void](Initialize-AIOUpdateTerminalState)
    $script:AIOUpdateLastTerminalState.Status = 'Restored'
    $script:AIOUpdateLastTerminalState.Phase = 'Restauracion Preflight'
    $script:AIOUpdateLastTerminalState.Message = "Restauracion $scope completada correctamente."
    $script:AIOUpdateLastTerminalState.MediaRoot = $target
    $script:AIOUpdateLastTerminalState.BackupRoot = $context.Root
    $script:AIOUpdateLastTerminalState.RestorationStatus = 'Restaurado y verificado'
    $script:AIOUpdateLastTerminalState.CompletedTargets = [object[]]@("Restauracion $scope completada")
    if ($restoreResult.StructuredReport) {
        $script:AIOUpdateLastTerminalState.ReportJson = $restoreResult.StructuredReport.JsonPath
        $script:AIOUpdateLastTerminalState.ReportHtml = $restoreResult.StructuredReport.HtmlPath
    }
    Show-AIOUpdateTerminalSummary -Status Restored -Message $script:AIOUpdateLastTerminalState.Message
    Wait-AIOUpdateUser
}

function Show-UpdatesIntegrator-Menu {
    [CmdletBinding()]
    param()

    [void](Initialize-AIOUpdateTerminalState)
    Clear-Host
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host '             INTEGRADOR DE ACTUALIZACIONES             ' -ForegroundColor Cyan
    Write-Host '=======================================================' -ForegroundColor Cyan
    Write-Host ''
    Write-Host ' Principal: install.wim | Opcionales: winre.wim + boot.wim + SetupDU' -ForegroundColor White
    Write-Host ''

    if (-not (Test-AIOUpdateAdministrator)) {
        Write-Host '[ERROR] Ejecuta AdminImagenOffline como Administrador.' -ForegroundColor Red
        Wait-AIOUpdateUser
        return
    }

    if ($Script:IMAGE_MOUNTED -gt 0) {
        Write-Host '[BLOQUEADO] Hay una imagen montada en AdminImagenOffline.' -ForegroundColor Yellow
        Write-Host 'Desmontala antes de iniciar la integracion masiva.' -ForegroundColor Gray
        Wait-AIOUpdateUser
        return
    }

    Write-Host '   [1] Integrar actualizaciones' -ForegroundColor Green
    Write-Host '       SSU, LCU, Enablement, SafeOS, .NET y SetupDU sobre install.wim / winre.wim / boot.wim' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [2] Restaurar un respaldo Preflight' -ForegroundColor Yellow
    Write-Host '       Revierte install.wim, winre.wim y boot.wim al estado previo a la integracion' -ForegroundColor Gray
    Write-Host ''
    Write-Host '   [V] Volver al menu anterior' -ForegroundColor Red
    $operationMode = (Read-MenuOption 'Seleccion').Trim().ToUpperInvariant()
    if ($operationMode -eq '2') {
        try {
            $adkInfo = Initialize-AIOUpdateServicingEnvironment

            Assert-AIOUpdateNoMountedImages
            Show-AIOUpdateAdkStatus -AdkInfo $adkInfo
            Show-AIOUpdatePreflightRestoreMenu
        }
        catch {
            Write-Host "`n[ERROR] $($_.Exception.Message)" -ForegroundColor Red
            Write-AIOUpdateLog -Level ERROR -Message "Restauracion Preflight: $($_.Exception.Message)"
            Wait-AIOUpdateUser
        }
        return
    }
    if ($operationMode -ne '1') {
        if ($operationMode -ne 'V') {
            Write-Host 'Opcion invalida.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
        return
    }

    try {
        $adkInfo = Initialize-AIOUpdateServicingEnvironment

        Assert-AIOUpdateNoMountedImages

        $mediaRoot = Select-AIOUpdateFolder -Title 'Selecciona la carpeta RAIZ del medio de Windows extraido'
        if (-not $mediaRoot) { return }
        $mediaRoot = (Resolve-Path -LiteralPath $mediaRoot -ErrorAction Stop).Path
        $script:AIOUpdateLastTerminalState.MediaRoot = $mediaRoot

        $installWim = Join-Path $mediaRoot 'sources\install.wim'
        $installEsd = Join-Path $mediaRoot 'sources\install.esd'
        $bootWim = Join-Path $mediaRoot 'sources\boot.wim'
        if (-not (Test-Path -LiteralPath $installWim -PathType Leaf)) {
            if (Test-Path -LiteralPath $installEsd -PathType Leaf) {
                throw 'El medio contiene install.esd. Conviertelo a install.wim antes de usar este modulo.'
            }
            throw 'No se encontro sources\install.wim.'
        }
        $bootWimAvailable = Test-Path -LiteralPath $bootWim -PathType Leaf
        if (-not (Test-AIOUpdateMediaWritable -MediaRoot $mediaRoot)) {
            throw 'El medio es de solo lectura. Extrae la ISO a una carpeta local escribible.'
        }

        $repositoryRoot = $null
        $defaultRepository = Join-Path $script:AIOUpdateApplicationRoot 'Actualizaciones'
        if (Test-Path -LiteralPath $defaultRepository -PathType Container) {
            $defaultRepository = (Resolve-Path -LiteralPath $defaultRepository -ErrorAction Stop).Path
            Write-Host "`nRepositorio detectado: $defaultRepository" -ForegroundColor Cyan
            if (Read-AIOUpdateYesNo -Prompt 'Usar este repositorio' -Default $true) {
                $repositoryRoot = $defaultRepository
            }
        }

        if (-not $repositoryRoot) {
            $repositoryRoot = Select-AIOUpdateFolder -Title 'Selecciona la carpeta de actualizaciones CAB/MSU'
            if (-not $repositoryRoot) { return }
            $repositoryRoot = (Resolve-Path -LiteralPath $repositoryRoot -ErrorAction Stop).Path
        }
        Assert-AIOUpdateRepositorySupport -RepositoryRoot $repositoryRoot

        $scanRoot = Join-Path $env:TEMP ('AIO_SCAN_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Initialize-AIOUpdateDirectory -Path $scanRoot -Empty
        try {
            $inventory = @(Get-AIOUpdatePackageInventory -RepositoryRoot $repositoryRoot -ScratchRoot $scanRoot)
        }
        finally {
            Remove-Item -LiteralPath $scanRoot -Recurse -Force -ErrorAction SilentlyContinue
        }

        $validPackages = @($inventory | Where-Object { $_.Installable })
        if ($validPackages.Count -eq 0) {
            throw 'No se encontraron paquetes CAB/MSU utilizables.'
        }

        $installImages = @(Get-AIOUpdateImageMetadata -ImagePath $installWim)

        Clear-Host
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host '                    RESUMEN PREVIO                     ' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor Cyan
        Write-Host " Medio       : $mediaRoot" -ForegroundColor White
        Write-Host " Paquetes    : $repositoryRoot" -ForegroundColor White
        Show-AIOUpdateAdkStatus -AdkInfo $adkInfo
        Write-Host ''
        Show-AIOUpdateInventorySummary -Inventory $inventory

        Write-Host "`n Clasificacion detectada:" -ForegroundColor Yellow
        foreach ($item in @($inventory | Where-Object { $_.Installable } | Sort-Object Category, Name)) {
            $checkpointTag = if ($item.IsCheckpoint) { ' [CHECKPOINT]' } else { '' }
            Write-Host ("   [{0,-10}] {1}{2}" -f $item.Category, $item.Name, $checkpointTag) -ForegroundColor White
            Write-Host ("                {0}" -f $item.Reason) -ForegroundColor DarkGray
        }

        $auxiliary = @($inventory | Where-Object { $_.Auxiliary })
        if ($auxiliary.Count -gt 0) {
            Write-Host "`n [AUXILIARES UUP/COMPDB - NO INSTALABLES DIRECTAMENTE]" -ForegroundColor DarkYellow
            foreach ($item in $auxiliary) { Write-Host "   - $($item.Name)" -ForegroundColor DarkGray }
            Write-Host '   Los usa para reconstruir MSU cuando existen fragmentos WIM/PSF;' -ForegroundColor DarkGray
            Write-Host '   con MSU completos no se envian a DISM /Add-Package.' -ForegroundColor DarkGray
        }

        $unknown = @($inventory | Where-Object { $_.Category -eq 'Unknown' })
        if ($unknown.Count -gt 0) {
            Write-Host "`n [NO CLASIFICADOS - OMITIDOS POR SEGURIDAD]" -ForegroundColor Yellow
            foreach ($item in $unknown) {
                Write-Host "   - $($item.Name)" -ForegroundColor Gray
                Write-Host "     $($item.Reason)" -ForegroundColor DarkGray
            }
            Write-Host '   Mueve un paquete confirmado a una subcarpeta de categoria para usar una anulacion manual.' -ForegroundColor DarkGray
        }

        $indexes = Select-AIOUpdateInstallIndexes -Images $installImages
        $compatibility = Assert-AIOUpdateCompatibleIndexes -Images $installImages -Indexes $indexes
        Assert-AIOUpdateEsuPrerequisites -Inventory $inventory -Compatibility $compatibility
        $compatibilityEditionId = if ($compatibility.Images[0].PSObject.Properties['EditionId']) { [string]$compatibility.Images[0].EditionId } else { '' }

        $incompatible = @(
            $inventory |
                Where-Object { $_.Installable } |
                Where-Object {
                    -not (Test-AIOUpdatePackageCompatibility -Package $_ -Architecture $compatibility.Architecture -Build $compatibility.Build -ImageName $compatibility.Images[0].ImageName -EditionId $compatibilityEditionId).Compatible
                }
        )
        if ($incompatible.Count -gt 0) {
            Write-Host "`n [OMITIDOS POR COMPATIBILIDAD]" -ForegroundColor DarkYellow
            foreach ($item in $incompatible) {
                $test = Test-AIOUpdatePackageCompatibility -Package $item -Architecture $compatibility.Architecture -Build $compatibility.Build -ImageName $compatibility.Images[0].ImageName -EditionId $compatibilityEditionId
                Write-Host "   - $($item.Name): $($test.Reason)" -ForegroundColor DarkGray
            }
        }

        if (@($inventory | Where-Object { $_.Category -eq 'ESU' }).Count -gt 0) {
            Write-Host "`n [ESU] Se integraran paquetes soportados, pero no se omiten comprobaciones de licencia/activacion." -ForegroundColor Yellow
        }

        Write-Host "`n Configuracion:" -ForegroundColor Yellow
        $updateWinRE = Read-AIOUpdateYesNo -Prompt 'Actualizar y reinyectar winre.wim' -Default $true
        if ($updateWinRE) {
            Write-Host ' WinRE: SSU + SafeOS; la LCU combinada solo prepara la pila de mantenimiento.' -ForegroundColor DarkGray
        }

        $updateBootWim = $false
        if ($bootWimAvailable) {
            $updateBootWim = Read-AIOUpdateYesNo -Prompt 'Actualizar boot.wim y sincronizar binarios de arranque' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] El medio no contiene sources\boot.wim.' -ForegroundColor DarkGray
        }

        $setupPackages = @(Get-AIOUpdatePackages -Inventory $inventory -Category @('SetupDU'))
        $applySetupDU = $false
        if ($setupPackages.Count -gt 0) {
            $applySetupDU = Read-AIOUpdateYesNo -Prompt 'Aplicar Setup Dynamic Update al medio' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] No se detectaron paquetes SetupDU.' -ForegroundColor DarkGray
        }

        Write-Host ' Reaplicacion de paquetes presentes: Automatica.' -ForegroundColor Yellow
        Write-Host ' Los paquetes Installed, InstallPending o Superseded se enviaran nuevamente a DISM sin desinstalarlos.' -ForegroundColor DarkGray
        Write-Host ' CBS puede aceptar el paquete o indicar que la reaplicacion no es necesaria/aplicable.' -ForegroundColor DarkGray

        $bootSigningPolicy = 'Preserve'
        if ($updateBootWim) {
            Write-Host ' Arranque UEFI: automatico; se conserva el firmante verificado del medio.' -ForegroundColor Yellow
        }
        $cleanup = Read-AIOUpdateYesNo -Prompt 'Ejecutar StartComponentCleanup en install.wim'  -Default $true
        $resetBase = $false
        if ($cleanup) {
            $resetBase = Read-AIOUpdateYesNo -Prompt 'Usar ResetBase (impide desinstalar actualizaciones)' -Default $false
        }

        $verifyPrePostCommit = Read-AIOUpdateYesNo -Prompt 'Ejecutar verificaciones completas Pre/Post-Commit' -Default $true
        Write-Host ' Las consultas CBS durante la integracion y las comprobaciones de copia e integridad se mantienen.' -ForegroundColor DarkGray

        $optimizeWims = Read-AIOUpdateYesNo -Prompt 'Reconstruir y optimizar los WIM al terminar' -Default $true
        $wimlib = Find-AIOUpdateWimlib
        $updateWimCreationTime = $false
        if ($wimlib) {
            $updateWimCreationTime = Read-AIOUpdateYesNo -Prompt 'Igualar CREATIONTIME interno con LASTMODIFICATIONTIME' -Default $true
        }
        else {
            Write-Host ' [OMITIDO] Fecha interna del WIM: falta AdminImagenOffline\Tools\wimlib\wimlib-imagex.exe o una instalacion disponible en PATH.' -ForegroundColor DarkGray
        }

        Write-Host "`n=======================================================" -ForegroundColor DarkCyan
        Write-Host ' PLAN DE EJECUCION' -ForegroundColor Cyan
        Write-Host '=======================================================' -ForegroundColor DarkCyan
        Write-Host " Indices install.wim : $($indexes -join ', ')" -ForegroundColor White
        $installOutput = if ($indexes.Count -eq 1) { "solo la edicion seleccionada; indice final 1 (original: $($indexes[0]))" } else { 'se conservan todos los indices del WIM' }
        Write-Host " Salida install.wim  : $installOutput" -ForegroundColor White
        Write-Host " WinRE               : $updateWinRE | SSU + SafeOS; MSU combinado solo para SSU" -ForegroundColor White
        Write-Host " Limpieza install.wim : $cleanup | ResetBase: $resetBase" -ForegroundColor White
        if ($updateWinRE -or $updateBootWim) { Write-Host ' Limpieza WinRE/Boot  : Automatica + ResetBase (se aplaza con operaciones pendientes)' -ForegroundColor White }
        if ($updateBootWim) { Write-Host " Firma UEFI           : $bootSigningPolicy" -ForegroundColor White }
        $bootPlan = if ($updateBootWim) { 'Si, todos los indices' } else { 'No' }
        $setupPlan = if (-not $applySetupDU) {
            'No'
        }
        elseif ($updateBootWim) {
            'Si (medio + indice Setup de boot.wim)'
        }
        else {
            'Si (solo medio; boot.wim omitido)'
        }
        Write-Host " boot.wim            : $bootPlan" -ForegroundColor White
        Write-Host " SetupDU             : $setupPlan" -ForegroundColor White
        Write-Host " Reaplicar presentes : Automatico (sin desinstalar)" -ForegroundColor White
        Write-Host " Verif. Pre/Post     : $verifyPrePostCommit" -ForegroundColor White
        Write-Host " Optimizar WIM       : $optimizeWims (incluye WinRE si se actualiza)" -ForegroundColor White
        if ($indexes.Count -eq 1 -and $installImages.Count -gt 1) { Write-Host ' Exportar edicion unica: requerido por la seleccion de indice, independiente de la optimizacion.' -ForegroundColor DarkGray }
        Write-Host " Fecha CREATIONTIME  : $updateWimCreationTime" -ForegroundColor White
        Write-Host " Respaldo previo     : Obligatorio, antes del primer montaje" -ForegroundColor White
        Write-Host ''

        $start = (Read-MenuOption 'Escribe I para INICIAR o V para volver').Trim().ToUpperInvariant()
        if ($start -ne 'I') {
            $script:AIOUpdateLastTerminalState.Status = 'Cancelled'
            $script:AIOUpdateLastTerminalState.Phase = 'Confirmacion del plan'
            $script:AIOUpdateLastTerminalState.Message = 'No se realizaron cambios en el medio.'
            Show-AIOUpdateTerminalSummary -Status Cancelled -Message $script:AIOUpdateLastTerminalState.Message
            Wait-AIOUpdateUser
            return
        }

        $result = Invoke-AIOUpdateMediaIntegration -MediaRoot $mediaRoot -Inventory $inventory -InstallIndexes $indexes -Compatibility $compatibility -UpdateWinRE:$updateWinRE -UpdateBootWim:$updateBootWim -ApplySetupDU:$applySetupDU -Cleanup:$cleanup -ResetBase:$resetBase -OptimizeWims:$optimizeWims -UpdateWimCreationTime:$updateWimCreationTime -BootSigningPolicy $bootSigningPolicy -VerifyPrePostCommit $verifyPrePostCommit

        Show-AIOUpdateTerminalSummary -Status Success -Message 'La integracion de actualizaciones termino correctamente.'
        Wait-AIOUpdateUser
    }
    catch {
        $errorLine = $_.InvocationInfo.ScriptLineNumber
        $errorCode = if ($_.InvocationInfo.Line) { $_.InvocationInfo.Line.Trim() } else { '' }
        if (-not $script:AIOUpdateLastTerminalState) { [void](Initialize-AIOUpdateTerminalState) }
        $script:AIOUpdateLastTerminalState.Status = 'Failed'
        if (-not $script:AIOUpdateLastTerminalState.Phase -or $script:AIOUpdateLastTerminalState.Phase -eq 'Inicializacion') {
            $script:AIOUpdateLastTerminalState.Phase = $script:AIOUpdateCurrentPhase
        }
        $script:AIOUpdateLastTerminalState.Message = $_.Exception.Message
        $script:AIOUpdateLastTerminalState.ErrorLine = $errorLine
        $script:AIOUpdateLastTerminalState.ErrorCode = $errorCode
        if ($script:AIOUpdateLastDiagnosticPath) { $script:AIOUpdateLastTerminalState.DiagnosticPath = $script:AIOUpdateLastDiagnosticPath }
        if ($script:AIOUpdateLastPersistentLogPath) { $script:AIOUpdateLastTerminalState.LogPath = $script:AIOUpdateLastPersistentLogPath }
        Write-AIOUpdateLog -Level ERROR -Message $_.Exception.Message
        if ($errorLine) { Write-AIOUpdateLog -Level ERROR -Message "Linea ${errorLine}: $errorCode" }
        Show-AIOUpdateTerminalSummary -Status Failed -Message $_.Exception.Message
        Wait-AIOUpdateUser
    }
}

function WindowsUpdate-Menu {
    [CmdletBinding()]
    param()

    Show-UpdatesIntegrator-Menu
}
