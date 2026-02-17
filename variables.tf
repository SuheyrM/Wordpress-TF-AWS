variable "region" {
  type    = string
  default = "us-east-1"
}

variable "allowed_ssh_cidr" {
  type        = string
  description = "Your IP in CIDR form, e.g. 1.2.3.4/32"
}

variable "key_name" {
  type        = string
  description = "Name of an existing EC2 Key Pair in AWS (for SSH)"
}

variable "db_username" {
  type        = string
  description = "RDS master username"
}

variable "db_password" {
  type        = string
  description = "RDS master password (min 8 chars). Use something strong."
  sensitive   = true
}

variable "wp_db_password" {
  type        = string
  description = "WordPress DB user password (wpuser)"
  sensitive   = true
}
