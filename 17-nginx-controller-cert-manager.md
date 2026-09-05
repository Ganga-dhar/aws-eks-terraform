# EKS NGINX Ingress Controller + cert-manager + Let's Encrypt HTTP-01

This example demonstrates how to expose an application running on **Amazon EKS** using:

* Kubernetes Namespace
* NGINX Ingress Controller
* AWS Network Load Balancer (NLB)
* Kubernetes Deployment
* Kubernetes ClusterIP Service
* Kubernetes Ingress
* cert-manager
* Let's Encrypt
* HTTP-01 ACME challenge
* HTTPS/TLS certificate

---

## Architecture

```text
                         Internet
                            |
                            | HTTPS / HTTP
                            v
                    +----------------+
                    |   AWS NLB      |
                    | Network LB     |
                    +----------------+
                            |
                            v
                +-------------------------+
                | NGINX Ingress Controller|
                +-------------------------+
                            |
                            v
                    Kubernetes Ingress
                            |
                            v
                    ClusterIP Service
                            |
                    +-------+-------+
                    |               |
                    v               v
                 Pod 1            Pod 2
                 nginx            nginx
```

Certificate flow:

```text
                    cert-manager
                         |
                         |
                         v
                  Let's Encrypt
                         |
                    HTTP-01
                    Challenge
                         |
                         v
       /.well-known/acme-challenge/<TOKEN>
                         |
                         v
                 NGINX Ingress
                         |
                         v
                       EKS
```

---

# 1. Prerequisites

Make sure the following tools are installed:

```bash
aws --version
kubectl version --client
helm version
terraform version
```

You also need:

* An existing EKS cluster
* AWS CLI configured
* kubectl configured for the EKS cluster
* Helm installed
* A publicly resolvable domain
* DNS pointing the domain to the NGINX AWS Load Balancer

---

# 2. Configure kubectl

Update your kubeconfig:

```bash
aws eks update-kubeconfig \
  --region ap-south-1 \
  --name my-eks-cluster
```

Verify:

```bash
kubectl get nodes
```

Example:

```text
NAME                                         STATUS   ROLES
ip-10-0-1-10.ap-south-1.compute.internal    Ready    <none>
ip-10-0-2-20.ap-south-1.compute.internal    Ready    <none>
```

---

# 3. Install NGINX Ingress Controller

Add the Helm repository:

```bash
helm repo add ingress-nginx \
  https://kubernetes.github.io/ingress-nginx

helm repo update
```

Install NGINX:

```bash
helm install ingress-nginx \
  ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --set controller.service.type=LoadBalancer \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/aws-load-balancer-type"="nlb"
```

Verify:

```bash
kubectl get pods -n ingress-nginx
```

Check the Service:

```bash
kubectl get svc -n ingress-nginx
```

Example:

```text
NAME                       TYPE           EXTERNAL-IP
ingress-nginx-controller   LoadBalancer   xxxxx.elb.amazonaws.com
```

The AWS Load Balancer provides the external entry point to the NGINX Ingress Controller.

---

# 4. Install cert-manager

cert-manager automatically obtains and renews TLS certificates.

Install:

```bash
helm install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.21.1 \
  --set crds.enabled=true
```

Verify:

```bash
kubectl get pods -n cert-manager
```

Expected:

```text
NAME                                       READY
cert-manager-xxxxxxxxxx                    1/1
cert-manager-cainjector-xxxxxxxxxx         1/1
cert-manager-webhook-xxxxxxxxxx            1/1
```

---

# 5. Create Namespace

Create an application namespace:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: nginx-demo
```

Apply:

```bash
kubectl apply -f namespace.yaml
```

Verify:

```bash
kubectl get namespace nginx-demo
```

---

# 6. Create Application Deployment

We use the standard NGINX image.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-demo
  namespace: nginx-demo

spec:
  replicas: 2

  selector:
    matchLabels:
      app: nginx-demo

  template:
    metadata:
      labels:
        app: nginx-demo

    spec:
      containers:
        - name: nginx
          image: nginx:latest

          ports:
            - containerPort: 80
```

Apply:

```bash
kubectl apply -f deployment.yaml
```

Verify:

```bash
kubectl get pods -n nginx-demo
```

Expected:

```text
NAME                          READY   STATUS
nginx-demo-xxxxxxxxxx         1/1     Running
nginx-demo-yyyyyyyyyy         1/1     Running
```

---

# 7. Create Kubernetes Service

The application Service is a `ClusterIP`.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-demo
  namespace: nginx-demo

spec:
  type: ClusterIP

  selector:
    app: nginx-demo

  ports:
    - port: 80
      targetPort: 80
```

Apply:

```bash
kubectl apply -f service.yaml
```

Verify:

```bash
kubectl get svc -n nginx-demo
```

Example:

```text
NAME          TYPE        CLUSTER-IP
nginx-demo    ClusterIP   10.100.20.10
```

### Why ClusterIP?

We don't expose every application using an AWS Load Balancer.

Instead:

```text
Internet
   |
   v
AWS NLB
   |
   v
