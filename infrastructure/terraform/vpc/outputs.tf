output "vpc_id" {
  description = "ID of the vpc"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the vpc"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (Where EKS nodes will live)"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "ID of the NAT Gateway (for reference / debugging)"
  value       = aws_nat_gateway.main.id
}

output "internet_gateway_id" {
  description = "ID of the Internet Gateway"
  value       = aws_internet_gateway.main.id
}

output "availability_zones" {
  description = "AZs the VPC spans"
  value       = var.availability_zones
}
