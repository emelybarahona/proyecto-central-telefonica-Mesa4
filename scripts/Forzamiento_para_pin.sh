#!/bin/bash

#Forzamos a que el ping salga estrictamente por la interfaz WiFi wlp2s0

HOST="google.com"

# Ping the host

ping -c 1 $HOST > /dev/null

if [ $? -eq 0 ]; then

echo "Host $HOST is available"

else

echo "Host $HOST is not available"

fi