NGINX Ingress Controller
   |
   v
ClusterIP Service
   |
   v
Pods
```

This allows multiple applications to share the same NGINX Load Balancer.

---

# 8. Create ClusterIssuer

The `ClusterIssuer` tells cert-manager to use Let's Encrypt.

For production:

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod

spec:
  acme:
    email: your-email@example.com

    server: https://acme-v02.api.letsencrypt.org/directory

    privateKeySecretRef:
      name: letsencrypt-prod

    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
```

Replace:

```text
your-email@example.com
```

with your actual email address.

Apply:

```bash
kubectl apply -f clusterissuer.yaml
```

Verify:

```bash
kubectl get clusterissuer
```

Expected:

```text
NAME               READY
letsencrypt-prod   True
```

---

# 9. DNS Configuration

Suppose your application domain is:

```text
app.example.com
```

First get the NGINX Load Balancer:

```bash
kubectl get svc -n ingress-nginx
```

Example:

```text
NAME                       TYPE
ingress-nginx-controller   LoadBalancer

EXTERNAL-IP:
xxxxx.elb.amazonaws.com
```

Create a DNS record:

```text
app.example.com
        |
        v
xxxxx.elb.amazonaws.com
```

Depending on your DNS provider, this could be a CNAME record or an equivalent DNS configuration.

For Route 53, an Alias record can be used where appropriate.

---

# 10. Create Ingress

Create the following Ingress:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nginx-demo
  namespace: nginx-demo

  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod

spec:
  ingressClassName: nginx

  tls:
    - hosts:
        - app.example.com

      secretName: nginx-demo-tls

  rules:
    - host: app.example.com

      http:
        paths:
          - path: /
            pathType: Prefix

            backend:
              service:
                name: nginx-demo

                port:
                  number: 80
```

Apply:

```bash
kubectl apply -f ingress.yaml
```

---

# 11. How HTTP-01 Works

This is the most important part.

When cert-manager sees:

```yaml
cert-manager.io/cluster-issuer: letsencrypt-prod
```

it requests a certificate from Let's Encrypt.

Let's Encrypt needs to verify that you control:

```text
app.example.com
```

cert-manager creates a temporary HTTP-01 challenge.

The challenge URL looks like:

```text
http://app.example.com/.well-known/acme-challenge/<TOKEN>
```

Let's Encrypt accesses this URL from the internet.

```text
Let's Encrypt
      |
      | HTTP GET
      v
http://app.example.com/.well-known/acme-challenge/TOKEN
      |
      v
    AWS NLB
      |
      v
NGINX Ingress Controller
      |
      v
cert-manager HTTP-01 solver
      |
      v
Expected token
```

If Let's Encrypt receives the correct token:

```text
Domain validation successful
```

Then Let's Encrypt issues the certificate.

---

# 12. HTTP-01 Challenge Example

Suppose cert-manager creates:

```text
TOKEN = abc123
```

Let's Encrypt checks:

```text
http://app.example.com/.well-known/acme-challenge/abc123
```

The HTTP response must contain the expected challenge value.

After successful validation:

```text
HTTP-01 Challenge
        |
        v
Domain Verified
        |
        v
Let's Encrypt
        |
        v
TLS Certificate
```

The certificate is then stored in Kubernetes:

```text
Secret:
nginx-demo-tls
```

---

# 13. Verify Certificate

Check certificates:

```bash
kubectl get certificate -n nginx-demo
```

Expected:

```text
NAME             READY   SECRET
nginx-demo-tls   True    nginx-demo-tls
```

You can inspect it:

```bash
kubectl describe certificate \
  nginx-demo-tls \
  -n nginx-demo
```

---

# 14. Check CertificateRequest

```bash
kubectl get certificaterequest \
  -n nginx-demo
```

Example:

```text
NAME                   READY   ISSUER
nginx-demo-tls-1       True    letsencrypt-prod
```

---

# 15. Check ACME Challenge

During certificate issuance:

```bash
kubectl get challenge \
  -n nginx-demo
```

Example:

```text
NAME                         STATE
nginx-demo-tls-xxxxx         valid
```

You can inspect it:

```bash
kubectl describe challenge \
  -n nginx-demo
```

---

# 16. Check Certificate Secret

```bash
kubectl get secret nginx-demo-tls \
  -n nginx-demo
```

Expected:

```text
NAME             TYPE                DATA
nginx-demo-tls   kubernetes.io/tls   2
```

The Secret contains:

```text
tls.crt
tls.key
```

---

# 17. Test HTTPS

Once the certificate is ready:

```bash
curl -I https://app.example.com
```

Expected:

```text
HTTP/2 200
```

You can also open:

```text
https://app.example.com
```

in a browser.

The browser should show a valid Let's Encrypt certificate.

---

# 18. Complete Request Flow

Normal HTTPS request:

```text
User
 |
 | HTTPS
 v
app.example.com
 |
 | DNS
 v
AWS NLB
 |
 v
NGINX Ingress Controller
 |
 | Host: app.example.com
 | Path: /
 v
Kubernetes Ingress
 |
 v
