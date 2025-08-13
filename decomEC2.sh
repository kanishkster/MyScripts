#!/bin/bash
# Usage: ./decommission-ec2.sh i-xxxxxxxxxxxxxxxx dry-run
# Second arg: "dry-run" or "delete"

INSTANCE_ID=$1
ACTION=${2:-dry-run}
REGION="ap-southeast-2" # Change if needed

if [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <instance-id> [dry-run|delete]"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is required but not installed."
    exit 1
fi

echo "=== Gathering resources for EC2 instance $INSTANCE_ID in $REGION ==="

# Instance details
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION)
if [ $? -ne 0 ]; then
    echo "Error: Instance not found."
    exit 1
fi

PRIVATE_IP=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].PrivateIpAddress')
PUBLIC_IP=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].PublicIpAddress')

echo "Private IP: $PRIVATE_IP"
echo "Public IP: $PUBLIC_IP"

# EBS Volumes
VOLUMES=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')
echo "EBS Volumes: $VOLUMES"

# Elastic IPs
EIPS=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$INSTANCE_ID" --region $REGION --query "Addresses[].AllocationId" --output text)
echo "Elastic IPs: $EIPS"

# Security Groups
SGS=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId')
echo "Security Groups: $SGS"

# ENIs
ENIS=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].NetworkInterfaces[].NetworkInterfaceId')
echo "ENIs: $ENIS"

# IAM Role
IAM_PROFILE=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn')
echo "IAM Instance Profile: $IAM_PROFILE"

# CloudWatch Alarms
ALARM_NAMES=$(aws cloudwatch describe-alarms --region $REGION --query "MetricAlarms[?Dimensions[?Name=='InstanceId' && Value=='$INSTANCE_ID']].AlarmName" --output text)
echo "CloudWatch Alarms: $ALARM_NAMES"

# Route53 DNS Records
echo "Checking Route53 records..."
for ZONE_ID in $(aws route53 list-hosted-zones --query "HostedZones[].Id" --output text); do
    aws route53 list-resource-record-sets --hosted-zone-id $ZONE_ID --query "ResourceRecordSets[?ResourceRecords[?Value=='$PUBLIC_IP' || Value=='$PRIVATE_IP']]" --output table
done

# Load Balancer Target Groups
echo "Checking Load Balancer target groups..."
TARGET_GROUPS=$(aws elbv2 describe-target-groups --region $REGION --query "TargetGroups[].TargetGroupArn" --output text)
for TG in $TARGET_GROUPS; do
    MATCH=$(aws elbv2 describe-target-health --target-group-arn $TG --region $REGION --query "TargetHealthDescriptions[?Target.Id=='$INSTANCE_ID'].Target.Id" --output text)
    if [ "$MATCH" == "$INSTANCE_ID" ]; then
        echo "Instance found in Target Group: $TG"
    fi
done

# SSM Associations
SSM_ASSOCS=$(aws ssm list-associations --region $REGION --query "Associations[?Targets[?Values[?contains(@, '$INSTANCE_ID')]]].AssociationId" --output text)
echo "SSM Associations: $SSM_ASSOCS"

if [ "$ACTION" == "delete" ]; then
    echo "=== Deleting resources ==="

    # Stop instance
    aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION
    aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID --region $REGION

    # Remove from Target Groups
    for TG in $TARGET_GROUPS; do
        aws elbv2 deregister-targets --target-group-arn $TG --targets Id=$INSTANCE_ID --region $REGION
    done

    # Remove EIPs
    for EIP in $EIPS; do
        aws ec2 release-address --allocation-id $EIP --region $REGION
    done

    # Delete EBS Volumes
    for VOL in $VOLUMES; do
        aws ec2 detach-volume --volume-id $VOL --region $REGION
        aws ec2 delete-volume --volume-id $VOL --region $REGION
    done

    # Delete ENIs
    for ENI in $ENIS; do
        aws ec2 delete-network-interface --network-interface-id $ENI --region $REGION
    done

    # Delete Security Groups
    for SG in $SGS; do
        if [ "$SG" != "sg-xxxxxxxx" ]; then
            aws ec2 delete-security-group --group-id $SG --region $REGION
        fi
    done

    # Delete IAM Role / Instance Profile
    if [ "$IAM_PROFILE" != "null" ]; then
        PROFILE_NAME=$(basename $IAM_PROFILE)
        ROLE_NAME=$(aws iam get-instance-profile --instance-profile-name $PROFILE_NAME --query "InstanceProfile.Roles[0].RoleName" --output text)
        aws iam remove-role-from-instance-profile --instance-profile-name $PROFILE_NAME --role-name $ROLE_NAME
        aws iam delete-instance-profile --instance-profile-name $PROFILE_NAME
        aws iam delete-role --role-name $ROLE_NAME
    fi

    # Delete CloudWatch Alarms
    for ALARM in $ALARM_NAMES; do
        aws cloudwatch delete-alarms --alarm-names "$ALARM" --region $REGION
    done

    # Delete SSM Associations
    for ASSOC in $SSM_ASSOCS; do
        aws ssm delete-association --association-id $ASSOC --region $REGION
    done

    # Terminate Instance
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION

    echo "=== Decommission completed for $INSTANCE_ID ==="
else
    echo "=== Dry Run Mode: No resources deleted ==="
fi
