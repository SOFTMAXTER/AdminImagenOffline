# =================================================================
# Motor de internacionalizacion (i18n) de AdminImagenOffline.
# Copyright (C) 2026 SOFTMAXTER.
# Distribuido bajo la licencia del proyecto (ver LICENSE).
# Carga paquetes JSON desde \Lang\ y detecta el idioma del sistema.
# =================================================================

$Script:AIOI18nBaseLanguage = 'es'
$Script:AIOI18nLangDir = $null
$Script:AIOI18nRequestedLanguage = 'auto'
$Script:AIOI18nActiveLanguage = 'es'
$Script:AIOI18nActiveMeta = $null
$Script:AIOI18nHostCulture = 'es'
$Script:AIOI18nFallbackStrings = @{}
$Script:AIOI18nStrings = @{}
$Script:AIOI18nInitialized = $false
$Script:AIOI18nUseBaseOnly = $false

function Get-AIOHostUICultureName {
    try {
        $culture = [System.Globalization.CultureInfo]::CurrentUICulture
        if ($null -ne $culture -and -not [string]::IsNullOrWhiteSpace($culture.Name)) {
            return $culture.Name
        }
    } catch {}

    try {
        $uiCulture = Get-UICulture -ErrorAction SilentlyContinue
        if ($null -ne $uiCulture -and -not [string]::IsNullOrWhiteSpace($uiCulture.Name)) {
            return $uiCulture.Name
        }
    } catch {}

    try {
        $current = [System.Globalization.CultureInfo]::CurrentCulture
        if ($null -ne $current -and -not [string]::IsNullOrWhiteSpace($current.Name)) {
            return $current.Name
        }
    } catch {}

    return $Script:AIOI18nBaseLanguage
}

function ConvertTo-AIOFlatStringTable {
    param(
        [Parameter(Mandatory = $false)]
        $InputObject,
        [string]$Prefix = '',
        [hashtable]$Target = $null
    )

    if ($null -eq $Target) {
        $Target = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    }
    if ($null -eq $InputObject) { return $Target }

    foreach ($prop in $InputObject.PSObject.Properties) {
        $name = [string]$prop.Name
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($Prefix -eq '' -and $name -eq '_meta') { continue }

        $fullKey = if ([string]::IsNullOrWhiteSpace($Prefix)) { $name } else { "$Prefix.$name" }
        $val = $prop.Value

        if ($null -eq $val) {
            $Target[$fullKey] = ''
        } elseif ($val -is [System.Management.Automation.PSCustomObject]) {
            [void](ConvertTo-AIOFlatStringTable -InputObject $val -Prefix $fullKey -Target $Target)
        } else {
            $Target[$fullKey] = [string]$val
        }
    }

    return $Target
}

function Read-AIOLanguageJsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        return $null
    }

    try {
        $rawJson = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($rawJson)) { return $null }
        $parsed = $rawJson | ConvertFrom-Json -ErrorAction Stop
        $meta = $null
        if ($null -ne $parsed.PSObject.Properties['_meta']) {
            $meta = $parsed._meta
        }
        $table = ConvertTo-AIOFlatStringTable -InputObject $parsed
        return [pscustomobject]@{
            Path    = $FilePath
            Code    = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
            Meta    = $meta
            Strings = $table
        }
    } catch {
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -LogLevel WARN -Message "I18N: Error leyendo paquete de idioma '$FilePath': $($_.Exception.Message)"
        }
        return $null
    }
}

