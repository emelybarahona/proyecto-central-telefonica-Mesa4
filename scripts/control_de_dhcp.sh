#!/bin/bash

#=====================================================================#
# Script: control_dhcp.sh                                             #
# Función: Control seguro del servicio DHCP mediante Keepalived.      #
# Estados: Master, Backup, Fault                                     #
# Sistemas: Zentyal / Ubuntu Server                                   #
# Características: Idempotente, valido y con confirmación interactiva #
#=====================================================================#

set -Eeuo pipefail

#==========================#
# Colores para la terminal #
#==========================#

ROJO='\033[0;31m'
VERDE='\033[0;32m'
AMARILLO='\033[0;33m'
AZUL='\033[0;34m'
NC='\033[0m'

readonly SCRIPT_NAME="control_dhcp"
readonly LOCK_FILE="/run/control_dhcp.lock"

#===========================================================#
# MOSTRAR MENSAJE EN PANTALLA Y REGISTRAR EVENTOS EN SYSLOG #
#===========================================================#
log() {
    local color="$1"
    local nivel="$2"
    shift 2
    
    printf '%b[%s] %s%b\n' "$color" "$nivel" "$*" "$NC"
    logger -t "$SCRIPT_NAME" -- "[$nivel] $*" 2>/dev/null || true
}

#=====================================================#
# COMPROBAR SI EL SCRIPT SE EJECUTA COMÓ SUPERUSUARIO #
#=====================================================#
if [[ "$EUID" -ne 0 ]]; then
    printf '%bERROR: debes ejecutar este script como superusuario.%b\n' \
        "$ROJO" "$NC"
    printf 'Ejemplo: sudo %s MASTER\n' "$0"
    exit 1
fi

log "$VERDE" "OK" "Ejecutando como superusuario (root)."

#======================#
# VALIDAR EL ARGUMENTO #
#======================#
if [[ $# -ne 1 ]]; then
    log "$ROJO" "ERROR" "Debes indicar el estado del nodo."
    printf 'Uso: %s MASTER|BACKUP|FAULT\n' "$0"
    exit 2
fi

ESTADO="${1^^}"

case "$ESTADO" in
    MASTER|BACKUP|FAULT)
        ;;
    *)
        log "$ROJO" "ERROR" "Estado no valido: $ESTADO"
        printf 'Estados permitidos: MASTER, BACKUP, FAULT\n'
        exit 2
        ;;
esac

#=============================================================#
# EL SCRIPT REQUIERE UNA TERMINAL PARA SOLICITAR CONFIRMACIÓN #
#=============================================================#
if [[ ! -t 0 || ! -t 1 ]]; then
    log "$ROJO" "ERROR" \
        "No hay una terminal interactiva. No se realizara ningun cambio."
    log "$AMARILLO" "AVISO" \
        "Si se utiliza con keepalived, configura una confirmacion previa."
    exit 3    
fi

#=====================================#
# CONFIRMAR ANTES DE REALIZAR CAMBIOS #
#=====================================#
printf '\n'
log "$AZUL" "INFORMACION" "Estado solicitado: $ESTADO"
printf '%bADVERTENCIA: esta operacion puede iniciar o detener DHCP.%b\n' \
    "$AMARILLO" "$NC"
printf '¿Estas seguro de continuar? [s/N]:'

read -r RESPUESTA

case "$RESPUESTA" in
    s|S|si|SI|Si|sí|SÍ)
        log "$VERDE" "OK" "Confirmacion recibida."
        ;;
    *)
        log "$AMARILLO" "CANCELADO" \
            "Operacion cancelada. No se modifico el servicio DHCP."
        exit 0
        ;;
esac

#================================#
# EVITAR EJECUCIONES SIMULTANEAS #
#================================#
if ! command -v flock >/dev/null 2>&1; then
    log "$ROJO" "ERROR" \
        "No se encuentra flock. No se realizara ningun cambio."
    exit 4
fi

exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "$AMARILLO" "AVISO" \
        "Ya existe otra ejecucion activa. No se realizara ningun cambio."
    exit 0
fi

#=========================================================#
# DETECTAR UNA UNIDAD DHCP REALMENTE INSTALADA EN SYSTEMD #
#=========================================================#
detectar_dhcp() {
    local servicio
    
    local servicio=(
        zentyal-dhcp.service
        zentyal-dhcp
        isc-dhcp-server.service
        isc.dhcp-server
        kea-dhcp4-server.service
        kea-dhcp4-server
    )	 

    for servicio in "${servicios[@]}"; do
        if systemctl show "$servicio" \
            --property=LoadState --value 2>/dev/null |
            grep -qx 'loaded'; then
            printf '%s\n' "$SERVICIO"
            return 0
        fi 
    done

    return 1
}

if ! SERVICIO_DHCP="$(detectar_dhcp)"; then
    log "$ROJO" "ERROR" \
        "No se encontro un servicio DHCP compatible."
    log "$AMARILLO" "AVISO" \
        "No se ha iniciado ni detenido ningun servicio."
    exit 5
fi

log "$AZUL" "INFORMACION" "Servicio detectado: $SERVICIO_DHCP"

#===========================#
# COMPROBAR ELESTADO ACTUAL #
#===========================#
if systemctl is-active --quiet "$SERVICIO_DHCP"; then
    DHCP_ACTIVO=1
    
else
    DHCP_ACTIVO=0
fi

#=======================================#
# APLICAR UNIAMENTE EL CAMBIO NECESARIO #
#=======================================#
case "$ESTADO" in
    
    MASTER)
        if (( DHCP_ACTIVO == 1 )); then
            log "$VERDE" "OK" \
                "DHCP ya esta activo. No se necesitan cambios."
        else
            log "$AZUL" "ACCION" "Iniciando DHCP..."
            
            if systemctl start "$SERVICIO_DHCP"; then
                log "$VERDE" "OK" "DHCP iniciado correctamente."
            else
                log "$ROJO" "ERROR" "No se pudo iniciar DHCP."
                exit 6
            fi
        fi
        ;;
        
    BACKUP|FAULT)
        if (( DHCP_ACTIVO == 0 )); then
            log "$VERDE" "OK" \
                "DHCP ya esta detenido. No se necesitan cambios."
        else
            log "$AZUL" "ACCION" "Deteniendo DHCP..."
            
            if systemctl stop "$SERVICIO_DHCP"; then
                log "$VERDE" "OK" "DHCP detenido correctamente."
            else
                log "$ROJO" "ERROR" "No se pudo detener DHCP."
                exit 7
            fi
        fi    
        ;;  
esac    
            
#==============================#           
# VERIFICAR EL RESULTADO FINAL #            
#==============================#            
if [[  "$ESTADO" == "MASTER" ]]; then
    if systemctl is-active --quiet "$SERVICIO_DHCP"; then
        log "$VERDE" "FINALIZADO" \
            "MASTER: DHCP esta activo y verificado."
    else
        log "$ROJO" "ERROR" \
            "DHCP no quedo activo despues de la operacion."
            exit 8
    fi
else
    if systemctl is-active --quiet "$SERVICIO_DHCP"; then
        log "$ROJO" "ERROR" \
            "DHCP sigue activo cuando deberia estar detenido.
            "           
        exit 9
    else   
        log "$VERDE" "FINALIZADO" \
            "$ESTADO: DHCP esta detenido y verificado."
    fi
fi

exit 0
