# EKS IAM Access Management with Terraform

This example demonstrates how to provide administrative access to an Amazon EKS cluster using:

* AWS IAM User
* IAM Role
* AWS STS `AssumeRole`
* EKS Access Entry
* Kubernetes RBAC
* EKS Access Policies

It also explains the difference between the **legacy `aws-auth` ConfigMap approach** and the **modern EKS Access Entry approach**.

---

## Architecture

```text
                    AWS ACCOUNT
                        │
                        ▼
                IAM User: manager
                        │
                        │ sts:AssumeRole
                        ▼
              IAM Role: eks_admin
                        │
              ┌─────────┴─────────┐
              │                   │
              ▼                   ▼
        IAM Permissions      EKS Access Entry
          eks:*                  │
       iam:PassRole              │
              │                  ▼
              │            EKS Access Policy
              │                   │
              └──────────┬────────┘
                         ▼
                    EKS Cluster
```

---

# 1. Get Current AWS Account

```hcl
data "aws_caller_identity" "current" {}
```

`aws_caller_identity` is a Terraform data source that retrieves information about the AWS identity currently being used by Terraform.

For example:

```hcl
data.aws_caller_identity.current.account_id
```

returns:

```text
123456789012
```

This allows us to dynamically construct ARNs instead of hardcoding the AWS account ID.

---

# 2. Create EKS Admin IAM Role

```hcl
resource "aws_iam_role" "eks_admin" {
  name = "${local.env}-${local.eks_name}-eks-admin"

  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Principal": {
        "AWS": "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
    }
  ]
}
POLICY
}
```

This creates an IAM role that will contain the administrative permissions.

### Trust Policy

The `assume_role_policy` is the **trust policy**.

It defines:

> Who is allowed to assume this IAM role?

The important part is:

```json
"Action": "sts:AssumeRole"
```

and:

```json
"Principal": {
  "AWS": "arn:aws:iam::<ACCOUNT_ID>:root"
}
```

The trust policy does **not** grant EKS permissions.

It only determines who can assume the role.

---

# 3. EKS Admin IAM Policy

```hcl
resource "aws_iam_policy" "eks_admin" {
  name = "AmazonEKSAdminPolicy"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "eks:*"
            ],
            "Resource": "*"
        },
        {
            "Effect": "Allow",
            "Action": "iam:PassRole",
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "iam:PassedToService": "eks.amazonaws.com"
                }
            }
        }
    ]
}
POLICY
}
```

This policy provides permissions to manage AWS EKS resources.

### `eks:*`

```json
"Action": [
    "eks:*"
]
```

This grants broad permissions for the EKS service.

For example:

```text
eks:DescribeCluster
eks:ListClusters
eks:CreateCluster
eks:UpdateClusterConfig
eks:DeleteCluster
```

and other EKS API operations.

---

# 4. IAM PassRole

The policy also contains:

```json
{
    "Effect": "Allow",
    "Action": "iam:PassRole",
    "Resource": "*",
    "Condition": {
        "StringEquals": {
            "iam:PassedToService": "eks.amazonaws.com"
        }
    }
}
```

`iam:PassRole` allows the identity to pass an IAM role to an AWS service.

The condition:

```json
"iam:PassedToService": "eks.amazonaws.com"
```

restricts the permission so the role can be passed specifically to EKS.

This is preferable to giving unrestricted `iam:PassRole`.

---

# 5. Attach Policy to EKS Admin Role

```hcl
resource "aws_iam_role_policy_attachment" "eks_admin" {
  role       = aws_iam_role.eks_admin.name
  policy_arn = aws_iam_policy.eks_admin.arn
}
```

This attaches the EKS administrator policy to the `eks_admin` role.

The resulting relationship is:

```text
eks_admin
    │
    ▼
AmazonEKSAdminPolicy
    │
    ├── eks:*
    │
    └── iam:PassRole → EKS
```

---

# 6. Create Manager IAM User

```hcl
resource "aws_iam_user" "manager" {
  name = "manager"
}
```

This creates an IAM user named:

```text
manager
```

The manager does not receive the EKS administrator permissions directly.

Instead, the manager assumes the `eks_admin` role.

```text
manager
   │
   ▼
AssumeRole
   │
   ▼
eks_admin
```

---

# 7. Allow Manager to Assume EKS Admin Role

