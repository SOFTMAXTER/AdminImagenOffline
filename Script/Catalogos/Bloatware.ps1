# --- CATALOGO DE APLICACIONES (BLOATWARE VS SEGURAS) ---
# Define las listas de apps para la herramienta de limpieza.

$script:AppLists = @{
    
    # 1. LISTA BLANCA (VERDE): Apps del sistema que NO se deben borrar
    #    Borrar estas puede romper la tienda, calculas o visualizacion de imagenes.
    Safe = @(
        "Microsoft.WindowsStore"
        "Microsoft.WindowsCalculator"
        "Microsoft.Windows.Photos"
        "Microsoft.Windows.Camera"
        "Microsoft.SecHealthUI"
        "Microsoft.UI.Xaml"
        "Microsoft.VCLibs"
        "Microsoft.NET.Native"
        "Microsoft.WebpImageExtension"
        "Microsoft.HEIFImageExtension"
        "Microsoft.VP9VideoExtensions"
        "Microsoft.ScreenSketch"
        "Microsoft.WindowsTerminal"
        "Microsoft.Paint"
        "Microsoft.WindowsNotepad"
    )

    # 2. LISTA NEGRA (NARANJA): Bloatware recomendado para borrar
    #    Publicidad, pruebas, apps de terceros preinstaladas, etc.
    Bloat = @(
        "Microsoft.Microsoft3DViewer"
        "Microsoft.BingSearch"
        "Microsoft.WindowsAlarms"
        "Microsoft.549981C3F5F10" # Check Experience
        "Microsoft.Windows.DevHome"
        "MicrosoftCorporationII.MicrosoftFamily"
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.Edge.GameAssist"
        "Microsoft.GetHelp"
        "Microsoft.Getstarted"
        "microsoft.windowscommunicationsapps" # Correo y Calendario
        "Microsoft.WindowsMaps"
        "Microsoft.MixedReality.Portal"
        "Microsoft.BingNews"
        "Microsoft.MicrosoftOfficeHub"
        "Microsoft.Office.OneNote"
        "Microsoft.MSPaint" # Paint 3D (diferente al Paint clasico)
        "Microsoft.People"
        "Microsoft.PowerAutomateDesktop"
        "Microsoft.SkypeApp"
        "Microsoft.MicrosoftSolitaireCollection"
        "Microsoft.MicrosoftStickyNotes"
        "MicrosoftTeams"
        "MSTeams"
        "Microsoft.Todos"
        "Microsoft.Wallet"
        "Microsoft.BingWeather"
        "Microsoft.Xbox.TCUI"
        "Microsoft.XboxApp"
        "Microsoft.XboxGameOverlay"
        "Microsoft.XboxGamingOverlay"
        "Microsoft.XboxIdentityProvider"
        "Microsoft.XboxSpeechToTextOverlay"
        "Microsoft.GamingApp"
        "Microsoft.ZuneMusic"
        "Microsoft.ZuneVideo"
        "Clipchamp.Clipchamp"
        "Microsoft.BingSports"
        "Microsoft.BingFinance"
        "Microsoft.WindowsSoundRecorder"
        "Microsoft.YourPhone"
    )
}
