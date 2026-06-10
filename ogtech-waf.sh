#!/bin/bash

# ============================================================
# OGWAF Installer & Updater v2.0
# Fresh install: curl -sSL https://install.origrata.com/ogtech-waf.sh | bash -s -- --email user@example.com --password pass
# Update only:   curl -sSL https://install.origrata.com/ogtech-waf.sh | bash -s -- --update
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
BOLD='\033[1m'
INSTALL_DIR="/opt/ogwaf"
WAF_SERVER="https://waf-key.origrata.com/api/v1"
REGISTRY="ghcr.io/origrata"
MODE="install"

# Progress bar function
show_progress() {
    local current=$1
    local total=$2
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))
    
    printf "\r  [${GREEN}"
    printf "%${completed}s" | tr ' ' '='
    printf "${NC}"
    printf "%${remaining}s" | tr ' ' ' '
    printf "] ${GREEN}%3d%%${NC}" "$percentage"
}

# Spinner function for indeterminate progress
show_spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while ps -p "$pid" > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════╗"
echo "║         OGWAF Installer v2.0                 ║"
echo "║   Advanced Web Application Firewall          ║"
echo "╚══════════════════════════════════════════════╝"
echo -e "${NC}"

# ─── Check root ───
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}✗ Please run as root${NC}"; exit 1
fi

# ─── Parse arguments ───
while [[ $# -gt 0 ]]; do
  case $1 in
    --email) EMAIL="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --license-key) LICENSE_KEY="$2"; shift 2 ;;
    --update) MODE="update"; shift ;;
    --help)
      echo "Usage: install.sh [OPTIONS]"
      echo ""
      echo "Modes:"
      echo "  (default)      Fresh install (removes old data)"
      echo "  --update       Update only (keep database & config)"
      echo ""
      echo "Options:"
      echo "  --email        Email for auto-provisioning"
      echo "  --password     Password for account"
      echo "  --name         Server name (default: hostname)"
      echo "  --license-key  Existing license key (skip provisioning)"
      exit 0 ;;
    *) shift ;;
  esac
done