```hcl
resource "aws_iam_policy" "eks_assume_admin" {
  name = "AmazonEKSAssumeAdminPolicy"

  policy = <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sts:AssumeRole"
            ],
            "Resource": "${aws_iam_role.eks_admin.arn}"
        }
    ]
}
POLICY
}
```

This policy allows the manager to call:

```text
sts:AssumeRole
```

on the specific:

```text
eks_admin
```

role.

The manager therefore gets temporary credentials for the role.

---

# 8. Attach AssumeRole Policy to Manager

```hcl
resource "aws_iam_user_policy_attachment" "manager" {
  user       = aws_iam_user.manager.name
  policy_arn = aws_iam_policy.eks_assume_admin.arn
}
```

The resulting flow is:

```text
IAM User: manager
       │
       │ sts:AssumeRole
       ▼
IAM Role: eks_admin
       │
       │ eks:*
       ▼
AWS EKS
```

---

# 9. Modern EKS Access Entry

The modern EKS approach uses **EKS Access Entries** instead of directly managing the legacy `aws-auth` ConfigMap.

### Access Entry

```hcl
resource "aws_eks_access_entry" "manager" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.eks_admin.arn

  type = "STANDARD"
}
```

The important part is:

```hcl
principal_arn = aws_iam_role.eks_admin.arn
```

We register the **IAM role**, not the manager IAM user.

The authentication flow is:

```text
manager
   │
   │ AssumeRole
   ▼
eks_admin
   │
   │ EKS Access Entry
   ▼
EKS Cluster
```

---

# 10. Modern EKS Access Policy

Instead of using Kubernetes groups, we can associate an AWS-managed EKS access policy.

```hcl
resource "aws_eks_access_policy_association" "manager_admin" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.eks_admin.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
```

This grants the `eks_admin` role cluster-wide EKS administrator access.

The complete modern flow becomes:

```text
IAM User
   │
   │ sts:AssumeRole
   ▼
IAM Role
eks_admin
   │
   ▼
EKS Access Entry
   │
   ▼
AmazonEKSClusterAdminPolicy
   │
   ▼
EKS Cluster
```

---

# 11. Namespace-Level Access

Access can also be restricted to specific namespaces.

For example:

```hcl
resource "aws_eks_access_policy_association" "developer_view" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.developer.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["development"]
  }
}
```

The developer can then access resources within:

```text
development
```

rather than receiving cluster-wide access.

This follows the principle of **least privilege**.

---

# 12. Alternative – EKS Access Entry with Kubernetes Groups

EKS Access Entries can also map an IAM role to a Kubernetes group.

```hcl
resource "aws_eks_access_entry" "manager" {
  cluster_name      = aws_eks_cluster.eks.name
  principal_arn     = aws_iam_role.eks_admin.arn
  kubernetes_groups = ["my-admin"]

  type = "STANDARD"
}
```

This maps:

```text
eks_admin
    │
    ▼
Kubernetes Group
my-admin
```

However, the group itself does not automatically have permissions.

Kubernetes RBAC must grant permissions to that group.

---

# 13. Kubernetes RBAC

Example:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: my-admin
subjects:
  - kind: Group
    name: my-admin
    apiGroup: rbac.authorization.k8s.io

roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

The complete flow becomes:

```text
IAM Role
   │
   ▼
EKS Access Entry
   │
   ▼
my-admin Kubernetes Group
   │
   ▼
ClusterRoleBinding
   │
   ▼
cluster-admin
   │
   ▼
Full Kubernetes permissions
```

### Important

This:

```hcl
kubernetes_groups = ["my-admin"]
```

does **not** automatically mean administrator access.

The Kubernetes group needs an appropriate `RoleBinding` or `ClusterRoleBinding`.

---

# 14. Legacy Approach – `aws-auth`

Before Access Entries, EKS commonly used the `aws-auth` ConfigMap.

Example:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system

data:
  mapRoles: |
    - rolearn: arn:aws:iam::123456789012:role/eks_admin
      username: eks-admin
      groups:
        - my-admin
```

This maps the IAM role to the Kubernetes group:

```text
my-admin
```

Kubernetes RBAC then determines what that group can do.

### Legacy Flow

```text
IAM Role
   │
   ▼
aws-auth ConfigMap
   │
   ▼
Kubernetes Group
   │
   ▼
Kubernetes RBAC
   │
   ▼
