variable "project" {
  type    = string
  default = "url-shortener"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "domain" {
  type        = string
  description = "Root domain (e.g. example.com). Frontend served from this domain."
}

variable "api_domain" {
  type        = string
  description = "API subdomain (e.g. api.example.com)."
}

variable "hosted_zone_id" {
  type        = string
  description = "Route 53 hosted zone ID for var.domain."
}

variable "image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag to deploy."
}

variable "db_name" {
  type        = string
  default     = "urlshortener"
  description = "PostgreSQL database name."
}

variable "db_username" {
  type        = string
  default     = "postgres"
  description = "PostgreSQL master username."
}
