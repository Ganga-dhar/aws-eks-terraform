# EKS + EFS CSI Driver using Terraform and Kubernetes YAML

This project demonstrates how to configure **Amazon EFS with Amazon EKS** using:

* Terraform
* Amazon EFS
* EFS Mount Targets
* EFS Security Group
* IAM Roles for Service Accounts (IRSA)
* AWS EFS CSI Driver
* Helm
* Kubernetes StorageClass
* Kubernetes PersistentVolumeClaim (PVC)
* Kubernetes Deployment
* Kubernetes Service
* Kubernetes Ingress

The **Kubernetes Terraform provider is intentionally not used**.

Terraform manages the AWS infrastructure and Helm installation, while Kubernetes application resources are managed using `kubectl` and YAML manifests.

---

## Architecture

```text
                         AWS VPC
                            |
                  +---------+---------+
                  |                   |
                AZ-A                 AZ-B
                  |                   |
             EKS Nodes           EKS Nodes
                  |                   |
                  +---------+---------+
                            |
                       TCP 2049/NFS
                            |
                +-----------+-----------+
                |                       |
          EFS Mount Target         EFS Mount Target
              AZ-A                     AZ-B
                |                       |
                +-----------+-----------+
                            |
                       EFS File System
                            |
                     EFS Access Point
                            |
                    EFS CSI Driver
                            |
                    Kubernetes PVC
                            |
                   +--------+--------+
                   |                 |
                 Pod-1             Pod-2
                   |                 |
                   +--------+--------+
                            |
                          /data
```

---

# Project Structure

```text
eks-efs/
│
├── terraform/
│   ├── 01-efs.tf
│   ├── 02-efs-iam.tf
│   ├── 03-efs-csi-driver.tf
│   ├── outputs.tf
│   └── ...
│
└── kubernetes/
    ├── 01-namespace.yaml
    ├── 02-storageclass.yaml
    ├── 03-pvc.yaml
    ├── 04-deployment.yaml
    ├── 05-service.yaml
    └── 06-ingress.yaml
```

---

# Prerequisites

Before starting, make sure you have:

```text
AWS CLI
Terraform
kubectl
Helm
An existing EKS cluster
```

Verify:

```bash
aws --version
terraform version
kubectl version --client
helm version
```

---

# 1. EFS File System

Create an encrypted EFS filesystem.

```hcl
resource "aws_efs_file_system" "eks" {
  creation_token = "${aws_eks_cluster.eks.name}-efs"

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"
  encrypted        = true

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs"
  }
}
```

### Explanation

```text
performance_mode = generalPurpose
```

Recommended for most workloads.

```text
throughput_mode = bursting
```

Provides burst throughput based on the filesystem.

```text
encrypted = true
```

Enables encryption at rest.

---

# 2. EFS Security Group

EFS uses NFS.

NFS traffic uses:

```text
TCP 2049
```

Create a security group:

```hcl
resource "aws_security_group" "efs" {
  name        = "${aws_eks_cluster.eks.name}-efs-sg"
  description = "Security group for EFS"
  vpc_id      = aws_eks_cluster.eks.vpc_config[0].vpc_id

  ingress {
    description = "NFS from EKS"

    protocol  = "tcp"
    from_port = 2049
    to_port   = 2049

    security_groups = [
      aws_eks_cluster.eks.vpc_config[0].cluster_security_group_id
    ]
  }

  egress {
    description = "Allow outbound"

    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs-sg"
  }
}
```

The traffic flow is:

```text
EKS Node/Pod
     |
     | TCP 2049
     ↓
EFS Security Group
     |
     ↓
EFS Mount Target
```

> For a production environment, restrict the EFS security group to the actual EKS node security group or pod security group rather than allowing a broad source.

---

# 3. EFS Mount Targets

Create one mount target per AZ.

## AZ-A

```hcl
resource "aws_efs_mount_target" "zone_a" {
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = aws_subnet.private_zone1.id
  security_groups = [aws_security_group.efs.id]
}
```

## AZ-B

```hcl
resource "aws_efs_mount_target" "zone_b" {
  file_system_id  = aws_efs_file_system.eks.id
  subnet_id       = aws_subnet.private_zone2.id
  security_groups = [aws_security_group.efs.id]
}
```

