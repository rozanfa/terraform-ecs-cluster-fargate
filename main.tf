data "aws_availability_zones" "available_zones" {
  state = "available"
}

resource "aws_vpc" "default" {
  cidr_block = "10.32.0.0/16"
}

resource "aws_subnet" "public" {
  count                   = 2
  cidr_block              = cidrsubnet(aws_vpc.default.cidr_block, 8, 2 + count.index)
  availability_zone       = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id                  = aws_vpc.default.id
  map_public_ip_on_launch = true
}

resource "aws_subnet" "private" {
  count             = 2
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.default.id
}

resource "aws_internet_gateway" "gateway" {
  vpc_id = aws_vpc.default.id
}

resource "aws_route" "internet_access" {
  route_table_id         = aws_vpc.default.main_route_table_id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.gateway.id
}

resource "aws_eip" "gateway" {
  count      = 2
  vpc        = true
  depends_on = [aws_internet_gateway.gateway]
}

resource "aws_nat_gateway" "gateway" {
  count         = 2
  subnet_id     = element(aws_subnet.public.*.id, count.index)
  allocation_id = element(aws_eip.gateway.*.id, count.index)
}

resource "aws_route_table" "private" {
  count  = 2
  vpc_id = aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.gateway.*.id, count.index)
  }
}

resource "aws_route_table_association" "private" {
  count          = 2
  subnet_id      = element(aws_subnet.private.*.id, count.index)
  route_table_id = element(aws_route_table.private.*.id, count.index)
}

resource "aws_security_group" "lb" {
  name   = "rozan-alb-security-group"
  vpc_id = aws_vpc.default.id

  ingress {
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb" "default" {
  name            = "rozan-lb"
  subnets         = aws_subnet.public.*.id
  security_groups = [aws_security_group.lb.id]
}

resource "aws_lb_target_group" "nginx" {
  name        = "rozan-target-group"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = aws_vpc.default.id
  target_type = "ip"
}

resource "aws_lb_listener" "nginx" {
  load_balancer_arn = aws_lb.default.id
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.nginx.id
    type             = "forward"
  }
}

resource "aws_ecs_task_definition" "nginx" {
  family                   = "nginx-app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 256
  memory                   = 512

  container_definitions = <<EOF
[
  {
    "image": "nginx:latest",
    "cpu": 256,
    "memory": 256,
    "name": "nginx-app",
    "networkMode": "awsvpc",
    "portMappings": [
      {
        "containerPort": 80,
        "hostPort": 80
      }
    ]
  }
]
EOF
}

resource "aws_security_group" "nginx_task" {
  name   = "rozan-task-security-group"
  vpc_id = aws_vpc.default.id

  ingress {
    protocol        = "tcp"
    from_port       = 80
    to_port         = 80
    security_groups = [aws_security_group.lb.id]
  }

  egress {
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_ecs_cluster" "main" {
  name = "rozan-cluster"
}

resource "aws_ecs_service" "nginx" {
  name            = "nginx-service"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.nginx.arn
  desired_count   = var.app_count
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.nginx_task.id]
    subnets         = aws_subnet.private.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.nginx.id
    container_name   = "nginx-app"
    container_port   = 80
  }

  depends_on = [aws_lb_listener.nginx]
}


# Resources for auto scaling

resource "aws_appautoscaling_target" "ecs_target" {
  min_capacity       = var.min_capacity
  max_capacity       = var.max_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.nginx.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_policy" {
  name               = "ecs-target-request-count"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs_target.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs_target.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label = "app/${aws_lb.default.name}/${basename("${aws_lb.default.id}")}/targetgroup/${aws_lb_target_group.nginx.name}/${basename("${aws_lb_target_group.nginx.id}")}"
    }
    target_value = var.policy_target_value
    scale_in_cooldown = var.scale_in_cooldown
    scale_out_cooldown = var.scale_out_cooldown
  }
}
