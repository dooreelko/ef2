#!/bin/bash 

set -euo pipefail
DEBUG=${DEBUG:-}
if [ -n "$DEBUG" ]; then
    set -x
fi

# UBUNTU_AMI_OWNER_ID='099720109477'
AWS_AMI_OWNER_ID='137112412989'
AMI_OWNER_ID="${EF2_AMI_OWNER_ID:-$AWS_AMI_OWNER_ID}"

export AWS_PAGER=''

PROJ=$(basename "$PWD")
DUR='4'
SIZE='60'
ROOT_SIZE='20'
TYPE='t4g.large'
ARCH='x86_64'
SSM_ARCH='amd64'
KEY="$USER"
LOCAL_KEY="$HOME/.ssh/id_rsa.pub"
JUST_CONNECT=''
LIST=''
PORT_FORWARD=''
MOUNT=''

args=$(getopt p:d:r:s:t:k:f:m:chvl "$@")

set -- $args
while true; do
    case $1 in
      (-p)   PROJ=$2; shift 2;;
      (-d)   DUR=$2; shift 2;;
      (-r)   ROOT_SIZE=$2; shift 2;;
      (-s)   SIZE=$2; shift 2;;
      (-t)   TYPE=$2; shift 2;;
      (-k)   LOCAL_KEY=$2; shift 2;;
      (-f)   PORT_FORWARD=$2; shift 2;;
      (-m)   MOUNT=$2; shift 2;;
      (-c)   JUST_CONNECT='aye';
                shift 1;;
      (-v)   DEBUG='aye';
                shift 1;;
      (-l)   LIST='aye';
                shift 1;;
      (-h)  
            echo 'ef2 - start an efemeral ec2 instance in the default VPC that will automatically
shutdown after a time.

    The instance will have an additional persistent EBS volume created and attached so next time
    you run it for the same project and size, the existing volume will be attached and mounted
    under /work

    The AMI for the instance will be chosen based on (in order of priority):
    - There is an AMI in the current account for this architecture tagged with current project
    - newest linux image from EF2_AMI_OWNER_ID environment variable
    - or 137112412989 which would be AWS Amazon Linux (currently 2)
    
    Usage:
        ef2 -p [project] -d [duration] -s [size] -t [instance type] -v

        -p <NAME> project name, defaults to the name of the current directory 
        -d <DUR> duration to live in hours (default 4)
        -r <SIZE> size of an efemeral EBS volume to attach to root (default 20GB)
        -s <SIZE> size of an EBS volume to attach (default 60GB)
        -t <TYPE> instance type (default t4g.large)
        -c just connect to the first instance found
        -f <PORT> forward remote PORT to the same local PORT 
        -m <DIR> mount remote /work to local DIR
        -k path to ssh key to use, defaults to ~/.ssh/id_rsa.pub 
        -l list currently running ef2 instances
        -v verbose output (can also be activated before arg parsing by setting DEBUG=something)

    After the sleep of [duration], the instance will check for file under /home/ssm-user/postpone and, 
    if present, will have an additional delay for number of seconds defined in that file.

    After that shutdown.

    To configure aws profile and region, provide them as AWS_PROFILE and AWS_REGION env variables, e.g.
    AWS_PROFILE=dev AWS_REGION=eu-central-1 ef2 
'
            
            exit 0;;

      (--)   shift; break;;
      (*)    exit 1;;           # error
    esac
done

if [ -n "$DEBUG" ]; then
    set -x
fi

if [ -n "$LIST" ]; then
    echo 'Currently running ef2 instances'
    aws ec2 describe-instances --filters Name=tag-key,Values=ef2 Name=instance-state-name,Values=pending,running \
     | jq -r '.Reservations[].Instances[] | [.InstanceId, .InstanceType, .State.Name, [ .Tags[] | select(.Key != "ef2") | ( .Value ) ]  ] | flatten | @tsv' 

    exit 0
fi

function CurrentInstance() {
    aws ec2 describe-instances --filters Name=tag:proj,Values="$PROJ" Name=instance-state-name,Values=running \
        | jq -r '.Reservations[].Instances[].InstanceId' | head -n1    
}

if [ -n "$JUST_CONNECT" ]; then
    INSTID=$(CurrentInstance)

    if [ -z "$INSTID" ]; then
        echo 'No current instances'
        exit 1
    else
        echo "Connecting to $INSTID"
        aws ssm start-session --target "${INSTID}"
        exit 0
    fi
fi