Architecture:

```text
                   EFS
                    |
          +---------+---------+
          |                   |
       Mount Target        Mount Target
         AZ-A                 AZ-B
          |                   |
       EKS Node             EKS Node
```

EFS is regional, so it can be accessed from multiple Availability Zones.

> Make sure `private_zone1` and `private_zone2` are in different Availability Zones. AWS supports one EFS mount target per AZ.

---

# 4. IAM Role for EFS CSI Driver

The EFS CSI controller needs AWS permissions.

This example uses **IRSA**.

## Trust Policy

```hcl
data "aws_iam_policy_document" "efs_csi_driver" {
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
```

---

# 5. IAM Role

```hcl
resource "aws_iam_role" "efs_csi_driver" {
  name = "${aws_eks_cluster.eks.name}-efs-csi-driver"

  assume_role_policy = data.aws_iam_policy_document.efs_csi_driver.json

  tags = {
    Name = "${aws_eks_cluster.eks.name}-efs-csi-driver"
  }
}
```

---

# 6. Attach EFS CSI IAM Policy

```hcl
resource "aws_iam_role_policy_attachment" "efs_csi_driver" {
  role = aws_iam_role.efs_csi_driver.name

  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}
```

The relationship is:

```text
EKS OIDC
   |
   | AssumeRoleWithWebIdentity
   ↓
IAM Role
   |
   ↓
AmazonEFSCSIDriverPolicy
   |
   ↓
EFS APIs
```

---

# 7. Install EFS CSI Driver using Helm

The Kubernetes Terraform provider is **not required**.

Terraform uses the Helm provider only to install the CSI driver.

```hcl
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
```

The service account will be:

```text
Namespace:
kube-system

ServiceAccount:
efs-csi-controller-sa
```

And it will have the IAM role annotation:

```text
eks.amazonaws.com/role-arn
```

---

# 8. Apply Terraform

Run:

```bash
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

---

# 9. Verify EFS CSI Driver

Check the pods:

```bash
kubectl get pods -n kube-system | grep efs
```

You should see EFS CSI controller/node pods.

Check the service account:

```bash
kubectl get serviceaccount \
  efs-csi-controller-sa \
  -n kube-system
```

Check the annotation:

```bash
kubectl describe serviceaccount \
  efs-csi-controller-sa \
  -n kube-system
```

---

# Kubernetes YAML

The following resources are deliberately managed with `kubectl`, not Terraform's Kubernetes provider.

---

# 10. Namespace

Create:

```text
kubernetes/01-namespace.yaml
```

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: efs-demo
```

Apply:

```bash
kubectl apply -f 01-namespace.yaml
```

---

# 11. EFS StorageClass

Create:

```text
kubernetes/02-storageclass.yaml
```

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: efs

provisioner: efs.csi.aws.com

parameters:
  provisioningMode: efs-ap
  fileSystemId: fs-0123456789abcdef
  directoryPerms: "700"

mountOptions:
  - tls
  - iam

reclaimPolicy: Delete
volumeBindingMode: Immediate
```

Replace:

```text
fs-0123456789abcdef
```

with your actual EFS filesystem ID.

Get it using:

```bash
terraform output efs_file_system_id
```

### What happens here?

The important configuration is:

```yaml
provisioningMode: efs-ap
```

This enables dynamic provisioning using EFS Access Points.

The flow is:

```text
PVC
 |
 ↓
StorageClass
 |
 ↓
EFS CSI Driver
 |
 ↓
EFS Access Point
 |
 ↓
EFS File System
```

---

# 12. PersistentVolumeClaim

Create:

```text
kubernetes/03-pvc.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim

metadata:
  name: efs-pvc
  namespace: efs-demo

spec:
  accessModes:
    - ReadWriteMany

  storageClassName: efs

  resources:
    requests:
      storage: 5Gi
```

Apply:

```bash
kubectl apply -f 03-pvc.yaml
```

Check:

```bash
kubectl get pvc -n efs-demo
```

Expected:

```text
NAME       STATUS   VOLUME
efs-pvc    Bound    pvc-xxxxxxxx
```

---

# 13. Deployment

Create:

```text
kubernetes/04-deployment.yaml
```

```yaml
apiVersion: apps/v1
kind: Deployment

