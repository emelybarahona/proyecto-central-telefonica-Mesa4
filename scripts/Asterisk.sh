#!/bin/bash

#==================================================================
# Script de Instalación de Asterisk y Configuración de Clientes
# Este script esta diseñado para una instalación y configuración
# básica, ideal para  realizar llamadas de manera rápida.
# Tarea: Módulo Final
# Autor: Jorge (Yo)
# Versión: 1.7 <^__^>
#==================================================================

#Coloressssz
COLOR_ROJO='\e[31m'
COLOR_VERDE='\e[32m'
COLOR_AMARILLO='\e[33m'
COLOR_AZUL='\e[34m'
NEGRITA='\e[1m'
CIERRE='\e[0m'

set -euo pipefail

#Verificar usuario root
verificar_root(){

	if [ "$EUID" -ne 0 ]; then
		echo -e "${COLOR_ROJO}No eres usuario root, no puedes ejecutar este script.${CIERRE}"
		exit 1
	fi
}

#Rutas de configuración necesarias - Para no escribirlas manualmente
SIP="/etc/asterisk/sip.conf"
EXT="/etc/asterisk/extensions.conf"
MOH="/etc/asterisk/musiconhold.conf"
MOH_SI=0

#Instalación de Asterisk
instalar_asterisk(){
	echo -e "${COLOR_AZUL}Instalando Asterisk${CIERRE}"
	apt-get install asterisk -y
	
	echo -e "${COLOR_AZUL}Instalando Audios en Español${CIERRE}"
	apt-get install asterisk-core-sounds-es asterisk-core-sounds-es-g722 asterisk-core-sounds-es-wav -y
	
	service asterisk restart
	echo -e "${COLOR_AZUL}¡Listo, Asterisk Instalado y Corriendo!${CIERRE}"
	sleep 3
}

#Configuración SIP básica
configuracion_sip(){
	#Copia de seguridad
	echo -e "${COLOR_AZUL}Realizando copia de seguridad del archivo SIP...${CIERRE}"
	cp $SIP $SIP.bak
	echo "" > $SIP
	
	sleep 2
	clear
	read -p "¿Cómo se llamará la plantilla?" Plantilla
	read -p "¿Cuál será el contexto?" Contexto
	
	cat <<EOF >> $SIP
[general]
context=public
allowguest=no
udpbindaddr=0.0.0.0
tcpenable=no
transport=udp
disallow=all
allow=ulaw
allow=alaw
language=es

[authentication]

[$Plantilla](!)
type=friend
context=$Contexto
host=dynamic
EOF

	echo -e "${COLOR_AZUL}SIP Configurado. Ahora puedes agregar usuarios y extensiones!${CIERRE}"
}

#Usuarios_Configuración
agregar_usuarios(){
	clear
	echo -e "${COLOR_AZUL}Agregando Usuario...${CIERRE}"
	echo ""
	read -p "Nombre:" nombre
	read -p "Username:" user
	read -p "Extensión:" ext
	read -p "Contraseña:" contra
	
	#Revisamos si ya existe el nombre
	if grep -q "^\[$nombre\]" $SIP; then
		echo -e "${COLOR_AZUL}El usuario ya existe!${CIERRE}"
	else
		cat <<EOF >> $SIP
		
[$nombre]($Plantilla)
callerid=$user
secret=$contra
EOF
	echo -e "${COLOR_AZUL}¡Usuario Agregado!${CIERRE}"
	fi
	
	#Agregamos la extension, primero revisamos si el contexto existe
	if ! grep -q "^\[$Contexto\]" $EXT; then
		echo "[$Contexto]" >> $EXT
	fi
	
	if grep -q "exten=> $ext," $EXT; then
		echo -e "${COLOR_AZUL}La extensión ya existe!${CIERRE}"
	else
		if [ "$MOH_SI" -eq 1 ]; then
			cat <<EOF >> $EXT
			
exten=> $ext,1,Answer()
same=> n,Set(CHANNEL(musicclass)=musica)
same=> n,Dial(SIP/$nombre)
same=> n,Hangup()
EOF
	else
			cat <<EOF >> $EXT
			
exten=> $ext,1,Answer()
same=> n,Dial(SIP/$nombre)
same=> n,Hangup()
EOF
		fi
	echo -e "${COLOR_AZUL}Extensión agregada con éxito!${CIERRE}"
	fi	
}

configurar_moh(){
	clear
	echo -e "${COLOR_AZUL}Configurando Música en Espera...${CIERRE}"
	
	mkdir -p /var/lib/asterisk/moh/espera
	cp $MOH $MOH.bak
	echo "" > $MOH
	
	cat <<EOF >> $MOH
[general]
cachertclasses=yes

[musica]
mode=files
directory=/var/lib/asterisk/moh/espera
sort=random
EOF

	MOH_SI=1
	echo -e "${COLOR_AZUL}MOH Configurada! Debes poner los audios .wav en la ruta: /var/lib/asterisk/moh/espera/${CIERRE}"
}

aplicar_cambios(){
	clear
	echo -e "${COLOR_AZUL}Aplicando Cambios...${CIERRE}"
	
	#Dando permisos al usuario no root
	chown -R asterisk:asterisk /etc/asterisk
	chmod 640 /etc/asterisk/*.conf
	
	#Recargando archivos y configuraciones
	asterisk -rx "sip reload"
	asterisk -rx "dialplan reload"
	asterisk -rx "moh reload"
	asterisk -rx "core reload"
	
	sleep 2
}

ufw(){
	clear
	echo -e "${COLOR_AZUL}Configurando Cortafuegos...${CIERRE}"
	
	ufw allow 5060/udp
	ufw allow 10000:20000/udp
	ufw reload
	
	sleep 2
}

salir(){
	echo "Adiosss"
	sleep 1
	exit 0
}

#Meu de elección
while true; do
	clear
	echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	echo "               MENU ASTERISK                "
	echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	echo "1. Instalar Asterisk"
	echo "2. Configurar Plantilla"
	echo "3. Agregar Usuarios"
	echo "4. Configurar Música en Espera (Opcional)"
	echo "5. Aplicar Cambios"
	echo "6. Configurar Cortafuegos"
	echo "7. Terminar"
	echo "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
	
	read -p "Elige una opción: " occion
	
	case $occion in
		1) instalar_asterisk ;;
		2) configuracion_sip ;;
		3) agregar_usuarios ;;
		4) configurar_moh ;;
		5) aplicar_cambios ;;
		6) ufw ;;
		7) salir ;;
		*) echo "Opcion no valida" ;;
	esac
done
