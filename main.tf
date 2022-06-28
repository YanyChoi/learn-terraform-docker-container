terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }

  required_version = ">= 1.2.0"
}

provider "aws" {
  profile = "yany"
  region = "ap-northeast-2"
}
# Ports to put in inbound rules
locals {
  ports_in = [
    443,
    80,
    3000
  ]
}

data "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"
}

data "aws_subnets" "subnets" {
  filter {
    name   = "vpc-id"
    values = [aws_vpc.vpc.id]
  }
}

# VPC configuration
resource "aws_vpc" "vpc" {
  cidr_block = "172.31.0.0/16"
  instance_tenancy = "default"
}
# Internet Gateway
resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.vpc.id
}
# Subnets
resource "aws_subnet" "subnet1" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "172.31.0.0/20"
  availability_zone = "ap-northeast-2a"
}
resource "aws_subnet" "subnet2" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "172.31.16.0/20"
  availability_zone = "ap-northeast-2b"
}
resource "aws_subnet" "subnet3" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "172.31.32.0/20"
  availability_zone = "ap-northeast-2c"
}
resource "aws_subnet" "subnet4" {
  vpc_id = aws_vpc.vpc.id
  cidr_block = "172.31.48.0/20"
  availability_zone = "ap-northeast-2d"
}
# Security Group
resource "aws_security_group" "security_group" {
  name        = "dev-test-security-group"
  description = "Terraform test"
  vpc_id = aws_vpc.vpc.id

  dynamic "ingress" {
    for_each = toset(local.ports_in)
    content {
      description      = "open port 3000"
      from_port        = ingress.value
      to_port          = ingress.value
      protocol         = "tcp"
      cidr_blocks      = ["0.0.0.0/0"]
    }
  }
  egress {
    description = "terraform"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECR Configuration
resource "aws_ecr_repository" "ecr" {
  name                 = "picky-web-app"
  image_tag_mutability = "MUTABLE"
}


# Load Balancer Configuration
# Target Group
resource "aws_lb_target_group" "web_target_group" {
  name     = "ECS-PICKY-WEB-APP"
  port     = 80
  protocol = "HTTP"
  target_type = "ip"
  vpc_id   = aws_vpc.vpc.id
}

# Application Load Balancer
resource "aws_lb" "load_balancer" {
  name               = "Web"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.security_group.id]
  subnets            = data.aws_subnets.subnets.ids

  enable_deletion_protection = true

}
# Load Balancer Listener
resource "aws_lb_listener" "lb_listener" {
  load_balancer_arn = aws_lb.load_balancer.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_target_group.arn
  }
}


#ECS Cluster Configuration
resource "aws_ecs_cluster" "cluster" {
  name = "picky-ecs-development-cluster"
}

resource "aws_ecs_cluster_capacity_providers" "example" {
  cluster_name = aws_ecs_cluster.cluster.name

  capacity_providers = ["FARGATE"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
  }
}

# Task Definition
resource "aws_ecs_task_definition" "task-definition" {
  family = "picky-web-app-task-def"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = data.aws_iam_role.ecs_task_execution_role.arn
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  container_definitions = jsonencode([
    {
      name      = "picky-web-app"
      image     = aws_ecr_repository.ecr.repository_url
      cpu       = 1
      memory    = 1024
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ]
    }
  ])
}

resource "aws_ecs_service" "picky-web-app" {
  name            = "picky-web-app"
  cluster         = aws_ecs_cluster.cluster.arn
  task_definition = aws_ecs_task_definition.task-definition.arn
  desired_count   = 1
  launch_type = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.web_target_group.arn
    container_name   = "picky-web-app"
    container_port   = 3000
  }
  network_configuration {
    subnets = data.aws_subnets.subnets.ids
    security_groups = [aws_security_group.security_group.id]
    assign_public_ip = true
  }
}