provider "aws" {
	region = "ap-northeast-2"
}

module "webserver_cluster" {
  # source = "git@github.com:largezero/tf-upNrunning//modules/services/webserver-cluster?ref=v0.0.2"
  source = "../../../../modules/services/webserver-cluster"

  cluster_name = "dy-tf-stage"  # stage
  instance_type = "t2.micro"
  key_pair = "dy-tf-dev"
  server_port = 8080
  min_size = 2
  max_size = 2
  enable_autoscaling = false
  give_user_cloudwatch_full_access = true
  enable_new_user_data = true

  # db reference info
  db_remote_state_bucket = "dy-tf-state"
  db_remote_state_key = "stage/data-stores/mysql/terraform.tfstate" # stage
}

# terraform 백엔드 구성
terraform {
  backend "s3" {
    bucket = "dy-tf-state"
    key = "stage/services/webserver-cluster/terraform.tfstate"
    region = "ap-northeast-2"

    dynamodb_table = "dy-tf-locks"
    encrypt = true
  }
}

# test port open in alb
# resource "aws_security_group_rule" "allow_testing_inbound" {
#   type = "ingress"

#   from_port = 12345
#   to_port = 12345
#   protocol = "tcp"
#   cidr_blocks = ["0.0.0.0/0"]

#   security_group_id = module.webserver_cluster.alb_security_group_id
# }