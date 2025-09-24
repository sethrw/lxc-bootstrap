#!/bin/bash

# LXC App Bootstrap Script - Idempotent Version
# Usage: wget -qO- https://raw.githubusercontent.com/yourusername/lxc-bootstrap/main/bootstrap.sh | bash
# Or: wget https://raw.githubusercontent.com/yourusername/lxc-bootstrap/main/bootstrap.sh && chmod +x bootstrap.sh && ./bootstrap.sh

set -e  # Exit on any error

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }
log_success() { echo -e "${GREEN}✅ $1${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
log_error() { echo -e "${RED}❌ $1${NC}"; }
log_skip() { echo -e "${YELLOW}⏭️  $1 (already done)${NC}"; }

# Progress tracking
BOOTSTRAP_DIR="/tmp/lxc-bootstrap"
PROGRESS_FILE="$BOOTSTRAP_DIR/progress"
STATE_FILE="$BOOTSTRAP_DIR/state"

# Initialize progress tracking
init_progress() {
    mkdir -p "$BOOTSTRAP_DIR"
    touch "$PROGRESS_FILE"
    touch "$STATE_FILE"
}

# Check if step is already completed
check_step() {
    grep -q "^$1$" "$PROGRESS_FILE" 2>/dev/null
}

# Mark step as completed
mark_step() {
    echo "$1" >> "$PROGRESS_FILE"
}

# Save state variable
save_state() {
    grep -v "^$1=" "$STATE_FILE" 2>/dev/null > "$STATE_FILE.tmp" || true
    echo "$1=$2" >> "$STATE_FILE.tmp"
    mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# Load state variable
load_state() {
    grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2-
}

# Banner
echo -e "${BLUE}"
cat << "EOF"
🚀 LXC App Bootstrap (Idempotent)
================================
Safe to re-run if something fails!
EOF
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

# Initialize progress tracking
init_progress

# Get container IP
CONTAINER_IP=$(hostname -I | awk '{print $1}')
log_info "Container IP detected: $CONTAINER_IP"

# Check if we have previous state
if [ -s "$STATE_FILE" ]; then
    log_info "Found previous run state - will resume/skip completed steps"
    APP_NAME=$(load_state "APP_NAME")
    GITHUB_REPO=$(load_state "GITHUB_REPO") 
    DB_CHOICE=$(load_state "DB_CHOICE")
    if [ -n "$APP_NAME" ]; then
        log_info "Previous app: $APP_NAME"
        read -p "Continue with previous configuration? [Y/n]: " CONTINUE_PREV
        if [[ "$CONTINUE_PREV" =~ ^[Nn]$ ]]; then
            log_info "Starting fresh configuration..."
            rm -f "$PROGRESS_FILE" "$STATE_FILE"
            APP_NAME=""
        fi
    fi
fi

# Interactive prompts (only if not already configured)
if [ -z "$APP_NAME" ]; then
    echo ""
    log_info "Let's get some info about your app..."

    read -p "App name (e.g., my-awesome-app): " APP_NAME
    if [ -z "$APP_NAME" ]; then
        log_error "App name is required"
        exit 1
    fi
    save_state "APP_NAME" "$APP_NAME"

    read -p "GitHub repo SSH URL (git@github.com:user/repo.git): " GITHUB_REPO
    if [ -z "$GITHUB_REPO" ]; then
        log_error "GitHub repo is required"
        exit 1
    fi
    save_state "GITHUB_REPO" "$GITHUB_REPO"

    echo "Database options:"
    echo "  1) PocketBase (SQLite with web admin)"
    echo "  2) PostgreSQL (traditional SQL database)"
    read -p "Choose database [1]: " DB_CHOICE
    DB_CHOICE=${DB_CHOICE:-1}
    save_state "DB_CHOICE" "$DB_CHOICE"

    # Get database credentials
    if [ "$DB_CHOICE" = "1" ]; then
        echo ""
        log_info "PocketBase admin account setup:"
        read -p "Admin email [admin@casawebster.com]: " POCKETBASE_EMAIL
        POCKETBASE_EMAIL=${POCKETBASE_EMAIL:-admin@casawebster.com}
        save_state "POCKETBASE_EMAIL" "$POCKETBASE_EMAIL"
        
        read -s -p "Admin password: " POCKETBASE_PASSWORD
        echo ""
        if [ -z "$POCKETBASE_PASSWORD" ]; then
            log_error "PocketBase password is required"
            exit 1
        fi
        save_state "POCKETBASE_PASSWORD" "$POCKETBASE_PASSWORD"
    elif [ "$DB_CHOICE" = "2" ]; then
        echo ""
        log_info "PostgreSQL database setup:"
        read -p "Database username [appuser]: " DB_USERNAME
        DB_USERNAME=${DB_USERNAME:-appuser}
        save_state "DB_USERNAME" "$DB_USERNAME"
        
        read -s -p "Database password: " DB_PASSWORD
        echo ""
        if [ -z "$DB_PASSWORD" ]; then
            log_error "Database password is required"
            exit 1
        fi
        save_state "DB_PASSWORD" "$DB_PASSWORD"
    fi

    # CI/CD Setup
    echo ""
    log_info "CI/CD setup (optional):"
    read -p "Do you want to set up automated deployment? [y/N]: " SETUP_CICD
    if [[ "$SETUP_CICD" =~ ^[Yy]$ ]]; then
        read -p "GitHub personal access token: " GITHUB_TOKEN
        if [ -z "$GITHUB_TOKEN" ]; then
            log_warning "No GitHub token provided - CI/CD will be skipped"
            SETUP_CICD=""
        else
            save_state "GITHUB_TOKEN" "$GITHUB_TOKEN"
            read -p "Toolbox LXC IP (where GitHub runner is installed): " TOOLBOX_IP
            if [ -z "$TOOLBOX_IP" ]; then
                log_warning "No toolbox IP provided - CI/CD will be skipped"
                SETUP_CICD=""
            else
                save_state "TOOLBOX_IP" "$TOOLBOX_IP"
            fi
        fi
    else
        SETUP_CICD=""
    fi
    save_state "SETUP_CICD" "$SETUP_CICD"
else
    # Load previous configuration
    GITHUB_REPO=$(load_state "GITHUB_REPO")
    DB_CHOICE=$(load_state "DB_CHOICE")
    POCKETBASE_EMAIL=$(load_state "POCKETBASE_EMAIL")
    POCKETBASE_PASSWORD=$(load_state "POCKETBASE_PASSWORD") 
    DB_USERNAME=$(load_state "DB_USERNAME")
    DB_PASSWORD=$(load_state "DB_PASSWORD")
    SETUP_CICD=$(load_state "SETUP_CICD")
    GITHUB_TOKEN=$(load_state "GITHUB_TOKEN")
    TOOLBOX_IP=$(load_state "TOOLBOX_IP")
fi

echo ""
log_info "Starting/resuming setup..."

# =============================================================================
# SYSTEM SETUP
# =============================================================================

if ! check_step "system_packages"; then
    log_info "Installing system packages..."
    apt update
    apt install -y curl git nginx ufw unzip wget sudo
    mark_step "system_packages"
else
    log_skip "System packages"
fi

if ! check_step "appuser_created"; then
    log_info "Creating appuser..."
    if ! id "appuser" &>/dev/null; then
        useradd -m -s /bin/bash appuser
        usermod -aG sudo appuser
    fi
    mark_step "appuser_created"
else
    log_skip "Appuser creation"
fi

# =============================================================================
# NODE.JS SETUP  
# =============================================================================

if ! check_step "nodejs_installed"; then
    if ! command -v node &>/dev/null; then
        log_info "Installing Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt install -y nodejs
    else
        log_info "Node.js already installed: $(node --version)"
    fi
    mark_step "nodejs_installed"
else
    log_skip "Node.js installation"
fi

if ! check_step "pm2_installed"; then
    if ! command -v pm2 &>/dev/null; then
        log_info "Installing PM2 globally..."
        npm install -g pm2
    else
        log_info "PM2 already installed: $(pm2 --version)"
    fi
    mark_step "pm2_installed"
else
    log_skip "PM2 installation"
fi

# =============================================================================
# DATABASE SETUP
# =============================================================================

POCKETBASE_PORT=8090

if [ "$DB_CHOICE" = "1" ] && ! check_step "pocketbase_setup"; then
    log_info "Setting up PocketBase..."
    
    # Create pocketbase directory
    mkdir -p /home/appuser/pocketbase
    chown appuser:appuser /home/appuser/pocketbase
    
    # Check if PocketBase binary exists
    if [ ! -f "/home/appuser/pocketbase/pocketbase" ]; then
        # Download latest PocketBase
        POCKETBASE_VERSION=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | grep tag_name | cut -d '"' -f 4)
        POCKETBASE_URL="https://github.com/pocketbase/pocketbase/releases/download/${POCKETBASE_VERSION}/pocketbase_${POCKETBASE_VERSION#v}_linux_amd64.zip"
        
        wget -q "$POCKETBASE_URL" -O /tmp/pocketbase.zip
        unzip -q /tmp/pocketbase.zip -d /home/appuser/pocketbase
        chmod +x /home/appuser/pocketbase/pocketbase
        chown -R appuser:appuser /home/appuser/pocketbase
    fi
    
    # Create PM2 ecosystem file for PocketBase if it doesn't exist
    if [ ! -f "/home/appuser/pocketbase/ecosystem.config.cjs" ]; then
        cat > /home/appuser/pocketbase/ecosystem.config.cjs << EOF
module.exports = {
  apps: [{
    name: 'pocketbase',
    cwd: '/home/appuser/pocketbase',
    script: './pocketbase',
    args: 'serve --http=0.0.0.0:${POCKETBASE_PORT}',
    instances: 1,
    exec_mode: 'fork'
  }]
};
EOF
        chown appuser:appuser /home/appuser/pocketbase/ecosystem.config.cjs
    fi
    
    # Start PocketBase if not already running
    if ! su - appuser -c "pm2 describe pocketbase" &>/dev/null; then
        log_info "Starting PocketBase..."
        su - appuser -c "cd /home/appuser/pocketbase && pm2 start ecosystem.config.cjs"
        sleep 5
    else
        log_info "PocketBase already running"
    fi
    
    # Create superuser (only if not exists - PocketBase will error if already exists)
    su - appuser -c "cd /home/appuser/pocketbase && echo '$POCKETBASE_EMAIL
$POCKETBASE_PASSWORD
$POCKETBASE_PASSWORD' | ./pocketbase superuser create" &>/dev/null || true
    
    DATABASE_CONFIG="# PocketBase Configuration
POCKETBASE_URL=http://localhost:${POCKETBASE_PORT}
POCKETBASE_PORT=${POCKETBASE_PORT}"
    
    mark_step "pocketbase_setup"

elif [ "$DB_CHOICE" = "2" ] && ! check_step "postgres_setup"; then
    log_info "Setting up PostgreSQL..."
    
    # Install PostgreSQL if not already installed
    if ! command -v psql &>/dev/null; then
        apt install -y postgresql postgresql-contrib
        systemctl start postgresql
        systemctl enable postgresql
    else
        log_info "PostgreSQL already installed"
        systemctl start postgresql || true
    fi
    
    # Create database and user if they don't exist
    DB_EXISTS=$(su - postgres -c "psql -tAc \"SELECT 1 FROM pg_roles WHERE rolname='$DB_USERNAME'\"")
    if [ -z "$DB_EXISTS" ]; then
        su - postgres -c "createuser $DB_USERNAME"
        su - postgres -c "createdb ${DB_USERNAME}_db -O $DB_USERNAME"
        su - postgres -c "psql -c \"ALTER USER $DB_USERNAME PASSWORD '$DB_PASSWORD';\""
    else
        log_info "PostgreSQL user $DB_USERNAME already exists"
    fi
    
    DATABASE_CONFIG="# PostgreSQL Configuration
DATABASE_URL=postgresql://${DB_USERNAME}:${DB_PASSWORD}@localhost/${DB_USERNAME}_db
DB_HOST=localhost
DB_PORT=5432
DB_NAME=${DB_USERNAME}_db
DB_USER=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}"
    
    mark_step "postgres_setup"

