
function Pause-Continue { Write-Host ""; Read-Host "Presione ENTER para continuar..." }

function Show-UsersLastLogon {
    Write-Host "Usuarios locales y último inicio de sesión" 
    
    try {
        $localUsers = Get-LocalUser -ErrorAction Stop
        $users = foreach ($u in $localUsers) {
            [PSCustomObject]@{
                Name = $u.Name
                Enabled = $u.Enabled
                LastLogon = $u.LastLogon
            }
        }
        $users | Format-Table -AutoSize
    } catch {
        Write-Warning "Get-LocalUser no disponible o se requiere privilegios. Intentando leer eventos de seguridad (4624). Esto puede tardar."
        $events = Get-WinEvent -FilterHashtable @{LogName='Security'; Id=4624} -ErrorAction SilentlyContinue
        if (-not $events) {
            Write-Warning "No se pudieron leer eventos de seguridad. Ejecute como Administrador o use Get-LocalUser."
            return
        }
        $lastByUser = @{}
        foreach ($ev in $events) {
            $xml = [xml]$ev.ToXml()
            $acct = $xml.Event.EventData.Data | Where-Object { $_.Name -eq 'TargetUserName' } | Select-Object -ExpandProperty '#text'
            if ($acct -and $acct -ne 'ANONYMOUS LOGON') {
                if (-not $lastByUser.ContainsKey($acct) -or $ev.TimeCreated -gt $lastByUser[$acct]) {
                    $lastByUser[$acct] = $ev.TimeCreated
                }
            }
        }
        $lastByUser.GetEnumerator() | Sort-Object Name | Format-Table Name, Value -AutoSize
    }
}

function Show-Filesystems {
    Write-Host "Filesystems / discos montados (tamaño y espacio libre en bytes)" 
    $drives = Get-PSDrive -PSProvider FileSystem
    $infos = foreach ($d in $drives) {
        try {
            $fi = Get-Volume -DriveLetter $d.Name.TrimEnd(':') -ErrorAction Stop
            [PSCustomObject]@{
                Name = $d.Name
                Root = $d.Root
                FileSystem = $fi.FileSystem
                SizeBytes = $fi.Size
                FreeBytes = $fi.SizeRemaining
            }
        } catch {
            try {
                $di = New-Object System.IO.DriveInfo($d.Root)
                [PSCustomObject]@{
                    Name = $d.Name
                    Root = $d.Root
                    FileSystem = $di.DriveFormat
                    SizeBytes = $di.TotalSize
                    FreeBytes = $di.TotalFreeSpace
                }
            } catch {
                [PSCustomObject]@{
                    Name = $d.Name
                    Root = $d.Root
                    FileSystem = 'N/A'
                    SizeBytes = 'N/A'
                    FreeBytes = 'N/A'
                }
            }
        }
    }
    $infos | Format-Table -AutoSize
}

function Show-TopFiles {
    param($path)
    if (-not $path) {
        $path = Read-Host "Ingrese la letra de unidad o ruta del filesystem (ej: C:\ , D:\mountpoint\)"
    }
    if (-not (Test-Path $path)) {
        Write-Warning "Ruta no encontrada: $path"
        return
    }
    Write-Host "Buscando los 10 archivos más grandes en $path (esto puede tardar)..." 
    Get-ChildItem -Path $path -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object FullName, @{Name='Size';Expression={$_.Length}} |
        Sort-Object -Property Size -Descending |
        Select-Object -First 10 |
        Format-Table @{Label='Tamaño(bytes)';Expression={$_.Size}}, @{Label='Ruta completa';Expression={$_.FullName}} -AutoSize
}