if [ -n "$PORT_FORWARD" ]; then
    INSTID=$(CurrentInstance)

    if [ -z "$INSTID" ]; then
        echo 'No current instances'
        exit 1
    else        
        echo "Forwarding port $PORT_FORWARD from $INSTID. http://localhost:$PORT_FORWARD"
        aws ssm start-session --target "$INSTID" --document-name AWS-StartPortForwardingSession \
            --parameters "$(jq --null-input --arg port "$PORT_FORWARD" '{portNumber:[$port],localPortNumber:[$port]}' )"
        exit 0
    fi
fi

if [ -n "$MOUNT" ]; then
    INSTID=$(CurrentInstance)

    if [ -z "$INSTID" ]; then
        echo 'No current instances'
        exit 1
    else        
        echo "Mounting $INSTID:/work onto $MOUNT"
        echo "First try with user ubuntu"
        if ! sshfs "ubuntu@$INSTID:/work" "$MOUNT" -f ; then
            echo "second try with user ec2-user"
            sshfs "ec2-user@$INSTID:/work" "$MOUNT" -f 
        fi
        exit 0
    fi
fi

function InstID() {
    aws ec2 describe-instances --filters Name=tag:proj,Values="$PROJ" Name=tag:size,Values="$SIZE" Name=instance-state-name,Values=pending,running \
     | jq -r '.Reservations[].Instances[].InstanceId' | head -n1
}

INSTID=$(InstID)

ARCH=$(aws ec2 describe-instance-types --instance-types "$TYPE" | jq -r '.InstanceTypes[0].ProcessorInfo.SupportedArchitectures[0]')

if [ "$ARCH" = 'arm64' ]; then
    SSM_ARCH='arm64'
fi

DUR=$(( DUR * 60 * 60 ))

EC2_PROFILE_NAME='ef2'

HAS_PROFILE=$(aws iam list-instance-profiles --query "InstanceProfiles[?InstanceProfileName==\`${EC2_PROFILE_NAME}\`].InstanceProfileName" --output text)

if [ -z "$HAS_PROFILE" ]; then
  ASSUME_DOC='{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}'
  echo "Hold on, let's create the instance profile first..."

  aws iam create-role --role-name "${EC2_PROFILE_NAME}" --assume-role-policy-document "${ASSUME_DOC}"
  aws iam attach-role-policy --role-name "${EC2_PROFILE_NAME}" --policy-arn 'arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore'

  aws iam create-instance-profile --instance-profile-name "${EC2_PROFILE_NAME}"
  aws iam add-role-to-instance-profile --instance-profile-name "${EC2_PROFILE_NAME}" --role-name "${EC2_PROFILE_NAME}"
else
  echo "Instance profile found"
fi

function VolID() {
    aws ec2 describe-volumes --filters Name=size,Values="$SIZE" Name=tag:proj,Values="$PROJ" | jq -r '.Volumes[].VolumeId'
}

function VolAZ() {
    aws ec2 describe-volumes --filters Name=size,Values="$SIZE" Name=tag:proj,Values="$PROJ" | jq -r '.Volumes[].AvailabilityZone'
}

VOLID=$(VolID)

AZ='so-wrong-az'

if [ -z "$VOLID" ]; then
    AZ=$(aws ec2 describe-availability-zones | jq -r '.AvailabilityZones[].ZoneName' | sort -R | head -n1)
    aws ec2 create-volume --availability-zone "$AZ" \
        --size "$SIZE" --tag-specifications "ResourceType=volume,Tags=[{Key=proj,Value=$PROJ}]" \
        --volume-type gp3 
    VOLID=$(VolID)
else 
    AZ="$(VolAZ)"
    echo "Reusing existing volume in $AZ"
fi

if [ -z "$VOLID" ]; then
    echo 'Failed creating volume'
    
    exit 1
fi

AMI_ACCOUNT=$(aws sts get-caller-identity | jq -r .Account)

function FindImage() {
    OWNER_ID=$1
    TAG=$2

    FILTER="Name=architecture,Values=$ARCH"
    FILTER_TAG=''

    if [ -n "$TAG" ]; then
        FILTER_TAG="Name=tag:proj,Values=$TAG"
    fi

    aws ec2 describe-images --owners "$OWNER_ID" \
        --filters "$FILTER" "$FILTER_TAG" | \
        jq -r '[.Images | sort_by(.CreationDate) | reverse | .[] | select(.PlatformDetails == "Linux/UNIX")][0].ImageId'
}

IMG=$(FindImage "$AMI_ACCOUNT" "$PROJ")

