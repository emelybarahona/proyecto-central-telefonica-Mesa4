#!/bin/bash

#==================================================================
# Script de eliminación de configuraciones necesarias para aplicar
# el modo puente a una VM KVM/QEMU.
# Tarea: Módulo Final
# Equipo: Mesa 4
# Versión: 1.5 <^__^>
#==================================================================

#Coloressssz
COLOR_ROJO='\e[31m'
COLOR_VERDE='\e[32m'
COLOR_AMARILLO='\e[33m'
COLOR_AZUL='\e[34m'
NEGRITA='\e[1m'
CIERRE='\e[0m'

#Verificación de errores
set -euo pipefail

#Verificar usuario root
verificar_root(){

	if [ "$EUID" -ne 0 ]; then
		echo -e "${COLOR_ROJO}No eres usuario root, no puedes ejecutar este script.${CIERRE}"
		exit 1
	fi
}

verificar_root

#Anuncio
echo -e "${COLOR_AZUL}XXXXXXXXXXXXXXXXXXXXXXXXXXXXX${CIERRE}"
echo -e "${COLOR_AZUL}X   Eliminando Modo Puente  X${CIERRE}"
echo -e "${COLOR_AZUL}XXXXXXXXXXXXXXXXXXXXXXXXXXXXX${CIERRE}"

#Solicitamos el nombre de la interfaz puente y cableada
read -p "¿Cuál es el nombre de la interfaz de red del puente?: " Puente_INT
sleep 1
read -p "¿Cuál es el nombre de la interfaz de red cableada?: " Cableada_INT
sleep 1

#Desactivamos la interfaz del puente
if ip link show "$Puente_INT" &>/dev/null; then
	echo -e "${COLOR_AZUL} Desactivando la interfaz $Puente_INT... ${CIERRE}"
	ip link set "$Puente_INT" down
else
	echo -e "${COLOR_ROJO}La interfaz $Puente_INT ya está desactivada o no existe!${CIERRE}"
fi

#Listamos los archivos de netplan y preguntamos por el del puente
echo -e "${COLOR_AZUL} Archivos Netplan Actuales: ${CIERRE}"
ls -l /etc/netplan

echo ""
read -p "Escribe el nombre del archivo Netplan donde se configuro el puente: " Netplan_Pue

Netplan_DEF="/etc/netplan/$Netplan_Pue"

#Eliminamos el Netplan
if [ -f "$Netplan_DEF" ]; then
	echo -e "${COLOR_AZUL}Eliminando el archivo $Netplan_Pue...${CIERRE}"
	rm "$Netplan_DEF"
else
	echo -e "${COLOR_ROJO}El archivo Netplan no existe! (ya fue eliminado)${CIERRE}"
fi

#Aplicando los cambios
echo -e "${COLOR_AZUL}Aplicando Cambios y Reiniciando...${CIERRE}"
netplan apply
systemctl restart systemd-networkd

#Eliminando la interfaz del puente
if ip link show "$Puente_INT" &>/dev/null; then
	echo -e "${COLOR_AZUL}Eliminando la interfaz $Puente_INT...${CIERRE}"
	ip link delete "$Puente_INT"
else
	echo -e "${COLOR_ROJO}La interfaz $Puente_INT ya fue eliminada!${CIERRE}"
fi

#Encendemos la interfaz cableada ethernet
echo -e "${COLOR_AZUL}Encendiendo interfaz física $Cableada_INT...${CIERRE}"
ip link set "$Cableada_INT" up

#Indicamos que la interfaz cableada reciba IP por DHCP
echo -e "${COLOR_AZUL}Entregando IP por DHCP...${CIERRE}"
dhclient -r "$Cableada_INT" || true
dhclient "$Cableada_INT" || echo -e "${COLOR_ROJO}dhclient falló! Intenta configurar manualmente el DHCP por interfaz gráfica."

#Verificamos Conectividad
echo -e "${COLOR_AZUL}Verificando conectividad a internet...${CIERRE}"
if ping -c 4 8.8.8.8 &>/dev/null; then
	echo -e "${COLOR_VERDE}La PC ha recuperado su conexión a internet!"
else
	echo -e "${COLOR_ROJO}No se puede hacer ping a internet! Verifica el dhcp por interfaz gráfica."
fi
