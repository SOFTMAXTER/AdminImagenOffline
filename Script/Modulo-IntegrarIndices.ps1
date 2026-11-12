# =================================================================
#  Modulo-IntegrarIndices
#
#  CONTENIDO   : Show-AIOIndexIntegrator (GUI) y sus funciones de apoyo
#                (lectura del catalogo de indices, plan de salida, validacion,
#                compatibilidad y exportacion con wimlib)
#  DEPENDENCIAS DEL NUCLEO (heredadas via dot-source):
#    - $Script:IMAGE_MOUNTED  : estado de montaje (1 = WIM); solo se consulta
#    - $Script:WIM_FILE_PATH  : ruta de la imagen montada; se usa para rechazar
#                               una fuente que este montada en la aplicacion
#  DEPENDENCIAS EXTERNAS:
#    - wimlib-imagex.exe      : en Tools\wimlib o en PATH (lectura, exportacion
#                               y verificacion de los WIM)
#  CARGA       : . "$PSScriptRoot\Modulo-IntegrarIndices.ps1"
#
#  NOTA: Esta funcion NO requiere imagen montada ($Script:IMAGE_MOUNTED).
#  Las fuentes WIM/ESD se abren solo para lectura y nunca se modifican; el
#  modulo no cambia el estado de montaje global y es autocontenido (usa su
#  propio registro .log junto al destino en lugar de Write-Log). Carga sin
#  efectos laterales.
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

function Find-AIOIndexWimlib {
    $bundled = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools\wimlib\wimlib-imagex.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    $command = Get-Command wimlib-imagex.exe -CommandType Application -ErrorAction SilentlyContinue
    if (-not $command) { $command = Get-Command wimlib-imagex -CommandType Application -ErrorAction SilentlyContinue }
    if ($command) { return $command.Source }
    throw 'No se encontro wimlib-imagex.exe en Tools\wimlib ni en PATH.'
}

function ConvertTo-AIOIndexArgument {
    param([AllowEmptyString()][string]$Value)
    # Quote cada argumento con reglas de CommandLineToArgvW. No interviene cmd.exe.
    '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Assert-AIOIndexNotCancelled {
    param([hashtable]$State)
    if ($State -and $State.Cancel) { throw [OperationCanceledException]::new('Operacion cancelada. No se publico un WIM de salida.') }
}

function Write-AIOIndexLog {
    param([string]$Path, [string]$Text)
    if ($Path) { Add-Content -LiteralPath $Path -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text) -Encoding UTF8 -ErrorAction Stop }
}

