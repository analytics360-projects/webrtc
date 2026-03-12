#!/bin/bash
# ============================================================
# Instalador del servidor WebRTC - Ubuntu 24
# Instala Node 20, dependencias, configura firewall, SSL
# y registra el servicio con systemd
# ============================================================

set -e

APP_NAME="webrtc-video-server"
APP_PORT=9010
APP_DIR="/opt/$APP_NAME"
SSL_DIR="$APP_DIR/ssl"
SERVICE_USER="webrtc"
NODE_VERSION=20

# Colores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[i]${NC} $1"; }

# Verificar root
if [ "$EUID" -ne 0 ]; then
  err "Ejecuta este script como root: sudo bash install.sh"
fi

echo ""
echo "============================================"
echo "  Instalador $APP_NAME"
echo "============================================"
echo ""

# ---- Preguntar tipo de SSL ----
echo -e "${CYAN}Selecciona el tipo de SSL:${NC}"
echo "  1) Let's Encrypt (necesitas un dominio publico apuntando a este servidor)"
echo "  2) Certificado autofirmado (para red interna / pruebas)"
echo "  3) Sin SSL (solo HTTP)"
echo ""
read -p "Opcion [1/2/3]: " SSL_OPTION

DOMAIN=""
if [ "$SSL_OPTION" = "1" ]; then
  read -p "Dominio (ej: webrtc.tudominio.com): " DOMAIN
  if [ -z "$DOMAIN" ]; then
    err "Debes ingresar un dominio para Let's Encrypt"
  fi
fi

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

# ---- 7. Configurar SSL ----
mkdir -p "$SSL_DIR"

if [ "$SSL_OPTION" = "1" ]; then
  # --- Let's Encrypt ---
  log "Instalando certbot..."
  apt-get install -y certbot

  log "Obteniendo certificado para $DOMAIN..."
  certbot certonly --standalone --non-interactive --agree-tos \
    --register-unsafely-without-email \
    --preferred-challenges http \
    -d "$DOMAIN" \
    --pre-hook "systemctl stop $APP_NAME 2>/dev/null || true" \
    --post-hook "systemctl start $APP_NAME 2>/dev/null || true"

  # Symlinks a los certificados
  ln -sf "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" "$SSL_DIR/cert.pem"
  ln -sf "/etc/letsencrypt/live/$DOMAIN/privkey.pem" "$SSL_DIR/key.pem"

  # Cron para renovacion automatica
  cat > /etc/cron.d/webrtc-certbot-renew <<EOF
0 3 * * * root certbot renew --quiet --pre-hook "systemctl stop $APP_NAME" --post-hook "systemctl start $APP_NAME"
EOF

  log "Certificado Let's Encrypt configurado para $DOMAIN"
  log "Renovacion automatica configurada (cada dia a las 3am)"

elif [ "$SSL_OPTION" = "2" ]; then
  # --- Certificado autofirmado ---
  log "Generando certificado autofirmado..."

  SERVER_IP=$(hostname -I | awk '{print $1}')

  openssl req -x509 -nodes -days 365 \
    -newkey rsa:2048 \
    -keyout "$SSL_DIR/key.pem" \
    -out "$SSL_DIR/cert.pem" \
    -subj "/C=MX/ST=CDMX/L=CDMX/O=WebRTC/CN=$SERVER_IP" \
    -addext "subjectAltName=IP:$SERVER_IP,IP:127.0.0.1,DNS:localhost"

  log "Certificado autofirmado generado (valido 365 dias)"
  warn "Los navegadores mostraran advertencia de seguridad (es normal)"

else
  # --- Sin SSL ---
  info "Sin SSL configurado, el servidor correra en HTTP"
  rm -rf "$SSL_DIR"
fi

# ---- 8. Permisos ----
chown -R "$SERVICE_USER":"$SERVICE_USER" "$APP_DIR"
# Permisos de lectura en certificados para el usuario del servicio
if [ -d "$SSL_DIR" ]; then
  chmod 750 "$SSL_DIR"
  chmod 640 "$SSL_DIR"/*.pem 2>/dev/null || true
fi
log "Permisos asignados a $SERVICE_USER"

# ---- 9. Crear servicio systemd ----
log "Configurando servicio systemd..."

# Variables de entorno para SSL con Let's Encrypt (symlinks necesitan acceso)
SSL_ENV=""
if [ "$SSL_OPTION" = "1" ]; then
  SSL_ENV="Environment=SSL_CERT=$SSL_DIR/cert.pem
Environment=SSL_KEY=$SSL_DIR/key.pem"
  # El usuario necesita acceso a los certs de letsencrypt
  usermod -aG ssl-cert "$SERVICE_USER" 2>/dev/null || true
  chmod 0755 /etc/letsencrypt/live/ 2>/dev/null || true
  chmod 0755 /etc/letsencrypt/archive/ 2>/dev/null || true
fi

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
$SSL_ENV

# Logs
StandardOutput=journal
StandardError=journal
SyslogIdentifier=$APP_NAME

# Seguridad
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR
ReadOnlyPaths=/etc/letsencrypt

[Install]
WantedBy=multi-user.target
EOF

# ---- 10. Firewall ----
log "Configurando firewall (UFW)..."
ufw allow $APP_PORT/tcp comment "WebRTC Server"
ufw allow OpenSSH comment "SSH"
if [ "$SSL_OPTION" = "1" ]; then
  ufw allow 80/tcp comment "HTTP (certbot)"
fi
if ! ufw status | grep -q "Status: active"; then
  warn "Activando UFW..."
  echo "y" | ufw enable
fi
log "Puerto $APP_PORT abierto"

# ---- 11. Habilitar e iniciar servicio ----
systemctl daemon-reload
systemctl enable "$APP_NAME"
systemctl start "$APP_NAME"

# ---- 12. Verificar ----
sleep 2
if systemctl is-active --quiet "$APP_NAME"; then
  log "Servicio $APP_NAME activo y corriendo"
else
  err "El servicio no pudo iniciar. Revisa: journalctl -u $APP_NAME -n 50"
fi

# ---- Resumen ----
SERVER_IP=$(hostname -I | awk '{print $1}')
if [ "$SSL_OPTION" = "1" ]; then
  PROTO="https"
  HOST="$DOMAIN"
elif [ "$SSL_OPTION" = "2" ]; then
  PROTO="https"
  HOST="$SERVER_IP"
else
  PROTO="http"
  HOST="$SERVER_IP"
fi

echo ""
echo "============================================"
echo -e "  ${GREEN}Instalacion completada${NC}"
echo "============================================"
echo ""
echo "  Servidor:    ${PROTO}://${HOST}:${APP_PORT}"
echo "  Broadcaster: ${PROTO}://${HOST}:${APP_PORT}/broadcaster.html"
echo "  Viewer:      ${PROTO}://${HOST}:${APP_PORT}/viewer.html?room=ROOM_ID"
echo ""
if [ "$SSL_OPTION" = "2" ]; then
  echo -e "  ${YELLOW}Nota: Certificado autofirmado - aceptar advertencia en el navegador${NC}"
  echo ""
fi
echo "  Comandos utiles:"
echo "    sudo systemctl status $APP_NAME    # Ver estado"
echo "    sudo systemctl restart $APP_NAME   # Reiniciar"
echo "    sudo systemctl stop $APP_NAME      # Detener"
echo "    sudo journalctl -u $APP_NAME -f    # Ver logs en vivo"
echo ""
