locals {
  bucket_name = coalesce(var.bucket_name, "${var.project_id}-vyos-images")
  bucket      = var.create_bucket ? google_storage_bucket.this[0].name : local.bucket_name

  services = toset([
    "cloudbuild.googleapis.com",
    "compute.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "this" {
  for_each           = var.enable_apis ? local.services : toset([])
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_storage_bucket" "this" {
  count                       = var.create_bucket ? 1 : 0
  project                     = var.project_id
  name                        = local.bucket_name
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.bucket_force_destroy
  labels                      = var.labels

  # tarballs are only needed until the image is registered; manifests stay for Terraform to read
  lifecycle_rule {
    condition {
      age            = var.artifact_retention_days
      matches_prefix = ["${var.bucket_prefix}builds/"]
      matches_suffix = [".tar.gz"]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age            = 7
      matches_prefix = ["${var.bucket_prefix}staging/"]
    }
    action {
      type = "Delete"
    }
  }

  depends_on = [google_project_service.this]
}
