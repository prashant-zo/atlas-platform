locals {
  az_count = length(var.availability_zones)
}

#VPC

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "atlas-${var.environment}-vpc"
  }
}

# Internet Gateway — for public subnets to reach the internet

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "atlas-${var.environment}-vpc"
  }
}

# Public Subnets — one per AZ
# Tagged for EKS Load Balancer Controller to discover them for public LBs

resource "aws_subnet" "public" {
  count = local.az_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name                                        = "atlas-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier                                        = "public"
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Private Subnets — one per AZ
# Tagged for EKS Load Balancer Controller to use for internal LBs

resource "aws_subnet" "private" {
  count = local.az_count

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name                                        = "atlas-${var.environment}-private-${var.availability_zones[count.index]}"
    Tier                                        = "private"
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# Elastic IP for NAT Gateway

resource "aws_eip" "nat" {
  domain = "vpc"

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "atlas-${var.environment}-nat-eip"
  }
}

# NAT Gateway — single, in first AZ's public subnet (cost-optimized)
# All private subnets route through this one NAT.

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "atlas-${var.environment}-nat"
  }
}

# Route Tables

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "atlas-${var.environment}-public-rt"
  }
}

# Private route table — routes 0.0.0.0/0 to NAT
# Single table shared across all private subnets (simpler + same-cost)

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = {
    Name = "atlas-${var.environment}-private-rt"
  }
}

# Route Table Associations

resource "aws_route_table_association" "public" {
  count = local.az_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  count = local.az_count

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}
