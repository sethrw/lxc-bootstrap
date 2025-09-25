#!/bin/bash

# LXC App Bootstrap Script
# Usage: wget https://raw.githubusercontent.com/yourusername/lxc-bootstrap/main/bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_skip() { echo -e "${YELLOW}⏭️  $1 (already done)${NC}"; }

# Progress tracking
BOOTSTRAP_DIR="/var/lib/lxc-bootstrap"
PROGRESS_FILE="$BOOTSTRAP_DIR/progress"
CONFIG_FILE="$BOOTSTRAP_DIR/config"

# Initialize progress tracking
init_progress() {
    mkdir -p "$BOOTSTRAP_DIR"
    touch "$PROGRESS_FILE" "$CONFIG_FILE"
}

# Check if step completed
check_step() {
    grep -q "^$1$" "$PROGRESS_FILE" 2>/dev/null
}

# Mark step completed
mark_step() {
    echo "$1" >> "$PROGRESS_FILE"
}

# Save configuration
save_config() {
    grep -v "^$1=" "$CONFIG_FILE" 2>/dev/null > "$CONFIG_FILE.tmp" || true
    echo "$1=$2" >> "$CONFIG_FILE.tmp"
    mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
}

# Load configuration
load_config() {
    grep "^$1=" "$CONFIG_FILE" 2>/dev/null | cut -d= -f2-
}

# Banner
echo -e "${BLUE}"
cat << "EOF"
🚀 LXC App Bootstrap
====================
Deploy your Nuxt app with database and CI/CD
EOF
echo -e "${NC}"

# Must run with administrator privileges
if [ "$EUID" -ne 0 ]; then
    log_error "Please run with administrator privileges"
    exit 1
fi

# Get container IP
CONTAINER_IP=$(hostname -I | awk '{print $1}')
log_info "Container IP: $CONTAINER_IP"

# Initialize tracking
init_progress

# Check for previous configuration
if [ -s "$CONFIG_FILE" ]; then
    log_info "Found previous configuration"
    APP_NAME=$(load_config "APP_NAME")
    if [ -n "$APP_NAME" ]; then
        log_info "Previous app: $APP_NAME"
        read -p "Continue with existing setup? [Y/n]: " CONTINUE
        if [[ "$CONTINUE" =~ ^[Nn]$ ]]; then
            rm -f "$PROGRESS_FILE" "$CONFIG_FILE"
            APP_NAME=""
        fi
    fi
fi

