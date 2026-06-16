# -----------------------------------------------------------------------------
# Backend configuration
# -----------------------------------------------------------------------------
# By default this lab uses a LOCAL backend so no GCS bucket is required.
# For team or persistent state, uncomment the GCS block below and remove or
# comment the local block.
# -----------------------------------------------------------------------------

terraform {
  backend "local" {
    path = "terraform.tfstate"
  }
}

# Uncomment to use a GCS remote backend:
# terraform {
#   backend "gcs" {
#     bucket = "YOUR_BUCKET_NAME"          # e.g. "my-project-tfstate"
#     prefix = "gcp-onprem/lab"
#   }
# }
#
# Prerequisites for GCS backend:
#   1. Create the bucket: gsutil mb -l us gs://YOUR_BUCKET_NAME
#   2. Enable versioning: gsutil versioning set on gs://YOUR_BUCKET_NAME
#   3. Grant the service account Storage Object Admin on the bucket.
#   4. Run: terraform init -reconfigure
