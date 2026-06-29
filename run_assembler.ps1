# =========================
# ASSEMBLER
# =========================

param (
    [string]$file
)

if (-not $file) {
    Write-Host "Uso: .\run_assembler.ps1 <arquivo.asm>"
    exit
}

Set-Location assembler
python assembler.py --dump $file

# =========================
# COPIAR MIFS PARA QUARTUS
# =========================
Move-Item -Force "data.mif" "../quartus/"
Move-Item -Force "instruction.mif" "../quartus/"

Set-Location ..

Write-Host "Assembler finalizado."