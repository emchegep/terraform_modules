terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.81.0"
    }
  }
}
locals {
  http_port    = 80
  any_port     = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips      = ["0.0.0.0/0"]
}
data "terraform_remote_state" "db" {
  backend = "s3"
  config = {
    bucket = var.db_remote_state_bucket
    key    = var.db_remote_state_key
    region = "us-east-2"
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "instance" {
  name        = "${var.cluster_name}-instance"
  description = "${var.cluster_name} EC2 security group"

  ingress {
    from_port   = local.http_port
    to_port     = local.http_port
    protocol    = local.tcp_protocol
    cidr_blocks = local.all_ips
  }

  egress {
    from_port   = local.any_port
    to_port     = local.any_port
    protocol    = local.any_protocol
    cidr_blocks = local.all_ips
  }
}

resource "aws_security_group_rule" "allow_server_http_inbound" {
  type = "ingress"
  security_group_id = aws_security_group.instance.id

  from_port = var.server_port
  to_port = var.server_port
  protocol = local.tcp_protocol
  cidr_blocks = local.all_ips
}
resource "aws_launch_template" "asg-launch-template" {
  name                   = "${var.cluster_name}-asg-launch-template"
  image_id               = "ami-0d1b5a8c13042c939"
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.instance.id]

  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    server_port = var.server_port
    db_address  = data.terraform_remote_state.db.outputs.address
    db_port     = data.terraform_remote_state.db.outputs.port
  }))

  # Required when using a launch template with an auto scaling group
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  name = "${var.cluster_name}-terraform-asg"
  launch_template {
    id      = aws_launch_template.asg-launch-template.id
    version = "$Latest"
  }
  vpc_zone_identifier = data.aws_subnets.default.ids
  min_size            = var.min_size
  max_size            = var.max_size

  target_group_arns = [aws_lb_target_group.asg-target-group.arn]
  health_check_type = "ELB"



  tag {
    key                 = "Name"
    value               = "${var.cluster_name}-terraform-asg"
    propagate_at_launch = true
  }
}

resource "aws_lb" "my-alb" {
  name               = "${var.cluster_name}-alb"
  load_balancer_type = "application"
  subnets            = data.aws_subnets.default.ids
  security_groups    = [aws_security_group.alb.id]
}

resource "aws_lb_listener" "my-alb-listener" {
  load_balancer_arn = aws_lb.my-alb.arn
  port              = local.http_port
  protocol          = "HTTP"

  # By default, return a simple 404 page
  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: page not found"
      status_code  = 404
    }
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.cluster_name}-alb-security-group"
  description = "${var.cluster_name} ALB security group"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  type              = "ingress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.http_port
  to_port     = local.http_port
  protocol    = local.tcp_protocol
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  type              = "egress"
  security_group_id = aws_security_group.alb.id

  from_port   = local.any_port
  to_port     = local.any_port
  protocol    = local.any_protocol
  cidr_blocks = local.all_ips
}

resource "aws_lb_target_group" "asg-target-group" {
  name     = "${var.cluster_name}-asg-TG"
  port     = var.server_port
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 15
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener_rule" "asg-listener-rule" {
  listener_arn = aws_lb_listener.my-alb-listener.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["*"]
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asg-target-group.arn
  }
}