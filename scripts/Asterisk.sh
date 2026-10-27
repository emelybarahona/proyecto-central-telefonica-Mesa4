#!/bin/bash

#==================================================================
# Script de Instalación de Asterisk y Configuración de Clientes
# Este script esta diseñado para una instalación y configuración
# básica, ideal para  realizar llamadas de manera rápida.
# Tarea: Módulo Final
# Equipo: Mesa 4
# Versión: 2.0 <^__^>
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

#Rutas de configuración necesarias - Para no escribirlas manualmente
PJSIP="/etc/asterisk/pjsip.conf"
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

#Configuración PJSIP básica
configuracion_pjsip(){
	#Copia de seguridad
	clear
	echo -e "${COLOR_AZUL}Realizando copia de seguridad del archivo SIP...${CIERRE}"
	
	if [ ! -f "$PJSIP.bak" ]; then
		cp $PJSIP $PJSIP.bak
	fi
	
	if ! grep -q "\[transport-udp\]" $PJSIP; then
		echo "" > $PJSIP
		sleep 2
	
	cat <<EOF >> $PJSIP
[transport-udp]
type=transport
protocol=udp
bind=0.0.0.0:5060
EOF

		echo -e "${COLOR_VERDE}Transporte PJSIP Configurado! Ahora puedes agregar usuarios y extensiones!${CIERRE}"
	fi
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
	read -p "¿Cuál será el contexto para el usuario?" Contexto
	
	#Revisamos si ya existe el nombre
	if grep -q "^\[$nombre\]" $PJSIP && grep -A1 "^\[$nombre\]" $PJSIP | grep -q "type=endpoint"; then
		echo -e "${COLOR_ROJO}El usuario ya existe!${CIERRE}"
	else
		cat <<EOF >> $PJSIP
		
[$nombre]
type=endpoint
context=$Contexto
disallow=all
allow=ulaw,alaw
transport=transport-udp
auth=auth_$nombre
aors=$nombre

[auth_$nombre]
type=auth
auth_type=userpass
username=$user
password=$contra
nonce_lifetime=600

[$nombre]
type=aor
max_contacts=1
EOF
		echo -e "${COLOR_VERDE}¡Usuario Agregado!${CIERRE}"
	fi
	
	#Agregamos la extension, primero revisamos si el contexto existe
	if ! grep -q "^\[$Contexto\]" "$EXT"; then
		echo "[$Contexto]" >> "$EXT"
	fi
	
	if grep -q "exten=> $ext," "$EXT" || grep -q "exten => $ext" "$EXT"; then
		echo -e "${COLOR_ROJO}La extensión '$ext' ya existe!${CIERRE}"
	else
		if [ "$MOH_SI" -eq 1 ]; then
			cat <<EOF >> "$EXT"
			
exten=> $ext,1,Answer()
same=> n,Set(CHANNEL(musicclass)=musica)
same=> n,Dial(PJSIP/$nombre)
same=> n,Hangup()
EOF
		else
			cat <<EOF >> "$EXT"
			
exten=> $ext,1,Answer()
same=> n,Dial(PJSIP/$nombre)
same=> n,Hangup()
EOF
		fi
	echo -e "${COLOR_VERDE}Extensión agregada con éxito!${CIERRE}"
	fi
	sleep 2	
}

#Configuramos la música en espera
configurar_moh(){
	clear
	echo -e "${COLOR_AZUL}Configurando Música en Espera...${CIERRE}"
	
	mkdir -p /var/lib/asterisk/moh/espera
	
	if [ ! -f "$MOH.bak" ]; then 
		cp "$MOH" "$MOH.bak"
	fi
	
	if ! grep -q "\[musica\]" "$MOH"; then
		cat <<EOF >> "$MOH"
[general]
cachertclasses=yes

[musica]
mode=files
directory=/var/lib/asterisk/moh/espera
sort=random
EOF

		echo -e "${COLOR_VERDE}MOH Configurada! Debes poner los audios .wav en la ruta: /var/lib/asterisk/moh/espera/${CIERRE}"
	else
		echo -e "${COLOR_ROJO}MOH ya estaba configurado!${CIERRE}"
	fi
	MOH_SI=1
}

#Aplicamos los cambios realizados
aplicar_cambios(){
	clear
	echo -e "${COLOR_AZUL}Aplicando Cambios...${CIERRE}"
	
	#Dando permisos al usuario no root
	chown -R asterisk:asterisk /etc/asterisk
	chmod 640 /etc/asterisk/*.conf
	
	#Recargando archivos y configuraciones
	asterisk -rx "pjsip reload"
	asterisk -rx "dialplan reload"
	asterisk -rx "moh reload"
	asterisk -rx "core reload"
	
	sleep 2
}

#Abrimos las reglas UFW
ufw(){
	clear
	echo -e "${COLOR_AZUL}Configurando Cortafuegos...${CIERRE}"
	
	if sudo ufw status | grep -q "Status: active"; then
		ufw allow 5060/udp
		ufw allow 10000:20000/udp
		ufw reload
		echo -e "${COLOR_VERDE}Reglas Aplicadas y Puertos Abiertos!${CIERRE}"
		sleep 2
	else
		echo -e "${COLOR_ROJO}UFW no esta activo!${CIERRE}"
	fi
	sleep 2
}

#Salimos del script
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