elif [ "$DB_CHOICE" = "1" ]; then
    log_skip "PocketBase setup"
    DATABASE_CONFIG="# PocketBase Configuration
POCKETBASE_URL=http://localhost:${POCKETBASE_PORT}
POCKETBASE_PORT=${POCKETBASE_PORT}"
elif [ "$DB_CHOICE" = "2" ]; then
    log_skip "PostgreSQL setup"
    # Reload credentials for existing setup
    DB_USERNAME=$(load_state "DB_USERNAME")
    DB_PASSWORD=$(load_state "DB_PASSWORD")
    DATABASE_CONFIG="# PostgreSQL Configuration
DATABASE_URL=postgresql://${DB_USERNAME}:${DB_PASSWORD}@localhost/${DB_USERNAME}_db
DB_HOST=localhost
DB_PORT=5432
DB_NAME=${DB_USERNAME}_db
DB_USER=${DB_USERNAME}
DB_PASSWORD=${DB_PASSWORD}"
fi

# =============================================================================
# APP DEPLOYMENT
# =============================================================================

if ! check_step "ssh_keys_setup"; then
    log_info "Setting up SSH keys for GitHub access..."
    mkdir -p /home/appuser/.ssh
    chown appuser:appuser /home/appuser/.ssh
    chmod 700 /home/appuser/.ssh

    # Generate SSH key if it doesn't exist
    if [ ! -f "/home/appuser/.ssh/id_rsa" ]; then
        su - appuser -c "ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ''"
        
        # Display public key for user to add to GitHub
        echo ""
        log_warning "IMPORTANT: Add this SSH key to your GitHub account:"
        echo "=========================================="
        cat /home/appuser/.ssh/id_rsa.pub
        echo "=========================================="
        echo ""
        echo "1. Go to GitHub.com → Settings → SSH and GPG keys"
        echo "2. Click 'New SSH key'"
        echo "3. Paste the key above"
        read -p "Press ENTER when you've added the key to GitHub..."
    else
        log_info "SSH key already exists"
    fi
    mark_step "ssh_keys_setup"
