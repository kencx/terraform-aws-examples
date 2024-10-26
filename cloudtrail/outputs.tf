output "trail_arn" {
  value = aws_cloudtrail.this.arn
}

output "trail_id" {
  value = aws_cloudtrail.this.id
}
