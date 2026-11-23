# =================================================================
# Estilo compartido de los controles graficos de AdminImagenOffline.
# Extension de AdminImagenOffline. Copyright (C) 2026 SOFTMAXTER.
# Distribuido bajo la licencia del proyecto (ver LICENSE).
# El nucleo carga este archivo junto con los demas Modulo-*.ps1.
# =================================================================

function Set-AIOTabControlStyle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Forms.TabControl]$TabControl
    )

    # No registrar los eventos dos veces ni ocupar Tag (reservado al modulo).
    if ($null -ne $TabControl.PSObject.Properties['AIOTabStyleApplied']) { return }

    $TabControl.DrawMode = [System.Windows.Forms.TabDrawMode]::OwnerDrawFixed
    # Mantener anchos automaticos; dejar espacio para la fuente en negrita.
    $TabControl.Padding = New-Object System.Drawing.Point(14, 5)

    # Los eventos usan su emisor, sin depender de variables locales del helper.
    $TabControl.Add_DrawItem({
        param($sender, $e)

        if ($e.Index -lt 0 -or $e.Index -ge $sender.TabPages.Count) { return }
        $bounds = $e.Bounds
        if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return }

        # SelectedIndex conserva el resaltado al pasar el foco al contenido.
        $selected = ($e.Index -eq $sender.SelectedIndex)
        if ([System.Windows.Forms.SystemInformation]::HighContrast) {
            $background = if ($selected) { [System.Drawing.SystemColors]::Highlight } else { [System.Drawing.SystemColors]::Control }
            $foreground = if ($selected) { [System.Drawing.SystemColors]::HighlightText } else { [System.Drawing.SystemColors]::ControlText }
            $accent = $foreground
        } else {
            $background = if ($selected) { [System.Drawing.Color]::FromArgb(0, 90, 158) } else { [System.Drawing.Color]::FromArgb(58, 58, 64) }
            $foreground = if ($selected) { [System.Drawing.Color]::White } else { [System.Drawing.Color]::FromArgb(220, 220, 228) }
            $accent = [System.Drawing.Color]::FromArgb(100, 210, 255)
        }

        $backgroundBrush = $null
        $accentBrush = $null
        $selectedFont = $null
        try {
            $backgroundBrush = New-Object System.Drawing.SolidBrush($background)
            $e.Graphics.FillRectangle($backgroundBrush, $bounds)

            $textFont = $sender.Font
            if ($selected) {
                $selectedFont = New-Object System.Drawing.Font($sender.Font, [System.Drawing.FontStyle]::Bold)
                $textFont = $selectedFont
            }

            # Reservar la misma franja en todas las cabeceras evita mover el texto.
            $accentHeight = [Math]::Max(2, [int][Math]::Round(3 * $e.Graphics.DpiY / 96))
            $textBounds = New-Object System.Drawing.Rectangle(
                ($bounds.X + 4), $bounds.Y,
                ([Math]::Max(1, $bounds.Width - 8)),
                ([Math]::Max(1, $bounds.Height - $accentHeight)))
            $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor
                     [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor
                     [System.Windows.Forms.TextFormatFlags]::SingleLine -bor
                     [System.Windows.Forms.TextFormatFlags]::EndEllipsis -bor
                     [System.Windows.Forms.TextFormatFlags]::NoPrefix
            [System.Windows.Forms.TextRenderer]::DrawText(
                $e.Graphics, $sender.TabPages[$e.Index].Text.Trim(),
                $textFont, $textBounds, $foreground, $flags)

            if ($selected) {
                $accentBrush = New-Object System.Drawing.SolidBrush($accent)
                $e.Graphics.FillRectangle(
                    $accentBrush, $bounds.X, ($bounds.Bottom - $accentHeight),
                    $bounds.Width, $accentHeight)

                # Mantener una indicacion de foco para navegacion con teclado.
                if ($sender.Focused) {
                    $focusBounds = [System.Drawing.Rectangle]::Inflate($bounds, -2, -2)
                    [System.Windows.Forms.ControlPaint]::DrawFocusRectangle(
                        $e.Graphics, $focusBounds, $foreground, $background)
                }
            }
        } finally {
            # DrawItem puede dispararse muchas veces: liberar recursos GDI propios.
            if ($null -ne $selectedFont) { $selectedFont.Dispose() }
            if ($null -ne $accentBrush) { $accentBrush.Dispose() }
            if ($null -ne $backgroundBrush) { $backgroundBrush.Dispose() }
        }
    })

    # Repintar ambas cabeceras al cambiar de pestaña, por raton o por teclado.
    $TabControl.Add_SelectedIndexChanged({ param($sender, $e) $sender.Invalidate() })
    $TabControl.Add_GotFocus({ param($sender, $e) $sender.Invalidate() })
    $TabControl.Add_LostFocus({ param($sender, $e) $sender.Invalidate() })

    Add-Member -InputObject $TabControl -MemberType NoteProperty -Name AIOTabStyleApplied -Value $true
    $TabControl.Invalidate()
}


