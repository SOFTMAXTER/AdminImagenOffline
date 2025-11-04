# AdminImagenOffline V1.3 by SOFTMAXTER

**AdminImagenOffline** es un completo script en PowerShell, diseñado para simplificar la administración y el mantenimiento de imágenes de instalación de Windows (`.wim`, `.esd`, `.vhd/vhdx`). El script encapsula complejas operaciones de `DISM` y otras herramientas del sistema en una interfaz de menús interactiva y fácil de usar.

Fue creado para administradores de TI, técnicos de soporte y entusiastas de la personalización de Windows que necesitan modificar, limpiar, reparar o convertir imágenes del sistema operativo de manera eficiente y sin conexión.

## Características Principales

* **Interfaz Guiada por Menús**: Todas las funciones están organizadas en menús y submenús claros y fáciles de navegar, con un estilo visual profesional.
* **Auto-Actualizador**: El script busca automáticamente nuevas versiones en GitHub al iniciar y ofrece al usuario la posibilidad de actualizarse.
* **Configuración Persistente**: Guarda las rutas de trabajo (Directorio de Montaje y Directorio Temporal) en un archivo `config.json` para que las preferencias del usuario sean permanentes.
* **Gestión de Directorios**: Comprueba si los directorios de trabajo (Montaje y Temporal) existen al inicio. Si no existen, ofrece crearlos automáticamente o permite al usuario seleccionar una nueva ubicación.
* **Detección Automática**: Verifica al inicio si ya existe una imagen montada en el sistema y carga su información dinámicamente (ruta, índice).
* **Autoelevación de Privilegios**: El script `Run.bat` incluido comprueba si se está ejecutando como Administrador y, de no ser así, intenta reiniciarse con los permisos necesarios.
* **Gestión de Imágenes**:
    * **Montaje/Desmontaje**: Permite montar un índice específico de un archivo WIM en un directorio local configurable y desmontarlo.
    * **Guardado de Cambios**: Ofrece la opción de guardar los cambios en el índice actual o crear un nuevo índice con las modificaciones (append).
    * **Recarga de Imagen**: Descarta todos los cambios no guardados desmontando y volviendo a montar la imagen rápidamente.
* **Edición de Índices WIM**:
    * **Exportar Índice**: Permite guardar un índice específico de un archivo WIM en un nuevo archivo WIM de destino.
    * **Eliminar Índice**: Ofrece la capacidad de borrar de forma permanente un índice de un archivo WIM.
* **Conversión de Formatos de Imagen**:
    * **ESD a WIM**: Convierte un índice específico de un archivo `.esd` (Electronic Software Download) a un archivo `.wim` con compresión máxima.
    * **VHD/VHDX a WIM**: Monta automáticamente un disco duro virtual (`.vhd` o `.vhdx`), captura su contenido en un nuevo archivo `.wim` y lo desmonta al finalizar.
* **Cambio de Edición de Windows**:
    * Detecta automáticamente la versión del SO (Windows 7/8.1/10/11) y la edición actual de la imagen montada.
    * Muestra las ediciones de destino a las que se puede actualizar y realiza el cambio con un solo comando.
* **Suite de Limpieza y Reparación**:
    * Integra las funciones más importantes de `DISM /Cleanup-Image` y `SFC` para imágenes offline.
    * **Reparación con Fuente Alternativa**: Si `DISM /RestoreHealth` falla, el script ofrece automáticamente la opción de especificar un archivo `install.wim` como fuente de reparación alternativa.
    * Permite ejecutar análisis, verificaciones, reparaciones y limpieza del almacén de componentes de forma individual o todas a la vez.

---

## Requisitos

* Sistema Operativo Windows.
* PowerShell 5.1 o superior.
* Privilegios de Administrador para ejecutar el script.
* Conexión a internet (opcional, para el auto-actualizador).

---

## Modo de Uso

1.  Descarga la estructura de carpetas (el archivo `Run.bat` debe estar en el directorio raíz y `AdminImagenOffline.ps1` dentro de la carpeta `Script`).
2.  Haz clic derecho sobre el archivo `Run.bat` y selecciona **"Ejecutar como administrador"**. El script validará los permisos e iniciará el entorno de PowerShell.
3.  Sigue las instrucciones en pantalla, seleccionando las opciones numéricas de los menús.
4.  Si es la primera ejecución, ve al menú **[4] Configurar Rutas de Trabajo** para definir tus directorios de Montaje y Temporal.

---

## Explicación Detallada de los Menús

### Menú Principal

Al iniciar, se muestra el estado actual (rutas, imagen montada) y las categorías principales de herramientas.

