#!/bin/sh -e
# Build the ImageMagick Lambda layer on a matching-arch AL2023 EC2 instance,
# then copy the zip back: rsync the sources up and run the identical native
# build, just on a box of the target architecture.
#
# Because an AL2023 EC2 instance IS the same OS as the Lambda runtime, we run
# the native Makefile directly on it -- no podman, no QEMU. Each architecture
# is built on its own hardware (arm64 layer on a Graviton box, amd64 layer on
# an Intel/AMD box).
#
# The instance is one-shot: launched, built on, copied from, then terminated
# (an EXIT trap tears it down even on failure).
#
# POSIX sh (no bashisms), so it runs under the same /bin/sh everywhere.
#
# Usage:
#   AWS_PROFILE=<dev-profile> scripts/build-on-ec2.sh <arm64|amd64>
#
# Env overrides:
#   AWS_PROFILE        (required) AWS CLI profile -- use your DEV account
#   AWS_DEFAULT_REGION default us-east-1
#   INSTANCE_TYPE      default c7g.large (arm64) / c7i.large (amd64)
#   VPC_ID             default: the account's sole VPC (required if >1 exists)
#   SUBNET_ID          default: a public subnet in that VPC
#   YES=1              skip the cost-confirmation prompt (for automation)
#   KEEP_INSTANCE=1    leave the instance running (debugging); prints the id

ARCH="${1:-}"
# RATE is the approximate on-demand price/hour in us-east-1, used only for the
# cost estimate shown before launch. Prices change; verify if it matters.
case "$ARCH" in
    arm64)  DEFAULT_TYPE="c7g.large"; AMI_ARCH="arm64";  RATE="0.073" ;;
    amd64)  DEFAULT_TYPE="c7i.large"; AMI_ARCH="x86_64"; RATE="0.089" ;;
    *)
        echo "usage: AWS_PROFILE=<profile> $0 <arm64|amd64>" >&2
        exit 2
        ;;
esac

if [ -z "${AWS_PROFILE:-}" ]; then
    echo "error: AWS_PROFILE is required (use your DEV account profile)." >&2
    exit 2
fi

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
INSTANCE_TYPE="${INSTANCE_TYPE:-$DEFAULT_TYPE}"
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)

KEY_NAME="im-lambda-build"
KEY_FILE="$HOME/.ssh/$KEY_NAME"
SG_NAME="im-lambda-build"
TAG="imagemagick-lambda-build"
REMOTE_USER="ec2-user"
REMOTE_DIR="/home/ec2-user/imagemagick-aws-lambda-2"
# Name the artifact with the AWS architecture name (arm64 / x86_64), which is
# what release consumers and `--compatible-architectures` expect -- not the
# Docker/OCI "amd64".
OUT_ZIP="$REPO_ROOT/imagemagick-7.1.2-al2023-$AMI_ARCH.zip"

# Native build dependencies -- the same set the Dockerfile installs for the
# local podman build, since here we run that build directly on the box. (curl
# is already present on AL2023.) rsync is needed for the file transfer.
DEPS="gcc gcc-c++ make cmake autoconf automake libtool pkgconfig \
tar gzip bzip2 xz zip zlib-devel rsync"

aws_cmd() { aws --profile "$AWS_PROFILE" --region "$REGION" "$@"; }

START_TS=$(date +%s)
echo "==> Building $ARCH layer on $INSTANCE_TYPE (profile=$AWS_PROFILE region=$REGION)"

# --- credentials sanity check --------------------------------------------
if ! aws_cmd sts get-caller-identity >/dev/null 2>&1; then
    echo "error: AWS credentials for profile '$AWS_PROFILE' are not valid." >&2
    echo "  Try: aws sso login --profile $AWS_PROFILE" >&2
    exit 1
fi

# --- cost estimate + confirmation ----------------------------------------
# The only real cost is the on-demand instance; the 20 GB gp3 volume and the
# ~27 MB egress round to a cent or two. Observed build time is ~8 min (arm64
# 7m54s, amd64 6m31s); instances are billed per-second. Estimate at ~8 min,
# with a generous 20 min ceiling.
EST_COST=$(awk "BEGIN { printf \"%.2f\", 8  / 60 * $RATE }")
MAX_COST=$(awk "BEGIN { printf \"%.2f\", 20 / 60 * $RATE }")
echo ""
echo "This launches one on-demand $INSTANCE_TYPE in $REGION (~\$$RATE/hr, billed"
echo "per-second) for the ~8 min build plus a 20 GB gp3 volume, then terminates it."
echo "Estimated cost: ~US\$$EST_COST per run; under US\$$MAX_COST even at 20 min."
if [ "${YES:-0}" != "1" ]; then
    printf 'Proceed? [y/N] '
    read -r reply
    case "$reply" in
        [Yy] | [Yy][Ee][Ss]) ;;
        *) echo "Aborted (nothing created)."; exit 0 ;;
    esac
fi

# --- ssh key pair --------------------------------------------------------
if [ ! -f "$KEY_FILE" ]; then
    echo "Generating SSH key $KEY_FILE..."
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "$KEY_NAME" >/dev/null
fi
if [ "$(aws_cmd ec2 describe-key-pairs --key-names "$KEY_NAME" \
        --query 'KeyPairs[0].KeyName' --output text 2>/dev/null)" != "$KEY_NAME" ]; then
    echo "Importing key pair '$KEY_NAME'..."
    aws_cmd ec2 import-key-pair --key-name "$KEY_NAME" \
        --public-key-material "fileb://${KEY_FILE}.pub" >/dev/null
fi

