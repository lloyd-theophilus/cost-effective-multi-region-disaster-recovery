# modules/compute/outputs.tf
output "alb_arn"              { value = aws_lb.main.arn }
output "alb_dns_name"         { value = aws_lb.main.dns_name }
output "alb_zone_id"          { value = aws_lb.main.zone_id }
output "ecs_cluster_name"     { value = aws_ecs_cluster.main.name }
output "ecs_service_name"     { value = aws_ecs_service.app.name }
output "sqs_queue_url"        { value = aws_sqs_queue.main.url }
output "sqs_queue_arn"        { value = aws_sqs_queue.main.arn }
output "lambda_function_name" { value = aws_lambda_function.worker.function_name }
output "lambda_function_arn"  { value = aws_lambda_function.worker.arn }
