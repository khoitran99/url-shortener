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
