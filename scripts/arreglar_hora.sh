#!/usr/bin/env bash

# ==========================================================
# ARREGLAR FECHA Y HORA - UBUNTU 24.04 SERVER
# Interfaz gráfica mediante YAD
# Zona horaria: El Salvador
# Script idempotente
# Autora: Emely Barahona :)
# ==========================================================

set -Eeuo pipefail

readonly ZONA_HORARIA="America/El_Salvador"
readonly TITULO="Corrección de fecha y hora"

# ----------------------------------------------------------
# Comprobar que YAD esté instalado
# ----------------------------------------------------------

if ! command -v yad >/dev/null 2>&1; then
  printf 'Error: YAD no está instalado.\n'
  printf 'Instálalo con: sudo apt install yad\n'
  exit 1
fi

if ! sudo -v; then
   yad --error \
    --title="$TITULO" \
    --text="No se pudieron obtener permisos de administrador."
    exit 1
fi

if ! timedatectl list-timezones | grep -Fxq "$ZONA_HORARIA"; then
    yad --error \
        --title="$TITULO" \
        --text="No se encontró la zona horaria $ZONA_HORARIA."
    exit 1
fi

if [[ "$(timedatectl show -p Timezone --value)" != "$ZONA_HORARIA" ]]; then
    if ! sudo timedatectl set-timezone "$ZONA_HORARIA"; then
        yad --error \
          --title="$TITULO" \
          --text="No se pudo configurar la zona horaria."
        exit 1
    fi
fi

FECHA=$(yad --calendar \
  --title="$TITULO" \
  --text="Selecciona la fecha correcta:" \
  --date-format="%Y-%m-%d" \
  --day="$(date +%-d)" \
  --month="$(date +%-m)" \
  --year="$(date +%Y)" \
  --width=350 \
  --height=300) || exit 0

HORA=$(yad --entry \
  --title="$TITULO" \
  --text="Introduce la hora correcta en formato HH:MM:SS\nEjemplo: 14:30:00" \
  --entry-text="$(date +%H:%M:%S)" \
  --width=350) || exit 0

HORA="$(printf '%s' "$HORA" | xargs)"

# Validar el formato de la hora.
if [[ ! "$HORA" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]$ ]]; then
    yad --error \
        --title="$TITULO" \
        --text="Hora incorrecta.\nUtiliza el formato HH:MM:SS.\nEjemplo: 09:45:00"
    exit 1
fi

# Comprobar que la fecha seleccionada sea válida.
if ! date -d "$FECHA" '+%Y-%m-%d' >/dev/null 2>&1 ||
   [[ "$(date -d "$FECHA" '+%Y-%m-%d')" != "$FECHA" ]]; then
    yad --error \
        --title="$TITULO" \
        --text="La fecha seleccionada no es válida."
    exit 1
fi

if ! yad --question \
    --title="$TITULO" \
    --text="Se aplicarán estos cambios:\n\nFecha: $FECHA\nHora: $HORA\nZona horaria: $ZONA_HORARIA\n\n¿Deseas continuar?" \
    --width=400; then
    exit 0
fi

if ! sudo timedatectl set-ntp false; then
    yad --error \
        --title="$TITULO" \
        --text="No se pudo desactivar la sincronización NTP."
    exit 1
fi

if ! sudo timedatectl set-time "$FECHA $HORA"; then
    yad --error \
        --title="$TITULO" \
        --text="No se pudo establecer la fecha y hora.\nComprueba los permisos y el estado del reloj del sistema."
    exit 1
fi

FECHA_FINAL=$(date '+%d/%m/%Y')
HORA_FINAL=$(date '+%H:%M:%S')
ZONA_FINAL=$(timedatectl show -p Timezone --value)
NTP_FINAL=$(timedatectl show -p NTP --value)

yad --info \
    --title="Corrección completada" \
    --text="La fecha y hora se configuraron correctamente.\n\nFecha actual: $FECHA_FINAL\nHora actual: $HORA_FINAL\nZona horaria: $ZONA_FINAL\nSincronización NTP: $NTP_FINAL\n\nLa sincronización automática permanece desactivada." \
    --width=400

exit 0

