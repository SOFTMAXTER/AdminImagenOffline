# Paquetes de Idioma — AdminImagenOffline

AdminImagenOffline detecta automáticamente el idioma del sistema anfitrión (`[System.Globalization.CultureInfo]::CurrentUICulture`) al iniciar y carga el paquete correspondiente desde esta carpeta `Lang\`.

## Cómo funciona la detección

1. **Preferencia guardada (`config.json`):** Si `"Language"` está en `"auto"` (predeterminado), se usa el idioma de Windows. También puedes elegir un idioma manualmente desde **[R] Configuración → [3] Idioma de la Interfaz**.
2. **Resolución en cascada:** Si Windows está en `pt-BR`, primero busca `Lang\pt-BR.json`; si no existe, busca `Lang\pt.json`; si tampoco existe, usa `Lang\es.json`.
3. **Respaldo por clave:** Si a una traducción le falta alguna clave nueva, se muestra automáticamente el texto de `Lang\es.json` en lugar de dejarla vacía.

## Cómo crear una traducción nueva (ejemplo: portugués `pt.json`)

1. Copia `Lang\en.json` (o `Lang\es.json`) y renómbralo con el código ISO del idioma, por ejemplo `Lang\pt.json` o `Lang\fr.json`.
2. Edita el bloque `_meta` al inicio del archivo:
   ```json
   "_meta": {
     "code": "pt",
     "name": "Portuguese",
     "nativeName": "Português",
     "version": "1.5.15",
     "author": "Tu Nombre"
   }
   ```
3. Traduce solo los **valores** (a la derecha de `:`). No modifiques los nombres de las claves ni los marcadores `{0}`, `{1}` que insertan rutas, números o versiones.
4. Guarda el archivo en **UTF-8**.
5. Abre AdminImagenOffline: el nuevo idioma aparecerá automáticamente en **[R] Configuración → [3] Idioma de la Interfaz** y se activará solo en sistemas Windows con ese idioma.

## Uso en nuevos módulos PowerShell

```powershell
Write-Host (Get-AIOString 'menu.main.title') -ForegroundColor Cyan
Write-Host (Get-AIOString 'save.commit_start' $Script:MOUNTED_INDEX) -ForegroundColor Yellow

# Validación de respuestas S/N o Y/N
if (Test-AIOYesResponse $respuesta) { ... }
```
