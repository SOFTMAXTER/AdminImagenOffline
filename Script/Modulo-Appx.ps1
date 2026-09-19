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

    # Variables de estado de la imagen (se determinan en Add_Shown)
    $script:imgArch  = "x64"
    $script:imgBuild = 0
    $script:appCache = @{}
    $script:appxDeprovisionedFamilies = @{}
    $script:cancelAppxAfterCurrent = $false
    $script:appxBatchBlocked = $false
    $script:appxBlockReason = ''
    $script:isAppxPreparing = $false

    # FIX MEDIO 5: Cargar el ensamblado de compresion una sola vez en memoria
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    # ------------------------------------------------------------------
    # 2. Construccion del formulario
    # ------------------------------------------------------------------
    $form                 = New-Object System.Windows.Forms.Form
    $form.Text            = "Inyector y Actualizador de Apps Modernas - $Script:MOUNT_DIR"
    $form.Size            = New-Object System.Drawing.Size(1050, 730)
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
    $lblOsInfo.Location  = "20, 42"
    $lblOsInfo.AutoSize  = $true
    $form.Controls.Add($lblOsInfo)

    # ListView de cola de paquetes (Altura ampliada)
    $lvAppQueue               = New-Object System.Windows.Forms.ListView
    $lvAppQueue.Location      = "20, 70"
    $lvAppQueue.Size          = "1000, 460"
    $lvAppQueue.View          = "Details"
    $lvAppQueue.FullRowSelect = $true
    $lvAppQueue.ShowItemToolTips = $true
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

    # --- BARRA DE ACCIONES (Fila Y: 545) ---
    $Y_Acciones = 545

    $btnAddApp            = New-Object System.Windows.Forms.Button
    $btnAddApp.Text       = "+ Archivos Sueltos"
    $btnAddApp.Location   = "20, $Y_Acciones"
    $btnAddApp.Size       = "150, 35"
    $btnAddApp.BackColor  = [System.Drawing.Color]::RoyalBlue
    $btnAddApp.FlatStyle  = "Flat"
    $form.Controls.Add($btnAddApp)

    $btnAddFolder            = New-Object System.Windows.Forms.Button
    $btnAddFolder.Text       = "+ Escanear Carpeta (Auto)"
    $btnAddFolder.Location   = "180, $Y_Acciones"
    $btnAddFolder.Size       = "190, 35"
    $btnAddFolder.BackColor  = [System.Drawing.Color]::DodgerBlue
    $btnAddFolder.FlatStyle  = "Flat"
    $form.Controls.Add($btnAddFolder)

    $btnRemoveApp            = New-Object System.Windows.Forms.Button
    $btnRemoveApp.Text       = "- Quitar Seleccion"
    $btnRemoveApp.Location   = "380, $Y_Acciones"
    $btnRemoveApp.Size       = "150, 35"
    $btnRemoveApp.BackColor  = [System.Drawing.Color]::Crimson
    $btnRemoveApp.FlatStyle  = "Flat"
    $form.Controls.Add($btnRemoveApp)

    $btnClear            = New-Object System.Windows.Forms.Button
    $btnClear.Text       = "Limpiar Cola"
    $btnClear.Location   = "540, $Y_Acciones"
    $btnClear.Size       = "110, 35"
    $btnClear.BackColor  = [System.Drawing.Color]::Gray
    $btnClear.FlatStyle  = "Flat"
    $form.Controls.Add($btnClear)

    $btnCancelAfterCurrent            = New-Object System.Windows.Forms.Button
    $btnCancelAfterCurrent.Text       = "Cancelar despues del actual"
    $btnCancelAfterCurrent.Location   = "660, $Y_Acciones"
    $btnCancelAfterCurrent.Size       = "360, 35"
    $btnCancelAfterCurrent.BackColor  = [System.Drawing.Color]::DarkOrange
    $btnCancelAfterCurrent.FlatStyle  = "Flat"
    $btnCancelAfterCurrent.Enabled    = $false
    $form.Controls.Add($btnCancelAfterCurrent)
    
    # Texto de estado anclado a la izquierda
    $lblStatus           = New-Object System.Windows.Forms.Label
    $lblStatus.Text      = "Inicializando motor heuristico..."
    $lblStatus.Location  = "20, 608"
    $lblStatus.Size      = "620, 22"
    $lblStatus.ForeColor = [System.Drawing.Color]::Yellow
    $form.Controls.Add($lblStatus)

    # Botón de ejecución anclado a la derecha
    $btnApply            = New-Object System.Windows.Forms.Button
    $btnApply.Text       = "EJECUTAR DESPLIEGUE INTELIGENTE"
    $btnApply.Location   = "660, 595"
    $btnApply.Size       = "360, 45"
    $btnApply.BackColor  = [System.Drawing.Color]::SeaGreen
    $btnApply.FlatStyle  = "Flat"
    $btnApply.Font       = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnApply.Enabled    = $false
    $form.Controls.Add($btnApply)

    $chkUpdateAppx = New-Object System.Windows.Forms.CheckBox
    $chkUpdateAppx.Text = 'Actualizar apps ya aprovisionadas con paquetes locales mas recientes'
    $chkUpdateAppx.Location = '20, 584'
    $chkUpdateAppx.Size = '625, 22'
    $chkUpdateAppx.Checked = $false
    $form.Controls.Add($chkUpdateAppx)

    $progressBar          = New-Object System.Windows.Forms.ProgressBar
    $progressBar.Location = "20, 655"
    $progressBar.Size     = "1000, 15"
    $progressBar.Style    = "Continuous"
    $progressBar.Visible  = $false
    $form.Controls.Add($progressBar)

    # ------------------------------------------------------------------
    # 3. Funciones helper internas
    # ------------------------------------------------------------------

    # FIX CRITICO 1: Analiza el paquete UWP leyendo nativamente el nodo <Identity> de su manifiesto XML interno
    function Get-UwpMetadata ([string]$filePath) {
        $nameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($filePath)
        
        # Valores por defecto (Fallback)
        $family = $nameNoExt
        $verStr = "0.0.0.0"
        $arch   = "neutral"
        $isFw   = $false
        $packageFamilyName = ''
        $identityError = 'No se pudo determinar la familia completa desde el manifiesto.' 

        $outerZip = $null
        try {
            $outerZip = [System.IO.Compression.ZipFile]::OpenRead($filePath)
            
            # Buscar el manifiesto principal (AppxManifest para normales, AppxBundleManifest para bundles)
            $manifestEntry = $outerZip.Entries | 
                Where-Object { $_.FullName -match 'AppxManifest\.xml$|AppxBundleManifest\.xml$' } | 
                Sort-Object Length -Descending | 
                Select-Object -First 1

            if ($manifestEntry) {
                $mStream = $manifestEntry.Open()
                $reader = New-Object System.IO.StreamReader($mStream, [System.Text.Encoding]::UTF8, $true)
                $xmlStr = $reader.ReadToEnd()
                
                $reader.Dispose()
                $mStream.Dispose()

                try {
                    $packageFamilyName = Get-AppxManifestFamilyName $xmlStr
                    $identityError = ''
                } catch {
                    $identityError = $_.Exception.Message
                    Write-Log -LogLevel WARN -Message "AppxInjector: Identidad de '$nameNoExt': $identityError"
                }

                # Extracción rápida vía Regex Compilada del nodo <Identity>
                $identityMatch = [regex]::Match($xmlStr, '(?i)<Identity\b([^>]+)/?>')
                if ($identityMatch.Success) {
                    $attrString = $identityMatch.Groups[1].Value

                    $nameMatch = [regex]::Match($attrString, '(?i)\bName=["\''`]([^"\''`]+)["\''`]')
                    if ($nameMatch.Success) { $family = $nameMatch.Groups[1].Value }

                    $verMatch = [regex]::Match($attrString, '(?i)\bVersion=["\''`]([^"\''`]+)["\''`]')
                    if ($verMatch.Success) { $verStr = $verMatch.Groups[1].Value }

                    $archMatch = [regex]::Match($attrString, '(?i)\bProcessorArchitecture=["\''`]([^"\''`]+)["\''`]')
                    if ($archMatch.Success) { 
                        $arch = $archMatch.Groups[1].Value.ToLower() 
                    } elseif ($filePath -match '(?i)bundle$') {
                        $arch = "neutral" # Los bundles agrupan varias arquitecturas
                    }
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo leer el XML nativo de '$nameNoExt'. Usando Fallback por nombre."
            # Fallback de emergencia a tu lógica de nombres original
            $parts = $nameNoExt.Split('_')
            if ($parts.Count -gt 0) { $family = $parts[0] }
            if ($parts.Count -gt 1 -and $parts[1] -match '^\d') { $verStr = $parts[1] }
            if ($parts.Count -gt 2) { $arch = $parts[2].ToLower() }
        } finally {
            if ($null -ne $outerZip) { $outerZip.Dispose() }
        }

        if ($arch -eq "" -or $arch -eq "~") { $arch = "neutral" }

        # Detección heurística de Frameworks/Librerías
        $isFw = $family -match "(?i)VCLibs|NET\.Native|UI\.Xaml|WinJS|Store\.Engagement|DirectX|Advertising|WindowsAppRuntime|WinAppRuntime|Microsoft\.WindowsAppSDK|Microsoft\.Graphics\.Win2D"

        $versionObj = [version]"0.0.0.0"
        try { $versionObj = [version]$verStr } catch {}

        return [PSCustomObject]@{
            Family     = $family
            PackageFamilyName = $packageFamilyName
            IdentityError = $identityError
            VersionStr = $verStr
            Version    = $versionObj
            Arch       = $arch
            Type       = if ($isFw) { "LIBRERIA" } else { "APLICACION" }
        }
    }

    function Get-AppxDeprovisionedMap {
        $map = @{}
        $deprovPath = "HKLM:\OfflineSoftware\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"

        if (Test-Path $deprovPath) {
            Get-ChildItem -Path $deprovPath -ErrorAction SilentlyContinue | ForEach-Object {
                $pkgKey = $_.PSChildName
                if ([string]::IsNullOrWhiteSpace($pkgKey)) { return }

                $map[$pkgKey] = $pkgKey
            }
        }

        return $map
    }

    function Initialize-AppxIdentityNative {
        if ('AIOAppxIdentityNative' -as [type]) { return }
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class AIOAppxIdentityNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct PackageId {
        public uint reserved;
        public uint processorArchitecture;
        public ulong version;
        [MarshalAs(UnmanagedType.LPWStr)] public string name;
        [MarshalAs(UnmanagedType.LPWStr)] public string publisher;
        [MarshalAs(UnmanagedType.LPWStr)] public string resourceId;
        [MarshalAs(UnmanagedType.LPWStr)] public string publisherId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, ExactSpelling=true)]
    static extern int PackageFamilyNameFromId(ref PackageId id, ref uint length, StringBuilder family);
    public static string GetFamily(string name, string publisher) {
        PackageId id = new PackageId { name = name, publisher = publisher };
        uint length = 0;
        int result = PackageFamilyNameFromId(ref id, ref length, null);
        if (result != 122) throw new Win32Exception(result);
        StringBuilder family = new StringBuilder((int)length);
        result = PackageFamilyNameFromId(ref id, ref length, family);
        if (result != 0) throw new Win32Exception(result);
        return family.ToString();
    }
}
'@ -ErrorAction Stop
    }

    function Get-AppxFamilyName {
        param([string]$Name, [string]$Publisher)
        if ([string]::IsNullOrWhiteSpace($Name) -or [string]::IsNullOrWhiteSpace($Publisher)) {
            throw 'La identidad requiere Name y Publisher.'
        }
        Initialize-AppxIdentityNative
        return [AIOAppxIdentityNative]::GetFamily($Name, $Publisher)
    }

    function Get-AppxManifestFamilyName([string]$Text) {
        # El nombre del archivo no es evidencia del hash de editor. Obtener la
        # identidad del manifiesto y pedir a Windows el PackageFamilyName.
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $inputReader = New-Object IO.StringReader($Text)
        $reader = $null
        try {
            $reader = [Xml.XmlReader]::Create($inputReader, $settings)
            $xml = New-Object Xml.XmlDocument
            $xml.XmlResolver = $null
            $xml.Load($reader)
            $id = $xml.SelectSingleNode("/*[local-name()='Package' or local-name()='Bundle']/*[local-name()='Identity']")
            if (-not $id) { throw 'No se encontro Identity en el manifiesto.' }
            return Get-AppxFamilyName $id.GetAttribute('Name') $id.GetAttribute('Publisher')
        } finally {
            if ($reader) { $reader.Dispose() }
            $inputReader.Dispose()
        }
    }

    function Update-AppxInstalledCache {
        Invoke-AppxSafeUnmount 'lectura de apps aprovisionadas'
        $cache = @{}
        foreach ($app in Get-AppxProvisionedPackage -Path $Script:MOUNT_DIR -ErrorAction Stop) {
            if ($app.PackageName -notmatch '^([^_]+)_(\d+\.\d+\.\d+\.\d+)_[^_]+_[^_]*_([0-9a-hjkmnp-tv-z]{13})$') {
                throw "No se pudo identificar la familia aprovisionada: $($app.PackageName)."
            }
            $familyName = $matches[1] + '_' + $matches[3]
            $version = [version]$matches[2]
            if (-not $cache.ContainsKey($familyName) -or $version -gt $cache[$familyName]) { $cache[$familyName] = $version }
        }
        $script:appCache = $cache
    }

    function Get-AppxQueueAction($Data) {
        if ($script:appxBatchBlocked) { return 'BLOQUEADO' }
        $pfn = $Data.PackageFamilyName
        if (-not $pfn) { return 'ERROR IDENTIDAD' }
        if (-not $script:appCache.ContainsKey($pfn)) { return 'INSTALAR' }
        $deprovisioned = $script:appxDeprovisionedFamilies.ContainsKey($pfn)
        if ($Data.Version -gt $script:appCache[$pfn]) {
            if ($chkUpdateAppx.Checked) { return 'ACTUALIZAR' }
            if ($deprovisioned) { return 'REPARAR' }
            return 'OMITIR (Actualizar desactivado)'
        }
        if ($deprovisioned) { return 'REPARAR' }
        return 'OMITIR (Ya existe)'
    }

    function Get-AppxActionColor([string]$Action) {
        switch -Regex ($Action) {
            '^INSTALAR' { return [Drawing.Color]::Yellow }
            '^ACTUALIZAR' { return [Drawing.Color]::Cyan }
            '^REPARAR' { return [Drawing.Color]::Orange }
            '^(ERROR|BLOQUEADO)' { return [Drawing.Color]::Salmon }
            default { return [Drawing.Color]::Gray }
        }
    }

    function Update-AppxQueueActions {
        foreach ($item in $lvAppQueue.Items) {
            if ($item.Text -notmatch '^(INSTALAR|ACTUALIZAR|REPARAR|REPARACION PENDIENTE|OMITIR)') { continue }
            $item.Text = Get-AppxQueueAction $item.Tag
            $item.ForeColor = Get-AppxActionColor $item.Text
        }
        $btnApply.Enabled = -not $script:appxBatchBlocked -and -not $script:isAppxPreparing -and -not $script:isAppxDeploying -and
            @($lvAppQueue.Items | Where-Object { $_.Text -in @('INSTALAR','ACTUALIZAR','REPARAR','REPARACION PENDIENTE') }).Count -gt 0
    }

    function Block-AppxBatch([string]$Message) {
        $script:appxBatchBlocked = $true
        $script:appxBlockReason = $Message
        foreach ($item in $lvAppQueue.Items) {
            if ($item.Text -match '^(OMITIR|INSTALADO|REPARADO|ERROR|BLOQUEADO)') { continue }
            $item.Text = 'BLOQUEADO'; $item.ToolTipText = $Message
            $item.ForeColor = [Drawing.Color]::Salmon
        }
        $btnApply.Enabled = $false
        $chkUpdateAppx.Enabled = $false
        $lblStatus.Text = 'Lote detenido. Pendientes bloqueados; consulte el detalle del error.'
        $lblStatus.ForeColor = [Drawing.Color]::Salmon
        Write-Log -LogLevel ERROR -Message "AppxInjector: $Message"
    }

    function Get-AppxMountedHivePaths {
        foreach ($name in @('OfflineSystem','OfflineSoftware','OfflineComponents','OfflineDefaultUser','OfflineUser','OfflineUserClasses')) {
            $path = 'HKLM:\' + $name
            if (Test-Path -LiteralPath $path -ErrorAction Stop) { $path }
        }
    }

    function Test-AppxOfflineHiveMounted { return @(Get-AppxMountedHivePaths).Count -gt 0 }

    function Invoke-AppxSafeUnmount([string]$Reason = '') {
        $before = @(); $remaining = @(); $failure = $null
        try {
            $before = @(Get-AppxMountedHivePaths)
            if (-not $before.Count) { return }
            Write-Log -LogLevel INFO -Message "AppxInjector: Desmontando colmenas ($Reason): $($before -join ', ')."
            # Tambien detenerse si la funcion emite errores no terminantes o False.
            $ErrorActionPreference = 'Stop'
            $result = @(Unmount-Hives)
            if (@($result | Where-Object { $_ -is [bool] -and -not $_ }).Count) { throw 'Unmount-Hives devolvio False.' }
        } catch { $failure = $_.Exception.Message }
        try { $remaining = @(Get-AppxMountedHivePaths) }
        catch { $failure = "No se pudo verificar el estado de las colmenas: $($_.Exception.Message). $failure" }
        if ($failure -or $remaining.Count) {
            $names = if ($remaining.Count) { $remaining -join ', ' }
                     elseif ($before.Count) { 'Comprobadas al iniciar: ' + ($before -join ', ') }
                     else { 'Estado no verificable' }
            $message = "Desmontaje fallido ($Reason). Colmenas pendientes/afectadas: $names. $failure"
            $script:appxBatchBlocked = $true; $script:appxBlockReason = $message
            Write-Log -LogLevel ERROR -Message "AppxInjector: $message"
            throw (New-Object InvalidOperationException($message))
        }
    }


    function Remove-AppxDeprovisionedMarks ([string[]]$FamilyNames, [switch]$StopOnFailure) {
        $families = @($FamilyNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
        if ($families.Count -eq 0) { return 0 }
        foreach ($family in $families) {
            if ($family -notmatch '^[^_]+_[0-9a-hjkmnp-tv-z]{13}$') {
                throw "Se requiere la familia completa (nombre + hash de editor): $family."
            }
        }

        $mountedHere = $false
        if (-not (Mount-Hives)) {
            Write-Log -LogLevel WARN -Message "AppxInjector: No se pudieron montar hives para limpiar marcas Deprovisioned."
            if ($StopOnFailure) { throw "No se pudieron montar hives para reparar la marca Deprovisioned." }
            return 0
        }
        $mountedHere = $true

        try {
            $removed = 0
            $deprovPath = "HKLM:\OfflineSoftware\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned"
            $readErrorAction = if ($StopOnFailure) { 'Stop' } else { 'SilentlyContinue' }
            if (-not (Test-Path $deprovPath -ErrorAction $readErrorAction)) { return 0 }

            foreach ($family in $families) {
                $matches = @(Get-ChildItem -Path $deprovPath -ErrorAction $readErrorAction |
                    Where-Object { $_.PSChildName -ieq $family })

                foreach ($key in $matches) {
                    try {
                        Remove-Item -LiteralPath $key.PSPath -Recurse -Force -ErrorAction Stop
                        $script:appxDeprovisionedFamilies.Remove($key.PSChildName)
                        $removed++
                        Write-Log -LogLevel INFO -Message "AppxInjector: Marca Deprovisioned eliminada: $($key.PSChildName)"
                    } catch {
                        Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo eliminar Deprovisioned '$($key.PSChildName)' - $($_.Exception.Message)"
                        if ($StopOnFailure) { throw }
                    }
                }
            }

            return $removed
        } finally {
            if ($mountedHere) {
                Invoke-AppxSafeUnmount -Reason "limpieza Deprovisioned"
            }
        }
    }

    # Lee AppxManifest/AppxBundleManifest y extrae SOLO dependencias declaradas realmente.
    # Importante: si el manifiesto se lee bien y no declara dependencias, devuelve 0 dependencias.
    # El fallback amplio solo debe usarse cuando no se pudo leer ningun manifiesto.
    function Get-AppxManifestDependencies ([string]$filePath) {
        $depEntries = @()
        $manifestReadCount = 0
        $outerZip = $null

        function Get-AppxXmlAttributeValue([string]$Text, [string]$AttrName) {
            if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
            $m = [regex]::Match($Text, ('(?i)\b' + [regex]::Escape($AttrName) + '=["\''`]([^"\''`]+)["\''`]'))
            if ($m.Success) { return $m.Groups[1].Value }
            return $null
        }

        function Read-ZipEntryText($Zip, [string]$EntryNamePattern) {
            $entry = $Zip.Entries |
                Where-Object { $_.FullName -match $EntryNamePattern } |
                Select-Object -First 1

            if (-not $entry) { return $null }

            $stream = $entry.Open()
            try {
                $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true)
                try     { return $reader.ReadToEnd() }
                finally { $reader.Dispose() }
            } finally { $stream.Dispose() }
        }

        function Add-DependenciesFromXml([string]$XmlText, [string]$SourceName) {
            if ([string]::IsNullOrWhiteSpace($XmlText)) { return }

            # Se usa regex namespace-aware para soportar uap/uap10/rescap sin depender de XmlNamespaceManager.
            $dependencyElements = [regex]::Matches(
                $XmlText,
                '(?is)<(?:\w+:)?PackageDependency\b[^>]*(?:/>|>.*?</(?:\w+:)?PackageDependency>)'
            )

            foreach ($m in $dependencyElements) {
                $attrString = $m.Value
                $depName = Get-AppxXmlAttributeValue -Text $attrString -AttrName 'Name'
                if ([string]::IsNullOrWhiteSpace($depName)) { continue }

                # Frameworks del sistema/plataforma no se pasan como /DependencyPackagePath.
                if ($depName -match '^(Windows\.|Microsoft\.Windows\.(Universal|Desktop|Mobile)|Microsoft\.Win32WebViewHost)') { continue }

                $minVersion = Get-AppxXmlAttributeValue -Text $attrString -AttrName 'MinVersion'
                $publisher  = Get-AppxXmlAttributeValue -Text $attrString -AttrName 'Publisher'

                $script:__appxDepCollector += [PSCustomObject]@{
                    Name       = $depName
                    MinVersion = $minVersion
                    Publisher  = $publisher
                    Source     = $SourceName
                }
            }
        }

        function Get-BundleApplicationPackages([string]$BundleXml) {
            $packages = @()
            if ([string]::IsNullOrWhiteSpace($BundleXml)) { return $packages }

            $packageElements = [regex]::Matches($BundleXml, '(?is)<(?:\w+:)?Package\b[^>]*(?:/>|>.*?</(?:\w+:)?Package>)')
            foreach ($m in $packageElements) {
                $attr = $m.Value
                $fileName = Get-AppxXmlAttributeValue -Text $attr -AttrName 'FileName'
                if ([string]::IsNullOrWhiteSpace($fileName)) { continue }

                $type = Get-AppxXmlAttributeValue -Text $attr -AttrName 'Type'
                if ([string]::IsNullOrWhiteSpace($type)) { $type = 'application' }
                if ($type -ine 'application') { continue }

                $arch = Get-AppxXmlAttributeValue -Text $attr -AttrName 'Architecture'
                if ([string]::IsNullOrWhiteSpace($arch)) { $arch = 'neutral' }
                $arch = $arch.ToLowerInvariant()
                if ($arch -eq '~') { $arch = 'neutral' }

                $packages += [PSCustomObject]@{
                    FileName = $fileName
                    Arch     = $arch
                    Type     = $type
                }
            }

            return $packages
        }

        function Test-AppxArchCompatible([string]$PkgArch) {
            if ([string]::IsNullOrWhiteSpace($PkgArch)) { return $true }
            $a = $PkgArch.ToLowerInvariant()
            if ($a -eq '~') { $a = 'neutral' }
            if ($a -eq 'neutral') { return $true }

            switch ($script:imgArch) {
                'x64'   { return ($a -eq 'x64' -or $a -eq 'x86') }
                'x86'   { return ($a -eq 'x86') }
                'arm64' { return ($a -eq 'arm64' -or $a -eq 'arm' -or $a -eq 'x86') }
                default { return $true }
            }
        }

        function Get-AppxArchRank([string]$PkgArch) {
            $a = if ([string]::IsNullOrWhiteSpace($PkgArch)) { 'neutral' } else { $PkgArch.ToLowerInvariant() }
            if ($a -eq '~') { $a = 'neutral' }
            switch ($script:imgArch) {
                'x64' {
                    if ($a -eq 'x64') { return 0 }
                    if ($a -eq 'neutral') { return 1 }
                    if ($a -eq 'x86') { return 2 }
                    return 9
                }
                'arm64' {
                    if ($a -eq 'arm64') { return 0 }
                    if ($a -eq 'neutral') { return 1 }
                    if ($a -eq 'arm') { return 2 }
                    if ($a -eq 'x86') { return 3 }
                    return 9
                }
                'x86' {
                    if ($a -eq 'x86') { return 0 }
                    if ($a -eq 'neutral') { return 1 }
                    return 9
                }
                default {
                    if ($a -eq 'neutral') { return 1 }
                    return 0
                }
            }
        }

        # Variable temporal de coleccion para evitar problemas de alcance en funciones anidadas.
        $oldCollector = $script:__appxDepCollector
        $script:__appxDepCollector = @()

        try {
            $outerZip = [System.IO.Compression.ZipFile]::OpenRead($filePath)

            $bundleXml = Read-ZipEntryText -Zip $outerZip -EntryNamePattern 'AppxBundleManifest\.xml$'
            if ($bundleXml) {
                $manifestReadCount++

                # Algunos bundles declaran dependencias en el bundle manifest; se agregan si existen.
                Add-DependenciesFromXml -XmlText $bundleXml -SourceName 'AppxBundleManifest.xml'

                $appPackages = @(Get-BundleApplicationPackages -BundleXml $bundleXml |
                    Where-Object { Test-AppxArchCompatible $_.Arch } |
                    Sort-Object @{ Expression = { Get-AppxArchRank $_.Arch }; Ascending = $true })

                # Leer solo los paquetes de aplicacion relevantes para la arquitectura de la imagen.
                # Si hay varios con el mismo mejor rango, se leen todos para no perder dependencias especificas.
                if ($appPackages.Count -gt 0) {
                    $bestRank = Get-AppxArchRank $appPackages[0].Arch
                    $appPackages = @($appPackages | Where-Object { (Get-AppxArchRank $_.Arch) -eq $bestRank })
                } else {
                    # Ultimo recurso dentro de bundles: buscar cualquier paquete app/msix, pero no activar fallback amplio.
                    $appPackages = @()
                }

                foreach ($appPkg in $appPackages) {
                    $innerEntry = $outerZip.Entries |
                        Where-Object { $_.FullName -ieq $appPkg.FileName -or $_.FullName -match ([regex]::Escape($appPkg.FileName) + '$') } |
                        Select-Object -First 1

                    if (-not $innerEntry) {
                        Write-Log -LogLevel WARN -Message "AppxInjector: Bundle '$([System.IO.Path]::GetFileName($filePath))' referencia '$($appPkg.FileName)', pero no se encontro dentro del paquete."
                        continue
                    }

                    $innerStream = $innerEntry.Open()
                    $memStream   = New-Object System.IO.MemoryStream
                    try {
                        $innerStream.CopyTo($memStream)
                        $memStream.Position = 0

                        $innerZip = New-Object System.IO.Compression.ZipArchive($memStream, [System.IO.Compression.ZipArchiveMode]::Read)
                        try {
                            $innerManifest = Read-ZipEntryText -Zip $innerZip -EntryNamePattern 'AppxManifest\.xml$'
                            if ($innerManifest) {
                                $manifestReadCount++
                                Add-DependenciesFromXml -XmlText $innerManifest -SourceName $appPkg.FileName
                            }
                        } finally { $innerZip.Dispose() }
                    } finally {
                        $innerStream.Dispose()
                        $memStream.Dispose()
                    }
                }
            } else {
                $xmlStr = Read-ZipEntryText -Zip $outerZip -EntryNamePattern 'AppxManifest\.xml$'
                if ($xmlStr) {
                    $manifestReadCount++
                    Add-DependenciesFromXml -XmlText $xmlStr -SourceName 'AppxManifest.xml'
                }
            }
        } catch {
            Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo leer manifiesto de '$([System.IO.Path]::GetFileName($filePath))' - $($_.Exception.Message)"
        } finally {
            if ($null -ne $outerZip) { $outerZip.Dispose() }
            $depEntries = @($script:__appxDepCollector)
            $script:__appxDepCollector = $oldCollector
        }

        $uniqueDeps = @(
            $depEntries |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } |
                Sort-Object Name, MinVersion, Publisher -Unique
        )

        return @{
            Success           = ($manifestReadCount -gt 0)
            ManifestReadCount = $manifestReadCount
            Deps              = $uniqueDeps
        }
    }

    function Resolve-AppxLicensePath {
        param([object[]]$Files, $Meta)

        $familyName = [string]$Meta.PackageFamilyName
        if ([string]::IsNullOrWhiteSpace($familyName)) { return $null }
        # En un bundle neutral, la preferencia corresponde a la imagen. Un
        # paquete individual (incluidas librerias x86 en x64) conserva su arq.
        $preferredArch = [string]$Meta.Arch
        if ([string]::IsNullOrWhiteSpace($preferredArch) -or $preferredArch -ieq 'neutral') {
            $preferredArch = [string]$script:imgArch
        }
        if ($preferredArch -ieq 'amd64') { $preferredArch = 'x64' }

        $candidates = @()
        foreach ($file in @($Files | Where-Object { $_.Extension -ieq '.xml' })) {
            $reader = $null
            try {
                $settings = New-Object System.Xml.XmlReaderSettings
                $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
                $settings.XmlResolver = $null
                $reader = [System.Xml.XmlReader]::Create($file.FullName, $settings)
                $xml = New-Object System.Xml.XmlDocument
                $xml.XmlResolver = $null
                $xml.Load($reader)
                # No confundir AppxManifest.xml u otros XML con una licencia.
                if ($xml.DocumentElement.LocalName -cne 'License') { continue }
                $identities = @($xml.SelectNodes("//*[local-name()='PFM' or local-name()='PackageFamilyName']") |
                    ForEach-Object { $_.InnerText.Trim() } | Where-Object { $_ })
                if ($identities.Count -eq 0) {
                    Write-Log -LogLevel WARN -Message "AppxInjector: Licencia omitida '$($file.Name)': no declara PFM ni PackageFamilyName; el nombre del archivo no acredita la familia."
                    continue
                }
                # PFM suele estar en minusculas. Todos los campos de identidad
                # presentes deben coincidir con la familia completa del paquete.
                if (@($identities | Where-Object { $_ -ine $familyName }).Count -gt 0) { continue }

                $licenseArch = ''
                $archMatch = [regex]::Match($file.BaseName, '(?i)(?:^|[._-])(?<arch>arm64|arm|x64|amd64|x86|neutral)(?:[._-]licen[cs]e)?$')
                if ($archMatch.Success) { $licenseArch = $archMatch.Groups['arch'].Value.ToLowerInvariant() }
                if ($licenseArch -eq 'amd64') { $licenseArch = 'x64' }
                $rank = if ($licenseArch -and $licenseArch -ieq $preferredArch) { 0 }
                        elseif (-not $licenseArch -or $licenseArch -eq 'neutral') { 1 }
                        else { 2 }
                $candidates += [pscustomobject]@{ Path = $file.FullName; Name = $file.Name; Arch = $licenseArch; Rank = $rank }
            } catch {
                Write-Log -LogLevel WARN -Message "AppxInjector: XML omitido al buscar licencia '$($file.Name)': $($_.Exception.Message)"
            } finally {
                if ($null -ne $reader) { $reader.Dispose() }
            }
        }

        if ($candidates.Count -eq 0) { return $null }
        $selected = $candidates | Sort-Object Rank, Name, Path | Select-Object -First 1
        if ($selected.Rank -eq 2) {
            # La arquitectura en el nombre es una preferencia, no un campo de
            # licencia verificado. La correspondencia se establece por PFM.
            Write-Log -LogLevel WARN -Message "AppxInjector: '$familyName' no tiene XML con sufijo '$preferredArch' ni generico; se usa '$($selected.Name)' por coincidencia exacta de familia. El sufijo '$($selected.Arch)' no acredita una restriccion de licencia."
        }
        Write-Log -LogLevel INFO -Message "AppxInjector: Licencia asociada a '$familyName': '$($selected.Name)' (preferencia: $preferredArch)."
        return $selected.Path
    }


    # Agrega un paquete analizado al ListView con accion heuristica (INSTALAR/ACTUALIZAR/REPARAR/OMITIR)
    function Add-UwpToQueue ($MainPkg, $Meta, [array]$Deps, $LicensePath) {
        $action = Get-AppxQueueAction $Meta
        $color = Get-AppxActionColor $action

        $newVersion = $Meta.Version
        if ($null -eq $newVersion) { try { $newVersion = [version]$Meta.VersionStr } catch { $newVersion = [version]"0.0.0.0" } }

        foreach ($item in @($lvAppQueue.Items)) {
            $existing = $item.Tag
            if ($null -eq $existing) { continue }

            if ($existing.MainPackage -ieq $MainPkg.FullName) { return }

            $sameIdentity = ($Meta.PackageFamilyName -and $existing.PackageFamilyName -ieq $Meta.PackageFamilyName -and
                             $existing.Arch   -ieq $Meta.Arch   -and
                             $existing.Type   -ieq $Meta.Type)

            if ($sameIdentity) {
                if ($newVersion -le $existing.Version) {
                    Write-Log -LogLevel INFO -Message "AppxInjector: Duplicado omitido: $($Meta.Family) $($Meta.VersionStr) [$($Meta.Arch)]"
                    return
                }

                Write-Log -LogLevel INFO -Message "AppxInjector: Reemplazando duplicado por version mas nueva: $($Meta.Family) $($Meta.VersionStr) [$($Meta.Arch)]"
                $lvAppQueue.Items.Remove($item)
            }
        }

        $appData = [PSCustomObject]@{
            MainPackage  = $MainPkg.FullName
            Dependencies = @($Deps | Select-Object -Unique)
            LicensePath  = $LicensePath
            Family       = $Meta.Family
            PackageFamilyName = $Meta.PackageFamilyName
            IdentityError = $Meta.IdentityError
            Version      = $newVersion
            VersionStr   = $Meta.VersionStr
            Arch         = $Meta.Arch
            Type         = $Meta.Type
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
        if ($action -eq 'ERROR IDENTIDAD') { $newItem.ToolTipText = $Meta.IdentityError }

        $lvAppQueue.Items.Add($newItem) | Out-Null
    }

    # Motor heuristico central: agrupa archivos por familia, filtra arquitectura,
    # elige el paquete principal, valida dependencias contra el manifiesto real
    function Process-UwpSelection ($fileList) {
        $lvAppQueue.BeginUpdate()

        try {
            # Advertir y filtrar paquetes cifrados
            $encryptedFiles = @($fileList | Where-Object { $_.Extension -match "^\.e(appx|msix|appxbundle|msixbundle)$" })
            if ($encryptedFiles.Count -gt 0) {
                $encNames = ($encryptedFiles | Select-Object -ExpandProperty Name) -join "`n  - "
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "Los siguientes paquetes son cifrados (.eappx/.emsix) y requieren descifrado previo:`n`n  - $encNames`n`nSe omitiran automaticamente.",
                    "Paquetes Cifrados Detectados", 'OK', 'Warning')
                $fileList = @($fileList | Where-Object { $_.Extension -notmatch "^\.e" })
            }

            # --- FIX MEDIO 4: MEMOIZACION ---
            $metaCache = @{}
            function Get-CachedMeta($fileObj) {
                if (-not $metaCache.ContainsKey($fileObj.FullName)) {
                    $metaCache[$fileObj.FullName] = Get-UwpMetadata $fileObj.FullName
                }
                return $metaCache[$fileObj.FullName]
            }

            function Select-BestUwpFile([array]$files) {
                return @($files | Sort-Object `
                    @{ Expression = { (Get-CachedMeta $_).Version }; Descending = $true }, `
                    @{ Expression = { $_.Length }; Descending = $true } | Select-Object -First 1)
            }

            $grouped = $fileList | Group-Object {
                $pfn = (Get-CachedMeta $_).PackageFamilyName
                if ($pfn) { $pfn } else { $_.FullName }
            }

            foreach ($group in $grouped) {
                $familyFiles = $group.Group

                # Filtrar por compatibilidad de arquitectura con la imagen
                $validFiles = @($familyFiles | Where-Object {
                    $fArch = (Get-CachedMeta $_).Arch
                    switch ($script:imgArch) {
                        "x64"   { $fArch -notmatch "^arm" }
                        "x86"   { $fArch -notmatch "x64|arm" }
                        "arm64" { $fArch -notmatch "^x64$" }
                        default { $true }
                    }
                })
                if ($validFiles.Count -eq 0) { continue }

                $groupType = (Get-CachedMeta $validFiles[0]).Type

                if ($groupType -eq "LIBRERIA") {
                    # Cada arquitectura de libreria se añade por separado
                    $archGroups = $validFiles | Group-Object { (Get-CachedMeta $_).Arch }
                    foreach ($archGroup in $archGroups) {
                        $bestFw    = Select-BestUwpFile @($archGroup.Group)
                        $fwMeta    = Get-CachedMeta $bestFw
                        $fwFiles = @(Get-ChildItem -LiteralPath $bestFw.DirectoryName -File -ErrorAction SilentlyContinue)
                        $fwLicPath = Resolve-AppxLicensePath -Files $fwFiles -Meta $fwMeta
                        Add-UwpToQueue -MainPkg $bestFw -Meta $fwMeta -Deps @() -LicensePath $fwLicPath
                    }
                } else {
                    # Seleccion del paquete principal: bundle > archivo por arquitectura
                    $mainPkg = $null
                    $bundles = @($validFiles | Where-Object { $_.Extension -match "bundle$" })

                    if ($bundles.Count -gt 0) {
                        $mainPkg = Select-BestUwpFile $bundles
                    } else {
                        switch ($script:imgArch) {
                            "x64" {
                                $x64     = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "x64" })
                                $neutral = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "neutral" })
                                $x86     = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "x86" })
                                if     ($x64.Count     -gt 0) { $mainPkg = Select-BestUwpFile $x64 }
                                elseif ($neutral.Count -gt 0) { $mainPkg = Select-BestUwpFile $neutral }
                                elseif ($x86.Count     -gt 0) { $mainPkg = Select-BestUwpFile $x86 }
                            }
                            "arm64" {
                                $arm64   = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "arm64" })
                                $neutral = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "neutral" })
                                $x86     = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "x86" })
                                if     ($arm64.Count   -gt 0) { $mainPkg = Select-BestUwpFile $arm64 }
                                elseif ($neutral.Count -gt 0) { $mainPkg = Select-BestUwpFile $neutral }
                                elseif ($x86.Count     -gt 0) { $mainPkg = Select-BestUwpFile $x86 }
                            }
                            default {
                                $x86     = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "x86" })
                                $neutral = @($validFiles | Where-Object { (Get-CachedMeta $_).Arch -eq "neutral" })
                                if     ($x86.Count     -gt 0) { $mainPkg = Select-BestUwpFile $x86 }
                                elseif ($neutral.Count -gt 0) { $mainPkg = Select-BestUwpFile $neutral }
                            }
                        }
                    }
                    if (-not $mainPkg) { continue }

                    $realMeta = Get-CachedMeta $mainPkg

                    # Candidatos de dependencia: se agrupan por familia+arquitectura y se elige la version mas alta valida.
                    $dirFiles      = @(Get-ChildItem -Path $mainPkg.DirectoryName -File -ErrorAction SilentlyContinue)
                    $depCandidates = @()

                    foreach ($dep in $dirFiles) {
                        if ($dep.FullName -ieq $mainPkg.FullName) { continue }
                        if ($dep.Extension -notmatch "^\.appx$|^\.msix$|^\.appxbundle$|^\.msixbundle$") { continue }

                        $depMeta = Get-CachedMeta $dep
                        if ($depMeta.Type -ne "LIBRERIA") { continue }

                        $depArch = $depMeta.Arch
                        if ($script:imgArch -eq "x64"   -and $depArch -match "^arm")    { continue }
                        if ($script:imgArch -eq "x86"   -and $depArch -match "x64|arm") { continue }
                        if ($script:imgArch -eq "arm64" -and $depArch -eq "x64")        { continue }

                        if ($script:imgArch -eq "x64" -and $depArch -eq "x86") {
                            $isKnownX86Dep = $depMeta.Family -match "VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime|WinAppRuntime|Microsoft\.UI\.Xaml"
                            if (-not $isKnownX86Dep) { continue }
                        }

                        $depCandidates += [PSCustomObject]@{
                            Path    = $dep.FullName
                            File    = $dep
                            Meta    = $depMeta
                            Family  = $depMeta.Family
                            Arch    = $depMeta.Arch
                            Version = $depMeta.Version
                        }
                    }

                    $manifestRead      = Get-AppxManifestDependencies -filePath $mainPkg.FullName
                    $exactDependencies = @($manifestRead.Deps)
                    $validatedDeps     = @()

                    if ($manifestRead.Success) {
                        if ($exactDependencies.Count -eq 0) {
                            # No es error: el manifiesto se leyo bien y no declaro PackageDependency.
                            # Antes esto caia a fallback y agregaba 20+ librerias falsas.
                            Write-Log -LogLevel INFO -Message "AppxInjector: $($mainPkg.Name) no declara dependencias Appx reales en el manifiesto."
                        }

                        foreach ($exactDep in $exactDependencies) {
                            $depName = $exactDep.Name
                            $minVersion = $null
                            if ($exactDep.MinVersion) { try { $minVersion = [version]$exactDep.MinVersion } catch {} }

                            # Coincidencia conservadora: nombre exacto o paquete con sufijo de arquitectura/version.
                            # Evita que dependencias cortas coincidan accidentalmente con muchas familias.
                            $matches = @($depCandidates | Where-Object {
                                $_.Family -ieq $depName -or
                                $_.Family -like "$depName.*" -or
                                $_.Family -like "$depName`_*"
                            })

                            if ($null -ne $minVersion) {
                                $matches = @($matches | Where-Object { $_.Version -ge $minVersion })
                            }

                            if ($matches.Count -eq 0) {
                                $minMsg = if ($null -ne $minVersion) { " >= $minVersion" } else { "" }
                                Write-Log -LogLevel WARN -Message "AppxInjector: Dependencia requerida no encontrada o insuficiente: $depName$minMsg para $($mainPkg.Name)"
                                continue
                            }

                            # Elegir una sola dependencia por familia real. Si existe arch nativa, preferirla;
                            # neutral es valida; x86 queda como ultima opcion en x64/arm64.
                            $bestDep = $matches | Sort-Object `
                                @{ Expression = {
                                    switch ($script:imgArch) {
                                        'x64' {
                                            if ($_.Arch -eq 'x64') { 0 }
                                            elseif ($_.Arch -eq 'neutral') { 1 }
                                            elseif ($_.Arch -eq 'x86') { 2 }
                                            else { 9 }
                                        }
                                        'arm64' {
                                            if ($_.Arch -eq 'arm64') { 0 }
                                            elseif ($_.Arch -eq 'neutral') { 1 }
                                            elseif ($_.Arch -eq 'arm') { 2 }
                                            elseif ($_.Arch -eq 'x86') { 3 }
                                            else { 9 }
                                        }
                                        'x86' {
                                            if ($_.Arch -eq 'x86') { 0 }
                                            elseif ($_.Arch -eq 'neutral') { 1 }
                                            else { 9 }
                                        }
                                        default { 0 }
                                    }
                                }; Ascending = $true }, `
                                @{ Expression = { $_.Version }; Descending = $true }, `
                                @{ Expression = { $_.File.Length }; Descending = $true } |
                                Select-Object -First 1

                            if ($bestDep -and $validatedDeps -notcontains $bestDep.Path) {
                                $validatedDeps += $bestDep.Path
                            }
                        }
                    } else {
                        # Fallback real: solo cuando NO se pudo leer ningun manifiesto.
                        # Se limita a frameworks conocidos para no inflar falsamente la cola con 20+ dependencias.
                        Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo leer manifiesto de $($mainPkg.Name). Fallback limitado a librerias conocidas."
                        $validatedDeps = @($depCandidates |
                            Where-Object { $_.Family -match '(?i)VCLibs|UI\.Xaml|NET\.Native|WindowsAppRuntime|WinAppRuntime|Microsoft\.WindowsAppSDK|Microsoft\.Graphics\.Win2D|Store\.Engagement' } |
                            Group-Object { "$($_.Family)|$($_.Arch)" } |
                            ForEach-Object {
                                $_.Group | Sort-Object `
                                    @{ Expression = { $_.Version }; Descending = $true }, `
                                    @{ Expression = { $_.File.Length }; Descending = $true } | Select-Object -First 1
                            } |
                            ForEach-Object { $_.Path })
                    }

                    $licPath = Resolve-AppxLicensePath -Files $dirFiles -Meta $realMeta

                    Add-UwpToQueue -MainPkg $mainPkg -Meta $realMeta -Deps $validatedDeps -LicensePath $licPath
                }
            }
        } catch {
            # FIX MEDIO: Captura de excepciones para evitar el colapso del WinForms Message Loop
            Write-Log -LogLevel ERROR -Message "AppxInjector: Error durante análisis heuristico - $($_.Exception.Message)"
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "Ocurrió un error analizando los paquetes: $_`nIntenta nuevamente o verifica los permisos de los archivos.", 
                "Error de Análisis", 
                'OK', 'Error'
            )
        } finally {
            # OBSERVACION B: Garantizado que la UI se descongele pase lo que pase
            $lvAppQueue.EndUpdate()
            $lblStatus.Text      = "Analisis completado. En cola: $($lvAppQueue.Items.Count) elemento(s)."
            $lblStatus.ForeColor = [System.Drawing.Color]::White
            Update-AppxQueueActions
        }
    }

    # ------------------------------------------------------------------
    # 4. Eventos
    # ------------------------------------------------------------------

    # Carga inicial: leer cache Appx, montar hives, detectar OS/arch
    $form.Add_Shown({
        $script:isAppxPreparing = $true
        foreach ($control in @($btnApply,$btnAddApp,$btnAddFolder,$btnRemoveApp,$btnClear,$chkUpdateAppx)) { $control.Enabled = $false }
        try {
            $form.Cursor    = [System.Windows.Forms.Cursors]::WaitCursor
            $lblStatus.Text = "Leyendo cache Appx via DISM (Puede tardar 15-30 seg. La ventana no respondera)..."
            $form.Refresh()
            [System.Windows.Forms.Application]::DoEvents()

            # 1. Leer Appx PRIMERO (sin colmenas montadas para evitar colision de archivos)
            try {
                Update-AppxInstalledCache
                $cacheMsg   = "$($script:appCache.Count) apps en cache"
                $cacheColor = [System.Drawing.Color]::LightGreen
            } catch {
                if ($script:appxBatchBlocked) { throw }
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

            try {
                $script:appxDeprovisionedFamilies = Get-AppxDeprovisionedMap
                if ($script:appxDeprovisionedFamilies.Count -gt 0) {
                    Write-Log -LogLevel INFO -Message "AppxInjector: $($script:appxDeprovisionedFamilies.Count) marca(s) Deprovisioned detectada(s)."
                }
            } catch {
                $script:appxDeprovisionedFamilies = @{}
                Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo leer Deprovisioned - $($_.Exception.Message)"
            }

            # Importante: no dejar colmenas montadas mientras la GUI queda abierta.
            # Esto evita que el cierre tarde varios segundos o que DISM encuentre handles abiertos.
            Invoke-AppxSafeUnmount -Reason "lectura inicial de build/deprovisioned"

            $osLabel = if     ($script:imgBuild -ge 26100) { "W11 24H2+" }
                       elseif ($script:imgBuild -ge 22621) { "W11 22H2/23H2" }
                       elseif ($script:imgBuild -ge 22000) { "W11 21H2" }
                       elseif ($script:imgBuild -ge 19041) { "W10 22H2" }
                       else                                { "Build $($script:imgBuild)" }

            # 5. Actualizar UI
            $lblOsInfo.Text      = "Imagen: $osLabel | Arquitectura: $($script:imgArch) | Build: $($script:imgBuild)"
            $lblStatus.Text      = "Motor Listo | OS: $osLabel | Arch: $($script:imgArch) | $cacheMsg"
            $lblStatus.ForeColor = $cacheColor
            $form.Cursor         = [System.Windows.Forms.Cursors]::Default
        } catch {
            Block-AppxBatch $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Inicializacion detenida','OK','Error') | Out-Null
        } finally {
            try { Invoke-AppxSafeUnmount 'fin de inicializacion' }
            catch { Block-AppxBatch $_.Exception.Message }
            $script:isAppxPreparing = $false
            foreach ($control in @($btnAddApp,$btnAddFolder,$btnRemoveApp,$btnClear,$chkUpdateAppx)) { $control.Enabled = -not $script:appxBatchBlocked }
            $form.Cursor = [Windows.Forms.Cursors]::Default
            Update-AppxQueueActions
        }
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
                    $form, "No se encontraron paquetes UWP en la carpeta.", "Sin resultados", 'OK', 'Information')
            }
            $form.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Quitar seleccion
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

    $btnCancelAfterCurrent.Add_Click({
        if (-not $script:isAppxDeploying) { return }
        $script:cancelAppxAfterCurrent = $true
        $btnCancelAfterCurrent.Enabled = $false
        $lblStatus.Text = "Cancelacion solicitada. Se detendra despues del paquete actual."
        $lblStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        Write-Log -LogLevel WARN -Message "AppxInjector: Cancelacion segura solicitada por el usuario."
    })

    $chkUpdateAppx.Add_CheckedChanged({ Update-AppxQueueActions })

    # Motor de despliegue inteligente
    $btnApply.Add_Click({
        if ($script:appxBatchBlocked -or $script:isAppxPreparing -or $script:isAppxDeploying) { return }
        $script:isAppxPreparing = $true
        foreach ($control in @($btnApply,$btnAddApp,$btnAddFolder,$btnRemoveApp,$btnClear,$chkUpdateAppx)) { $control.Enabled = $false }
        try {
            # Revalidar la decision justo antes del despliegue.
            Update-AppxInstalledCache
            Update-AppxQueueActions
        } catch {
            Block-AppxBatch $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Lote detenido','OK','Error') | Out-Null
            return
        } finally {
            $script:isAppxPreparing = $false
            foreach ($control in @($btnAddApp,$btnAddFolder,$btnRemoveApp,$btnClear,$chkUpdateAppx)) { $control.Enabled = -not $script:appxBatchBlocked }
            Update-AppxQueueActions
        }
        $pendingItems = @($lvAppQueue.Items | Where-Object { $_.Text -in @('INSTALAR','ACTUALIZAR','REPARAR','REPARACION PENDIENTE') })

        if ($pendingItems.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show(
                $form, "No hay paquetes pendientes de instalar.", "Sin pendientes", 'OK', 'Information')
            return
        }

        if ([System.Windows.Forms.MessageBox]::Show(
                $form,
                "Se desplegaran $($pendingItems.Count) paquetes en la imagen.`nContinuar?",
                "Confirmar Despliegue", 'YesNo', 'Question') -ne 'Yes') { return }

        $script:isAppxDeploying       = $true
        $script:cancelAppxAfterCurrent = $false
        $btnApply.Enabled             = $false
        $btnAddApp.Enabled        = $false
        $btnAddFolder.Enabled     = $false
        $btnRemoveApp.Enabled     = $false 
        $btnClear.Enabled             = $false
        $btnCancelAfterCurrent.Enabled = $true
        $chkUpdateAppx.Enabled = $false
        $lblStatus.ForeColor          = [System.Drawing.Color]::Yellow

        $total   = $pendingItems.Count
        $count   = 0; $success = 0; $errors = 0
        $cancelled = $false
        $successFamilies = @()
        $failedDismLogs = @()
        
        $skipped = ($lvAppQueue.Items | Where-Object { $_.Text -match "OMITIR" }).Count

        try {
            # 1. Asegurar hives montadas para Sideloading
            Write-Log -LogLevel INFO -Message "AppxInjector: Preparando registro offline para Sideloading..."
            if (-not (Mount-Hives)) {
                [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "No se pudieron montar las colmenas offline para habilitar sideloading.",
                    "Error de registro offline", 'OK', 'Error')
                return
            }

            # 2. Habilitar AllowAllTrustedApps en el registro offline
            $parentPolPath = "HKLM:\OfflineSoftware\Policies\Microsoft\Windows"
            $appxPolPath   = "$parentPolPath\Appx"

            Unlock-OfflineKey -KeyPath $parentPolPath
            try {
                if (-not (Test-Path $appxPolPath)) {
                    New-Item -Path $appxPolPath -Force -ErrorAction Stop | Out-Null
                }
                # No asumir que la herencia del padre alcanzo a esta subclave (recien
                # creada o con una ACE del padre sin ContainerInherit): desbloquearla
                # explicitamente antes de escribir el valor.
                Unlock-OfflineKey -KeyPath $appxPolPath
                Set-ItemProperty -Path $appxPolPath -Name "AllowAllTrustedApps" -Value 1 -Type DWord -Force -ErrorAction Stop
            } catch {
                Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo escribir AllowAllTrustedApps - $($_.Exception.Message)"
            } finally {
                if (Test-Path $appxPolPath) { Restore-KeyOwner -KeyPath $appxPolPath }
                Restore-KeyOwner -KeyPath $parentPolPath
            }

            # 3. Desmontar hives ANTES de llamar a DISM
            Write-Log -LogLevel INFO -Message "AppxInjector: Sideloading habilitado. Desmontando colmenas para ceder el control a DISM..."
            Invoke-AppxSafeUnmount -Reason "antes de DISM"

            # 4. Ordenar cola: LIBRERIAS primero para evitar errores de dependencia
            $orderedQueue = @($pendingItems | Where-Object { $_.SubItems[1].Text -eq "LIBRERIA" }) +
                            @($pendingItems | Where-Object { $_.SubItems[1].Text -ne "LIBRERIA" })

            # 5. Bucle de inyeccion
            $progressBar.Value   = 0
            $progressBar.Maximum = $total
            $progressBar.Visible = $true

            foreach ($item in $orderedQueue) {
                [System.Windows.Forms.Application]::DoEvents()
                if ($script:cancelAppxAfterCurrent) {
                    $cancelled = $true
                    Write-Log -LogLevel WARN -Message "AppxInjector: Despliegue cancelado de forma segura antes del siguiente paquete."
                    break
                }

                # Fuera del catch por paquete: un fallo detiene todo el lote.
                Invoke-AppxSafeUnmount 'antes del siguiente paquete'
                $appData    = $item.Tag
                $familyName = $item.SubItems[2].Text

                if ($item.Text -in @("REPARAR", "REPARACION PENDIENTE")) {
                    $item.Text      = "REPARANDO..."
                    $item.ForeColor = [System.Drawing.Color]::Orange
                    $item.EnsureVisible()
                    $lblStatus.Text = "[$($count + 1)/$total] Reparando marca Deprovisioned: $familyName..."
                    $form.Refresh()
                    try {
                        # Completar la reparacion de este objeto antes de avanzar al siguiente.
                        $cleanedRepair = Remove-AppxDeprovisionedMarks -FamilyNames @($appData.PackageFamilyName) -StopOnFailure
                        $item.Text      = "REPARADO"
                        $item.ForeColor = [System.Drawing.Color]::LightGreen
                        $success++
                        Write-Log -LogLevel INFO -Message "AppxInjector: Reparacion completada [$familyName]; marcas limpiadas: $cleanedRepair"
                    } catch {
                        if ($script:appxBatchBlocked) { throw }
                        $item.Text      = "ERROR REPARACION"
                        $item.ForeColor = [System.Drawing.Color]::Red
                        $errors++
                        Write-Log -LogLevel ERROR -Message "AppxInjector: Fallo reparando [$familyName] - $($_.Exception.Message)"
                    } finally {
                        # Contar el objeto solo despues de terminar su procesamiento.
                        if (-not $script:appxBatchBlocked) { $count++ }
                        $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                        $form.Refresh()
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                    continue
                }

                $item.Text      = "PROCESANDO..."
                $item.ForeColor = [System.Drawing.Color]::Cyan
                $item.EnsureVisible()
                $lblStatus.Text = "[$($count + 1)/$total] $familyName..."
                $form.Refresh()

                Write-Log -LogLevel INFO -Message "AppxInjector: Desplegando [$familyName] -> $($appData.MainPackage)"

                $dismLogPath = $null
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

                    if ($Script:Scratch_DIR) {
                        if (-not (Test-Path -LiteralPath $Script:Scratch_DIR)) {
                            New-Item -Path $Script:Scratch_DIR -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                        $argLine += " /ScratchDir:`"$Script:Scratch_DIR`""
                    }

                    $scratchBase = $Script:Scratch_DIR
                    if ([string]::IsNullOrWhiteSpace($scratchBase)) { $scratchBase = [System.IO.Path]::GetTempPath() }
                    if (-not (Test-Path -LiteralPath $scratchBase)) {
                        New-Item -Path $scratchBase -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
                    }

                    $dismLogPath = Join-Path $scratchBase "dism_appx_$([Guid]::NewGuid().ToString('N').Substring(0,8)).log"
                    $argLine += " /LogPath:`"$dismLogPath`" /LogLevel:3"
                    $dismSucceeded = $false

                    Invoke-AppxSafeUnmount 'inmediatamente antes de DISM'
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
                        $dismSucceeded = $true
                        $successFamilies += $appData.PackageFamilyName
                        Write-Log -LogLevel INFO -Message "AppxInjector: OK [$familyName] (ExitCode: $exitCode)"
                    } else {
                        $hexCode = [Convert]::ToString([int32]$exitCode, 16).ToUpper().PadLeft(8, '0')
                        $item.Text      = "ERROR (0x$hexCode)"
                        $item.ForeColor = [System.Drawing.Color]::Red
                        $errors++
                        Write-Log -LogLevel ERROR -Message "AppxInjector: FALLO [$familyName] ExitCode: 0x$hexCode"
                        
                        if (Test-Path -LiteralPath $dismLogPath) {
                            $dismTail = Get-Content $dismLogPath -Tail 15 -ErrorAction SilentlyContinue | Where-Object { $_ -match "Error" -or $_ -match "Warning" }
                            if ($dismTail) {
                                Write-Log -LogLevel ERROR -Message "DISM Forensics: $($dismTail -join ' | ')"
                            }
                        }
                    }

                } catch {
                    if ($script:appxBatchBlocked) { throw }
                    $item.Text      = "ERROR CRITICO"
                    $item.ForeColor = [System.Drawing.Color]::Red
                    $errors++
                    Write-Log -LogLevel ERROR -Message "AppxInjector: Excepcion desplegando [$familyName] - $($_.Exception.Message)"
                } finally {
                    $script:currentDismProcess = $null
                    
                    if ($null -ne $dismLogPath -and (Test-Path -LiteralPath $dismLogPath -ErrorAction SilentlyContinue)) {
                        if ($dismSucceeded) {
                            Remove-Item -LiteralPath $dismLogPath -Force -ErrorAction SilentlyContinue
                        } else {
                            $failedDismLogs += $dismLogPath
                            Write-Log -LogLevel ERROR -Message "AppxInjector: Log DISM conservado para diagnostico: $dismLogPath"
                        }
                    }
                    # Contar el objeto solo despues de terminar su procesamiento.
                    if (-not $script:appxBatchBlocked) { $count++ }
                    $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                    $form.Refresh()
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }

            # 6. Limpiar marcas Deprovisioned para paquetes reinstalados
            if ($successFamilies.Count -gt 0) {
                $lblStatus.Text = "Finalizando limpieza de marcas Deprovisioned..."
                $form.Refresh()
                $cleanedDeprov = Remove-AppxDeprovisionedMarks -FamilyNames $successFamilies
                if ($cleanedDeprov -gt 0) {
                    Write-Log -LogLevel INFO -Message "AppxInjector: $cleanedDeprov marca(s) Deprovisioned limpiada(s)."
                }
            }

            # 7. Actualizar cache post-despliegue por familia completa.
            try { Update-AppxInstalledCache }
            catch {
                if ($script:appxBatchBlocked) { throw }
                Write-Log -LogLevel WARN -Message "AppxInjector: No se pudo refrescar la cache: $($_.Exception.Message)"
            }

            $cancelText = if ($cancelled) { " | Cancelado por usuario" } else { "" }
            $lblStatus.Text      = "Completado. Exitos: $success | Errores: $errors | Omitidos: $skipped$cancelText"
            $lblStatus.ForeColor = if ($errors -gt 0) { [System.Drawing.Color]::Salmon } elseif ($cancelled) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::LightGreen }

            $msg = "Despliegue finalizado.`n`nExitos:    $success`nErrores:   $errors`nOmitidos:  $skipped"
            if ($cancelled) { $msg += "`nCancelado: si" }
            if ($errors -gt 0) {
                $msg += "`n`nLos logs DISM con error se conservaron en Scratch para diagnostico."
                if ($failedDismLogs.Count -gt 0) {
                    $msg += "`n`n" + (($failedDismLogs | Select-Object -Unique) -join "`n")
                }
            }
            [System.Windows.Forms.MessageBox]::Show($form, $msg, "Reporte de Despliegue", 'OK', 'Information')

        } catch {
            Block-AppxBatch $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Lote detenido','OK','Error') | Out-Null
        } finally {
            $script:isAppxDeploying        = $false
            $script:currentDismProcess     = $null
            $script:cancelAppxAfterCurrent = $false
            $progressBar.Visible           = $false
            $btnApply.Enabled              = -not $script:appxBatchBlocked
            $chkUpdateAppx.Enabled         = -not $script:appxBatchBlocked
            $btnAddApp.Enabled             = -not $script:appxBatchBlocked
            $btnAddFolder.Enabled          = -not $script:appxBatchBlocked
            $btnRemoveApp.Enabled          = -not $script:appxBatchBlocked
            $btnClear.Enabled              = -not $script:appxBatchBlocked
            $btnCancelAfterCurrent.Enabled = $false
        }
    })

    # ------------------------------------------------------------------
    # Cierre de la Interfaz: Solo interacciones visuales ligeras
    # ------------------------------------------------------------------
    $form.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:isAppxDeploying -or $script:isAppxPreparing) {
            [System.Windows.Forms.MessageBox]::Show(
                $form,
                "La inyeccion de aplicaciones esta en curso.`nEspera a que termine o usa 'Cancelar despues del actual'.",
                "Operacion Critica en Curso",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            $eventArgs.Cancel = $true
            return
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            $form,
            "Estas seguro de que deseas salir?",
            "Confirmar Salida",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            $eventArgs.Cancel = $true
            return
        }
        $script:isAppxPreparing = $true
        try { Invoke-AppxSafeUnmount 'cierre de AppxInjector' }
        catch {
            $eventArgs.Cancel = $true
            Block-AppxBatch $_.Exception.Message
            [Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Colmenas bloqueadas','OK','Error') | Out-Null
        } finally { $script:isAppxPreparing = $false }
    })

    $form.Add_FormClosed({
        if ($null -ne $lvAppQueue -and -not $lvAppQueue.IsDisposed) {
            $lvAppQueue.Dispose()
        }
        $script:appCache = $null
        $script:appxDeprovisionedFamilies = @{}
    })

    # ------------------------------------------------------------------
    # 5. Destruccion Visual
    # ------------------------------------------------------------------
    $form.ShowDialog() | Out-Null

    if (-not $form.IsDisposed) { 
        $form.Dispose() 
    }
    
    [GC]::Collect()
}