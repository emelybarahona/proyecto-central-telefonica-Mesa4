#!/bin/bash

/bin/ping -I wlp2s0 -c 2 -W 2 8.8.8.8 > /dev/null 2>&1

if [ $? -eq 0 ]; then
    exit 0
else
   
    exit 1
fi

