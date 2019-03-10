/**
 * # aws-terraform-ec2_asg
 *
 *This module creates one or more autoscaling groups.
 *
 *## Basic Usage
 *
 *```
 *module "asg" {
 *  source = "git::https://github.com/scafeman/aws-terraform-ec2_asg//?ref=v0.0.11"
 *
 *  ec2_os              = "amazon"
 *  subnets             = ["${module.vpc.private_subnets}"]
 *  image_id            = "${var.image_id}"
 *  resource_name       = "my_asg"
 *  security_group_list = ["${module.sg.private_web_security_group_id}"]
 *}
 *```
 *
 * Full working references are available at [examples](examples)
 */

# Lookup the correct AMI based on the region specified
data "aws_ami" "asg_ami" {
  most_recent = true
  owners      = ["${local.ami_owner_mapping[var.ec2_os]}"]

  filter {
    name   = "name"
    values = ["${local.ami_name_mapping[var.ec2_os]}"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "template_file" "user_data" {
  template = "${file("${path.module}/text/${lookup(local.user_data_map, var.ec2_os)}")}"

  vars {
    initial_commands = "${var.initial_userdata_commands != "" ? "${var.initial_userdata_commands}" : "" }"
    final_commands   = "${var.final_userdata_commands != "" ? "${var.final_userdata_commands}" : "" }"
  }
}

data "aws_region" "current_region" {}
data "aws_caller_identity" "current_account" {}

#
# IAM policies
#

data "aws_iam_policy_document" "mod_ec2_assume_role_policy_doc" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "mod_ec2_instance_role_policies" {
  statement {
    effect    = "Allow"
    actions   = ["cloudformation:Describe"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "ssm:CreateAssociation",
      "ssm:DescribeInstanceInformation",
    ]

    resources = ["*"]
  }

  statement {
    effect = "Allow"

    actions = [
      "logs:CreateLogStream",
      "ec2:DescribeTags",
      "logs:DescribeLogStreams",
      "logs:CreateLogGroup",
      "logs:PutLogEvents",
      "ssm:GetParameter",
    ]

    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeTags"]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "create_instance_role_policy" {
  count       = "${var.instance_profile_override ? 0 : 1}"
  name        = "InstanceRolePolicy-${var.resource_name}"
  description = "Rackspace Instance Role Policies for EC2"
  policy      = "${data.aws_iam_policy_document.mod_ec2_instance_role_policies.json}"
}

resource "aws_iam_role" "mod_ec2_instance_role" {
  count              = "${var.instance_profile_override ? 0 : 1}"
  name               = "InstanceRole-${var.resource_name}"
  path               = "/"
  assume_role_policy = "${data.aws_iam_policy_document.mod_ec2_assume_role_policy_doc.json}"
}

resource "aws_iam_role_policy_attachment" "attach_ssm_policy" {
  count      = "${var.instance_profile_override ? 0 : 1}"
  role       = "${aws_iam_role.mod_ec2_instance_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_role_policy_attachment" "attach_codedeploy_policy" {
  count      = "${var.install_codedeploy_agent && var.instance_profile_override != true ? 1 : 0}"
  role       = "${aws_iam_role.mod_ec2_instance_role.name}"
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforAWSCodeDeploy"
}

resource "aws_iam_role_policy_attachment" "attach_instance_role_policy" {
  count      = "${var.instance_profile_override ? 0 : 1}"
  role       = "${aws_iam_role.mod_ec2_instance_role.name}"
  policy_arn = "${aws_iam_policy.create_instance_role_policy.arn}"
}

resource "aws_iam_role_policy_attachment" "attach_additonal_policies" {
  count      = "${var.instance_profile_override ? 0 : var.instance_role_managed_policy_arn_count}"
  role       = "${aws_iam_role.mod_ec2_instance_role.name}"
  policy_arn = "${element(var.instance_role_managed_policy_arns, count.index)}"
}

resource "aws_iam_instance_profile" "instance_role_instance_profile" {
  count = "${var.instance_profile_override ? 0 : 1}"
  name  = "InstanceRoleInstanceProfile-${var.resource_name}"
  role  = "${aws_iam_role.mod_ec2_instance_role.name}"
  path  = "/"
}

#
# Provisioning of ASG related resources
#

resource "aws_launch_configuration" "launch_config_with_secondary_ebs" {
  name_prefix          = "${join("-",compact(list("LaunchConfigWith2ndEbs", var.resource_name, format("%03d-",count.index+1))))}"
  count                = "${var.secondary_ebs_volume_size != "" ? 1 : 0}"
  user_data_base64     = "${base64encode(data.template_file.user_data.rendered)}"
  enable_monitoring    = "${var.detailed_monitoring}"
  image_id             = "${var.image_id != "" ? var.image_id : data.aws_ami.asg_ami.image_id}"
  key_name             = "${var.key_pair}"
  security_groups      = ["${var.security_group_list}"]
  placement_tenancy    = "${var.tenancy}"
  ebs_optimized        = "${var.enable_ebs_optimization}"
  iam_instance_profile = "${element(coalescelist(aws_iam_instance_profile.instance_role_instance_profile.*.name, list(var.instance_profile_override_name)), 0)}"
  instance_type        = "${var.instance_type}"

  root_block_device {
    volume_type = "${var.primary_ebs_volume_type}"
    volume_size = "${var.primary_ebs_volume_size}"
    iops        = "${var.primary_ebs_volume_type == "io1" ? var.primary_ebs_volume_size : 0}"
  }

  ebs_block_device {
    device_name = "${lookup(local.ebs_device_map, var.ec2_os)}"
    volume_type = "${var.secondary_ebs_volume_type}"
    volume_size = "${var.secondary_ebs_volume_size}"
    iops        = "${var.secondary_ebs_volume_iops}"
    encrypted   = "${var.encrypt_secondary_ebs_volume}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_launch_configuration" "launch_config_no_secondary_ebs" {
  name_prefix          = "${join("-",compact(list("LaunchConfigNo2ndEbs", var.resource_name, format("%03d-",count.index+1))))}"
  count                = "${var.secondary_ebs_volume_size != "" ? 0 : 1}"
  user_data_base64     = "${base64encode(data.template_file.user_data.rendered)}"
  enable_monitoring    = "${var.detailed_monitoring}"
  image_id             = "${var.image_id != "" ? var.image_id : data.aws_ami.asg_ami.image_id}"
  key_name             = "${var.key_pair}"
  security_groups      = ["${var.security_group_list}"]
  placement_tenancy    = "${var.tenancy}"
  ebs_optimized        = "${var.enable_ebs_optimization}"
  iam_instance_profile = "${element(coalescelist(aws_iam_instance_profile.instance_role_instance_profile.*.name, list(var.instance_profile_override_name)), 0)}"
  instance_type        = "${var.instance_type}"

  root_block_device {
    volume_type = "${var.primary_ebs_volume_type}"
    volume_size = "${var.primary_ebs_volume_size}"
    iops        = "${var.primary_ebs_volume_type == "io1" ? var.primary_ebs_volume_size : 0}"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_policy" "ec2_scale_up_policy" {
  name                   = "${join("-",compact(list("ec2_scale_up_policy", var.resource_name, format("%03d",count.index+1))))}"
  count                  = "${var.asg_count}"
  scaling_adjustment     = "${var.ec2_scale_up_adjustment}"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = "${var.ec2_scale_up_cool_down}"
  autoscaling_group_name = "${element(aws_autoscaling_group.autoscalegrp.*.name, count.index)}"
}

resource "aws_autoscaling_policy" "ec2_scale_down_policy" {
  name                   = "${join("-",compact(list("ec2_scale_down_policy", var.resource_name, format("%03d",count.index+1))))}"
  count                  = "${var.asg_count}"
  scaling_adjustment     = "${var.ec2_scale_down_adjustment > 0 ? 0 - var.ec2_scale_down_adjustment : var.ec2_scale_down_adjustment}"
  adjustment_type        = "ChangeInCapacity"
  cooldown               = "${var.ec2_scale_down_cool_down}"
  autoscaling_group_name = "${element(aws_autoscaling_group.autoscalegrp.*.name, count.index)}"
}

resource "aws_autoscaling_group" "autoscalegrp" {
  name_prefix               = "${join("-",compact(list("AutoScaleGrp", var.resource_name, format("%03d-",count.index+1))))}"
  count                     = "${var.asg_count}"
  max_size                  = "${var.scaling_max}"
  min_size                  = "${var.scaling_min}"
  health_check_grace_period = "${var.health_check_grace_period}"
  health_check_type         = "${var.health_check_type}"

  # coalescelist and list("novalue") were used here due to element not being able to handle empty lists, even if conditional will not allow portion to execute
  launch_configuration      = "${var.secondary_ebs_volume_size != "" ? element(coalescelist(aws_launch_configuration.launch_config_with_secondary_ebs.*.name, list("novalue")), count.index) : element(coalescelist(aws_launch_configuration.launch_config_no_secondary_ebs.*.name, list("novalue")), count.index)}"
  vpc_zone_identifier       = ["${var.subnets}"]
  load_balancers            = ["${var.load_balancer_names}"]
  metrics_granularity       = "1Minute"
  target_group_arns         = ["${var.target_group_arns}"]
  wait_for_capacity_timeout = "${var.asg_wait_for_capacity_timeout}"

  tags = ["${
    concat(
        local.tags,
        var.additional_tags)}"]

  lifecycle {
    create_before_destroy = true
  }

  depends_on = ["aws_ssm_association.ssm_bootstrap_assoc"]
}

resource "aws_autoscaling_notification" "scaling_notifications" {
  count = "${var.enable_scaling_notification ? var.asg_count : 0}"

  group_names = [
    "${element(aws_autoscaling_group.autoscalegrp.*.name, count.index)}",
  ]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH",
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]

  topic_arn = "${var.scaling_notification_topic}"
}

resource "aws_autoscaling_notification" "rs_support_emergency" {
  count = "${var.rackspace_managed ? var.asg_count : 0}"

  group_names = [
    "${element(aws_autoscaling_group.autoscalegrp.*.name, count.index)}",
  ]

  notifications = [
    "autoscaling:EC2_INSTANCE_LAUNCH_ERROR",
    "autoscaling:EC2_INSTANCE_TERMINATE_ERROR",
  ]

  topic_arn = "arn:aws:sns:${data.aws_region.current_region.name}:${data.aws_caller_identity.current_account.account_id}:rackspace-support-emergency"
}