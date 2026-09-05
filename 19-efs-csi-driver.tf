##1. EFS + Security Group + Mount Targets

resource "aws_efs_file_system" "eks" {
  creation_token = "${aws_eks_cluster.eks.name}-efs"

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs"
  }
}

# Security group for EFS
resource "aws_security_group" "efs" {
  name        = "${aws_eks_cluster.eks.name}-efs-sg"
  description = "Security group for EKS EFS"
  vpc_id      = aws_eks_cluster.eks.vpc_config[0].vpc_id

  ingress {
    description     = "NFS from EKS nodes"
    protocol        = "tcp"
    from_port       = 2049
    to_port         = 2049
    security_groups = [
  aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
]
  }

  egress {
    description = "Allow outbound traffic"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs-sg"
  }
}

# EFS mount target - AZ A
resource "aws_efs_mount_target" "zone_a" {
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = aws_subnet.private_zone1.id
  security_groups = [aws_security_group.efs.id]
}

# EFS mount target - AZ B
resource "aws_efs_mount_target" "zone_b" {
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = aws_subnet.private_zone2.id
  security_groups = [aws_security_group.efs.id]
}

##IRSA IAM Role for EFS CSI Driver


data "aws_iam_policy_document" "efs_csi_driver" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type        = "Federated"
      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {
      test = "StringEquals"

      variable = "${replace(
        aws_iam_openid_connect_provider.eks.url,
        "https://",
        ""
      )}:sub"

      values = [
        "system:serviceaccount:kube-system:efs-csi-controller-sa"
      ]
    }

    condition {
      test = "StringEquals"

      variable = "${replace(
        aws_iam_openid_connect_provider.eks.url,
        "https://",
        ""
      )}:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "efs_csi_driver" {
  name = "${aws_eks_cluster.eks.name}-efs-csi-driver"

  assume_role_policy = data.aws_iam_policy_document.efs_csi_driver.json

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  role = aws_iam_role.efs_csi_driver.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}





resource "helm_release" "efs_csi_driver" {
  name       = "aws-efs-csi-driver"
  repository = "https://kubernetes-sigs.github.io/aws-efs-csi-driver/"
  chart      = "aws-efs-csi-driver"

  namespace        = "kube-system"
  create_namespace = false

  version = "3.0.5"

  set = [
    {
      name  = "controller.serviceAccount.create"
      value = "true"
    },
    {
      name  = "controller.serviceAccount.name"
      value = "efs-csi-controller-sa"
    },
    {
      name  = "controller.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
      value = aws_iam_role.efs_csi_driver.arn
    }
  ]

  depends_on = [
    aws_iam_role_policy_attachment.efs_csi_driver,
    aws_efs_mount_target.zone_a,
    aws_efs_mount_target.zone_b
  ]
}




provider "kubernetes" {
  host = data.aws_eks_cluster.eks.endpoint

  cluster_ca_certificate = base64decode(
    data.aws_eks_cluster.eks.certificate_authority[0].data
  )

  token = data.aws_eks_cluster_auth.eks.token
}




resource "kubernetes_namespace_v1" "efs_demo" {
  metadata {
    name = "efs-demo"
  }
}


resource "kubernetes_storage_class_v1" "efs" {
  metadata {
    name = "efs"
  }

  storage_provisioner = "efs.csi.aws.com"

  reclaim_policy      = "Delete"
  volume_binding_mode = "Immediate"

  parameters = {
    provisioningMode = "efs-ap"
    fileSystemId     = aws_efs_file_system.eks.id
    directoryPerms   = "700"
  }

  mount_options = [
    "tls",
    "iam"
  ]

  depends_on = [
    helm_release.efs_csi_driver
  ]
}


resource "kubernetes_persistent_volume_claim_v1" "efs" {
  metadata {
    name      = "efs-pvc"
    namespace = kubernetes_namespace_v1.efs_demo.metadata[0].name
  }

  spec {
    access_modes = [
      "ReadWriteMany"
    ]

    storage_class_name = kubernetes_storage_class_v1.efs.metadata[0].name

    resources {
      requests = {
        storage = "5Gi"
      }
    }
  }

  depends_on = [
    kubernetes_storage_class_v1.efs
  ]
}



resource "kubernetes_deployment_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.efs_demo.metadata[0].name
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "nginx"
      }
    }

    template {
      metadata {
        labels = {
          app = "nginx"
        }
      }

      spec {
        container {
          name  = "nginx"
          image = "nginx:latest"

          port {
            name           = "http"
            container_port = 80
          }

          volume_mount {
            name       = "efs-storage"
            mount_path = "/data"
          }
        }

        volume {
          name = "efs-storage"

          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.efs.metadata[0].name
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_persistent_volume_claim_v1.efs
  ]
}


resource "kubernetes_service_v1" "nginx" {
  metadata {
    name      = "nginx"
    namespace = kubernetes_namespace_v1.efs_demo.metadata[0].name
  }

  spec {
    selector = {
      app = "nginx"
    }

    port {
      name        = "http"
      port        = 80
      target_port = 80
    }

    type = "ClusterIP"
  }
}