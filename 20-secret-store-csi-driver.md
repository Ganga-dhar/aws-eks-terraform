# EKS Secret Store CSI Driver with AWS Secrets Manager

This project demonstrates how to securely consume secrets stored in **AWS Secrets Manager** from applications running on **Amazon EKS** using:

* Amazon EKS
* AWS Secrets Manager
* Secret Store CSI Driver
* AWS Secrets Store CSI Driver Provider
* IAM Roles for Service Accounts (IRSA)
* Terraform
* Helm
* Kubernetes YAML

The project does **not** use the Terraform Kubernetes provider. Terraform is used for AWS infrastructure and Helm deployments, while Kubernetes application resources are managed using `kubectl`.

---

## Architecture

```text
                    AWS
                     |
             +------------------+
             | AWS Secrets      |
             | Manager          |
             |                  |
             | myapp/database   |
             +--------+---------+
                      |
                      | GetSecretValue
                      |
                IAM Policy
                      |
                IAM Role / IRSA
                      |
                      |
              +-------v-------+
              | EKS           |
              | ServiceAccount|
              | myapp         |
              +-------+-------+
                      |
                      v
        +-----------------------------+
        | Secret Store CSI Driver     |
        +-------------+---------------+
                      |
                      v
        +-----------------------------+
        | AWS Provider                |
        | for Secret Store CSI       |
        +-------------+---------------+
                      |
                      v
              AWS Secrets Manager
                      |
                      v
              Kubernetes Pod
                 /       \
                /         \
               v           v
      Mounted Secret     K8s Secret
      /mnt/secrets-store  (optional)
```

---

# Project Structure

```text
eks-secret-store-csi/
│
├── terraform/
│   ├── secret-store-csi.tf
│   ├── secrets-manager.tf
│   ├── iam.tf
│   └── outputs.tf
│
└── kubernetes/
    ├── 01-namespace.yaml
    ├── 02-serviceaccount.yaml
    ├── 03-secretproviderclass.yaml
    ├── 04-deployment.yaml
    └── 05-service.yaml
```

---

# Prerequisites

Install/configure:

* AWS CLI
* Terraform
* kubectl
* Helm
* An existing EKS cluster
* EKS OIDC provider
* AWS credentials with sufficient permissions

Verify:

```bash
aws --version
terraform version
kubectl version --client
helm version
```

Configure AWS:

```bash
aws configure
```

Verify AWS identity:

```bash
aws sts get-caller-identity
```

Configure kubeconfig:

```bash
aws eks update-kubeconfig \
  --region <AWS_REGION> \
  --name <EKS_CLUSTER_NAME>
```

Verify:

```bash
kubectl get nodes
```

---

# 1. Deploy Secret Store CSI Driver

Terraform deploys the Secret Store CSI Driver using Helm.

## `terraform/secret-store-csi.tf`

```hcl
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
```

### Important

For the Helm provider version used in this project, `set` is defined as an argument:

```hcl
set = [
  {
    name  = "syncSecret.enabled"
    value = "true"
  }
]
```

Do not use:

```hcl
set {
  name  = "syncSecret.enabled"
  value = true
}
```

---

# 2. Create AWS Secrets Manager Secret

Create a demo secret.

## `terraform/secrets-manager.tf`

```hcl
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
```

The secret stored in AWS Secrets Manager looks conceptually like:

```json
{
  "username": "admin",
  "password": "SuperSecretPassword123!",
  "database": "myapp",
  "host": "mysql.example.internal"
}
```

> **Production note:** Do not normally store real production passwords directly in Terraform code because secret values can become part of Terraform state. Use a secure secret-creation/rotation process for production.

---

# 3. IAM Role for Service Account

The application Pod needs permission to retrieve the secret from AWS Secrets Manager.

We use **IRSA**.

The existing EKS OIDC provider is:

```hcl
aws_iam_openid_connect_provider.eks
```

---

## Trust Policy

### `terraform/iam.tf`

```hcl
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
```

---

# 4. Create IAM Role

```hcl
resource "aws_iam_role" "myapp_secrets" {
  name = "${aws_eks_cluster.eks.name}-myapp-secrets"

  assume_role_policy = data.aws_iam_policy_document.myapp_secrets.json
}
```

The ServiceAccount:

```text
namespace = 12-example
serviceAccount = myapp
```

is allowed to assume this IAM role.

---

