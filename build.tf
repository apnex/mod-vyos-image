## build source: the pipeline under build/, content-addressed in the bucket
data "archive_file" "build" {
  type        = "zip"
  source_dir  = "${path.module}/build"
  output_path = "${path.root}/.terraform/mod-vyos-image/${var.name_prefix}-source.zip"
  # the orchestrator runs in Cloud Run, not Cloud Build; keep it out of the image identity
  excludes = ["orchestrator/run.sh"]
}

resource "google_storage_bucket_object" "source" {
  bucket = local.bucket
  name   = "${var.bucket_prefix}source/${data.archive_file.build.output_sha256}.zip"
  source = data.archive_file.build.output_path
}

locals {
  build_timeout_seconds = var.build_timeout_minutes * 60
  job_timeout_seconds   = local.build_timeout_seconds + 900
  apply_timeout         = "${ceil(local.job_timeout_seconds / 60) + 10}m"

  # every input that shapes the image; a change starts a new build under a new path
  build_inputs = {
    project_id                  = var.project_id
    bucket                      = local.bucket
    bucket_prefix               = var.bucket_prefix
    source_sha256               = data.archive_file.build.output_sha256
    vyos_release                = var.vyos_release
    rebuild_trigger             = var.rebuild_trigger
    ssh_password_authentication = var.ssh_password_authentication
    disk_size_gb                = var.disk_size_gb
    vyos_build_ref              = var.vyos_build_ref
    vyos_build_image            = var.vyos_build_image
  }
  build_token = substr(sha256(jsonencode(local.build_inputs)), 0, 16)
  build_path  = "${var.bucket_prefix}builds/${local.build_token}/"
  image_name  = "${var.image_name_prefix}-${local.build_token}"

  orchestrator_env = {
    PROJECT_ID             = var.project_id
    REGION                 = var.region
    BUCKET                 = local.bucket
    PREFIX                 = var.bucket_prefix
    SOURCE_OBJECT          = google_storage_bucket_object.source.name
    BUILD_TOKEN            = local.build_token
    BUILDER_SA             = local.builder_email
    RELEASE                = var.vyos_release
    DISK_SIZE              = tostring(var.disk_size_gb)
    SSH_PASSWORD_AUTH      = tostring(var.ssh_password_authentication)
    VYOS_BUILD_REF         = var.vyos_build_ref
    VYOS_BUILD_IMAGE       = var.vyos_build_image
    MACHINE_TYPE           = var.build_machine_type
    BUILD_TIMEOUT          = "${local.build_timeout_seconds}s"
    WAIT_TIMEOUT           = tostring(local.build_timeout_seconds + 600)
    POLL_INTERVAL          = "20"
    IMAGE_NAME             = local.image_name
    IMAGE_FAMILY           = var.image_family
    IMAGE_STORAGE_LOCATION = coalesce(var.image_storage_location, var.region)
    IMAGE_LABELS           = join(",", [for k, v in var.labels : "${k}=${v}"])
    IMAGE_RETENTION        = tostring(var.image_retention)
  }

  # everything that changes the job itself; any change needs a fresh execution
  job_spec = {
    env             = local.orchestrator_env
    image           = var.orchestrator_image
    service_account = local.runner_email
    timeout         = local.job_timeout_seconds
    script_sha256   = filesha256("${path.module}/build/orchestrator/run.sh")
  }
}

## retry markers: a failed execution writes builds/<token>/failed-<execution>; listing them
## at plan time changes the execution trigger, so a plain re-apply retries the same token
data "google_storage_buckets" "lookup" {
  count   = var.create_bucket ? 1 : 0
  project = var.project_id
  prefix  = local.bucket_name
}

locals {
  bucket_present = var.create_bucket ? contains([for b in data.google_storage_buckets.lookup[0].buckets : b.name], local.bucket_name) : true
}

data "google_storage_bucket_objects" "failures" {
  count  = local.bucket_present ? 1 : 0
  bucket = local.bucket_name
  prefix = "${local.build_path}failed-"
}

locals {
  failure_markers = sort([for o in try(data.google_storage_bucket_objects.failures[0].bucket_objects, []) : o.name])
}

## execution names must never repeat, including when inputs revert to an earlier build;
## terraform_data mints a new id each time the job spec or the failure history changes
resource "terraform_data" "execution" {
  triggers_replace = [sha256(jsonencode(local.job_spec)), sha256(jsonencode(local.failure_markers))]
}

locals {
  execution_token = "${substr(local.build_token, 0, 8)}-${substr(replace(terraform_data.execution.id, "-", ""), 0, 8)}"
}

## orchestrator: one execution per job spec; apply waits for it to complete
resource "google_cloud_run_v2_job" "build" {
  project             = var.project_id
  name                = "${var.name_prefix}-build"
  location            = var.region
  deletion_protection = false
  run_execution_token = local.execution_token

  template {
    task_count = 1
    template {
      service_account = local.runner_email
      timeout         = "${local.job_timeout_seconds}s"
      max_retries     = 0
      containers {
        image   = var.orchestrator_image
        command = ["bash", "-c"]
        args    = [file("${path.module}/build/orchestrator/run.sh")]
        dynamic "env" {
          for_each = local.orchestrator_env
          content {
            name  = env.key
            value = env.value
          }
        }
        resources {
          limits = {
            cpu    = "1"
            memory = "512Mi"
          }
        }
      }
    }
  }

  timeouts {
    create = local.apply_timeout
    update = local.apply_timeout
  }

  depends_on = [
    google_project_service.this,
    google_project_iam_member.builder_log_writer,
    google_storage_bucket_iam_member.builder_objects,
    google_project_iam_member.runner_builds_editor,
    google_storage_bucket_iam_member.runner_objects,
    google_storage_bucket_iam_member.runner_bucket_reader,
    google_service_account_iam_member.runner_acts_as_builder,
    google_project_iam_member.runner_compute_storage_admin,
  ]
}
