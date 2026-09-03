# Amazon EKS Access Management

This document explains two approaches for granting IAM users or IAM roles access to an Amazon EKS cluster:

1. **Legacy approach – `aws-auth` ConfigMap**
2. **Modern approach – EKS Access Entries**

---

## 1. Legacy Approach – `aws-auth` ConfigMap

Historically, EKS used the `aws-auth` ConfigMap in the `kube-system` namespace to map AWS IAM identities to Kubernetes users and groups.

### Example

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system

data:
  mapUsers: |
    - userarn: arn:aws:iam::123456789012:user/developer
      username: developer
      groups:
        - my-viewer
```

The IAM user is mapped to the Kubernetes group:

```text
my-viewer
```

You then use Kubernetes RBAC to assign permissions to that group.

### Example RBAC

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-viewer
subjects:
  - kind: Group
    name: my-viewer
    apiGroup: rbac.authorization.k8s.io

roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

### Access Flow

```text
IAM User
   │
   ▼
aws-auth ConfigMap
   │
   ▼
Kubernetes Group
   │
   ▼
ClusterRoleBinding
   │
   ▼
Kubernetes permissions
```

---

# 2. Modern Approach – EKS Access Entries

Amazon EKS provides **Access Entries** as the modern way to manage access for IAM principals.

Instead of manually modifying the `aws-auth` ConfigMap, access is managed through the EKS API and can be managed declaratively using Terraform.

## Terraform Example

### Step 1 – Create an EKS Access Entry

```hcl
resource "aws_eks_access_entry" "developer" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn

  type = "STANDARD"
}
```

This registers the IAM principal with the EKS cluster.

### Step 2 – Associate an EKS Access Policy

```hcl
resource "aws_eks_access_policy_association" "developer_view" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}
```

The developer receives read-only/view access to the cluster.

### Access Flow

```text
IAM User / IAM Role
        │
        ▼
EKS Access Entry
        │
        ▼
EKS Access Policy
AmazonEKSViewPolicy
        │
        ▼
EKS Cluster
        │
        ▼
Kubernetes API
```

---

# 3. Namespace-Level Access

With Access Entries, you can restrict access to a specific namespace.

```hcl
resource "aws_eks_access_policy_association" "developer_view" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["development"]
  }
}
```

The developer can view resources only in:

```text
development
```

rather than the entire cluster.

---

# 4. Access Entry with Kubernetes Groups

Access Entries can also map an IAM principal to Kubernetes groups.

```hcl
resource "aws_eks_access_entry" "developer" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn

  kubernetes_groups = ["my-viewer"]
}
```

You can then use Kubernetes RBAC:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: developer-viewer
subjects:
  - kind: Group
    name: my-viewer
    apiGroup: rbac.authorization.k8s.io

roleRef:
  kind: ClusterRole
  name: view
  apiGroup: rbac.authorization.k8s.io
```

### Important

Creating the Access Entry with:

```hcl
kubernetes_groups = ["my-viewer"]
```

**does not automatically give the group permissions.**

Kubernetes RBAC must still grant permissions to `my-viewer`.

---

# 5. Legacy vs Modern Approach

| Feature                      | `aws-auth` ConfigMap | EKS Access Entry |
| ---------------------------- | -------------------- | ---------------- |
| Approach                     | Legacy               | Modern           |
| Managed through              | Kubernetes ConfigMap | EKS API          |
| Terraform support            | Yes                  | Yes              |
| IAM → EKS mapping            | Yes                  | Yes              |
| Kubernetes groups            | Yes                  | Yes              |
| EKS access policies          | No                   | Yes              |
| Namespace-scoped EKS policy  | No                   | Yes              |
| Requires editing `aws-auth`  | Yes                  | No               |
| Easier to automate           | Moderate             | Yes              |
| AWS-managed policies         | No                   | Yes              |
| Recommended for new clusters | No                   | **Yes**          |
| Migration direction          | Existing/legacy      | **Preferred**    |

---

# 6. Which Approach Is Best?

## Recommended: EKS Access Entries

For **new EKS clusters**, use:

```text
EKS Access Entry
        +
EKS Access Policy
```

For example:

```hcl
resource "aws_eks_access_entry" "developer" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn
}

resource "aws_eks_access_policy_association" "developer_view" {
  cluster_name  = aws_eks_cluster.eks.name
  principal_arn = aws_iam_user.developer.arn

  policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"

  access_scope {
    type = "cluster"
  }
}
```

### Why?

The Access Entry approach:

* Removes the need to manually manage `aws-auth`.
* Is easier to manage using Terraform.
* Provides AWS-managed EKS access policies.
* Supports cluster-level and namespace-level access scopes.
* Provides a cleaner separation between AWS IAM identity and EKS authorization.
* Is the preferred approach for modern EKS access management.

---

# 7. When Would You Still Use `aws-auth`?

You may encounter `aws-auth` when:

* Managing an older EKS cluster.
* Supporting an existing infrastructure implementation.
* Working with legacy automation.
* Maintaining a cluster that has not yet migrated to Access Entries.

For new implementations, however, **Access Entries should generally be preferred**.

---

# 8. Interview Answer

If asked:

> "How do you provide IAM users access to an EKS cluster?"

A good answer is:

> "Historically, we used the `aws-auth` ConfigMap to map IAM users or roles to Kubernetes users and groups. The modern approach is EKS Access Entries. I would create an Access Entry for the IAM role or user and associate an appropriate EKS access policy, such as AmazonEKSViewPolicy. I can also scope the access to specific namespaces. For new EKS implementations, I prefer Access Entries because they are managed through the EKS API, integrate well with Terraform, and avoid directly managing the legacy `aws-auth` ConfigMap."

---

# 9. Recommended Architecture

For a production EKS environment, a common pattern is:

```text
                    AWS IAM
                       │
             ┌─────────┴─────────┐
             │                   │
        Developer Role      Platform/Admin Role
             │                   │
             ▼                   ▼
       EKS Access Entry    EKS Access Entry
             │                   │
             ▼                   ▼
     AmazonEKSViewPolicy   AmazonEKSClusterAdminPolicy
             │                   │
             ▼                   ▼
       Dev Namespace          EKS Cluster
```

Use **IAM roles rather than individual IAM users** where possible, especially when integrating with AWS IAM Identity Center or other centralized identity systems.

---

## Summary

```text
OLD
IAM User/Role
     ↓
aws-auth ConfigMap
     ↓
Kubernetes Group
     ↓
Kubernetes RBAC


MODERN / RECOMMENDED
IAM User/Role
     ↓
EKS Access Entry
     ↓
EKS Access Policy
     ↓
Cluster / Namespace
```

### Final Recommendation

**New EKS cluster → Use EKS Access Entries.**

**Existing legacy cluster → `aws-auth` may still exist, but consider migrating to Access Entries.**

**Fine-grained custom Kubernetes permissions → Access Entry + Kubernetes groups/RBAC can be used.**