# 5. Create IAM Policy

The application only needs:

```text
secretsmanager:GetSecretValue
secretsmanager:DescribeSecret
```

Use the specific secret ARN instead of:

```text
Resource = "*"
```

Example:

```hcl
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
```

Attach the policy:

```hcl
resource "aws_iam_role_policy_attachment" "myapp_secrets" {
  role = aws_iam_role.myapp_secrets.name

  policy_arn = aws_iam_policy.myapp_secrets.arn
}
```

---

# 6. Terraform Outputs

## `terraform/outputs.tf`

```hcl
output "myapp_secrets_role_arn" {
  value = aws_iam_role.myapp_secrets.arn
}

output "myapp_secret_arn" {
  value = aws_secretsmanager_secret.myapp.arn
}
```

Get the role ARN:

```bash
terraform output myapp_secrets_role_arn
```

Example:

```text
arn:aws:iam::123456789012:role/dev-eks-myapp-secrets
```

---

# 7. Kubernetes Namespace

## `kubernetes/01-namespace.yaml`

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: 12-example
```

Apply:

```bash
kubectl apply -f 01-namespace.yaml
```

---

# 8. Kubernetes ServiceAccount

## `kubernetes/02-serviceaccount.yaml`

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  namespace: 12-example
  annotations:
    eks.amazonaws.com/role-arn: "REPLACE_WITH_TERRAFORM_OUTPUT"
```

Replace:

```text
REPLACE_WITH_TERRAFORM_OUTPUT
```

with:

```bash
terraform output myapp_secrets_role_arn
```

Example:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: myapp
  namespace: 12-example
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789012:role/dev-eks-myapp-secrets"
```

Apply:

```bash
kubectl apply -f 02-serviceaccount.yaml
```

---

# 9. SecretProviderClass

The `SecretProviderClass` tells the CSI driver:

1. Which provider to use
2. Which AWS Secrets Manager secret to retrieve
3. Which JSON fields to expose
4. Whether to create a Kubernetes Secret

## `kubernetes/03-secretproviderclass.yaml`

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass

metadata:
  name: myapp-secrets
  namespace: 12-example

spec:
  provider: aws

  parameters:
    objects: |
      - objectName: "myapp/database"
        objectType: "secretsmanager"

        jmesPath:
          - path: username
            objectAlias: username

          - path: password
            objectAlias: password

          - path: database
            objectAlias: database

          - path: host
            objectAlias: host

  secretObjects:
    - secretName: myapp-k8s-secret
      type: Opaque

      data:
        - objectName: username
          key: username

        - objectName: password
          key: password

        - objectName: database
          key: database

        - objectName: host
          key: host
```

Apply:

```bash
kubectl apply -f 03-secretproviderclass.yaml
```

---

# 10. Deployment

## `kubernetes/04-deployment.yaml`

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: myapp
  namespace: 12-example

spec:
  replicas: 2

  selector:
    matchLabels:
      app: myapp

  template:
    metadata:
      labels:
        app: myapp

    spec:
      serviceAccountName: myapp

      containers:
        - name: myapp
          image: nginx:latest

          ports:
            - containerPort: 80

          volumeMounts:
            - name: secrets-store
              mountPath: /mnt/secrets-store
              readOnly: true

          env:
            - name: DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: myapp-k8s-secret
                  key: username

            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: myapp-k8s-secret
                  key: password

            - name: DB_HOST
              valueFrom:
                secretKeyRef:
                  name: myapp-k8s-secret
                  key: host

      volumes:
        - name: secrets-store
          csi:
            driver: secrets-store.csi.k8s.io
            readOnly: true

            volumeAttributes:
              secretProviderClass: myapp-secrets
```

Apply:

```bash
kubectl apply -f 04-deployment.yaml
```

---

# 11. Kubernetes Service

## `kubernetes/05-service.yaml`

```yaml
apiVersion: v1
kind: Service

metadata:
  name: myapp
  namespace: 12-example

spec:
  type: ClusterIP

  selector:
    app: myapp

  ports:
    - port: 80
      targetPort: 80
```

Apply:

```bash
kubectl apply -f 05-service.yaml
```

---

# 12. Deploy the Complete Project

## Terraform

```bash
cd terraform