if [ -z "$IMG" ]; then
    AMI_ACCOUNT=$AMI_OWNER_ID
    IMG=$(FindImage "$AMI_ACCOUNT")
else
    echo "Using project's specialized AMI"
fi

ROOT_DEV=$(aws ec2 describe-images --image-ids "$IMG" | \
    jq -r '.Images[0].RootDeviceName')

if [ "$(aws ec2 describe-key-pairs --filters Name=key-name,Values="$KEY" | jq -r '.KeyPairs | length')" == '0' ]; then

    if [ ! -f "$LOCAL_KEY" ]; then
        echo "$LOCAL_KEY doesn't exist, please create one"
        exit 1
    fi

    echo "Importing ssh key from $LOCAL_KEY under $KEY..."
    aws ec2 import-key-pair --key-name "$KEY" --public-key-material "fileb://$LOCAL_KEY"
fi

VPC_DEFAULT=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)

SG_DEFAULT=$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=${VPC_DEFAULT}" | jq -r '[.SecurityGroups[] | select(.GroupName == "default")] | .[0] | .GroupId')
SUBNET=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_DEFAULT}" Name=availability-zone,Values="$AZ" --query 'Subnets[0].SubnetId' --output text)


# mkfs -t ext4 /dev/sdx
TOSHUTDOWN=$(date -d "today + ${DUR} seconds")

USRDATA="#!/bin/sh 

set -x

which yum && yum install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_${SSM_ARCH}/amazon-ssm-agent.rpm

# systemctl status amazon-ssm-agent

while [ ! -d /home/ssm-user ]; do
    sleep 1
done

mkdir /work
mount /dev/nvme1n1 /work
chown -R ec2-user /work

sleep ${DUR} 

if [ -f '/home/ssm-user/postpone' ]; then
    sleep \$(cat /home/ssm-user/postpone)
fi

shutdown
"

function InstStatus() {
    aws ec2 describe-instance-status --instance-id "${INSTID}" | jq -r '.InstanceStatuses[0].InstanceStatus.Details[0].Status'
}

if [ -z "$INSTID" ]; then

    echo "Starting a new instance for $PROJ:
    $TYPE @ $ARCH, ${SIZE}GB
    Will shut down on $TOSHUTDOWN"

    aws ec2 run-instances --image-id "$IMG" --instance-type "$TYPE" --key-name "$KEY" --security-group-ids "${SG_DEFAULT}" \
        --subnet-id "$SUBNET" --user-data "$USRDATA" --tag-specifications "ResourceType=instance,Tags=[{Key=proj,Value=$PROJ},{Key=size,Value=$SIZE},{Key=ef2,Value=aye},{Key=off,Value=$TOSHUTDOWN}]" \
        --iam-instance-profile Name="${EC2_PROFILE_NAME}" --instance-initiated-shutdown-behavior terminate \
        --block-device-mapping "DeviceName=$ROOT_DEV,Ebs={VolumeSize=$ROOT_SIZE,DeleteOnTermination=true}" > /dev/null

    INSTID=$(InstID)

    echo "Started $INSTID. Waiting for first meaningful state..."

    FIRSTSTATE=$(InstStatus)
    while [ "$FIRSTSTATE" == "null" ]; do
        FIRSTSTATE=$(InstStatus)
        echo -n '.'
    done

    NEWSTATE="$FIRSTSTATE"
    echo "Instance is now in $NEWSTATE"
    aws ec2 attach-volume --device '/dev/sdx' --instance-id "$INSTID" --volume-id "$VOLID"

    while [ "$FIRSTSTATE" == "$NEWSTATE" ]; do
        sleep 10
        NEWSTATE=$(InstStatus)
        echo "${INSTID} is ${NEWSTATE}"
    done
else
    echo "Reusing an existing instance ${INSTID}"
    if [ "$(aws ec2 describe-volumes --volume-ids "$VOLID" | jq -r '.Volumes[0].Attachments | length')" = '0' ]; then
        echo "Reattaching the volume"
        aws ec2 attach-volume --device '/dev/sdx' --instance-id "$INSTID" --volume-id "$VOLID" || true
    fi
fi

echo "Will attempt a connection
    aws ssm start-session --target ${INSTID}
    If you configured ssh with ssm proxy, you can connect as
    ssh ${INSTID}
" 

set +e
MAX_TRIES=10
for x in $(seq 1 "$MAX_TRIES"); do
  if aws ssm start-session --target "${INSTID}"; then
    exit 0
  fi

  echo "Connection attempt $x/$MAX_TRIES failed. Maybe retry."
  sleep 60
done