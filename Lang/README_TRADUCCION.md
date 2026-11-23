# Paquetes de Idioma — AdminImagenOffline

AdminImagenOffline detecta automáticamente el idioma del sistema anfitrión (`[System.Globalization.CultureInfo]::CurrentUICulture`) al iniciar y carga el paquete correspondiente desde esta carpeta `Lang\`.

## Cómo funciona la detección

1. **Preferencia guardada (`config.json`):** Si `"Language"` está en `"auto"` (predeterminado), se usa el idioma de Windows. La preferencia se lee de forma temprana al arrancar (incluso antes de los avisos de administrador, instancia única y rutas largas) y puede cambiarse en caliente desde **[C] Configuración → [3] Idioma de la Interfaz**, invalidando automáticamente la caché del Dashboard y del catálogo de ediciones.
2. **Resolución en cascada:** Si Windows está en `pt-BR`, primero busca `Lang\pt-BR.json`; si no existe, busca `Lang\pt.json`; si tampoco existe, usa `Lang\es.json`.
3. **Respaldo por clave y tolerancia a fallos:** Si a una traducción le falta alguna clave nueva, se muestra automáticamente el texto de `Lang\es.json`. Si faltara el archivo `Script\I18n.ps1`, el orquestador activa funciones de respaldo para mostrar `[clave]` sin generar errores en cadena.
4. **Registros técnicos:** Los logs forenses (`Logs\Registro.log` y registros internos de `IsoMaker`, `Actualizaciones` y `Lenguajes`) y el parseo de `DISM /English` permanecen en su idioma técnico original por diseño para facilitar el soporte y la depuración.

## Cómo crear una traducción nueva (ejemplo: portugués `pt.json`)

1. Copia `Lang\en.json` (o `Lang\es.json`) y renómbralo con el código ISO del idioma, por ejemplo `Lang\pt.json` o `Lang\fr.json`.
2. Edita el bloque `_meta` al inicio del archivo:
   ```json
   "_meta": {
     "code": "pt",
     "name": "Portuguese",
     "nativeName": "Português",
     "author": "Tu Nombre"
   }
   ```
3. Traduce solo los **valores** (a la derecha de `:`). No modifiques los nombres de las claves ni los marcadores `{0}`, `{1}` que insertan rutas, números o versiones.
4. Guarda el archivo en **UTF-8**.
5. Abre AdminImagenOffline: el nuevo idioma aparecerá automáticamente en **[C] Configuración → [3] Idioma de la Interfaz** y se activará solo en sistemas Windows con ese idioma.

## Uso en nuevos módulos PowerShell

```powershell
Write-Host (Get-AIOString 'menu.main.title') -ForegroundColor Cyan
Write-Host (Get-AIOString 'save.commit_start' $Script:MOUNTED_INDEX) -ForegroundColor Yellow

# Mensajes de error con marcadores {0}, {1}: se pasan con -FormatArgs
throw (Get-AIOString 'errors.e024' -FormatArgs @($partes, $encontradas))

# Menús de consola (↑/↓, Enter y Retroceso); el pie de teclas usa las claves common.nav_hint_*
$items = @(@{ Value = 'A'; Label = (Get-AIOString 'menu.main.opt1') })
$opcion = [string](Show-AIOConsoleMenu -Items $items -AllowBack -BackValue 'V')

# Validación de respuestas S/N o Y/N
if (Test-AIOYesResponse $respuesta) { ... }
```
