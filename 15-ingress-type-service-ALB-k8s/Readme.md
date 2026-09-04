# EKS Networking: LoadBalancer Service vs Ingress

## Overview

In Amazon EKS, there are two common approaches for exposing applications outside the Kubernetes cluster:

1. **Kubernetes Service with `type: LoadBalancer`**
2. **Kubernetes Ingress with AWS Load Balancer Controller**

The main difference is:

> **`Service type: LoadBalancer` exposes a Kubernetes Service externally, normally using an AWS NLB.**
>
> **Ingress provides Layer 7 HTTP/HTTPS routing and, with AWS Load Balancer Controller, normally creates an AWS ALB.**

---

# 1. Service Type: LoadBalancer

A Kubernetes Service with:

```yaml
spec:
  type: LoadBalancer
```

is used when we want to expose a particular Kubernetes Service outside the cluster.

With the **AWS Load Balancer Controller**, the typical AWS implementation is an **NLB (Network Load Balancer)**.

## Architecture

```text
                    Internet
                       |
                       v
                +-------------+
                | AWS NLB     |
                | Layer 4     |
                +-------------+
                       |
                 Target Group
                       |
              +--------+--------+
              |        |        |
              v        v        v
            Pod      Pod      Pod
           :8080    :8080    :8080
```

Traffic flow:

```text
Client
  |
  v
AWS NLB
  |
  v
Target Group
  |
  v
Pod IP
  |
  v
Application Container
```

---

# 2. Service LoadBalancer Example

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
  namespace: default

  annotations:
    # Use AWS Load Balancer Controller
    service.beta.kubernetes.io/aws-load-balancer-type: "external"

    # Register Pod IPs directly
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"

    # Internet-facing NLB
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"

spec:
  type: LoadBalancer

  selector:
    app: my-app

  ports:
    - name: http
      port: 80
      targetPort: 8080
```

Application Deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app

spec:
  replicas: 3

  selector:
    matchLabels:
      app: my-app

  template:
    metadata:
      labels:
        app: my-app

    spec:
      containers:
        - name: my-app
          image: nginx:1.27

          ports:
            - containerPort: 8080
```

---

# 3. What Happens in AWS?

When Kubernetes sees:

```yaml
type: LoadBalancer
```

the AWS Load Balancer Controller watches the Service.

It creates AWS resources such as:

```text
Kubernetes Service
       |
       v
AWS Load Balancer Controller
       |
       v
AWS NLB
       |
       v
Target Group
       |
       v
Pod IPs
```

With:

```yaml
service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: "ip"
```

the Pod IPs are registered directly in the NLB target group.

This is generally preferred when using the AWS Load Balancer Controller because traffic does not need to first land on a worker node.

---

# 4. When Should We Use Service type LoadBalancer?

Use it when:

* You need to expose a single application/service.
* You need Layer 4 networking.
* You need TCP/UDP traffic.
* You want an AWS NLB.
* You don't need host/path-based HTTP routing.

Example:

```text
Internet
   |
   v
NLB
   |
   +----> payment-service
   |
   +----> database-service
```

However, creating a separate LoadBalancer Service for every application can become expensive and difficult to manage.

---

# 5. Can Service type LoadBalancer Create an ALB?

### Normally, with AWS Load Balancer Controller: No.

The typical mapping is:

```text
Service type: LoadBalancer
            |
            v
           NLB
```

and:

```text
Ingress
   |
   v
  ALB
```

If the requirement is:

* HTTP/HTTPS
* Host-based routing
* Path-based routing
* Centralized TLS termination
* Multiple applications behind one load balancer

then **Ingress + AWS Load Balancer Controller** is normally the better approach.

---

# 6. Kubernetes Ingress

Ingress is a Kubernetes API resource that defines HTTP/HTTPS routing rules.

For example:

```text
app.example.com
       |
       v
      ALB
       |
       +---- /        ---> frontend-service
       |
       +---- /api     ---> backend-service
       |
       +---- /payment ---> payment-service
```

Ingress itself is **not the load balancer**.

An **Ingress Controller** implements the Ingress rules.

In AWS EKS, the **AWS Load Balancer Controller** can implement the Ingress by creating and configuring an AWS ALB.

---

# 7. Ingress Example

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app

  annotations:
    # Create an internet-facing ALB
    alb.ingress.kubernetes.io/scheme: internet-facing

    # Register Pod IPs directly
    alb.ingress.kubernetes.io/target-type: ip

spec:
  ingressClassName: alb

  rules:
    - host: app.example.com

      http:
        paths:

          # Frontend
          - path: /
            pathType: Prefix

            backend:
              service:
                name: frontend-service
                port:
                  number: 80

          # Backend API
          - path: /api
            pathType: Prefix

            backend:
              service:
                name: backend-service
                port:
                  number: 80
