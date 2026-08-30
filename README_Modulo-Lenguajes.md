# Módulo de Idiomas — AdminImagenOffline

Integra paquetes de idioma, características lingüísticas y recursos localizados en medios extraídos de Windows 10 y Windows 11.

El módulo trabaja de forma transaccional: antes de la primera modificación crea un respaldo **Preflight**, verifica todos los archivos mediante SHA-256 y puede restaurar el medio si una operación falla.

## Contenido

- [Funciones principales](#funciones-principales)
- [Requisitos](#requisitos)
- [Ubicación del módulo](#ubicación-del-módulo)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Uso](#uso)
- [Opciones del asistente](#opciones-del-asistente)
- [Compatibilidad de WinPE](#compatibilidad-de-winpe)
- [Respaldo y restauración](#respaldo-y-restauración)
- [Verificaciones](#verificaciones)
- [Reportes y registros](#reportes-y-registros)
- [Mensajes finales](#mensajes-finales)
- [Solución de problemas](#solución-de-problemas)
- [Advertencias](#advertencias)

## Funciones principales

- Detecta `install.wim` o convierte `install.esd` a WIM antes del mantenimiento.
- Permite seleccionar uno, varios o todos los índices de `install.wim`.
- Detecta paquetes de idioma CAB o ESD mediante nombre, estructura y metadatos internos.
- Detecta y ordena Language Features on Demand por identidad CBS.
- Detecta Windows ADK, WinPE Add-on y la versión más reciente de DISM disponible.
- Valida idioma, arquitectura y familia de compilación antes de modificar el medio.
- Integra primero el Language Pack y después sus características dependientes.
- Puede actualizar `winre.wim` cuando existen componentes WinPE compatibles.
- Puede actualizar todos los índices de `boot.wim`.
- Identifica el índice de Windows Setup mediante metadatos, paquetes WinPE Setup, `setup.exe`, `winpeshl.ini` y un fallback seguro al índice 2.
- Genera y sincroniza `sources\lang.ini`.
- Copia recursos MUI de Windows Setup.
- Aplica un modo de compatibilidad cuando no existe un WinPE Add-on de la misma familia.
- Verifica paquetes CBS, `/Get-Intl`, `lang.ini` y recursos MUI antes y después del commit.
- Puede conservar el idioma actual o establecer uno nuevo como predeterminado.
- Puede exportar una sola edición cuando se selecciona un único índice.
- Puede reconstruir los WIM con compresión máxima.
- Genera reportes JSON, HTML, registro DISM y diagnóstico ZIP.

## Requisitos

- Windows 10 o Windows 11.
- Windows PowerShell 5.1.
- Ejecución como **Administrador**.
- Medio de Windows extraído a una carpeta local con permisos de escritura.
- Espacio libre suficiente para:
  - respaldo Preflight;
  - montajes temporales;
  - reconstrucción de WIM;
  - extracción de ESD y CAB.
- No debe existir otra imagen WIM montada por AdminImagenOffline o DISM.

### ADK y WinPE Add-on

El módulo puede usar DISM del sistema, pero detecta y prefiere una versión más reciente de DISM incluida en Windows ADK.

Para una traducción completa de WinPE, el WinPE Add-on debe coincidir con:

- arquitectura del medio;
- idioma seleccionado;
- familia de compilación compatible.

Un WinPE Add-on incompatible no se fuerza dentro de la imagen.

## Ubicación del módulo

Estructura esperada:

```text
E:\windows\AdminImagenOffline\
├── Script\
│   └── Modulo-Lenguajes.ps1
├── Lenguajes\
├── Reportes\
├── Logs\
└── config.json
```

Punto de entrada utilizado por AdminImagenOffline:

```powershell
LanguagePack-Menu
```

El módulo está diseñado para cargarse desde AdminImagenOffline. No se recomienda ejecutarlo de forma aislada sin inicializar previamente las variables y directorios del programa principal.

## Estructura del repositorio

El repositorio predeterminado es:

```text
E:\windows\AdminImagenOffline\Lenguajes
```

Estructura recomendada:

```text
Lenguajes\
├── LanguagePacks\
│   ├── x64\
│   └── x86\
├── FeaturesOnDemand\
│   ├── x64\
│   └── x86\
└── WinPE\
    ├── amd64\WinPE_OCs\
    └── x86\WinPE_OCs\
```

También se admite una carpeta plana. El módulo clasifica los archivos por metadatos internos, identidad CBS, arquitectura, idioma y versión.

### Tipos de paquetes reconocidos

- Language Pack de cliente.
- Language Features on Demand:
  - Basic;
  - Handwriting;
  - OCR;
  - Speech;
  - TextToSpeech;
  - otros componentes lingüísticos reconocibles por identidad.
- Componentes WinPE localizados.
- Recursos de Windows Setup contenidos en el payload del idioma.

## Uso

Desde el menú principal de AdminImagenOffline abre el módulo de Idiomas.

Menú interno:

```text
[1] Integrar idiomas / crear medio multilingüe
[2] Restaurar un respaldo Preflight
[V] Volver al menú principal
```

### Flujo de integración

1. Selecciona la carpeta raíz del medio extraído.
2. Confirma o selecciona el repositorio de idiomas.
3. Revisa el resumen de ADK, DISM, paquetes y compatibilidad WinPE.
4. Selecciona los índices de `install.wim`.
5. Selecciona uno o varios idiomas.
6. Selecciona el idioma predeterminado.
7. Configura las opciones del asistente.
8. Revisa el plan de ejecución.
9. Escribe `I` para iniciar.
10. Espera el resumen final y presiona `ENTER` para volver al menú.

## Opciones del asistente

### Integrar Features on Demand

Agrega las características lingüísticas detectadas y compatibles. El módulo instala primero el Language Pack y después los componentes dependientes.

### Actualizar winre.wim

Solo aparece como opción efectiva cuando existen paquetes WinPE compatibles con la arquitectura y familia del medio.

### Actualizar boot.wim

Puede funcionar de dos maneras:

- **FullWinPE**: integra paquetes WinPE compatibles y recursos localizados.
- **SetupResourcesOnly**: cuando no hay paquetes WinPE compatibles, integra `lang.ini` y recursos MUI en el índice de Windows Setup.

### StartComponentCleanup

Ejecuta:

```text
/Cleanup-Image /StartComponentCleanup
```

### ResetBase

Añade `/ResetBase`. Después de usarlo, los componentes consolidados no pueden desinstalarse individualmente.

### Reconstruir y optimizar WIM

Exporta los índices con compresión máxima y reemplazo controlado del archivo original.

### Exportar una sola edición

Cuando se selecciona un único índice, permite crear un `install.wim` con esa sola edición. El índice exportado pasa a ser el índice 1.

## Compatibilidad de WinPE

El módulo distingue entre:

- paquetes WinPE encontrados;
- paquetes compatibles;
- paquetes incompatibles por arquitectura o familia.

Ejemplo de escenario válido:

```text
Medio: familia 26100/26200
WinPE Add-on: familia 28000
Paquetes compatibles: 0
```

En ese caso no se integran paquetes WinPE 28000 dentro de una imagen 26100. Si el usuario habilita la compatibilidad de Setup, se aplica `SetupResourcesOnly`.

### Alcance de SetupResourcesOnly

Este modo habilita el selector de idiomas de Windows Setup mediante:

- `sources\lang.ini`;
- carpetas de idioma;
- recursos MUI esenciales de Setup.

No afirma que todo WinPE haya sido traducido. El resumen final muestra una advertencia cuando faltan paquetes WinPE completos.

## Respaldo y restauración

Antes de la primera modificación se crea un respaldo en una ruta similar a:

```text
C:\AdminImagenOffline_Backup\WIN11\AAAAMMdd_HHmmss\Preflight
```

El respaldo incluye un `manifest.json` Schema 3 con:

- raíz del medio;
- idiomas seleccionados;
- algoritmo SHA-256;
- cobertura de archivos y árboles de directorios;
- número de archivos;
- tamaños;
- hashes individuales y de índice.

La consola usa salida compacta. Todos los archivos se copian y verifican, aunque solo se muestren permanentemente los WIM principales y el resumen final.

### Restauración manual

Selecciona:

```text
[2] Restaurar un respaldo Preflight
```

Después selecciona directamente la carpeta `Preflight`. El módulo valida el manifiesto y los hashes antes de restaurar.

### Restauración después de un error

Si el fallo ocurre después de iniciar cambios en el medio, el módulo ofrece restaurarlo desde Preflight. El resumen final indica uno de estos estados:

- `Restaurado y verificado`;
- `No solicitada por el usuario`;
- `No requerida; el medio no fue modificado`;
- `Fallo: <motivo>`.

## Verificaciones

El éxito no depende únicamente del código de salida de DISM.

El módulo comprueba, según el modo utilizado:

- presencia de Language Packs y FOD en el catálogo CBS;
- configuración internacional mediante `/Get-Intl`;
- existencia y contenido de `sources\lang.ini`;
- presencia de carpetas de idioma;
- recursos MUI esenciales de Windows Setup;
- identidad del índice Setup;
- persistencia de los cambios después del commit y reconstrucción;
- estructura final de `install.wim` y `boot.wim`.

Los índices de `boot.wim` que no fueron modificados se omiten en la verificación final.

## Reportes y registros

Salidas habituales:

```text
E:\windows\AdminImagenOffline\Reportes\Idiomas\
├── Idiomas_AAAAMMDD_HHMMSS.json
├── Idiomas_AAAAMMDD_HHMMSS.html
├── DISM_Idiomas_AAAAMMDD_HHMMSS.log
└── Diagnostico_AAAAMMDD_HHMMSS.zip
```

El ZIP de diagnóstico se genera ante errores e incluye la información disponible antes de limpiar la sesión temporal.

## Mensajes finales

El módulo muestra un resumen obligatorio en:

- éxito;
- error;
- cancelación;
- restauración.

La pantalla final incluye, cuando están disponibles:

- estado;
- fase;
- medio;
- respaldo;
- restauración;
- diagnóstico;
- reportes;
- registro DISM;
- línea del error;
- operaciones completadas.

El módulo espera `ENTER` antes de devolver el control al menú principal.

## Solución de problemas

### No se detectan idiomas

- Verifica que el repositorio contenga CAB o ESD válidos.
- Comprueba que la arquitectura coincida con el medio.
- Revisa el resumen de inventario y el reporte JSON.

### El idioma aparece en install.wim, pero no en Windows Setup

- Confirma que `boot.wim` haya sido procesado.
- Revisa si se aplicó `FullWinPE` o `SetupResourcesOnly`.
- Revisa `sources\lang.ini`.
- Comprueba los recursos MUI del índice Setup.

### No hay paquetes WinPE compatibles

Instala un WinPE Add-on de la familia adecuada o usa `SetupResourcesOnly` para habilitar el selector de Setup sin traducir completamente WinPE.

### DISM informa que una imagen ya está montada

Desmonta o descarta cualquier montaje anterior antes de iniciar. No elimines manualmente una carpeta de montaje sin liberar primero el registro de DISM.

### Falta espacio libre

El proceso puede necesitar temporalmente más espacio que el tamaño de `install.wim`, debido al respaldo, montaje, extracción y reconstrucción.

### El módulo regresó al menú después de un error

La versión actual muestra primero un resumen final y espera `ENTER`. Revisa que el archivo instalado sea la versión más reciente del módulo.

## Advertencias

- No trabajes directamente sobre una ISO montada en modo lectura.
- No interrumpas DISM durante `Commit`, `Export-Image` o restauración.
- `ResetBase` impide desinstalar componentes consolidados.
- Conserva el respaldo Preflight hasta completar pruebas de instalación.
- Prueba el medio final en una máquina virtual antes de usarlo en producción.
- Después de integrar idiomas, ejecuta el módulo de Actualizaciones para aplicar LCU, SafeOS, SetupDU y demás paquetes.