function Initialize-AIOIndexNativeReader {
    # Mismo patron que AIODeployNativeReader: callbacks C# a colas concurrentes.
    # Ningun scriptblock PowerShell ni control WinForms se ejecuta en callbacks .NET.
    if ('AIOIndexNativeReaderV1' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
public sealed class AIOIndexNativeReaderV1 : IDisposable {
    private readonly Process process;
    public readonly ConcurrentQueue<string> Output = new ConcurrentQueue<string>();
    public readonly ConcurrentQueue<string> Error = new ConcurrentQueue<string>();
    public AIOIndexNativeReaderV1(string fileName, string arguments) {
        process = new Process();
        process.StartInfo = new ProcessStartInfo {
            FileName = fileName, Arguments = arguments, UseShellExecute = false,
            CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true
        };
        process.OutputDataReceived += (sender, args) => { if (args.Data != null) Output.Enqueue(args.Data); };
        process.ErrorDataReceived += (sender, args) => { if (args.Data != null) Error.Enqueue(args.Data); };
    }
    public void Start() {
        if (!process.Start()) throw new InvalidOperationException("No se pudo iniciar el proceso.");
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
    }
    public bool HasExited { get { return process.HasExited; } }
    public int ExitCode { get { return process.ExitCode; } }
    public void WaitForExit() { process.WaitForExit(); }
    public void CancelAndWait() {
        if (!process.HasExited) process.Kill();
        process.WaitForExit();
    }
    public void Dispose() { process.Dispose(); }
}
'@
}

function Get-AIOIndexPercent {
    param([string]$Text)
    # Variante del parser de DeployVHD: admite punto/coma decimal y descarta signos/rangos invalidos.
    foreach ($match in [regex]::Matches($Text, '(?<![\d.,+\-])(?<percent>\d{1,3}(?:[.,]\d+)?)\s*%')) {
        $percent = [double]::Parse($match.Groups['percent'].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
        if ($percent -ge 0 -and $percent -le 100) { $percent }
    }
}

function Update-AIOIndexNativeProgress {
    param([hashtable]$State, [string]$Line)
    if (-not $State) { return }
    $phase = ''; $key = ''
    if ($Line -match '^\s*Archiving file data:') { $phase = 'Exportando datos'; $key = 'Archive' }
    elseif ($Line -match '^\s*Verifying integrity of "([^"]+)":') { $phase = 'Comprobando integridad'; $key = 'Integrity:' + $Matches[1] }
    elseif ($Line -match '^\s*Calculating integrity table for WIM:') { $phase = 'Generando tabla de integridad'; $key = 'IntegrityTable' }
    elseif ($Line -match '^\s*Verifying file data:') { $phase = 'Verificando datos'; $key = 'VerifyData' }
    elseif ($Line -match '^\s*\[.*\d+(?:[.,]\d+)?\s*%.*\]\s*$') { $phase = 'Progreso del motor'; $key = 'DismProgress' }
    else { return }
    $percents = @(Get-AIOIndexPercent $Line)
    if ($percents.Count -eq 0) { return }
    # El ultimo porcentaje evita confundir un '%' en la ruta con el progreso real.
    $percent = $percents[-1]
    if ($State.NativePhaseKey -ne $key) {
        $State.NativePhaseKey = $key
        $State.NativePercent = -1.0
    }
    # --check puede terminar al 100% antes de empezar la exportacion; cada fase tiene su propio avance.
    if ($percent -ge [double]$State.NativePercent) {
        $State.NativePhase = $phase
        $State.NativePercent = $percent
    }
}

function Invoke-AIOIndexNative {
    param([string]$Engine, [string[]]$Arguments, [hashtable]$State, [string]$LogPath)
    Assert-AIOIndexNotCancelled $State
    Initialize-AIOIndexNativeReader
    $argumentText = (@($Arguments | ForEach-Object { ConvertTo-AIOIndexArgument $_ }) -join ' ')
    Write-AIOIndexLog $LogPath ('wimlib ' + $argumentText)
    $reader = New-Object AIOIndexNativeReaderV1($Engine, $argumentText)
    $started = $false; $succeeded = $false; $logWriter = $null
    $tail = New-Object 'Collections.Generic.List[string]'
    if ($State) {
        $State.NativePercent = -1.0; $State.NativePhaseKey = ''; $State.NativeActive = $true
        $State.NativeSucceeded = $false
        $State.NativePhase = switch ($Arguments[0]) { 'export' { 'Preparando exportacion' } 'verify' { 'Preparando verificacion' } default { 'Leyendo metadatos' } }
    }
    try {
        if ($LogPath) { $logWriter = New-Object IO.StreamWriter($LogPath, $true, [Text.Encoding]::UTF8) }
        $reader.Start(); $started = $true
        do {
            Assert-AIOIndexNotCancelled $State
            $exited = $reader.HasExited
            # Esperar las ultimas entregas de stdout/stderr antes de drenar y comprobar el codigo.
            if ($exited) { $reader.WaitForExit() }
            foreach ($queue in @($reader.Output, $reader.Error)) {
                $line = $null
                while ($queue.TryDequeue([ref]$line)) {
                    Assert-AIOIndexNotCancelled $State
                    Update-AIOIndexNativeProgress $State $line
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        if ($logWriter) { $logWriter.WriteLine($line) }
                        $tail.Add($line)
                        if ($tail.Count -gt 20) { $tail.RemoveAt(0) }
                    }
                }
            }
            # El runspace trabaja en segundo plano; el Timer es el unico que actualiza la GUI.
            if (-not $exited) { Start-Sleep -Milliseconds 75 }
        } while (-not $exited)
        Assert-AIOIndexNotCancelled $State
        if ($reader.ExitCode -ne 0) { throw "wimlib fallo (codigo $($reader.ExitCode)).`n$($tail -join "`n")" }
        $succeeded = $true
    } finally {
        try {
            # No se retira el temporal mientras el proceso pueda seguir escribiendo.
            if ($started) { $reader.CancelAndWait() }
        } finally {
            if ($logWriter) { $logWriter.Dispose() }
            $reader.Dispose()
            if ($State) { $State.NativeActive = $false; $State.NativeSucceeded = $succeeded }
        }
    }
}

function Read-AIOIndexCatalog {
    param([string]$Path, [string]$Engine, [hashtable]$State, [string]$LogPath)
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Extension -notin @('.wim', '.esd')) { throw 'Selecciona una fuente WIM o ESD (no cifrada).' }
    $xmlPath = Join-Path ([IO.Path]::GetTempPath()) ('AIO-indices-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        Invoke-AIOIndexNative $Engine @('info', $file.FullName, "--extract-xml=$xmlPath") $State $LogPath
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [Xml.XmlReader]::Create($xmlPath, $settings)
        try {
            $xml = New-Object Xml.XmlDocument
            $xml.XmlResolver = $null
            $xml.Load($reader)
        } finally { $reader.Dispose() }
        $nodes = @($xml.SelectNodes('/WIM/IMAGE'))
        if ($nodes.Count -eq 0) { throw 'La fuente no contiene indices.' }
        foreach ($node in $nodes) {
            $arch = [string]$node.WINDOWS.ARCH
            $archName = switch ($arch) { '0' { 'x86' } '9' { 'x64' } '12' { 'ARM64' } default { $arch } }
            [pscustomobject]@{
                Source = $file.FullName; Index = [int]$node.GetAttribute('INDEX')
                Name = [string]$node.NAME; Description = [string]$node.DESCRIPTION
                Architecture = $archName; Edition = [string]$node.WINDOWS.EDITIONID
                Build = [string]$node.WINDOWS.VERSION.BUILD; Flags = [string]$node.FLAGS
                ProductType = [string]$node.WINDOWS.PRODUCTTYPE
                InstallationType = [string]$node.WINDOWS.INSTALLATIONTYPE
                Bytes = [long]$node.TOTALBYTES
                SourceLength = $file.Length; SourceTicks = $file.LastWriteTimeUtc.Ticks
            }
        }
    } finally { if ([IO.File]::Exists($xmlPath)) { [IO.File]::Delete($xmlPath) } }
}

function Format-AIOIndexOutputName {
    param([string]$Name, [string]$Architecture, [int]$Suffix = 0)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    $arch = switch ($Architecture.Trim().ToUpperInvariant()) {
        'X86' { 'x86' }; 'X64' { 'x64' }; 'ARM64' { 'ARM64' }
        '' { 'sin arquitectura' }; default { $Architecture.Trim() }
    }
    # La etiqueta final pertenece al gestor. Corregirla al editar o reimportar;
    # conservar los demas corchetes y el texto personalizado del nombre.
    $baseName = $Name.Trim()
    $pattern = '\s*\[(?:x86|x64|ARM64|sin arquitectura|' + [regex]::Escape($arch) + ')\]\s*$'
    while ($baseName -match $pattern) { $baseName = [regex]::Replace($baseName, $pattern, '', 'IgnoreCase').Trim() }
    if (-not $baseName) { return '' }
    if ($Suffix -gt 1) { $baseName += ' (' + $Suffix + ')' }
    return $baseName + ' [' + $arch + ']'
}

function New-AIOIndexPlanEntry {
    param([object]$Image, [object[]]$Existing = @())
    $baseName = $Image.Name.Trim()
    if (-not $baseName) { $baseName = 'Imagen ' + $Image.Index }
    $name = Format-AIOIndexOutputName $baseName $Image.Architecture
    if (-not $name) { $baseName = 'Imagen ' + $Image.Index; $name = Format-AIOIndexOutputName $baseName $Image.Architecture }
    $suffix = 2
    while (@($Existing | Where-Object { $_.Name -ieq $name }).Count) {
        $name = Format-AIOIndexOutputName $baseName $Image.Architecture $suffix; $suffix++
    }
    [pscustomobject]@{
        Source = $Image.Source; Index = $Image.Index; Name = $name
        OriginalName = $Image.Name; Description = $Image.Description
        Architecture = $Image.Architecture; Edition = $Image.Edition; Build = $Image.Build
        ProductType = $Image.ProductType; InstallationType = $Image.InstallationType
        Flags = $Image.Flags; Bytes = $Image.Bytes
        SourceLength = $Image.SourceLength; SourceTicks = $Image.SourceTicks; Boot = $false
    }
}

function Move-AIOIndexPlanEntry {
    param([Collections.IList]$Plan, [int]$Index, [ValidateSet(-1, 1)][int]$Direction)
    $target = $Index + $Direction
    if ($Index -lt 0 -or $Index -ge $Plan.Count -or $target -lt 0 -or $target -ge $Plan.Count) { return $Index }
    $entry = $Plan[$Index]
    $Plan.RemoveAt($Index)
    $Plan.Insert($target, $entry)
    return $target
}

function Group-AIOIndexPlanByArchitecture {
    param([Collections.IList]$Plan, [int]$SelectedIndex = -1)
    # Indice original como desempate explicito: Sort-Object de PS 5.1 no tiene -Stable.
    $ordered = @(for ($i = 0; $i -lt $Plan.Count; $i++) {
        $arch = ([string]$Plan[$i].Architecture).Trim().ToUpperInvariant()
        $rank = switch ($arch) { 'X86' { 0 }; 'X64' { 1 }; 'ARM64' { 2 }; default { 3 } }
        [pscustomobject]@{ Rank = $rank; Architecture = $arch; Position = $i; Entry = $Plan[$i] }
    })
    $ordered = @($ordered | Sort-Object Rank, Architecture, Position)
    $Plan.Clear()
    $selected = -1
    foreach ($item in $ordered) {
        if ($item.Position -eq $SelectedIndex) { $selected = $Plan.Count }
        [void]$Plan.Add($item.Entry)
    }
    return $selected
}

function Test-AIOIndexWindows11 {
    param([object]$Image)
    # Windows Server y WinPE pueden compartir compilacion con Windows 11.
    if ($Image.ProductType -match '^(ServerNT|LanmanNT)$' -or
        $Image.InstallationType -match '^(Server|WindowsPE|WinPE)' -or
        $Image.Edition -match '^(Server|WindowsPE|WinPE)' -or $Image.Flags -match '^(Server|WindowsPE|WinPE)') { return $false }
    $build = 0
    $hasBuild = [int]::TryParse([string]$Image.Build, [ref]$build)
    if ($hasBuild -and $build -lt 22000) { return $false }
    if ($hasBuild -and ($Image.InstallationType -eq 'Client' -or $Image.ProductType -eq 'WinNT' -or
        $Image.Edition -match '^(Core|Professional|Enterprise|Education|IoTEnterprise|Cloud|PPIPro)')) { return $true }
    # Solo como respaldo de metadatos incompletos; nunca usar el nombre editado.
    $sourceName = if ($Image.PSObject.Properties['OriginalName']) { [string]$Image.OriginalName } else { [string]$Image.Name }
    return $sourceName -match '\bWindows\s*11\b'
}

function Get-AIOIndexCompatibilityWarnings {
    param([object[]]$Plan)
    $architectures = @($Plan | Select-Object -ExpandProperty Architecture -Unique | Where-Object { $_ })
    if ($architectures.Count -gt 1) {
        [pscustomobject]@{ Code = 'MixedArchitecture'; Message = 'Arquitecturas distintas: el orden de los indices es libre. El WIM integrado no prepara el arranque ni Windows Setup para cada arquitectura.' }
    }
    if ($architectures -icontains 'x86' -and @($Plan | Where-Object { Test-AIOIndexWindows11 $_ }).Count -gt 0) {
        [pscustomobject]@{ Code = 'X86Windows11'; Message = 'x86 + Windows 11: Windows 11 no tiene edicion x86 y WinPE x86 no sirve para desplegarlo. Prepara una ruta de arranque, boot.wim (WinPE) y Setup x86 para las imagenes x86, y otra compatible con Windows 11 x64 o ARM64. Si una imagen se identifica como Windows 11 x86, revisa su origen.' }
    }
    if ($architectures -icontains 'ARM64') {
        [pscustomobject]@{ Code = 'ARM64'; Message = 'ARM64: prepara el cargador UEFI ARM64 (EFI\BOOT\BOOTAA64.EFI), boot.wim con WinPE ARM64, Windows Setup compatible y los controladores ARM64 del equipo. Incluir un indice ARM64 en install.wim no adapta un medio de instalacion x64/x86.' }
    }
}

function Assert-AIOIndexPlan {
    param([object[]]$Plan, [string]$Destination)
    if (-not $Plan -or $Plan.Count -eq 0) { throw 'Agrega al menos un indice al orden final.' }
    if ([string]::IsNullOrWhiteSpace($Destination)) { throw 'Selecciona el archivo WIM de salida.' }
    $dest = [IO.Path]::GetFullPath($Destination)
    if ([IO.Path]::GetExtension($dest) -ine '.wim') { throw 'El archivo de salida debe tener extension .wim.' }
    if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($dest))) { throw 'La carpeta de salida no existe.' }
    if (Test-Path -LiteralPath $dest) { throw 'El destino ya existe. Elige un nombre nuevo; no se sobrescriben archivos.' }
    $names = @{}
    $boots = 0
    foreach ($entry in $Plan) {
        if ($entry.Index -lt 1) { throw 'Indice de origen invalido.' }
        if ([string]::IsNullOrWhiteSpace($entry.Name) -or $entry.Name -match '[\x00-\x1F]') { throw 'Todos los indices necesitan un nombre valido, sin saltos de linea.' }
        if ($names.ContainsKey($entry.Name)) { throw "Nombre repetido en el resultado: '$($entry.Name)'. Edita la celda Nombre de salida." }
        $names[$entry.Name] = $true
        if ($entry.Boot) { $boots++ }
        $source = Get-Item -LiteralPath $entry.Source -Force -ErrorAction Stop
        if ($source.PSIsContainer -or $source.Extension -notin @('.wim', '.esd')) { throw 'Solo se admiten fuentes WIM y ESD.' }
        if ($source.FullName -ieq $dest) { throw 'El destino no puede ser una fuente.' }
        if ($source.Length -ne $entry.SourceLength -or $source.LastWriteTimeUtc.Ticks -ne $entry.SourceTicks) {
            throw "La fuente cambio desde que se leyo: $($entry.Source). Quita sus indices y vuelve a agregar la fuente."
        }
    }
    if ($boots -gt 1) { throw 'Solo un indice puede marcarse como arranque WinPE.' }
    return $dest
}

function Export-AIOIndexPlan {
    param([object[]]$Plan, [string]$Destination, [string]$Engine,
          [ValidateSet('LZX','XPRESS','none')][string]$Compression = 'LZX', [hashtable]$State)
    $dest = Assert-AIOIndexPlan $Plan $Destination
    Assert-AIOIndexNotCancelled $State
    $sources = @($Plan | Select-Object -ExpandProperty Source -Unique)
    # Consultar montajes externos a esta instancia antes de bloquear las fuentes.
    if ($env:OS -eq 'Windows_NT') {
        $mounted = @(Get-WindowsImage -Mounted -ErrorAction Stop)
        foreach ($mount in $mounted) {
            if ($mount.ImagePath -and $sources -icontains [IO.Path]::GetFullPath($mount.ImagePath)) {
                throw "La fuente esta montada: $($mount.ImagePath). Guarda y desmonta antes de integrar."
            }
        }
    }
    $pending = Join-Path ([IO.Path]::GetDirectoryName($dest)) ('.aio-indices-' + [guid]::NewGuid().ToString('N') + '.wim')
    $log = $dest + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.log'
    $locks = New-Object 'Collections.Generic.List[IDisposable]'
    try {
        $State.LogPath = $log
        Write-AIOIndexLog $log 'Inicio de integracion. Las fuentes se abren solo para lectura.'
        foreach ($source in $sources) {
            $locks.Add([IO.File]::Open($source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read))
        }
        # Revalidar tras adquirir los bloqueos para cerrar la ventana de cambios externos.
        [void](Assert-AIOIndexPlan $Plan $dest)
        $catalogs = @{}
        foreach ($source in $sources) {
            $State.Status = 'Validando fuente: ' + [IO.Path]::GetFileName($source)
            $catalogs[$source] = @(Read-AIOIndexCatalog $source $Engine $State $log)
        }
        foreach ($entry in $Plan) {
            $original = @($catalogs[$entry.Source] | Where-Object { $_.Index -eq $entry.Index })
            if ($original.Count -ne 1 -or $original[0].Name -cne $entry.OriginalName) { throw "El indice $($entry.Index) ya no coincide con la fuente: $($entry.Source)." }
        }
        $position = 0
        foreach ($entry in $Plan) {
            Assert-AIOIndexNotCancelled $State
            $position++
            $State.Status = "Exportando $position de $($Plan.Count): $($entry.Name)"
            $State.Progress = [int](80 * ($position - 1) / $Plan.Count)
            $argsList = @('export', "--compress=$Compression", '--check')
            if ($entry.Boot) { $argsList += '--boot' }
            $argsList += @('--', $entry.Source, [string]$entry.Index, $pending, $entry.Name)
            Invoke-AIOIndexNative $Engine $argsList $State $log
        }
        $State.Progress = 85
        $State.Status = 'Verificando todos los datos del WIM resultante...'
        Invoke-AIOIndexNative $Engine @('verify', $pending) $State $log
        $result = @(Read-AIOIndexCatalog $pending $Engine $State $log)
        if ($result.Count -ne $Plan.Count) { throw 'La cantidad de indices resultantes no coincide con el plan.' }
        for ($i = 0; $i -lt $Plan.Count; $i++) {
            $expected = $Plan[$i]; $actual = $result[$i]
            if ($actual.Index -ne ($i + 1) -or $actual.Name -cne $expected.Name -or
                $actual.Description -cne $expected.Description -or $actual.Flags -cne $expected.Flags -or
                $actual.Architecture -ne $expected.Architecture -or $actual.Edition -cne $expected.Edition -or
                $actual.ProductType -cne $expected.ProductType -or $actual.InstallationType -cne $expected.InstallationType -or
                $actual.Build -ne $expected.Build -or $actual.Bytes -ne $expected.Bytes) {
                throw "La verificacion de orden/metadatos fallo en el indice $($i + 1)."
            }
        }
        Assert-AIOIndexNotCancelled $State
        Write-AIOIndexLog $log 'Verificacion correcta. Publicando el archivo de salida.'
        # File.Move no reemplaza un archivo aparecido durante el trabajo. Mismo volumen.
        [IO.File]::Move($pending, $dest)
        $State.Progress = 100
        $State.Status = 'WIM creado y verificado.'
        [pscustomobject]@{ Destination = $dest; Count = $Plan.Count; LogPath = $log }
    } finally {
        foreach ($handle in $locks) { $handle.Dispose() }
        if ([IO.File]::Exists($pending)) { [IO.File]::Delete($pending) }
    }
}

function Invoke-AIOIndexWork {
    param([string]$Engine, [string]$Action, [object]$Payload, [hashtable]$State)
    $ErrorActionPreference = 'Stop'
    try {
        if ($Action -eq 'Load') {
            $images = New-Object Collections.ArrayList
            $failures = New-Object Collections.ArrayList
            foreach ($path in $Payload.Paths) {
                Assert-AIOIndexNotCancelled $State
                $State.Status = 'Leyendo: ' + [IO.Path]::GetFileName($path)
                try { foreach ($item in @(Read-AIOIndexCatalog $path $Engine $State)) { [void]$images.Add($item) } }
                catch [OperationCanceledException] { throw }
                catch { [void]$failures.Add($path + ': ' + $_.Exception.Message) }
            }
            [pscustomobject]@{ Success = $true; Action = $Action; Images = $images.ToArray(); Failures = $failures.ToArray() }
        } else {
            $result = Export-AIOIndexPlan -Plan $Payload.Plan -Destination $Payload.Destination -Engine $Engine -Compression $Payload.Compression -State $State
            [pscustomobject]@{ Success = $true; Action = $Action; Result = $result }
        }
    } catch {
        [pscustomobject]@{ Success = $false; Cancelled = ($_.Exception -is [OperationCanceledException]); Message = $_.Exception.Message; LogPath = $State.LogPath }
    }
}

function Show-AIOIndexIntegrator {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    try { $engine = Find-AIOIndexWimlib } catch { [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Integrar indices'); return }
    $modulePath = Join-Path $PSScriptRoot 'Modulo-IntegrarIndices.ps1'
    $ui = @{
        Catalog = New-Object Collections.ArrayList
        Plan = New-Object Collections.ArrayList
        Worker = $null; Handle = $null; Action = ''; State = $null; Started = $null
        ProgressValue = 0; ProgressBusy = $false; Animation = 0
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Integrar y ordenar indices | AdminImagenOffline'
    $form.Size = New-Object Drawing.Size(1220, 820)
    $form.MinimumSize = New-Object Drawing.Size(960, 700)
    $form.StartPosition = 'CenterScreen'
    $form.Font = New-Object Drawing.Font('Segoe UI', 9)
    $form.AutoScaleMode = 'Dpi'
    # Paleta compartida visualmente con DeployVHD, Drivers y BootSetup.
    $form.BackColor = [Drawing.Color]::FromArgb(30, 30, 30)
    $form.ForeColor = [Drawing.Color]::White

    $root = New-Object Windows.Forms.TableLayoutPanel
    $root.Dock = 'Fill'; $root.Padding = New-Object Windows.Forms.Padding(16)
    $root.ColumnCount = 1; $root.RowCount = 7
    foreach ($height in @(56, 44, -1, 78, 44, 52, 100)) {
        if ($height -eq -1) { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))) }
        else { [void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
    }
    $form.Controls.Add($root)
    $intro = New-Object Windows.Forms.Label
    $intro.Text = "Integra indices de varias fuentes WIM / ESD en un nuevo WIM. Orden libre; agrupar es opcional.`r`nEl orden de la tabla derecha sera la numeracion final: 1, 2, 3... Las fuentes se conservan."
    $intro.Dock = 'Fill'; $intro.AutoSize = $true
    $intro.ForeColor = [Drawing.Color]::Silver
    $root.Controls.Add($intro, 0, 0)

    function New-AIOIndexButton([string]$Text, [int]$Width = 150) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $Text; $b.Width = $Width; $b.Height = 32
        $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
        $b.BackColor = [Drawing.Color]::FromArgb(60, 60, 60)
        $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(85, 85, 85)
        $b.FlatAppearance.BorderSize = 1
        $b.Margin = New-Object Windows.Forms.Padding(0, 0, 8, 0)
        return $b
    }
    $sourceBar = New-Object Windows.Forms.FlowLayoutPanel
    $sourceBar.Dock = 'Fill'; $sourceBar.WrapContents = $false
    $addSource = New-AIOIndexButton 'Agregar fuentes...' 155
    $addSource.BackColor = [Drawing.Color]::RoyalBlue
    $clearSources = New-AIOIndexButton 'Limpiar fuentes' 135
    $sourceBar.Controls.AddRange(@($addSource, $clearSources))
    $root.Controls.Add($sourceBar, 0, 1)

    $columns = New-Object Windows.Forms.TableLayoutPanel
    $columns.Dock = 'Fill'; $columns.ColumnCount = 2; $columns.RowCount = 1
    [void]$columns.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 48)))
    [void]$columns.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 52)))
    $root.Controls.Add($columns, 0, 2)
    $sourceGroup = New-Object Windows.Forms.GroupBox
    $sourceGroup.ForeColor = [Drawing.Color]::Cyan
    $sourceGroup.Text = '1. Indices disponibles (Ctrl / Shift para seleccionar varios)'; $sourceGroup.Dock = 'Fill'
    $planGroup = New-Object Windows.Forms.GroupBox
    $planGroup.ForeColor = [Drawing.Color]::Orange
    $planGroup.Text = '2. Orden final (Nombre de salida editable)'; $planGroup.Dock = 'Fill'
    $columns.Controls.Add($sourceGroup, 0, 0); $columns.Controls.Add($planGroup, 1, 0)

    function New-AIOIndexGrid {
        $grid = New-Object Windows.Forms.DataGridView
        $grid.Dock = 'Fill'; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
        $grid.AllowUserToOrderColumns = $false; $grid.RowHeadersVisible = $false
        $grid.AutoSizeColumnsMode = 'Fill'; $grid.SelectionMode = 'FullRowSelect'
        $grid.BackgroundColor = [Drawing.Color]::FromArgb(45, 45, 48)
        $grid.ForeColor = [Drawing.Color]::White; $grid.BorderStyle = 'None'
        $grid.GridColor = [Drawing.Color]::FromArgb(65, 65, 68)
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersBorderStyle = 'Single'
        $grid.DefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(45, 45, 48)
        $grid.DefaultCellStyle.ForeColor = [Drawing.Color]::White
        $grid.DefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(0, 92, 155)
        $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(38, 38, 41)
        $grid.ColumnHeadersDefaultCellStyle.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
        $grid.ColumnHeadersDefaultCellStyle.ForeColor = [Drawing.Color]::Silver
        $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = [Drawing.Color]::FromArgb(50, 50, 50)
        $grid.ColumnHeadersDefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
        $grid.RowTemplate.Height = 28; $grid.AllowUserToResizeRows = $false
        return $grid
    }
    function Add-AIOIndexColumn($Grid, [string]$Name, [string]$Title, [int]$Width, [bool]$Editable = $false) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.Name = $Name; $col.HeaderText = $Title; $col.FillWeight = $Width
        $col.ReadOnly = -not $Editable; $col.SortMode = 'NotSortable'
        [void]$Grid.Columns.Add($col)
    }
    $sourceGrid = New-AIOIndexGrid
    $sourceGrid.ReadOnly = $true; $sourceGrid.MultiSelect = $true
    Add-AIOIndexColumn $sourceGrid 'Source' 'Fuente' 90
    Add-AIOIndexColumn $sourceGrid 'Index' 'Indice' 40
    Add-AIOIndexColumn $sourceGrid 'Name' 'Nombre' 170
    Add-AIOIndexColumn $sourceGrid 'Arch' 'Arq.' 45
    Add-AIOIndexColumn $sourceGrid 'Build' 'Build' 55
    $sourceGroup.Controls.Add($sourceGrid)
    $planGrid = New-AIOIndexGrid
    $planGrid.MultiSelect = $false
    Add-AIOIndexColumn $planGrid 'Order' 'Orden' 40
    Add-AIOIndexColumn $planGrid 'Name' 'Nombre de salida' 165 $true
    Add-AIOIndexColumn $planGrid 'Source' 'Fuente / indice' 120
    Add-AIOIndexColumn $planGrid 'Arch' 'Arq.' 45
    $bootColumn = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $bootColumn.Name = 'Boot'; $bootColumn.HeaderText = 'WinPE'; $bootColumn.FillWeight = 45
    $bootColumn.FlatStyle = 'Flat'
    $bootColumn.SortMode = 'NotSortable'; [void]$planGrid.Columns.Add($bootColumn)
    $planGroup.Controls.Add($planGrid)
    $planGrid.Add_EditingControlShowing({ param($sender, $e)
        $e.Control.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
        $e.Control.ForeColor = [Drawing.Color]::White
    })

    $actions = New-Object Windows.Forms.FlowLayoutPanel
    $actions.Dock = 'Fill'; $actions.Padding = New-Object Windows.Forms.Padding(0, 10, 0, 0)
    $addSelected = New-AIOIndexButton 'Agregar seleccion >' 160
    $addAll = New-AIOIndexButton 'Agregar todos >' 140
    $up = New-AIOIndexButton 'Subir' 80; $down = New-AIOIndexButton 'Bajar' 80
    $groupArchitecture = New-AIOIndexButton 'Agrupar por arquitectura' 195
    $remove = New-AIOIndexButton 'Quitar' 85; $clearPlan = New-AIOIndexButton 'Vaciar orden' 115
    $actions.Controls.AddRange(@($addSelected, $addAll, $up, $down, $groupArchitecture, $remove, $clearPlan))
    $root.Controls.Add($actions, 0, 3)

    $outputRow = New-Object Windows.Forms.TableLayoutPanel
    $outputRow.Dock = 'Fill'; $outputRow.ColumnCount = 3; $outputRow.RowCount = 1
    [void]$outputRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 65)))
    [void]$outputRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$outputRow.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 130)))
    $outputLabel = New-Object Windows.Forms.Label
    $outputLabel.Text = 'Salida:'; $outputLabel.Dock = 'Fill'
    $outputLabel.ForeColor = [Drawing.Color]::Silver
    $destination = New-Object Windows.Forms.TextBox
    $destination.Dock = 'Fill'
    $destination.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
    $destination.ForeColor = [Drawing.Color]::White
    $destination.BorderStyle = 'FixedSingle'
    $browse = New-AIOIndexButton 'Examinar...' 120
    $outputRow.Controls.Add($outputLabel, 0, 0); $outputRow.Controls.Add($destination, 1, 0); $outputRow.Controls.Add($browse, 2, 0)
    $root.Controls.Add($outputRow, 0, 4)

    $footer = New-Object Windows.Forms.FlowLayoutPanel
    $footer.Dock = 'Fill'; $footer.WrapContents = $false
    $compression = New-Object Windows.Forms.ComboBox
    $compression.DropDownStyle = 'DropDownList'; $compression.Width = 190
    $compression.FlatStyle = 'Flat'
    $compression.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
    $compression.ForeColor = [Drawing.Color]::White
    [void]$compression.Items.AddRange(@('LZX - maxima compresion', 'XPRESS - mas rapido', 'Sin compresion'))
    $compression.SelectedIndex = 0
    $build = New-AIOIndexButton 'Crear WIM' 125
    $build.BackColor = [Drawing.Color]::SeaGreen
    $cancel = New-AIOIndexButton 'Cancelar proceso' 145; $cancel.Enabled = $false
    $cancel.BackColor = [Drawing.Color]::DarkOrange
    $cancel.ForeColor = [Drawing.Color]::Black
    $close = New-AIOIndexButton 'Cerrar' 85
    $footer.Controls.AddRange(@($compression, $build, $cancel, $close))
    $root.Controls.Add($footer, 0, 5)
    $statusBox = New-Object Windows.Forms.TableLayoutPanel
    $statusBox.Dock = 'Fill'; $statusBox.RowCount = 4; $statusBox.ColumnCount = 1
    foreach ($height in @(32, 18, 32, 18)) {
        [void]$statusBox.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', $height)))
    }
    $status = New-Object Windows.Forms.Label
    $status.Text = 'Agrega las fuentes para comenzar.'; $status.Dock = 'Fill'; $status.AutoEllipsis = $true
    $status.ForeColor = [Drawing.Color]::Cyan
    # Igual que DeployVHD: paneles propios para que el progreso respete el tema oscuro.
    $progress = New-Object Windows.Forms.Panel
    $progress.Dock = 'Fill'; $progress.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
    $progress.AccessibleName = 'Progreso de integracion'
    $progressFill = New-Object Windows.Forms.Panel
    $progressFill.BackColor = [Drawing.Color]::LightGreen
    $progressFill.Width = 0; $progress.Controls.Add($progressFill)
    $renderProgress = {
        $width = $progress.ClientSize.Width
        if ($width -le 0) { return }
        $progressFill.Height = $progress.ClientSize.Height
        if ($ui.ProgressBusy) {
            $progressFill.Width = [Math]::Min($width, [Math]::Max(30, [int]($width / 5)))
            $travel = [Math]::Max(1, $width - $progressFill.Width)
            $progressFill.Left = [int](($ui.Animation * 15) % $travel)
            $progress.AccessibleDescription = 'Lectura de imagen en curso'
        } else {
            $progressFill.Left = 0
            $progressFill.Width = [int]($width * [Math]::Min(100, [Math]::Max(0, $ui.ProgressValue)) / 100)
            $progress.AccessibleDescription = [string]$ui.ProgressValue + ' por ciento de las etapas'
        }
    }
    $progress.Add_Resize({ & $renderProgress })
    $nativeStatus = New-Object Windows.Forms.Label
    $nativeStatus.Text = 'Progreso del motor: en espera.'
    $nativeStatus.Dock = 'Fill'; $nativeStatus.AutoEllipsis = $true
    $nativeStatus.ForeColor = [Drawing.Color]::Silver
    $nativeProgress = New-Object Windows.Forms.Panel
    $nativeProgress.Dock = 'Fill'; $nativeProgress.BackColor = [Drawing.Color]::FromArgb(50, 50, 50)
    $nativeProgress.AccessibleName = 'Porcentaje de la fase actual del motor'
    $nativeFill = New-Object Windows.Forms.Panel
    $nativeFill.BackColor = [Drawing.Color]::DodgerBlue
    $nativeFill.Width = 0; $nativeProgress.Controls.Add($nativeFill)
    $renderNativeProgress = {
        $width = $nativeProgress.ClientSize.Width
        if ($width -le 0) { return }
        $nativeFill.Height = $nativeProgress.ClientSize.Height
        $value = if ($ui.State) { [double]$ui.State.NativePercent } else { -1.0 }
        if ($value -lt 0 -and $ui.Worker) {
            $nativeFill.Width = [Math]::Min($width, [Math]::Max(30, [int]($width / 5)))
            $travel = [Math]::Max(1, $width - $nativeFill.Width)
            $nativeFill.Left = [int](($ui.Animation * 15) % $travel)
            $nativeProgress.AccessibleDescription = 'Esperando porcentaje del motor'
        } else {
            $nativeFill.Left = 0
            # Como DeployVHD: el 100% informado no confirma exito hasta comprobar ExitCode.
            $maximum = if ($ui.State -and $ui.State.NativeSucceeded) {100.0} else {99.9}
            $display = [Math]::Max(0, [Math]::Min($maximum, $value))
            $nativeFill.Width = [int][Math]::Floor($width * $display / 100)
            $nativeProgress.AccessibleDescription = $display.ToString('0.0') + ' por ciento'
        }
    }
    $nativeProgress.Add_Resize({ & $renderNativeProgress })
    $statusBox.Controls.Add($status, 0, 0); $statusBox.Controls.Add($progress, 0, 1)
    $statusBox.Controls.Add($nativeStatus, 0, 2); $statusBox.Controls.Add($nativeProgress, 0, 3)
    $root.Controls.Add($statusBox, 0, 6)
    $tips = New-Object Windows.Forms.ToolTip
    $tips.SetToolTip($planGrid, 'Edita el nombre con doble clic; la etiqueta de arquitectura se conserva automaticamente. WinPE marca UN indice de arranque de boot.wim; dejalo sin marcar para install.wim.')
    $tips.SetToolTip($addSource, 'Selecciona varios .wim o .esd con Ctrl. Para ISO: extrae primero sources\install.wim o install.esd. Para SWM: convierte primero a WIM.')
    $tips.SetToolTip($up, 'Sube una posicion el indice seleccionado. Alt + Flecha arriba.')
    $tips.SetToolTip($down, 'Baja una posicion el indice seleccionado. Alt + Flecha abajo.')
    $tips.SetToolTip($groupArchitecture, 'Opcional: agrupa x86, x64 y ARM64; otras arquitecturas quedan al final. Conserva el orden dentro de cada grupo. Despues puedes seguir usando Subir/Bajar. No cambia la compatibilidad de arranque.')
    $tips.SetToolTip($progress, 'Avance general por indices y verificacion final. Solo termina cuando el WIM esta verificado y publicado.')
    $tips.SetToolTip($nativeProgress, 'Porcentaje real de la fase actual. Se reinicia al pasar de comprobar integridad a exportar datos o a otra fase.')
    $tips.SetToolTip($clearSources, 'Vacia la lista de fuentes disponibles. El orden final conserva sus referencias.')
    $editableControls = @($addSource, $clearSources, $sourceGrid, $planGrid, $addSelected, $addAll, $up, $down, $groupArchitecture, $remove, $clearPlan, $destination, $browse, $compression, $build)

    $syncPlan = {
        [void]$planGrid.EndEdit()
        for ($i = 0; $i -lt $ui.Plan.Count; $i++) {
            $ui.Plan[$i].Name = Format-AIOIndexOutputName ([string]$planGrid.Rows[$i].Cells['Name'].Value) $ui.Plan[$i].Architecture
            $planGrid.Rows[$i].Cells['Name'].Value = $ui.Plan[$i].Name
            $ui.Plan[$i].Boot = [bool]$planGrid.Rows[$i].Cells['Boot'].Value
        }
    }
    $refreshPlan = {
        param([int]$Selected = -1)
        $planGrid.Rows.Clear()
        for ($i = 0; $i -lt $ui.Plan.Count; $i++) {
            $entry = $ui.Plan[$i]
            $row = $planGrid.Rows.Add([object[]]@(($i + 1), $entry.Name, ('{0} / {1}' -f [IO.Path]::GetFileName($entry.Source), $entry.Index), $entry.Architecture, $entry.Boot))
            $planGrid.Rows[$row].Cells['Source'].ToolTipText = $entry.Source
        }
        $planGrid.ClearSelection()
        if ($Selected -ge 0 -and $Selected -lt $planGrid.Rows.Count) {
            $planGrid.CurrentCell = $planGrid.Rows[$Selected].Cells['Name']
            $planGrid.Rows[$Selected].Selected = $true
        }
        $planGroup.Text = '2. Orden final: ' + $ui.Plan.Count + ' indices (Nombre de salida editable)'
    }
    $refreshSources = {
        $sourceGrid.Rows.Clear()
        foreach ($entry in $ui.Catalog) {
            $row = $sourceGrid.Rows.Add([object[]]@([IO.Path]::GetFileName($entry.Source), $entry.Index, $entry.Name, $entry.Architecture, $entry.Build))
            $sourceGrid.Rows[$row].Tag = $entry
            $sourceGrid.Rows[$row].Cells['Source'].ToolTipText = $entry.Source
        }
        $sourceGrid.ClearSelection()
    }
    $startWork = {
        param([string]$Action, [object]$Payload)
        $ui.State = [hashtable]::Synchronized(@{ Cancel = $false; Progress = 0; Status = 'Iniciando...'; LogPath = ''; NativePercent = -1.0; NativePhase = ''; NativePhaseKey = ''; NativeActive = $false; NativeSucceeded = $false })
        $ui.Action = $Action; $ui.Started = [Diagnostics.Stopwatch]::StartNew()
        $ui.Worker = [PowerShell]::Create()
        $workerScript = {
            param($ModulePath, $Engine, $Action, $Payload, $State)
            $ErrorActionPreference = 'Stop'
            . $ModulePath
            Invoke-AIOIndexWork $Engine $Action $Payload $State
        }
        [void]$ui.Worker.AddScript($workerScript.ToString()).AddArgument($modulePath).AddArgument($engine).AddArgument($Action).AddArgument($Payload).AddArgument($ui.State)
        try { $ui.Handle = $ui.Worker.BeginInvoke() }
        catch { $ui.Worker.Dispose(); $ui.Worker = $null; throw }
        foreach ($control in $editableControls) { $control.Enabled = $false }
        $cancel.Enabled = $true
        $status.ForeColor = [Drawing.Color]::Yellow
        $nativeStatus.ForeColor = [Drawing.Color]::Silver
        $nativeStatus.Text = 'Progreso del motor: esperando porcentaje...'
        $ui.ProgressValue = 0; $ui.ProgressBusy = $true; $ui.Animation = 0
        & $renderProgress; & $renderNativeProgress
    }
    $showError = { param([string]$Message) [void][Windows.Forms.MessageBox]::Show($form, $Message, 'Integrar indices', 'OK', 'Warning') }
    $timer = New-Object Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({
        if (-not $ui.Worker) { return }
        $status.Text = $ui.State.Status + ' | General: ' + [string]$ui.State.Progress + '% | ' + $ui.Started.Elapsed.ToString('hh\:mm\:ss')
        $ui.ProgressBusy = ($ui.Action -eq 'Load')
        $ui.ProgressValue = [int]$ui.State.Progress; $ui.Animation++
        & $renderProgress; & $renderNativeProgress
        if ([double]$ui.State.NativePercent -ge 0) {
            $maximum = if ($ui.State.NativeSucceeded) {100.0} else {99.9}
            $percent = [Math]::Min($maximum, [double]$ui.State.NativePercent)
            $nativeStatus.Text = $ui.State.NativePhase + ': ' + $percent.ToString('0.0') + '%'
            if ($ui.State.NativePercent -eq 100 -and $ui.State.NativeActive) { $nativeStatus.Text += ' (finalizando fase)' }
        } else {
            $nativeStatus.Text = $ui.State.NativePhase + ': esperando porcentaje...'
        }
        if (-not $ui.Handle.IsCompleted) { return }
        $worker = $ui.Worker
        $timer.Stop()
        try {
            $answers = @($worker.EndInvoke($ui.Handle))
            if ($worker.HadErrors -or $answers.Count -ne 1) { throw ('No se pudo completar el proceso. ' + ($worker.Streams.Error -join "`r`n")) }
            $answer = $answers[0]
            if (-not $answer.Success) {
                $status.Text = if ($answer.Cancelled) { 'Operacion cancelada. Fuentes conservadas.' } else { 'No se creo el WIM. Revisa el mensaje de error.' }
                $status.ForeColor = if ($answer.Cancelled) { [Drawing.Color]::Gold } else { [Drawing.Color]::Salmon }
                $nativeStatus.ForeColor = $status.ForeColor
                $nativeStatus.Text = if ($answer.Cancelled) { 'Proceso cancelado.' } else { 'Proceso detenido por error.' }
                $detail = $answer.Message
                if ($answer.LogPath) { $detail += "`r`n`r`nRegistro: " + $answer.LogPath }
                & $showError $detail
            } elseif ($answer.Action -eq 'Load') {
                # Renovar todas las filas de cada fuente leida; puede haber perdido indices.
                # El plan conserva su instantanea y exige volver a agregar una fuente modificada.
                $loadedSources = @($answer.Images | Select-Object -ExpandProperty Source -Unique)
                for ($i = $ui.Catalog.Count - 1; $i -ge 0; $i--) {
                    if ($loadedSources -icontains $ui.Catalog[$i].Source) { $ui.Catalog.RemoveAt($i) }
                }
                foreach ($entry in $answer.Images) { [void]$ui.Catalog.Add($entry) }
                & $refreshSources
                $nativeStatus.Text = 'Lectura de fuentes finalizada.'
                $status.ForeColor = if ($answer.Failures.Count) { [Drawing.Color]::Gold } else { [Drawing.Color]::LightGreen }
                $status.Text = $ui.Catalog.Count.ToString() + ' indices disponibles. Selecciona los que quieras integrar.'
                if ($answer.Failures.Count) { & $showError ('No se pudieron leer estas fuentes:' + "`r`n`r`n" + ($answer.Failures -join "`r`n`r`n")) }
            } else {
                $ui.ProgressValue = 100
                $ui.State.NativePercent = 100; $ui.State.NativeSucceeded = $true
                $nativeStatus.Text = 'WIM verificado y publicado: 100%.'
                $nativeStatus.ForeColor = [Drawing.Color]::LightGreen
                $status.ForeColor = [Drawing.Color]::LightGreen
                $status.Text = 'WIM creado: ' + $answer.Result.Destination
                [void][Windows.Forms.MessageBox]::Show($form, ("WIM creado y verificado con {0} indices, en el orden indicado.`r`n`r`n{1}`r`n`r`nRegistro: {2}" -f $answer.Result.Count, $answer.Result.Destination, $answer.Result.LogPath), 'Integracion completada', 'OK', 'Information')
            }
        } catch { $status.Text = 'Error en el proceso.'; $status.ForeColor = [Drawing.Color]::Salmon; & $showError $_.Exception.Message }
        finally {
            $ui.Worker = $null; $ui.Handle = $null; $worker.Dispose(); $ui.Started.Stop()
            foreach ($control in $editableControls) { $control.Enabled = $true }
            $cancel.Enabled = $false; $ui.ProgressBusy = $false
            & $renderProgress; & $renderNativeProgress
            $timer.Start()
        }
    })
    $addSource.Add_Click({
        $dialog = New-Object Windows.Forms.OpenFileDialog
        $dialog.Title = 'Selecciona una o varias fuentes'; $dialog.Multiselect = $true
        $dialog.Filter = 'Imagenes WIM y ESD|*.wim;*.esd'; $dialog.CheckFileExists = $true
        try {
            if ($dialog.ShowDialog($form) -eq 'OK') { & $startWork 'Load' @{ Paths = @($dialog.FileNames) } }
        } catch { & $showError $_.Exception.Message } finally { $dialog.Dispose() }
    })
    $clearSources.Add_Click({ $ui.Catalog.Clear(); & $refreshSources })
    $addEntries = {
        param([bool]$All)
        & $syncPlan
        $rows = if ($All) { @($sourceGrid.Rows) } else { @($sourceGrid.SelectedRows | Sort-Object Index) }
        foreach ($row in $rows) {
            $entry = $row.Tag
            # Evitar duplicados accidentales de la misma fuente e indice.
            $exists = @($ui.Plan | Where-Object { $_.Source -ieq $entry.Source -and $_.Index -eq $entry.Index }).Count -gt 0
            if (-not $exists) { [void]$ui.Plan.Add((New-AIOIndexPlanEntry $entry @($ui.Plan.ToArray()))) }
        }
        & $refreshPlan ($ui.Plan.Count - 1)
    }
    $addSelected.Add_Click({ & $addEntries $false })
    $addAll.Add_Click({ & $addEntries $true })
    $sourceGrid.Add_CellDoubleClick({ param($sender, $e) if ($e.RowIndex -ge 0) { & $addEntries $false } })
    $moveSelection = {
        param([int]$Direction)
        & $syncPlan
        if ($planGrid.SelectedRows.Count) {
            $selected = Move-AIOIndexPlanEntry $ui.Plan $planGrid.SelectedRows[0].Index $Direction
            & $refreshPlan $selected
        }
    }
    $up.Add_Click({ & $moveSelection -1 }); $down.Add_Click({ & $moveSelection 1 })
    $groupArchitecture.Add_Click({
        & $syncPlan
        $selected = if ($planGrid.SelectedRows.Count) { $planGrid.SelectedRows[0].Index } else { -1 }
        $selected = Group-AIOIndexPlanByArchitecture $ui.Plan $selected
        & $refreshPlan $selected
        $status.Text = 'Agrupacion aplicada: x86, x64, ARM64 y otras. El orden sigue siendo editable.'
    })
    $planGrid.Add_CellEndEdit({ param($sender, $e)
        if ($e.RowIndex -ge 0 -and $e.RowIndex -lt $ui.Plan.Count -and $e.ColumnIndex -eq $planGrid.Columns['Name'].Index) {
            $cell = $planGrid.Rows[$e.RowIndex].Cells['Name']
            $cell.Value = Format-AIOIndexOutputName ([string]$cell.Value) $ui.Plan[$e.RowIndex].Architecture
            $ui.Plan[$e.RowIndex].Name = [string]$cell.Value
        }
    })
    $planGrid.Add_KeyDown({ param($sender, $e)
        if ($e.Alt -and $e.KeyCode -eq 'Up') { & $moveSelection -1; $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.Alt -and $e.KeyCode -eq 'Down') { & $moveSelection 1; $e.Handled = $true; $e.SuppressKeyPress = $true }
    })
    $planGrid.Add_CurrentCellDirtyStateChanged({
        if ($planGrid.IsCurrentCellDirty -and $planGrid.CurrentCell.ColumnIndex -eq 4) { [void]$planGrid.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) }
    })
    $planGrid.Add_CellValueChanged({ param($sender, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 4 -and [bool]$planGrid.Rows[$e.RowIndex].Cells['Boot'].Value) {
            foreach ($row in $planGrid.Rows) { if ($row.Index -ne $e.RowIndex) { $row.Cells['Boot'].Value = $false } }
        }
    })
    $remove.Add_Click({
        & $syncPlan
        if ($planGrid.SelectedRows.Count) {
            $index = $planGrid.SelectedRows[0].Index
            $ui.Plan.RemoveAt($index); & $refreshPlan ([Math]::Min($index, $ui.Plan.Count - 1))
        }
    })
    $clearPlan.Add_Click({ $ui.Plan.Clear(); & $refreshPlan })
    $browse.Add_Click({
        $dialog = New-Object Windows.Forms.SaveFileDialog
        $dialog.Filter = 'Imagen WIM|*.wim'; $dialog.DefaultExt = 'wim'; $dialog.AddExtension = $true
        $dialog.FileName = 'install_integrado.wim'; $dialog.Title = 'Crear un nuevo WIM'
        try { if ($dialog.ShowDialog($form) -eq 'OK') { $destination.Text = $dialog.FileName } }
        finally { $dialog.Dispose() }
    })
    $build.Add_Click({
        try {
            & $syncPlan
            $plan = @($ui.Plan.ToArray())
            $dest = Assert-AIOIndexPlan $plan $destination.Text.Trim()
            if ($Script:IMAGE_MOUNTED -eq 1 -and @($plan | Where-Object { $_.Source -ieq $Script:WIM_FILE_PATH }).Count) {
                throw 'Una fuente esta montada en la aplicacion. Guarda y desmonta antes de integrar.'
            }
            $summary = "Se creara un WIM con $($plan.Count) indices, en el orden de la tabla derecha.`r`n`r`n$dest`r`n`r`nLas fuentes se conservaran. Se necesita espacio libre para el WIM completo."
            $warnings = @(Get-AIOIndexCompatibilityWarnings $plan)
            foreach ($warning in $warnings) { $summary += "`r`n`r`n" + $warning.Message }
            $summary += "`r`n`r`nContinuar?"
            $icon = if ($warnings.Count) { 'Warning' } else { 'Question' }
            if ([Windows.Forms.MessageBox]::Show($form, $summary, 'Crear WIM integrado', 'YesNo', $icon, 'Button2') -ne 'Yes') { return }
            & $startWork 'Build' @{ Plan = $plan; Destination = $dest; Compression = @('LZX','XPRESS','none')[$compression.SelectedIndex] }
        } catch { & $showError $_.Exception.Message }
    })
    $cancel.Add_Click({ if ($ui.Worker) { $ui.State.Cancel = $true; $ui.State.Status = if ($ui.Action -eq 'Load') { 'Cancelando lectura de fuentes...' } else { 'Cancelando y retirando el temporal...' }; $cancel.Enabled = $false } })
    $close.Add_Click({ $form.Close() })
    $form.Add_FormClosing({ param($sender, $e)
        if ($ui.Worker) { $e.Cancel = $true; & $showError 'Hay una operacion en curso. Usa Cancelar proceso y espera a que termine antes de cerrar.' }
    })
    try { $timer.Start(); [void]$form.ShowDialog() }
    finally { $timer.Stop(); $timer.Dispose(); $tips.Dispose(); $form.Dispose() }
}
