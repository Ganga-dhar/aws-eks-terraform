#Get EKS OIDC URL
##Your EKS cluster exposes an OIDC issuer such as:

##https://oidc.eks.us-east-1.amazonaws.com/id/XXXXXXXX

##Terraform retrieves the TLS certificate chain from that endpoint.



data "tls_certificate" "eks" {
  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}


##Create IAM OIDC provider
##"Trust tokens issued by this EKS OIDC provider."
##client_id_list = ["sts.amazonaws.com"]

##means the OIDC token's audience is expected to be:
##sts.amazonaws.com
##That's important because the pod eventually calls:sts:AssumeRoleWithWebIdentity

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]

  thumbprint_list = [
    data.tls_certificate.eks.certificates[0].sha1_fingerprint
  ]

  url = aws_eks_cluster.eks.identity[0].oidc[0].issuer
}


##3. Why the certificate fingerprint?
##This establishes trust in the OIDC provider's TLS certificate.


##4. Then you create an IAM role for the ServiceAccount

##For example:

##resource "aws_iam_role" "app" {
  ##name = "eks-app-role"

  ##assume_role_policy = jsonencode({
    ##Version = "2012-10-17"
    ##Statement = [{
      ##Effect = "Allow"
      ##Principal = {
        ##Federated = aws_iam_openid_connect_provider.eks.arn
      ##}
      ##Action = "sts:AssumeRoleWithWebIdentity"

      ##Condition = {
        ##StringEquals = {
          ##"oidc.eks.us-east-1.amazonaws.com/id/XXXX:sub" = "system:serviceaccount:default:my-app"
          ##"oidc.eks.us-east-1.amazonaws.com/id/XXXX:aud" = "sts.amazonaws.com"
        ##}
      ##}
    ##}]
  ##})
##}

##Then:

##apiVersion: v1
##kind: ServiceAccount
##metadata:
  ##name: my-app
  ##annotations:
    ##eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eks-app-role

##Now the pod can obtain temporary AWS credentials without storing an AWS access key inside the container.