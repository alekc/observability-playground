output "appserver_public_ip" {
  description = "Public IP of the application server (Caddy on :80)."
  value       = aws_instance.appserver.public_ip
}

output "observer_public_ip" {
  description = "Public IP of the observability server (Grafana on :3000)."
  value       = aws_instance.observer.public_ip
}

output "appserver_private_ip" {
  description = "Private IP of appserver (source of remote_write traffic)."
  value       = aws_instance.appserver.private_ip
}

output "observer_private_ip" {
  description = "Private IP of observer. Use this as OBSERVER_IP on appserver so metrics/logs stay on the VPC and avoid public egress."
  value       = aws_instance.observer.private_ip
}

output "ssh_private_key_path" {
  description = "Path to the generated SSH private key."
  value       = local_sensitive_file.private_key.filename
}

output "grafana_url" {
  description = "Grafana entry point."
  value       = "http://${aws_instance.observer.public_ip}:3000"
}

output "app_url" {
  description = "Application entry point (via Caddy)."
  value       = "http://${aws_instance.appserver.public_ip}"
}
