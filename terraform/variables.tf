variable "sonarr_api_key" {
  description = "Sonarr's own API key, stored here as the client credential Prowlarr uses to reach it"
  type        = string
  sensitive   = true
}

variable "radarr_api_key" {
  description = "Radarr's own API key, stored here as the client credential Prowlarr uses to reach it"
  type        = string
  sensitive   = true
}

variable "sabnzbd_api_key" {
  description = "SABnzbd's own API key, stored here as the client credential Sonarr/Radarr use to reach it"
  type        = string
  sensitive   = true
}
