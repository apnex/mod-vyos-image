## placement

variable "project_id" {
  description = "Project that hosts the build pipeline, the bucket and the resulting image."
  type        = string
}

variable "region" {
  description = "Region for Cloud Build, the Cloud Run orchestrator job and the bucket."
  type        = string
}

variable "enable_apis" {
  description = "Enable the project services the module needs. Set false when the caller manages services."
  type        = bool
  default     = true
}

variable "name_prefix" {
  description = "Prefix for the service accounts and the Cloud Run job."
  type        = string
  default     = "vyos-image"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,18}$", var.name_prefix))
    error_message = "name_prefix must be 3-19 lowercase letters, digits or hyphens, starting with a letter."
  }
}

## storage

variable "bucket_name" {
  description = "Bucket for build source, the ISO cache and build artifacts. Defaults to \"<project_id>-vyos-images\"."
  type        = string
  default     = null
}

variable "create_bucket" {
  description = "Create the bucket. Set false to use an existing bucket; the module then only grants itself object access."
  type        = bool
  default     = true
}

variable "bucket_force_destroy" {
  description = "Allow destroying a module-created bucket that still holds objects."
  type        = bool
  default     = false
}

variable "bucket_prefix" {
  description = "Object prefix for everything the module writes, so it can share a bucket. Must end with \"/\" or be empty."
  type        = string
  default     = "vyos/"
  validation {
    condition     = var.bucket_prefix == "" || endswith(var.bucket_prefix, "/")
    error_message = "bucket_prefix must be empty or end with \"/\"."
  }
}

variable "artifact_retention_days" {
  description = "Age after which build tarballs and staging objects are deleted. Applies only to a module-created bucket; manifests and the ISO cache are kept."
  type        = number
  default     = 30
}

## identities

variable "builder_service_account" {
  description = "Existing service account email for Cloud Build. Null creates one."
  type        = string
  default     = null
}

variable "runner_service_account" {
  description = "Existing service account email for the Cloud Run orchestrator job. Null creates one."
  type        = string
  default     = null
}

## release and build

variable "vyos_release" {
  description = "VyOS nightly release tag, or \"latest\". \"latest\" is resolved when a build runs and then held until an input changes."
  type        = string
  default     = "latest"
}

variable "rebuild_trigger" {
  description = "Arbitrary string; change it to force a new build, for example to pick up a newer \"latest\"."
  type        = string
  default     = ""
}

variable "ssh_password_authentication" {
  description = "Leave SSH password login enabled in the image. The default disables it; the serial console keeps password access."
  type        = bool
  default     = false
}

variable "disk_size_gb" {
  description = "Size of the image disk in GB."
  type        = number
  default     = 10
}

variable "vyos_build_ref" {
  description = "Branch or tag of github.com/vyos/vyos-build used for the raw image tooling."
  type        = string
  default     = "rolling"
}

variable "vyos_build_image" {
  description = "Build container, pinned by digest."
  type        = string
  default     = "vyos/vyos-build@sha256:482461a415e2fa05b5b1753bfa5490f6fd349585b88be6c23314867b770bb1a0"
}

variable "build_machine_type" {
  description = "Cloud Build machine type."
  type        = string
  default     = "e2-highcpu-8"
}

variable "build_timeout_minutes" {
  description = "Upper bound for one image build. The orchestrator job and Terraform wait slightly longer."
  type        = number
  default     = 60
}

variable "orchestrator_image" {
  description = "Container image for the Cloud Run orchestrator job; must provide gcloud and python3."
  type        = string
  default     = "gcr.io/google.com/cloudsdktool/cloud-sdk:slim"
}

## image

variable "image_family" {
  description = "Image family assigned to the resulting image."
  type        = string
  default     = "vyos-rolling"
}

variable "image_name_prefix" {
  description = "Prefix for the image name; the 16-character build token is appended. The VyOS version is in the vyos-version label."
  type        = string
  default     = "vyos"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,44}$", var.image_name_prefix))
    error_message = "image_name_prefix must be 1-45 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "image_retention" {
  description = "Number of module-built images kept in the family, including the current one; older ones are deleted after each build. 0 keeps all."
  type        = number
  default     = 3
}

variable "image_storage_location" {
  description = "Image storage location. Defaults to the region."
  type        = string
  default     = null
}

variable "labels" {
  description = "Labels applied to the bucket and the images; values must be valid GCE label values."
  type        = map(string)
  default     = {}
}
