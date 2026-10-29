#!/bin/bash

#=======================================================#
# Este script es para limpiar los logs del servidor     #
# Mesa: 4                                               #
# Institución: Complejo Educativo Residencial Altavista #
# Docente: Franklin David Barahona López                #
#=======================================================#

set -euo pipefail

ruta="/var/log/mi_servidor"

#============================================#
# COMPROBAR SI SE EJECUTA COMO SUPERUSUARIO. #
#============================================#
if [[ "$EUID" -ne 0 ]]; then
    echo "Se necesitan permisos de superusuario."
    
    if ! command -v sudo >/dev/null 2>&1; then
        echo "Error: sudo no está instalado"
        exit 1
    fi
    
    script_path="$(readlink -f -- "$0")"
    exec sudo -- bash "$script_path" "$@"
fi

#===========================================================#  
# COMPROBAR QUE LA RUTA EXISTE Y NO ES UN ENLACE SIMBÓLICO. #
#===========================================================#
if [[ ! -d "$ruta" || -L "$ruta" ]]; then
    echo "Error: la carpeta no existe o no es segura: $ruta"
    exit 1
fi

#========================================================#  
# BUSCAR ARCHIVOS .LOG Y TXT DIRECTAMENTE EN LA CARPETA. #
#========================================================#  
mapfile -d '' archivos < <(
    find "$ruta" -maxdepth 1 -type f \
    \( -name '*.log' -o -name '*.txt' \) -print0
)    

echo "Carpeta: $ruta"
echo "Archivos que se eliminarán: ${#archivos[@]}"

#===========================================#
# SI NO HAY ARCHIVOS, NO HAY NADA QUE HACER #
#===========================================#
if [[ ${#archivos[@]} -eq 0 ]]; then
    echo "No hay archivos . log ni .txt para eliminar."
    exit 0
fi

#============================================#
# MOSTRAR LOS ARCHIVOS ANTES DE ELIMINARLOS. #
#============================================#
printf '  %s\n' "${archivos[@]##*/}"

#===================================#
# SOLICITAR CONFIRMACIÓN EXPLÍCITA. #
#===================================#
read -r -p '¿Seguro que quieres eliminar estos archivos? Escribe SI para confirmar: ' respuesta

if [[ "$respuesta" != "SI" ]]; then
    echo "Operación cancelada. No se ha eliminado ningún archivo."
    exit 0
fi    

#=================================================#
# ELIMINAR ÚNICAMENTE LOS ARCHIVOS SELECCIONADOS. #
#=================================================#
rm -f -- "${archivos[@]}"

#=======================#
# MOSTRAR EL RESULTADO. #
#=======================#
restantes=$(find "$ruta" -maxdepth 1 -type f | wc -l)

echo "Limpieza finalizada."
echo "Archivos eliminados: ${#archivos[@]}"
echo "Archivos regulares restantes en la carpeta: $restantes"