# =================================================================
# Motor de navegacion interactiva en consola (flechas, Enter, Retroceso).
# =================================================================

function Enable-AIOConsoleVT {
    if ($null -ne $Script:AIOConsoleVTEnabled) { return [bool]$Script:AIOConsoleVTEnabled }
    $enabled = $false
    try {
        if (-not ('AIOConsoleVTNative' -as [type])) {
            Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class AIOConsoleVTNative {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
"@ -ErrorAction Stop
        }
        $handle = [AIOConsoleVTNative]::GetStdHandle(-11)
        if ($handle -ne [IntPtr]::Zero -and $handle -ne ([IntPtr](-1))) {
            [uint32]$mode = 0
            if ([AIOConsoleVTNative]::GetConsoleMode($handle, [ref]$mode)) {
                if (($mode -band 0x0004) -ne 0) {
                    $enabled = $true
                } else {
                    $enabled = [bool][AIOConsoleVTNative]::SetConsoleMode($handle, ($mode -bor 0x0004))
                }
            }
        }
    } catch {
        $enabled = $false
    }
    $Script:AIOConsoleVTEnabled = $enabled
    return $enabled
}

function Show-AIOConsoleMenu {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Items,
        [switch]$AllowBack,
        [string]$BackValue = 'BACK',
        [int]$DefaultIndex = 0,
        [string]$FooterText = '',
        [string]$SeparatorText = '-------------------------------------------------------',
        [switch]$NoSeparator,
        [int]$Columns = 1
    )

    $getStr = {
        param([string]$Key, [string]$Fallback)
        if (Get-Command -Name Get-AIOString -ErrorAction SilentlyContinue) {
            $val = Get-AIOString $Key
            if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne $Key) { return $val }
        }
        return $Fallback
    }

    $winWidth = 80
    try {
        $w = [Console]::WindowWidth
        if ($w -gt 20) { $winWidth = $w }
    } catch { }

    # Normalizar entradas e identificar opciones seleccionables habilitadas.
    $entries = New-Object System.Collections.ArrayList
    $enabledIndices = New-Object System.Collections.ArrayList

    for ($i = 0; $i -lt $Items.Count; $i++) {
        $item = $Items[$i]
        $type = 'Option'
        if ($item -is [hashtable] -and $item.ContainsKey('Type') -and $item['Type']) {
            $type = [string]$item['Type']
        } elseif ($item.PSObject.Properties['Type'] -and $item.Type) {
            $type = [string]$item.Type
        }

        $entry = @{
            Type        = $type
            Value       = $null
            Label       = ''
            Color       = [System.ConsoleColor]::White
            Suffix      = ''
            SuffixColor = [System.ConsoleColor]::Gray
            Details     = @()
            Disabled    = $false
            SpaceAfter  = $false
            LineOffset  = -1
            ColX        = 0
        }

        if ($type -eq 'Option') {
            $entry.Value = $item['Value']
            $entry.Label = if ($null -ne $item['Label']) { ([string]$item['Label']).TrimStart() } else { '' }
            if ($item.ContainsKey('Color') -and $null -ne $item['Color']) {
                $entry.Color = [System.ConsoleColor]$item['Color']
            }
            if ($item.ContainsKey('Suffix') -and $null -ne $item['Suffix']) {
                $entry.Suffix = [string]$item['Suffix']
            }
            if ($item.ContainsKey('SuffixColor') -and $null -ne $item['SuffixColor']) {
                $entry.SuffixColor = [System.ConsoleColor]$item['SuffixColor']
            }
            if ($item.ContainsKey('Details') -and $null -ne $item['Details']) {
                $entry.Details = @($item['Details'])
            }
            if ($item.ContainsKey('Disabled')) {
                $entry.Disabled = [bool]$item['Disabled']
            }
            if ($item.ContainsKey('SpaceAfter')) {
                $entry.SpaceAfter = [bool]$item['SpaceAfter']
            }
            if (-not $entry.Disabled) {
                [void]$enabledIndices.Add($entries.Count)
            }
        } else {
            if ($item.ContainsKey('Text') -and $null -ne $item['Text']) {
                $entry.Label = [string]$item['Text']
            }
            if ($item.ContainsKey('Color') -and $null -ne $item['Color']) {
                $entry.Color = [System.ConsoleColor]$item['Color']
            }
        }

        [void]$entries.Add($entry)
    }

    if ($enabledIndices.Count -eq 0) {
        if ($AllowBack) { return $BackValue }
        return $null
    }

    $selectedPos = if ($DefaultIndex -ge 0 -and $DefaultIndex -lt $enabledIndices.Count) { $DefaultIndex } else { 0 }
    $selectedEntryIdx = [int]$enabledIndices[$selectedPos]

    $allSimpleOptions = ($entries.Count -eq $enabledIndices.Count)
    $useGrid = ($Columns -gt 1 -and $allSimpleOptions -and $enabledIndices.Count -gt 1 -and $winWidth -ge 64)
    $colCount = if ($useGrid) { [Math]::Min($Columns, $enabledIndices.Count) } else { 1 }
    $gridRowCount = if ($useGrid) { [int][Math]::Ceiling([double]$enabledIndices.Count / [double]$colCount) } else { $entries.Count }
    $colGap = 4
    if ($useGrid) {
        $longestText = 0
        foreach ($ent in $entries) {
            $len = $ent.Label.Length + $ent.Suffix.Length
            if ($len -gt $longestText) { $longestText = $len }
        }
        $availPerCol = [int][Math]::Floor(($winWidth - 2 - ($colGap * ($colCount - 1))) / $colCount)
        $desiredCell = [Math]::Max(26, $longestText + 4)
        $maxOptionWidth = [Math]::Max(18, [Math]::Min($availPerCol, $desiredCell))
        $colStride = $maxOptionWidth + $colGap
    } else {
        $maxOptionWidth = [Math]::Max(20, $winWidth - 1)
        $colStride = $maxOptionWidth
    }

    if ([string]::IsNullOrWhiteSpace($FooterText)) {
        if ($useGrid) {
            if ($AllowBack) {
                $FooterText = & $getStr 'common.nav_hint_grid_back' '   [Flechas] Navegar  |  [Enter] Seleccionar  |  [Retroceso] Volver'
            } else {
                $FooterText = & $getStr 'common.nav_hint_grid_noback' '   [Flechas] Navegar  |  [Enter] Seleccionar'
            }
        } else {
            if ($AllowBack) {
                $FooterText = & $getStr 'common.nav_hint_back' '   [Arriba/Abajo] Navegar  |  [Enter] Seleccionar  |  [Retroceso] Volver'
            } else {
                $FooterText = & $getStr 'common.nav_hint_noback' '   [Arriba/Abajo] Navegar  |  [Enter] Seleccionar'
            }
        }
    }

    $origBg = [System.ConsoleColor]::Black
    try { $origBg = [Console]::BackgroundColor } catch { }

    $selGlyph = [string][char]0x00BB
    $useAnsiBold = Enable-AIOConsoleVT
    $boldOn = if ($useAnsiBold) { "$([char]27)[1m" } else { '' }
    $boldOff = if ($useAnsiBold) { "$([char]27)[22m" } else { '' }

    $formatOptionParts = {
        param($Entry, [bool]$IsSelected)
        $leadMargin = if ($IsSelected) { ' ' } else { '' }
        $prefix = if ($IsSelected) { ($selGlyph + ' ') } else { '   ' }
        $trailPad = if ($IsSelected) { ' ' } else { '' }
        $labelText = if ($IsSelected) { $Entry.Label.ToUpper() } else { $Entry.Label }
        $suffixText = if ($IsSelected) { $Entry.Suffix.ToUpper() } else { $Entry.Suffix }
        $limit = $maxOptionWidth - $leadMargin.Length - $trailPad.Length
        $innerLen = $prefix.Length + $labelText.Length + $suffixText.Length
        if ($innerLen -gt $limit) {
            if (($prefix.Length + $labelText.Length) -ge $limit) {
                $cutLen = [Math]::Max(1, $limit - $prefix.Length - 3)
                $labelText = $labelText.Substring(0, [Math]::Min($labelText.Length, $cutLen)) + '...'
                $suffixText = ''
            } else {
                $rem = $limit - $prefix.Length - $labelText.Length
                if ($rem -gt 3) {
                    $suffixText = $suffixText.Substring(0, $rem - 3) + '...'
                } else {
                    $suffixText = ''
                }
            }
        }
        $totalLen = $leadMargin.Length + $prefix.Length + $labelText.Length + $suffixText.Length + $trailPad.Length
        return @{
            LeadMargin = $leadMargin
            Prefix     = $prefix
            Label      = $labelText
            Suffix     = $suffixText
            TrailPad   = $trailPad
            Length     = $totalLen
        }
    }

    $writeOptionAt = {
        param([int]$ColX, [int]$RowY, $Entry, [bool]$IsSelected)
        $parts = & $formatOptionParts $Entry $IsSelected
        $padLen = [Math]::Max(0, $maxOptionWidth - $parts.Length)
        $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }

        if ($RowY -ge 0) {
            [Console]::SetCursorPosition($ColX, $RowY)
        }

        if ($IsSelected) {
            if ($parts.LeadMargin.Length -gt 0) {
                Write-Host $parts.LeadMargin -ForegroundColor White -BackgroundColor $origBg -NoNewline
            }
            Write-Host ($boldOn + $parts.Prefix + $parts.Label + $parts.Suffix + $parts.TrailPad + $boldOff) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
            if ($pad.Length -gt 0) {
                Write-Host $pad -ForegroundColor White -BackgroundColor $origBg -NoNewline
            }
        } elseif ($Entry.Disabled) {
            Write-Host ($parts.Prefix + $parts.Label + $parts.Suffix + $pad) -ForegroundColor DarkGray -BackgroundColor $origBg -NoNewline
        } else {
            Write-Host ($parts.Prefix + $parts.Label) -ForegroundColor $Entry.Color -BackgroundColor $origBg -NoNewline
            if ($parts.Suffix.Length -gt 0) {
                Write-Host $parts.Suffix -ForegroundColor $Entry.SuffixColor -BackgroundColor $origBg -NoNewline
            }
            if ($pad.Length -gt 0) {
                Write-Host $pad -ForegroundColor $Entry.Color -BackgroundColor $origBg -NoNewline
            }
        }
    }

    $measureWrappedRows = {
        param([string]$Text)
        if ([string]::IsNullOrEmpty($Text)) { return 1 }
        return [Math]::Max(1, [int][Math]::Ceiling([double]$Text.Length / [double]$winWidth))
    }

    # Verificar si la consola soporta posicionamiento interactivo y ReadKey.
    $interactiveOk = $true
    try {
        [void][Console]::KeyAvailable
        [void][Console]::CursorTop
    } catch {
        $interactiveOk = $false
    }

    if (-not $interactiveOk) {
        # Respaldo minimo si la entrada/salida esta redirigida.
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            if ($e.Type -eq 'Option') {
                $col = if ($e.Disabled) { [System.ConsoleColor]::DarkGray } else { $e.Color }
                Write-Host ("   " + $e.Label + $e.Suffix) -ForegroundColor $col
                if ($e.SpaceAfter) { Write-Host '' }
            } elseif ($e.Type -eq 'Blank') {
                Write-Host ''
            } else {
                Write-Host $e.Label -ForegroundColor $e.Color
            }
        }
        if ($AllowBack) { return $BackValue }
        return $entries[$selectedEntryIdx].Value
    }

    $prevCursorVisible = $true
    try { $prevCursorVisible = [Console]::CursorVisible } catch { }

    try {
        try { [Console]::CursorVisible = $false } catch { }

        # Renderizado inicial registrando el desplazamiento vertical relativo.
        $totalRows = 0
        if ($useGrid) {
            for ($r = 0; $r -lt $gridRowCount; $r++) {
                for ($c = 0; $c -lt $colCount; $c++) {
                    $idx = ($c * $gridRowCount) + $r
                    if ($idx -lt $entries.Count) {
                        $e = $entries[$idx]
                        $e.LineOffset = $totalRows
                        $e.ColX = $c * $colStride
                        $isSel = ($idx -eq $selectedEntryIdx)
                        $parts = & $formatOptionParts $e $isSel
                        $padLen = [Math]::Max(0, $maxOptionWidth - $parts.Length)
                        $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
                        $gap = if ($c -lt ($colCount - 1)) { (' ' * $colGap) } else { '' }

                        if ($isSel) {
                            if ($parts.LeadMargin.Length -gt 0) {
                                Write-Host $parts.LeadMargin -ForegroundColor White -BackgroundColor $origBg -NoNewline
                            }
                            Write-Host ($boldOn + $parts.Prefix + $parts.Label + $parts.Suffix + $parts.TrailPad + $boldOff) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
                            Write-Host ($pad + $gap) -ForegroundColor White -BackgroundColor $origBg -NoNewline
                        } else {
                            Write-Host ($parts.Prefix + $parts.Label) -ForegroundColor $e.Color -BackgroundColor $origBg -NoNewline
                            if ($parts.Suffix.Length -gt 0) {
                                Write-Host $parts.Suffix -ForegroundColor $e.SuffixColor -BackgroundColor $origBg -NoNewline
                            }
                            Write-Host ($pad + $gap) -ForegroundColor $e.Color -BackgroundColor $origBg -NoNewline
                        }
                    }
                }
                Write-Host ''
                $totalRows += 1
            }
            Write-Host ''
            $totalRows += 1
        } else {
        for ($i = 0; $i -lt $entries.Count; $i++) {
            $e = $entries[$i]
            switch ($e.Type) {
                'Blank' {
                    Write-Host ''
                    $totalRows += 1
                }
                'Header' {
                    Write-Host $e.Label -ForegroundColor $e.Color
                    $totalRows += (& $measureWrappedRows $e.Label)
                }
                'Separator' {
                    Write-Host $e.Label -ForegroundColor $e.Color
                    $totalRows += (& $measureWrappedRows $e.Label)
                }
                'Text' {
                    Write-Host $e.Label -ForegroundColor $e.Color
                    $totalRows += (& $measureWrappedRows $e.Label)
                }
                'Option' {
                    $e.LineOffset = $totalRows
                    $isSel = ($i -eq $selectedEntryIdx)
                    $parts = & $formatOptionParts $e $isSel
                    $padLen = [Math]::Max(0, $maxOptionWidth - $parts.Length)
                    $pad = if ($padLen -gt 0) { ' ' * $padLen } else { '' }
                    if ($isSel) {
                        if ($parts.LeadMargin.Length -gt 0) {
                            Write-Host $parts.LeadMargin -ForegroundColor White -BackgroundColor $origBg -NoNewline
                        }
                        Write-Host ($boldOn + $parts.Prefix + $parts.Label + $parts.Suffix + $parts.TrailPad + $boldOff) -ForegroundColor Black -BackgroundColor Cyan -NoNewline
                        Write-Host $pad -ForegroundColor White -BackgroundColor $origBg
                    } elseif ($e.Disabled) {
                        Write-Host ($parts.Prefix + $parts.Label + $parts.Suffix + $pad) -ForegroundColor DarkGray -BackgroundColor $origBg
                    } else {
                        Write-Host ($parts.Prefix + $parts.Label) -ForegroundColor $e.Color -BackgroundColor $origBg -NoNewline
                        if ($parts.Suffix.Length -gt 0) {
                            Write-Host $parts.Suffix -ForegroundColor $e.SuffixColor -BackgroundColor $origBg -NoNewline
                        }
                        Write-Host $pad -ForegroundColor $e.Color -BackgroundColor $origBg
                    }
                    $totalRows += 1

                    foreach ($det in $e.Details) {
                        if ($det -is [hashtable] -and $det.ContainsKey('Prefix') -and $det['Prefix']) {
                            $pText = [string]$det['Prefix']
                            $pCol = if ($det.ContainsKey('PrefixColor') -and $null -ne $det['PrefixColor']) { [System.ConsoleColor]$det['PrefixColor'] } else { [System.ConsoleColor]::White }
                            $tText = if ($det.ContainsKey('Text') -and $null -ne $det['Text']) { [string]$det['Text'] } else { '' }
                            $tCol = if ($det.ContainsKey('Color') -and $null -ne $det['Color']) { [System.ConsoleColor]$det['Color'] } else { [System.ConsoleColor]::Gray }
                            Write-Host $pText -ForegroundColor $pCol -NoNewline
                            Write-Host $tText -ForegroundColor $tCol
                            $totalRows += (& $measureWrappedRows ($pText + $tText))
                        } elseif ($det -is [hashtable]) {
                            $tText = if ($det.ContainsKey('Text') -and $null -ne $det['Text']) { [string]$det['Text'] } else { '' }
                            $tCol = if ($det.ContainsKey('Color') -and $null -ne $det['Color']) { [System.ConsoleColor]$det['Color'] } else { [System.ConsoleColor]::Gray }
                            Write-Host $tText -ForegroundColor $tCol
                            $totalRows += (& $measureWrappedRows $tText)
                        } else {
                            $tText = [string]$det
                            Write-Host $tText -ForegroundColor Gray
                            $totalRows += (& $measureWrappedRows $tText)
                        }
                    }

                    if ($e.SpaceAfter) {
                        Write-Host ''
                        $totalRows += 1
                    }
                }
            }
        }
        }

        if (-not $NoSeparator) {
            $effectiveSep = $SeparatorText
            if ($useGrid -and -not $PSBoundParameters.ContainsKey('SeparatorText')) {
                $gridWidth = [Math]::Min($winWidth - 2, [Math]::Max(55, ($colStride * $colCount) - $colGap))
                $effectiveSep = '-' * $gridWidth
            }
            Write-Host $effectiveSep -ForegroundColor DarkGray
            $totalRows += (& $measureWrappedRows $effectiveSep)
        }
        Write-Host $FooterText -ForegroundColor DarkGray
        $totalRows += (& $measureWrappedRows $FooterText)
        Write-Host ''
        $totalRows += 1

        $afterTop = [Console]::CursorTop
        $baseTop = [Math]::Max(0, $afterTop - $totalRows)

        # Limpiar cualquier tecla rezagada en el buffer antes de leer.
        while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) }

        while ($true) {
            $keyInfo = [Console]::ReadKey($true)
            $oldPos = $selectedPos

            switch ($keyInfo.Key) {
                'UpArrow' {
                    $selectedPos = if ($selectedPos -le 0) { $enabledIndices.Count - 1 } else { $selectedPos - 1 }
                }
                'DownArrow' {
                    $selectedPos = if ($selectedPos -ge ($enabledIndices.Count - 1)) { 0 } else { $selectedPos + 1 }
                }
                'LeftArrow' {
                    if ($useGrid -and $selectedPos -ge $gridRowCount) {
                        $selectedPos = $selectedPos - $gridRowCount
                    }
                }
                'RightArrow' {
                    if ($useGrid -and $selectedPos -lt (($colCount - 1) * $gridRowCount)) {
                        $nextPos = $selectedPos + $gridRowCount
                        if ($nextPos -lt $enabledIndices.Count) {
                            $selectedPos = $nextPos
                        } else {
                            $selectedPos = $enabledIndices.Count - 1
                        }
                    }
                }
                'Home' {
                    $selectedPos = 0
                }
                'End' {
                    $selectedPos = $enabledIndices.Count - 1
                }
                'Enter' {
                    try { [Console]::SetCursorPosition(0, $afterTop) } catch { }
                    return $entries[$selectedEntryIdx].Value
                }
                'Backspace' {
                    if ($AllowBack) {
                        try { [Console]::SetCursorPosition(0, $afterTop) } catch { }
                        return $BackValue
                    }
                }
                default { }
            }

            if ($selectedPos -ne $oldPos) {
                $oldEntryIdx = $selectedEntryIdx
                $selectedEntryIdx = [int]$enabledIndices[$selectedPos]

                $oldY = $baseTop + $entries[$oldEntryIdx].LineOffset
                $newY = $baseTop + $entries[$selectedEntryIdx].LineOffset

                if ($oldY -ge 0 -and $oldY -lt [Console]::BufferHeight) {
                    & $writeOptionAt $entries[$oldEntryIdx].ColX $oldY $entries[$oldEntryIdx] $false
                }
                if ($newY -ge 0 -and $newY -lt [Console]::BufferHeight) {
                    & $writeOptionAt $entries[$selectedEntryIdx].ColX $newY $entries[$selectedEntryIdx] $true
                }
            }
        }
    } finally {
        try { [Console]::CursorVisible = $prevCursorVisible } catch { }
    }
}
