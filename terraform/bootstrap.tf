terraform {
  required_version = ">= 0.12"
}

provider "aws" {
  region = var.aws_region
}

provider "github" {
  version      = "2.4.0" # Personal account webhooks broken in 2.5
  token        = var.github_token
  organization = var.github_user
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

resource "aws_codepipeline" "codepipeline" {
  name     = var.application_name
  role_arn = aws_iam_role.codepipeline_role.arn

  artifact_store {
    location = aws_s3_bucket.artifact_s3_bucket.bucket
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
      output_artifacts = [format("output_%s", var.application_name)]

      configuration = {
        Owner      = var.github_user
        Repo       = var.github_repository
        Branch     = var.github_branch
        OAuthToken = var.github_token
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = [format("output_%s", var.application_name)]
      version         = "1"

      configuration = {
        ProjectName = aws_codebuild_project.codebuild_project.name
      }
    }
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
  build_timeout = "5"
  service_role  = aws_iam_role.codebuild_role.arn

  source {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:1.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ARTIFACT_S3_BUCKET"
      value = aws_s3_bucket.artifact_s3_bucket.bucket
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
      "Resource": [ "${aws_s3_bucket.artifact_s3_bucket.arn}" ]
    },
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject"
      ],
      "Resource": [ "${aws_s3_bucket.artifact_s3_bucket.arn}/*" ]
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

resource "aws_s3_bucket" "artifact_s3_bucket" {
  bucket = "ci-artifact-s3-bucket"
  acl    = "private"
}