terraform init
```

Format:

```bash
terraform fmt
```

Validate:

```bash
terraform validate
```

Plan:

```bash
terraform plan
```

Apply:

```bash
terraform apply
```

Get the IAM role:

```bash
terraform output myapp_secrets_role_arn
```

---

# Kubernetes

```bash
cd ../kubernetes
```

Apply all resources:

```bash
kubectl apply -f .
```

Or individually:

```bash
kubectl apply -f 01-namespace.yaml
kubectl apply -f 02-serviceaccount.yaml
kubectl apply -f 03-secretproviderclass.yaml
kubectl apply -f 04-deployment.yaml
kubectl apply -f 05-service.yaml
```

---

# 13. Verify Secret Store CSI Driver

```bash
kubectl get pods -n kube-system | grep secrets
```

Expected components include:

```text
secrets-store-csi-driver-xxxxx
secrets-store-csi-driver-xxxxx
secrets-store-csi-driver-provider-aws-xxxxx
```

Check Helm releases:

```bash
helm list -n kube-system
```

---

# 14. Verify ServiceAccount

```bash
kubectl get sa -n 12-example
```

Check the annotation:

```bash
kubectl describe sa myapp -n 12-example
```

You should see:

```text
eks.amazonaws.com/role-arn:
arn:aws:iam::123456789012:role/dev-eks-myapp-secrets
```

---

# 15. Verify SecretProviderClass

```bash
kubectl get secretproviderclass -n 12-example
```

Expected:

```text
NAME             AGE
myapp-secrets    1m
```

Describe:

```bash
kubectl describe secretproviderclass myapp-secrets -n 12-example
```

---

# 16. Verify Application Pods

```bash
kubectl get pods -n 12-example
```

Expected:

```text
NAME                      READY   STATUS
myapp-xxxxxxxxxx-xxxxx    1/1     Running
myapp-xxxxxxxxxx-xxxxx    1/1     Running
```

---

# 17. Verify Mounted Secrets

Get the Pod:

```bash
kubectl get pods -n 12-example
```

Execute into the Pod:

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  ls -l /mnt/secrets-store
```

Expected:

```text
database
host
password
username
```

Read the username:

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  cat /mnt/secrets-store/username
```

Expected:

```text
admin
```

Read database:

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  cat /mnt/secrets-store/database
```

Expected:

```text
myapp
```

---

# 18. Verify Kubernetes Secret

Because we configured:

```yaml
secretObjects:
```

the CSI driver can synchronize the mounted secret into a Kubernetes Secret.

Check:

```bash
kubectl get secret -n 12-example
```

Expected:

```text
NAME                 TYPE
myapp-k8s-secret     Opaque
```

Describe:

```bash
kubectl describe secret myapp-k8s-secret -n 12-example
```

The values will not be displayed by `describe`.

---

# 19. Verify Environment Variables

The Deployment uses:

```yaml
env:
  - name: DB_USERNAME
    valueFrom:
      secretKeyRef:
        name: myapp-k8s-secret
        key: username
```

Check:

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  printenv DB_USERNAME
```

Expected:

```text
admin
```

Check:

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  printenv DB_HOST
```

Expected:

```text
mysql.example.internal
```

---

# How It Works

The complete authentication flow is:

```text
                    EKS
                     |
                     |
              Kubernetes Pod
                     |
                     |
             ServiceAccount
                 "myapp"
                     |
                     |
                  IRSA
                     |
                     | AssumeRoleWithWebIdentity
                     |
                     v
                AWS STS
                     |
                     |
                 IAM Role
                     |
                     | GetSecretValue
                     |
                     v
            AWS Secrets Manager
                     |
                     |
              myapp/database
                     |
                     |
                     v
           Secret Store CSI Driver
                     |
              +------+------+
              |             |
              v             v
       Mounted Files    K8s Secret
       /mnt/secrets-     myapp-k8s-secret
       store/
```

---

# Why IRSA?

Without IRSA, applications might require static AWS credentials.

For example:

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

This is not recommended.

With IRSA:

```text
Pod
 |
 v
ServiceAccount
 |
 v
OIDC
 |
 v
IAM Role
 |
 v
AWS API
```

The Pod receives temporary AWS credentials.

There is no need to hard-code AWS access keys inside the application.

---

# Why Secret Store CSI Driver?

The Secret Store CSI Driver allows Kubernetes Pods to consume secrets from external secret-management systems.

In this project:

```text
Kubernetes
    |
    v
Secret Store CSI Driver
    |
    v
AWS Provider
    |
    v
AWS Secrets Manager
```

