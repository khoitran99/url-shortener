variable "project" {
  type = string
}

variable "env" {
  type = string
}

variable "private_subnets" {
  type = list(string)
}

variable "redis_sg_id" {
  type = string
}

variable "node_type" {
  type    = string
  default = "cache.t4g.micro"
}
