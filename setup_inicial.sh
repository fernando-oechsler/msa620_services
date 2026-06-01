#!/bin/bash
# ============================================================================
#  Setup Inicial MSA620 - Raspberry Pi 4
#  Roda UMA VEZ num Pi OS Lite recem-instalado
#  Configura o sistema, clona o repo de configuracoes e aplica plymouth+service
#  NAO mexe na aplicacao Python (isso vai por pendrive depois)
# ============================================================================

set -e
set -u

# ----------- CONFIGURACOES --------------------------------------------------
REPO_URL="https://github.com/fernando-oechsler/msa620.git"
SERVICES_DIR="/opt/msa620_services"
USERNAME="msa620"
SCREEN_WIDTH=800
SCREEN_HEIGHT=480
# ----------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[X]${NC} $1"; exit 1; }

# Validacoes
if [ "$EUID" -eq 0 ]; then
    err "Nao rode como root. Rode como $USERNAME."
fi
if [ "$USER" != "$USERNAME" ]; then
    err "Rode este script como $USERNAME (voce e $USER)."
fi

log "Verificando internet..."
if ! ping -c 1 -W 5 github.com &>/dev/null; then
    err "Sem internet."
fi

# ============================================================================
# 1. Sistema base
# ============================================================================
log "Atualizando sistema..."
sudo apt update
sudo apt upgrade -y

log "Instalando pacotes..."
sudo apt install -y \
    git \
    python3-pip \
    python3-venv \
    cage \
    seatd \
    weston \
    xwayland \
    plymouth \
    plymouth-themes \
    ffmpeg \
    libgles2 \
    libgl1 \
    libegl1 \
    libfontconfig1 \
    libdbus-1-3 \
    libxkbcommon0

# ============================================================================
# 2. Grupos e permissoes do usuario
# ============================================================================
log "Adicionando $USERNAME aos grupos..."
sudo usermod -aG video,input,tty,render,gpio "$USERNAME" || true
if getent group seat &>/dev/null; then
    sudo usermod -aG seat "$USERNAME"
fi

# ============================================================================
# 3. seatd e linger
# ============================================================================
log "Habilitando seatd..."
sudo systemctl enable seatd
sudo systemctl start seatd || true

log "Habilitando linger para $USERNAME..."
sudo loginctl enable-linger "$USERNAME"

# ============================================================================
# 4. Boot silencioso (cmdline.txt)
# ============================================================================
log "Configurando boot silencioso..."
CMDLINE_FILE="/boot/firmware/cmdline.txt"
[ ! -f "${CMDLINE_FILE}.bak" ] && sudo cp "$CMDLINE_FILE" "${CMDLINE_FILE}.bak"

CMDLINE=$(cat "$CMDLINE_FILE")
for PARAM in "quiet" "splash" "loglevel=3" "logo.nologo" "vt.global_cursor_default=0" "plymouth.ignore-serial-consoles"; do
    if ! echo "$CMDLINE" | grep -q "$PARAM"; then
        CMDLINE="$CMDLINE $PARAM"
    fi
done
echo "$CMDLINE" | sudo tee "$CMDLINE_FILE" >/dev/null

# ============================================================================
# 5. Resolucao fixa (config.txt)
# ============================================================================
log "Configurando resolucao $SCREEN_WIDTH x $SCREEN_HEIGHT..."
CONFIG_FILE="/boot/firmware/config.txt"
[ ! -f "${CONFIG_FILE}.bak" ] && sudo cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

if ! grep -q "hdmi_cvt=$SCREEN_WIDTH $SCREEN_HEIGHT" "$CONFIG_FILE"; then
    sudo tee -a "$CONFIG_FILE" >/dev/null <<EOF

# MSA620 - resolucao fixa
hdmi_group=2
hdmi_mode=87
hdmi_cvt=$SCREEN_WIDTH $SCREEN_HEIGHT 60 6 0 0 0
hdmi_force_hotplug=1
EOF
fi

# ============================================================================
# 6. Autologin no console
# ============================================================================
log "Configurando autologin..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
EOF

sudo systemctl set-default multi-user.target

# ============================================================================
# 7. Clonar o repositorio de configuracoes
# ============================================================================
log "Clonando configuracoes em $SERVICES_DIR..."
sudo mkdir -p "$SERVICES_DIR"
sudo chown "$USERNAME:$USERNAME" "$SERVICES_DIR"

if [ -d "$SERVICES_DIR/.git" ]; then
    warn "Repositorio ja existe, fazendo pull..."
    cd "$SERVICES_DIR"
    git pull
else
    if [ "$(ls -A $SERVICES_DIR 2>/dev/null)" ]; then
        warn "Diretorio nao vazio, limpando..."
        sudo rm -rf "$SERVICES_DIR"/* "$SERVICES_DIR"/.[!.]* 2>/dev/null || true
    fi
    git clone "$REPO_URL" "$SERVICES_DIR"
fi

# ============================================================================
# 8. Executar o apply.sh do repositorio
# ============================================================================
if [ -f "$SERVICES_DIR/apply.sh" ]; then
    log "Executando apply.sh..."
    chmod +x "$SERVICES_DIR/apply.sh"
    bash "$SERVICES_DIR/apply.sh"
else
    warn "apply.sh nao encontrado no repositorio."
fi

echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Setup do sistema concluido!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Sistema preparado. Plymouth e service ja aplicados."
echo ""
echo "Proximos passos (manuais):"
echo "  - Copiar codigo Python para /opt/msa620/ via pendrive"
echo "  - Criar venv e instalar dependencias"
echo "  - sudo reboot"
echo ""
echo "Para atualizar configuracoes futuras:"
echo "  cd $SERVICES_DIR && git pull && ./apply.sh"
echo ""
