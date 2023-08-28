variable "location" {
  description = "The Azure Region in which all resources in this example should be created."
  type        = string
  default     = "westeurope"
}

variable "vm_username" {
  description = "The username of the local administrator to be created on all VMs."
  type        = string
  default     = "azureuser"
}

variable "vm_password" {
  description = "The password of the local administrator to be created on all VMs."
  type        = string
  default     = "P@ssw0rd1234!"
}