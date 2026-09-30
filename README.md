## SYN
Builds a VyOS GCE image from the latest VyOS rolling nightly using Google Cloud Build, and registers it in Compute Engine.\
`terraform apply` blocks until the image is ready - around 10-15 minutes for a first build.

### main.tf
```
locals {
	project_id	= "my-project"
	region		= "australia-southeast1"
}

module "vyos_image" {
	source		= "github.com/apnex/mod-vyos-image"
	project_id	= local.project_id
	region		= local.region
}

output "image_self_link" {
	value = module.vyos_image.image_self_link
}

output "vyos_version" {
	value = module.vyos_image.vyos_version
}
```

### apply
```
terraform init
terraform plan
terraform apply -auto-approve
```

### options
All inputs are described in `variables.tf`; the common ones:
```
vyos_release			= "latest"		# or a nightly tag, e.g. "2026.09.28-0746-rolling"
rebuild_trigger			= ""			# change to rebuild and pick up a newer "latest"
ssh_password_authentication	= false			# true leaves SSH password login enabled
google_guest_agent		= true			# Google guest agent, configured for a router
bucket_name			= null			# defaults to "<project_id>-vyos-images"
create_bucket			= true			# false to use an existing bucket_name
image_family			= "vyos-rolling"
image_retention			= 3			# images kept in the family for rollback
name_prefix			= "vyos-image"		# service accounts and job; change for a second instance in one project
```

### notes
- Needs Google credentials that can enable services, create service accounts and grant project IAM - nothing else runs locally
- The image boots on UEFI and gVNIC, takes the SSH key for user `vyos` from instance metadata, and refuses SSH password login
- The Google guest agent handles forwarded IPs, so internal load balancer addresses work on the router; users and SSH keys, interfaces, hostname, SSH host keys, alias IP ranges and time stay with VyOS (see `/etc/default/instance_configs.cfg` in the image)
- Boot routers from it with [`mod-gce-vyos`](https://github.com/apnex/mod-gce-vyos)
- Images are registered by the build, not by Terraform, so they survive `terraform destroy`; list them with `gcloud compute images list --filter="labels.managed-by=mod-vyos-image"`