function Resolve-AIOLanguageFilePath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LangDir,
        [Parameter(Mandatory = $true)]
        [string]$CultureCode
    )

    if (-not (Test-Path -LiteralPath $LangDir -PathType Container)) {
        return $null
    }

    $normalized = $CultureCode.Trim().Replace('_', '-')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        $normalized = $Script:AIOI18nBaseLanguage
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    [void]$candidates.Add($normalized)

    if ($normalized -match '^([A-Za-z]{2,3})-') {
        $neutral = $matches[1]
        if (-not $candidates.Contains($neutral)) {
            [void]$candidates.Add($neutral)
        }
    }

    if (-not $candidates.Contains($Script:AIOI18nBaseLanguage)) {
        [void]$candidates.Add($Script:AIOI18nBaseLanguage)
    }

    $availableFiles = @(Get-ChildItem -LiteralPath $LangDir -Filter '*.json' -File -ErrorAction SilentlyContinue)
    foreach ($candidate in $candidates) {
        $match = $availableFiles | Where-Object {
            [string]::Equals($_.BaseName, $candidate, [System.StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1
        if ($null -ne $match) {
            return $match.FullName
        }
    }

    return $null
}

function Get-AIOAvailableLanguages {
    param(
        [string]$LangDir = $Script:AIOI18nLangDir
    )

    $results = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($LangDir) -or -not (Test-Path -LiteralPath $LangDir -PathType Container)) {
        return @()
    }

    $files = @(Get-ChildItem -LiteralPath $LangDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($file in $files) {
        $pack = Read-AIOLanguageJsonFile -FilePath $file.FullName
        if ($null -eq $pack) { continue }

        $code = $file.BaseName
        $name = $code
        $nativeName = $code
        $author = ''

        if ($null -ne $pack.Meta) {
            if ($pack.Meta.PSObject.Properties['code'] -and -not [string]::IsNullOrWhiteSpace([string]$pack.Meta.code)) {
                $code = [string]$pack.Meta.code
            }
            if ($pack.Meta.PSObject.Properties['name'] -and -not [string]::IsNullOrWhiteSpace([string]$pack.Meta.name)) {
                $name = [string]$pack.Meta.name
            }
            if ($pack.Meta.PSObject.Properties['nativeName'] -and -not [string]::IsNullOrWhiteSpace([string]$pack.Meta.nativeName)) {
                $nativeName = [string]$pack.Meta.nativeName
            }
            if ($pack.Meta.PSObject.Properties['author'] -and -not [string]::IsNullOrWhiteSpace([string]$pack.Meta.author)) {
                $author = [string]$pack.Meta.author
            }
        }

        [void]$results.Add([pscustomobject]@{
            Code       = $code
            Name       = $name
            NativeName = $nativeName
            Author     = $author
            FilePath   = $file.FullName
            KeyCount   = $pack.Strings.Count
        })
    }

    return $results.ToArray()
}

function Initialize-AIOI18n {
    [CmdletBinding()]
    param(
        [string]$LangDir = '',
        [string]$PreferredLanguage = 'auto'
    )

    if ([string]::IsNullOrWhiteSpace($LangDir)) {
        if (-not [string]::IsNullOrWhiteSpace($Script:AIOI18nLangDir)) {
            $LangDir = $Script:AIOI18nLangDir
        } else {
            $baseDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
                Split-Path -Parent $PSScriptRoot
            } else {
                $PWD.Path
            }
            $LangDir = Join-Path -Path $baseDir -ChildPath 'Lang'
        }
    }

    $Script:AIOI18nLangDir = $LangDir
    $Script:AIOI18nHostCulture = Get-AIOHostUICultureName

    $requested = if ([string]::IsNullOrWhiteSpace($PreferredLanguage)) { 'auto' } else { $PreferredLanguage.Trim() }
    $Script:AIOI18nRequestedLanguage = $requested

    $effectiveCulture = if ([string]::Equals($requested, 'auto', [System.StringComparison]::OrdinalIgnoreCase)) {
        $Script:AIOI18nHostCulture
    } else {
        $requested
    }

    # Cargar siempre el paquete base (es) como respaldo para claves faltantes.
    $basePath = Resolve-AIOLanguageFilePath -LangDir $LangDir -CultureCode $Script:AIOI18nBaseLanguage
    $basePack = if ($null -ne $basePath) { Read-AIOLanguageJsonFile -FilePath $basePath } else { $null }
    if ($null -ne $basePack) {
        $Script:AIOI18nFallbackStrings = $basePack.Strings
    } else {
        $Script:AIOI18nFallbackStrings = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
    }

    # Resolver y cargar el paquete activo segun el idioma del sistema o preferencia.
    $activePath = Resolve-AIOLanguageFilePath -LangDir $LangDir -CultureCode $effectiveCulture
    $activePack = if ($null -ne $activePath) { Read-AIOLanguageJsonFile -FilePath $activePath } else { $null }

    if ($null -ne $activePack) {
        $Script:AIOI18nStrings = $activePack.Strings
        $Script:AIOI18nActiveLanguage = $activePack.Code
        $Script:AIOI18nActiveMeta = $activePack.Meta
    } elseif ($null -ne $basePack) {
        $Script:AIOI18nStrings = $basePack.Strings
        $Script:AIOI18nActiveLanguage = $basePack.Code
        $Script:AIOI18nActiveMeta = $basePack.Meta
    } else {
        $Script:AIOI18nStrings = New-Object System.Collections.Hashtable ([System.StringComparer]::OrdinalIgnoreCase)
        $Script:AIOI18nActiveLanguage = $Script:AIOI18nBaseLanguage
        $Script:AIOI18nActiveMeta = $null
    }

    $Script:AIOI18nInitialized = $true

    if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -LogLevel INFO -Message "I18N: Idioma activo '$($Script:AIOI18nActiveLanguage)' (Preferencia: '$($Script:AIOI18nRequestedLanguage)' | Sistema: '$($Script:AIOI18nHostCulture)' | Claves: $($Script:AIOI18nStrings.Count))."
    }

    return $Script:AIOI18nActiveLanguage
}

function Get-AIOString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Key,

        [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
        [object[]]$FormatArgs
    )

    $template = $null
    if ($Script:AIOI18nUseBaseOnly -and $null -ne $Script:AIOI18nFallbackStrings -and $Script:AIOI18nFallbackStrings.ContainsKey($Key)) {
        $template = $Script:AIOI18nFallbackStrings[$Key]
    } elseif ($null -ne $Script:AIOI18nStrings -and $Script:AIOI18nStrings.ContainsKey($Key)) {
        $template = $Script:AIOI18nStrings[$Key]
    } elseif ($null -ne $Script:AIOI18nFallbackStrings -and $Script:AIOI18nFallbackStrings.ContainsKey($Key)) {
        $template = $Script:AIOI18nFallbackStrings[$Key]
    } else {
        $template = $Key
    }

    if ($null -ne $FormatArgs -and $FormatArgs.Count -gt 0) {
        try {
            return [string]::Format([System.Globalization.CultureInfo]::InvariantCulture, [string]$template, [object[]]$FormatArgs)
        } catch {
            return [string]$template
        }
    }

    return [string]$template
}