else
    log_skip "SSH keys setup"
fi

if ! check_step "app_cloned"; then
    if [ ! -d "/home/appuser/$APP_NAME" ]; then
        log_info "Cloning your app repository..."
        su - appuser -c "git clone $GITHUB_REPO /home/appuser/$APP_NAME" || {
            log_error "Failed to clone repository. Make sure you added the SSH key to GitHub."
            exit 1
        }
    else
        log_info "App directory already exists, pulling latest changes..."
        su - appuser -c "cd /home/appuser/$APP_NAME && git pull origin main" || true
    fi
    mark_step "app_cloned"
else
    log_skip "App repository clone"
fi

if ! check_step "app_dependencies"; then
    log_info "Installing app dependencies..."
    su - appuser -c "cd /home/appuser/$APP_NAME && npm install"
    mark_step "app_dependencies"
else
    log_skip "App dependencies (run 'npm install' manually if needed)"
fi

if ! check_step "app_env_file"; then
    log_info "Creating environment configuration..."
    cat > /home/appuser/$APP_NAME/.env << EOF
# App Configuration
NUXT_HOST=0.0.0.0
NUXT_PORT=3000
NODE_ENV=production

$DATABASE_CONFIG
EOF
    chown appuser:appuser /home/appuser/$APP_NAME/.env
    chmod 600 /home/appuser/$APP_NAME/.env
    mark_step "app_env_file"
