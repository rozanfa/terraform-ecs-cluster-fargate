variable "app_count" {
  type    = number
  default = 1
}

variable "min_capacity" {
  type    = number
  default = 1
}

variable "max_capacity" {
  type    = number
  default = 10
}

variable "scale_in_cooldown" {
  type    = number
  default = 60
}

variable "scale_out_cooldown" {
  type    = number
  default = 60
}

variable "policy_target_value" {
  type    = number
  default = 50
}
