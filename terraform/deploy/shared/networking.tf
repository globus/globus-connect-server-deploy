
resource "aws_vpc" "this" {
  cidr_block                       = local.config.cidr_block
  assign_generated_ipv6_cidr_block = true

  tags = local.config.tags
}

resource "aws_subnet" "private" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(local.config.cidr_block, 8, 0)
  availability_zone       = "us-east-1d"
  map_public_ip_on_launch = false
  tags                    = merge({ Name = "${local.config.resource_prefix}-private" }, local.config.tags)
}

resource "aws_subnet" "public" {
  vpc_id                          = aws_vpc.this.id
  cidr_block                      = cidrsubnet(local.config.cidr_block, 8, 1)
  ipv6_cidr_block                 = cidrsubnet(aws_vpc.this.ipv6_cidr_block, 8, 0)
  assign_ipv6_address_on_creation = true

  tags = merge(
    {
      Name = "${local.config.resource_prefix}-public"
    },
    local.config.tags
  )
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "this" {
  subnet_id     = aws_subnet.public.id
  allocation_id = aws_eip.nat.allocation_id

  tags = merge({ Name = local.config.resource_prefix }, local.config.tags)
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = local.config.tags
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = merge({ Name = "${local.config.resource_prefix}-private" }, local.config.tags)
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.this.id
  }

  tags = merge(
    {
      Name = "${local.config.resource_prefix}-public"
    },
    local.config.tags
  )
}

resource "aws_route_table_association" "private" {
  route_table_id = aws_route_table.private.id
  subnet_id      = aws_subnet.private.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "this" {
  name        = local.config.resource_prefix
  description = "Allows GCS to communicate inbound and outbound"
  vpc_id      = aws_vpc.this.id

  tags = local.config.tags
}

resource "aws_vpc_security_group_ingress_rule" "gcs" {
  description       = "Allow communication with the Globus service, GridFTP Control Channel, and Collections"
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  ip_protocol = "tcp"
  to_port     = 443
}

resource "aws_vpc_security_group_ingress_rule" "gcs-ipv6" {
  description       = "Allow communication with the Globus service, GridFTP Control Channel, and Collections"
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = 443
  ip_protocol = "tcp"
  to_port     = 443
}

resource "aws_vpc_security_group_ingress_rule" "data" {
  description       = "Allow GridFTP data channel traffic"
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 50000
  ip_protocol = "tcp"
  to_port     = 51000
}

resource "aws_vpc_security_group_ingress_rule" "data-ipv6" {
  description       = "Allow GridFTP data channel traffic"
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = 50000
  ip_protocol = "tcp"
  to_port     = 51000
}

resource "aws_vpc_security_group_egress_rule" "gcs" {
  description       = "Allow communication with the Globus service, Cloud Storage, and GCS Packages"
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  ip_protocol = "tcp"
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "gcs-ipv6" {
  description       = "Allow communication with the Globus service, Cloud Storage, and GCS Packages"
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = 443
  ip_protocol = "tcp"
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "data" {
  description       = "Allow GridFTP data channel traffic"
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 50000
  ip_protocol = "tcp"
  to_port     = 51000
}


resource "aws_vpc_security_group_egress_rule" "data-ipv6" {
  description       = "Allow GridFTP data channel traffic"
  security_group_id = aws_security_group.this.id

  cidr_ipv6   = "::/0"
  from_port   = 50000
  ip_protocol = "tcp"
  to_port     = 51000
}

resource "aws_vpc_security_group_egress_rule" "apt" {
  description       = "Allow apt to work"
  security_group_id = aws_security_group.this.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 80
  ip_protocol = "tcp"
  to_port     = 80
}
