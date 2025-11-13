set -euo pipefail

pause() { read -rp $'Presione ENTER para continuar...\n' _; }

show_users_lastlogon() {
    echo "Usuarios del sistema y último login:"
    if command -v lastlog >/dev/null 2>&1; then
        # Muestra todos los usuarios y la última vez que ingresaron
        lastlog
    else
        # Fallback: listar /etc/passwd y usar last para cada usuario
        awk -F: '{ print $1 }' /etc/passwd | while read -r u; do
            last -F -n 1 "$u" 2>/dev/null | head -n1 || echo "$u nunca ha iniciado sesión"
        done
    fi
}

show_filesystems() {
    echo "Filesystems / discos montados (tamaño y espacio libre en bytes):"
    # Usar lsblk para obtener tamaño en bytes y punto de montaje
    if command -v lsblk >/dev/null 2>&1; then
        lsblk -b -o NAME,SIZE,TYPE,MOUNTPOINT | awk 'NR==1{print $0;next} {print}'
    fi
    echo ""
    echo "df (tamaño y libre en bytes):"
    df -B1 -h --output=source,size,used,avail,pcent,target
}

show_top_files() {
    read -rp "Ingrese punto de montaje o ruta del filesystem (ej: /mnt/data): " path
    if [ ! -d "$path" ]; then
        echo "Ruta no encontrada: $path"
        return
    fi
    echo "Buscando los 10 archivos más grandes en $path (puede tardar)..."
    # find + stat para tamaño en bytes, luego ordenar
    if command -v stat >/dev/null 2>&1; then
        find "$path" -xdev -type f -printf '%s\t%p\n' 2>/dev/null | sort -nr -k1,1 | head -n 10 | awk -F'\t' '{printf "%s bytes\t%s\n", $1, $2}'
    else
        # Alternativa usando du -b (puede tardar)
        find "$path" -xdev -type f -print0 2>/dev/null | xargs -0 du -b 2>/dev/null | sort -nr | head -n10
    fi
}

show_memory_swap() {
    echo "Memoria y swap (bytes y porcentaje):"
    if command -v free >/dev/null 2>&1; then
        # Mostrar en bytes
        free -b | awk 'NR==2{total=$2;free=$7;used=total-free;printf "Memoria total: %d bytes\nMemoria libre: %d bytes\nMemoria en uso: %d bytes (%.2f%%)\n", total, free, used, used/total*100} NR==3{total=$2;used=$3;printf "Swap total: %d bytes\nSwap en uso: %d bytes (%.2f%%)\n", total, used, (total>0?used/total*100:0)}'
    else
        echo "Comando free no disponible."
    fi
}

backup_to_usb() {
    read -rp "Ingrese la ruta del directorio a respaldar: " source
    if [ ! -d "$source" ]; then
        echo "Directorio no existe: $source"
        return
    fi

    echo "Detectando dispositivos removibles montados..."
    # Buscar dispositivos con RM=1 en lsblk y que tengan punto de montaje
    if command -v lsblk >/dev/null 2>&1; then
        mapfile -t mts < <(lsblk -o NAME,RM,MOUNTPOINT -J | jq -r '.blockdevices[] | select(.rm==1 and .mountpoint!=null) | .mountpoint' 2>/dev/null || true)
    fi

    # Fallback buscar en /media y /run/media
    if [ ${#mts[@]:-0} -eq 0 ]; then
        for d in /media/*/* /run/media/*/*; do
            [ -d "$d" ] && mts+=("$d")
        done
    fi

    if [ ${#mts[@]:-0} -eq 0 ]; then
        echo "No se detectaron memorias USB montadas. Monte la USB y vuelva a intentarlo."
        return
    fi

    echo "Memorias detectadas:"
    local i=0
    for p in "${mts[@]}"; do
        i=$((i+1))
        echo "[$i] $p"
    done
    read -rp "Seleccione número del dispositivo destino: " sel
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#mts[@]}" ]; then
        echo "Selección inválida"
        return
    fi
    dest="${mts[$((sel-1))]}"
    timestamp=$(date +%Y%m%d_%H%M%S)
    destdir="$dest/backup_$timestamp"
    mkdir -p "$destdir"

    # Usar rsync si está disponible
    if command -v rsync >/dev/null 2>&1; then
        echo "Copiando con rsync..."
        rsync -a --info=progress2 "$source"/ "$destdir"/
    else
        echo "Copiando con cp -a..."
        cp -a "$source" "$destdir"
    fi

    # Crear catálogo: nombre y fecha de última modificación
    find "$destdir" -type f -printf '%p|%TY-%Tm-%Td %TH:%TM:%TS\n' 2>/dev/null > "$destdir/catalogo.txt"
    echo "Backup completado en $destdir"
    echo "Catálogo creado: $destdir/catalogo.txt"
}

while true; do
    clear
    cat <<EOF
=== Herramienta DC (Bash) ===
1) Desplegar usuarios y último login
2) Desplegar filesystems / discos (tamaño y espacio libre en bytes)
3) Top 10 archivos más grandes en filesystem especificado
4) Memoria libre y swap en uso (bytes y porcentaje)
5) Hacer copia de seguridad a memoria USB + catálogo
0) Salir
EOF
    read -rp "Seleccione una opción: " opt
    case "$opt" in
        1) show_users_lastlogon; pause ;;
        2) show_filesystems; pause ;;
        3) show_top_files; pause ;;
        4) show_memory_swap; pause ;;
        5) backup_to_usb; pause ;;
        0) break ;;
        *) echo "Opción inválida"; pause ;;
    esac
done
