output "image_self_link" {
  description = "Self link of the registered VyOS image."
  value       = data.google_compute_image.vyos.self_link
}

output "image_name" {
  description = "Name of the registered VyOS image."
  value       = data.google_compute_image.vyos.name
}

output "image_family" {
  description = "Family of the registered VyOS image."
  value       = data.google_compute_image.vyos.family
}

output "image_family_uri" {
  description = "Family reference usable as a boot disk image: projects/<project>/global/images/family/<family>."
  value       = "projects/${var.project_id}/global/images/family/${data.google_compute_image.vyos.family}"
}

output "vyos_version" {
  description = "VyOS version baked into the image."
  value       = local.manifest.vyos_version
}

output "release_tag" {
  description = "Nightly release tag the image was built from."
  value       = local.manifest.release_tag
}

output "tarball_uri" {
  description = "GCE-format tarball (disk.raw) in Cloud Storage."
  value       = "gs://${local.bucket}/${local.build_path}image.tar.gz"
}

output "manifest_uri" {
  description = "Build manifest in Cloud Storage."
  value       = "gs://${local.bucket}/${local.build_path}manifest.json"
}

output "manifest" {
  description = "Build manifest: versions, checksums and provenance."
  value       = local.manifest
}

output "build_token" {
  description = "Hash of the build inputs; names the artifact path and the job execution."
  value       = local.build_token
}

output "bucket_name" {
  description = "Bucket holding source, ISO cache and artifacts."
  value       = local.bucket
}

output "builder_service_account" {
  description = "Service account that runs Cloud Build."
  value       = local.builder_email
}

output "runner_service_account" {
  description = "Service account that runs the orchestrator job."
  value       = local.runner_email
}
