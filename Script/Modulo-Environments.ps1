# =================================================================
#  Modulo-Entornos
#
#  CONTENIDO   : Manage-WinRE-Menu, Manage-BootWim-Menu; invocacion de la GUI Setup/fondos
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:WIM_FILE_PATH  : ruta del archivo de imagen base
#    - $Script:MOUNTED_INDEX  : indice WIM montado
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : habilitar privilegios de token
#    - Unlock-Single-File     : romper bloqueos de TrustedInstaller en archivos
#    - Restore-FileOwner      : restaurar SDDL original de archivos
#    - Select-PathDialog      : ui para seleccion de rutas
#    - Initialize-ScratchSpace: limpiar y preparar espacio temporal
#    - Unmount-Image          : logica base para desmontar imagenes
#    - Show-Addons-GUI        : invocacion del inyector de addons
#    - Show-Drivers-GUI       : invocacion del inyector de drivers
#    - Modulo-BootSetup.ps1   : GUI y motor reversible de Setup/fondos
#  CARGA       : . "$PSScriptRoot\Modulo-Environments.ps1"
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

# El cargador del nucleo ya importa BootSetup antes de Environments.
# Mantener tambien el uso directo por dot-source sin duplicar definiciones.
if (-not (Get-Command Show-BootSetup-GUI -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Modulo-BootSetup.ps1')
}

# =================================================================
#  Modulo Avanzado: Gestor de Entorno de RecuperaciOn (WinRE)
# =================================================================
# WinRE: sesiones aisladas, origen del mismo disco y publicacion con respaldo.
function Invoke-AIOWinREDism {
    param([Parameter(Mandatory = $true)][string[]]$DismArguments)
    & dism.exe @DismArguments
    if ($LASTEXITCODE -ne 0) { throw "DISM devolvio $LASTEXITCODE ($($DismArguments[0]))." }
}

function Wait-AIOWinREFile {
    param([string]$Path)
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $stream = $null
        try {
            $stream = [IO.File]::Open($Path, 'Open', 'Read', 'None')
            if ($stream.Length -eq 0) { throw 'El WIM esta vacio.' }
            return
        } catch {
            if ($attempt -eq 14) { throw "No se puede leer el WIM terminado: $Path. $($_.Exception.Message)" }
            Start-Sleep -Seconds 1
        } finally { if ($null -ne $stream) { $stream.Dispose() } }
    }
}

function Get-AIOWinREMetadata {
    param([string]$Path)
    # Audit es obligatorio: no guardar si no podemos respaldar tambien la SACL.
    $acl = Get-Acl -LiteralPath $Path -Audit -ErrorAction Stop
    [pscustomobject]@{
        Sddl = $acl.GetSecurityDescriptorSddlForm([Security.AccessControl.AccessControlSections]::All)
        Attributes = (Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes
    }
}

function Set-AIOWinREMetadata {
    param([string]$Path, $Metadata)
    $current = Get-AIOWinREMetadata -Path $Path
    if ($current.Sddl -cne $Metadata.Sddl) {
        $acl = New-Object Security.AccessControl.FileSecurity
        $acl.SetSecurityDescriptorSddlForm($Metadata.Sddl, [Security.AccessControl.AccessControlSections]::All)
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    }
    if ($current.Attributes -ne $Metadata.Attributes) { [IO.File]::SetAttributes($Path, $Metadata.Attributes) }
}

function Copy-AIOWinREData {
    param([string]$Source, [string]$Destination)
    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::Open($Source, 'Open', 'Read', 'Read')
        # Archivo nuevo: heredar la seguridad del directorio Windows de destino,
        # sin importar las ACL de la particion Recovery ni del espacio temporal.
        $outputStream = [IO.File]::Open($Destination, 'CreateNew', 'Write', 'None')
        $inputStream.CopyTo($outputStream)
        $outputStream.Flush($true)
    } finally {
        if ($null -ne $outputStream) { $outputStream.Dispose() }
        if ($null -ne $inputStream) { $inputStream.Dispose() }
    }
}

