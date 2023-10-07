variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "access_key" {
  type      = string
  sensitive = true
}

variable "secret_key" {
  type      = string
  sensitive = true
}

variable "public_ingress_ports" {
  type        = list(number)
  description = "List of public ingress ports"
  default     = [22, 80, 443]
}
