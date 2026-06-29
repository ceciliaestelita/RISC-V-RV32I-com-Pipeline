param (
    [string]$port
)

if (-not $port) {
    Write-Host "Uso: .\run_serial.ps1 COMx"
    exit
}

Set-Location dump
python serial_dump.py $port
Set-Location ..