#!/bin/bash
# ============================================================================
#  Apply MSA620 - aplica configuracoes do repositorio no sistema
#  Rode esse script depois de cada 'git pull' para aplicar mudancas
# ============================================================================

set -e
set -u

# ----------- CONFIGURACOES --------------------------------------------------
USERNAME="msa620"
SERVICE_NAME="msa620"
PLYMOUTH_THEME="msa620"
# Diretorio do proprio repositorio (onde esse script esta)
SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# ----------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[X]${NC} $1"; exit 1; }

if [ "$EUID" -eq 0 ]; then
    err "Nao rode como root. Rode como $USERNAME."
fi
if [ "$USER" != "$USERNAME" ]; then
    err "Rode este script como $USERNAME (voce e $USER)."
fi

log "Aplicando configuracoes a partir de: $SERVICES_DIR"

# ============================================================================
# 1. Aplicar tema Plymouth
# ============================================================================
if [ -d "$SERVICES_DIR/plymouth" ]; then
    log "Aplicando tema Plymouth '$PLYMOUTH_THEME'..."
    THEME_DIR="/usr/share/plymouth/themes/$PLYMOUTH_THEME"

    # Limpa frames antigos para evitar acumulo
    if [ -d "$THEME_DIR" ]; then
        sudo rm -f "$THEME_DIR"/*.png
    fi
    sudo mkdir -p "$THEME_DIR"

    # Copia arquivos do tema
    if [ -f "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.plymouth" ]; then
        sudo cp "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.plymouth" "$THEME_DIR/"
    else
        warn "$PLYMOUTH_THEME.plymouth nao encontrado"
    fi

    if [ -f "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.script" ]; then
        sudo cp "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.script" "$THEME_DIR/"
    else
        warn "$PLYMOUTH_THEME.script nao encontrado"
    fi

    # Copia frames
    if [ -d "$SERVICES_DIR/plymouth/frames" ]; then
        log "Copiando frames..."
        sudo cp "$SERVICES_DIR/plymouth/frames/"*.png "$THEME_DIR/"
    fi

    # Define como tema padrao
    sudo plymouth-set-default-theme "$PLYMOUTH_THEME"

    # Atualiza initramfs (necessario para Plymouth carregar o tema novo)
    log "Atualizando initramfs (pode demorar)..."
    sudo update-initramfs -u
else
    warn "Pasta plymouth/ nao encontrada"
fi

# ============================================================================
# 2. Aplicar systemd service
# ============================================================================
if [ -f "$SERVICES_DIR/systemd/$SERVICE_NAME.service" ]; then
    log "Instalando $SERVICE_NAME.service..."
    USER_SYSTEMD_DIR="/home/$USERNAME/.config/systemd/user"
    mkdir -p "$USER_SYSTEMD_DIR"
    cp "$SERVICES_DIR/systemd/$SERVICE_NAME.service" "$USER_SYSTEMD_DIR/"

    systemctl --user daemon-reload
    systemctl --user enable "$SERVICE_NAME.service"
    log "Servico habilitado"
else
    warn "systemd/$SERVICE_NAME.service nao encontrado"
fi

echo ""
echo -e "${GREEN}Configuracoes aplicadas!${NC}"
echo ""
echo "Para reiniciar o servico agora:"
echo "    systemctl --user restart $SERVICE_NAME.service"
echo ""
echo "Para aplicar tudo do zero (recomendado):"
echo "    sudo reboot"
echo ""
