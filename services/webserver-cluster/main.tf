data "aws_vpc" "default" {
  default = true
}

terraform {
  backend "s3" {
    bucket = "bijan-terraform-state"
    key   = "stage/services/webserver-cluster/terraform.tfstate"
    region = "us-east-2"

  dynamodb_table = "bijan-terraform-locks"
  encrypt = true
  }
}

locals {
  http_port = 80
  any_port = 0
  any_protocol = "-1"
  tcp_protocol = "tcp"
  all_ips = ["0.0.0.0/0"]
}

data "terraform_remote_state" "db" {
  backend = "s3"

  config = {
    bucket = var.db_remote_state_bucket
    key = var.db_remote_state_key
    region = "us-east-2"
  }
}

data "aws_subnet_ids" "default" {
  vpc_id = data.aws_vpc.default.id
}

data "template_file" "user_data" {
  template = file("${path.module}/user-data.sh")

  vars = {
    server_port = var.server_port
    db_address = data.terraform_remote_state.db.outputs.address
    db_port = data.terraform_remote_state.db.outputs.port
  }
}

resource "aws_lb" "example" {
  name = "${var.cluster_name}-alb"
  load_balancer_type = "application"
  subnets = data.aws_subnet_ids.default.ids
  security_groups = [aws_security_group.alb.id]
}

resource "aws_lb_target_group" "asg" {
  name = "${var.cluster_name}-asg-target-group"
  port = var.server_port
  protocol = "HTTP"
  vpc_id = data.aws_vpc.default.id

  health_check {
    path = "/"
    protocol = "HTTP"
    matcher = "200"
    interval = 15
    timeout  = 3
    healthy_threshold = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.example.arn
  port  = local.http_port
  protocol = "HTTP"

  default_action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      message_body = "404: Page not found"
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



resource "aws_launch_configuration" "example" {
  image_id  = "ami-0c55b159cbfafe1f0"
  instance_type = var.instance_type
# here we specify which security group to use, which creates an implicit dependency
  security_groups = [aws_security_group.instance.id]

# user data is a good way to run a script
  user_data = data.template_file.user_data.rendered
  /*
  user_data = <<-EOF
              #!/bin/bash
              echo "Hello world" >> index.html
              echo "${data.terraform_remote_state.db.outputs.address}" >> index.html
              echo "${data.terraform_remote_state.db.outputs.port}" >> index.html
              nohup busybox httpd -f -p ${var.server_port} &
              EOF
*/

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "example" {
  launch_configuration = aws_launch_configuration.example.name
  vpc_zone_identifier = data.aws_subnet_ids.default.ids

  target_group_arns = [aws_lb_target_group.asg.arn]
  health_check_type = "ELB"

  min_size = var.min_size
  max_size = var.max_size

  tag {
    key = "Name"
    value = "${var.cluster_name}-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}



# by deafult ec2 doesn't allow any traffic incoming or outgoing
resource "aws_security_group" "instance" {
  name = "${var.cluster_name}-instance"

  ingress {
    from_port = var.server_port
    to_port   = var.server_port
    protocol  = local.tcp_protocol
    cidr_blocks = local.all_ips
  }
}

resource "aws_security_group" "alb" {
  name = "${var.cluster_name}-alb"
}

resource "aws_security_group_rule" "allow_http_inbound" {
  from_port = local.http_port
  protocol = local.tcp_protocol
  security_group_id = aws_security_group.alb.id
  to_port = local.http_port
  type = "ingress"
  cidr_blocks = local.all_ips
}

resource "aws_security_group_rule" "allow_all_outbound" {
  from_port = local.any_port
  protocol = local.tcp_protocol
  security_group_id = aws_security_group.alb.id
  to_port = local.any_port
  type = "egress"
  cidr_blocks = local.all_ips

}