# ═══════════════════════════════════════════════════
# UPDATE MODE
# ═══════════════════════════════════════════════════
if [ "$MODE" = "update" ]; then
  echo -e "${CYAN}→ Mode: UPDATE (keep database & config)${NC}"
  cd "$INSTALL_DIR" 2>/dev/null || { echo -e "${RED}✗ OGWAF not installed at $INSTALL_DIR${NC}"; exit 1; }

  echo -e "${YELLOW}→ Pulling latest images...${NC}"
  
  # Pull with progress for update mode
  IMAGES=("waf-core" "api-server" "frontend")
  TOTAL_IMAGES=${#IMAGES[@]}
  CURRENT=0
  
  for img in "${IMAGES[@]}"; do
    CURRENT=$((CURRENT + 1))
    echo -ne "  Pulling $img... "
    if docker compose pull -q "$img" 2>/dev/null; then
      echo -e "${GREEN}✓${NC}"
    else
      echo -e "${RED}✗ Failed${NC}"
      exit 1
    fi
    show_progress "$CURRENT" "$TOTAL_IMAGES"
    echo ""
  done

  echo -e "${YELLOW}→ Recreating services...${NC}"
  if ! docker compose up -d --force-recreate --no-deps waf-core api-server frontend; then
    echo -e "${RED}✗ Failed to recreate services${NC}"
    exit 1
  fi

  echo -n "→ Waiting for services"
  for i in $(seq 1 30); do
    if docker compose exec -T waf-core wget -qO- --timeout=5 http://localhost:8080/health 2>/dev/null | grep -q "ok"; then
      echo ""
      echo -e "${GREEN}✓ Update complete!${NC}"
      break
    fi
    echo -n "."; sleep 2
  done
  echo ""
  exit 0
fi

# ═══════════════════════════════════════════════════
# FRESH INSTALL MODE
# ═══════════════════════════════════════════════════
echo -e "${CYAN}→ Mode: FRESH INSTALL${NC}"

# ─── Clean up old installation ───
echo -e "${YELLOW}→ Removing old installation...${NC}"

# Hentikan & hapus semua container dari image OGWAF
for img in ghcr.io/origrata/ogwaf ghcr.io/origrata/ogwaf-api-server ghcr.io/origrata/ogwaf-frontend; do
  docker rm -f $(docker ps -aq --filter "ancestor=$img") 2>/dev/null || true
done

# Hapus compose project jika directory masih ada
if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
  cd "$INSTALL_DIR"
  docker compose down -v --remove-orphans 2>/dev/null || true
  cd /
fi

# Hapus named volumes
for vol in pgdata redisdata; do
  docker volume rm -f "$vol" 2>/dev/null || true
done

# Hapus semua image OGWAF
docker rmi $(docker images "ghcr.io/origrata/ogwaf*" -q) 2>/dev/null || true

# Hapus directory & docker-compose.yml sisa
rm -rf "$INSTALL_DIR"

echo -e "${GREEN}✓ Old installation removed${NC}"

# ─── Prompt if not provided ───
if [ -z "$LICENSE_KEY" ]; then
  [ -z "$EMAIL" ] && read -p "Email: " EMAIL
  [ -z "$PASSWORD" ] && read -sp "Password: " PASSWORD && echo
fi
[ -z "$NAME" ] && NAME=$(hostname)

# ─── Detect OS ───
if [ -f /etc/os-release ]; then
  . /etc/os-release
  echo -e "${CYAN}→ OS: $PRETTY_NAME${NC}"
else
  echo -e "${RED}✗ Unsupported OS${NC}"; exit 1
fi

# ─── Install Docker ───
install_docker_rhel() {
  dnf install -y -q dnf-utils
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  if grep -qi "rocky\|almalinux\|rhel" /etc/os-release 2>/dev/null; then
    sed -i 's/^\$releasever/9/g' /etc/yum.repos.d/docker-ce.repo 2>/dev/null || true
  fi
  dnf install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin
}

if ! command -v docker &>/dev/null; then
  echo -e "${YELLOW}→ Installing Docker...${NC}"
  if grep -qi "rocky\|almalinux" /etc/os-release 2>/dev/null; then
    if ! install_docker_rhel; then
      echo -e "${RED}✗ Docker installation failed${NC}"
      exit 1
    fi
  elif ! curl -4 -fsSL https://get.docker.com | bash; then
    echo -e "${RED}✗ Docker installation failed${NC}"
    exit 1
  fi
  if ! systemctl enable --now docker; then
    echo -e "${RED}✗ Failed to enable Docker service${NC}"
    exit 1
  fi
  echo -e "${GREEN}✓ Docker installed${NC}"
else
  echo -e "${GREEN}✓ Docker found: $(docker --version | cut -d' ' -f3)${NC}"
fi

# ─── Install Docker Compose ───
if ! docker compose version &>/dev/null; then
  echo "Installing Docker Compose plugin..."
  if command -v apt-get &>/dev/null; then
      apt-get update -qq
      apt-get install -y -qq docker-compose-plugin
  elif command -v dnf &>/dev/null; then
      dnf install -y docker-compose-plugin
  elif command -v yum &>/dev/null; then
      yum install -y docker-compose-plugin
  else
      echo "No supported package manager found"
      exit 1
  fi
fi

# ─── Collect fingerprint ───
get_mac() {
  local iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
  [ -n "$iface" ] && cat /sys/class/net/$iface/address 2>/dev/null || echo "unknown"
}
get_cpu_id() {
  cat /sys/class/dmi/id/product_uuid 2>/dev/null || cat /etc/machine-id 2>/dev/null || hostname
}

MAC=$(get_mac)
CPU_ID=$(get_cpu_id)
PUBLIC_IP=$(curl -4 -s --max-time 5 https://ifconfig.me/ip || curl -4 -s --max-time 5 https://icanhazip.com || echo "unknown")
PRIVATE_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")
if [ -z "$PRIVATE_IP" ] || [ "$PRIVATE_IP" = "127.0.0.1" ]; then
  PRIVATE_IP="$PUBLIC_IP"
fi
INSTANCE_ID=$(hostname)

echo -e "${CYAN}→ Instance: $INSTANCE_ID${NC}"
echo -e "${CYAN}→ Public IP: $PUBLIC_IP${NC}"

# ─── Auto-Provision or use existing key ───
if [ -z "$LICENSE_KEY" ]; then
  echo -e "${YELLOW}→ Provisioning license...${NC}"
  RESPONSE=$(curl -4 -s --max-time 30 -X POST "$WAF_SERVER/license/auto-provision" \
    -H "Content-Type: application/json" \
    -d "{
      \"email\": \"$EMAIL\",
      \"password\": \"$PASSWORD\",
      \"name\": \"$NAME\",
      \"instance_id\": \"$INSTANCE_ID\",
      \"fingerprint\": {
        \"mac_address\": \"$MAC\",
        \"cpu_id\": \"$CPU_ID\",
        \"public_ip\": \"$PUBLIC_IP\",
        \"private_ip\": \"$PRIVATE_IP\"
      }
    }")

  SUCCESS=$(echo "$RESPONSE" | grep -o '"success":[[:space:]]*true' || true)
  if [ -z "$SUCCESS" ]; then
    echo -e "${RED}✗ Provisioning failed${NC}"
    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"
    if echo "$RESPONSE" | grep -qi "IP mismatch"; then
      echo ""
      echo -e "${YELLOW}  ── Debug Info ──${NC}"
      echo -e "  Public IP sent (fingerprint): ${CYAN}$PUBLIC_IP${NC}"
      echo -e "  Private IP sent (fingerprint): ${CYAN}$PRIVATE_IP${NC}"
      echo -e "  ${YELLOW}  ⚠ Server sees a different request IP (likely behind Cloudflare)${NC}"
    fi
    exit 1
  fi

  LICENSE_KEY=$(echo "$RESPONSE" | grep -o '"license_key":[[:space:]]*"[^"]*"' | cut -d'"' -f4)
  TIER=$(echo "$RESPONSE" | grep -o '"tier":[[:space:]]*"[^"]*"' | cut -d'"' -f4)
  MAX_DOMAINS=$(echo "$RESPONSE" | grep -o '"max_domains":[[:space:]]*[0-9]*' | cut -d: -f2)

  echo -e "${GREEN}✓ License: $LICENSE_KEY${NC}"
  echo -e "${GREEN}✓ Tier: $TIER (max $MAX_DOMAINS domains)${NC}"
else
  echo -e "${GREEN}✓ Using provided license key${NC}"
fi

# ─── Create install directory ───
mkdir -p "$INSTALL_DIR"/{certs,geoip}
cd "$INSTALL_DIR"

# ─── Download GeoIP database ───
if [ ! -f "$INSTALL_DIR/geoip/GeoLite2-Country.mmdb" ]; then
  echo -e "${YELLOW}→ Downloading GeoIP databases...${NC}"
  curl -4 -sSL "https://install.origrata.com/geoip/GeoLite2-Country.mmdb" -o "$INSTALL_DIR/geoip/GeoLite2-Country.mmdb" 2>/dev/null && \
    echo -e "${GREEN}✓ GeoIP Country downloaded${NC}" || \
    echo -e "${YELLOW}⚠ GeoIP Country download failed (optional)${NC}"
  curl -4 -sSL "https://install.origrata.com/geoip/GeoLite2-City.mmdb" -o "$INSTALL_DIR/geoip/GeoLite2-City.mmdb" 2>/dev/null && \
    echo -e "${GREEN}✓ GeoIP City downloaded${NC}" || \
    echo -e "${YELLOW}⚠ GeoIP City download failed (optional)${NC}"
fi

# ─── Generate .env ───
JWT_SECRET=$(openssl rand -hex 32)
DB_PASSWORD=$(openssl rand -hex 16)
REDIS_PASS=$(openssl rand -hex 16)

cat > .env <<EOF
# OGWAF Configuration (auto-generated)
LICENSE_KEY=${LICENSE_KEY}
LICENSE_SERVER_URL=${WAF_SERVER}
JWT_SECRET=${JWT_SECRET}
DB_HOST=postgres
DB_PORT=5432
DB_USER=waf
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=wafdb
REDIS_ADDR=redis:6379
REDIS_PASS=${REDIS_PASS}
SSL_EMAIL=${EMAIL:-admin@waf.local}
HTTP_PORT=80
HTTPS_PORT=443
API_PORT=8080
EOF
chmod 600 .env
echo -e "${GREEN}✓ Config generated${NC}"

# ─── Create docker-compose.yml ───
cat > docker-compose.yml <<'COMPOSE'
services:
  waf-core:
    image: ghcr.io/origrata/ogwaf:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    env_file: .env
    volumes:
      - ./certs:/app/certs
      - ./geoip:/app/geoip
      - /var/run/docker.sock:/var/run/docker.sock
    pid: host
    privileged: true
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  api-server:
    image: ghcr.io/origrata/ogwaf-api-server:latest
    restart: unless-stopped
    env_file: .env
    volumes:
      - ./certs:/app/certs
      - ./geoip:/app/geoip
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy

  frontend:
    image: ghcr.io/origrata/ogwaf-frontend:latest
    restart: unless-stopped
    ports:
      - "3000:443"
    depends_on:
      - api-server
    volumes:                                                                                                                                                                           
      - ./certs:/etc/nginx/ssl                                                                                                                                                                            - ./certs:/etc/nginx/ssl

  postgres:
    image: timescale/timescaledb:latest-pg16
    restart: unless-stopped
    environment:
      POSTGRES_DB: wafdb
      POSTGRES_USER: waf
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U waf -d wafdb"]
      interval: 5s
      timeout: 5s
      retries: 10

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    command: redis-server --requirepass ${REDIS_PASS} --appendonly yes
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "-a", "${REDIS_PASS}", "ping"]
      interval: 5s
      timeout: 3s
      retries: 5