metadata:
  name: nginx
  namespace: efs-demo

spec:
  replicas: 2

  selector:
    matchLabels:
      app: nginx

  template:
    metadata:
      labels:
        app: nginx

    spec:
      containers:
        - name: nginx
          image: nginx:latest

          ports:
            - name: http
              containerPort: 80

          volumeMounts:
            - name: efs-storage
              mountPath: /data

      volumes:
        - name: efs-storage
          persistentVolumeClaim:
            claimName: efs-pvc
```

Apply:

```bash
kubectl apply -f 04-deployment.yaml
```

Check:

```bash
kubectl get pods -n efs-demo
```

Expected:

```text
nginx-xxxxxxxxxx-xxxxx
nginx-xxxxxxxxxx-yyyyy
```

Both pods mount:

```text
/data
```

from the same EFS PVC.

---

# 14. Service

Create:

```text
kubernetes/05-service.yaml
```

```yaml
apiVersion: v1
kind: Service

metadata:
  name: nginx
  namespace: efs-demo

spec:
  type: ClusterIP

  selector:
    app: nginx

  ports:
    - name: http
      port: 80
      targetPort: 80
```

Apply:

```bash
kubectl apply -f 05-service.yaml
```

Check:

```bash
kubectl get svc -n efs-demo
```

---

# 15. Ingress

If you already have the NGINX Ingress Controller installed:

Create:

```text
kubernetes/06-ingress.yaml
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
  name: nginx
  namespace: efs-demo

spec:
  ingressClassName: nginx

  rules:
    - host: efs.example.com

      http:
        paths:
          - path: /
            pathType: Prefix

            backend:
              service:
                name: nginx
                port:
                  number: 80
```

Apply:

```bash
kubectl apply -f 06-ingress.yaml
```

Check:

```bash
kubectl get ingress -n efs-demo
```

---

# 16. Test Shared EFS Storage

This is the most important test.

First get the pods:

```bash
kubectl get pods -n efs-demo -o wide
```

Suppose:

```text
POD-1 = nginx-abc123
POD-2 = nginx-def456
```

Write a file from Pod 1:

```bash
kubectl exec -n efs-demo nginx-abc123 -- \
  sh -c 'echo "Hello from Pod 1" > /data/test.txt'
```

Read the file from Pod 2:

```bash
kubectl exec -n efs-demo nginx-def456 -- \
  cat /data/test.txt
```

Expected:

```text
Hello from Pod 1
```

This proves both pods are accessing the same EFS storage.

---

# EFS vs EBS

| Feature               | EBS CSI | EFS CSI                  |
| --------------------- | ------- | ------------------------ |
| Storage type          | Block   | File                     |
| Scope                 | AZ      | Regional                 |
| Typical access mode   | RWO     | RWX                      |
| Multi-AZ              | No      | Yes                      |
| Multiple pods         | Limited | Yes                      |
| NFS                   | No      | Yes                      |
| Access Points         | No      | Yes                      |
| Shared filesystem     | No      | Yes                      |
| Good for databases    | Yes     | Usually not first choice |
| Good for shared files | No      | Yes                      |

---

# EFS Access Point

With:

```yaml
provisioningMode: efs-ap
```

the EFS CSI driver dynamically creates an Access Point.

Conceptually:

```text
Kubernetes PVC
      |
      ↓
EFS CSI Driver
      |
      ↓
EFS Access Point
      |
      ↓
EFS File System
```

An Access Point provides an application-specific entry point into the EFS filesystem.

---

# Why ReadWriteMany?

The PVC uses:

```yaml
accessModes:
  - ReadWriteMany
```

This allows multiple pods to mount the same storage.

For example:

```text
             EFS
              |
       +------+------+
       |      |      |
     Pod-1  Pod-2  Pod-3
       |      |      |
       +------+------+
              |
            /data
```

This is one of the primary use cases for EFS.

---

# Important Difference: EBS vs EFS

### EBS

```text
Pod
 |
 ↓
EBS Volume
 |
 ↓
