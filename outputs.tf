output "elastic_ip" {
  value = aws_eip.wordpress_eip.public_ip
}

output "wordpress_url" {
  value = "http://${aws_eip.wordpress_eip.public_ip}"
}

output "rds_endpoint" {
  value = aws_db_instance.wp_db.address
}
