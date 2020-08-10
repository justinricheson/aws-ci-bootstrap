terraform {
  required_version = ">= 0.12"
  backend "s3" {
    region = "us-east-1"
    bucket = "terraform-790055257995"
  }
}

provider "aws" {
  region = var.aws_region
}

provider "github" {
  version      = "2.4.0" # Personal account webhooks broken in 2.5
  token        = var.github_token
  organization = var.github_user
}

data "aws_s3_bucket" "artifacts_s3_bucket" {
  bucket = "ci-artifacts-790055257995"
}

variable "aws_region" {
  type = string
}

variable "application_name" {
  type = string
}

variable "github_user" {
  type = string
}

variable "github_repository" {
  type = string
}

variable "github_branch" {
  type = string
}

variable "github_token" {
  type = string
}

variable "build_image" {
  type = string
}

resource "aws_codepipeline" "codepipeline" {
  name     = var.application_name
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = data.aws_s3_bucket.artifacts_s3_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "ThirdParty"
      provider         = "GitHub"
      version          = "1"
      output_artifacts = ["source"]

      configuration = {
        Owner                = var.github_user
        Repo                 = var.github_repository
        Branch               = var.github_branch
        OAuthToken           = var.github_token
        PollForSourceChanges = false
      }
    }
  }

  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source"]
      output_artifacts = ["build"]

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project.name
      }
    }
  }

  lifecycle {
    # Terraform seems to store a hashed version of the OAuthToken in the state file.
    # When updates to the codepipeline are made, the hashed token is used, which breaks
    # the pipeline. This can be confirmed by using the aws cli to update the pipeline
    # with the correct OAuthToken, fixing the issue. This is a hack to ignore the changed
    # token supplied by the aws cli so the broken hashed token doesn't overwrite it.
    ignore_changes = [stage[0].action[0].configuration]
  }
}

resource "aws_codepipeline_webhook" "codepipeline_webhook" {
  name            = format("github-webhook-%s", var.application_name)
  authentication  = "GITHUB_HMAC"
  target_action   = "Source"
  target_pipeline = aws_codepipeline.codepipeline.name

  authentication_configuration {
    secret_token = var.github_token
  }

  filter {
    json_path    = "$.ref"
    match_equals = "refs/heads/{Branch}"
  }
}

resource "github_repository_webhook" "github_webhook" {
  repository = var.github_repository

  configuration {
    url          = aws_codepipeline_webhook.codepipeline_webhook.url
    content_type = "json"
    insecure_ssl = false
    secret       = var.github_token
  }

  events = ["push"]
}

resource "aws_codebuild_project" "codebuild_project" {
  name          = format("%s-project", var.application_name)
  service_role  = aws_iam_role.codebuild_role.arn
  build_timeout = "5"

  source {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = var.build_image
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACT_S3_BUCKET"
      value = data.aws_s3_bucket.artifacts_s3_bucket.bucket
    }
    environment_variable {
      name  = "ARTIFACT_S3_KEY"
      value = var.application_name
    }
  }

  artifacts {
    name = var.application_name
    type = "CODEPIPELINE"
  }
}

resource "aws_iam_role" "codepipeline_role" {
  name = format("codepipeline-role-%s", var.application_name)

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codepipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = format("codepipeline-policy-%s", var.application_name)
  role = aws_iam_role.codepipeline_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [ "s3:GetBucketVersioning" ],
      "Resource": [ "${data.aws_s3_bucket.artifacts_s3_bucket.arn}" ]
    },
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject"
      ],
      "Resource": [ "${data.aws_s3_bucket.artifacts_s3_bucket.arn}/*" ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "codedeploy:CreateDeployment",
            "codedeploy:GetApplicationRevision",
            "codedeploy:GetDeployment",
            "codedeploy:GetDeploymentConfig",
            "codedeploy:RegisterApplicationRevision"
        ],
        "Resource": "*"
    },
    {
        "Effect": "Allow",
        "Action": [
            "codebuild:BatchGetBuilds",
            "codebuild:StartBuild"
        ],
        "Resource": "*"
    }
  ]
}
EOF
}

resource "aws_iam_role" "codebuild_role" {
  name = format("codebuild-role-%s", var.application_name)

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "codebuild.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codebuild_policy" {
  name = format("codebuild-policy-%s", var.application_name)
  role = aws_iam_role.codebuild_role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [ "*" ],
      "Action": [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
      ]
    },
    {
      "Effect": "Allow",
      "Resource": [
          "${data.aws_s3_bucket.artifacts_s3_bucket.arn}/${var.application_name}/*"
      ],
      "Action": [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject"
      ]
    }
  ]
}
EOF
}
