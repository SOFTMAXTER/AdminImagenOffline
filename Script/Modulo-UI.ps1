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
