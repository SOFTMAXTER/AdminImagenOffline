# Módulo de Actualizaciones — AdminImagenOffline

Integra actualizaciones offline en medios extraídos de Windows 10 y Windows 11.

El módulo clasifica paquetes CAB y MSU mediante identidades y contenido interno, crea un respaldo **Preflight** antes de modificar el medio, mantiene un orden de servicio verificable y genera reportes estructurados de cada operación.

## Contenido

- [Funciones principales](#funciones-principales)
- [Requisitos](#requisitos)
- [Ubicación del módulo](#ubicación-del-módulo)
- [Estructura del repositorio](#estructura-del-repositorio)
- [Categorías reconocidas](#categorías-reconocidas)
- [Uso](#uso)
- [Opciones del asistente](#opciones-del-asistente)
- [Orden y reaplicación CBS](#orden-y-reaplicación-cbs)
- [Preservación de idiomas](#preservación-de-idiomas)
- [Respaldo y restauración](#respaldo-y-restauración)
- [Verificaciones](#verificaciones)
- [Reportes y registros](#reportes-y-registros)
- [Mensajes finales](#mensajes-finales)
- [Solución de problemas](#solución-de-problemas)
- [Advertencias](#advertencias)

## Funciones principales

- Detecta medios con `install.wim` y `boot.wim`.
- Clasifica CAB y MSU por metadatos e identidades internas, sin depender de una lista fija de KB.
- Admite repositorio plano o subcarpetas por categoría.
- Detecta paquetes auxiliares UUP/CompDB y evita enviarlos directamente a `/Add-Package`.
- Procesa cadenas LCU con checkpoint MSU cuando corresponde.
- Actualiza `winre.wim` por separado y lo reinyecta dentro de `install.wim`.
- Puede actualizar todos los índices de `boot.wim`.
- Puede aplicar Setup Dynamic Update al medio y al índice Setup de `boot.wim`.
- Reaplica automáticamente paquetes CBS ya presentes sin desinstalarlos.
- Mantiene el orden planeado y registra el orden realmente ejecutado.
- Tolera consolidación y supersedencia normales de CBS.
- Maneja WinPE-Rejuv en compilaciones modernas.
- Sincroniza archivos de Setup y arranque sin degradar versiones existentes.
- Preserva `lang.ini`, carpetas de idioma y recursos MUI de los TrustedLocales.
- Puede exportar una sola edición cuando se selecciona un único índice.
- Puede reconstruir y optimizar todos los WIM.
- Puede usar `wimlib-imagex.exe` para ajustar la fecha interna de creación.
- Genera reportes JSON, HTML, registro DISM y diagnóstico ZIP.

## Requisitos

- Windows 10 o Windows 11.
- Windows PowerShell 5.1.
- Ejecución como **Administrador**.
- Medio de Windows extraído a una carpeta local escribible.
- `sources\install.wim`.
- Espacio libre suficiente para respaldo, montajes, staging de MSU y reconstrucción.
- No debe existir otra imagen montada.

### install.esd

Este módulo requiere `install.wim`. Si el medio contiene `install.esd`, conviértelo antes de ejecutar Actualizaciones. El módulo de Idiomas puede realizar esa conversión como parte de su flujo.

### ADK

El módulo detecta Windows ADK y utiliza la versión más reciente de DISM disponible. Si no encuentra ADK, puede utilizar DISM del sistema cuando resulte adecuado.

### wimlib opcional

Para ajustar `CREATIONTIME` interno debe existir:

```text
E:\windows\AdminImagenOffline\Tools\wimlib-imagex.exe
```

o una instalación accesible desde `PATH`.

Sin wimlib, la integración continúa y solamente se omite el ajuste de fecha interna.

## Ubicación del módulo

Estructura esperada:

```text
E:\windows\AdminImagenOffline\
├── Script\
│   └── Modulo-Actualizaciones.ps1
├── Actualizaciones\
├── Reportes\
├── Logs\
├── Tools\
└── config.json
```

Punto de entrada utilizado por AdminImagenOffline:

```powershell
WindowsUpdate-Menu
```

El módulo está diseñado para ejecutarse dentro de AdminImagenOffline.

## Estructura del repositorio

Repositorio predeterminado:

```text
E:\windows\AdminImagenOffline\Actualizaciones
```

Estructura opcional recomendada:

```text
Actualizaciones\
├── SSU\
├── LCU\
├── SafeOS\
├── SecureBoot\
├── SetupDU\
├── ESU\
├── Enablement\
├── OS\
├── DotNet\
├── WinPE\
└── Defender\
```

También se admite una carpeta plana. Las subcarpetas ayudan a expresar una categoría, pero la clasificación final utiliza metadatos internos siempre que están disponibles.

## Categorías reconocidas

### SSU

Servicing Stack Update independiente o extraíble de una LCU cuando el formato lo permite.

### LCU

Latest Cumulative Update. El módulo puede reconocer una cadena con checkpoint MSU y aplicar los paquetes en el orden correspondiente.

### SafeOS

Actualización para Windows Recovery Environment. Se procesa dentro de `winre.wim`.

### SecureBoot

Contenido asociado al mantenimiento de arranque seguro y archivos UEFI admitidos por el módulo.

### SetupDU

Setup Dynamic Update. Se fusiona en la superficie `sources` del medio y, cuando se actualiza `boot.wim`, también en el índice de Windows Setup.

### ESU

Paquetes Extended Security Updates. El módulo no elimina ni omite requisitos de licencia o activación.

### Enablement

Paquetes de habilitación que relacionan familias de servicio, por ejemplo 26100 y 26200.

### OS

CAB generales del sistema operativo. Los casos ambiguos se muestran para revisión.

### DotNet

Acumulativos de .NET Framework identificados por metadatos internos.

### WinPE

Paquetes específicos de Windows PE cuando son compatibles.

### Defender

Se procesan como plataforma o firmas de Defender, no como un paquete CBS genérico.

### Auxiliary

Archivos UUP o CompDB usados como apoyo para reconstrucción o clasificación. No se envían directamente a DISM `/Add-Package`.

## Uso

Desde el menú principal de AdminImagenOffline abre el módulo de Actualizaciones.

Menú interno:

```text
[1] Integrar actualizaciones
[2] Restaurar un respaldo Preflight
[V] Volver
```

### Flujo de integración

1. Selecciona la carpeta raíz del medio extraído.
2. Confirma o selecciona el repositorio de actualizaciones.
3. Revisa herramientas, categorías y clasificación detectada.
4. Selecciona uno, varios o todos los índices de `install.wim`.
5. Configura WinRE, `boot.wim`, SetupDU, limpieza y optimización.
6. Revisa el plan de ejecución.
7. Escribe `I` para iniciar.
8. Espera la verificación final.
9. Revisa el resumen y presiona `ENTER` para volver al menú.

## Opciones del asistente

### Actualizar y reinyectar winre.wim

Extrae `winre.wim` desde el índice correspondiente de `install.wim`, aplica SafeOS y los paquetes determinados por la política automática, verifica, optimiza y reinyecta el resultado.

La política LCU de WinRE es automática y depende de la compilación y de la disponibilidad de SafeOS.

### Actualizar boot.wim

Procesa todos los índices de `boot.wim`, preserva la estructura y sincroniza archivos de arranque.

### Aplicar Setup Dynamic Update

Actualiza la superficie `sources` del medio. Cuando `boot.wim` también se procesa, SetupDU se integra en el índice Setup.

### Reaplicación automática

Los paquetes con estado `Installed`, `InstallPending` o `Superseded` pueden enviarse nuevamente a DISM sin desinstalarlos.

CBS decide si:

- acepta la reaplicación;
- considera que no es necesaria;
- determina que no es aplicable.

### StartComponentCleanup

Ejecuta limpieza de componentes en `install.wim` y en las superficies configuradas por el flujo.

### ResetBase

Consolida componentes y evita su desinstalación posterior.

### Reconstruir y optimizar WIM

Exporta los índices con compresión máxima y verifica el reemplazo.

### CREATIONTIME

Cuando `wimlib-imagex.exe` está disponible, puede igualar el tiempo interno de creación con `LASTMODIFICATIONTIME`.

## Orden y reaplicación CBS

El módulo construye un plan por contexto y registra:

- posición planeada;
- posición ejecutada;
- categoría;
- paquete;
- dependencias CBS detectadas;
- restricciones;
- estado final (`Applied`, `Reapplied`, etc.).

Un orden habitual puede incluir:

```text
LCU checkpoint → LCU final → Enablement → DotNet
```

El orden exacto depende de las identidades y relaciones detectadas. El módulo no usa una lista fija de KB para decidir la secuencia.

### Supersedencia

Después de una LCU, CBS puede retirar, consolidar o marcar paquetes anteriores como superseded. Esto no se trata automáticamente como error. La verificación compara operaciones, identidades esperadas, inventario activo y evidencias semánticas.

## Preservación de idiomas

Antes de modificar el medio, el respaldo Preflight registra una política de idiomas basada en `sources\lang.ini`.

Ejemplo:

```json
"LocalePolicy": "LangIni",
"TrustedLocales": [
  "en-us",
  "es-mx"
]
```

Después de SetupDU y del mantenimiento de `boot.wim`, el módulo verifica por separado:

- TrustedLocales esperados;
- contenido de `sources\lang.ini`;
- carpetas localizadas;
- cantidad de archivos MUI;
- recursos esenciales de Windows Setup.

Esta validación es estructural. No se mezcla con el inventario de paquetes CBS.

## Respaldo y restauración

Antes del primer montaje se crea un respaldo similar a:

```text
C:\AdminImagenOffline_Backup\WIN11\AAAAMMdd_HHmmss\Preflight
```

El manifiesto Schema 3 contiene:

- raíz del medio;
- cobertura `AllFiles`;
- TrustedLocales;
- SHA-256 por archivo;
- hash índice del conjunto;
- número de archivos;
- tamaño total.

### Salida compacta

Todos los archivos se copian y verifican, pero la consola muestra de forma permanente principalmente `boot.wim`, `install.wim` y el resumen.

### Restauración manual

Selecciona:

```text
[2] Restaurar un respaldo Preflight
```

Ámbitos disponibles:

```text
[1] Todo el medio respaldado
[2] Solamente install.wim
[3] Solamente boot.wim
[4] Setup, sources y archivos de arranque
```

Para confirmar se debe escribir exactamente:

```text
RESTAURAR
```

### Restauración automática después de un fallo

Si el error ocurre después de iniciar cambios, el módulo ofrece restaurar el medio desde Preflight. La restauración se verifica antes de continuar.

## Verificaciones

El módulo comprueba, según el contexto:

- código de salida de DISM;
- operaciones planeadas y ejecutadas;
- identidades esperadas;
- inventario CBS antes y después;
- familia CBS observada;
- paquetes nuevos;
- paquetes retirados o consolidados;
- persistencia después del commit;
- hash de `winre.wim` reinyectado;
- estructura final de `install.wim`;
- estructura final de `boot.wim`;
- versiones y arquitectura;
- preservación de TrustedLocales, `lang.ini` y MUI;
- aplicación de SetupDU;
- sincronización de archivos de arranque.

El reporte distingue entre:

- versión final de la imagen;
- familia CBS observada.

No deben interpretarse como el mismo dato.

## Reportes y registros

Salidas habituales:

```text
E:\windows\AdminImagenOffline\Reportes\Actualizaciones\
├── Resultado_AIOU_AAAAMMDD_HHMMSS.json
├── Resultado_AIOU_AAAAMMDD_HHMMSS.html
└── Actualizaciones_AAAAMMDD_HHMMSS.log
```

Diagnósticos:

```text
E:\windows\AdminImagenOffline\Reportes\Diagnosticos\Actualizaciones\
└── Diagnostico_AIOU_AAAAMMDD_HHMMSS.zip
```

Los reportes incluyen:

- estado;
- duración;
- inventario de paquetes;
- imágenes finales;
- orden CBS;
- verificaciones;
- operaciones completadas;
- respaldo utilizado;
- error y fase, cuando corresponde.

## Mensajes finales

El módulo muestra una pantalla final obligatoria en:

- éxito;
- error;
- cancelación;
- restauración.

La pantalla puede mostrar:

- mensaje;
- fase;
- medio;
- respaldo;
- estado de restauración;
- diagnóstico;
- reportes;
- registro DISM;
- línea de error;
- operaciones completadas.

El módulo espera `ENTER` antes de regresar al menú principal.

## Solución de problemas

### El repositorio contiene CAB auxiliares

Los archivos UUP/CompDB clasificados como `Auxiliary` no son errores. Se usan como apoyo y no se envían directamente a `/Add-Package`.

### Se reaplica un paquete ya presente

Es el comportamiento configurado. El módulo lo envía de nuevo a DISM sin desinstalarlo y registra el resultado.

### El WIM mantiene una versión de imagen distinta de la familia CBS

Puede ser normal en una relación de mantenimiento, por ejemplo una imagen 26200 con familia CBS 26100. El reporte muestra ambos valores por separado.

### WinPE-Rejuv vuelve a aparecer

CBS puede conservar o restablecer una identidad neutral durante el mantenimiento. El módulo verifica identidades exactas y consolida los avisos. Revisa el reporte final antes de considerar esto un fallo.

### No aparece la opción de CREATIONTIME

Instala `wimlib-imagex.exe` en `Tools` o agrégalo a `PATH`. El resto del mantenimiento puede completarse sin esa herramienta.

### install.esd no es aceptado

Convierte el medio a `install.wim` antes de usar este módulo.

### El proceso tarda mucho

Las fases más lentas suelen ser:

- LCU grandes;
- commit de `install.wim`;
- verificación de montaje;
- reconstrucción con compresión máxima;
- respaldo SHA-256 completo.

No cierres la consola mientras DISM esté trabajando.

### El módulo regresó al menú después de un error

La versión actual muestra un resumen final y espera `ENTER`. Verifica que `Modulo-Actualizaciones.ps1` sea la versión más reciente.

## Advertencias

- Conserva el respaldo Preflight hasta probar el medio.
- No interrumpas DISM durante montaje, commit, exportación o restauración.
- `ResetBase` impide desinstalar actualizaciones consolidadas.
- Los paquetes ESU siguen sujetos a sus requisitos de licencia y activación.
- No mezcles paquetes de arquitecturas o familias incompatibles sin revisar la clasificación.
- Prueba el medio final en una máquina virtual antes de desplegarlo.
