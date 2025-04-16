#!/bin/bash
# Paymenter Automated Installer by IC Development
# This script installs Paymenter, sets up the database, and configures your web server (Nginx or Apache)

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Animated IC Development Banner
function animated_banner() {
    local text="IC DEVELOPMENT"
    echo -ne "\n"
    for ((i=0; i<${#text}; i++)); do
        echo -ne "${BLUE}${text:$i:1}${NC}"
        sleep 0.08
    done
    echo -e "\n"
    sleep 0.5
    echo -e "${YELLOW}Automated Paymenter Installer${NC}\n"
    sleep 0.5
}

animated_banner

# Check for root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root (sudo).${NC}"
    exit 1
fi

# Prompt for user input
read -p "Enter your Paymenter domain (e.g., example.com): " DOMAIN
while [[ -z "$DOMAIN" ]]; do
    read -p "Domain cannot be empty. Please enter your domain: " DOMAIN
done

read -p "Enter a strong database password for Paymenter: " DBPASS
while [[ -z "$DBPASS" ]]; do
    read -p "Password cannot be empty. Please enter a strong password: " DBPASS
done

# Webserver selection
echo -e "\nWhich webserver do you want to use?"
select SERVER in "Nginx" "Apache"; do
    case $SERVER in
        Nginx ) WEBSERVER="nginx"; break;;
        Apache ) WEBSERVER="apache"; break;;
        * ) echo "Please select 1 or 2.";;
    esac
done

# Step 1: Install dependencies

OS_ID=$(grep ^ID= /etc/os-release | cut -d'=' -f2 | tr -d '"')
OS_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'=' -f2 | tr -d '"')

if [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" ]]; then
    echo -e "${GREEN}Installing required dependencies...${NC}"
    apt -y install software-properties-common curl apt-transport-https ca-certificates gnupg
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    curl -sSL https://downloads.mariadb.com/MariaDB/mariadb_repo_setup | bash -s -- --mariadb-server-version="mariadb-10.11"
    apt update
    apt -y install php8.3 php8.3-{common,cli,gd,mysql,mbstring,bcmath,xml,fpm,curl,zip,intl,redis} mariadb-server nginx tar unzip git redis-server
    curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
else
    echo -e "${RED}This script currently supports Ubuntu/Debian only.${NC}"
    exit 1
fi

# Step 2: Download Paymenter

mkdir -p /var/www/paymenter
cd /var/www/paymenter
curl -Lo paymenter.tar.gz https://github.com/paymenter/paymenter/releases/latest/download/paymenter.tar.gz

tar -xzvf paymenter.tar.gz
chmod -R 755 storage/* bootstrap/cache/

# Step 3: Install Composer packages
composer install --no-dev --optimize-autoloader

# Step 4: Database setup

mysql -u root <<MYSQL_SCRIPT
CREATE USER IF NOT EXISTS 'paymenter'@'127.0.0.1' IDENTIFIED BY '$DBPASS';
CREATE DATABASE IF NOT EXISTS paymenter;
GRANT ALL PRIVILEGES ON paymenter.* TO 'paymenter'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
MYSQL_SCRIPT

echo -e "${GREEN}Database and user created successfully.${NC}"

# Step 5: .env setup
cp .env.example .env

# Replace DB credentials in .env
db_env=(DB_DATABASE DB_USERNAME DB_PASSWORD)
db_vals=(paymenter paymenter "$DBPASS")
for i in ${!db_env[@]}; do
    sed -i "s/^${db_env[$i]}.*/${db_env[$i]}=${db_vals[$i]}/" .env
done

# Step 6: Key generation and storage link
php artisan key:generate --force
php artisan storage:link

# Step 7: Migrate and seed database
php artisan migrate --force --seed
php artisan app:init
echo -e "${YELLOW}You can now create your admin user:${NC}"
php artisan app:user:create

# Step 8: Setup cronjob
CRON_JOB="* * * * * php /var/www/paymenter/artisan schedule:run >> /dev/null 2>&1"
(crontab -l 2>/dev/null | grep -v 'paymenter/artisan schedule:run'; echo "$CRON_JOB") | crontab -
echo -e "${GREEN}Cronjob for Paymenter schedule added.${NC}"

# Step 9: Setup systemd service
cat <<SERVICE > /etc/systemd/system/paymenter.service
[Unit]
Description=Paymenter Queue Worker

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/paymenter/artisan queue:work
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

systemctl enable --now paymenter.service
systemctl enable --now redis-server

# Step 10: Webserver configuration
if [[ "$WEBSERVER" == "nginx" ]]; then
    cat <<NGINX > /etc/nginx/sites-available/paymenter.conf
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    root /var/www/paymenter/public;

    index index.php;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
    }
}
NGINX
    ln -sf /etc/nginx/sites-available/paymenter.conf /etc/nginx/sites-enabled/
    systemctl restart nginx
    chown -R www-data:www-data /var/www/paymenter/*
    echo -e "${GREEN}Nginx configured for Paymenter.${NC}"
else
    cat <<APACHE > /etc/apache2/sites-available/paymenter.conf
<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /var/www/paymenter/public
    <Directory /var/www/paymenter/public>
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>
APACHE
    ln -sf /etc/apache2/sites-available/paymenter.conf /etc/apache2/sites-enabled/paymenter.conf
    a2enmod rewrite
    systemctl restart apache2
    chown -R www-data:www-data /var/www/paymenter/*
    echo -e "${GREEN}Apache configured for Paymenter.${NC}"
fi

# Step 11: SSL Setup (Let's Encrypt)
echo -e "${YELLOW}Do you want to enable SSL with a free Let's Encrypt certificate for $DOMAIN?${NC}"
select SSL_CHOICE in "Yes" "No"; do
    case $SSL_CHOICE in
        Yes ) ENABLE_SSL=true; break;;
        No ) ENABLE_SSL=false; break;;
        * ) echo "Please select 1 or 2.";;
    esac
done

if [ "$ENABLE_SSL" = true ]; then
    echo -e "${GREEN}Installing Certbot and obtaining SSL certificate...${NC}"
    if [[ "$WEBSERVER" == "nginx" ]]; then
        apt -y install certbot python3-certbot-nginx
        certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" --redirect || echo -e "${RED}Certbot failed. Check your DNS and firewall settings.${NC}"
        systemctl reload nginx
    else
        apt -y install certbot python3-certbot-apache
        certbot --apache -d "$DOMAIN" --non-interactive --agree-tos -m admin@"$DOMAIN" --redirect || echo -e "${RED}Certbot failed. Check your DNS and firewall settings.${NC}"
        systemctl reload apache2
    fi
    echo -e "${GREEN}SSL certificate installed! Your site is now available at https://$DOMAIN${NC}"
else
    echo -e "${YELLOW}SSL setup skipped. You can enable SSL later with Certbot.${NC}"
fi

echo -e "${GREEN}\nPaymenter installation and setup complete!${NC}"
echo -e "${YELLOW}Visit: http://$DOMAIN or https://$DOMAIN to finish setup in your browser.${NC}"
echo -e "${BLUE}Back up your .env APP_KEY! If you need help, join the Paymenter Discord.${NC}"
