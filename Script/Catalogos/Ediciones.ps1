# =================================================================
#  CATÁLOGO CENTRAL DE EDICIONES DE WINDOWS 10 / 11 / SERVER
#  Útil para inyectar metadatos (Nombre y Descripción) durante 
#  operaciones de captura (Convert-VHD, Save-NewWim, Export-Image).
# =================================================================

$script:EditionCatalog = @(

    # =========================================================
    # RAMA DOMÉSTICA (HOME)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Core"
        Name        = "Windows Home"
        Description = (Get-AIOString 'catalog.editions.Core')
    },
    [PSCustomObject]@{
        EditionID   = "CoreN"
        Name        = "Windows Home N"
        Description = (Get-AIOString 'catalog.editions.CoreN')
    },
    [PSCustomObject]@{
        EditionID   = "CoreK"
        Name        = "Windows Home K / KN"
        Description = (Get-AIOString 'catalog.editions.CoreK')
    },
    [PSCustomObject]@{
        EditionID   = "CoreSingleLanguage"
        Name        = "Windows Home Single Language"
        Description = (Get-AIOString 'catalog.editions.CoreSingleLanguage')
    },
    [PSCustomObject]@{
        EditionID   = "CoreCountrySpecific"
        Name        = "Windows Home Country Specific"
        Description = (Get-AIOString 'catalog.editions.CoreCountrySpecific')
    },

    # =========================================================
    # RAMA PROFESIONAL (PRO)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Professional"
        Name        = "Windows Pro"
        Description = (Get-AIOString 'catalog.editions.Professional')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalN"
        Name        = "Windows Pro N"
        Description = (Get-AIOString 'catalog.editions.ProfessionalN')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalSingleLanguage"
        Name        = "Windows Pro Single Language"
        Description = (Get-AIOString 'catalog.editions.ProfessionalSingleLanguage')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalCountrySpecific"
        Name        = "Windows Pro Country Specific"
        Description = (Get-AIOString 'catalog.editions.ProfessionalCountrySpecific')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalWorkstation"
        Name        = "Windows Pro for Workstations"
        Description = (Get-AIOString 'catalog.editions.ProfessionalWorkstation')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalWorkstationN"
        Name        = "Windows Pro for Workstations N"
        Description = (Get-AIOString 'catalog.editions.ProfessionalWorkstationN')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalEducation"
        Name        = "Windows Pro Education"
        Description = (Get-AIOString 'catalog.editions.ProfessionalEducation')
    },
    [PSCustomObject]@{
        EditionID   = "ProfessionalEducationN"
        Name        = "Windows Pro Education N"
        Description = (Get-AIOString 'catalog.editions.ProfessionalEducationN')
    },

    # =========================================================
    # RAMA EMPRESARIAL (ENTERPRISE)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Enterprise"
        Name        = "Windows Enterprise"
        Description = (Get-AIOString 'catalog.editions.Enterprise')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseN"
        Name        = "Windows Enterprise N"
        Description = (Get-AIOString 'catalog.editions.EnterpriseN')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseS"
        Name        = "Windows Enterprise LTSC"
        Description = (Get-AIOString 'catalog.editions.EnterpriseS')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseSN"
        Name        = "Windows Enterprise LTSC N"
        Description = (Get-AIOString 'catalog.editions.EnterpriseSN')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseG"
        Name        = "Windows Enterprise G"
        Description = (Get-AIOString 'catalog.editions.EnterpriseG')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseGN"
        Name        = "Windows Enterprise G (N)"
        Description = (Get-AIOString 'catalog.editions.EnterpriseGN')
    },
    [PSCustomObject]@{
        EditionID   = "ServerRdsh"
        Name        = "Windows Enterprise Multi-Session"
        Description = (Get-AIOString 'catalog.editions.ServerRdsh')
    },

    # =========================================================
    # RAMA EDUCATIVA Y CLOUD
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "Education"
        Name        = "Windows Education"
        Description = (Get-AIOString 'catalog.editions.Education')
    },
    [PSCustomObject]@{
        EditionID   = "EducationN"
        Name        = "Windows Education N"
        Description = (Get-AIOString 'catalog.editions.EducationN')
    },
    [PSCustomObject]@{
        EditionID   = "Cloud"
        Name        = "Windows 10 S"
        Description = (Get-AIOString 'catalog.editions.Cloud')
    },
    [PSCustomObject]@{
        EditionID   = "CloudN"
        Name        = "Windows 10 S (N)"
        Description = (Get-AIOString 'catalog.editions.CloudN')
    },
    [PSCustomObject]@{
        EditionID   = "CloudEdition"
        Name        = "Windows 11 SE"
        Description = (Get-AIOString 'catalog.editions.CloudEdition')
    },
    [PSCustomObject]@{
        EditionID   = "CloudEditionN"
        Name        = "Windows 11 SE (N)"
        Description = (Get-AIOString 'catalog.editions.CloudEditionN')
    },

    # =========================================================
    # RAMA INTERNET DE LAS COSAS (IoT)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "IoTEnterprise"
        Name        = "Windows IoT Enterprise"
        Description = (Get-AIOString 'catalog.editions.IoTEnterprise')
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseK"
        Name        = "Windows IoT Enterprise K"
        Description = (Get-AIOString 'catalog.editions.IoTEnterpriseK')
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseS"
        Name        = "Windows IoT Enterprise LTSC"
        Description = (Get-AIOString 'catalog.editions.IoTEnterpriseS')
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseSK"
        Name        = "Windows IoT Enterprise LTSC K"
        Description = (Get-AIOString 'catalog.editions.IoTEnterpriseSK')
    },

    # =========================================================
    # RAMA SERVIDORES (WINDOWS SERVER)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "ServerStandard"
        Name        = "Windows Server Standard"
        Description = (Get-AIOString 'catalog.editions.ServerStandard')
    },
    [PSCustomObject]@{
        EditionID   = "ServerStandardCore"
        Name        = "Windows Server Standard (Server Core)"
        Description = (Get-AIOString 'catalog.editions.ServerStandardCore')
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenter"
        Name        = "Windows Server Datacenter"
        Description = (Get-AIOString 'catalog.editions.ServerDatacenter')
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenterCore"
        Name        = "Windows Server Datacenter (Server Core)"
        Description = (Get-AIOString 'catalog.editions.ServerDatacenterCore')
    },
    [PSCustomObject]@{
        EditionID   = "ServerAzureCor"
        Name        = "Windows Server Datacenter: Azure Edition (Core)"
        Description = (Get-AIOString 'catalog.editions.ServerAzureCor')
    },
    [PSCustomObject]@{
        EditionID   = "ServerTurbine"
        Name        = "Windows Server Datacenter: Azure Edition"
        Description = (Get-AIOString 'catalog.editions.ServerTurbine')
    },
    [PSCustomObject]@{
        EditionID   = "ServerTurbineCor"
        Name        = "Windows Server Datacenter: Azure Edition (Core)"
        Description = (Get-AIOString 'catalog.editions.ServerTurbineCor')
    },
    [PSCustomObject]@{
        EditionID   = "ServerStandardACor"
        Name        = "Windows Server Standard (Server Core)"
        Description = (Get-AIOString 'catalog.editions.ServerStandardACor')
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenterACor"
        Name        = "Windows Server Datacenter (Server Core)"
        Description = (Get-AIOString 'catalog.editions.ServerDatacenterACor')
    },
    [PSCustomObject]@{
        EditionID   = "ServerStandardEval"
        Name        = "Windows Server Standard Evaluation"
        Description = (Get-AIOString 'catalog.editions.ServerStandardEval')
    },
    [PSCustomObject]@{
        EditionID   = "ServerStandardCoreEval"
        Name        = "Windows Server Standard (Server Core) Evaluation"
        Description = (Get-AIOString 'catalog.editions.ServerStandardCoreEval')
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenterEval"
        Name        = "Windows Server Datacenter Evaluation"
        Description = (Get-AIOString 'catalog.editions.ServerDatacenterEval')
    },
    [PSCustomObject]@{
        EditionID   = "ServerDatacenterCoreEval"
        Name        = "Windows Server Datacenter (Server Core) Evaluation"
        Description = (Get-AIOString 'catalog.editions.ServerDatacenterCoreEval')
    },
    [PSCustomObject]@{
        EditionID   = "ServerSolution"
        Name        = "Windows Server Essentials"
        Description = (Get-AIOString 'catalog.editions.ServerSolution')
    },

    # =========================================================
    # EDICIONES DE EVALUACIÓN Y ESPECIALIZADAS (CLIENT / OEM)
    # =========================================================
    [PSCustomObject]@{
        EditionID   = "EnterpriseEval"
        Name        = "Windows Enterprise Evaluation"
        Description = (Get-AIOString 'catalog.editions.EnterpriseEval')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseNEval"
        Name        = "Windows Enterprise N Evaluation"
        Description = (Get-AIOString 'catalog.editions.EnterpriseNEval')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseSEval"
        Name        = "Windows Enterprise LTSC Evaluation"
        Description = (Get-AIOString 'catalog.editions.EnterpriseSEval')
    },
    [PSCustomObject]@{
        EditionID   = "EnterpriseSNEval"
        Name        = "Windows Enterprise LTSC N Evaluation"
        Description = (Get-AIOString 'catalog.editions.EnterpriseSNEval')
    },
    [PSCustomObject]@{
        EditionID   = "IoTEnterpriseSEval"
        Name        = "Windows IoT Enterprise LTSC Evaluation"
        Description = (Get-AIOString 'catalog.editions.IoTEnterpriseSEval')
    },
    [PSCustomObject]@{
        EditionID   = "PPIPro"
        Name        = "Windows Team"
        Description = (Get-AIOString 'catalog.editions.PPIPro')
    },
    [PSCustomObject]@{
        EditionID   = "WNC"
        Name        = "Windows Cloud PC"
        Description = (Get-AIOString 'catalog.editions.WNC')
    },
    [PSCustomObject]@{
        EditionID   = "Starter"
        Name        = "Windows Starter"
        Description = (Get-AIOString 'catalog.editions.Starter')
    },
    [PSCustomObject]@{
        EditionID   = "StarterN"
        Name        = "Windows Starter N"
        Description = (Get-AIOString 'catalog.editions.StarterN')
    }
)

# =================================================================
# FUNCIÓN AUXILIAR DE BÚSQUEDA
# Retorna el objeto completo basado en el EditionID o el Nombre.
# =================================================================
function Get-WindowsEditionMetadata {
    param(
        [string]$QueryString
    )
    
    # Priorizar coincidencia exacta de EditionID o Name antes de buscar por subcadena
    $match = $script:EditionCatalog | Where-Object {
        $_.EditionID -ieq $QueryString -or $_.Name -ieq $QueryString
    } | Select-Object -First 1

    if (-not $match -and -not [string]::IsNullOrWhiteSpace($QueryString)) {
        $match = $script:EditionCatalog | Where-Object {
            $_.Name -match [regex]::Escape($QueryString)
        } | Select-Object -First 1
    }

    if ($match) {
        return $match
    } else {
        # Fallback genérico si se encuentra una edición muy rara
        return [PSCustomObject]@{
            EditionID   = $QueryString
            Name        = "Windows $QueryString"
            Description = (Get-AIOString 'catalog.editions.fallback' $QueryString)
        }
    }
}