volumes:
  pgdata:
  redisdata:
COMPOSE
echo -e "${GREEN}✓ docker-compose.yml created${NC}"

# ─── Pull images with progress bar ───
echo -e "${YELLOW}→ Pulling Docker images...${NC}"
echo ""

# List of images to pull
IMAGES=("waf-core" "api-server" "frontend" "postgres" "redis")
TOTAL_IMAGES=${#IMAGES[@]}
CURRENT=0

for img in "${IMAGES[@]}"; do
  CURRENT=$((CURRENT + 1))
  
  # Display current image being pulled
  printf "  [%d/%d] Pulling ${CYAN}%s${NC}...\n" "$CURRENT" "$TOTAL_IMAGES" "$img"
  
  # Pull with progress display
  if docker compose pull "$img" 2>&1 | while IFS= read -r line; do
    # Extract percentage from docker pull output
    if [[ $line =~ ([0-9]+)% ]]; then
      percent="${BASH_REMATCH[1]}"
      show_progress "$percent" 100
    fi
  done; then
    echo -e "\n  ${GREEN}✓ $img pulled successfully${NC}"
  else
    echo -e "\n  ${RED}✗ Failed to pull $img${NC}"
    exit 1
  fi
  echo ""
done

echo -e "${GREEN}✓ All images pulled successfully${NC}"
echo ""

# ─── Start services ───
echo -e "${YELLOW}→ Starting OGWAF services...${NC}"
if ! docker compose up -d; then
  echo -e "${RED}✗ Failed to start OGWAF services${NC}"
  exit 1
fi

# ─── Setup heartbeat cron ───
if ! cat > /etc/cron.d/ogwaf-heartbeat <<'CRON'
0 */6 * * * root /opt/ogwaf/heartbeat.sh >/dev/null 2>&1
CRON
then
  echo -e "${YELLOW}⚠ Failed to create cron file (continue anyway)${NC}"
fi

cat > "$INSTALL_DIR/heartbeat.sh" <<'HEARTBEAT'
#!/bin/bash
cd /opt/ogwaf
docker compose exec -T waf-core wget -qO- --timeout=5 http://localhost:8080/health >/dev/null 2>&1
if [ $? -ne 0 ]; then
  docker compose restart waf-core
fi
HEARTBEAT
chmod +x "$INSTALL_DIR/heartbeat.sh"

# ─── Wait for healthy with improved method ───
echo -n "→ Waiting for services to be ready"
HEALTH_OK=0

# Give initial delay for containers to start properly
sleep 10

# Check and wait for services with improved method
for i in $(seq 1 90); do
  # Check if waf-core container is running
  if docker ps | grep -q "ogwaf-waf-core"; then
    # Try health check with curl (more reliable than wget)
    if docker compose exec -T waf-core sh -c "curl -s http://localhost:8080/health 2>/dev/null | grep -q 'ok'" 2>/dev/null; then
      echo ""
      echo -e "${GREEN}✓ OGWAF is running!${NC}"
      HEALTH_OK=1
      break
    fi
    
    # Alternative check using wget
    if docker compose exec -T waf-core wget -qO- --timeout=5 http://localhost:8080/health 2>/dev/null | grep -q "ok"; then
      echo ""
      echo -e "${GREEN}✓ OGWAF is running!${NC}"
      HEALTH_OK=1
      break
    fi
  fi
  
  # Progress indicator
  echo -n "."
  
  # Show status every 30 seconds for debugging
  if [ $((i % 10)) -eq 0 ]; then
    echo -n " (${i}s)"
  fi
  
  sleep 3
done

# If health check still fails, show diagnostic info but continue
if [ $HEALTH_OK -eq 0 ]; then
  echo ""
  echo -e "${YELLOW}⚠ Health check timeout after 90 seconds${NC}"
  echo -e "${YELLOW}  Container status:${NC}"
  docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
  echo -e "${GREEN}  Continuing with installation...${NC}"
fi

# ─── Update super admin credentials ───
if [ -n "$EMAIL" ] && [ -n "$PASSWORD" ]; then
  echo -e "${YELLOW}→ Updating admin credentials...${NC}"

  # Capture ke local variable agar tidak hilang di subshell
  _EMAIL="$EMAIL"
  _PASSWORD="$PASSWORD"

  # Wait for database to be ready
  echo -n "  Waiting for database"
  DB_READY=0
  for i in $(seq 1 30); do
    if docker compose exec -T postgres pg_isready -U waf -d wafdb >/dev/null 2>&1; then
      DB_READY=1
      echo ""
      break
    fi
    echo -n "."
    sleep 2
  done
  
  if [ $DB_READY -eq 0 ]; then
    echo ""
    echo -e "${YELLOW}  ⚠ Database not ready, skipping credential update${NC}"
  else
    # Wait a bit more for migrations
    sleep 5
    
    # Check if users table exists
    TABLE_EXISTS=0
    for i in $(seq 1 20); do
      if docker compose exec -T postgres psql -U waf -d wafdb -c "SELECT 1 FROM users LIMIT 1" >/dev/null 2>&1; then
        TABLE_EXISTS=1
        break
      fi
      sleep 2
    done
    
    if [ $TABLE_EXISTS -eq 0 ]; then
      echo -e "${YELLOW}  ⚠ Users table not ready, skipping credential update${NC}"
    else
      # Escape single quotes for SQL safety
      _EMAIL_ESC=$(printf '%s' "$_EMAIL" | sed "s/'/''/g")
      _PASSWORD_ESC=$(printf '%s' "$_PASSWORD" | sed "s/'/''/g")

      # Update super admin credentials
      SQL="UPDATE users SET email = '$_EMAIL_ESC', password_hash = crypt('$_PASSWORD_ESC', gen_salt('bf', 10)) WHERE role = 'super_admin' AND email = 'admin@waf.local';"
      
      if echo "$SQL" | docker compose exec -T postgres psql -U waf -d wafdb >/dev/null 2>&1; then
        echo -e "${GREEN}  ✓ Admin credentials updated (login: $_EMAIL)${NC}"
      else
        echo -e "${YELLOW}  ⚠ Could not update admin credentials (default: admin@waf.local / admin123)${NC}"
      fi
    fi
  fi
fi

# ─── Final check before summary ───
echo ""
echo -e "${CYAN}→ Final verification...${NC}"

# Try one more health check if it failed earlier
if [ $HEALTH_OK -eq 0 ]; then
  echo -n "  Checking services one more time"
  for i in $(seq 1 15); do
    if docker compose exec -T waf-core sh -c "curl -s http://localhost:8080/health 2>/dev/null | grep -q 'ok'" 2>/dev/null; then
      echo ""
      echo -e "${GREEN}  ✓ OGWAF is now running!${NC}"
      HEALTH_OK=1
      break
    fi
    echo -n "."
    sleep 2
  done
  echo ""
fi

# ─── Print summary ───
echo ""
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}  OGWAF Installation Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""

