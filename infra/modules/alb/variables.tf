variable "project"         { type = string }
variable "env"             { type = string }
variable "vpc_id"          { type = string }
variable "public_subnets"  { type = list(string) }
variable "alb_sg_id"       { type = string }
variable "api_domain"      { type = string }
variable "hosted_zone_id"  { type = string }
