# values & secrets should be defined in separate configuration
resource "aws_ssm_parameter" "container_image" {
  name  = "/${local.container_name}/container_image"
  type  = "String"
  value = local.container_image
}

resource "aws_secretsmanager_secret" "db_url" {
  name = "db_url"
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id     = aws_secretsmanager_secret.db_url.id
  secret_string = local.db_url
}

resource "aws_secretsmanager_secret" "admin" {
  name = "admin"
}

resource "aws_secretsmanager_secret_version" "admin" {
  secret_id = aws_secretsmanager_secret.admin.id
  secret_string = jsonencode({
    "username" : local.admin_username,
    "password" : local.admin_pass
  })
}

