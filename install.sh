#!/bin/bash
# ============================================================
# Instalador del servidor WebRTC - Ubuntu 24
# Instala Node 20, dependencias, configura firewall
# y registra el servicio con systemd
# ============================================================

set -e

APP_NAME="webrtc-video-server"
APP_PORT=9010
APP_DIR="/opt/$APP_NAME"
SERVICE_USER="webrtc"
NODE_VERSION=20

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Verificar root
if [ "$EUID" -ne 0 ]; then
  err "Ejecuta este script como root: sudo bash install.sh"
fi

echo ""
echo "============================================"
echo "  Instalador $APP_NAME"
echo "============================================"
echo ""

# ---- 1. Actualizar sistema ----
log "Actualizando paquetes del sistema..."
apt-get update -y && apt-get upgrade -y

# ---- 2. Instalar dependencias del sistema ----
log "Instalando dependencias del sistema..."
apt-get install -y curl wget gnupg2 ca-certificates lsb-release ufw

# ---- 3. Instalar Node.js 20 ----
if command -v node &> /dev/null && node -v | grep -q "v${NODE_VERSION}"; then
  log "Node.js $(node -v) ya instalado"
else
  log "Instalando Node.js ${NODE_VERSION}..."
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
  apt-get install -y nodejs
  log "Node.js $(node -v) instalado"
fi

log "npm $(npm -v)"

# ---- 4. Crear usuario del servicio ----
if id "$SERVICE_USER" &>/dev/null; then
  log "Usuario '$SERVICE_USER' ya existe"
else
  log "Creando usuario '$SERVICE_USER'..."
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
  log "Usuario '$SERVICE_USER' creado"
fi

# ---- 5. Copiar archivos de la aplicacion ----
log "Copiando archivos a $APP_DIR..."
mkdir -p "$APP_DIR"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cp "$SCRIPT_DIR/package.json" "$APP_DIR/"
cp "$SCRIPT_DIR/package-lock.json" "$APP_DIR/" 2>/dev/null || true
cp "$SCRIPT_DIR/server.js" "$APP_DIR/"
cp -r "$SCRIPT_DIR/public" "$APP_DIR/"

# ---- 6. Instalar dependencias de Node ----
log "Instalando dependencias de Node.js..."
cd "$APP_DIR"
npm install --omit=dev

# ---- 7. Permisos ----
chown -R "$SERVICE_USER":"$SERVICE_USER" "$APP_DIR"
log "Permisos asignados a $SERVICE_USER"

# ---- 8. Crear servicio systemd ----
log "Configurando servicio systemd..."
cat > /etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=Servidor WebRTC Video Streaming
After=network.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_USER
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=PORT=$APP_PORT

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$APP_NAME

# Seguridad
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR

[Install]
WantedBy=multi-user.target
EOF

# ---- 9. Firewall ----
log "Configurando firewall (UFW)..."
ufw allow $APP_PORT/tcp comment "WebRTC Server"
ufw allow OpenSSH comment "SSH"
if ! ufw status | grep -q "Status: active"; then
  warn "Activando UFW..."
  echo "y" | ufw enable
fi
log "Puerto $APP_PORT abierto"

# ---- 10. Habilitar e iniciar servicio ----
systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl start "$APP_NAME"

# ---- 11. Verificar ----
sleep 2
if systemctl is-active --quiet "$APP_NAME"; then
  log "Servicio $APP_NAME activo y corriendo"
else
  err "El servicio no pudo iniciar. Revisa: journalctl -u $APP_NAME -n 50"
fi

echo ""
echo "============================================"
echo -e "  ${GREEN}Instalacion completada${NC}"
echo "============================================"
echo ""
echo "  Servidor:  http://$(hostname -I | awk '{print $1}'):$APP_PORT"
echo "  Broadcaster: http://$(hostname -I | awk '{print $1}'):$APP_PORT/broadcaster.html"
echo "  Viewer:      http://$(hostname -I | awk '{print $1}'):$APP_PORT/viewer.html?room=ROOM_ID"
echo ""
echo "  Comandos utiles:"
echo "    sudo systemctl status $APP_NAME    # Ver estado"
echo "    sudo systemctl restart $APP_NAME   # Reiniciar"
echo "    sudo systemctl stop $APP_NAME      # Detener"
echo "    sudo journalctl -u $APP_NAME -f    # Ver logs en vivo"
echo ""
