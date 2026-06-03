#!/bin/bash
# ============================================================================
#  Setup Inicial MSA620 - Raspberry Pi 4
#  Roda UMA VEZ num Pi OS Lite recem-instalado, de DENTRO da pasta ja clonada
#  Configura o sistema, compila o driver e aplica plymouth + labwc + service
#  NAO mexe na aplicacao Python (isso vai por pendrive depois)
# ============================================================================

set -e
set -u

# ----------- CONFIGURACOES --------------------------------------------------
USERNAME="msa620"
SERVICE_NAME="msa620"
PLYMOUTH_THEME="msa620"
PLYMOUTH_SET="intro_2"   # conjunto de frames ativo (intro_1 = animacao antiga)
SCREEN_WIDTH=800
SCREEN_HEIGHT=480
# Diretorio do proprio repositorio (onde esse script esta) - ja clonado manualmente
SERVICES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# Obs: git ja vem (foi usado pra clonar) e o build do driver (secao 7) assume
# gcc/make + headers do kernel ja presentes na imagem. Se trocar pra uma imagem
# que nao tenha, re-adicione aqui: build-essential e linux-headers-$(uname -r).
sudo apt install -y \
    python3-pip \
    python3-venv \
    labwc \
    wtype \
    seatd \
    weston \
    xwayland \
    plymouth \
    plymouth-themes \
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

# Sem a tela rainbow do firmware durante o POST
disable_splash=1
EOF
fi

# ============================================================================
# 6. Console: autologin (quieto) + tty1 limpo no handoff Plymouth->labwc
# ============================================================================
log "Configurando console (autologin quieto + tty1 limpo)..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d/
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf >/dev/null <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noissue --noclear %I \$TERM
EOF

# Sem MOTD / "Last login" no login automatico
touch "/home/$USERNAME/.hushlogin"

# O labwc sobe via linger, entao o getty do tty1 e dispensavel. Mascarar tira o
# "(automatic login)" + o prompt que apareciam no tty1 entre o Plymouth e o labwc.
# (Se num flash novo o labwc nao subir, desmascare:
#  sudo systemctl unmask getty@tty1.service)
sudo systemctl mask getty@tty1.service

sudo systemctl set-default multi-user.target

# ============================================================================
# 7. Compilar e instalar o driver do teclado (modulo de kernel + overlay)
# ============================================================================
if [ -d "$SERVICES_DIR/keyboard" ]; then
    log "Compilando e instalando driver do teclado MSA620..."
    cd "$SERVICES_DIR/keyboard"
    sudo make
    sudo make install
    cd "$SERVICES_DIR"
else
    warn "Pasta keyboard/ nao encontrada, driver nao instalado."
fi

# ============================================================================
# 8. Plymouth, config do labwc e systemd service (antes era o apply.sh)
# ============================================================================

# --- Tema Plymouth ---
if [ -d "$SERVICES_DIR/plymouth" ]; then
    log "Aplicando tema Plymouth '$PLYMOUTH_THEME'..."
    THEME_DIR="/usr/share/plymouth/themes/$PLYMOUTH_THEME"
    [ -d "$THEME_DIR" ] && sudo rm -f "$THEME_DIR"/*.png
    sudo mkdir -p "$THEME_DIR"
    sudo cp "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.plymouth" "$THEME_DIR/"
    sudo cp "$SERVICES_DIR/plymouth/$PLYMOUTH_THEME.script" "$THEME_DIR/"
    sudo cp "$SERVICES_DIR/plymouth/$PLYMOUTH_SET/"*.png "$THEME_DIR/"
    sudo plymouth-set-default-theme "$PLYMOUTH_THEME"
    log "Atualizando initramfs (pode demorar)..."
    sudo update-initramfs -u
else
    warn "Pasta plymouth/ nao encontrada"
fi

# --- Config do labwc (compositor) ---
if [ -d "$SERVICES_DIR/labwc" ]; then
    log "Instalando config do labwc..."
    LABWC_DIR="/home/$USERNAME/.config/labwc"
    mkdir -p "$LABWC_DIR"
    cp "$SERVICES_DIR/labwc/"* "$LABWC_DIR/"
else
    warn "Pasta labwc/ nao encontrada"
fi

# --- systemd user service ---
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
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN}  Setup do sistema concluido!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo ""
echo "Sistema preparado. Driver, Plymouth, labwc e service (labwc) aplicados."
echo ""
echo "Proximos passos (manuais):"
echo "  - Copiar codigo Python para /opt/msa620_app/ via pendrive"
echo "  - Criar venv e instalar dependencias"
echo "  - sudo reboot"
echo ""
