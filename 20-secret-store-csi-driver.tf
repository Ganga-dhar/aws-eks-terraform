resource "helm_release" "secrets_csi_driver" {
  name = "secrets-store-csi-driver"

  repository = "https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts"
  chart      = "secrets-store-csi-driver"

  namespace = "kube-system"
  version   = "1.4.3"

  set = [
    {
      name  = "syncSecret.enabled"
      value = "true"
    }
  ]
}

resource "helm_release" "secrets_csi_driver_aws_provider" {
  name = "secrets-store-csi-driver-provider-aws"

  repository = "https://aws.github.io/secrets-store-csi-driver-provider-aws"
  chart      = "secrets-store-csi-driver-provider-aws"

  namespace = "kube-system"
  version   = "0.3.9"

  depends_on = [
    helm_release.secrets_csi_driver
  ]
}



resource "aws_secretsmanager_secret" "myapp" {
  name = "myapp/database"

  description = "Database credentials for myapp"

  tags = {
    Application = "myapp"
    Environment = "dev"
  }
}

resource "aws_secretsmanager_secret_version" "myapp" {
  secret_id = aws_secretsmanager_secret.myapp.id

  secret_string = jsonencode({
    username = "admin"
    password = "SuperSecretPassword123!"
    database = "myapp"
    host     = "mysql.example.internal"
  })
}

#IRSA IAM role


data "aws_iam_policy_document" "myapp_secrets" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

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
        "system:serviceaccount:12-example:myapp"
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

#IAM Role

resource "aws_iam_role" "myapp_secrets" {
  name = "${aws_eks_cluster.eks.name}-myapp-secrets"

  assume_role_policy = data.aws_iam_policy_document.myapp_secrets.json
}


resource "aws_iam_policy" "myapp_secrets" {
  name = "${aws_eks_cluster.eks.name}-myapp-secrets"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect = "Allow"

        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]

        Resource = aws_secretsmanager_secret.myapp.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "myapp_secrets" {
  role = aws_iam_role.myapp_secrets.name

  policy_arn = aws_iam_policy.myapp_secrets.arn
}


output "myapp_secrets_role_arn" {
  value = aws_iam_role.myapp_secrets.arn
}

output "myapp_secret_arn" {
  value = aws_secretsmanager_secret.myapp.arn
}