function Publish-AIOWinREFile {
    param([string]$Source, [string]$Destination, [string]$OriginalHash, $Metadata, [string]$WorkRoot)
    $id = [guid]::NewGuid().ToString('N')
    $parent = Split-Path -Path $Destination -Parent
    $pending = Join-Path $parent "winre_$id.pending.wim"
    $backup = Join-Path $parent "winre_$id.original.wim"
    $rejected = Join-Path $parent "winre_$id.rejected.wim"
    $expectedHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256 -ErrorAction Stop).Hash
    $attempted = $false
    $publishedNew = $false
    $replaceExisting = -not [string]::IsNullOrEmpty($OriginalHash)
    $verified = $false
    # Guardar las rutas y la seguridad original en la carpeta de trabajo.
    [pscustomobject]@{ Destination = $Destination; DestinationExisted = $replaceExisting; OriginalHash = $OriginalHash
        OriginalSddl = $Metadata.Sddl; Attributes = [int]$Metadata.Attributes
        Pending = $pending; Backup = $backup; Rejected = $rejected
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkRoot 'publicacion.json') -Encoding UTF8 -ErrorAction Stop
    try {
        if (-not (Test-Path -LiteralPath $parent -PathType Container -ErrorAction Stop)) {
            if ($replaceExisting) { throw 'La carpeta de destino desaparecio durante la edicion.' }
            [IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        # La copia hermana comprueba espacio y acceso sin tocar el original.
        Copy-AIOWinREData -Source $Source -Destination $pending
        if ((Get-FileHash -LiteralPath $pending -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
            throw 'La copia preparada no coincide con el WIM editado.'
        }
        if ($replaceExisting) {
            Set-AIOWinREMetadata -Path $pending -Metadata $Metadata
            [IO.File]::SetAttributes($pending, ($Metadata.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            $current = Get-AIOWinREMetadata -Path $Destination
            if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $OriginalHash -or
                $current.Sddl -cne $Metadata.Sddl -or $current.Attributes -ne $Metadata.Attributes) {
                throw 'El WinRE de destino cambio durante la edicion. No se sobrescribira.'
            }
            $attempted = $true
            [IO.File]::SetAttributes($Destination, ($Metadata.Attributes -band (-bnot [IO.FileAttributes]::ReadOnly)))
            # ReplaceFile con respaldo en el mismo volumen y sin ignorar errores de ACL.
            [IO.File]::Replace($pending, $Destination, $backup, $false)
            Set-AIOWinREMetadata -Path $Destination -Metadata $Metadata
        } else {
            $Metadata = Get-AIOWinREMetadata -Path $pending
            # Move de dos argumentos nunca sobrescribe un archivo que aparezca entretanto.
            [IO.File]::Move($pending, $Destination)
            $publishedNew = $true
        }
        $after = Get-AIOWinREMetadata -Path $Destination
        if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash -or
            $after.Sddl -cne $Metadata.Sddl -or $after.Attributes -ne $Metadata.Attributes) {
            throw 'La verificacion final de contenido, propietario, ACL o atributos fallo.'
        }
        $verified = $true
    } catch {
        $publishError = $_.Exception.Message
        if ($publishedNew) {
            try {
                if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expectedHash) {
                    throw 'El archivo nuevo cambio despues de publicarse; se conserva para revision.'
                }
                [IO.File]::Move($Destination, $rejected)
                Write-Warning (Get-AIOString 'environments.winre_pub_cancelled' $rejected)
            } catch {
                throw "Fallo al publicar: $publishError. RECUPERACION REQUERIDA: $($_.Exception.Message). Consulta $WorkRoot\publicacion.json."
            }
        }
        if ($attempted) {
            try {
                if (Test-Path -LiteralPath $backup -PathType Leaf -ErrorAction Stop) {
                    if ((Get-FileHash -LiteralPath $backup -Algorithm SHA256 -ErrorAction Stop).Hash -ne $OriginalHash) {
                        throw "El respaldo no coincide con el original: $backup"
                    }
                    if (Test-Path -LiteralPath $Destination -PathType Leaf -ErrorAction Stop) {
                        [IO.File]::SetAttributes($Destination, [IO.FileAttributes]::Normal)
                        [IO.File]::Replace($backup, $Destination, $rejected, $false)
                    } else { [IO.File]::Move($backup, $Destination) }
                }
                Set-AIOWinREMetadata -Path $Destination -Metadata $Metadata
                $restored = Get-AIOWinREMetadata -Path $Destination
                if ((Get-FileHash -LiteralPath $Destination -Algorithm SHA256 -ErrorAction Stop).Hash -ne $OriginalHash -or
                    $restored.Sddl -cne $Metadata.Sddl -or $restored.Attributes -ne $Metadata.Attributes) {
                    throw 'No se pudo verificar la restauracion del original.'
                }
                Write-Warning (Get-AIOString 'environments.winre_save_cancelled')
            } catch {
                throw "Fallo al publicar: $publishError. RECUPERACION REQUERIDA: $($_.Exception.Message). Consulta $WorkRoot\publicacion.json."
            }
        }
        throw "No se publico WinRE: $publishError. Se conserva el trabajo en $WorkRoot."
    } finally {
        if ($verified) {
            # Un error al borrar el respaldo no invalida una publicacion ya verificada.
            foreach ($path in @($backup, $pending, $rejected)) {
                if (Test-Path -LiteralPath $path) {
                    try { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                    catch { Write-Warning (Get-AIOString 'environments.winre_temp_keep' $path) }
                }
            }
        }
    }
}

function Get-AIOWinRECandidates {
    param([string]$WorkRoot, [System.Collections.Generic.List[object]]$TemporaryAccessPaths)
    $roots = New-Object 'System.Collections.Generic.List[object]'
    $roots.Add([pscustomobject]@{ Root = $Script:MOUNT_DIR; Label = 'Volumen de Windows'; Embedded = $true })
    if ($Script:IMAGE_MOUNTED -eq 2) {
        # Resolver siempre el disco desde el VHD conectado, nunca desde un disco fisico arbitrario.
        $vhd = Get-VHD -Path $Script:WIM_FILE_PATH -ErrorAction Stop
        if (-not $vhd.Attached) { throw 'El VHD de la sesion no esta conectado.' }
        $disks = @($vhd | Get-Disk -ErrorAction Stop)
        if ($disks.Count -ne 1) { throw 'No se pudo identificar un unico disco para este VHD.' }
        $parts = @(Get-Partition -DiskNumber $disks[0].Number -ErrorAction Stop)
        $windowsRoot = $Script:MOUNT_DIR.TrimEnd('\', '/')
        $windowsParts = @($parts | Where-Object {
            $paths = @($_.AccessPaths | ForEach-Object { ([string]$_).TrimEnd('\', '/') })
            ($paths -contains $windowsRoot) -or ($_.DriveLetter -and $windowsRoot -eq "$($_.DriveLetter):")
        })
        if ($windowsParts.Count -ne 1) { throw 'El volumen Windows montado no se pudo vincular al VHD de la sesion.' }
        $roots[0].Label = Get-AIOString 'environments.disk_part_windows' $disks[0].Number $windowsParts[0].PartitionNumber
        foreach ($part in $parts) {
            if ($part.PartitionNumber -eq $windowsParts[0].PartitionNumber) { continue }
            if ($part.Type -ne 'Recovery' -and
                ([string]$part.GptType).Trim('{}') -ne 'de94bba4-06d1-4d40-a16a-bfd50179d6ac' -and
                $part.MbrType -ne 0x27) { continue }
            if ($part.DriveLetter) { $root = "$($part.DriveLetter):\" }
            else {
                $root = Join-Path $WorkRoot "Recovery_$($part.PartitionNumber)"
                New-Item -Path $root -ItemType Directory -ErrorAction Stop | Out-Null
                # Registrar ANTES: una llamada fallida puede haber creado el acceso.
                $TemporaryAccessPaths.Add([pscustomobject]@{ Partition = $part; AccessPath = $root })
                Add-PartitionAccessPath -InputObject $part -AccessPath $root -ErrorAction Stop
            }
            $roots.Add([pscustomobject]@{ Root = $root; Label = (Get-AIOString 'environments.disk_part_recovery' $disks[0].Number $part.PartitionNumber); Embedded = $false })
        }
    }
    foreach ($root in $roots) {
        $relativePaths = @('Recovery\WindowsRE\winre.wim')
        if ($root.Embedded) { $relativePaths = @('Windows\System32\Recovery\winre.wim') + $relativePaths }
        foreach ($relative in $relativePaths) {
            $path = Join-Path $root.Root $relative
            if (Test-Path -LiteralPath $path -PathType Leaf -ErrorAction Stop) {
                [pscustomobject]@{ Path = $path; Label = "$($root.Label): $relative" }
            }
        }
    }
}

function Restore-AIOWinREContext {
    param([hashtable]$Context)
    foreach ($name in $Context.Keys) {
        if ($Context[$name].Exists) { Set-Variable -Name $name -Scope Script -Value $Context[$name].Value }
        else { Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue }
    }
}

function Manage-WinRE-Menu {
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'environments.winre_title') -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Log -LogLevel INFO -Message "WinRE_Manager: Iniciando el modulo de gestion de Entorno de Recuperacion (WinRE)."

    # Si no se pudieron cerrar los hives de una sesion anterior, no mezclar registros.
    if ($Script:AIOWinREPendingContext) {
        Write-Host (Get-AIOString 'environments.winre_pending_ctx') -ForegroundColor Yellow
        try {
            Unmount-Hives | Out-Null
            Restore-AIOWinREContext -Context $Script:AIOWinREPendingContext
            $Script:AIOWinREPendingContext = $null
            Write-Host (Get-AIOString 'environments.winre_ctx_restored') -ForegroundColor Green
        } catch {
            Write-Log -LogLevel WARN -Message "WinRE_Manager: Aun no se pueden liberar los hives de WinRE: $($_.Exception.Message)"
            Write-Warning (Get-AIOString 'environments.winre_hives_busy' $_.Exception.Message)
            Pause; return
        }
    }

    if ($Script:IMAGE_MOUNTED -notin @(1, 2)) {
        Write-Log -LogLevel WARN -Message "WinRE_Manager: Acceso denegado. No hay imagen montada."
        Write-Warning (Get-AIOString 'environments.winre_need_mount')
        Pause; return
    }

    $workRoot = $null
    $winreMount = $null
    $activeMount = $false
    $contextChanged = $false
    $hivesClosed = $true
    $cleanWork = $false
    $temporaryAccessPaths = New-Object 'System.Collections.Generic.List[object]'
    $context = @{}

    try {
        if (-not (Test-Path -LiteralPath (Join-Path $Script:MOUNT_DIR 'Windows\System32\config\SYSTEM') -PathType Leaf)) {
            throw 'El punto de montaje no contiene una instalacion de Windows reconocible.'
        }

        Write-Host (Get-AIOString 'environments.winre_step1') -ForegroundColor Yellow
        $workRoot = Join-Path $Script:Scratch_DIR ("WinRE_" + [guid]::NewGuid().ToString('N'))
        New-Item -Path $workRoot -ItemType Directory -ErrorAction Stop | Out-Null

        $candidates = @(Get-AIOWinRECandidates -WorkRoot $workRoot -TemporaryAccessPaths $temporaryAccessPaths)
        if ($candidates.Count -eq 0) {
            throw 'No se encontro winre.wim en Windows ni en las particiones Recovery del mismo VHD.'
        }

        $selected = $candidates[0]
        if ($candidates.Count -gt 1) {
            Write-Host (Get-AIOString 'environments.winre_multi_found') -ForegroundColor Cyan
            Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
            for ($i = 0; $i -lt $candidates.Count; $i++) {
                $candItem = Get-Item -LiteralPath $candidates[$i].Path -Force -ErrorAction SilentlyContinue
                $candSizeMB = if ($candItem) { "{0:N2} MB" -f ($candItem.Length / 1MB) } else { "N/D" }
                Write-Host "   [$($i + 1)] $($candidates[$i].Label)" -ForegroundColor White -NoNewline
                Write-Host " ($candSizeMB)" -ForegroundColor Yellow
                Write-Host (Get-AIOString 'environments.winre_path_label' $candidates[$i].Path) -ForegroundColor Gray
            }
            Write-Host ""
            Write-Host (Get-AIOString 'environments.cancel_back_enter') -ForegroundColor Red
            Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray

            $choice = 0
            do {
                $answer = if (Get-Command Read-MenuOption -ErrorAction SilentlyContinue) {
                    ([string](Read-MenuOption (Get-AIOString 'environments.winre_select_prompt'))).Trim()
                } else {
                    ([string](Read-Host (Get-AIOString 'environments.winre_select_prompt_fb'))).Trim()
                }
                if ([string]::IsNullOrWhiteSpace($answer) -or $answer.ToUpperInvariant() -eq 'V') {
                    Write-Log -LogLevel INFO -Message "WinRE_Manager: Seleccion de candidato WinRE cancelada por el usuario."
                    $cleanWork = $true
                    return
                }
                if (-not ([int]::TryParse($answer, [ref]$choice) -and $choice -ge 1 -and $choice -le $candidates.Count)) {
                    Write-Warning (Get-AIOString 'environments.winre_select_invalid' $candidates.Count)
                }
            } until ($choice -ge 1 -and $choice -le $candidates.Count)
            $selected = $candidates[$choice - 1]
        }

        $winrePath = $selected.Path
        # Resolver ANTES de redirigir MOUNT_DIR al WinRE temporal.
        $destinationPath = Join-Path $Script:MOUNT_DIR 'Windows\System32\Recovery\winre.wim'
        $origItem = Get-Item -LiteralPath $winrePath -Force -ErrorAction Stop
        $origSizeMB = [math]::Round($origItem.Length / 1MB, 2)
        $baseModeLabel = if ($Script:IMAGE_MOUNTED -eq 2) { "VHD / VHDX" } else { Get-AIOString 'environments.base_wim' }

        Write-Host ""
        Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
        Write-Host (Get-AIOString 'environments.winre_lbl_base_mode') -NoNewline -ForegroundColor Gray; Write-Host $baseModeLabel -ForegroundColor White
        Write-Host (Get-AIOString 'environments.winre_lbl_source') -NoNewline -ForegroundColor Gray; Write-Host $selected.Label -ForegroundColor Cyan
        Write-Host (Get-AIOString 'environments.winre_lbl_size') -NoNewline -ForegroundColor Gray; Write-Host "$origSizeMB MB" -ForegroundColor Yellow
        Write-Host (Get-AIOString 'environments.winre_lbl_dest') -NoNewline -ForegroundColor Gray; Write-Host $destinationPath -ForegroundColor Cyan
        Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray

        Write-Log -LogLevel INFO -Message "WinRE_Manager: Origen -> $winrePath ($origSizeMB MB); destino -> $destinationPath; trabajo -> $workRoot"

        Write-Host (Get-AIOString 'environments.winre_step2') -ForegroundColor Yellow
        Enable-Privileges | Out-Null
        $metadata = Get-AIOWinREMetadata -Path $winrePath
        $originalHash = (Get-FileHash -LiteralPath $winrePath -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = $null
        $destinationMetadata = $null
        if (Test-Path -LiteralPath $destinationPath -PathType Leaf -ErrorAction Stop) {
            if ($destinationPath -eq $winrePath) {
                $destinationHash = $originalHash
                $destinationMetadata = $metadata
            } else {
                $destinationMetadata = Get-AIOWinREMetadata -Path $destinationPath
                $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256 -ErrorAction Stop).Hash
            }
        }

        [pscustomobject]@{ BaseImage = $Script:WIM_FILE_PATH; ImageType = $Script:IMAGE_MOUNTED
            WindowsMount = $Script:MOUNT_DIR; WinRELocation = $selected.Label; AccessPath = $winrePath
            Destination = $destinationPath; DestinationOriginalHash = $destinationHash
            OriginalHash = $originalHash; OriginalSddl = $metadata.Sddl; Attributes = [int]$metadata.Attributes
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $workRoot 'origen.json') -Encoding UTF8 -ErrorAction Stop

        $tempWinrePath = Join-Path $workRoot 'winre_editado.wim'
        Copy-Item -LiteralPath $winrePath -Destination $tempWinrePath -ErrorAction Stop
        [IO.File]::SetAttributes($tempWinrePath, [IO.FileAttributes]::Normal)
        if ((Get-FileHash -LiteralPath $tempWinrePath -Algorithm SHA256 -ErrorAction Stop).Hash -ne $originalHash) {
            throw 'La copia de trabajo no coincide con el WinRE original.'
        }

        $images = @(Get-WindowsImage -ImagePath $tempWinrePath -ErrorAction Stop)
        if ($images.Count -ne 1 -or $images[0].ImageIndex -ne 1) { throw 'Se esperaba un WinRE con un unico indice (1).' }
        $winreImgName = if ($images[0].ImageName) { $images[0].ImageName } else { 'Microsoft Windows Recovery Environment' }
        $winreImgVer  = if ($images[0].Version)   { $images[0].Version }   else { 'N/D' }
        Write-Host (Get-AIOString 'environments.winre_copy_verified' $winreImgName $winreImgVer) -ForegroundColor Green

        $winreMount = Join-Path $workRoot 'Mount'
        New-Item -Path $winreMount -ItemType Directory -ErrorAction Stop | Out-Null

        Write-Host (Get-AIOString 'environments.winre_step3') -ForegroundColor Yellow
        Write-Log -LogLevel ACTION -Message "WinRE_Manager: Montando $tempWinrePath en $winreMount..."
        # Un montaje fallido puede quedar registrado: conservar la carpeta en ese caso.
        $activeMount = $true
        Invoke-AIOWinREDism -DismArguments @('/Mount-Image', "/ImageFile:$tempWinrePath", '/Index:1', "/MountDir:$winreMount", '/CheckIntegrity')
        foreach ($relative in @('Windows\System32\config\SYSTEM', 'Windows\System32\config\SOFTWARE', 'Windows\System32\winpeshl.exe')) {
            if (-not (Test-Path -LiteralPath (Join-Path $winreMount $relative) -PathType Leaf)) { throw "La imagen WinRE no contiene $relative." }
        }
        Write-Host (Get-AIOString 'environments.winre_mounted_ok') -ForegroundColor Green
        Write-Host (Get-AIOString 'environments.winre_isolating_reg') -ForegroundColor DarkGray
        Unmount-Hives | Out-Null
        foreach ($name in @('MOUNT_DIR', 'IMAGE_MOUNTED', 'WIM_FILE_PATH', 'MOUNTED_INDEX', 'CachedControlSet',
            'OfflineUserClassesPresent', 'SDDL_Backups', 'FileSDDL_Backups', 'AIODashboardCache', 'ForceMenuRefresh')) {
            $variable = Get-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
            $context[$name] = @{ Exists = ($null -ne $variable); Value = $(if ($variable) { $variable.Value } else { $null }) }
        }
        $contextChanged = $true
        $Script:MOUNT_DIR = $winreMount
        $Script:IMAGE_MOUNTED = 1
        $Script:WIM_FILE_PATH = $tempWinrePath
        $Script:MOUNTED_INDEX = 1
        $Script:CachedControlSet = $null
        $Script:OfflineUserClassesPresent = $null
        $Script:SDDL_Backups = @{}
        $Script:FileSDDL_Backups = @{}
        $Script:AIODashboardCache = $null
        $Script:ForceMenuRefresh = $false
        $hivesClosed = $false

        # --- MENU INTERACTIVO DE EDICION EN WINRE ---
        do {
            Clear-Host
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host (Get-AIOString 'environments.winre_edit_title') -ForegroundColor Magenta
            Write-Host "=======================================================" -ForegroundColor Magenta
            Write-Host (Get-AIOString 'environments.winre_edit_img') -NoNewline -ForegroundColor Gray; Write-Host "$winreImgName (v$winreImgVer)" -ForegroundColor White
            Write-Host (Get-AIOString 'environments.winre_edit_src') -NoNewline -ForegroundColor Gray; Write-Host "$($selected.Label) ($origSizeMB MB)" -ForegroundColor Cyan
            Write-Host (Get-AIOString 'environments.winre_edit_mnt') -NoNewline -ForegroundColor Gray; Write-Host $winreMount -ForegroundColor Yellow
            Write-Host (Get-AIOString 'environments.winre_edit_dst') -NoNewline -ForegroundColor Gray; Write-Host $destinationPath -ForegroundColor Cyan
            Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
            Write-Host ""
            Write-Host (Get-AIOString 'environments.opt_inject_addons') -ForegroundColor White
            Write-Host (Get-AIOString 'environments.winre_opt1_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host (Get-AIOString 'environments.opt_inject_drivers') -ForegroundColor Cyan
            Write-Host (Get-AIOString 'environments.winre_opt2_desc') -ForegroundColor Gray
            Write-Host ""
            Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
            Write-Host (Get-AIOString 'environments.opt_finish_save') -ForegroundColor Green
            Write-Host ""

            $option = ([string](Read-Host (Get-AIOString 'common.select_option_spaced'))).Trim().ToUpperInvariant()
            switch ($option) {
                '1' {
                    try {
                        Write-Log -LogLevel INFO -Message 'WinRE_Manager: Lanzando inyector de Addons sobre WinRE.'
                        Show-Addons-GUI
                    } catch {
                        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Error en Addons GUI: $($_.Exception.Message)"
                        Write-Warning $_.Exception.Message
                        Pause
                    }
                }
                '2' {
                    try {
                        Write-Log -LogLevel INFO -Message 'WinRE_Manager: Lanzando inyector de Drivers sobre WinRE.'
                        Show-Drivers-GUI
                    } catch {
                        Write-Log -LogLevel ERROR -Message "WinRE_Manager: Error en Drivers GUI: $($_.Exception.Message)"
                        Write-Warning $_.Exception.Message
                        Pause
                    }
                }
                'T' {
                    Write-Log -LogLevel INFO -Message 'WinRE_Manager: El usuario finalizo la edicion interactiva.'
                }
                default {
                    Write-Warning (Get-AIOString 'environments.winre_opt_invalid')
                    Start-Sleep -Seconds 1
                }
            }
        } until ($option -eq 'T')

        Write-Host ""
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'environments.winre_finish_title') -ForegroundColor Cyan
        Write-Host "=======================================================" -ForegroundColor Cyan
        Write-Host (Get-AIOString 'environments.winre_finish_yes') -ForegroundColor Green
        Write-Host (Get-AIOString 'environments.winre_finish_no') -ForegroundColor Yellow
        Write-Host ""

        $save = $null
        do {
            $rawSave = ([string](Read-Host (Get-AIOString 'environments.winre_save_prompt'))).Trim()
            $save = if (Test-AIOYesResponse $rawSave) { 'S' } elseif (Test-AIONoResponse $rawSave) { 'N' } else { '' }
            if ($save -notin @('S', 'N')) {
                Write-Warning (Get-AIOString 'environments.save_invalid_sn')
            }
        } until ($save -in @('S', 'N'))

        # Los hives deben quedar descargados antes de CUALQUIER desmontaje DISM.
        $step4Label = if ($save -eq 'N') { Get-AIOString 'environments.winre_step4_discard' } else { Get-AIOString 'environments.winre_step4_commit' }
        Write-Host "`n$step4Label" -ForegroundColor Yellow
        Unmount-Hives | Out-Null
        $hivesClosed = $true

        if ($save -eq 'N') {
            Write-Log -LogLevel INFO -Message "WinRE_Manager: El usuario eligio descartar los cambios (/Discard)."
            Invoke-AIOWinREDism -DismArguments @('/Unmount-Image', "/MountDir:$winreMount", '/Discard')
            $activeMount = $false
            $cleanWork = $true
            Write-Host (Get-AIOString 'environments.winre_discarded_ok') -ForegroundColor Gray
        } else {
            Write-Log -LogLevel ACTION -Message "WinRE_Manager: Guardando cambios en el montaje temporal (/Commit /CheckIntegrity)..."
            Invoke-AIOWinREDism -DismArguments @('/Unmount-Image', "/MountDir:$winreMount", '/Commit', '/CheckIntegrity')
            $activeMount = $false
            Wait-AIOWinREFile -Path $tempWinrePath

            Write-Host (Get-AIOString 'environments.winre_step5') -ForegroundColor Cyan
            $finalPath = Join-Path $workRoot 'winre_final.wim'
            Invoke-AIOWinREDism -DismArguments @('/Export-Image', "/SourceImageFile:$tempWinrePath", '/SourceIndex:1',
                "/DestinationImageFile:$finalPath", '/Compress:max', '/Bootable', '/CheckIntegrity')
            Wait-AIOWinREFile -Path $finalPath

            Write-Host (Get-AIOString 'environments.winre_verify_ro') -ForegroundColor DarkGray
            $activeMount = $true
            Invoke-AIOWinREDism -DismArguments @('/Mount-Image', "/ImageFile:$finalPath", '/Index:1', "/MountDir:$winreMount", '/ReadOnly', '/CheckIntegrity')
            foreach ($relative in @('Windows\System32\config\SYSTEM', 'Windows\System32\config\SOFTWARE', 'Windows\System32\winpeshl.exe')) {
                if (-not (Test-Path -LiteralPath (Join-Path $winreMount $relative) -PathType Leaf)) { throw "El WinRE final no contiene $relative." }
            }
            Invoke-AIOWinREDism -DismArguments @('/Unmount-Image', "/MountDir:$winreMount", '/Discard')
            $activeMount = $false
            Wait-AIOWinREFile -Path $finalPath

            Write-Host (Get-AIOString 'environments.winre_pub_atomic') -ForegroundColor DarkGray
            Publish-AIOWinREFile -Source $finalPath -Destination $destinationPath -OriginalHash $destinationHash -Metadata $destinationMetadata -WorkRoot $workRoot
            $cleanWork = $true

            $finalItem = Get-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
            $finalSizeMB = if ($finalItem) { [math]::Round($finalItem.Length / 1MB, 2) } else { 0 }

            Write-Host ""
            Write-Host "=======================================================" -ForegroundColor Green
            Write-Host (Get-AIOString 'environments.winre_success_title') -ForegroundColor Green
            Write-Host "=======================================================" -ForegroundColor Green
            Write-Host (Get-AIOString 'environments.winre_success_dest' $destinationPath) -ForegroundColor White
            Write-Host (Get-AIOString 'environments.winre_success_size' $origSizeMB $finalSizeMB) -ForegroundColor Cyan
            Write-Host (Get-AIOString 'environments.winre_success_sec') -ForegroundColor Green
            if ($context.IMAGE_MOUNTED.Value -eq 1) {
                Write-Host (Get-AIOString 'environments.winre_success_note') -ForegroundColor Yellow
            }
            Write-Log -LogLevel INFO -Message "WinRE_Manager: Guardado y verificado en $destinationPath ($origSizeMB MB -> $finalSizeMB MB)."
        }
    } catch {
        Write-Warning $_.Exception.Message
        Write-Log -LogLevel ERROR -Message "WinRE_Manager: $($_.Exception.Message)"
    } finally {
        if ($contextChanged) {
            if (-not $hivesClosed) {
                try { Unmount-Hives | Out-Null; $hivesClosed = $true }
                catch { Write-Warning (Get-AIOString 'environments.winre_hives_open' $_.Exception.Message) }
            }
            if ($hivesClosed) { Restore-AIOWinREContext -Context $context }
            else {
                # Mantener la identidad real del registro hasta que pueda descargarse.
                $Script:AIOWinREPendingContext = $context
                Write-Warning (Get-AIOString 'environments.winre_ctx_still_open')
            }
        }
        $accessPathsRemoved = $true
        foreach ($access in $temporaryAccessPaths) {
            try { Remove-PartitionAccessPath -InputObject $access.Partition -AccessPath $access.AccessPath -ErrorAction Stop }
            catch { $accessPathsRemoved = $false; Write-Warning (Get-AIOString 'environments.winre_access_keep' $access.AccessPath) }
        }
        if ($workRoot) {
            if ($cleanWork -and -not $activeMount -and $accessPathsRemoved -and $hivesClosed) {
                try { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction Stop }
                catch { Write-Warning (Get-AIOString 'environments.winre_temp_err' $workRoot) }
            } else {
                Write-Warning (Get-AIOString 'environments.winre_work_kept' $workRoot)
                if ($activeMount) { Write-Warning (Get-AIOString 'environments.winre_check_dism' $winreMount) }
            }
        }
    }
    Pause
}

function Manage-BootWim-Menu {
    $bootEditorSource = $MyInvocation.MyCommand.ScriptBlock.File
    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'environments.boot_title') -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan

    Write-Log -LogLevel INFO -Message "BootWimManager: Iniciando modulo de gestion de arranque (boot.wim)."

    # 1. Seguridad: Verificar que no haya nada montado
    if ($Script:IMAGE_MOUNTED -ne 0) {
        Write-Log -LogLevel WARN -Message "BootWimManager: Acceso bloqueado. Ya existe una imagen montada en $Script:MOUNT_DIR."
        Write-Warning (Get-AIOString 'environments.boot_already_mounted' $Script:MOUNT_DIR)
        Write-Host (Get-AIOString 'environments.boot_unmount_first') -ForegroundColor Gray
        Pause; return
    }

    # 2. Seleccionar archivo
    Write-Host (Get-AIOString 'environments.boot_step1') -ForegroundColor Yellow
    $bootPath = Select-PathDialog -DialogType File -Title (Get-AIOString 'environments.boot_dialog_title') -Filter (Get-AIOString 'environments.boot_filter')
    if (-not $bootPath) { 
        Write-Log -LogLevel INFO -Message "BootWimManager: El usuario cancelo la seleccion del archivo boot.wim."
        return 
    }

    $bootItem = Get-Item -LiteralPath $bootPath -Force -ErrorAction SilentlyContinue
    $bootSizeMB = if ($bootItem) { [math]::Round($bootItem.Length / 1MB, 2) } else { 0 }
    Write-Host (Get-AIOString 'environments.boot_selected_lbl') -NoNewline -ForegroundColor Gray
    Write-Host "$bootPath ($bootSizeMB MB)" -ForegroundColor Cyan
    Write-Log -LogLevel INFO -Message "BootWimManager: Archivo seleccionado -> $bootPath ($bootSizeMB MB)"

    # 3. Analizar Indices
    Write-Host (Get-AIOString 'environments.boot_step2') -ForegroundColor Yellow
    try {
        $images = @(Get-WindowsImage -ImagePath $bootPath -ErrorAction Stop)
    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo al leer la estructura de indices del WIM. Probable corrupcion. - $($_.Exception.Message)"
        Write-Warning (Get-AIOString 'environments.boot_read_err')
        Pause; return
    }

    Write-Host (Get-AIOString 'environments.boot_indexes_found') -ForegroundColor Cyan
    Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
    $idxSetup = $null
    $idxPE = $null
    $setupNamePattern = "Setup|(?<!Pre)Installation|Instalar|Instalaci[oó]n"

    foreach ($img in $images) {
        $desc = "Generico"
        # Heuristica para identificar que es cada indice
        if ($img.ImageName -match $setupNamePattern) { 
            $desc = "Instalador de Windows (Setup)"; $idxSetup = $img.ImageIndex 
        }
        elseif ($img.ImageName -match "PE|Preinstallation") { 
            $desc = "Windows PE (Rescate/Live)"; $idxPE = $img.ImageIndex 
        }
        $verTxt = if ($img.Version) { " | v$($img.Version)" } else { "" }

        Write-Log -LogLevel INFO -Message "BootWimManager: Indice detectado [$($img.ImageIndex)] $($img.ImageName) -> $desc"
        Write-Host "   [$($img.ImageIndex)] $($img.ImageName)$verTxt" -ForegroundColor White -NoNewline
        Write-Host " --> $desc" -ForegroundColor Yellow
    }
    Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""

    # 4. Seleccion Inteligente
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'environments.boot_which_idx_title') -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    $peLabel = if ($null -ne $idxPE) { Get-AIOString 'environments.idx_fmt' $idxPE } else { Get-AIOString 'environments.not_auto_detected' }
    $setupLabel = if ($null -ne $idxSetup) { Get-AIOString 'environments.idx_fmt' $idxSetup } else { Get-AIOString 'environments.not_auto_detected' }

    Write-Host (Get-AIOString 'environments.boot_opt1_pe' $peLabel) -ForegroundColor White
    Write-Host (Get-AIOString 'environments.boot_opt1_desc') -ForegroundColor Gray
    Write-Host ""
    Write-Host (Get-AIOString 'environments.boot_opt2_setup' $setupLabel) -ForegroundColor White
    Write-Host (Get-AIOString 'environments.boot_opt2_desc') -ForegroundColor Gray
    Write-Host ""
    Write-Host (Get-AIOString 'environments.boot_opt_manual') -ForegroundColor DarkGray
    Write-Host (Get-AIOString 'environments.cancel_back_enter') -ForegroundColor Red
    Write-Host ""

    $sel = if (Get-Command Read-MenuOption -ErrorAction SilentlyContinue) {
        ([string](Read-MenuOption (Get-AIOString 'environments.boot_select_prompt'))).Trim().ToUpperInvariant()
    } else {
        ([string](Read-Host (Get-AIOString 'environments.boot_select_prompt_fb'))).Trim().ToUpperInvariant()
    }

    if ([string]::IsNullOrWhiteSpace($sel) -or $sel -eq 'V') {
        Write-Log -LogLevel INFO -Message "BootWimManager: Seleccion de indice cancelada por el usuario."
        return
    }

    $targetIndex = $null
    switch ($sel) {
        "1" { $targetIndex = $idxPE }
        "2" { $targetIndex = $idxSetup }
        "M" { $targetIndex = Read-Host (Get-AIOString 'environments.boot_manual_prompt') }
    }

    $parsedIndex = 0
    if (-not [int]::TryParse([string]$targetIndex, [ref]$parsedIndex) -or
        $parsedIndex -lt 1 -or $parsedIndex -notin @($images | ForEach-Object { [int]$_.ImageIndex })) { 
        Write-Log -LogLevel WARN -Message "BootWimManager: Seleccion de indice invalida o vacia."
        Write-Warning (Get-AIOString 'conversion.index_invalid'); Pause; return 
    }

    $targetIndex = $parsedIndex
    # Clasificar el indice elegido, tambien cuando se selecciono manualmente.
    # No asumir que Windows Setup siempre ocupa el indice numerico 2.
    $selectedImage = $images | Where-Object { [int]$_.ImageIndex -eq $targetIndex } | Select-Object -First 1
    $isSetupIndex = ([string]$selectedImage.ImageName -match $setupNamePattern)
    $selectedImgName = if ($selectedImage -and $selectedImage.ImageName) { $selectedImage.ImageName } else { "Indice $targetIndex" }
    $selectedImgVer  = if ($selectedImage -and $selectedImage.Version)   { $selectedImage.Version }   else { "N/D" }
    $selectedRole    = if ($isSetupIndex) { Get-AIOString 'environments.role_setup' } elseif ([string]$selectedImage.ImageName -match "PE|Preinstallation") { Get-AIOString 'environments.role_winpe' } else { Get-AIOString 'environments.role_generic' }

    Write-Log -LogLevel INFO -Message "BootWimManager: Indice objetivo fijado en -> [$targetIndex] ($selectedImgName - $selectedRole)"

    # 5. Proceso de Montaje y Edicion
    $bootMountActive = $false
    try {
        # Contexto compartido para los modulos de addons, drivers y desmontaje.
        $Script:WIM_FILE_PATH = $bootPath
        $Script:MOUNTED_INDEX = $targetIndex
        # Marcar como montada solo despues del exito real de DISM.
        
        # Limpieza previa
        Initialize-ScratchSpace

        # Montaje Real
        Write-Log -LogLevel ACTION -Message "BootWimManager: Iniciando montaje del boot.wim (Indice: $targetIndex)..."
        Write-Host (Get-AIOString 'environments.boot_step3' $targetIndex $selectedImgName) -ForegroundColor Yellow
        dism /mount-wim /wimfile:"$Script:WIM_FILE_PATH" /index:$Script:MOUNTED_INDEX /mountdir:"$Script:MOUNT_DIR"

        if ($LASTEXITCODE -eq 0) {
            $bootMountActive = $true
            $Script:IMAGE_MOUNTED = 1
            $setupSession = New-AIOBootSetupSession -MountPath $Script:MOUNT_DIR -BootPath $bootPath -IsSetupIndex:$isSetupIndex
            Write-Host (Get-AIOString 'environments.boot_mounted_ok' $Script:MOUNT_DIR) -ForegroundColor Green
            Write-Log -LogLevel INFO -Message "BootWimManager: Montaje exitoso. Desplegando menu de edicion en vivo."

            # --- MINI-MENU DE EDICION BOOT.WIM ---
            $doneEditingBoot = $false
            while (-not $doneEditingBoot) {
                Clear-Host
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host (Get-AIOString 'environments.boot_edit_title') -ForegroundColor Magenta
                Write-Host "=======================================================" -ForegroundColor Magenta
                Write-Host (Get-AIOString 'environments.boot_edit_file') -NoNewline -ForegroundColor Gray; Write-Host "$bootPath ($bootSizeMB MB)" -ForegroundColor Cyan
                Write-Host (Get-AIOString 'environments.boot_edit_idx') -NoNewline -ForegroundColor Gray; Write-Host "[$targetIndex] $selectedImgName (v$selectedImgVer)" -ForegroundColor White
                Write-Host (Get-AIOString 'environments.boot_edit_role') -NoNewline -ForegroundColor Gray; Write-Host $selectedRole -ForegroundColor Yellow
                Write-Host (Get-AIOString 'environments.winre_edit_mnt') -NoNewline -ForegroundColor Gray; Write-Host $Script:MOUNT_DIR -ForegroundColor Yellow
                Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
                Write-Host ""
                Write-Host (Get-AIOString 'environments.opt_inject_addons') -ForegroundColor White
                Write-Host (Get-AIOString 'environments.boot_opt1_edit_desc') -ForegroundColor Gray
                Write-Host ""
                Write-Host (Get-AIOString 'environments.opt_inject_drivers') -ForegroundColor Cyan
                Write-Host (Get-AIOString 'environments.boot_opt2_edit_desc') -ForegroundColor Gray
                if ($isSetupIndex) {
                    Write-Host ""
                    Write-Host (Get-AIOString 'environments.boot_opt3_setup') -ForegroundColor Yellow
                    Write-Host (Get-AIOString 'environments.boot_opt3_desc') -ForegroundColor Gray
                    $summaryText = Get-AIOBootSetupSessionSummary -Session $setupSession
                    foreach ($sLine in ($summaryText -split "\r?\n")) {
                        if (-not [string]::IsNullOrWhiteSpace($sLine)) {
                            $sColor = if ($sLine -match '^ERROR') { [System.ConsoleColor]::Red } else { [System.ConsoleColor]::Cyan }
                            Write-Host "       -> $sLine" -ForegroundColor $sColor
                        }
                    }
                }
                Write-Host ""
                Write-Host "-------------------------------------------------------" -ForegroundColor DarkGray
                Write-Host (Get-AIOString 'environments.opt_finish_save') -ForegroundColor Green
                Write-Host ""
                
                $opcionBoot = ([string](Read-Host (Get-AIOString 'common.select_option_spaced'))).Trim().ToUpperInvariant()
                switch ($opcionBoot) {
                    "1" {
                        try {
                            Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Addons."
                            Show-Addons-GUI
                        } catch {
                            Write-Log -LogLevel ERROR -Message "BootWimManager: Error en Addons GUI: $($_.Exception.Message)"
                            Write-Warning $_.Exception.Message
                            Pause
                        }
                    }
                    "2" {
                        try {
                            Write-Log -LogLevel INFO -Message "BootWimManager: Lanzando inyector de Drivers."
                            Show-Drivers-GUI
                        } catch {
                            Write-Log -LogLevel ERROR -Message "BootWimManager: Error en Drivers GUI: $($_.Exception.Message)"
                            Write-Warning $_.Exception.Message
                            Pause
                        }
                    }
                    { $isSetupIndex -and $_ -eq '3' } {
                        try {
                            Write-Log -LogLevel INFO -Message 'BootWimManager: Abriendo GUI de Setup, bypass y fondos.'
                            Show-BootSetup-GUI -Session $setupSession
                        } catch {
                            Write-Log -LogLevel ERROR -Message "BootWimManager: GUI Setup: $($_.Exception.Message)"
                            Write-Warning $_.Exception.Message
                            Pause
                        }
                    }
                    "T" {
                        Write-Host ""
                        Write-Host "=======================================================" -ForegroundColor Cyan
                        Write-Host (Get-AIOString 'environments.boot_finish_title') -ForegroundColor Cyan
                        Write-Host "=======================================================" -ForegroundColor Cyan
                        Write-Host (Get-AIOString 'environments.boot_finish_yes') -ForegroundColor Green
                        Write-Host (Get-AIOString 'environments.boot_finish_no') -ForegroundColor Yellow
                        Write-Host ""

                        $saveBoot = $null
                        do {
                            $rawSaveBoot = ([string](Read-Host (Get-AIOString 'environments.boot_save_prompt'))).Trim()
                            $saveBoot = if (Test-AIOYesResponse $rawSaveBoot) { 'S' } elseif (Test-AIONoResponse $rawSaveBoot) { 'N' } else { '' }
                            if ($saveBoot -notin @('S', 'N')) {
                                Write-Warning (Get-AIOString 'environments.save_invalid_sn')
                            }
                        } until ($saveBoot -in @('S', 'N'))

                        Write-Host (Get-AIOString 'environments.boot_step4') -ForegroundColor Yellow
                        $unmountCalled = $false
                        try {
                            if ($saveBoot -eq 'S') {
                                Invoke-AIOBootSetupPreCommit -Session $setupSession
                                Write-Log -LogLevel ACTION -Message 'BootWimManager: Guardando boot.wim; Setup, bypass y fondos comprobados antes del Commit.'
                                $unmountCalled = $true
                                Unmount-Image -Commit
                                if ($Script:IMAGE_MOUNTED -ne 0) { throw 'DISM no completo el guardado. El montaje sigue activo.' }
                                try { Complete-AIOBootSetupCommit -Session $setupSession }
                                catch {
                                    Write-Warning (Get-AIOString 'environments.boot_external_warn' $_.Exception.Message)
                                    Pause
                                }
                                $afterItem = Get-Item -LiteralPath $bootPath -Force -ErrorAction SilentlyContinue
                                $afterSizeMB = if ($afterItem) { [math]::Round($afterItem.Length / 1MB, 2) } else { $bootSizeMB }
                                Write-Log -LogLevel INFO -Message "BootWimManager: boot.wim guardado correctamente ($bootSizeMB MB -> $afterSizeMB MB)."
                            } else {
                                Undo-AIOBootSetupExternalChanges -Session $setupSession
                                Write-Log -LogLevel INFO -Message 'BootWimManager: Descartando todos los cambios del montaje.'
                                $unmountCalled = $true
                                Unmount-Image
                            }
                            if ($Script:IMAGE_MOUNTED -eq 0) {
                                $bootMountActive = $false
                                $doneEditingBoot = $true
                            }
                        } catch {
                            $closeFailure = $_.Exception.Message
                            $rollbackWarn = $false
                            if ($Script:IMAGE_MOUNTED -ne 0) {
                                try { Undo-AIOBootSetupExternalChanges -Session $setupSession }
                                catch { Write-Warning $_.Exception.Message; $rollbackWarn = $true }
                            }
                            Write-Log -LogLevel ERROR -Message "BootWimManager: No se completo el cierre: $closeFailure"
                            if (-not $unmountCalled -or $rollbackWarn) {
                                Write-Warning $_.Exception.Message
                                Pause
                            }
                        }
                    }
                    default { Write-Warning (Get-AIOString 'common.invalid_option'); Start-Sleep -Seconds 1 }
                }
            }


        } else {
            Write-Log -LogLevel ERROR -Message "BootWimManager: Fallo critico al montar el boot.wim. Codigo DISM: $LASTEXITCODE"
            Write-Error "Fallo al montar el boot.wim."
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
            Pause
        }

    } catch {
        Write-Log -LogLevel ERROR -Message "BootWimManager: Excepcion no controlada en el gestor de arranque - $($_.Exception.Message)"
        Write-Error "Error critico en el gestor de arranque: $_"
        # No perder el seguimiento de un montaje real si falla una operacion.
        if (-not $bootMountActive) {
            $Script:IMAGE_MOUNTED = 0
            $Script:WIM_FILE_PATH = $null
            $Script:MOUNTED_INDEX = $null
        } else {
            Write-Warning (Get-AIOString 'environments.boot_still_mounted')
        }
        Pause
    }
}