# --- VPC + public subnet -------------------------------------------------
# This account has no default VPC, so we resolve one explicitly. Override with
# VPC_ID / SUBNET_ID if the auto-detection picks the wrong one.
if [ -z "${VPC_ID:-}" ]; then
    VPC_COUNT=$(aws_cmd ec2 describe-vpcs --query 'length(Vpcs)' --output text)
    if [ "$VPC_COUNT" = "0" ]; then
        echo "error: no VPCs in this account/region. Create one (with a public" >&2
        echo "  subnet + internet gateway), then set VPC_ID and SUBNET_ID." >&2
        exit 1
    fi
    if [ "$VPC_COUNT" != "1" ]; then
        echo "error: found $VPC_COUNT VPCs; set VPC_ID to choose one:" >&2
        aws_cmd ec2 describe-vpcs \
            --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,Name:Tags[?Key==`Name`]|[0].Value}' \
            --output table >&2
        exit 1
    fi
    VPC_ID=$(aws_cmd ec2 describe-vpcs --query 'Vpcs[0].VpcId' --output text)
fi
echo "Using VPC $VPC_ID"

if [ -z "${SUBNET_ID:-}" ]; then
    # Prefer a subnet that auto-assigns public IPs -- by convention the one
    # wired to an internet gateway, which we need for SSH and package/source
    # downloads.
    SUBNET_ID=$(aws_cmd ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$VPC_ID" "Name=map-public-ip-on-launch,Values=true" \
        --query 'Subnets[0].SubnetId' --output text)
    if [ "$SUBNET_ID" = "None" ] || [ -z "$SUBNET_ID" ]; then
        echo "error: no public subnet in $VPC_ID; set SUBNET_ID to a public one." >&2
        exit 1
    fi
fi
echo "Using subnet $SUBNET_ID"

# --- security group: SSH from this machine's public IP only --------------
MY_IP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
SG_ID=$(aws_cmd ec2 describe-security-groups \
    --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)
if [ -z "$SG_ID" ] || [ "$SG_ID" = "None" ]; then
    echo "Creating security group '$SG_NAME'..."
    SG_ID=$(aws_cmd ec2 create-security-group --group-name "$SG_NAME" \
        --description "one-shot ImageMagick layer builds" \
        --vpc-id "$VPC_ID" \
        --query 'GroupId' --output text)
fi
# Ensure an ingress rule for the current IP (idempotent; ignore duplicates).
aws_cmd ec2 authorize-security-group-ingress --group-id "$SG_ID" \
    --protocol tcp --port 22 --cidr "$MY_IP/32" >/dev/null 2>&1 || true

# --- latest AL2023 AMI for this arch (SSM public parameter) --------------
AMI_ID=$(aws_cmd ssm get-parameters \
    --names "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-$AMI_ARCH" \
    --query 'Parameters[0].Value' --output text)
echo "Using AMI $AMI_ID"

# --- launch --------------------------------------------------------------
INSTANCE_ID=$(aws_cmd ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --network-interfaces "DeviceIndex=0,SubnetId=$SUBNET_ID,Groups=$SG_ID,AssociatePublicIpAddress=true,DeleteOnTermination=true" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3}' \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$TAG},{Key=Project,Value=imagemagick-aws-lambda-2}]" \
    --query 'Instances[0].InstanceId' --output text)
echo "Launched $INSTANCE_ID"

terminate() {
    rc=$?
    if [ "${KEEP_INSTANCE:-0}" = "1" ]; then
        echo "KEEP_INSTANCE=1; leaving $INSTANCE_ID running at ${INSTANCE_IP:-?}"
        echo "  Terminate: aws --profile $AWS_PROFILE --region $REGION ec2 terminate-instances --instance-ids $INSTANCE_ID"
    else
        echo "Terminating $INSTANCE_ID..."
        aws_cmd ec2 terminate-instances --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi
    return $rc
}
trap terminate EXIT

echo "Waiting for instance to be running..."
aws_cmd ec2 wait instance-running --instance-ids "$INSTANCE_ID"
INSTANCE_IP=$(aws_cmd ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
echo "Instance IP: $INSTANCE_IP"

SSH="ssh -i $KEY_FILE -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o LogLevel=ERROR"

echo "Waiting for SSH..."
i=0
until $SSH "$REMOTE_USER@$INSTANCE_IP" true 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 30 ] || { echo "SSH never came up" >&2; exit 1; }
    sleep 10
done

echo "Installing build tooling..."
$SSH "$REMOTE_USER@$INSTANCE_IP" \
    "sudo dnf install -y $DEPS >/dev/null && sudo shutdown -h +60 || true"

echo "Syncing repo to instance..."
rsync -az --delete \
    --exclude='.git/' \
    --exclude='build/' \
    --exclude='*.zip' \
    -e "$SSH" \
    "$REPO_ROOT/" "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/"

echo "Building layer natively on instance..."
$SSH "$REMOTE_USER@$INSTANCE_IP" "
    set -e
    # ImageMagick installs to /opt (its baked-in config path). /opt is empty on
    # a fresh AL2023 box; hand it to our user so make can write it without sudo.
    sudo mkdir -p /opt && sudo chown \$(id -u):\$(id -g) /opt
    cd $REMOTE_DIR
    make imagemagick-layer.zip
"

echo "Copying layer back to $OUT_ZIP..."
rsync -az -e "$SSH" \
    "$REMOTE_USER@$INSTANCE_IP:$REMOTE_DIR/imagemagick-layer.zip" "$OUT_ZIP"

ELAPSED=$(( $(date +%s) - START_TS ))
echo ""
echo "==> Done in $((ELAPSED / 60))m $((ELAPSED % 60))s. $ARCH layer: $OUT_ZIP"
echo "    sha256: $(shasum -a 256 "$OUT_ZIP" | cut -d' ' -f1)"
