variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_name" {
  type    = string
  default = "urlshortener"
}

variable "db_username" {
  type    = string
  default = "postgres"
}

variable "snapshot_identifier" {
  type        = string
  default     = ""
  description = "RDS snapshot ID to restore from on creation. Leave empty for a fresh database."
}
