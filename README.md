# Proyecto-Central-Telefonica-Mesa4
*Repositorio Oficial para el Proyecto Final de - Mesa 4*

**Integrantes**  
*- Emely Carolina Barahona Lara*<br> 
*- Jeniffer Gabriela Rivas Aviles*<br>
*- Sara Beatriz Flores Escobar*<br> 
*- Jorge Josafat Pérez Colorado*<br>
*- Gabriel Arturo Alfaro Pérez*<br> 

## Arquitectura y Topología<br>
La infraestructura consta de 5 nodos (físicos y virtualizados) distribuidos en dos ubicaciones físicas, apovechando la infraestructura presente en el aula para permanecer conectados, asegurando cada nodo en el proceso para evitar fugas de información.

| Nodo | Sistema Operativo | Máquina | Funciones | Dirección IP |  
| :--- | :--- | :--- | :--- | :--- |
| **Nodo 1** | Ubuntu Server + Zentyal | PC Real | Pasarela Primaria | 192.168.14.252 |
| **Nodo 2** | Ubuntu Server 24.04 | VM (KVM/QEMU) | Servidor Asterisk | 192.168.14.50 |
| **Nodo 3** | Ubuntu Server 24.04 | VM (KVM/QEMU) | Servidor Zabbix | 192.168.14.51 |
| **Nodo 4** | Ubuntu Server 24.04 | VM (KVM/QEMU) | Respaldos | 192.168.14. |
| **Nodo 5** | Ubuntu Server + Zentyal | PC Real | Pasarela Secundaria | 192.168.14.252 |