# Configuration prompts
if [ -z "$APP_NAME" ]; then
    echo ""
    log_info "App configuration:"
    
    read -p "App name (lowercase, no spaces, e.g. my-app): " APP_NAME
    [[ -z "$APP_NAME" ]] && { log_error "App name required"; exit 1; }
    save_config "APP_NAME" "$APP_NAME"
    
    read -p "GitHub SSH URL (git@github.com:username/repository.git): " GITHUB_REPO
    [[ -z "$GITHUB_REPO" ]] && { log_error "GitHub repo required"; exit 1; }
    save_config "GITHUB_REPO" "$GITHUB_REPO"
    
    echo "Database options:"
    echo "  1) PocketBase (SQLite + web admin)"
    echo "  2) PostgreSQL"
    read -p "Database choice [1]: " DB_CHOICE
    DB_CHOICE=${DB_CHOICE:-1}
    save_config "DB_CHOICE" "$DB_CHOICE"
    
    # Database credentials
    if [ "$DB_CHOICE" = "1" ]; then
        read -p "PocketBase admin email [admin@$APP_NAME.local]: " PB_EMAIL
        PB_EMAIL=${PB_EMAIL:-admin@$APP_NAME.local}
        read -s -p "PocketBase admin password: " PB_PASSWORD
        echo ""
        [[ -z "$PB_PASSWORD" ]] && { log_error "Password required"; exit 1; }
        save_config "PB_EMAIL" "$PB_EMAIL"
        save_config "PB_PASSWORD" "$PB_PASSWORD"
    else
        read -p "PostgreSQL username [${APP_NAME//[-.]/_}user]: " DB_USER
        DB_USER=${DB_USER:-${APP_NAME//[-.]/_}user}
        read -s -p "PostgreSQL password: " DB_PASSWORD
        echo ""
        [[ -z "$DB_PASSWORD" ]] && { log_error "Password required"; exit 1; }
        save_config "DB_USER" "$DB_USER"
        save_config "DB_PASSWORD" "$DB_PASSWORD"
    fi
    
    # CI/CD setup - always required
    echo ""
    log_info "CI/CD configuration (required):"
    read -p "GitHub personal access token (needs 'repo' permissions): " GITHUB_TOKEN
    [[ -z "$GITHUB_TOKEN" ]] && { 
        log_error "GitHub token required for CI/CD setup"
        log_error "Create token at: https://github.com/settings/tokens"
        log_error "Grant 'repo' permission and re-run script"
        exit 1
    }
    
    read -p "Toolbox server IP address (where GitHub runner is installed): " TOOLBOX_IP
    [[ -z "$TOOLBOX_IP" ]] && { 
        log_error "Toolbox IP required for CI/CD setup"
        log_error "This should be the IP of your management server"
        exit 1
    }
    
    save_config "GITHUB_TOKEN" "$GITHUB_TOKEN"
    save_config "TOOLBOX_IP" "$TOOLBOX_IP"
    save_config "SETUP_CICD" "true"
else
    # Load existing config
    GITHUB_REPO=$(load_config "GITHUB_REPO")
    DB_CHOICE=$(load_config "DB_CHOICE")
    PB_EMAIL=$(load_config "PB_EMAIL")
    PB_PASSWORD=$(load_config "PB_PASSWORD")
    DB_USER=$(load_config "DB_USER")
    DB_PASSWORD=$(load_config "DB_PASSWORD")
    SETUP_CICD=$(load_config "SETUP_CICD")
    GITHUB_TOKEN=$(load_config "GITHUB_TOKEN")
    TOOLBOX_IP=$(load_config "TOOLBOX_IP")
fi

echo ""
log_info "Starting setup..."

# =============================================================================
# SYSTEM SETUP
# =============================================================================

if ! check_step "system_setup"; then
    log_info "Installing system packages..."
    apt update
    apt install -y curl wget git openssh-server ufw unzip sudo
    
    # Configure SSH
    log_info "Configuring SSH..."
    sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    sed -i 's/PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    systemctl restart sshd
    systemctl enable ssh
    
    mark_step "system_setup"
else
    log_skip "System setup"
fi

# =============================================================================
# NODE.JS SETUP
# =============================================================================

if ! check_step "nodejs_setup"; then
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt install -y nodejs
    else
        log_info "Node.js already installed: $(node --version)"
    fi
    
    if ! command -v pm2 &>/dev/null; then
        log_info "Installing PM2..."
        npm install -g pm2
    else
        log_info "PM2 already installed: $(pm2 --version)"
    fi
    
    mark_step "nodejs_setup"
else
    log_skip "Node.js setup"
fi

# =============================================================================
# DATABASE SETUP
# =============================================================================

if [ "$DB_CHOICE" = "1" ] && ! check_step "pocketbase_setup"; then
    log_info "Setting up PocketBase..."
    
    mkdir -p /opt/pocketbase
    cd /opt/pocketbase
    
    if [ ! -f "pocketbase" ]; then
        PB_VERSION=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | grep -o '"tag_name": "[^"]*"' | cut -d'"' -f4)
        PB_URL="https://github.com/pocketbase/pocketbase/releases/download/${PB_VERSION}/pocketbase_${PB_VERSION#v}_linux_amd64.zip"
        wget -q "$PB_URL" -O pocketbase.zip
        unzip -q pocketbase.zip
        rm pocketbase.zip
        chmod +x pocketbase
    fi
    
    # Create PM2 config
    cat > ecosystem.config.cjs << EOF
module.exports = {
  apps: [{
    name: 'pocketbase',
    script: './pocketbase',
    args: 'serve --http=0.0.0.0:8090',
    cwd: '/opt/pocketbase'
  }]
};
EOF
    
    # Start PocketBase
    pm2 start ecosystem.config.cjs
    sleep 5
    
    # Create admin user
    echo -e "$PB_EMAIL\n$PB_PASSWORD\n$PB_PASSWORD" | ./pocketbase superuser create || true
    
    DATABASE_CONFIG="POCKETBASE_URL=http://localhost:8090"
    
    mark_step "pocketbase_setup"
    
elif [ "$DB_CHOICE" = "2" ] && ! check_step "postgres_setup"; then
    log_info "Setting up PostgreSQL..."
    
    apt install -y postgresql postgresql-contrib
    systemctl start postgresql
    systemctl enable postgresql
    
    # Create database and user
    sudo -u postgres createuser "$DB_USER" || true
    sudo -u postgres createdb "${APP_NAME//[-.]/_}_db" -O "$DB_USER" || true
    sudo -u postgres psql -c "ALTER USER $DB_USER PASSWORD '$DB_PASSWORD';" || true
    
    # Configure for remote connections
    log_info "Configuring PostgreSQL for remote access..."
    
    # Enable remote connections
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
    sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
    
    # Add client authentication for private networks
    echo "host    all             all             192.168.0.0/16          md5" >> /etc/postgresql/*/main/pg_hba.conf
    echo "host    all             all             10.0.0.0/8              md5" >> /etc/postgresql/*/main/pg_hba.conf
    echo "host    all             all             172.16.0.0/12           md5" >> /etc/postgresql/*/main/pg_hba.conf
    
    # Restart PostgreSQL to apply changes
    systemctl restart postgresql
    
    # Open firewall for PostgreSQL
    ufw allow 5432
    
    DATABASE_CONFIG="DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@localhost/${APP_NAME//[-.]/_}_db"
    
    log_success "PostgreSQL configured for remote access"
    log_info "Connect from your dev machine using:"
    log_info "Host: $CONTAINER_IP, Port: 5432"
    log_info "Database: ${APP_NAME//[-.]/_}_db, User: $DB_USER"
    
    mark_step "postgres_setup"
    
elif [ "$DB_CHOICE" = "1" ]; then
    log_skip "PocketBase setup"
    DATABASE_CONFIG="POCKETBASE_URL=http://localhost:8090"
elif [ "$DB_CHOICE" = "2" ]; then
    log_skip "PostgreSQL setup"
    DB_USER=$(load_config "DB_USER")
    DB_PASSWORD=$(load_config "DB_PASSWORD")
    DATABASE_CONFIG="DATABASE_URL=postgresql://${DB_USER}:${DB_PASSWORD}@localhost/${APP_NAME//[-.]/_}_db"
fi

# =============================================================================
# SSH KEYS FOR GITHUB
# =============================================================================

if ! check_step "ssh_keys"; then
    log_info "Setting up SSH keys..."
    
    if [ ! -f /root/.ssh/id_rsa ]; then
        ssh-keygen -t rsa -b 4096 -f /root/.ssh/id_rsa -N ''
        
        echo ""
        echo "=========================================="
        echo "Add this SSH key to GitHub:"
        echo "=========================================="
        cat /root/.ssh/id_rsa.pub
        echo "=========================================="
        echo ""
        read -p "Press ENTER after adding key to GitHub..."
    fi
    
    # Add GitHub to known_hosts
    ssh-keyscan -H github.com >> /root/.ssh/known_hosts 2>/dev/null
    
    mark_step "ssh_keys"
else
    log_skip "SSH keys"
fi

# =============================================================================
# APP DEPLOYMENT
# =============================================================================

if ! check_step "app_deployment"; then
    log_info "Deploying app..."
    
    # Clone or update repository
    if [ ! -d "/opt/$APP_NAME" ]; then
        git clone "$GITHUB_REPO" "/opt/$APP_NAME"
    else
        cd "/opt/$APP_NAME" && git pull origin main
    fi
    
    cd "/opt/$APP_NAME"
    
    # Create .env file
    cat > .env << EOF
NUXT_HOST=0.0.0.0
NUXT_PORT=3000
NODE_ENV=production
$DATABASE_CONFIG
EOF
    
    # Install and build
    npm install
    npm run build
    
    # Create PM2 config
    cat > ecosystem.config.cjs << EOF
module.exports = {
  apps: [{
    name: '$APP_NAME',
    script: '.output/server/index.mjs',
    env_file: '.env',
    instances: 1,
    exec_mode: 'cluster'
  }]
};
EOF
    
    # Start app
    pm2 start ecosystem.config.cjs
    pm2 save
    pm2 startup | grep -E '^sudo ' | bash || true
    
    mark_step "app_deployment"
else
    log_skip "App deployment"
fi

# =============================================================================
# CI/CD SETUP
# =============================================================================

if ! check_step "cicd_setup"; then
    log_info "Setting up CI/CD..."
    
    cd "/opt/$APP_NAME"
    
    mkdir -p .github/workflows
    cat > .github/workflows/deploy.yml << EOF
name: Deploy App
on:
  push:
    branches: [ main ]
jobs:
  deploy:
    runs-on: self-hosted
    steps:
    - name: Deploy to LXC
      run: |
        ssh -o StrictHostKeyChecking=no root@$CONTAINER_IP "
          cd /opt/$APP_NAME
          git pull origin main
          npm install
          npm run build
          pm2 restart $APP_NAME
        "
EOF
    
    # Commit workflow file
    git add .github/workflows/deploy.yml
    git config user.email "bootstrap@$APP_NAME.local"
    git config user.name "Bootstrap"
    git commit -m "Add CI/CD workflow" || true
    git push origin main || true
    
    mark_step "cicd_setup"
else
    log_skip "CI/CD setup"
fi

# =============================================================================
# FINAL SETUP
# =============================================================================

if ! check_step "ssh_toolbox_setup"; then
    log_warning "Final CI/CD setup required:"
    echo "On your toolbox server ($TOOLBOX_IP), run:"
    echo "ssh-copy-id root@$CONTAINER_IP"
    echo ""
    echo "This enables passwordless SSH for automated deployments."
    read -p "Press ENTER after completing SSH key setup..."
    mark_step "ssh_toolbox_setup"
fi

# =============================================================================
# SUCCESS OUTPUT
# =============================================================================

echo ""
echo -e "${GREEN}"
cat << "EOF"
🎉 Bootstrap Complete!
======================
EOF
echo -e "${NC}"

log_success "Your app is running!"
echo "📱 App: http://$CONTAINER_IP:3000"

if [ "$DB_CHOICE" = "1" ]; then
    echo "🗄️  PocketBase: http://$CONTAINER_IP:8090/_/"
    echo "   Email: $PB_EMAIL"
elif [ "$DB_CHOICE" = "2" ]; then
    echo "🗄️  PostgreSQL: ${APP_NAME//[-.]/_}_db"
    echo "   Check connection details: cat /opt/$APP_NAME/.env | grep -E \"(DATABASE_URL|DB_)\""
fi

if [ "$SETUP_CICD" = "true" ]; then
    echo "🚀 CI/CD: Push to main branch for automated deployment"
    echo "   REMINDER: Run 'git pull' on your local env to get the new deployment file"
fi

echo ""
log_info "Management commands:"
echo "  Status: pm2 status"
echo "  Logs: pm2 logs $APP_NAME"
echo "  Restart: pm2 restart $APP_NAME"

echo ""
log_success "Setup complete!"