The secret can be mounted directly into the Pod as a file.

Example:

```text
/mnt/secrets-store/password
```

---

# Two Ways to Consume the Secret

## Option 1 — Mounted File

The application reads:

```text
/mnt/secrets-store/username
/mnt/secrets-store/password
/mnt/secrets-store/database
/mnt/secrets-store/host
```

This is provided by the CSI volume.

---

## Option 2 — Kubernetes Secret

The `secretObjects` configuration synchronizes the external secret into:

```text
myapp-k8s-secret
```

The application can then use:

```yaml
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: myapp-k8s-secret
        key: password
```

---

# Secret Rotation

AWS Secrets Manager supports secret rotation.

When the secret changes in AWS Secrets Manager, the CSI driver can update the mounted secret contents according to its rotation/reconciliation behavior.

Applications should be designed to handle secret changes appropriately.

For environment variables sourced from a Kubernetes Secret, remember that changing the Secret does not automatically recreate an already-running Pod. Applications that require refreshed environment variables may need a Pod restart.

---

# Security Best Practices

## 1. Use least-privilege IAM

Avoid:

```hcl
Resource = "*"
```

Prefer:

```hcl
Resource = aws_secretsmanager_secret.myapp.arn
```

---

## 2. Restrict the ServiceAccount

The IRSA trust policy should restrict:

```text
namespace
+
service account
```

Example:

```text
system:serviceaccount:12-example:myapp
```

This prevents other ServiceAccounts from assuming the role.

---

## 3. Do not use static AWS credentials

Avoid:

```yaml
env:
  - name: AWS_ACCESS_KEY_ID
  - name: AWS_SECRET_ACCESS_KEY
```

Use:

```text
IRSA
```

instead.

---

## 4. Protect Terraform State

The following resource contains sensitive data:

```hcl
aws_secretsmanager_secret_version
```

Terraform state can therefore contain the secret value.

For production:

* Encrypt the Terraform backend
* Use an S3 backend with appropriate access controls
* Enable state locking where applicable
* Restrict access to Terraform state
* Avoid putting production secret values directly into `.tf` files
* Use a secure secret bootstrap/rotation mechanism

---

# Troubleshooting

## Pod is not starting

```bash
kubectl describe pod <POD_NAME> -n 12-example
```

Check events:

```bash
kubectl get events \
  -n 12-example \
  --sort-by=.lastTimestamp
```

---

## SecretProviderClass errors

```bash
kubectl describe secretproviderclass \
  myapp-secrets \
  -n 12-example
```

Check CSI driver logs:

```bash
kubectl get pods -n kube-system | grep secrets
```

Then:

```bash
kubectl logs -n kube-system <CSI_DRIVER_POD>
```

---

## AWS Provider logs

Find the provider:

```bash
kubectl get pods -n kube-system | grep provider-aws
```

Then:

```bash
kubectl logs -n kube-system <AWS_PROVIDER_POD>
```

---

## AccessDeniedException

If you see:

```text
AccessDeniedException
```

check:

### IAM policy

The role should have:

```text
secretsmanager:GetSecretValue
secretsmanager:DescribeSecret
```

### Secret ARN

Make sure the IAM policy references the correct secret:

```hcl
Resource = aws_secretsmanager_secret.myapp.arn
```

### IRSA annotation

Check:

```bash
kubectl describe sa myapp -n 12-example
```

Make sure:

```text
eks.amazonaws.com/role-arn
```

contains the correct IAM role.

### Trust policy

Make sure the trust relationship contains:

```text
system:serviceaccount:12-example:myapp
```

and:

```text
sts.amazonaws.com
```

---

# Common Mistake

Do not accidentally use:

```yaml
serviceAccountName: default
```

The Deployment must use:

```yaml
serviceAccountName: myapp
```

because the IAM role is attached to:

```text
myapp
```

---

# Important Difference: CSI Secret vs Kubernetes Secret

```text
AWS Secrets Manager
        |
        v
Secret Store CSI
        |
        +--------------------+
        |                    |
        v                    v
Mounted file          Kubernetes Secret
        |                    |
        v                    v
Application            Application
```

CSI mounted secret:

```text
/mnt/secrets-store/password
```

Kubernetes Secret:

```text
myapp-k8s-secret
```

The second one introduces a copy of the secret into Kubernetes/etcd, so use it only when your application specifically needs Kubernetes Secret semantics.

