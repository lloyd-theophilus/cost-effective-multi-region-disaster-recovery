# modules/networking/main.tf
# VPC, Subnets (public/private app/private data), IGW, NAT, Security Groups

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-vpc"
  })
}

# ── Internet Gateway ──────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-igw" })
}

# ── Public Subnets (ALB, NAT GW) ─────────────────────────────────
resource "aws_subnet" "public" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index)
  availability_zone = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  })
}

# ── Private App Subnets (ECS, Lambda) ────────────────────────────
resource "aws_subnet" "private_app" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 4)
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-private-app-${var.availability_zones[count.index]}"
    Tier = "private-app"
  })
}

# ── Private Data Subnets (RDS, ElastiCache) ───────────────────────
resource "aws_subnet" "private_data" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 4, count.index + 8)
  availability_zone = var.availability_zones[count.index]

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-private-data-${var.availability_zones[count.index]}"
    Tier = "private-data"
  })
}

# ── Elastic IPs for NAT Gateways ─────────────────────────────────
resource "aws_eip" "nat" {
  count  = var.is_primary ? length(var.availability_zones) : 1
  domain = "vpc"
  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-nat-eip-${count.index}"
  })
}

# ── NAT Gateways (multi-AZ in primary, single in DR) ─────────────
resource "aws_nat_gateway" "main" {
  count         = var.is_primary ? length(var.availability_zones) : 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  depends_on    = [aws_internet_gateway.main]

  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-nat-${count.index}"
  })
}

# ── Route Tables ─────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-rt-public" })
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private_app" {
  count  = var.is_primary ? length(var.availability_zones) : 1
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-rt-private-app-${count.index}"
  })
}

resource "aws_route_table_association" "private_app" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = var.is_primary ? aws_route_table.private_app[count.index].id : aws_route_table.private_app[0].id
}

resource "aws_route_table" "private_data" {
  count  = var.is_primary ? length(var.availability_zones) : 1
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[count.index].id
  }
  tags = merge(var.tags, {
    Name = "${var.app_name}-${var.environment}-rt-private-data-${count.index}"
  })
}

resource "aws_route_table_association" "private_data" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_data[count.index].id
  route_table_id = var.is_primary ? aws_route_table.private_data[count.index].id : aws_route_table.private_data[0].id
}

# ── Security Groups ───────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.app_name}-${var.environment}-alb-sg"
  description = "ALB - allow HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-alb-sg" })
}

resource "aws_security_group" "app" {
  name        = "${var.app_name}-${var.environment}-app-sg"
  description = "ECS tasks - allow traffic from ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = var.app_port
    to_port         = var.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-app-sg" })
}

resource "aws_security_group" "database" {
  name        = "${var.app_name}-${var.environment}-db-sg"
  description = "Aurora - allow from app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-db-sg" })
}

resource "aws_security_group" "cache" {
  name        = "${var.app_name}-${var.environment}-cache-sg"
  description = "ElastiCache Redis - allow from app tier only"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.app.id]
  }
  tags = merge(var.tags, { Name = "${var.app_name}-${var.environment}-cache-sg" })
}

# ── VPC Flow Logs ────────────────────────────────────────────────
resource "aws_flow_log" "main" {
  iam_role_arn    = var.flow_log_role_arn
  log_destination = var.flow_log_group_arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id
  tags            = merge(var.tags, { Name = "${var.app_name}-${var.environment}-flow-logs" })
}