```

---

# 8. AWS Architecture for Ingress

```text
                         Internet
                            |
                            v
                    +---------------+
                    |   AWS ALB     |
                    |   Layer 7     |
                    +---------------+
                            |
                   Listener :80/:443
                            |
                    ALB Routing Rules
                       /          \
                      /            \
                     v              v
              /api                  /
                |                    |
                v                    v
        backend-service       frontend-service
                |                    |
                v                    v
              Pods                 Pods
```

The AWS Load Balancer Controller watches the Ingress resource:

```text
Kubernetes Ingress
        |
        v
AWS Load Balancer Controller
        |
        v
AWS ALB
        |
        v
ALB Listener
        |
        v
ALB Rules
        |
        v
Target Groups
        |
        v
Pod IPs
```

---

# 9. ALB vs NLB

| Feature                                   | ALB                  | NLB                                  |
| ----------------------------------------- | -------------------- | ------------------------------------ |
| AWS Layer                                 | Layer 7              | Layer 4                              |
| Kubernetes resource                       | Ingress              | Service                              |
| Typical EKS implementation                | Ingress              | Service `LoadBalancer`               |
| HTTP                                      | Yes                  | Yes                                  |
| HTTPS                                     | Yes                  | TLS pass-through/termination options |
| TCP                                       | No                   | Yes                                  |
| UDP                                       | No                   | Yes                                  |
| Host-based routing                        | Yes                  | No                                   |
| Path-based routing                        | Yes                  | No                                   |
| HTTP headers                              | Yes                  | No                                   |
| URL routing                               | Yes                  | No                                   |
| Very high connection/throughput workloads | Good                 | Excellent                            |
| Typical use case                          | Web applications/API | TCP/UDP/high-performance networking  |

---

# 10. Host-Based Routing

ALB supports host-based routing.

Example:

```text
api.example.com
      |
      v
     ALB
      |
      +----> backend-service


app.example.com
      |
      v
     ALB
      |
      +----> frontend-service
```

Example Ingress:

```yaml
rules:

  - host: api.example.com
    http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: backend-service
              port:
                number: 80

  - host: app.example.com
    http:
      paths:
        - path: /
          pathType: Prefix
          backend:
            service:
              name: frontend-service
              port:
                number: 80
```

One ALB can therefore serve multiple applications.

---

# 11. Path-Based Routing

ALB can also route based on URL paths.

Example:

```text
https://example.com/
        |
        +----> frontend-service


https://example.com/api
        |
        +----> backend-service


https://example.com/payment
        |
        +----> payment-service
```

Ingress:

```yaml
rules:
  - host: example.com

    http:
      paths:

        - path: /
          pathType: Prefix
          backend:
            service:
              name: frontend-service
            port:
              number: 80

        - path: /api
          pathType: Prefix
          backend:
            service:
              name: backend-service
            port:
              number: 80

        - path: /payment
          pathType: Prefix
          backend:
            service:
              name: payment-service
            port:
              number: 80
```

---

# 12. TLS / HTTPS with ALB

Ingress can also be used for HTTPS.

Example:

```yaml
metadata:
  annotations:

    alb.ingress.kubernetes.io/scheme: internet-facing

    alb.ingress.kubernetes.io/target-type: ip

    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'

    alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:region:account-id:certificate/example
```

Architecture:

```text
Client
  |
 HTTPS :443
  |
  v
AWS ALB
  |
  +---- TLS termination
  |
  v
Target Group
  |
  v
Pods
```

The certificate can be managed through **AWS Certificate Manager (ACM)**.

---

# 13. `target-type: ip` vs `instance`

This is an important AWS Load Balancer Controller concept.

## IP Target

```yaml
alb.ingress.kubernetes.io/target-type: ip
```

Traffic:

```text
ALB
 |
 +----> Pod IP
 |
 +----> Pod IP
 |
 +----> Pod IP
```

The Pods are registered directly as targets.

Advantages:

* Direct traffic to Pods
* Better integration with Kubernetes
* No additional node-level hop
* Works well with EKS networking

---

## Instance Target

With instance targets:

```text
ALB
 |
 v
EC2 Worker Node
 |
 v
Kubernetes Service
 |
 v
Pod
```

Traffic has an additional node/service forwarding layer.

Conceptually:

```text
ALB
 |
 v
Worker Node
 |
 v
Service
 |
 v
Pod
```

---

# 14. Comparison: LoadBalancer Service vs Ingress

| Area              | Service `LoadBalancer`          | Ingress                            |
| ----------------- | ------------------------------- | ---------------------------------- |
| Kubernetes object | Service                         | Ingress                            |
| AWS LB            | Usually NLB                     | Usually ALB                        |
| OSI layer         | L4                              | L7                                 |
| HTTP routing      | Limited                         | Yes                                |
| Host routing      | No                              | Yes                                |
| Path routing      | No                              | Yes                                |
| TCP               | Yes                             | No                                 |
| UDP               | Yes                             | No                                 |
| TLS termination   | Possible                        | Yes                                |
| Multiple apps     | Usually separate LB per Service | One ALB can route to many Services |
| Cost efficiency   | Can require many LBs            | Better for many HTTP apps          |
| Best for          | TCP/UDP/direct service exposure | Web/API applications               |

---

# 15. Approach 1 — One NLB Per Application

Example:

```text
                    Internet
                       |
        +--------------+--------------+
        |              |              |
        v              v              v
      NLB-1          NLB-2          NLB-3
        |              |              |
        v              v              v
   frontend        backend        payment
