## The orchestrator registers the image, so a failed build can never remove the last good one
## and old images stay available for rollback (pruned to var.image_retention).
## Terraform reads the results once the orchestrator execution has completed.

data "google_storage_bucket_object_content" "manifest" {
  bucket     = local.bucket
  name       = "${local.build_path}manifest.json"
  depends_on = [google_cloud_run_v2_job.build]
}

data "google_compute_image" "vyos" {
  project    = var.project_id
  name       = local.image_name
  depends_on = [google_cloud_run_v2_job.build]
}

locals {
  manifest = jsondecode(data.google_storage_bucket_object_content.manifest.content)
}
