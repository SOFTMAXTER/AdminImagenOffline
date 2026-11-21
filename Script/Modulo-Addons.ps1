# =================================================================
#  Modulo-Addons
#
#  CONTENIDO   : Expand-AddonArchive, Install-OfflineAddon, Show-Addons-GUI
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - Write-Log              : registro de eventos
#    - $Script:IMAGE_MOUNTED  : estado de montaje (0 = sin imagen, 1 = WIM, 2 = VHD)
#    - $Script:MOUNT_DIR      : ruta al punto de montaje activo
#    - $Script:Scratch_DIR    : ruta al directorio temporal
#    - Mount-Hives            : montar colmenas offline del registro
#    - Unmount-Hives          : desmontar colmenas offline del registro
#    - Enable-Privileges      : habilitar privilegios de token
#    - Import-OfflineReg      : inyeccion de payloads de registro
#    - Restore-AllOfflineSDDL : restaurar SDDL diferido de archivos/claves
#  CARGA       : . "$PSScriptRoot\Modulo-Addons.ps1"
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

# =================================================================
#  MODULO DE INYECCION DE ADDONS (.TPK, .BPK, .REG,)
# =================================================================
# --- HELPER: Extractor Inteligente por Analisis de Cabecera ---
function Expand-AddonArchive {
    param([string]$FilePath, [string]$DestPath, [int]$WimIndex = 1)
    
    # 1. Validar Firma Binaria
    $stream = New-Object System.IO.FileStream($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $buffer = New-Object byte[] 4
    $stream.Read($buffer, 0, 4) | Out-Null
    $stream.Close()
    $hexSignature = [BitConverter]::ToString($buffer) -replace '-'

    if (-not (Test-Path $DestPath)) { New-Item -Path $DestPath -ItemType Directory -Force | Out-Null }

    if ($hexSignature -match "^4D535749") { 
        $actualIndexToExtract = $WimIndex

        # 2. Contar índices usando DISM nativo (Ignora la extensión del archivo)
        $dismInfo = dism.exe /Get-WimInfo /WimFile:"$FilePath" /English | Select-String "Index :"
        $indexCount = @($dismInfo).Count

        # 3. Lógica de Fallback Estricta
        if ($indexCount -eq 1) {
            $actualIndexToExtract = 1
            Write-Log -LogLevel INFO -Message "Paquete de indice unico detectado ($indexCount). Forzando extraccion del Indice 1."
        } elseif ($indexCount -eq 0) {
            # Fallback por si la consola falla al leer
            $actualIndexToExtract = 1
            Write-Log -LogLevel WARN -Message "No se pudieron contar los indices. Forzando Indice 1 por seguridad."
        }

        Write-Log -LogLevel INFO -Message "Firma detectada: WIM (MSWI). Extrayendo payload (Indice $actualIndexToExtract)..."

        # 4. Extraer usando DISM nativo
        $proc = Start-Process "dism.exe" -ArgumentList "/Apply-Image /ImageFile:`"$FilePath`" /Index:$actualIndexToExtract /ApplyDir:`"$DestPath`"" -Wait -NoNewWindow -PassThru
        
        if ($proc.ExitCode -ne 0) {
            throw "DISM /Apply-Image fallo al extraer el paquete (Codigo de salida: $($proc.ExitCode))."
        }
    }
    else {
        throw "Formato no reconocido (Firma: $hexSignature). No es un empaquetado valido."
    }
}

# Resultado estructurado opcional; sin -PassThru se conserva la salida de texto.
function New-AIOAddonResult {
    param([string]$Message, [int]$BlockedSections = 0, [switch]$PassThru)
    $status = if ($BlockedSections -gt 0) { 'CompletedWithOmissions' } else { 'Completed' }
    if ($BlockedSections -gt 0) { $Message += " [Con omisiones: $BlockedSections secciones de registro protegidas]" }
    if ($PassThru) {
        [pscustomobject]@{ Status=$status; Message=$Message; BlockedSections=$BlockedSections }
    } else { $Message }
}

# --- MOTOR PRINCIPAL: Inyector de Addons ---
function Install-OfflineAddon {
    param([string]$FilePath, [int]$WimIndex = 1, [switch]$PassThru)
    
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    
    if ($ext -eq '.reg') {
        $regResult = Import-OfflineReg -FilePath $FilePath -PassThru
        $message = Get-AIOString 'addons.reg_processed_fmt' $regResult.KeysWritten $regResult.ValuesWritten
        return (New-AIOAddonResult -Message $message -BlockedSections $regResult.BlockedSections -PassThru:$PassThru)
    }

    if ($ext -match '\.(wim|tpk|bpk)$') {
        $tempExtract = Join-Path $Script:Scratch_DIR "Addon_$baseName"

        try {
            # Extraemos el payload usando nuestro extractor blindado
            Expand-AddonArchive -FilePath $FilePath -DestPath $tempExtract -WimIndex $WimIndex

            # --- FASE A: Inyeccion de Archivos (Mapeo de Estructura Blindado) ---
            $hasFiles = $false
            
            # Verificamos si hay ALGO en la raiz extraida (Excluyendo los .reg)
            $payloadFiles = Get-ChildItem -Path $tempExtract -Force | Where-Object { $_.Extension -ne '.reg' }
            
            if ($payloadFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando estructura de archivos completa hacia $Script:MOUNT_DIR"
                
                # Activamos privilegios (SeBackup / SeRestore)
                Enable-Privileges

                $safeMountDir = $Script:MOUNT_DIR.TrimEnd('\', '/')

				# Usamos Robocopy en Modo Backup (/B) para ignorar permisos de TrustedInstaller
                # /E = Recursivo | /B = Backup Mode | /IS = Sobrescribir iguales | /IT = Sobrescribir modificados
                # /R:0 /W:0 = Sin reintentos | /NJH /NJS /NDL /NC /NS /NP = Totalmente silencioso
                $roboArgs = "`"$tempExtract`" `"$safeMountDir`" /E /B /IS /IT /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP"
                
                $proc = Start-Process robocopy.exe -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
                
                # Evaluamos el bitmask de Robocopy (8 o superior es fallo critico)
                if ($proc.ExitCode -ge 8) {
                    Write-Log -LogLevel ERROR -Message "Robocopy fallo al inyectar la carga util (Codigo: $($proc.ExitCode))"
                    throw "Robocopy fallo en $safeMountDir. Bug de sintaxis o bloqueo de archivos. (Codigo: $($proc.ExitCode))"
                }
                
                $hasFiles = $true
            }

            # --- FASE B: Inyección de Registro ---
            $blockedSections = 0
            $regFiles = Get-ChildItem -Path $tempExtract -Filter "*.reg" -Recurse
            foreach ($reg in $regFiles) {
                Write-Log -LogLevel ACTION -Message "Inyectando registro adjunto: $($reg.Name)"
                $regResult = Import-OfflineReg -FilePath $reg.FullName -PassThru
                $blockedSections += $regResult.BlockedSections
            }

            $msg = Get-AIOString 'addons.injected_prefix'
            if ($hasFiles) { $msg += Get-AIOString 'addons.tag_files' }
            if ($regFiles) { $msg += Get-AIOString 'addons.tag_registry' }
            return (New-AIOAddonResult -Message $msg.Trim() -BlockedSections $blockedSections -PassThru:$PassThru)

        } finally {
            # Limpieza absoluta garantizada
            if (Test-Path $tempExtract) { Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    throw "Formato no soportado para inyeccion automatica."
}

# ============================================================================
# --- COMPATIBILIDAD: Paquetes DeltaPack Dual-Engine (manifest_*.json) ------
# ============================================================================

function Get-DeltaPackManifest {
    param([Parameter(Mandatory=$true)][string]$PackagePath)

    $files = @(Get-ChildItem -LiteralPath $PackagePath -Filter 'manifest_*.json' -File -ErrorAction Stop)
    if ($files.Count -gt 1) { throw 'El paquete contiene varios manifiestos.' }
    $manifestFile = $files | Select-Object -First 1
    if (-not $manifestFile) {
        throw "No se encontro 'manifest_*.json' en '$PackagePath'. No es un paquete DeltaPack Dual-Engine valido."
    }

    $manifestPath = Resolve-AIODeltaChild $PackagePath $manifestFile.Name
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        throw "El manifest '$($manifestFile.Name)' no es un JSON valido: $($_.Exception.Message)"
    }

    if (-not $manifest.generatedBy -or $manifest.generatedBy -notmatch 'DeltaPack') {
        throw "El manifest '$($manifestFile.Name)' no fue generado por DeltaPack Dual-Engine."
    }
    if (-not $manifest.outputs) {
        throw "El manifest '$($manifestFile.Name)' no contiene la seccion 'outputs' esperada (esquema no soportado)."
    }

    Add-Member -InputObject $manifest -NotePropertyName '_ManifestPath' -NotePropertyValue $manifestFile.FullName -Force
    Add-Member -InputObject $manifest -NotePropertyName '_PackagePath'  -NotePropertyValue (Resolve-Path $PackagePath).Path -Force
    return $manifest
}

function Resolve-AIODeltaChild {
    param([string]$Root,[string]$Relative)
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative -match '^[\\/]|[:*?"<>|\x00-\x1f]') {
        throw "Nombre relativo de paquete invalido: '$Relative'."
    }
    $current = [IO.Path]::GetFullPath($Root)
    $rootAttributes = [IO.File]::GetAttributes($current)
    if (($rootAttributes -band [IO.FileAttributes]::ReparsePoint) -or -not ($rootAttributes -band [IO.FileAttributes]::Directory)) {
        throw "Raiz de paquete o montaje no verificable: $Root"
    }
    $parts = @($Relative.TrimEnd('\','/') -split '[\\/]')
    if ($parts.Count -gt 1 -and $parts[0] -eq '.') { $parts = @($parts | Select-Object -Skip 1) }
    foreach ($name in $parts) {
        if (-not $name -or $name -match '[ .]$|^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]|CONIN\$|CONOUT\$)(?:\.|$)') {
            throw "Componente de ruta no permitido: '$Relative'."
        }
        $current = [IO.Path]::Combine($current,$name)
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] { continue }
        catch [System.IO.DirectoryNotFoundException] { continue }
        if ($attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Ruta redirigida en el paquete o montaje: $current" }
    }
    return $current
}

function Get-AIODeltaTree {
    param([string]$Root)
    $stack = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $stack.Push([IO.DirectoryInfo]::new($Root))
    while ($stack.Count) {
        foreach ($entry in $stack.Pop().GetFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Punto de reanalisis en el arbol: $($entry.FullName)" }
            $entry
            if ($entry -is [IO.DirectoryInfo]) { $stack.Push($entry) }
        }
    }
}

function Remove-AIODeltaScratch {
    param([IO.DirectoryInfo]$Directory)
    # No seguir enlaces, incluso al retirar una extraccion fallida bajo Windows PowerShell 5.1.
    foreach ($item in $Directory.GetFileSystemInfos()) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { $item.Delete(); continue }
        if ($item -is [IO.DirectoryInfo]) { Remove-AIODeltaScratch $item }
        else { $item.IsReadOnly = $false; $item.Delete() }
    }
    $Directory.Delete()
}

function Assert-AIODeltaChecksums {
    param([string]$List,[string]$Root,[string]$RequiredFile)
    $seen = @{}
    foreach ($line in (Get-Content -LiteralPath $List -Encoding UTF8 -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.TrimStart().StartsWith('#')) { continue }
        if ($line -notmatch '^([0-9a-f]{64})[ \t]+[*]?(.+)$') { throw "Entrada SHA-256 invalida en $List." }
        $expected = $Matches[1]
        $file = Resolve-AIODeltaChild $Root $Matches[2]
        if ($seen.ContainsKey($file)) { throw "Entrada SHA-256 duplicada: $file" }
        $seen[$file] = $true
        if (-not [IO.File]::Exists($file) -or (Get-FileHash -LiteralPath $file -Algorithm SHA256 -ErrorAction Stop).Hash -ne $expected) {
            throw "No se pudo verificar SHA-256 de '$file'."
        }
    }
    if (-not $seen.Count -or ($RequiredFile -and -not $seen.ContainsKey($RequiredFile))) { throw "Lista de integridad incompleta: $List" }
}

function Get-AIODeltaDeletionTarget {
    param($Entry)
    $target = Resolve-AIODeltaChild $Script:MOUNT_DIR $Entry.path
    if ($Entry.kind -notin @('file','directory')) { throw "Tipo de eliminacion no reconocido: $($Entry.kind)" }
    if (Test-Path -LiteralPath $target -ErrorAction Stop) {
        $item = Get-Item -LiteralPath $target -Force -ErrorAction Stop
        if ($item.PSIsContainer -ne ($Entry.kind -eq 'directory')) { throw "El tipo del destino difiere del plan: $target" }
        if ($item.PSIsContainer) { Get-AIODeltaTree $target | Out-Null }
    }
    return $target
}

function Invoke-DeltaPackDeletions {
    param([object[]]$Entries)
    foreach ($entry in $Entries) {
        $target = Get-AIODeltaDeletionTarget $entry
        if (Test-Path -LiteralPath $target -ErrorAction Stop) {
            if ($entry.kind -eq 'directory') {
                # Retirar de las hojas hacia la raiz. Una entrada nueva hace fallar el borrado
                # de la carpeta en vez de iniciar un recorrido recursivo no validado.
                $children = @(Get-AIODeltaTree $target)
                for ($i = $children.Count - 1; $i -ge 0; $i--) {
                    $child = $children[$i]
                    $relative = $child.FullName.Substring($Script:MOUNT_DIR.TrimEnd('\','/').Length + 1)
                    $verified = Resolve-AIODeltaChild $Script:MOUNT_DIR $relative
                    if ($child -is [IO.DirectoryInfo]) { [IO.Directory]::Delete($verified, $false) }
                    else { Remove-Item -LiteralPath $verified -Force -ErrorAction Stop }
                }
                $target = Resolve-AIODeltaChild $Script:MOUNT_DIR $entry.path
                [IO.Directory]::Delete($target, $false)
            } else { Remove-Item -LiteralPath $target -Force -ErrorAction Stop }
            Write-Log -LogLevel ACTION -Message "DeltaPack: eliminado $target"
        }
    }
}

function Invoke-DeltaPackActions {
    param(
        [Parameter(Mandatory=$true)]$Actions,
        [Parameter(Mandatory=$true)][ValidateSet('afterWimBeforeRegistry','afterRegistry')][string]$Phase
    )

    $phaseData = $actions.phases.$Phase
    if (-not $phaseData) { return }

    if ($Phase -eq 'afterWimBeforeRegistry') {
        foreach ($drv in $phaseData.driverPackages) {
            $infFull = Resolve-AIODeltaChild $Script:MOUNT_DIR $drv.infPath
            if (Test-Path -LiteralPath $infFull) {
                Write-Log -LogLevel ACTION -Message "DeltaPackActions: Registrando driver offline -> $($drv.infPath)"
                $proc = Invoke-AIOConsoleSystemTool -Tool dism.exe -Arguments @("/Image:$Script:MOUNT_DIR",'/Add-Driver',"/Driver:$infFull",'/ForceUnsigned')
                if ($proc.ExitCode -ne 0) {
                    throw "DISM /Add-Driver fallo con codigo $($proc.ExitCode) para '$($drv.infPath)'."
                }
            } else {
                throw "INF requerido ausente: $($drv.infPath)"
            }
        }
        foreach ($cat in $phaseData.protectedCatalogs) {
            Write-Log -LogLevel WARN -Message "DeltaPackActions: Catalogo/controlador protegido requiere revision manual (no automatizable): $($cat.path)"
        }
    }
    else {
        foreach ($task in $phaseData.scheduledTasks) {
            Write-Log -LogLevel INFO -Message "DeltaPackActions: Tarea programada pendiente de validacion post-arranque: $($task.taskFile)"
        }
        foreach ($rp in $phaseData.reparsePoints) {
            Write-Log -LogLevel INFO -Message "DeltaPackActions: Punto de reanalisis reportado por el paquete: $rp"
        }
    }
}

# --- MOTOR PRINCIPAL: Inyector de Paquetes DeltaPack Dual-Engine (respeta manifest.deployment.order) ---
function Install-DeltaPackPackage {
    param(
        [Parameter(Mandatory=$true)][string]$PackagePath,
        [int]$WimIndex = 1,
        [switch]$PassThru
    )

    $manifest = Get-DeltaPackManifest -PackagePath $PackagePath
    $fullName = $manifest.package.fullName

    # --- Validacion de arquitectura contra la imagen montada (bloqueante) ---
    $imgArch =
        if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32")) { "ARM64" }
        elseif (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) { "x64" }
        else                                                                { "x86" }

    if ($manifest.compatibility.architecture -and $manifest.compatibility.architecture -ne $imgArch) {
        throw "Arquitectura del paquete '$fullName' ($($manifest.compatibility.architecture)) no coincide con la imagen montada ($imgArch)."
    }

    # --- Aviso no bloqueante de linea base de servicing (build de captura vs. imagen) ---
    $regData = Get-ItemProperty -Path "Registry::HKLM\OfflineSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction SilentlyContinue
    if ($regData -and $manifest.compatibility.buildNumber -and $regData.CurrentBuildNumber -and
        ([string]$regData.CurrentBuildNumber -ne [string]$manifest.compatibility.buildNumber)) {
        Write-Log -LogLevel WARN -Message "DeltaPack [$fullName]: Build de captura ($($manifest.compatibility.buildNumber)) difiere del build de la imagen montada ($($regData.CurrentBuildNumber)). Continuando (politica declarada: '$($manifest.compatibility.policy)')."
    }

    $outputs = @{}
    foreach ($key in @('wimFile','regFile','actionsFile','deletionsFile','checksumsFile','artifactChecksumsFile')) {
        $relative = $manifest.outputs.$key
        if ($null -eq $relative -or $relative -ceq '') { continue }
        $file = Resolve-AIODeltaChild $PackagePath $relative
        if (-not [IO.File]::Exists($file)) { throw "Recurso declarado ausente ($key): $relative" }
        $outputs[$key] = $file
    }
    if ($outputs.artifactChecksumsFile) { Assert-AIODeltaChecksums $outputs.artifactChecksumsFile $PackagePath $outputs.wimFile }
    if ($outputs.checksumsFile -and -not $outputs.wimFile) { throw 'Lista de payload declarada sin WIM.' }

    $entries = @()
    if ($outputs.deletionsFile) {
        $deletions = Get-Content -LiteralPath $outputs.deletionsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $deletions.entries) { throw 'Lista de eliminaciones incompleta.' }
        $entries = @($deletions.entries | Where-Object { $_.operation -eq 'delete' })
        foreach ($entry in $entries) { $null = Get-AIODeltaDeletionTarget $entry }
    }
    if ($null -ne $manifest.deletions.actionableEntryCount -and $entries.Count -ne [int]$manifest.deletions.actionableEntryCount) {
        throw 'El numero de eliminaciones del plan difiere del manifest.'
    }
    $actions = $null
    $drivers = @()
    if ($outputs.actionsFile) {
        $actions = Get-Content -LiteralPath $outputs.actionsFile -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $actions.phases) { throw 'Plan de acciones sin fases.' }
        $drivers = @($actions.phases.afterWimBeforeRegistry.driverPackages | Where-Object { $null -ne $_ })
        foreach ($driver in $drivers) { $null = Resolve-AIODeltaChild $Script:MOUNT_DIR $driver.infPath }
    }
    if (-not ($outputs.wimFile -or $outputs.regFile -or $outputs.actionsFile -or $outputs.deletionsFile)) {
        throw 'El paquete no declara contenido aplicable.'
    }

    $stage = $null
    $blockedSections = 0
    try {
        if ($outputs.wimFile) {
            $indexes = @(Get-AIOWimIndexes -ImagePath $outputs.wimFile)
            $index = if ($indexes.Count -eq 1) { $indexes[0] } else { $WimIndex }
            if ($index -notin $indexes) { throw "Indice WIM ausente: $index" }
            $scratch = (Get-AIOFileIdentity $Script:Scratch_DIR).Path
            $mount = (Get-AIOFileIdentity $Script:MOUNT_DIR).Path
            if (Test-AIOPathWithin $scratch $mount) { throw 'Scratch debe estar fuera de la imagen offline.' }
            $stage = (New-Item -ItemType Directory -Path (Join-Path $Script:Scratch_DIR ('DeltaPack_' + [Guid]::NewGuid().ToString('N'))) -ErrorAction Stop).FullName
            $result = Invoke-AIOConsoleSystemTool -Tool dism.exe -Arguments @('/Apply-Image',"/ImageFile:$($outputs.wimFile)","/Index:$index","/ApplyDir:$stage")
            if ($result.ExitCode -ne 0) { throw "Fallo al extraer el WIM (DISM $($result.ExitCode))." }
            if ($outputs.checksumsFile) { Assert-AIODeltaChecksums $outputs.checksumsFile $stage }
            # Verificar tanto el arbol extraido como cada ruta equivalente en el destino antes de copiar.
            Get-AIODeltaTree $stage | ForEach-Object {
                $relative = $_.FullName.Substring($stage.Length + 1)
                $target = Resolve-AIODeltaChild $Script:MOUNT_DIR $relative
                if ((Test-Path -LiteralPath $target) -and ([IO.Directory]::Exists($target) -ne ($_ -is [IO.DirectoryInfo]))) {
                    throw "Tipo de archivo incompatible en la imagen: $relative"
                }
            }
        }
        foreach ($driver in $drivers) {
            $inf = Resolve-AIODeltaChild $Script:MOUNT_DIR $driver.infPath
            if (-not [IO.File]::Exists($inf) -and (-not $stage -or -not [IO.File]::Exists((Resolve-AIODeltaChild $stage $driver.infPath)))) {
                throw "INF requerido ausente: $($driver.infPath)"
            }
        }
        if ($stage) {
            Enable-Privileges
            & robocopy.exe $stage $Script:MOUNT_DIR /E /B /IS /IT /XJ /R:0 /W:0 /NJH /NJS /NDL /NC /NS /NP | Out-Host
            if ($LASTEXITCODE -notin (0..7)) { throw "Fallo al copiar el payload (Robocopy $LASTEXITCODE)." }
        }
        if ($actions) { Invoke-DeltaPackActions -Actions $actions -Phase 'afterWimBeforeRegistry' }
        Invoke-DeltaPackDeletions -Entries $entries
        if ($outputs.regFile) {
            $reg = Import-OfflineReg -FilePath $outputs.regFile -PassThru
            $blockedSections = $reg.BlockedSections
        }
        if ($actions) { Invoke-DeltaPackActions -Actions $actions -Phase 'afterRegistry' }
    } finally {
        if ($stage) {
            try { Remove-AIODeltaScratch ([IO.DirectoryInfo]::new($stage)) }
            catch { Write-Warning "Extraccion temporal pendiente en $stage. $($_.Exception.Message)" }
        }
    }
    $applied = @(
        if ($outputs.wimFile) { 'WIM' }
        if ($outputs.actionsFile) { 'Acciones' }
        if ($outputs.deletionsFile) { "Eliminaciones: $($entries.Count)" }
        if ($outputs.regFile) { 'Registro' }
    ) -join ', '
    return (New-AIOAddonResult -Message "DeltaPack '$fullName' [$applied]" -BlockedSections $blockedSections -PassThru:$PassThru)
}

# --- INTERFAZ GRÁFICA DEL GESTOR DE ADDONS ---
function Show-Addons-GUI {
    # Los ensamblados deben cargarse ANTES de cualquier MessageBox (incluido el guard de
    # imagen no montada); si esta es la primera GUI de la sesion, el tipo aun no existe.
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    if ($Script:IMAGE_MOUNTED -eq 0) { 
        [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'drivers.mount_first'), (Get-AIOString 'common.error_title'), 'OK', 'Error')
        return 
    }

    if (-not (Mount-Hives)) { return }

    # Flags a nivel de script (no de scriptblock) para que Add_Click y Add_FormClosing,
    # que corren como delegates independientes, vean y actualicen el mismo estado.
    $script:AddonBusy          = $false
    $script:AddonHivesUnmounted = $false

    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text = Get-AIOString 'addons.form_title'
        $form.Size = New-Object System.Drawing.Size(950, 660)
        $form.StartPosition = "CenterScreen"
        $form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $form.ForeColor = [System.Drawing.Color]::White
        $form.FormBorderStyle = "FixedDialog"
        $form.MaximizeBox = $false

        # --- TÍTULO Y BOTÓN DE CARGA ---
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = Get-AIOString 'addons.title'
        $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $lblTitle.Location = "20, 15"; $lblTitle.AutoSize = $true
        $form.Controls.Add($lblTitle)

        # Botón de Información / Ayuda
        $btnHelp = New-Object System.Windows.Forms.Button
        $btnHelp.Text = "?"
        $btnHelp.Location = "630, 12"
        $btnHelp.Size = "30, 30"
        $btnHelp.BackColor = [System.Drawing.Color]::DarkOrange
        $btnHelp.FlatStyle = "Flat"
        $btnHelp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($btnHelp)

        $btnAddFiles = New-Object System.Windows.Forms.Button
        $btnAddFiles.Text = Get-AIOString 'addons.btn_add'
        $btnAddFiles.Location = "670, 12"
        $btnAddFiles.Size = "240, 30"
        $btnAddFiles.BackColor = [System.Drawing.Color]::RoyalBlue
        $btnAddFiles.FlatStyle = "Flat"
        $form.Controls.Add($btnAddFiles)

        # Label de advertencia de nomenclatura (Texto Rápido)
        $lblNomenclatura = New-Object System.Windows.Forms.Label
        $lblNomenclatura.Text = Get-AIOString 'addons.nomenclature_hint'
        $lblNomenclatura.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
        $lblNomenclatura.ForeColor = [System.Drawing.Color]::White
        $lblNomenclatura.Location = "20, 42"
        $lblNomenclatura.AutoSize = $true
        $form.Controls.Add($lblNomenclatura)

        # --- DETECCIÓN INTELIGENTE DE ARQUITECTURA (INSTANTÁNEA) ---
        # Mismo criterio que la deteccion global del script (SysArm32 / SysWOW64).
        $defaultIdx = 1 # Asumimos x86 por defecto
        if     (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysArm32")) { $defaultIdx = 3 } # ARM64
        elseif (Test-Path (Join-Path $Script:MOUNT_DIR "Windows\SysWOW64")) { $defaultIdx = 2 } # x64

        # --- SELECTOR DE ARQUITECTURA (GRUPO) ---
        $grpArch = New-Object System.Windows.Forms.GroupBox
        $grpArch.Text = Get-AIOString 'addons.grp_arch'
        $grpArch.Location = "20, 65" 
        $grpArch.Size = "890, 55"
        $grpArch.ForeColor = [System.Drawing.Color]::Orange
        $form.Controls.Add($grpArch)

        $radX86 = New-Object System.Windows.Forms.RadioButton
        $radX86.Text = "x86 / 32-bits"
        $radX86.Location = "20, 22"
        $radX86.AutoSize = $true
        $radX86.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 1) { $radX86.Checked = $true }
        $grpArch.Controls.Add($radX86)

        $radX64 = New-Object System.Windows.Forms.RadioButton
        $radX64.Text = "x64 / 64-bits"
        $radX64.Location = "200, 22"
        $radX64.AutoSize = $true
        $radX64.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 2) { $radX64.Checked = $true }
        $grpArch.Controls.Add($radX64)

        $radArm64 = New-Object System.Windows.Forms.RadioButton
        $radArm64.Text = "ARM64"
        $radArm64.Location = "380, 22"
        $radArm64.AutoSize = $true
        $radArm64.ForeColor = [System.Drawing.Color]::White
        if ($defaultIdx -eq 3) { $radArm64.Checked = $true }
        $grpArch.Controls.Add($radArm64)

        # --- LISTVIEW (DESPLAZADO HACIA ABAJO) ---
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = "20, 135"
        $lv.Size = "890, 360"
        $lv.View = "Details"
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
        $lv.ForeColor = [System.Drawing.Color]::White
        
        $lv.Columns.Add((Get-AIOString 'addons.col_status'), 150) | Out-Null
        $lv.Columns.Add((Get-AIOString 'addons.col_file'), 250) | Out-Null
        $lv.Columns.Add((Get-AIOString 'addons.col_type'), 120) | Out-Null
        $lv.Columns.Add((Get-AIOString 'addons.col_path'), 360) | Out-Null
        $form.Controls.Add($lv)

        # --- PALETA DE COLORES DE ESTADO (centralizada para mantenimiento) ---
        $ColorEspera     = [System.Drawing.Color]::Silver       # Neutral: en cola, sin actividad aun
        $ColorProcesando = [System.Drawing.Color]::Cyan         # Activo: se esta procesando AHORA MISMO
        $ColorCompletado = [System.Drawing.Color]::LimeGreen    # Exito
        $ColorError      = [System.Drawing.Color]::Tomato       # Fallo critico
        $ColorOmitido    = [System.Drawing.Color]::Goldenrod    # Omitido por arquitectura (advertencia, no error)

        # --- ESTADO Y BOTONES INFERIORES ---
        $lblStatus = New-Object System.Windows.Forms.Label
        $lblStatus.Text = Get-AIOString 'addons.status_initial'
        $lblStatus.Location = "20, 505"
        $lblStatus.AutoSize = $true
        $lblStatus.ForeColor = [System.Drawing.Color]::Cyan
        $form.Controls.Add($lblStatus)

        $btnRemoveItem = New-Object System.Windows.Forms.Button
        $btnRemoveItem.Text = Get-AIOString 'addons.btn_remove'
        $btnRemoveItem.Location = "20, 530"
        $btnRemoveItem.Size = "150, 30"
        $btnRemoveItem.BackColor = [System.Drawing.Color]::Crimson
        $btnRemoveItem.FlatStyle = "Flat"
        $form.Controls.Add($btnRemoveItem)

        $btnInstall = New-Object System.Windows.Forms.Button
        $btnInstall.Text = Get-AIOString 'addons.btn_install'
        $btnInstall.Location = "640, 520"
        $btnInstall.Size = "270, 40"
        $btnInstall.BackColor = [System.Drawing.Color]::SeaGreen
        $btnInstall.FlatStyle = "Flat"
        $btnInstall.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($btnInstall)

        $progressBar = New-Object System.Windows.Forms.ProgressBar
        $progressBar.Location = New-Object System.Drawing.Point(20, 580)
        $progressBar.Size = New-Object System.Drawing.Size(890, 15)
        $progressBar.Style = "Continuous"
        $progressBar.Visible = $false
        $form.Controls.Add($progressBar)

        # --- EVENTO DEL BOTÓN DE AYUDA ---
        $btnHelp.Add_Click({
            $helpMsg = Get-AIOString 'addons.help_body'

            [System.Windows.Forms.MessageBox]::Show($helpMsg, (Get-AIOString 'addons.help_title'), 'OK', 'Information')
        })

        # --- EVENTOS ---
        $btnAddFiles.Add_Click({
            $ofd = New-Object System.Windows.Forms.OpenFileDialog
            $ofd.Filter = Get-AIOString 'addons.filter_addons'
            $ofd.Multiselect = $true
            if ($ofd.ShowDialog() -eq 'OK') {
                $lv.BeginUpdate()
                foreach ($file in $ofd.FileNames) {

                    # --- Paquete DeltaPack Dual-Engine: se agrega seleccionando su manifest_*.json ---
                    if ([System.IO.Path]::GetFileName($file) -match '^(?i)manifest_.*\.json$') {
                        $packageFolder = Split-Path $file -Parent
                        try {
                            $dpManifest = Get-DeltaPackManifest -PackagePath $packageFolder
                        } catch {
                            [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.deltapack_invalid' $packageFolder $_.Exception.Message), (Get-AIOString 'addons.deltapack_invalid_title'), 'OK', 'Error')
                            continue
                        }

                        $yaAgregado = $lv.Items | Where-Object { $_.Tag -is [pscustomobject] -and $_.Tag.Kind -eq 'DeltaPack' -and $_.Tag.Path -eq $packageFolder }
                        if ($yaAgregado) { continue }

                        $displayName = if ($dpManifest.outputs.wimFile) { $dpManifest.outputs.wimFile } else { "$($dpManifest.package.fullName).wim" }

                        $item = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                        $item.SubItems.Add($displayName) | Out-Null
                        $item.SubItems.Add("DELTAPACK") | Out-Null
                        $item.SubItems.Add($packageFolder) | Out-Null
                        $item.ForeColor = $ColorEspera
                        $item.Tag = [pscustomobject]@{ Kind = 'DeltaPack'; Path = $packageFolder }
                        $lv.Items.Add($item) | Out-Null
                        continue
                    }

                    # --- Addon suelto (.wim / .tpk / .bpk / .reg) ---
                    $item = New-Object System.Windows.Forms.ListViewItem("EN ESPERA")
                    $item.SubItems.Add([System.IO.Path]::GetFileName($file)) | Out-Null
                    $item.SubItems.Add([System.IO.Path]::GetExtension($file).ToUpper()) | Out-Null
                    $item.SubItems.Add($file) | Out-Null
                    $item.ForeColor = $ColorEspera
                    $item.Tag = $file
                    $lv.Items.Add($item) | Out-Null
                }
                $lv.EndUpdate()
            }
        })

        $btnRemoveItem.Add_Click({
            foreach ($item in $lv.SelectedItems) { $lv.Items.Remove($item) }
        })

        $btnInstall.Add_Click({
            if ($lv.Items.Count -eq 0) { 
                Write-Log -LogLevel WARN -Message "AddonInjector: Intento de ejecucion sin addons en la lista."
                return 
            }
            $confirm = [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.confirm_batch'), (Get-AIOString 'drivers.confirm_title'), 'YesNo', 'Warning')
            if ($confirm -ne 'Yes') { 
                Write-Log -LogLevel INFO -Message "AddonInjector: Operacion cancelada por el usuario en el cuadro de confirmacion."
                return 
            }

            # --- Limpiar caché SDDL residual de ejecuciones previas fallidas ---
            $Script:SDDL_Backups.Clear()

            Write-Log -LogLevel ACTION -Message "AddonInjector: Iniciando motor de inyeccion inteligente de Addons."

            $script:AddonBusy      = $true
            $btnInstall.Enabled    = $false
            $btnRemoveItem.Enabled = $false
            $btnAddFiles.Enabled   = $false
            $form.Cursor           = [System.Windows.Forms.Cursors]::WaitCursor
            $errors = 0; $success = 0; $skipped = 0; $withOmissions = 0; $totalBlockedSections = 0

            try {
                # Capturamos la arquitectura de la UI (1=x86, 2=x64, 3=ARM64 dentro del .wim/.tpk/.bpk)
                $targetArch = if ($radX86.Checked) { "x86" } elseif ($radX64.Checked) { "x64" } else { "ARM64" }
                $selectedIndex = if ($radX86.Checked) { 1 } elseif ($radX64.Checked) { 2 } else { 3 }
                Write-Log -LogLevel INFO -Message "AddonInjector: Destino arquitectonico -> $targetArch | Indice WIM local: $selectedIndex"

                # --- 1. EXTRAER ELEMENTOS PENDIENTES ---
                $pendingItems = @()
                foreach ($item in $lv.Items) {
                    if ($item.Text -eq "EN ESPERA") {
                        $pendingItems += $item
                    }
                }

                if ($pendingItems.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.none_pending'), (Get-AIOString 'addons.none_pending_title'), 'OK', 'Information') | Out-Null
                    return
                }

                # --- 2. ORDENAMIENTO INTELIGENTE (Prioridad + Alfabeto) ---
                $lblStatus.Text = Get-AIOString 'addons.status_calc_order'
                $form.Refresh()

                $sortedItems = @($pendingItems | Sort-Object {
                    $fileName = $_.SubItems[1].Text.ToLower()
                    $priority = 5 # Prioridad por defecto (otros)
                    
                    # Asignacion de pesos (1 es lo primero que se instala)
                    if ($fileName -match "_main\.(tpk|bpk|wim)$") { $priority = 1 } # Paquetes Principales
                    elseif ($fileName -match "_main\.reg$")               { $priority = 2 } # Registro Principal
                    elseif ($fileName -match "\.(tpk|bpk|wim)$")   { $priority = 3 } # Paquetes de Idioma / Extras
                    elseif ($fileName -match "\.reg$")                     { $priority = 4 } # Registros de Idioma / Extras

                    # Al retornar "Prioridad-Nombre", PowerShell agrupa primero por fase y luego alfabeticamente
                    # Ej: "1-firefox_main.tpk" se procesara antes que "2-firefox_x64_main.reg"
                    "$priority-$fileName"
                })
                Write-Log -LogLevel INFO -Message "AddonInjector: Fase 2 - $($sortedItems.Count) elementos ordenados por algoritmo de prioridad."

                $progressBar.Value   = 0
                $progressBar.Maximum = $sortedItems.Count
                $progressBar.Visible = $true
                $count = 0

                # --- 3. PROCESAMIENTO E INYECCION ---
                foreach ($item in $sortedItems) {
                    try {
                        [System.Windows.Forms.Application]::DoEvents()

                        $fileName = $item.SubItems[1].Text.ToLower()

                        # --- CONDICION 1: FILTRO DE ARQUITECTURA (x86 / x64 / ARM64, mutuamente excluyentes) ---
                        $is64BitFile = $fileName -match "(\b|_|\.|-)(x64|64-?bit|amd64)(\b|_|\.|-)"
                        $is32BitFile = $fileName -match "(\b|_|\.|-)(x86|32-?bit)(\b|_|\.|-)"
                        $isArm64File = $fileName -match "(\b|_|\.|-)(arm64|aarch64)(\b|_|\.|-)"

                        $archMismatch = $false
                        $archReason   = ""
                        switch ($targetArch) {
                            "x86"   { if ($is64BitFile)  { $archMismatch = $true; $archReason = "Solo x64" }
                                      elseif ($isArm64File) { $archMismatch = $true; $archReason = "Solo ARM64" } }
                            "x64"   { if ($is32BitFile)  { $archMismatch = $true; $archReason = "Solo x86" }
                                      elseif ($isArm64File) { $archMismatch = $true; $archReason = "Solo ARM64" } }
                            "ARM64" { if ($is32BitFile)  { $archMismatch = $true; $archReason = "Solo x86" }
                                      elseif ($is64BitFile) { $archMismatch = $true; $archReason = "Solo x64" } }
                        }

                        if ($archMismatch) {
                            $item.Text = "OMITIDO (Arch)"
                            $item.SubItems[2].Text = "Ignorado ($archReason)"
                            $item.ForeColor = $ColorOmitido
                            $skipped++
                            Write-Log -LogLevel INFO -Message "AddonInjector: Omitiendo [$fileName] ($archReason, imagen destino $targetArch)."
                            continue
                        }

                        # --- CONDICION 2: INYECCION EN ORDEN ---
                        $lblStatus.Text = Get-AIOString 'addons.status_injecting' $item.SubItems[1].Text
                        $item.Text = "PROCESANDO..."
                        $item.ForeColor = $ColorProcesando

                        # Hacemos auto-scroll en la UI para ver por donde va
                        $item.EnsureVisible()
                        $form.Refresh()

                        Write-Log -LogLevel INFO -Message "AddonInjector: Instalando -> [$fileName]"

                        try {
                            # Motor correspondiente segun el tipo de addon en cola (archivo suelto vs. paquete DeltaPack)
                            if ($item.Tag -is [pscustomobject] -and $item.Tag.Kind -eq 'DeltaPack') {
                                $resultado = Install-DeltaPackPackage -PackagePath $item.Tag.Path -WimIndex $selectedIndex -PassThru
                            } else {
                                $resultado = Install-OfflineAddon -FilePath $item.Tag -WimIndex $selectedIndex -PassThru
                            }

                            $item.SubItems[2].Text = $resultado.Message
                            if ($resultado.Status -eq 'CompletedWithOmissions') {
                                $item.Text = "COMPLETADO CON OMISIONES"
                                $item.ForeColor = $ColorOmitido
                                $withOmissions++
                                $totalBlockedSections += $resultado.BlockedSections
                                Write-Log -LogLevel WARN -Message "AddonInjector: Completado con omisiones. $($resultado.Message)"
                            } else {
                                $item.Text = "COMPLETADO"
                                $item.ForeColor = $ColorCompletado
                                $success++
                                Write-Log -LogLevel INFO -Message "AddonInjector: Completado. $($resultado.Message)"
                            }
                        } catch {
                            $item.Text = "ERROR"
                            $item.SubItems[2].Text = $_.Exception.Message
                            $item.ForeColor = $ColorError
                            $errors++
                            Write-Log -LogLevel ERROR -Message "AddonInjector: Fallo critico instalando addon [$fileName] - $($_.Exception.Message)"
                        }
                    } finally {
                        # Contar el objeto solo despues de terminar su procesamiento.
                        $count++
                        $progressBar.Value = [Math]::Min($count, $progressBar.Maximum)
                        $form.Refresh()
                        [System.Windows.Forms.Application]::DoEvents()
                    }
                }

                Write-Log -LogLevel ACTION -Message "AddonInjector: Ciclo de inyeccion finalizado. Exitos sin omisiones: $success | Con omisiones: $withOmissions | Secciones bloqueadas: $totalBlockedSections | Errores: $errors | Omitidos (Arch): $skipped"

                try {
                    Restore-AllOfflineSDDL
                } catch {
                    Write-Log -LogLevel WARN -Message "AddonInjector: Fallo al restaurar SDDL tras la inyeccion - $($_.Exception.Message)"
                }

                $reportIcon = if ($errors -gt 0) { 'Error' } elseif ($withOmissions -gt 0) { 'Warning' } else { 'Information' }
                [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.report_body' $success $withOmissions $totalBlockedSections $errors $skipped), (Get-AIOString 'addons.report_title'), 'OK', $reportIcon)
            } catch {
                Write-Log -LogLevel ERROR -Message "AddonInjector: Error inesperado durante el ciclo de inyeccion - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.err_unexpected' $_.Exception.Message), (Get-AIOString 'common.error_title'), 'OK', 'Error') | Out-Null
            } finally {
                $progressBar.Visible   = $false
                $form.Cursor           = [System.Windows.Forms.Cursors]::Default
                $btnInstall.Enabled    = $true
                $btnRemoveItem.Enabled = $true
                $btnAddFiles.Enabled   = $true
                $lblStatus.Text        = Get-AIOString 'addons.status_done'
                $script:AddonBusy      = $false
            }
        })

        # Cierre seguro (Desmontar Hives de registro)
        $form.Add_FormClosing({ 
            if ($script:AddonBusy) {
                [System.Windows.Forms.MessageBox]::Show(
                    (Get-AIOString 'addons.busy_warn'),
                    (Get-AIOString 'addons.busy_title'), 'OK', 'Warning') | Out-Null
                $_.Cancel = $true
                return
            }

            $confirm = [System.Windows.Forms.MessageBox]::Show(
                (Get-AIOString 'metadata.confirm_exit_body'),
                (Get-AIOString 'metadata.confirm_exit_title'), 
                [System.Windows.Forms.MessageBoxButtons]::YesNo, 
                [System.Windows.Forms.MessageBoxIcon]::Question
            )

            if ($confirm -eq 'No') {
                $_.Cancel = $true
            } else {
                $lblStatus.Text = Get-AIOString 'servicios.status_unloading_hives'
                $form.Refresh()
                Start-Sleep -Milliseconds 500
                if (-not $script:AddonHivesUnmounted) {
                    Unmount-Hives
                    $script:AddonHivesUnmounted = $true
                }
            }
        })
        
        $form.ShowDialog() | Out-Null
        $form.Dispose()
    } catch {
        Write-Log -LogLevel ERROR -Message "AddonInjector: Error inesperado construyendo la GUI - $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show((Get-AIOString 'addons.err_open' $_.Exception.Message), (Get-AIOString 'common.error_title'), 'OK', 'Error') | Out-Null
    } finally {
        if (-not $script:AddonHivesUnmounted) {
            Unmount-Hives
            $script:AddonHivesUnmounted = $true
        }
        [GC]::Collect()
    }
}