if [ $HEALTH_OK -eq 1 ]; then
  echo -e "  Status:     ${GREEN}● Running${NC}"
else
  echo -e "  Status:     ${YELLOW}● Starting (check with 'docker compose ps')${NC}"
fi

echo -e "  Dashboard:  ${CYAN}https://${PUBLIC_IP}:3000${NC}"
echo -e "  WAF HTTP:   ${CYAN}http://${PUBLIC_IP}:80${NC}"
echo -e "  WAF HTTPS:  ${CYAN}https://${PUBLIC_IP}:443${NC}"

if [ -n "$EMAIL" ] && [ -n "$PASSWORD" ]; then
  echo -e "  Login:      ${GREEN}${EMAIL}${NC} / ${GREEN}${PASSWORD}${NC}"
else
  echo -e "  Login:      ${YELLOW}admin@waf.local${NC} / ${YELLOW}admin123${NC}"
fi

echo ""
echo -e "  Portal:     ${CYAN}https://portal.origrata.com${NC}"
echo -e "  License:    ${GREEN}$LICENSE_KEY${NC}"
echo ""
echo -e "${YELLOW}   Change default password immediately!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "  Manage:  cd $INSTALL_DIR && docker compose [logs|restart|stop]"
echo -e "  Update:  curl -sSL https://install.origrata.com/ogtech-waf.sh | bash -s -- --update"
echo ""

# Show running containers
if docker ps | grep -q "ogwaf"; then
  echo -e "${CYAN}→ Running containers:${NC}"
  docker ps --format "table {{.Names}}\t{{.Status}}" | grep -E "ogwaf|NAMES"
  echo ""
fi

exit 0