Set-Alias -Name T -Value Get-AIOString -Scope Script -Force

function Invoke-AIOWithBaseLanguage {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][scriptblock]$ScriptBlock)

    # Ejecuta el bloque resolviendo los textos siempre en el idioma base (es),
    # para que los metadatos escritos en un WIM no dependan del idioma de la interfaz.
    $previous = $Script:AIOI18nUseBaseOnly
    $Script:AIOI18nUseBaseOnly = $true
    try {
        return (& $ScriptBlock)
    } finally {
        $Script:AIOI18nUseBaseOnly = $previous
    }
}

function Test-AIOYesResponse {
    param(
        [AllowNull()]
        [string]$InputText
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) { return $false }
    $clean = $InputText.Trim().ToUpperInvariant()

    $rawTokens = Get-AIOString 'common.yes_tokens'
    if ([string]::IsNullOrWhiteSpace($rawTokens) -or $rawTokens -eq 'common.yes_tokens') {
        $rawTokens = 'S,SI,SÍ,Y,YES'
    }

    $tokens = @($rawTokens -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ -ne '' })
    return ($tokens -contains $clean)
}

function Test-AIONoResponse {
    param(
        [AllowNull()]
        [string]$InputText
    )

    if ([string]::IsNullOrWhiteSpace($InputText)) { return $false }
    $clean = $InputText.Trim().ToUpperInvariant()

    $rawTokens = Get-AIOString 'common.no_tokens'
    if ([string]::IsNullOrWhiteSpace($rawTokens) -or $rawTokens -eq 'common.no_tokens') {
        $rawTokens = 'N,NO'
    }

    $tokens = @($rawTokens -split ',' | ForEach-Object { $_.Trim().ToUpperInvariant() } | Where-Object { $_ -ne '' })
    return ($tokens -contains $clean)
}

function Get-AIOLanguageDisplaySummary {
    $native = $Script:AIOI18nActiveLanguage
    if ($null -ne $Script:AIOI18nActiveMeta -and $Script:AIOI18nActiveMeta.PSObject.Properties['nativeName']) {
        $native = [string]$Script:AIOI18nActiveMeta.nativeName
    }

    if ([string]::Equals($Script:AIOI18nRequestedLanguage, 'auto', [System.StringComparison]::OrdinalIgnoreCase)) {
        return (Get-AIOString 'config.lang_auto_summary' $native $Script:AIOI18nHostCulture)
    }

    return "$native ($($Script:AIOI18nActiveLanguage))"
}

function Show-AIOLanguageSelector {
    $available = @(Get-AIOAvailableLanguages)

    Clear-Host
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'config.lang_menu_title') -ForegroundColor Cyan
    Write-Host "=======================================================" -ForegroundColor Cyan
    Write-Host (Get-AIOString 'config.lang_menu_desc')
    Write-Host ""
    Write-Host (Get-AIOString 'config.lang_current' (Get-AIOLanguageDisplaySummary)) -ForegroundColor Yellow
    Write-Host ""
    $langItems = @(
        @{ Value = 'auto'; Label = (Get-AIOString 'config.lang_opt_auto' $Script:AIOI18nHostCulture); Color = 'Cyan' }
    )
    for ($i = 0; $i -lt $available.Count; $i++) {
        $lang = $available[$i]
        $langItems += @{
            Value = $lang.Code
            Label = ("{0} ({1})" -f $lang.NativeName, $lang.Code)
            Color = 'White'
        }
    }
    $langItems += @{ Type = 'Blank' }

    $choice = [string](Show-AIOConsoleMenu -Items $langItems -AllowBack -BackValue 'V')
    if ([string]::IsNullOrWhiteSpace($choice) -or $choice -eq 'V') {
        return $false
    }

    if ($choice -eq 'auto') {
        $Script:UI_LANGUAGE = 'auto'
        [void](Initialize-AIOI18n -PreferredLanguage 'auto')
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -LogLevel ACTION -Message "CONFIG: UI_LANGUAGE cambiado a 'auto' (activo: '$($Script:AIOI18nActiveLanguage)')."
        }
        return $true
    }

    $selected = $available | Where-Object { $_.Code -eq $choice } | Select-Object -First 1
    if ($null -ne $selected) {
        $Script:UI_LANGUAGE = $selected.Code
        [void](Initialize-AIOI18n -PreferredLanguage $selected.Code)
        if (Get-Command -Name Write-Log -ErrorAction SilentlyContinue) {
            Write-Log -LogLevel ACTION -Message "CONFIG: UI_LANGUAGE cambiado a '$($selected.Code)'."
        }
        return $true
    }

    return $false
}