else
    log_skip "Environment file creation"
fi

if ! check_step "app_built"; then
    log_info "Building the application..."
    su - appuser -c "cd /home/appuser/$APP_NAME && npm run build"
    mark_step "app_built"
else
    log_skip "App build (run 'npm run build' manually if needed)"
fi

if ! check_step "app_pm2_config"; then
    # Create PM2 ecosystem file for app
    log_info "Setting up PM2 for the app..."
    cat > /home/appuser/$APP_NAME/ecosystem.config.cjs << EOF
module.exports = {
  apps: [{
    name: '$APP_NAME',
    cwd: '/home/appuser/$APP_NAME',
    script: '.output/server/index.mjs',
    instances: 1,
    exec_mode: 'cluster',
    env_file: '.env'
  }]
};
EOF
    chown appuser:appuser /home/appuser/$APP_NAME/ecosystem.config.cjs
    mark_step "app_pm2_config"
else
    log_skip "PM2 configuration"
fi

if ! check_step "app_started"; then
    # Start the app
    if ! su - appuser -c "pm2 describe $APP_NAME" &>/dev/null; then
        log_info "Starting your app..."
        su - appuser -c "cd /home/appuser/$APP_NAME && pm2 start ecosystem.config.cjs"
    else
        log_info "App already running, restarting..."
        su - appuser -c "pm2 restart $APP_NAME"
    fi

    # Save PM2 configuration and set up startup
    su - appuser -c "pm2 save"
    if ! systemctl is-enabled pm2-appuser &>/dev/null; then
        env PATH=$PATH:/usr/bin pm2 startup systemd -u appuser --hp /home/appuser
        systemctl enable pm2-appuser
    fi
    mark_step "app_started"
else
    log_skip "App startup"
fi

# =============================================================================
# CI/CD SETUP (if requested)
# =============================================================================