Usually one AZ
```

EBS is block storage and is generally used with `ReadWriteOnce`.

### EFS

```text
Pod-1 ──┐
Pod-2 ──┼──→ EFS
Pod-3 ──┘
```

EFS is a regional network filesystem and supports `ReadWriteMany`.

---

# Troubleshooting

## PVC stuck in Pending

Check:

```bash
kubectl describe pvc efs-pvc -n efs-demo
```

Check CSI driver:

```bash
kubectl get pods -n kube-system | grep efs
```

Check StorageClass:

```bash
kubectl describe storageclass efs
```

---

## Pod stuck in ContainerCreating

Check:

```bash
kubectl describe pod <pod-name> -n efs-demo
```

Look for:

```text
MountVolume
FailedMount
NFS
AccessDenied
Connection timeout
```

---

## Check EFS mount targets

AWS CLI:

```bash
aws efs describe-mount-targets \
  --file-system-id <EFS-ID>
```

You should have mount targets in the AZs where your EKS nodes run.

---

## Check security group

EFS requires:

```text
TCP 2049
```

Make sure the EFS security group allows traffic from your EKS node/pod security group.

---

## Check EFS CSI driver

```bash
kubectl get pods -n kube-system | grep efs
```

Check controller logs:

```bash
kubectl logs \
  -n kube-system \
  -l app.kubernetes.io/name=aws-efs-csi-driver \
  --all-containers
```

---

# Cleanup

Delete Kubernetes resources:

```bash
kubectl delete -f 06-ingress.yaml
kubectl delete -f 05-service.yaml
kubectl delete -f 04-deployment.yaml
kubectl delete -f 03-pvc.yaml
kubectl delete -f 02-storageclass.yaml
kubectl delete -f 01-namespace.yaml
```

Then destroy Terraform infrastructure:

```bash
terraform destroy
```

---

# Final Architecture

```text
                         AWS
                          |
                 +--------+--------+
                 |                 |
                EKS               EFS
                 |                 |
          EFS CSI Driver      Mount Targets
                 |              AZ-A / AZ-B
                 |
                IRSA
                 |
             IAM Role
                 |
      AmazonEFSCSIDriverPolicy
                 |
                 ↓
          StorageClass
                 |
          provisioningMode
              efs-ap
                 |
                 ↓
               PVC
                 |
          ReadWriteMany
                 |
          +------+------+
          |             |
        Pod-1         Pod-2
          |             |
          +------+------+
                 |
                /data
                 |
                 ↓
                EFS
```

---

# Key Interview Explanation

If asked:

**"How do you integrate EFS with EKS?"**

Answer:

> "I create an encrypted regional EFS filesystem with mount targets in the Availability Zones where my EKS nodes run. I configure the EFS security group to allow NFS traffic on TCP 2049. I install the AWS EFS CSI driver using Helm and provide its controller service account with AWS permissions through IRSA. Then I create an EFS StorageClass using the `efs.csi.aws.com` provisioner and `efs-ap` dynamic provisioning. A Kubernetes PVC requests `ReadWriteMany`, and the CSI driver dynamically creates an EFS Access Point. Multiple pods running on different nodes or Availability Zones can then mount the same EFS storage."

---

# Key Commands

```bash
# Terraform
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply

# EFS ID
terraform output efs_file_system_id

# Kubernetes
kubectl get pods -n kube-system | grep efs
kubectl get storageclass
kubectl get pvc -n efs-demo
kubectl get pods -n efs-demo
kubectl get svc -n efs-demo
kubectl get ingress -n efs-demo

# Troubleshooting
kubectl describe pvc efs-pvc -n efs-demo
kubectl describe pod <pod-name> -n efs-demo

# Cleanup
kubectl delete -f kubernetes/
terraform destroy
```

---

## Summary

This implementation separates responsibilities cleanly:

```text
Terraform
    |
    +-- AWS EFS
    +-- EFS Mount Targets
    +-- EFS Security Group
    +-- IAM / IRSA
    +-- EFS CSI Driver via Helm

kubectl / YAML
    |
    +-- Namespace
    +-- StorageClass
    +-- PVC
    +-- Deployment
    +-- Service
    +-- Ingress
```

There is **no Kubernetes Terraform provider** in this design.
