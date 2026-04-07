# modules/networking/outputs.tf
output "vpc_id"                  { value = aws_vpc.main.id }
output "public_subnet_ids"       { value = aws_subnet.public[*].id }
output "private_app_subnet_ids"  { value = aws_subnet.private_app[*].id }
output "private_data_subnet_ids" { value = aws_subnet.private_data[*].id }
output "alb_sg_id"               { value = aws_security_group.alb.id }
output "app_sg_id"               { value = aws_security_group.app.id }
output "database_sg_id"          { value = aws_security_group.database.id }
output "cache_sg_id"             { value = aws_security_group.cache.id }
output "nat_gateway_ids"         { value = aws_nat_gateway.main[*].id }
