# --- CATALOGO CENTRAL DE SERVICIOS ---
# Define todos los servicios gestionables, su proposito, categoria y estado por defecto.
# Esto hace que la funcion sea facilmente extensible.
$script:ServiceCatalog = @(
    # Categoria: Estandar (Servicios que a menudo se pueden desactivar para liberar recursos)
    [PSCustomObject]@{
        Name               = "Fax"
        Description        = (Get-AIOString 'catalog.services.desc.Fax')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "PrintSpooler"
        Description        = (Get-AIOString 'catalog.services.desc.PrintSpooler')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "RemoteRegistry"
        Description        = (Get-AIOString 'catalog.services.desc.RemoteRegistry')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "SysMain"
        Description        = (Get-AIOString 'catalog.services.desc.SysMain')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "TabletInputService"
        Description        = (Get-AIOString 'catalog.services.desc.TabletInputService')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
	},
    [PSCustomObject]@{
        Name               = "WalletService"
        Description        = (Get-AIOString 'catalog.services.desc.WalletService')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "wisvc"
        Description        = (Get-AIOString 'catalog.services.desc.wisvc')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
	},
	[PSCustomObject]@{
        Name               = "AJRouter"
        Description        = (Get-AIOString 'catalog.services.desc.AJRouter')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
	},	
	[PSCustomObject]@{
        Name               = "MapsBroker"
        Description        = (Get-AIOString 'catalog.services.desc.MapsBroker')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
	},
	[PSCustomObject]@{
        Name               = "icssvc"
        Description        = (Get-AIOString 'catalog.services.desc.icssvc')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
	},
    [PSCustomObject]@{
        Name               = "WSearch"
        Description        = (Get-AIOString 'catalog.services.desc.WSearch')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
	[PSCustomObject]@{
        Name               = "fhsvc"
        Description        = (Get-AIOString 'catalog.services.desc.fhsvc')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "TrkWks"
        Description        = (Get-AIOString 'catalog.services.desc.TrkWks')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "RetailDemo"
        Description        = (Get-AIOString 'catalog.services.desc.RetailDemo')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "DPS"
        Description        = (Get-AIOString 'catalog.services.desc.DPS')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "WdiServiceHost"
        Description        = (Get-AIOString 'catalog.services.desc.WdiServiceHost')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "WdiSystemHost"
        Description        = (Get-AIOString 'catalog.services.desc.WdiSystemHost')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "PcaSvc"
        Description        = (Get-AIOString 'catalog.services.desc.PcaSvc')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
	[PSCustomObject]@{
        Name               = "FontCache"
        Description        = (Get-AIOString 'catalog.services.desc.FontCache')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "FontCache3.0.0.0"
        Description        = (Get-AIOString 'catalog.services.desc.FontCache3_0_0_0')
        Category           = (Get-AIOString 'catalog.services.cat.std')
        DefaultStartupType = "Manual"
    },
    # Categoria: Avanzado/Opcional (Servicios para funciones especificas)
    [PSCustomObject]@{
        Name               = "TermService"
        Description        = (Get-AIOString 'catalog.services.desc.TermService')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "WMPNetworkSvc"
        Description        = (Get-AIOString 'catalog.services.desc.WMPNetworkSvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "DiagTrack"
        Description        = (Get-AIOString 'catalog.services.desc.DiagTrack')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Automatic"
	},
	[PSCustomObject]@{
        Name               = "lfsvc"
        Description        = (Get-AIOString 'catalog.services.desc.lfsvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
	},
	[PSCustomObject]@{
        Name               = "CscService"
        Description        = (Get-AIOString 'catalog.services.desc.CscService')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Automatic"
	},
	 [PSCustomObject]@{
        Name               = "StiSvc"
        Description        = (Get-AIOString 'catalog.services.desc.StiSvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "SSDPSRV"
        Description        = (Get-AIOString 'catalog.services.desc.SSDPSRV')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "upnphost"
        Description        = (Get-AIOString 'catalog.services.desc.upnphost')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "WbioSrvc"
        Description        = (Get-AIOString 'catalog.services.desc.WbioSrvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "WerSvc"
        Description        = (Get-AIOString 'catalog.services.desc.WerSvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "GraphicsPerfSvc"
        Description        = (Get-AIOString 'catalog.services.desc.GraphicsPerfSvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "Wecsvc"
        Description        = (Get-AIOString 'catalog.services.desc.Wecsvc')
        Category           = (Get-AIOString 'catalog.services.cat.adv')
        DefaultStartupType = "Manual"
    },
	# Red y Conectividad
	[PSCustomObject]@{
        Name               = "iphlpsvc"
        Description        = (Get-AIOString 'catalog.services.desc.iphlpsvc')
        Category           = (Get-AIOString 'catalog.services.cat.net')
        DefaultStartupType = "Automatic"
    },
    [PSCustomObject]@{
        Name               = "lmhosts"
        Description        = (Get-AIOString 'catalog.services.desc.lmhosts')
        Category           = (Get-AIOString 'catalog.services.cat.net')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "TapiSrv"
        Description        = (Get-AIOString 'catalog.services.desc.TapiSrv')
        Category           = (Get-AIOString 'catalog.services.cat.legacy')
        DefaultStartupType = "Manual"
    },
	# Legacy/Obsoleto
    [PSCustomObject]@{
        Name               = "WPDBusEnum"
        Description        = (Get-AIOString 'catalog.services.desc.WPDBusEnum')
        Category           = (Get-AIOString 'catalog.services.cat.legacy')
        DefaultStartupType = "Manual"
    },
	# Realidad Mixta
    [PSCustomObject]@{
        Name               = "MixedRealityOpenXRSvc"
        Description        = (Get-AIOString 'catalog.services.desc.MixedRealityOpenXRSvc')
        Category           = (Get-AIOString 'catalog.services.cat.mr')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "spectrum"
        Description        = (Get-AIOString 'catalog.services.desc.spectrum')
        Category           = (Get-AIOString 'catalog.services.cat.mr')
        DefaultStartupType = "Manual"
    },
	# Seguridad Corporativa
	[PSCustomObject]@{
        Name               = "Netlogon"
        Description        = (Get-AIOString 'catalog.services.desc.Netlogon')
        Category           = (Get-AIOString 'catalog.services.cat.corp')
        DefaultStartupType = "Manual"
    },
    # Categoria: Opcional
    [PSCustomObject]@{
        Name               = "XblAuthManager"
        Description        = (Get-AIOString 'catalog.services.desc.XblAuthManager')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "XblGameSave"
        Description        = (Get-AIOString 'catalog.services.desc.XblGameSave')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "XboxGipSvc"
        Description        = (Get-AIOString 'catalog.services.desc.XboxGipSvc')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
    },
    [PSCustomObject]@{
        Name               = "XboxNetApiSvc"
        Description        = (Get-AIOString 'catalog.services.desc.XboxNetApiSvc')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
    },
	[PSCustomObject]@{
        Name               = "WpcMonSvc"
        Description        = (Get-AIOString 'catalog.services.desc.WpcMonSvc')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
	},
	[PSCustomObject]@{
        Name               = "PhoneSvc"
        Description        = (Get-AIOString 'catalog.services.desc.PhoneSvc')
        Category           = (Get-AIOString 'catalog.services.cat.opt')
        DefaultStartupType = "Manual"
    }
)