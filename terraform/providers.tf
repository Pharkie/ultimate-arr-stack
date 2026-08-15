terraform {
  required_providers {
    sonarr = {
      source  = "devopsarr/sonarr"
      version = "~> 3.4"
    }
    radarr = {
      source  = "devopsarr/radarr"
      version = "~> 2.4"
    }
    prowlarr = {
      source  = "devopsarr/prowlarr"
      version = "~> 3.2"
    }
  }
}

# Auth is supplied via SONARR_URL/SONARR_API_KEY, RADARR_URL/RADARR_API_KEY,
# and PROWLARR_URL/PROWLARR_API_KEY env vars (set by apply.sh from Bitwarden)
# so no credential ever appears in this repo or in `terraform plan` output.
provider "sonarr" {}
provider "radarr" {}
provider "prowlarr" {}
