#!/bin/bash
ESTADO=$1


if systemctl list-unit-files | grep -q zentyal-dhcp; then
    SERVICIO_DHCP="zentyal-dhcp"
elif systemctl list-unit-files | grep -q isc-dhcp-server; then
    SERVICIO_DHCP="isc-dhcp-server"
else
    SERVICIO_DHCP="kea-dhcp4-server"
fi

case $ESTADO in
    "MASTER")
        
        systemctl start $SERVICIO_DHCP
        ;;
    "BACKUP"|"FAULT")
        
        systemctl stop $SERVICIO_DHCP
        ;;
esac

