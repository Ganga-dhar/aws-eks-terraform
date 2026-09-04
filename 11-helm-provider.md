###########################approch-2####################


terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_eks_cluster" "eks" {
  name = aws_eks_cluster.eks.name
}

provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.eks.endpoint
    cluster_ca_certificate = base64decode(
      data.aws_eks_cluster.eks.certificate_authority[0].data
    )

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"

      args = [
        "eks",
        "get-token",
        "--cluster-name",
        data.aws_eks_cluster.eks.name
      ]
    }
  }
}