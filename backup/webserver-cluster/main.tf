locals {
  ssh_port = 22
  http_port = 80
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  http_protocol = "HTTP"
  https_protocol = "HTTPS"
  all_ips = ["0.0.0.0/0"]
  home_cidr = "125.177.68.23/32"
  work_cidr = "211.206.114.80/32"
}

data "aws_vpc" "default" {
  #default = true
  tags = {
    Name = "${var.cluster_name}-vpc"
  }
}

# TAG NAME 으로 subnet 을 가져온다.
data "aws_subnets" "default" {
  #vpc_id = data.aws_vpc.default.id ## deprecated option
  filter {
    name = "tag:Name"
    values = ["${var.cluster_name}-sb-public-*"]
  }
  filter {
    name = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group_rule" "service_in" {
  type = "ingress"
  from_port = var.server_port
  to_port = var.server_port
  protocol = "tcp"
  cidr_blocks = local.all_ips
  security_group_id = aws_security_group.instance.id
}

resource "aws_security_group_rule" "service_out" {
  type = "egress"
  from_port = 0
  to_port = 0
  protocol = local.any_protocol
  cidr_blocks = local.all_ips
  security_group_id = aws_security_group.instance.id
}

resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-sg-instance"
  vpc_id = data.aws_vpc.default.id
}

resource "aws_security_group_rule" "ssh" {
  type = "ingress"

  from_port = local.ssh_port
  to_port = local.ssh_port
  protocol = local.tcp_protocol
  cidr_blocks = [local.work_cidr, local.home_cidr] 

  security_group_id = aws_security_group.instance.id
}

data "aws_instances" "example" {
  filter {
    name = "tag:Name"
    values = ["${var.cluster_name}-asg-ex"]
  }
}

# ASG setting
resource "aws_launch_configuration" "example" {
  name = "${var.cluster_name}-launch-config"
  image_id  = "ami-06eea3cd85e2db8ce"
  security_groups = [aws_security_group.instance.id]
  #key_name = "dy-cloud-dev.pem"
  key_name = var.key_pair
	instance_type = var.instance_type
 
  # user_data = <<-EOF
  #             #!/bin/bash
  #             echo "Hello, World" > index.html
  #             nohup busybox httpd -f -p ${var.server_port} &
  #             EOF
  # template file 을 읽어들인 렌더링 결과를 input 으로 받음.
  
  # user_data = data.template_file.user_data.rendered
  user_data = (
    length(data.template_file.user_data[*]) > 0 
      ? data.template_file.user_data[0].rendered
      : data.template_file.user_data_new[0].rendered
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  name = "${var.cluster_name}-asg-ex"
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier = data.aws_subnets.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key = "Name"
    value = "${var.cluster_name}-asg-ex"
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = var.custom_tags
    content {
      key = tag.key
      value = tag.value
      propagate_at_launch = true
    }
  }
}

resource "aws_autoscaling_schedule" "scale_out_during_business_hours" {
  count = var.enable_autoscaling ? 1 : 0

  scheduled_action_name = "scale-out-during-business-hours"
  min_size = 2
  max_size = 10
  desired_capacity = 5
  recurrence = "0 9 * * *"

  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_autoscaling_schedule" "scale_in_at_night" {
  count = var.enable_autoscaling ? 1 : 0

  scheduled_action_name = "scale-in-at-night"
  min_size = 2
  max_size = 10
  desired_capacity = 2
  recurrence = "0 17 * * *"

  autoscaling_group_name = aws_autoscaling_group.example.name
}

resource "aws_security_group" "alb" {
  vpc_id = data.aws_vpc.default.id
  name = "${var.cluster_name}-alb" # name = "dy-tf-alb"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type = "ingress"

  from_port = local.http_port
  to_port = local.http_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips

  security_group_id = aws_security_group.alb.id
}

resource "aws_security_group_rule" "allow_http_outbound" {
  type = "egress"

  from_port = 0
  to_port = 0
  protocol = local.any_protocol
  cidr_blocks = local.all_ips

  security_group_id = aws_security_group.alb.id
}

