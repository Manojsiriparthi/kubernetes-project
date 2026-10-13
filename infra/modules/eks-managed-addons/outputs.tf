output "role_arns" {
  value = {
    vpc_cni    = aws_iam_role.vpc_cni.arn
    ebs_csi    = aws_iam_role.ebs_csi.arn
    cloudwatch = aws_iam_role.cloudwatch.arn
  }
}
