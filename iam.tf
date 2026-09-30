## builder: runs the Cloud Build pipeline
resource "google_service_account" "builder" {
  count        = var.builder_service_account == null ? 1 : 0
  project      = var.project_id
  account_id   = "${var.name_prefix}-builder"
  display_name = "VyOS image build (Cloud Build)"
  depends_on   = [google_project_service.this]
}

## runner: the Cloud Run job that submits the build and waits for it
resource "google_service_account" "runner" {
  count        = var.runner_service_account == null ? 1 : 0
  project      = var.project_id
  account_id   = "${var.name_prefix}-runner"
  display_name = "VyOS image build orchestrator (Cloud Run job)"
  depends_on   = [google_project_service.this]
}

locals {
  builder_email = var.builder_service_account != null ? var.builder_service_account : google_service_account.builder[0].email
  runner_email  = var.runner_service_account != null ? var.runner_service_account : google_service_account.runner[0].email
}

resource "google_project_iam_member" "builder_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${local.builder_email}"
}

resource "google_storage_bucket_iam_member" "builder_objects" {
  bucket = local.bucket
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${local.builder_email}"
}

resource "google_project_iam_member" "runner_builds_editor" {
  project = var.project_id
  role    = "roles/cloudbuild.builds.editor"
  member  = "serviceAccount:${local.runner_email}"
}

resource "google_storage_bucket_iam_member" "runner_objects" {
  bucket = local.bucket
  role   = "roles/storage.objectUser"
  member = "serviceAccount:${local.runner_email}"
}

# gcloud builds submit reads the staging bucket's metadata
resource "google_storage_bucket_iam_member" "runner_bucket_reader" {
  bucket = local.bucket
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${local.runner_email}"
}

# the runner registers and prunes images
resource "google_project_iam_member" "runner_compute_storage_admin" {
  project = var.project_id
  role    = "roles/compute.storageAdmin"
  member  = "serviceAccount:${local.runner_email}"
}

# the runner submits builds that run as the builder
resource "google_service_account_iam_member" "runner_acts_as_builder" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${local.builder_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${local.runner_email}"
}
