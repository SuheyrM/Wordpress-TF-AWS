terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# Default VPC + its subnets (simple lab setup)
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Amazon Linux 2023 AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# EC2 Security Group (SSH from you, HTTP/HTTPS from anywhere)
resource "aws_security_group" "wp_sg" {
  name        = "wp-sg"
  description = "Allow SSH, HTTP, HTTPS"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS Security Group (ONLY allow MySQL from the EC2 SG)
resource "aws_security_group" "rds_sg" {
  name        = "wp-rds-sg"
  description = "Allow MySQL from WordPress EC2 only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from WordPress SG"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.wp_sg.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS subnet group (default subnets)
resource "aws_db_subnet_group" "wp_db_subnets" {
  name       = "wp-db-subnet-group"
  subnet_ids = data.aws_subnets.default.ids

  tags = {
    Name = "wp-db-subnet-group"
  }
}

# RDS MySQL
resource "aws_db_instance" "wp_db" {
  identifier        = "wp-mysql-db"
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t3.micro"
  allocated_storage = 20
  storage_type      = "gp2"

  db_subnet_group_name   = aws_db_subnet_group.wp_db_subnets.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  username = var.db_username
  password = var.db_password

  publicly_accessible = false
  skip_final_snapshot = true
  deletion_protection = false
  multi_az            = false

  tags = {
    Name = "wp-rds-mysql"
  }
}

# WordPress EC2
resource "aws_instance" "wordpress" {
  ami                         = data.aws_ami.al2023.id
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.wp_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # Force instance recreation if you change user_data
  user_data_replace_on_change = true
  depends_on                  = [aws_db_instance.wp_db]

  # IMPORTANT:
  # - Shebang must be FIRST LINE.
  # - Avoid ${DB_NAME} style (Terraform tries to treat it as interpolation).
  user_data = <<EOF
#!/bin/bash
set -euxo pipefail

dnf update -y

# Web + PHP + MySQL client + tools + SELinux tools
dnf install -y httpd php php-mysqlnd php-fpm php-gd php-xml php-mbstring wget tar mariadb105 nmap-ncat policycoreutils-python-utils

systemctl enable --now httpd

# Allow Apache/PHP to connect to network DB (SELinux)
setsebool -P httpd_can_network_connect_db 1 || true
setsebool -P httpd_can_network_connect 1 || true

# Disable Apache welcome page if present
if [ -f /etc/httpd/conf.d/welcome.conf ]; then
  mv /etc/httpd/conf.d/welcome.conf /etc/httpd/conf.d/welcome.conf.bak
fi

DB_HOST="${aws_db_instance.wp_db.address}"
DB_NAME="wordpress"
DB_USER="wpuser"
DB_PASS="${var.wp_db_password}"

MASTER_USER="${var.db_username}"
MASTER_PASS="${var.db_password}"

# Wait for RDS port to accept connections
for i in {1..60}; do
  nc -z "$DB_HOST" 3306 && break
  sleep 10
done

# Create DB + app user (safe to re-run)
mysql -h "$DB_HOST" -u "$MASTER_USER" -p"$MASTER_PASS" -e "CREATE DATABASE IF NOT EXISTS $DB_NAME;"
mysql -h "$DB_HOST" -u "$MASTER_USER" -p"$MASTER_PASS" -e "CREATE USER IF NOT EXISTS '$DB_USER'@'%' IDENTIFIED BY '$DB_PASS';"
mysql -h "$DB_HOST" -u "$MASTER_USER" -p"$MASTER_PASS" -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'%'; FLUSH PRIVILEGES;"

# Install WordPress
cd /tmp
wget -q https://wordpress.org/latest.tar.gz
tar -xzf latest.tar.gz

rm -rf /var/www/html/*
cp -R /tmp/wordpress/* /var/www/html/

chown -R apache:apache /var/www/html
chmod -R 755 /var/www/html

cd /var/www/html
cp wp-config-sample.php wp-config.php

sed -i "s/database_name_here/$DB_NAME/" wp-config.php
sed -i "s/username_here/$DB_USER/" wp-config.php
sed -i "s/password_here/$DB_PASS/" wp-config.php
sed -i "s/localhost/$DB_HOST/" wp-config.php

# Force correct URL using instance public IP (when EIP exists later, it still matches public IP)
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)
if [ -n "$PUBLIC_IP" ]; then
  cat >> wp-config.php <<CFG

define('WP_HOME', 'http://$PUBLIC_IP');
define('WP_SITEURL', 'http://$PUBLIC_IP');
CFG
fi

# Enable permalinks
sed -i 's/AllowOverride None/AllowOverride All/g' /etc/httpd/conf/httpd.conf

systemctl restart httpd
EOF

  tags = {
    Name = "wordpress-ec2"
  }
}

# Elastic IP (optional but recommended)
resource "aws_eip" "wordpress_eip" {
  domain   = "vpc"
  instance = aws_instance.wordpress.id

  tags = {
    Name = "wordpress-eip"
  }
}