---

# Terraform vs Kubernetes Responsibility

This project intentionally separates infrastructure from application configuration.

## Terraform manages

```text
AWS Secrets Manager
        |
IAM Role
        |
IAM Policy
        |
IRSA trust relationship
        |
Secret Store CSI Driver
        |
AWS Provider
```

## kubectl manages

```text
Namespace
ServiceAccount
SecretProviderClass
Deployment
Service
```

There is **no Kubernetes Terraform provider** in this project.

---

# Complete Deployment Flow

```text
1. Create EKS
       |
       v
2. Configure OIDC
       |
       v
3. Create Secrets Manager secret
       |
       v
4. Create IAM policy
       |
       v
5. Create IRSA role
       |
       v
6. Install Secret Store CSI Driver
       |
       v
7. Install AWS provider
       |
       v
8. Create Kubernetes ServiceAccount
       |
       v
9. Create SecretProviderClass
       |
       v
10. Deploy application
       |
       v
11. CSI driver requests secret
       |
       v
12. IAM/IRSA authentication
       |
       v
13. AWS Secrets Manager
       |
       v
14. Secret mounted into Pod
```

---

# Cleanup

Delete Kubernetes resources:

```bash
kubectl delete -f kubernetes/
```

Destroy Terraform resources:

```bash
cd terraform

terraform destroy
```

---

# Interview Explanation

### Question: How do you access AWS Secrets Manager secrets from an EKS Pod?

**Answer:**

> I use the AWS Secrets Store CSI Driver with the AWS provider. The application Pod runs with a dedicated Kubernetes ServiceAccount mapped to an IAM role using IRSA. The IAM role has least-privilege permissions to read a specific secret from AWS Secrets Manager. The SecretProviderClass defines which secret should be retrieved, and the CSI driver mounts the secret into the Pod as files. If required, I can also synchronize the external secret into a Kubernetes Secret for applications that consume secrets through environment variables.

---

# Interview Architecture Answer

```text
EKS Pod
   |
   | ServiceAccount
   v
IRSA
   |
   | AssumeRoleWithWebIdentity
   v
IAM Role
   |
   | secretsmanager:GetSecretValue
   v
AWS Secrets Manager
   |
   v
Secret Store CSI Driver
   |
   v
Pod filesystem
```

This avoids static AWS credentials and follows the principle of least privilege.

---

# Key Commands

### Terraform

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
terraform output myapp_secrets_role_arn
terraform destroy
```

### Kubernetes

```bash
kubectl get nodes

kubectl get pods -n kube-system

kubectl get pods -n 12-example

kubectl get sa -n 12-example

kubectl get secretproviderclass -n 12-example

kubectl get secrets -n 12-example

kubectl describe pod <POD_NAME> -n 12-example

kubectl logs -n kube-system <POD_NAME>
```

### Test mounted secret

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  ls -l /mnt/secrets-store
```

```bash
kubectl exec -n 12-example <POD_NAME> -- \
  cat /mnt/secrets-store/username
```

---

# Final Architecture

```text
                         AWS
                          |
              +-----------+-----------+
              |                       |
              v                       v
       Secrets Manager             IAM
       myapp/database           IAM Role / IRSA
              |                       |
              |                       |
              +-----------+-----------+
                          |
                          v
                         EKS
                          |
                ServiceAccount: myapp
                          |
                          v
              Secret Store CSI Driver
                          |
                    AWS Provider
                          |
                          v
                    Application Pod
                     /           \
                    /             \
                   v               v
          Mounted Secret       K8s Secret
          /mnt/secrets-store   myapp-k8s-secret
```

---

## Key Takeaways

* **AWS Secrets Manager** stores the actual secret.
* **IRSA** provides AWS permissions to the Kubernetes ServiceAccount.
* **IAM policy** provides least-privilege access to Secrets Manager.
* **Secret Store CSI Driver** retrieves external secrets.
* **AWS provider** connects the CSI driver to AWS Secrets Manager.
* **SecretProviderClass** defines which secrets the Pod consumes.
* Secrets can be mounted as **files**.
* Secrets can optionally be synchronized into a **Kubernetes Secret**.
* No static AWS access keys are required.
* No Terraform Kubernetes provider is required.
* Terraform manages AWS infrastructure and Helm.
* `kubectl` manages Kubernetes application resources.