```

Kubernetes:

```text
Service A
type: LoadBalancer
      |
      +---- NLB

Service B
type: LoadBalancer
      |
      +---- NLB

Service C
type: LoadBalancer
      |
      +---- NLB
```

### Advantages

* Simple
* Independent applications
* Good for TCP/UDP
* Easy isolation

### Disadvantages

* More AWS Load Balancers
* Higher cost
* More DNS management
* Not ideal for many HTTP applications

---

# 16. Approach 2 — Shared ALB Using Ingress

Recommended for multiple HTTP/HTTPS applications.

```text
                       Internet
                           |
                           v
                    +-------------+
                    |    ALB      |
                    +-------------+
                           |
                 +---------+---------+
                 |         |         |
                 v         v         v
              Frontend   Backend   Payment
               Service   Service    Service
                  |         |         |
                  v         v         v
                 Pods      Pods      Pods
```

For example:

```text
app.example.com
       |
       +----> frontend


api.example.com
       |
       +----> backend


payment.example.com
       |
       +----> payment
```

### Advantages

* One ALB can serve many applications
* Host/path routing
* Centralized HTTPS
* ACM integration
* Better cost efficiency for HTTP workloads

### Disadvantages

* More complex routing configuration
* ALB is primarily for HTTP/HTTPS
* Applications share the ALB infrastructure

---

# 17. Recommended Architecture for a Real EKS Platform

For a typical microservices EKS platform:

```text
                         Internet
                            |
                            v
                     Route 53 DNS
                            |
                            v
                    +---------------+
                    |   AWS ALB     |
                    +---------------+
                            |
                  AWS Load Balancer
                      Controller
                            |
          +-----------------+------------------+
          |                 |                  |
          v                 v                  v
      frontend           backend           payment
      service             service           service
          |                 |                  |
          v                 v                  v
        Pods              Pods               Pods
```

Use:

```text
Ingress
  |
  +---- ALB
```

for HTTP/HTTPS applications.

Use:

```text
Service type: LoadBalancer
  |
  +---- NLB
```

for applications requiring direct Layer 4 exposure.

---

# 18. Simple Decision Tree

```text
Do I need to expose a Kubernetes application?
                |
                v
             Yes
                |
                v
       Is it HTTP/HTTPS?
          /          \
        Yes           No
         |             |
         v             v
   Need routing?     TCP/UDP?
     /     \          |
   Yes      No        v
    |        |       NLB
    v        v
 Ingress   Service
    |      LoadBalancer
    v        |
   ALB       NLB
```

---

# 19. Interview Answer

### Question:

**What is the difference between Service type LoadBalancer and Ingress in EKS?**

### Answer:

> "`Service type LoadBalancer` exposes a Kubernetes Service externally and, with the AWS Load Balancer Controller, typically provisions an AWS NLB. It is mainly used for Layer 4 traffic such as TCP or UDP.
>
> Ingress is a Kubernetes resource used to define HTTP/HTTPS routing rules such as host-based and path-based routing. The AWS Load Balancer Controller implements the Ingress by provisioning an AWS ALB.
>
> So, for a single service or TCP workload I would use a LoadBalancer Service/NLB. For multiple HTTP/HTTPS microservices where I need centralized routing and TLS termination, I would use Ingress/ALB."

---

# 20. Important Interview Point

Remember this mapping:

```text
Kubernetes Service
type: LoadBalancer
        |
        v
AWS Load Balancer Controller
        |
        v
       NLB
```

Whereas:

```text
Kubernetes Ingress
        |
        v
AWS Load Balancer Controller
        |
        v
       ALB
```

And:

```text
Ingress ≠ ALB
```

Ingress is the **Kubernetes routing configuration**.

The **Ingress Controller** implements that configuration.

The **AWS ALB** is the actual AWS load balancer.

---

# 21. Final Summary

```text
                    EKS EXTERNAL ACCESS
                           |
              +------------+------------+
              |                         |
              v                         v
       Service LoadBalancer          Ingress
              |                         |
              v                         v
             NLB                       ALB
              |                         |
          Layer 4                    Layer 7
              |                         |
       TCP / UDP / TLS         HTTP / HTTPS
                                      |
                              Host / Path Routing
```

### Use NLB when:

```text
Service type: LoadBalancer
```

and you need:

* TCP
* UDP
* Layer 4
* Direct service exposure
* High-performance network traffic

### Use ALB when:

```text
Ingress + AWS Load Balancer Controller
```

and you need:

* HTTP/HTTPS
* Host-based routing
* Path-based routing
* TLS termination
* Multiple applications behind one load balancer

### Best practical rule

> **NLB for Layer 4 service exposure; ALB + Ingress for Layer 7 HTTP/HTTPS routing.**
