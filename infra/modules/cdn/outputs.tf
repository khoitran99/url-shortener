output "cloudfront_domain"   { value = aws_cloudfront_distribution.web.domain_name }
output "cloudfront_id"       { value = aws_cloudfront_distribution.web.id }
output "s3_bucket_name"      { value = aws_s3_bucket.web.bucket }
output "web_url"             { value = "https://${var.domain}" }
