# ---------------------------------------------------
#    CloudWatch Log Groups
# ---------------------------------------------------
resource aws_cloudwatch_log_group ecs_group {
  name = "${var.name_prefix}/ecs/${var.cluster_name}/${var.service_name}/"
  tags = var.standard_tags
}


# ---------------------------------------------------
#    ECS Service
# ---------------------------------------------------
resource aws_ecs_service main {
  name                                = "${var.name_prefix}-${var.wm_instance}-${var.service_name}"
  cluster                             = var.cluster_name
  propagate_tags                      = "SERVICE"
  deployment_maximum_percent          = 200
  deployment_minimum_healthy_percent  = 100
  desired_count                       = var.desired_count
  task_definition                     = aws_ecs_task_definition.main.arn
  health_check_grace_period_seconds   = var.health_check_grace_period_seconds
  tags                                = merge(var.standard_tags, tomap({ Name = var.service_name }))

  ordered_placement_strategy {
    type  = "binpack"
    field = "memory"
  }
  ordered_placement_strategy {
    type  = "binpack"
    field = "cpu"
  }

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
    base              = 1
  }

  network_configuration {
    security_groups   = var.security_groups
    subnets           = var.subnets
    assign_public_ip  = var.public
  }

  load_balancer {
    target_group_arn  = aws_lb_target_group.main.arn
    container_name    = var.service_name
    container_port    = var.service_external_port
  }
}


# ---------------------------------------------------
#     Container - Main
# ---------------------------------------------------
module main_container_definition {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.1"

  container_name                = var.service_name
  container_image               = "${var.ecr_account_id}.dkr.ecr.${var.ecr_region}.amazonaws.com/${var.image_name}:${var.image_version}"
  container_cpu                 = var.container_cpu
  container_memory              = var.container_memory
  container_memory_reservation  = var.container_memory_reservation > var.container_memory ? var.container_memory_reservation : var.container_memory
  
  port_mappings = [
    {
      containerPort = var.service_internal_port
      hostPort      = var.service_internal_port
      protocol      = "tcp"
    }
  ]

  environment = setunion(var.environment,  
  [
    {
      name  = "PORT"
      value = var.service_port
    },
    {
      name  = "APP_PORT"
      value = var.service_port
    }
  ])

  log_configuration = {
    logDriver     = "awslogs"
    secretOptions = null
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.ecs_group.name
      "awslogs-region"        = data.aws_region.current.name
      "awslogs-stream-prefix" = "ecs"
    }
  }
}


# ---------------------------------------------------
#     Container - Logs
# ---------------------------------------------------
module logs_container_definition {
  source  = "cloudposse/ecs-container-definition/aws"
  version = "0.58.1"

  container_name  = "logdna"
  container_image = "logdna/logspout:latest"

  environment = [
    {
      name  = "LOGDNA_KEY"
      value = var.logdna_key
    },
    {
      name  = "TAGS"
      value = "${var.name_prefix}, ${data.aws_region.current.name}, ${var.wm_instance}, ${var.service_name}"
    }]

  mount_points = [
    {
      readOnly      : true,
      containerPath : "/var/run/docker.sock",
      sourceVolume  : "logdna"
    }
  ]

  log_configuration = {
    logDriver     = "awslogs"
    secretOptions = null
    options = {
      "awslogs-group"         = aws_cloudwatch_log_group.ecs_group.name
      "awslogs-region"        = data.aws_region.current.name
      "awslogs-stream-prefix" = "ecs"
    }
  }
}


# ---------------------------------------------------
#     Task Definition
# ---------------------------------------------------
resource aws_ecs_task_definition main {
  family                    = "${var.name_prefix}-${var.wm_instance}-${var.service_name}"
  requires_compatibilities  = ["EC2"]
  execution_role_arn        = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecsTaskExecutionRole"
  cpu                       = var.task_cpu > var.container_cpu ? var.task_cpu : var.container_cpu
  memory                    = var.task_memory > var.container_memory ? var.task_memory : var.container_memory
  network_mode              = "awsvpc"
  tags                      = merge(var.standard_tags, tomap({ Name = var.service_name }))
  container_definitions     = "[${module.main_container_definition.json_map_encoded}, ${module.logs_container_definition.json_map_encoded}]" # module.main_container_definition.json_map_encoded_list

  volume {
    name      = "logdna"
    host_path = "/var/run/docker.sock"
  }
}