nginx-demo Service
 |
 v
NGINX Pod
```

Certificate request:

```text
Ingress
   |
   | cert-manager annotation
   v
cert-manager
   |
   | ACME request
   v
Let's Encrypt
   |
   | HTTP-01 challenge
   v
app.example.com
   |
   v
AWS NLB
   |
   v
NGINX Ingress
   |
   v
HTTP-01 Solver
   |
   v
Challenge validated
   |
   v
Certificate issued
   |
   v
Kubernetes TLS Secret
   |
   v
nginx-demo-tls
```

---

# 19. HTTP-01 vs DNS-01

| Feature              | HTTP-01             | DNS-01                            |
| -------------------- | ------------------- | --------------------------------- |
| Validation method    | HTTP request        | DNS TXT record                    |
| Port                 | 80                  | DNS                               |
| Public endpoint      | Required            | Not required for the HTTP service |
| Wildcard certificate | No                  | Yes                               |
| Example              | `app.example.com`   | `*.example.com`                   |
| NGINX integration    | Easy                | Not required                      |
| Common use           | Public applications | Wildcard/private DNS scenarios    |

### HTTP-01

```text
Let's Encrypt
      |
      v
http://app.example.com/.well-known/acme-challenge/...
      |
      v
NGINX
```

### DNS-01

```text
cert-manager
      |
      v
DNS Provider / Route 53
      |
      v
_acme-challenge.example.com
      |
      | TXT
      v
Let's Encrypt
```

---

# 20. Important HTTP-01 Requirements

For HTTP-01 to work:

### 1. Domain must resolve correctly

```text
app.example.com
       |
       v
AWS NLB
```

### 2. Port 80 must be reachable

Let's Encrypt needs to access:

```text
http://app.example.com/.well-known/acme-challenge/...
```

Therefore, don't block the HTTP challenge path with security rules.

### 3. NGINX Ingress must be running

```bash
kubectl get pods -n ingress-nginx
```

### 4. cert-manager must be healthy

```bash
kubectl get pods -n cert-manager
```

### 5. ClusterIssuer must be ready

```bash
kubectl get clusterissuer
```

Expected:

```text
letsencrypt-prod   True
```

---

# 21. Troubleshooting

## Check Ingress

```bash
kubectl describe ingress nginx-demo \
  -n nginx-demo
```

---

## Check Certificate

```bash
kubectl describe certificate nginx-demo-tls \
  -n nginx-demo
```

---

## Check CertificateRequest

```bash
kubectl describe certificaterequest \
  -n nginx-demo
```

---

## Check Challenge

```bash
kubectl describe challenge \
  -n nginx-demo
```

---

## Check cert-manager logs

```bash
kubectl logs \
  -n cert-manager \
  deployment/cert-manager
```

---

## Check NGINX logs

```bash
kubectl logs \
  -n ingress-nginx \
  deployment/ingress-nginx-controller
```

---

# 22. Kubernetes Resources

The final resources are:

```text
Namespace
   |
   +-- Deployment
   |      |
   |      +-- Pod
   |      +-- Pod
   |
   +-- Service
   |      |
   |      +-- ClusterIP
   |
   +-- Ingress
          |
          +-- TLS Secret
```

Cluster-level resources:

```text
NGINX Ingress Controller
        |
        +-- AWS NLB

cert-manager
        |
        +-- ClusterIssuer
        |
        +-- Certificate
        |
        +-- CertificateRequest
        |
        +-- Challenge
```

---

# 23. File Structure

A simple project can be organized as:

```text
nginx-cert-manager/
│
├── namespace.yaml
├── deployment.yaml
├── service.yaml
├── clusterissuer.yaml
└── ingress.yaml
```

Apply:

```bash
kubectl apply -f namespace.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml
kubectl apply -f clusterissuer.yaml
kubectl apply -f ingress.yaml
```

Or:

```bash
kubectl apply -f .
```

---

# 24. Key Interview Explanation

A concise interview answer:

> NGINX Ingress Controller provides HTTP/HTTPS routing into the Kubernetes cluster. Its Service is exposed through an AWS Load Balancer, while application Services normally remain ClusterIP.
>
> cert-manager manages TLS certificates. We configure a Let's Encrypt ClusterIssuer with the ACME HTTP-01 solver. When an Ingress requests a certificate, cert-manager creates a temporary challenge endpoint under `/.well-known/acme-challenge/`. Let's Encrypt accesses that endpoint through the AWS Load Balancer and NGINX Ingress. Once the challenge succeeds, Let's Encrypt issues the certificate and cert-manager stores it as a Kubernetes TLS Secret. cert-manager also handles certificate renewal automatically.

---

# 25. Important Production Note

For a new production EKS platform, evaluate the current lifecycle/status of the ingress-nginx project before adopting it. AWS-native alternatives include:

```text
AWS Load Balancer Controller
        +
ALB
        +
ACM
```

or a Gateway API-based architecture.

For learning HTTP-01 and cert-manager, however, the NGINX Ingress example above is a useful end-to-end setup.
