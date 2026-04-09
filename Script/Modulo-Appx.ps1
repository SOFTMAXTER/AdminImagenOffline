# =================================================================
#  Modulo-Appx
#
#  CONTENIDO   : Show-AppxInjector-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Unlock-OfflineKey      : tomar propiedad de clave de registro offline
#    - Restore-KeyOwner       : restaurar propietario de clave de registro offline
#  CARGA       : . "$PSScriptRoot\Modulo-Appx.ps1"
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

function Show-AppxInjector-GUI {

    # ------------------------------------------------------------------
    # 1. Validacion de imagen montada
    # ------------------------------------------------------------------
    if ($Script:IMAGE_MOUNTED -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Primero debes montar una imagen.", "Error", 'OK', 'Error')
        return
    }

    # Variables de estado para el cierre seguro y la cancelacion de DISM
    $script:isAppxDeploying    = $false
    $script:currentDismProcess = $null

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Inyector y Actualizador de Apps Modernas - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(1050, 700)
    $form.StartPosition   = "CenterScreen"
    $form.BackColor       = [System.Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor       = [System.Drawing.Color]::White
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox     = $false

    $lblTitle          = New-Object System.Windows.Forms.Label
    $lblTitle.Text     = "Motor Heuristico de Aprovisionamiento UWP"
    $lblTitle.Font     = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblTitle.Location = "20, 15"
    $lblTitle.AutoSize = $true
    $form.Controls.Add($lblTitle)

    $lblOsInfo           = New-Object System.Windows.Forms.Label
    $lblOsInfo.Text      = "Analizando imagen..."
    $lblOsInfo.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblOsInfo.ForeColor = [System.Drawing.Color]::LightGreen
    $lblOsInfo.Location  = "20, 40"
    $lblOsInfo.AutoSize  = $true
    $form.Controls.Add($lblOsInfo)

    # ListView de cola de paquetes
    $lvAppQueue               = New-Object System.Windows.Forms.ListView
    $lvAppQueue.Location      = "20, 60"
    $lvAppQueue.Size          = "1000, 420"
    $lvAppQueue.View          = "Details"
    $lvAppQueue.FullRowSelect = $true
    $lvAppQueue.GridLines     = $true
    $lvAppQueue.BackColor     = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $lvAppQueue.ForeColor     = [System.Drawing.Color]::White
    $lvAppQueue.Columns.Add("Accion",             120) | Out-Null
    $lvAppQueue.Columns.Add("Tipo",               100) | Out-Null
    $lvAppQueue.Columns.Add("Familia / Paquete",  280) | Out-Null
    $lvAppQueue.Columns.Add("Version",            120) | Out-Null
    $lvAppQueue.Columns.Add("Arch",                70) | Out-Null
    $lvAppQueue.Columns.Add("Deps",                50) | Out-Null
    $lvAppQueue.Columns.Add("Ruta",               300) | Out-Null
    $form.Controls.Add($lvAppQueue)

    # Botones superiores
    $btnAddApp           = New-Object System.Windows.Forms.Button
    $btnAddApp.Text      = "+ Archivos Sueltos"
    $btnAddApp.Location  = "20, 495"
    $btnAddApp.Size      = "150, 35"
    $btnAddApp.BackColor = [System.Drawing.Color]::RoyalBlue
    $btnAddApp.FlatStyle = "Flat"
    $form.Controls.Add($btnAddApp)

    $btnAddFolder           = New-Object System.Windows.Forms.Button
    $btnAddFolder.Text      = "+ Escanear Carpeta (Auto)"
    $btnAddFolder.Location  = "180, 495"
    $btnAddFolder.Size      = "190, 35"
    $btnAddFolder.BackColor = [System.Drawing.Color]::DodgerBlue
    $btnAddFolder.FlatStyle = "Flat"
    $form.Controls.Add($btnAddFolder)

    $btnRemoveApp           = New-Object System.Windows.Forms.Button
    $btnRemoveApp.Text      = "- Quitar Seleccion"
    $btnRemoveApp.Location  = "380, 495"
    $btnRemoveApp.Size      = "150, 35"
    $btnRemoveApp.BackColor = [System.Drawing.Color]::Crimson
    $btnRemoveApp.FlatStyle = "Flat"
    $form.Controls.Add($btnRemoveApp)

    $btnClear           = New-Object System.Windows.Forms.Button
    $btnClear.Text      = "Limpiar Cola"
    $btnClear.Location  = "540, 495"
    $btnClear.Size      = "110, 35"
    $btnClear.BackColor = [System.Drawing.Color]::Gray
    $btnClear.FlatStyle = "Flat"
    $form.Controls.Add($btnClear)

    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Inicializando motor heuristico..."
    $lblStatus.Location  = "20, 610"
    $lblStatus.Size      = "620, 22"
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    $btnApply           = New-Object System.Windows.Forms.Button
    $btnApply.Text      = "EJECUTAR DESPLIEGUE INTELIGENTE"
    $btnApply.Location  = "660, 590"
    $btnApply.Size      = "360, 50"
    $btnApply.BackColor = [System.Drawing.Color]::SeaGreen
    $btnApply.FlatStyle = "Flat"
    $btnApply.Font      = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnApply.Enabled   = $false
    $form.Controls.Add($btnApply)

    # Variables de estado de la imagen (se determinan en Add_Shown)
    $script:imgArch  = "x64"
    $script:imgBuild = 0
    $script:appCache = @{}

    # ------------------------------------------------------------------
    # 3. Funciones helper internas
    # ------------------------------------------------------------------

    # Analiza el nombre de archivo UWP y extrae metadatos estructurados
    function Get-UwpMetadata ([string]$fileName) {
        $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $parts     = $nameNoExt.Split('_')

        $family = if ($parts.Count -gt 0) { $parts[0] } else { $nameNoExt }
        $verStr = if ($parts.Count -gt 1 -and $parts[1] -match '^\d') { $parts[1] } else { "0.0.0.0" }
        $arch   = if ($parts.Count -gt 2) { $parts[2] } else { "neutral" }
        if ($arch -eq "" -or $arch -eq "~") { $arch = "neutral" }

        $isFw = $family -match (
            "VCLibs|NET\.Native|UI\.Xaml|WinJS|Store\.Engagement|DirectX|Advertising|" +
            "WindowsAppRuntime|WinAppRuntime|Microsoft\.WindowsAppSDK|" +
            "Microsoft\.UI\.Xaml|Microsoft\.Graphics\.Win2D"
        )

        return [PSCustomObject]@{
            Family     = $family
            VersionStr = $verStr
            Arch       = $arch
            Type       = if ($isFw) { "LIBRERIA" } else { "APLICACION" }
        }
    }

    # Lee el AppxManifest o AppxBundleManifest en RAM y extrae dependencias reales
    function Get-AppxManifestDependencies ([string]$filePath) {
        $depNames = @()
        $outerZip = $null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $outerZip = [System.IO.Compression.ZipFile]::OpenRead($filePath)

            $bundleManifestEntry = $outerZip.Entries |
                Where-Object { $_.FullName -match 'AppxBundleManifest\.xml$' } |
                Select-Object -First 1

            $xmlStr = $null

            if ($bundleManifestEntry) {
                # Leer AppxBundleManifest.xml para localizar el paquete interno de tipo "application"
                $bmStream = $bundleManifestEntry.Open()
                $bundleXml = $null
                try {
                    $bmReader = New-Object System.IO.StreamReader($bmStream, [System.Text.Encoding]::UTF8, $true)
                    try     { $bundleXml = $bmReader.ReadToEnd() }
                    finally { $bmReader.Dispose() }
                } finally { $bmStream.Dispose() }

                $appPkgElement = [regex]::Match(
                    $bundleXml,
                    '(?i)<Package\b[^>]+\bType=["\''`]application["\''`][^>]*/?>',
                    [System.Text.RegularExpressions.RegexOptions]::Singleline
                )

                $innerPackageFileName = $null
                if ($appPkgElement.Success) {
                    $fileNameAttr = [regex]::Match($appPkgElement.Value, '(?i)\bFileName=["\''`]([^"\''`]+)["\''`]')
                    if ($fileNameAttr.Success) { $innerPackageFileName = $fileNameAttr.Groups[1].Value }
                }

                # Buscar el paquete interno con FileName exacto, fallback a primer .appx/.msix
                $innerEntry = $null
                if ($innerPackageFileName) {
                    $innerEntry = $outerZip.Entries |
                        Where-Object { $_.FullName -match ([regex]::Escape($innerPackageFileName) + '$') } |
                        Select-Object -First 1
                }
                if (-not $innerEntry) {
                    $innerEntry = $outerZip.Entries |
                        Where-Object { $_.FullName -match '\.(appx|msix)$' } |
                        Sort-Object Length -Descending |
                        Select-Object -First 1
                }

                # Extraer el AppxManifest.xml del paquete interno en memoria
                if ($innerEntry) {
                    $innerStream = $innerEntry.Open()
                    $memStream   = New-Object System.IO.MemoryStream
                    try {
                        $innerStream.CopyTo($memStream)
                        $memStream.Position = 0

                        $innerZip = New-Object System.IO.Compression.ZipArchive(
                            $memStream, [System.IO.Compression.ZipArchiveMode]::Read)
                        try {
                            $manifestEntry = $innerZip.Entries |
                                Where-Object { $_.FullName -match 'AppxManifest\.xml$' } |
                                Select-Object -First 1
                            if ($manifestEntry) {
                                $mStream = $manifestEntry.Open()
                                try {
                                    $reader = New-Object System.IO.StreamReader(
                                        $mStream, [System.Text.Encoding]::UTF8, $true)
                                    try     { $xmlStr = $reader.ReadToEnd() }
                                    finally { $reader.Dispose() }
                                } finally { $mStream.Dispose() }
                            }
                        } finally { $innerZip.Dispose() }
                    } finally {
                        $innerStream.Dispose()
                        $memStream.Dispose()
                    }
                }
            } else {
                # Paquete suelto (.appx / .msix) — leer manifiesto directamente
                $entry = $outerZip.Entries |
                    Where-Object { $_.FullName -match 'AppxManifest\.xml$' } |
                    Select-Object -First 1
                if ($entry) {
                    $stream = $entry.Open()
                    try {
                        $reader = New-Object System.IO.StreamReader(
                            $stream, [System.Text.Encoding]::UTF8, $true)
                        try     { $xmlStr = $reader.ReadToEnd() }
                        finally { $reader.Dispose() }
                    } finally { $stream.Dispose() }
                }
            }

            # Extraer dependencias por regex — excluir plataformas Windows (no son deps descargables)
            if ($xmlStr) {
                $regexMatches = [regex]::Matches(
                    $xmlStr,
                    '(?i)<(?:\w+:)?PackageDependency[^>]+\bName=["\''`]([^"\''`\s]+)["\''`]'
                )
                foreach ($m in $regexMatches) {
                    $depName = $m.Groups[1].Value
                    if ($depName -notmatch 'Windows\.Universal|Windows\.Desktop|Windows\.Mobile') {
                        $depNames += $depName
                    }
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo leer manifiesto de '$([System.IO.Path]::GetFileName($filePath))' - $($_.Exception.Message)"
        } finally {
            if ($null -ne $outerZip) { $outerZip.Dispose() }
        }

        return @{
            Success = ($null -ne $xmlStr)
            Deps    = @($depNames | Select-Object -Unique)
        }
    }

    # Agrega un paquete analizado al ListView con accion heuristica (INSTALAR/ACTUALIZAR/OMITIR)
    function Add-UwpToQueue ($MainPkg, $Meta, [array]$Deps, $LicensePath) {
        $action = "INSTALAR"
        $color  = [System.Drawing.Color]::Yellow

        try {
            $fileVerObj = [version]$Meta.VersionStr
            if ($script:appCache.ContainsKey($Meta.Family)) {
                if ($fileVerObj -gt $script:appCache[$Meta.Family]) {
                    $action = "ACTUALIZAR"; $color = [System.Drawing.Color]::Cyan
                } else {
                    $action = "OMITIR (Ya existe)"; $color = [System.Drawing.Color]::Gray
                }
            }
        } catch {}

        # Deduplicar por ruta completa
        foreach ($item in $lvAppQueue.Items) {
            if ($item.SubItems[6].Text -ieq $MainPkg.FullName) { return }
        }

        $appData = [PSCustomObject]@{
            MainPackage  = $MainPkg.FullName
            Dependencies = @($Deps | Select-Object -Unique)
            LicensePath  = $LicensePath
        }

        $newItem           = New-Object System.Windows.Forms.ListViewItem($action)
        $newItem.ForeColor = $color
        $newItem.SubItems.Add($Meta.Type)                             | Out-Null
        $newItem.SubItems.Add($Meta.Family)                           | Out-Null
        $newItem.SubItems.Add($Meta.VersionStr)                       | Out-Null
        $newItem.SubItems.Add($Meta.Arch)                             | Out-Null
        $newItem.SubItems.Add($appData.Dependencies.Count.ToString()) | Out-Null
        $newItem.SubItems.Add($MainPkg.FullName)                      | Out-Null
        $newItem.Tag = $appData

        $lvAppQueue.Items.Add($newItem) | Out-Null
    }

    # Motor heuristico central: agrupa archivos por familia, filtra arquitectura,
    # elige el paquete principal, valida dependencias contra el manifiesto real
    function Process-UwpSelection ($fileList) {
        $lvAppQueue.BeginUpdate()

        # Advertir y filtrar paquetes cifrados
        $encryptedFiles = @($fileList | Where-Object { $_.Extension -match "^\.e(appx|msix|appxbundle|msixbundle)$" })
        if ($encryptedFiles.Count -gt 0) {
            $encNames = ($encryptedFiles | Select-Object -ExpandProperty Name) -join "`n  - "
            [System.Windows.Forms.MessageBox]::Show(
                "Los siguientes paquetes son cifrados (.eappx/.emsix) y requieren descifrado previo:`n`n  - $encNames`n`nSe omitiran automaticamente.",
                "Paquetes Cifrados Detectados", 'OK', 'Warning')
            $fileList = @($fileList | Where-Object { $_.Extension -notmatch "^\.e" })
        }

        $grouped = $fileList | Group-Object { (Get-UwpMetadata $_.Name).Family }

        foreach ($group in $grouped) {
            $familyFiles = $group.Group

            # Filtrar por compatibilidad de arquitectura con la imagen
            $validFiles = @($familyFiles | Where-Object {
                $fArch = (Get-UwpMetadata $_.Name).Arch
                switch ($script:imgArch) {
                    "x64"   { $fArch -notmatch "^arm" }
                    "x86"   { $fArch -notmatch "x64|arm" }
                    "arm64" { $fArch -notmatch "^x64$" }
                    default { $true }
                }
            })
            if ($validFiles.Count -eq 0) { continue }

            $groupType = (Get-UwpMetadata $validFiles[0].Name).Type

            if ($groupType -eq "LIBRERIA") {
                # Cada arquitectura de libreria se añade por separado
                $archGroups = $validFiles | Group-Object { (Get-UwpMetadata $_.Name).Arch }
                foreach ($archGroup in $archGroups) {
                    $bestFw    = $archGroup.Group | Sort-Object Length -Descending | Select-Object -First 1
                    $fwMeta    = Get-UwpMetadata $bestFw.Name
                    $fwLicPath = $null
                    $fwLicFile = Get-ChildItem -Path $bestFw.DirectoryName -Filter "*license*.xml" -File -ErrorAction SilentlyContinue |
                                 Select-Object -First 1
                    if ($fwLicFile) { $fwLicPath = $fwLicFile.FullName }
                    Add-UwpToQueue -MainPkg $bestFw -Meta $fwMeta -Deps @() -LicensePath $fwLicPath
                }
            } else {
                # Seleccion del paquete principal: bundle > archivo por arquitectura
                $mainPkg = $null
                $bundles = @($validFiles | Where-Object { $_.Extension -match "bundle$" })

                if ($bundles.Count -gt 0) {
                    $mainPkg = $bundles | Sort-Object Length -Descending | Select-Object -First 1
                } else {
                    switch ($script:imgArch) {
                        "x64" {
                            $x64     = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "x64" })
                            $neutral = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "neutral" })
                            $x86     = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "x86" })
                            if     ($x64.Count     -gt 0) { $mainPkg = $x64     | Sort-Object Length -Descending | Select-Object -First 1 }
                            elseif ($neutral.Count -gt 0) { $mainPkg = $neutral  | Sort-Object Length -Descending | Select-Object -First 1 }
                            elseif ($x86.Count     -gt 0) { $mainPkg = $x86     | Sort-Object Length -Descending | Select-Object -First 1 }
                        }
                        "arm64" {
                            $arm64   = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "arm64" })
                            $neutral = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "neutral" })
                            $x86     = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "x86" })
                            if     ($arm64.Count   -gt 0) { $mainPkg = $arm64   | Sort-Object Length -Descending | Select-Object -First 1 }
                            elseif ($neutral.Count -gt 0) { $mainPkg = $neutral  | Sort-Object Length -Descending | Select-Object -First 1 }
                            elseif ($x86.Count     -gt 0) { $mainPkg = $x86     | Sort-Object Length -Descending | Select-Object -First 1 }
                        }
                        default {
                            $x86     = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "x86" })
                            $neutral = @($validFiles | Where-Object { (Get-UwpMetadata $_.Name).Arch -eq "neutral" })
                            if     ($x86.Count     -gt 0) { $mainPkg = $x86     | Sort-Object Length -Descending | Select-Object -First 1 }
                            elseif ($neutral.Count -gt 0) { $mainPkg = $neutral  | Sort-Object Length -Descending | Select-Object -First 1 }
                        }
                    }
                }
                if (-not $mainPkg) { continue }

                $realMeta = Get-UwpMetadata $mainPkg.Name

                # Candidatos de dependencia: paquetes en el mismo directorio que sean LIBRERIA
                $dirFiles  = @(Get-ChildItem -Path $mainPkg.DirectoryName -File -ErrorAction SilentlyContinue)
                $depsArray = @()

                foreach ($dep in $dirFiles) {
                    if ($dep.FullName -ieq $mainPkg.FullName) { continue }
                    if ($dep.Extension -notmatch "^\.appx$|^\.msix$|^\.appxbundle$|^\.msixbundle$") { continue }

                    $depMeta = Get-UwpMetadata $dep.Name
                    if ($depMeta.Type -ne "LIBRERIA") { continue }

                    $depArch = $depMeta.Arch
                    if ($script:imgArch -eq "x64"   -and $depArch -match "^arm")    { continue }
                    if ($script:imgArch -eq "x86"   -and $depArch -match "x64|arm") { continue }
                    if ($script:imgArch -eq "arm64" -and $depArch -eq "x64")        { continue }

                    # En x64 solo incluir x86 si es una libreria de compatibilidad conocida (WoW64 aware)
                    if ($script:imgArch -eq "x64" -and $depArch -eq "x86") {
                        $isKnownX86Dep = $depMeta.Family -match "VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime|WinAppRuntime|Microsoft\.UI\.Xaml"
                        if (-not $isKnownX86Dep) { continue }
                    }

                    if ($depsArray -notcontains $dep.FullName) { $depsArray += $dep.FullName }
                }

                # Validar dependencias contra el manifiesto real del paquete
                $manifestRead      = Get-AppxManifestDependencies -filePath $mainPkg.FullName
                $exactDependencies = $manifestRead.Deps
                $validatedDeps     = @()

                if ($manifestRead.Success) {
                    foreach ($depPath in $depsArray) {
                        $depMeta   = Get-UwpMetadata (Split-Path $depPath -Leaf)
                        $isRequired = $false
                        foreach ($exactDep in $exactDependencies) {
                            if ($exactDep -match [regex]::Escape($depMeta.Family) -or
                                $depMeta.Family -match [regex]::Escape($exactDep)) {
                                $isRequired = $true; break
                            }
                        }
                        if ($isRequired) { $validatedDeps += $depPath }
                    }
                } else {
                    Write-Log -LogLevel WARN -Message "AppxInjector: Fallback activado para $($mainPkg.Name)"
                    $validatedDeps = $depsArray
                }

                # Buscar archivo de licencia (.xml)
                $licPath = $null
                $licFile = $dirFiles |
                    Where-Object { $_.Name -match "(?i)license" -and $_.Extension -eq ".xml" } |
                    Select-Object -First 1

                if (-not $licFile) {
                    $msmgLicenses = @($dirFiles |
                        Where-Object { $_.Name.StartsWith($realMeta.Family) -and $_.Extension -eq ".xml" })
                    if ($msmgLicenses.Count -gt 0) {
                        $licFile = switch ($script:imgArch) {
                            "x64"   { $msmgLicenses | Where-Object { $_.Name -notmatch "\.arm\." } | Select-Object -First 1 }
                            "x86"   { $msmgLicenses | Where-Object { $_.Name -notmatch "\.x64\.|\.arm\." } | Select-Object -First 1 }
                            default { $msmgLicenses | Select-Object -First 1 }
                        }
                    }
                }
                if ($licFile) { $licPath = $licFile.FullName }

                Add-UwpToQueue -MainPkg $mainPkg -Meta $realMeta -Deps $validatedDeps -LicensePath $licPath
            }
        }

        $lvAppQueue.EndUpdate()
        $lblStatus.Text      = "Analisis completado. En cola: $($lvAppQueue.Items.Count) elemento(s)."
        $lblStatus.ForeColor = [System.Drawing.Color]::White
        if ($lvAppQueue.Items.Count -gt 0) { $btnApply.Enabled = $true }
    }

    # ------------------------------------------------------------------
    # 4. Eventos
    # ------------------------------------------------------------------

    # Carga inicial: leer cache Appx, montar hives, detectar OS/arch
    $form.Add_Shown({
        $form.Cursor    = [System.Windows.Forms.Cursors]::WaitCursor
        $lblStatus.Text = "Leyendo cache Appx via DISM (Puede tardar 15-30 seg. La ventana no respondera)..."
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()

        # 1. Leer Appx PRIMERO (sin colmenas montadas para evitar colision de archivos)
        try {
            $installed = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR -ErrorAction Stop
            foreach ($app in $installed) {
                try { $script:appCache[$app.DisplayName] = [version]$app.Version } catch {}
            }
            $cacheMsg   = "$($script:appCache.Count) apps en cache"
            $cacheColor = [System.Drawing.Color]::LightGreen
        } catch {
            $cacheMsg   = "Cache no disponible"
            $cacheColor = [System.Drawing.Color]::Salmon
            Write-Log -LogLevel WARN -Message "AppxInjector: Fallo al leer cache - $($_.Exception.Message)"
        }

        # 2. Montar colmenas para el resto de operaciones
        $lblStatus.Text = "Montando colmenas del registro..."
        $form.Refresh()
        [System.Windows.Forms.Application]::DoEvents()

        if (-not (Mount-Hives)) {
            $lblStatus.Text      = "Error fatal: No se pudieron montar las colmenas."
            $lblStatus.ForeColor = [System.Drawing.Color]::Red
            $form.Cursor         = [System.Windows.Forms.Cursors]::Default
            return
        }

        # 3. Detectar arquitectura de la imagen
        if      (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32"))    { $script:imgArch = "arm64" }
        elseif (-not (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64"))) { $script:imgArch = "x86" }
        else    { $script:imgArch = "x64" }

        # 4. Leer build del OS desde el registro offline
        $regCurVer = "HKLM:\OfflineSoftware\Microsoft\Windows NT\CurrentVersion"
        if (Test-Path $regCurVer) {
            try {
                $vd = Get-ItemProperty -Path $regCurVer -ErrorAction SilentlyContinue
                if ($null -ne $vd.CurrentBuildNumber) { $script:imgBuild = [int]$vd.CurrentBuildNumber }
            } catch {}
        }

        $osLabel = if     ($script:imgBuild -ge 26100) { "W11 24H2+" }
                   elseif ($script:imgBuild -ge 22621) { "W11 22H2/23H2" }
                   elseif ($script:imgBuild -ge 22000) { "W11 21H2" }
                   elseif ($script:imgBuild -ge 19041) { "W10 22H2" }
                   else                                 { "Build $($script:imgBuild)" }

        # 5. Actualizar UI
        $lblOsInfo.Text      = "Imagen: $osLabel | Arquitectura: $($script:imgArch) | Build: $($script:imgBuild)"
        $lblStatus.Text      = "Motor Listo | OS: $osLabel | Arch: $($script:imgArch) | $cacheMsg"
        $lblStatus.ForeColor = $cacheColor
        $form.Cursor         = [System.Windows.Forms.Cursors]::Default
        $btnApply.Enabled    = $true
    })

    # Agregar archivos sueltos
    $btnAddApp.Add_Click({
        $ofd             = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Filter      = "Paquetes UWP (*.appx;*.msix;*.appxbundle;*.msixbundle;*.eappx;*.emsix;*.eappxbundle;*.emsixbundle)|*.appx;*.msix;*.appxbundle;*.msixbundle;*.eappx;*.emsix;*.eappxbundle;*.emsixbundle"
        $ofd.Multiselect = $true
        if ($ofd.ShowDialog() -eq 'OK') {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $allFiles = @($ofd.FileNames | ForEach-Object { Get-Item $_ })
            if ($allFiles.Count -gt 0) { Process-UwpSelection $allFiles }
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Escanear carpeta recursivamente
    $btnAddFolder.Add_Click({
        $fbd             = New-Object System.Windows.Forms.FolderBrowserDialog
        $fbd.Description = "Selecciona la carpeta que contiene los paquetes UWP"
        if ($fbd.ShowDialog() -eq 'OK') {
            $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $allFiles    = @(Get-ChildItem -Path $fbd.SelectedPath `
                -Include "*.appx","*.msix","*.appxbundle","*.msixbundle","*.eappx","*.emsix","*.eappxbundle","*.emsixbundle" `
                -Recurse -File -ErrorAction SilentlyContinue)
            if ($allFiles.Count -gt 0) {
                Process-UwpSelection $allFiles
            } else {
                [System.Windows.Forms.MessageBox]::Show(
                    "No se encontraron paquetes UWP en la carpeta.", "Sin resultados", 'OK', 'Information')
            }
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Quitar seleccion — snapshot antes de iterar para evitar bug de coleccion-mutacion
    $btnRemoveApp.Add_Click({
        if ($lvAppQueue.SelectedItems.Count -eq 0) { return }
        $lvAppQueue.BeginUpdate()
        $toRemove = @($lvAppQueue.SelectedItems)
        foreach ($item in $toRemove) { $lvAppQueue.Items.Remove($item) }
        $lvAppQueue.EndUpdate()
        $lblStatus.Text = "En cola: $($lvAppQueue.Items.Count) elemento(s)."
        if ($lvAppQueue.Items.Count -eq 0) { $btnApply.Enabled = $false }
    })

    # Limpiar cola completa
    $btnClear.Add_Click({
        $lvAppQueue.Items.Clear()
        $lblStatus.Text      = "Cola vaciada."
        $lblStatus.ForeColor = [System.Drawing.Color]::Gray
        $btnApply.Enabled    = $false
    })

    # Motor de despliegue inteligente
    $btnApply.Add_Click({
        $pendingItems = @($lvAppQueue.Items | Where-Object { $_.Text -notmatch "OMITIR|INSTALADO|ERROR" })

        if ($pendingItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "No hay paquetes pendientes de instalar.", "Sin pendientes", 'OK', 'Information')
            return
        }

        if ([System.Windows.Forms.MessageBox]::Show(
                "Se desplegaran $($pendingItems.Count) paquetes en la imagen.`nContinuar?",
                "Confirmar Despliegue", 'YesNo', 'Question') -ne 'Yes') { return }

        $script:isAppxDeploying   = $true
        $btnApply.Enabled         = $false
        $btnAddApp.Enabled        = $false
        $btnAddFolder.Enabled     = $false
        $btnClear.Enabled         = $false
        $lblStatus.ForeColor      = [System.Drawing.Color]::Yellow

        $total   = $pendingItems.Count
        $count   = 0; $success = 0; $errors = 0; $skipped = 0

        try {
            # 1. Asegurar hives montadas para Sideloading
            Write-Log -LogLevel INFO -Message "AppxInjector: Preparando registro offline para Sideloading..."
            Mount-Hives | Out-Null

            # 2. Habilitar AllowAllTrustedApps en el registro offline
            $parentPolPath = "HKLM:\OfflineSoftware\Policies\Microsoft\Windows"
            $appxPolPath   = "$parentPolPath\Appx"

            Unlock-OfflineKey -KeyPath $parentPolPath
            try {
                if (-not (Test-Path $appxPolPath)) {
                    New-Item -Path $appxPolPath -Force -ErrorAction SilentlyContinue | Out-Null
                }
                Set-ItemProperty -Path $appxPolPath -Name "AllowAllTrustedApps" -Value 1 -Type DWord -Force
            } catch {
                Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo escribir AllowAllTrustedApps - $($_.Exception.Message)"
            } finally {
                Restore-KeyOwner -KeyPath $parentPolPath
            }

            # 3. Desmontar hives ANTES de llamar a DISM (cede el acceso exclusivo al archivo)
            Write-Log -LogLevel INFO -Message "AppxInjector: Sideloading habilitado. Desmontando colmenas para ceder el control a DISM..."
            Unmount-Hives

            # 4. Ordenar cola: LIBRERIAS primero para evitar errores de dependencia
            $orderedQueue = @($pendingItems | Where-Object { $_.SubItems[1].Text -eq "LIBRERIA" }) +
                            @($pendingItems | Where-Object { $_.SubItems[1].Text -ne "LIBRERIA" })

            # 5. Bucle de inyeccion
            foreach ($item in $orderedQueue) {
                [System.Windows.Forms.Application]::DoEvents()
                $count++

                $appData    = $item.Tag
                $familyName = $item.SubItems[2].Text

                $item.Text      = "PROCESANDO..."
                $item.ForeColor = [System.Drawing.Color]::Cyan
                $item.EnsureVisible()
                $lblStatus.Text = "[$count/$total] $familyName..."
                $form.Refresh()

                Write-Log -LogLevel INFO -Message "AppxInjector: Desplegando [$familyName] -> $($appData.MainPackage)"

                try {
                    $argLine  = "/Image:`"$($Script:MOUNT_DIR.TrimEnd('\'))`" "
                    $argLine += "/Add-ProvisionedAppxPackage "
                    $argLine += "/PackagePath:`"$($appData.MainPackage)`" "

                    if ($script:imgBuild -ge 18362) { $argLine += "/Region:`"all`" " }

                    foreach ($dep in $appData.Dependencies) {
                        $argLine += "/DependencyPackagePath:`"$dep`" "
                    }

                    if ($appData.LicensePath -and (Test-Path $appData.LicensePath)) {
                        $argLine += "/LicensePath:`"$($appData.LicensePath)`""
                    } else {
                        $argLine += "/SkipLicense"
                    }

                    $script:currentDismProcess = Start-Process "dism.exe" `
                        -ArgumentList $argLine -WindowStyle Hidden -PassThru

                    if ($null -eq $script:currentDismProcess) { throw "No se pudo iniciar dism.exe." }

                    while (-not $script:currentDismProcess.HasExited) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 200
                    }

                    $exitCode = $script:currentDismProcess.ExitCode
                    if ($exitCode -eq 0 -or $exitCode -eq 3010) {
                        $item.Text      = if ($exitCode -eq 3010) { "INSTALADO (Reinicio)" } else { "INSTALADO" }
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                        $success++
                        Write-Log -LogLevel INFO -Message "AppxInjector: OK [$familyName] (ExitCode: $exitCode)"
                    } else {
                        $item.Text      = "ERROR (0x$("{0:X}" -f $exitCode))"
                        $item.ForeColor = [System.Drawing.Color]::Red
                        $errors++
                        Write-Log -LogLevel ERROR -Message "AppxInjector: FALLO [$familyName] ExitCode: 0x$("{0:X}" -f $exitCode)"
                    }
                } catch {
                    $item.Text      = "ERROR CRITICO"
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $errors++
                    Write-Log -LogLevel ERROR -Message "AppxInjector: Excepcion desplegando [$familyName] - $($_.Exception.Message)"
                } finally {
                    $script:currentDismProcess = $null
                }
            }

            # 6. Actualizar cache post-despliegue
            try {
                $script:appCache.Clear()
                $installed = Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR -ErrorAction SilentlyContinue
                foreach ($app in $installed) {
                    try { $script:appCache[$app.DisplayName] = [version]$app.Version } catch {}
                }
            } catch {}

            $lblStatus.Text      = "Completado. Exitos: $success | Errores: $errors | Omitidos: $skipped"
            $lblStatus.ForeColor = if ($errors -gt 0) { [System.Drawing.Color]::Salmon } else { [System.Drawing.Color]::LightGreen }

            $msg = "Despliegue finalizado.`n`nExitos:    $success`nErrores:   $errors`nOmitidos:  $skipped"
            if ($errors -gt 0) { $msg += "`n`nRevisa el log para los codigos de error de DISM." }
            [System.Windows.Forms.MessageBox]::Show($msg, "Reporte de Despliegue", 'OK', 'Information')

        } finally {
            $script:isAppxDeploying    = $false
            $script:currentDismProcess = $null
            $btnApply.Enabled          = $true
            $btnAddApp.Enabled         = $true
            $btnAddFolder.Enabled      = $true
            $btnClear.Enabled          = $true
        }
    })

    # Cierre seguro — bloquear si hay despliegue activo, desmontar hives al salir
    $form.Add_FormClosing({
        if ($script:isAppxDeploying) {
            [System.Windows.Forms.MessageBox]::Show(
                "La inyeccion de aplicaciones esta en curso.`nSi cierras ahora corromperas el WIM.`nEspera a que el proceso termine.",
                "Operacion Critica en Curso",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            $_.Cancel = $true
            return
        }
        if ($null -ne $lvAppQueue -and -not $lvAppQueue.IsDisposed) {
            $lvAppQueue.Dispose()
        }
        Write-Log -LogLevel INFO -Message "AppxInjector: Cerrando ventana. Desmontando Hives..."
        try { Unmount-Hives } catch {}
    })

    # ------------------------------------------------------------------
    # 5. Mostrar y limpiar
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null
    $form.Dispose()
    $script:appCache = $null
    [GC]::Collect()
}