# ---------------------------------------------------
#    CloudWatch Alarms for ASG
# ---------------------------------------------------
resource aws_cloudwatch_metric_alarm service_cpu_high {
  alarm_name          = "${var.name_prefix}-${var.wm_instance}-${var.service_name}-high-cpu"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  threshold           = var.container_cpu_high_threshold
  datapoints_to_alarm = 1
  statistic           = "Average"
  period              = "60"

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.main.name
  }

  alarm_actions = [
    aws_appautoscaling_policy.scale_up.arn
  ]
}

resource aws_cloudwatch_metric_alarm service_cpu_low {
  alarm_name          = "${var.name_prefix}-${var.wm_instance}-${var.service_name}-low-cpu"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = "2"
  threshold           = var.container_cpu_low_threshold
  datapoints_to_alarm = 1
  statistic           = "Average"
  period              = "60"

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = aws_ecs_service.main.name
  }

  alarm_actions = [
    aws_appautoscaling_policy.scale_down.arn
  ]
}


# ---------------------------------------------------
#    Autoscaling
# ---------------------------------------------------
resource time_sleep wait {
  depends_on      = [aws_ecs_service.main]
  create_duration = "30s"
}

resource aws_appautoscaling_target autoscaling_target {
  min_capacity        = var.min_capacity
  max_capacity        = var.max_capacity
  resource_id         = "service/${var.cluster_name}/${var.name_prefix}-${var.wm_instance}-${var.service_name}"
  role_arn            = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/aws-service-role/ecs.application-autoscaling.amazonaws.com/AWSServiceRoleForApplicationAutoScaling_ECSService"
  scalable_dimension  = "ecs:service:DesiredCount"
  service_namespace   = "ecs"
  depends_on          = [time_sleep.wait]
}

resource aws_appautoscaling_policy scale_up {
  name               = "scale-up-${var.name_prefix}-${var.wm_instance}-${var.service_name}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.autoscaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.autoscaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.autoscaling_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_upper_bound = 0
      scaling_adjustment          = 1
    }
  }
}

resource aws_appautoscaling_policy scale_down {
  name               = "scale-down-${var.name_prefix}-${var.wm_instance}-${var.service_name}"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.autoscaling_target.resource_id
  scalable_dimension = aws_appautoscaling_target.autoscaling_target.scalable_dimension
  service_namespace  = aws_appautoscaling_target.autoscaling_target.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Maximum"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = -1
    }
  }
}


# ---------------------------------------------------
#    Load Balancing
# ---------------------------------------------------
resource aws_lb_target_group main {
  name                          = "${var.name_prefix}-${var.wm_instance}-${var.service_name}-tg"
  port                          = var.service_internal_port
  protocol                      = "HTTP"
  vpc_id                        = var.vpc_id
  load_balancing_algorithm_type = "round_robin"
  target_type                   = "ip"
  depends_on                    = [data.aws_lb.passed_on]
  
  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    path                = "/health"
    port                = var.service_external_port
  }
}

resource aws_lb_listener public {
    load_balancer_arn = aws_lb.public.arn
    port              = var.service_internal_port
    protocol          = "HTTP"
    depends_on        = [aws_lb.public]

    default_action {
        type = "redirect"

        redirect {
            port        = var.service_external_port
            protocol    = "HTTPS"
            status_code = "HTTP_301"
        }
    }
}

resource aws_lb_listener_rule block_header {
    listener_arn = aws_lb_listener.public.arn
    priority = 100

    condition {
        http_header {
            http_header_name = "X-Forwarded-Host"
            values           = ["*"]
        }
    }
    action {
        type = "fixed-response"
        fixed_response {
            content_type = "text/plain"
            message_body = "Invalid host header."
            status_code = 400
        }
    }
}