Permissions
```

---

# 15. Legacy vs Modern EKS Access

| Feature                                  | `aws-auth` ConfigMap | EKS Access Entry   |
| ---------------------------------------- | -------------------- | ------------------ |
| Status                                   | Legacy               | Modern             |
| Managed through                          | Kubernetes ConfigMap | EKS API            |
| Terraform support                        | Yes                  | Yes                |
| IAM authentication                       | Yes                  | Yes                |
| Kubernetes groups                        | Yes                  | Yes                |
| EKS access policies                      | No                   | Yes                |
| Namespace access scope                   | Manual RBAC          | Supported          |
| Direct `aws-auth` management             | Required             | Not required       |
| AWS-managed access policies              | No                   | Yes                |
| Recommended for new deployments          | No                   | **Yes**            |
| Easier to automate                       | Moderate             | **Yes**            |
| Recommended for existing legacy clusters | Existing use         | Consider migration |

---

# 16. Recommended Production Architecture

For a modern production EKS environment:

```text
                Identity Provider
                       │
                       ▼
                IAM Role / SSO
                       │
                       ▼
               EKS Access Entry
                       │
              ┌────────┴────────┐
              │                 │
              ▼                 ▼
       EKS Access Policy    Kubernetes Groups
              │                 │
              ▼                 ▼
       AWS-managed policy   Kubernetes RBAC
              │                 │
              └────────┬────────┘
                       ▼
                   EKS Cluster
```

### Recommended Practices

* Prefer **IAM roles** instead of long-lived IAM users.
* Use temporary credentials through `AssumeRole` or IAM Identity Center.
* Use **EKS Access Entries** for new EKS clusters.
* Use EKS access policies where AWS-managed permissions meet your requirements.
* Use namespace-scoped access wherever possible.
* Use Kubernetes RBAC for custom or fine-grained permissions.
* Follow the **principle of least privilege**.
* Avoid giving `cluster-admin` unless full administrative access is genuinely required.
* Avoid unrestricted `iam:PassRole`.

---

# 17. Complete Modern Terraform Example

```hcl
data "aws_caller_identity" "current" {}

# IAM role
resource "aws_iam_role" "eks_admin" {
  name = "${local.env}-${local.eks_name}-eks-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"

    Statement = [{
      Effect = "Allow"

      Action = "sts:AssumeRole"

      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
    }]
  })
}

# EKS administrative IAM policy
resource "aws_iam_policy" "eks_admin" {
  name = "AmazonEKSAdminPolicy"

  policy = jsonencode({
    Version = "2012-10-17"

    Statement = [
      {
        Effect   = "Allow"
        Action   = "eks:*"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = "*"

        Condition = {
          StringEquals = {
            "iam:PassedToService" = "eks.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Attach IAM policy to role
resource "aws_iam_role_policy_attachment" "eks_admin" {
  role       = aws_iam_role.eks_admin.name
  policy_arn = aws_iam_policy.eks_admin.arn
}

# EKS Access Entry
resource "aws_eks_access_entry" "manager" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.eks_admin.arn

  type = "STANDARD"
}

# EKS Cluster Administrator access
resource "aws_eks_access_policy_association" "manager_admin" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_role.eks_admin.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}
```

---

# 18. Final Recommendation

### For a new EKS implementation

Use:

```text
IAM Role
   ↓
EKS Access Entry
   ↓
EKS Access Policy
   ↓
Cluster / Namespace
```

### For custom Kubernetes permissions

Use:

```text
IAM Role
   ↓
EKS Access Entry
   ↓
Kubernetes Group
   ↓
RoleBinding / ClusterRoleBinding
   ↓
Kubernetes RBAC
```

### For legacy EKS clusters

You may still encounter:

```text
IAM Role
   ↓
aws-auth ConfigMap
   ↓
Kubernetes Group
   ↓
RBAC
```

but for new implementations, **EKS Access Entries are the preferred modern approach**.

---

## Interview Summary

> **"Historically, EKS used the aws-auth ConfigMap to map IAM users or roles to Kubernetes groups. The modern approach is EKS Access Entries. I prefer creating an Access Entry for an IAM role and associating an appropriate EKS access policy, such as AmazonEKSViewPolicy or AmazonEKSClusterAdminPolicy. For least privilege, I can scope access to specific namespaces. If I need custom Kubernetes permissions, I can use Kubernetes groups with RoleBindings or ClusterRoleBindings."**
