#!/bin/bash

# LXC App Bootstrap Script
# Usage: wget -qO- https://raw.githubusercontent.com/yourusername/lxc-bootstrap/main/bootstrap.sh | bash

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

# Banner
echo -e "${BLUE}"
cat << "EOF"
🚀 LXC App Bootstrap
===================
Get your Nuxt app running in minutes!
EOF
echo -e "${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi

# Get container IP
CONTAINER_IP=$(hostname -I | awk '{print $1}')
log_info "Container IP detected: $CONTAINER_IP"

# Interactive prompts
echo ""
log_info "Let's get some info about your app..."

read -p "App name (e.g., my-awesome-app): " APP_NAME
if [ -z "$APP_NAME" ]; then
    log_error "App name is required"
    exit 1
fi

read -p "GitHub repo SSH URL (git@github.com:user/repo.git): " GITHUB_REPO
if [ -z "$GITHUB_REPO" ]; then
    log_error "GitHub repo is required"
    exit 1
fi

echo "Database options:"
echo "  1) PocketBase (SQLite with web admin)"
echo "  2) PostgreSQL (traditional SQL database)"
read -p "Choose database [1]: " DB_CHOICE
DB_CHOICE=${DB_CHOICE:-1}

# Get database credentials
if [ "$DB_CHOICE" = "1" ]; then
    echo ""
    log_info "PocketBase admin account setup:"
    read -p "Admin email [admin@casawebster.com]: " POCKETBASE_EMAIL
    POCKETBASE_EMAIL=${POCKETBASE_EMAIL:-admin@casawebster.com}
    
    read -s -p "Admin password: " POCKETBASE_PASSWORD
    echo ""
    if [ -z "$POCKETBASE_PASSWORD" ]; then
        log_error "PocketBase password is required"
        exit 1
    fi
elif [ "$DB_CHOICE" = "2" ]; then
    echo ""
    log_info "PostgreSQL database setup:"
    read -p "Database username [appuser]: " DB_USERNAME
    DB_USERNAME=${DB_USERNAME:-appuser}
    
    read -s -p "Database password: " DB_PASSWORD
    echo ""
    if [ -z "$DB_PASSWORD" ]; then
        log_error "Database password is required"
        exit 1
    fi
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
        read -p "Toolbox LXC IP (where GitHub runner is installed): " TOOLBOX_IP
        if [ -z "$TOOLBOX_IP" ]; then
            log_warning "No toolbox IP provided - CI/CD will be skipped"
            SETUP_CICD=""
        fi
    fi
else
    SETUP_CICD=""
fi

echo ""
log_info "Starting setup..."

# =============================================================================
# SYSTEM SETUP
# =============================================================================

log_info "Installing system packages..."
apt update
apt install -y curl git nginx ufw unzip wget sudo

# Create appuser
log_info "Creating appuser..."
useradd -m -s /bin/bash appuser
usermod -aG sudo appuser

# =============================================================================
# NODE.JS SETUP  
# =============================================================================

log_info "Installing Node.js LTS..."
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
apt install -y nodejs

log_info "Installing PM2 globally..."
npm install -g pm2

# =============================================================================
# DATABASE SETUP
# =============================================================================

POCKETBASE_PORT=8090

if [ "$DB_CHOICE" = "1" ]; then
    log_info "Setting up PocketBase..."
    
    # Create pocketbase directory
    mkdir -p /home/appuser/pocketbase
    chown appuser:appuser /home/appuser/pocketbase
    
    # Download latest PocketBase
    POCKETBASE_VERSION=$(curl -s https://api.github.com/repos/pocketbase/pocketbase/releases/latest | grep tag_name | cut -d '"' -f 4)
    POCKETBASE_URL="https://github.com/pocketbase/pocketbase/releases/download/${POCKETBASE_VERSION}/pocketbase_${POCKETBASE_VERSION#v}_linux_amd64.zip"
    
    wget -q "$POCKETBASE_URL" -O /tmp/pocketbase.zip
    unzip -q /tmp/pocketbase.zip -d /home/appuser/pocketbase
    chmod +x /home/appuser/pocketbase/pocketbase
    chown -R appuser:appuser /home/appuser/pocketbase
    
    # Create PM2 ecosystem file for PocketBase
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
    
    # Start PocketBase
    su - appuser -c "cd /home/appuser/pocketbase && pm2 start ecosystem.config.cjs"
    
    # Wait for PocketBase to be ready
    log_info "Waiting for PocketBase to start..."
    sleep 5
    
    # Create superuser with custom credentials
    su - appuser -c "cd /home/appuser/pocketbase && echo '$POCKETBASE_EMAIL
$POCKETBASE_PASSWORD
$POCKETBASE_PASSWORD' | ./pocketbase superuser create" || true
    
    DATABASE_CONFIG="# PocketBase Configuration
POCKETBASE_URL=http://localhost:${POCKETBASE_PORT}
POCKETBASE_PORT=${POCKETBASE_PORT}"

elif [ "$DB_CHOICE" = "2" ]; then
    log_info "Setting up PostgreSQL..."
    
    apt install -y postgresql postgresql-contrib
    systemctl start postgresql
    systemctl enable postgresql
    
    # Create database and user with custom credentials
    su - postgres -c "createuser $DB_USERNAME"
    su - postgres -c "createdb ${DB_USERNAME}_db -O $DB_USERNAME"
    su - postgres -c "psql -c \"ALTER USER $DB_USERNAME PASSWORD '$DB_PASSWORD';\""
    
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

log_info "Setting up SSH keys for GitHub access..."
mkdir -p /home/appuser/.ssh
chown appuser:appuser /home/appuser/.ssh
chmod 700 /home/appuser/.ssh

# Generate SSH key
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

log_info "Cloning your app repository..."
su - appuser -c "git clone $GITHUB_REPO /home/appuser/$APP_NAME" || {
    log_error "Failed to clone repository. Make sure you added the SSH key to GitHub."
    exit 1
}

log_info "Installing app dependencies..."
su - appuser -c "cd /home/appuser/$APP_NAME && npm install"

# Create .env file
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

log_info "Building the application..."
su - appuser -c "cd /home/appuser/$APP_NAME && npm run build"

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

# Start the app
log_info "Starting your app..."
su - appuser -c "cd /home/appuser/$APP_NAME && pm2 start ecosystem.config.cjs"

# Save PM2 configuration and set up startup
su - appuser -c "pm2 save"
env PATH=$PATH:/usr/bin pm2 startup systemd -u appuser --hp /home/appuser
systemctl enable pm2-appuser

# =============================================================================
# CI/CD SETUP (if requested)
# =============================================================================

if [ -n "$SETUP_CICD" ]; then
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
        # SSH into the LXC and update the app
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
    echo "🗄️  PocketBase Admin: http://$CONTAINER_IP:8090/_/"
    echo "   Username: $POCKETBASE_EMAIL"
    echo "   Password: [hidden]"
elif [ "$DB_CHOICE" = "2" ]; then
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
    echo "  Connect to PostgreSQL: su - appuser -c 'psql postgresql://appuser:$POSTGRES_PASSWORD@localhost/appuser_db'"
fi

echo ""
log_success "Happy coding! 🚀"
