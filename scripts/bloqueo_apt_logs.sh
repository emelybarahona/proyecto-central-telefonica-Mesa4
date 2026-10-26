#!/bin/bash

##############################################################################################################################
# Este script fue creado para proteger archivos y permisos, pero no deshabilitar APT por completo. Al ejecutarlo nuevamente,  #
# vuelve a aplicar los permisos definidos.                                                                                   #
# Ubuntu                                                                                                                     #
# Script idempotente                                                                                                         #
# Mesa: 4                                                                                                                    #
# Institución: Complejo Educativo Residencial Altavisata                                                                      #
# Profesor: Franklin David Barahona López                                                                                    #
##############################################################################################################################

set -u

###########
# Colores #
###########
VERDE='\033[0;32m'
ROJO='\033[0;31m'
AMARILLO='\033[1;33m'
AZUL='\033[0;34m'
NC='\033[0m'

mensaje() { echo -e "${AZUL}[INFO]${NC} $1"; }
exito() { echo -e "${VERDE}[OK]${NC} $1"; }
aviso() { echo -e "${AMARILLO}[AVISO]${NC} $1"; }
error() { echo -e "${ROJO}[ERROR]${NC} $1"; }

#===================#
# 1. COMPROBAR ROOT #
#===================#

echo "=================================="
echo " BLOQUEO DE APT Y PROTECCION LOGS "
echo "=================================="
echo

if [[ $EUID -ne 0 ]]; then
    aviso "No estas ejecutando el script como root."
    
    read -r -p "¿Deseas continuar como superusuario usando sudo? (s/n): " respuesta
    
    case "$respuesta" in
        s|S|si|SI|Si|sí|SÍ)
            if command -v sudo >/dev/null 2>&1; then
                exec sudo bash "$0" "$@"
            else
                error "sudo no esta instalado."
                echo "Ingresa manualmente como root y ejecuta el script."
                exit 1
            fi
            ;;
         *)
            mensaje "Operacion cancelada."
            exit 0
            ;;
     esac
fi

exito "Permisos de superusuario confirmados."
echo

#================#
# 2.CONFIRMACION #
#================#

echo "Se aplicaran las siguientes medidas:"
echo " 1. Proteccion de la configuracion de APT."
echo " 2. Proteccion de las credenciales de APT."           
echo " 3. Restriccion de permisos de logs."                  
echo " 4. Conservacion del funcionamiento del sistema."           
echo

aviso "Esta operacion modificara permisos y propietarios."
read -r -p "¿Estas seguro de continuar? (s/n): " confirmar

case "$confirmar" in
    s|S|si|SI|Si|sí|SÍ);;
    *)
        mensaje "Operacion cancelada por el usuario."
        exit 0
        ;;
esac

ERRORES=0

#================================#
# 3. PROTEGER DIRECTORIOS DE APT #
#================================#

echo
echo "===== PROTECCION DE APT ====="

for directorio in \
    /etc/apt \
    /etc/apt/apt.conf.d \
    /etc/apt/sources.list.d
do
      if [[ -d "$directorio" ]]; then
          if chown root:root "$directorio" &&
             chmod 755 "$directorio"; then
             exito "$directorio protegido."
        else
            error "No se pudo proteger $directorio."
            ((ERRORES+=1))
        fi
    fi
done     

#=======================================#
# 4. PROTEGER ARCHIVOS DE CONFIGURACION #
#=======================================#

for archivo in \
    /etc/apt/sources.list \
   /etc/apt/apt.conf
do
   if [[ -f "$archivo" && ! -L "$archivo" ]]; then
       if chown root:root "$archivo" &&
          chmod 644 "$archivo"; then
          exito "$archivo protegido."
       else
           error "No se pudo proteger $archivo."
           ((ERRORES+=1))
       fi
    fi
done

for directorio in \
    /etc/apt/apt.conf.d \
   /etc/apt/sources.list.d
do
   if [[ -d "$directorio" ]]; then
       while IFS= read -r -d '' archivo; do
           if [[ -L "$archivo" ]]; then
               aviso "Se omite enlace simbolico: $archivo"
               continue
           fi
           
           if chown root:root "$archivo" &&
              chmod 644 "$archivo"; then
              exito "Archivo protegido: $archivo"
           else
               error "No se pudo proteger: $archivo"
               ((ERRORES+=1))
           fi
       done < <(find "$directorio" -maxdepth 1 -type f -print0)
    fi
done

#=================================#
# 5. PROTEGER CREDENCIALES DE APT #
#=================================#

if [[ -f /etc/apt/auth.conf &&
      ! -L /etc/apt/auth.conf ]]; then
      
   if chown root:root /etc/apt/auth.conf &&
      chmod 600 /etc/apt/auth.conf; then
      exito "Credenciales de APT protegidas."
   else
       error "No se pudieron proteger las credenciales."
       ((ERRORES+=1))
   fi
fi

if [[ -d /etc/apt/auth.conf.d ]]; then
    
    if chown root:root /etc/apt/auth.conf.d &&
       chmod 755 /etc/apt/auth.conf.d; then
       exito "Directorio auth.conf.d protegido."
    else
        error "No se pudo proteger auth.conf.d."
        ((ERRORES+=1))
    fi
    
    while IFS= read -r -d '' archivo; do
        if [[ -L "$archivo" ]]; then
            aviso "Se omite enlace simbolico: $archivo"
            continue
        fi
        
        if chown root:root "$archivo" &&
           chmod 600 "$archivo"; then
           exito "Credencial protegida: $archivo"
        else
            error "No se pudo proteger: $archivo"
            ((ERRORES+=1))
        fi
       
    done < <(find /etc/apt/auth.conf.d -maxdepth 1 -type f -print0)
fi

#==============================#
# 6. PROTEGER LOGS DEL SISTEMA #
#==============================#     
        
echo
echo "===== PROTECCION DE LOGS ====="

LOGS=(
    "/var/log/syslog"
    "/var/log/auth.log"
    "/var/log/kern.log"  
    "/var/log/daemon.log"
    "/var/log/dpkg.log"
    "/var/log/apt/history.log"
    "/var/log/apt/term.log"
)

for archivo in "${LOGS[@]}"; do
    
    if [[ -f "$archivo" && ! -L "$archivo" ]]; then
    
        if chown root:adm "$archivo" &&
           chmod 640 "$archivo"; then
           exito "Log protegido: $archivo"
        else
            error "No se pudo proteger: $archivo"
            ((ERRORES+=1))
        fi
        
    else    
        mensaje "No existe o se omite: $archivo"
    fi
    
done

#==================#
# 7. RESUMEN FINAL #
#==================# 

echo
echo "==============="
echo " RESUMEN FINAL "
echo "==============="

if [[ "$ERRORES" -eq 0 ]]; then
    exito "Proceso completado sin errores."
else
    error "Se produjeron $ERRORES error(es)."
fi

echo
echo "APT permanece disponible para root."
echo "Los logs siguen disponibles para los servicios autorizados."
echo "El script puede ejecutarse nuevamente."

exit "$ERRORES"