* **1. Gestionar Imagen**: Accede al submenú para operaciones de montaje, guardado, edición y conversión de la imagen WIM.
* **2. Cambiar Edicion de Windows**: Permite cambiar la edición de una imagen previamente montada.
* **3. Herramientas de Limpieza**: Accede a las utilidades de mantenimiento y reparación de la imagen.
* **4. Configurar Rutas de Trabajo**: Permite cambiar y guardar permanentemente las rutas para el Directorio de Montaje (ej. `D:\TEMP`) y el Directorio Temporal (ej. `D:\Scratch`).
* **L. Ver Registro de Actividad**: Abre el archivo `.log` con un registro de todas las acciones realizadas.

### 1. Gestión de Imagen

#### → 1. Montar/Desmontar Imagen
* `1. Montar Imagen`: Solicita la ruta a un archivo `.wim` o `.esd` y el número de índice. Lo monta en el `MOUNT_DIR` configurado.
* `2. Desmontar Imagen`: Ejecuta `dism /unmount-wim /discard` para desmontar la imagen, descartando cualquier cambio no guardado.
* `3. Recargar Imagen (Descartar cambios)`: Desmonta la imagen actual sin guardar (`/discard`) y la vuelve a montar usando la misma ruta e índice.

#### → 2. Guardar Cambios
* `1. Guardar cambios en el Indice actual`: Ejecuta `dism /commit-image` para guardar las modificaciones.
* `2. Guardar cambios en un nuevo Indice (Append)`: Usa la opción `/append` para crear un nuevo índice en el WIM con los cambios.

#### → 3. Editar Índices
* `1. Exportar un Indice`: Exporta un índice de un WIM existente a un nuevo archivo WIM.
* `2. Eliminar un Indice`: Elimina permanentemente un índice del archivo WIM.

#### → 4. Convertir Imagen a WIM
* `1. Convertir ESD a WIM`: Pide un `.esd` y el índice, y lo convierte a `.wim` (`/Compress:max /CheckIntegrity`).
* `2. Convertir VHD/VHDX a WIM`: Monta un VHD/VHDX, captura el contenido con `dism /capture-image` y lo desmonta.

### 2. Cambiar Edición de Windows

Esta opción solo está disponible si hay una imagen montada.

1.  **Obtención de Información**: Carga temporalmente el hive del registro (`SOFTWARE`) de la imagen para leer la versión y el build.
2.  **Listado de Ediciones de Destino**: Ejecuta `dism /Image:%MOUNT_DIR% /Get-TargetEditions` para mostrar las actualizaciones posibles.
3.  **Cambio de Edición**: Ejecuta `dism /Image:%MOUNT_DIR% /Set-Edition` para aplicar el cambio.

### 3. Herramientas de Limpieza

Requiere una imagen montada. Ofrece un menú con las siguientes herramientas:

* **1. Verificar Salud de Imagen**: `DISM /... /CheckHealth`.
* **2. Escaneo Avanzado de Salud**: `DISM /... /ScanHealth`.
* **3. Reparar Imagen**: `DISM /... /RestoreHealth`.
    * **¡NUEVO!** Si este comando falla, el script preguntará si deseas reintentar la operación usando un archivo `install.wim` como fuente de reparación alternativa.
* **4. Escaneo y Reparacion SFC**: `SFC /scannow /offwindir=%MOUNT_DIR%\Windows`. (Corregido para usar la sintaxis correcta para imágenes montadas).
* **5. Analizar Almacen de Componentes**: `DISM /... /AnalyzeComponentStore`.
* **6. Limpieza de Componentes**: `DISM /... /StartComponentCleanup /ResetBase` usando el `Scratch_DIR` configurado.
* **7. Ejecutar Todas las Opciones**: Ejecuta las tareas 1-6 en secuencia.

## Notas Importantes

* **COPIA DE SEGURIDAD:** Es **altamente recomendable** realizar una copia de seguridad de tu imagen de Windows antes de utilizar las funciones de cambio de edición o reparación.
* **CONOCIMIENTOS TÉCNICOS:** Se recomienda tener conocimientos básicos sobre DISM, SFC y la administración de imágenes de Windows.
* **IDIOMA:** El script y sus mensajes en consola están en español.

## Descargo de Responsabilidad

Este script realiza operaciones avanzadas que modifican archivos de imagen de Windows. El autor, **SOFTMAXTER**, no se hace responsable de la pérdida de datos o daños que puedan ocurrir en tus archivos WIM.

**Se recomienda encarecidamente crear una copia de seguridad de tus archivos `.wim` antes de utilizar esta herramienta.**

## Autor

* **SOFTMAXTER**

---
### Cómo Contribuir

Si deseas contribuir al desarrollo de este script:

1.  Haz un Fork del repositorio.
2.  Crea una nueva rama (`git checkout -b feature/nueva-funcionalidad`).
3.  Realiza tus cambios y haz commit (`git commit -am 'Añade nueva funcionalidad'`).
4.  Haz Push a la rama (`git push origin feature/nueva-funcionalidad`).
5.  Abre un Pull Request.
