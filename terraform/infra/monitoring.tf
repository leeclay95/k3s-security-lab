resource "aws_sns_topic" "security_alerts" {
  name              = "webapp-security-alerts"
  kms_master_key_id = aws_kms_key.secrets.id
  tags              = { project = "webapp-lab" }
}

resource "aws_cloudwatch_log_group" "k8s_audit" {
  name              = "/k8s/webapp/audit"
  retention_in_days = 30
  tags              = { project = "webapp-lab" }
}

resource "aws_cloudwatch_log_group" "k8s_app" {
  name              = "/k8s/webapp/app"
  retention_in_days = 14
  tags              = { project = "webapp-lab" }
}

# PutMetricFilter is not supported in LocalStack community edition.
# In production this would count "FailedCreate" lines from Gatekeeper events
# and feed the alarm below. Omitted here; the alarm is wired to the SNS topic
# to prove the notification path even without a real metric source.

# Alert fires when a custom GatekeeperDenials metric exceeds threshold.
# In production this is populated by the log metric filter above.
resource "aws_cloudwatch_metric_alarm" "gatekeeper_violations" {
  alarm_name          = "gatekeeper-policy-violations"
  alarm_description   = "Fires when Gatekeeper blocks an admission request in the webapp namespace"
  namespace           = "K8s/Security"
  metric_name         = "GatekeeperDenials"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]

  tags = { project = "webapp-lab" }
}