function Show-MemorySwap {
    Write-Host "Memoria y Swap (bytes y porcentaje)" 
    $os = Get-CimInstance Win32_OperatingSystem
    $totalKB = [int64]$os.TotalVisibleMemorySize
    $freeKB = [int64]$os.FreePhysicalMemory
    $usedKB = $totalKB - $freeKB
    $totalBytes = $totalKB * 1024
    $freeBytes = $freeKB * 1024
    $usedBytes = $usedKB * 1024
    $usedPct = [math]::Round(($usedKB / $totalKB) * 100,2)
    Write-Host "Memoria total: $totalBytes bytes"
    Write-Host "Memoria libre:  $freeBytes bytes"
    Write-Host "Memoria en uso:  $usedBytes bytes ($usedPct`%)"

    $pf = Get-CimInstance Win32_PageFileUsage
    if ($pf) {
        foreach ($p in $pf) {
            $allocatedMB = $p.AllocatedBaseSize
            $currentUsageMB = $p.CurrentUsage
            $allocatedBytes = $allocatedMB * 1MB
            $currentBytes = $currentUsageMB * 1MB
            $pct = if ($allocatedMB -ne 0) { [math]::Round(($currentUsageMB / $allocatedMB) * 100,2) } else { 0 }
            Write-Host "PageFile: $($p.Name) - Tamaño asignado: $allocatedBytes bytes - En uso: $currentBytes bytes ($pct`%)"
        }
    } else {
        Write-Warning "No se encontró información de PageFile."
    }
}

function Backup-ToUSB {
    Write-Host "Backup de directorio a memoria USB" 
    try {
        $removable = Get-Disk | Where-Object { $_.BusType -eq 'USB' } | Get-Partition | Get-Volume | Where-Object { $_.FileSystem -ne $null }
    } catch {
        $removable = @()
    }
    if (-not $removable -or $removable.Count -eq 0) {
        Write-Warning "No se detectaron volúmenes removibles. Asegúrese de conectar la memoria USB y ejecutar como Administrador."
        return
    }
    Write-Host "Volúmenes removibles detectados:"
    $i = 0
    $removable | ForEach-Object { $i++; Write-Host "[$i] $($_.DriveLetter) $($_.FriendlyName) - $($_.FileSystem) - Punto de montaje: $($_.Path)" }
    $sel = Read-Host "Seleccione número del dispositivo destino"
    if (-not [int]::TryParse($sel, [ref]$null) -or $sel -lt 1 -or $sel -gt $removable.Count) {
        Write-Warning "Selección inválida."
        return
    }
    $target = $removable[$sel - 1].DriveLetter + ":\"
    $source = Read-Host "Ingrese la ruta del directorio a respaldar (ej: C:\data\backup\)"
    if (-not (Test-Path $source)) {
        Write-Warning "Directorio origen no existe."
        return
    }
    $timestamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $dest = Join-Path $target ("backup_$timestamp")
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    $robo = Get-Command robocopy -ErrorAction SilentlyContinue
    if ($robo) {
        Write-Host "Usando robocopy para copiar..."
        $args = @($source.TrimEnd('\'), $dest, "/E","/COPY:DAT","/R:3","/W:5")
        robocopy @args | Out-Null
    } else {
        Write-Host "Usando Copy-Item recursivo..."
        Copy-Item -Path $source -Destination $dest -Recurse -Force -ErrorAction Stop
    }

    $catalogPath = Join-Path $dest "catalogo.csv"
    Get-ChildItem -Path $dest -Recurse -File | Select-Object @{Name='FullName';Expression={$_.FullName}}, @{Name='LastWriteTime';Expression={$_.LastWriteTime}} |
        Export-Csv -Path $catalogPath -NoTypeInformation -Encoding UTF8

    Write-Host "Backup completado en $dest"
    Write-Host "Catálogo creado: $catalogPath"
}

while ($true) {
    Clear-Host
    Write-Host "=== Herramienta DC (PowerShell) ===" 
    Write-Host "1) Desplegar usuarios y ultimo login"
    Write-Host "2) Desplegar filesystems / discos (tamano y espacio libre en bytes)"
    Write-Host "3) Top 10 archivos mas grandes en filesystem especificado"
    Write-Host "4) Memoria libre y swap en uso (bytes y porcentaje)"
    Write-Host "5) Hacer copia de seguridad a memoria USB + catalogo"
    Write-Host "0) Salir"
    $opt = Read-Host "Seleccione una opcion"
    switch ($opt) {
        '1' { Show-UsersLastLogon; Pause-Continue }
        '2' { Show-Filesystems; Pause-Continue }
        '3' { Show-TopFiles; Pause-Continue }
        '4' { Show-MemorySwap; Pause-Continue }
        '5' { Backup-ToUSB; Pause-Continue }
        '0' { break }
        default { Write-Warning "Opcion invalida"; Pause-Continue }
    }
}