if [ -n "$SETUP_CICD" ] && ! check_step "cicd_setup"; then
    log_info "Setting up CI/CD with GitHub Actions..."
    
    # Create the workflow file in the repo
    mkdir -p /home/appuser/$APP_NAME/.github/workflows
    cat > /home/appuser/$APP_NAME/.github/workflows/deploy.yml << EOF
name: Deploy App
on:
  push:
    branches: [ main ]
jobs:
  deploy:
    runs-on: self-hosted
    steps:
    - name: Deploy latest code to LXC
      run: |
        ssh -o StrictHostKeyChecking=no root@$CONTAINER_IP "
          cd /home/appuser/$APP_NAME
          git pull origin main
          npm install
          npm run build
          su - appuser -c 'cd $APP_NAME && pm2 restart $APP_NAME'
        "
EOF
    chown -R appuser:appuser /home/appuser/$APP_NAME/.github
    
    # Set up SSH access from toolbox to this LXC
    log_info "Setting up SSH access from toolbox..."
    
    # Enable SSH key authentication for root
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    
    # Get the public key from toolbox (we'll prompt user to add it)
    log_warning "IMPORTANT: SSH setup required for CI/CD"
    echo "Run this command on your TOOLBOX LXC to copy SSH access:"
    echo "ssh-copy-id root@$CONTAINER_IP"
    echo ""
    read -p "Press ENTER after running the ssh-copy-id command on toolbox..."
    
    # Test SSH connection
    log_info "Testing SSH connection from toolbox..."
    echo "You can test the connection by running this from toolbox:"
    echo "ssh root@$CONTAINER_IP 'echo \"SSH connection successful\"'"
    
    # Commit and push the workflow file
    su - appuser -c "cd /home/appuser/$APP_NAME && git add .github/workflows/deploy.yml"
    su - appuser -c "cd /home/appuser/$APP_NAME && git config user.email 'bootstrap@casawebster.com'"
    su - appuser -c "cd /home/appuser/$APP_NAME && git config user.name 'LXC Bootstrap'"
    su - appuser -c "cd /home/appuser/$APP_NAME && git commit -m 'Add automated deployment workflow' || true"
    su - appuser -c "cd /home/appuser/$APP_NAME && git push origin main || true"
    
    log_success "CI/CD workflow created and pushed to GitHub!"
    mark_step "cicd_setup"
elif [ -n "$SETUP_CICD" ]; then
    log_skip "CI/CD setup"
fi

# =============================================================================
# FINAL OUTPUT
# =============================================================================

echo ""
echo -e "${GREEN}"
cat << "EOF"
🎉 Bootstrap Complete!
======================
EOF
echo -e "${NC}"

log_success "Your app is running!"
echo "📱 App URL: http://$CONTAINER_IP:3000"

if [ "$DB_CHOICE" = "1" ]; then
    POCKETBASE_EMAIL=$(load_state "POCKETBASE_EMAIL")
    echo "🗄️  PocketBase Admin: http://$CONTAINER_IP:8090/_/"
    echo "   Username: $POCKETBASE_EMAIL"
    echo "   Password: [hidden]"
elif [ "$DB_CHOICE" = "2" ]; then
    DB_USERNAME=$(load_state "DB_USERNAME")
    echo "🗄️  PostgreSQL Database: ${DB_USERNAME}_db"
    echo "   Connection: postgresql://${DB_USERNAME}:[password]@localhost/${DB_USERNAME}_db"
fi

if [ -n "$SETUP_CICD" ]; then
    echo "🚀 CI/CD: Push to main branch for automatic deployment!"
    echo "   Make sure you ran: ssh-copy-id root@$CONTAINER_IP from toolbox"
fi

echo ""
log_info "Useful commands:"
echo "  Check app status: su - appuser -c 'pm2 status'"
echo "  View app logs: su - appuser -c 'pm2 logs $APP_NAME'"
echo "  Restart app: su - appuser -c 'pm2 restart $APP_NAME'"

if [ "$DB_CHOICE" = "1" ]; then
    echo "  Check PocketBase: su - appuser -c 'pm2 logs pocketbase'"
elif [ "$DB_CHOICE" = "2" ]; then
    DB_USERNAME=$(load_state "DB_USERNAME")
    echo "  Connect to PostgreSQL: su - appuser -c 'psql postgresql://${DB_USERNAME}:PASSWORD@localhost/${DB_USERNAME}_db'"
fi

echo ""
log_success "Happy coding! 🚀"
log_info "Script state saved in $BOOTSTRAP_DIR - safe to re-run if needed!"
