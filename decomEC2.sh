#!/bin/bash
# Usage: ./decommission-ec2.sh i-xxxxxxxxxxxxxxxx dry-run
# Second arg: "dry-run" or "delete"

INSTANCE_ID=$1
ACTION=${2:-dry-run}  # default dry run
REGION="ap-southeast-2"  # change to your region

if [ -z "$INSTANCE_ID" ]; then
    echo "Usage: $0 <instance-id> [dry-run|delete]"
    exit 1
fi

echo "=== Gathering resources for EC2 instance $INSTANCE_ID in $REGION ==="

# 1. Get instance details
INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION)
if [ $? -ne 0 ]; then
    echo "Error: Instance not found."
    exit 1
fi

# 2. Get EBS Volumes
VOLUMES=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].BlockDeviceMappings[].Ebs.VolumeId')
echo "EBS Volumes: $VOLUMES"

# 3. Get Elastic IPs
EIPS=$(aws ec2 describe-addresses --filters "Name=instance-id,Values=$INSTANCE_ID" --region $REGION --query "Addresses[].AllocationId" --output text)
echo "Elastic IPs: $EIPS"

# 4. Get Security Groups
SGS=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].SecurityGroups[].GroupId')
echo "Security Groups: $SGS"

# 5. Get ENIs
ENIS=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].NetworkInterfaces[].NetworkInterfaceId')
echo "ENIs: $ENIS"

# 6. Get IAM Role
IAM_PROFILE=$(echo $INSTANCE_INFO | jq -r '.Reservations[].Instances[].IamInstanceProfile.Arn')
echo "IAM Instance Profile: $IAM_PROFILE"

# 7. Get CloudWatch Alarms
ALARM_NAMES=$(aws cloudwatch describe-alarms --region $REGION --query "MetricAlarms[?Dimensions[?Name=='InstanceId' && Value=='$INSTANCE_ID']].AlarmName" --output text)
echo "CloudWatch Alarms: $ALARM_NAMES"

# 8. Perform Actions
if [ "$ACTION" == "delete" ]; then
    echo "=== Deleting resources ==="

    # Stop instance first
    aws ec2 stop-instances --instance-ids $INSTANCE_ID --region $REGION
    aws ec2 wait instance-stopped --instance-ids $INSTANCE_ID --region $REGION

    # Remove EIPs
    for EIP in $EIPS; do
        aws ec2 release-address --allocation-id $EIP --region $REGION
    done

    # Detach and delete EBS Volumes
    for VOL in $VOLUMES; do
        aws ec2 detach-volume --volume-id $VOL --region $REGION
        aws ec2 delete-volume --volume-id $VOL --region $REGION
    done

    # Delete ENIs
    for ENI in $ENIS; do
        aws ec2 delete-network-interface --network-interface-id $ENI --region $REGION
    done

    # Delete Security Groups (skip default)
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

    # Terminate instance
    aws ec2 terminate-instances --instance-ids $INSTANCE_ID --region $REGION
    aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID --region $REGION

    echo "=== Decommission completed for $INSTANCE_ID ==="
else
    echo "=== Dry Run Mode: No resources deleted ==="
fi
