# Four resources only - the cross-app credential copies that
# scripts/configure-apps.sh creates once but never updates after a key
# rotation. Everything else (root folders, naming, custom formats,
# qBittorrent, Pi-hole) stays owned by configure-apps.sh; this config is
# purely the "keep credentials in sync" layer on top of it.
#
# Sonarr/Radarr/Prowlarr's *own* keys are managed declaratively via the
# SONARR__AUTH__APIKEY/RADARR__AUTH__APIKEY/PROWLARR__AUTH__APIKEY env vars
# in docker-compose.arr-stack.yml - Terraform only propagates copies of
# those keys into the apps that consume them as a client credential.

resource "prowlarr_application_sonarr" "sonarr" {
  name                  = "Sonarr"
  sync_level            = "fullSync"
  base_url              = "http://172.20.0.10:8989"
  prowlarr_url          = "http://172.20.0.3:9696"
  api_key               = var.sonarr_api_key
  sync_categories       = [5000, 5010, 5020, 5030, 5040, 5045, 5050, 5080]
  anime_sync_categories = [5070]
  tags                  = []
}

resource "prowlarr_application_radarr" "radarr" {
  name            = "Radarr"
  sync_level      = "fullSync"
  base_url        = "http://172.20.0.11:7878"
  prowlarr_url    = "http://172.20.0.3:9696"
  api_key         = var.radarr_api_key
  sync_categories = [2000, 2010, 2020, 2030, 2040, 2045, 2050, 2060, 2070, 2080, 2090]
  tags            = []
}

resource "sonarr_download_client_sabnzbd" "sabnzbd" {
  enable                     = true
  priority                   = 1
  name                       = "SABnzbd (TorBox Usenet)"
  host                       = "172.20.0.3"
  port                       = 8080
  use_ssl                    = false
  url_base                   = ""
  api_key                    = var.sabnzbd_api_key
  username                   = ""
  password                   = ""
  tv_category                = "tv"
  recent_tv_priority         = -100
  older_tv_priority          = -100
  remove_completed_downloads = true
  remove_failed_downloads    = true
  tags                       = []
}

resource "radarr_download_client_sabnzbd" "sabnzbd" {
  enable                     = true
  priority                   = 1
  name                       = "SABnzbd (TorBox Usenet)"
  host                       = "172.20.0.3"
  port                       = 8080
  use_ssl                    = false
  url_base                   = ""
  api_key                    = var.sabnzbd_api_key
  username                   = ""
  password                   = ""
  movie_category             = "movies"
  recent_movie_priority      = -100
  older_movie_priority       = -100
  remove_completed_downloads = true
  remove_failed_downloads    = true
  tags                       = []
}