# ALB setting
resource "aws_lb" "example" {
  name = "${var.cluster_name}-lb"
  load_balancer_type = "application"
  subnets = data.aws_subnets.default.ids

  security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port = local.http_port
  protocol = local.http_protocol

  # default return is 404 page error 
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code = 404
    }
  }
}

resource "aws_lb_listener_rule" "asg" {
  listener_arn = aws_lb_listener.http.arn
  priority = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type = "forward"
    target_group_arn = aws_lb_target_group.asg.arn
  }
}

resource "aws_lb_target_group" "asg" {
  name = "${var.cluster_name}-asg"
  port = var.server_port
  protocol = local.http_protocol
  vpc_id = data.aws_vpc.default.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 30
    timeout = 30
    healthy_threshold = 2
    unhealthy_threshold = 10
  }
}

resource "aws_cloudwatch_metric_alarm" "high_cpu_utilization" {
  alarm_name = "${var.cluster_name}-high-cpu-utilization"
  namespace = "AWS/EC2"
  metric_name = "CPUUtilization"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods = 1
  period = 300 # second, 5 min
  statistic = "Average"
  threshold = 90 
  unit = "Percent"
}

resource "aws_cloudwatch_metric_alarm" "low_cpu_credit_balance" {
  count = format("%.1s", var.instance_type) == "t" ? 1 : 0  # instance type 이 t 시리즈들만 CPU credit 이 있기 때문에 필터링함.

  alarm_name = "${var.cluster_name}-low-cpu-credit-balance"
  namespace = "AWS/EC2"
  metric_name = "CPUCreditBalance"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.example.name
  }

  comparison_operator = "LessThanThreshold"
  evaluation_periods = 1
  period = 300 # second, 5 min
  statistic = "Minimum"
  threshold = 10 
  unit = "Count" 
}

# db 관련 정보 불러오기 데이터소스.
data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket #bucket = "dy-tf-state"
    key = var.db_remote_state_key       #key = "stage/data-stores/mysql/terraform.tfstate"
    region = "ap-northeast-2"
  }
}

# server port 및 db 관련 정보 쉘 파일로 전달.
data "template_file" "user_data" {
  count = var.enable_new_user_data ? 0 : 1
  template = file("${path.module}/user-data.sh")

  vars = {
    server_port = var.server_port # 8080
    db_address = data.terraform_remote_state.db.outputs.address
    db_port = data.terraform_remote_state.db.outputs.port
  }
}

data "template_file" "user_data_new" {
  count = var.enable_new_user_data ? 1 : 0
  template = file("${path.module}/user-data-new.sh")

  vars = {
    server_port = var.server_port # 8080
  }
}

# terraform 백엔드 구성
# terraform {
#   backend "s3" {
#     bucket = "dy-tf-state"
#     key = "modules/services/webserver-cluster/terraform.tfstate"
#     region = "ap-northeast-2"

#     dynamodb_table = "dy-tf-locks"
#     encrypt = true
#   }
# }

# cloudwatch read only
resource "aws_iam_policy" "cloudwatch_read_only" {
  count = var.give_user_cloudwatch_full_access ? 0 : 1
  
  name = "${var.cluster_name}-cloudwatch-read-only"
  policy = data.aws_iam_policy_document.cloudwatch_read_only.json
}

data "aws_iam_policy_document" "cloudwatch_read_only" {
  statement {
    effect = "Allow"
    actions = [
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*"
    ]
    resources = ["*"]
  }
}

# cloudwatch full access
resource "aws_iam_policy" "cloudwatch_full_access" {
  count = var.give_user_cloudwatch_full_access ? 1 : 0

  name = "${var.cluster_name}-cloudwatch-full-access"
  policy = data.aws_iam_policy_document.cloudwatch_full_access.json
}

data "aws_iam_policy_document" "cloudwatch_full_access" {
  statement {
    effect = "Allow"
    actions = ["cloudwatch:*"]
    resources = ["*"]
  }
}