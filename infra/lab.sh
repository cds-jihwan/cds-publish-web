#!/usr/bin/env bash
set -euo pipefail

region=ap-northeast-2
project=cds-publish-web
tag="Name=tag:Project,Values=$project"
template="$(cd "$(dirname "$0")" && pwd)/web.yml"

aws_cli() {
    aws --region "$region" --no-cli-pager "$@"
}

check_identity() {
    principal=$(aws_cli sts get-caller-identity --query Arn --output text)
    case "$principal" in
        arn:aws:iam::*:user/*|arn:aws:sts::*:assumed-role/*) ;;
        *) echo '실습 전용 IAM 사용자 또는 역할로 접속하세요.' >&2; exit 1 ;;
    esac
}

deploy() {
    public_key=${1:?공개키 파일 경로를 입력하세요.}
    ssh_ip=${2:?SSH에 사용할 공인 IPv4 주소를 입력하세요.}
    ssh-keygen -l -f "$public_key" >/dev/null
    if [[ $(head -c 4 "$public_key") != ssh- ]]; then
        echo '공개키 파일만 입력하세요.' >&2
        exit 1
    fi
    if ! [[ $ssh_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo '공인 IPv4 주소 한 개를 입력하세요.' >&2
        exit 1
    fi

    # 프리 티어 대상 인스턴스와 우분투 이미지만 선택한다.
    instance_type=$(aws_cli ec2 describe-instance-types \
        --filters Name=instance-type,Values=t3.micro Name=free-tier-eligible,Values=true \
        --query 'InstanceTypes[0].InstanceType' --output text)
    ami=$(aws_cli ec2 describe-images --owners 099720109477 \
        --filters 'Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*' \
            Name=state,Values=available Name=free-tier-eligible,Values=true \
        --query 'sort_by(Images, &CreationDate)[-1].ImageId' --output text)
    if [[ $instance_type != t3.micro || $ami != ami-* ]]; then
        echo '서울 리전에서 프리 티어 대상 인스턴스 또는 이미지를 확인하지 못했습니다.' >&2
        exit 1
    fi

    aws_cli cloudformation validate-template --template-body "file://$template" >/dev/null
    aws_cli ec2 import-key-pair --key-name "$project" \
        --public-key-material "fileb://$public_key" \
        --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=$project}]" >/dev/null

    # 생성 실패 시 스택 이벤트를 확인하고 정리 명령을 실행한다.
    aws_cli cloudformation create-stack --stack-name "$project" --template-body "file://$template" \
        --timeout-in-minutes 15 --on-failure ROLLBACK --tags "Key=Project,Value=$project" \
        --parameters "ParameterKey=AmiId,ParameterValue=$ami" \
            "ParameterKey=KeyName,ParameterValue=$project" \
            "ParameterKey=SshCidr,ParameterValue=$ssh_ip/32"
    aws_cli cloudformation wait stack-create-complete --stack-name "$project"
    status
}

status() {
    aws_cli cloudformation describe-stacks --stack-name "$project" \
        --query 'Stacks[0].Outputs[].[OutputKey, OutputValue]' --output table
    aws_cli ec2 describe-instances --filters "$tag" Name=instance-state-name,Values=running \
        --query 'Reservations[].Instances[].[InstanceId, State.Name, PublicIpAddress, BlockDeviceMappings[0].Ebs.VolumeId]' \
        --output table
}

cleanup() {
    aws_cli cloudformation delete-stack --stack-name "$project"
    aws_cli cloudformation wait stack-delete-complete --stack-name "$project"

    key_id=$(aws_cli ec2 describe-key-pairs \
        --filters "$tag" "Name=key-name,Values=$project" \
        --query 'KeyPairs[0].KeyPairId' --output text)
    if [[ $key_id == key-* ]]; then
        aws_cli ec2 delete-key-pair --key-pair-id "$key_id"
    fi

    echo '정리 완료 여부를 확인합니다.'
    echo '삭제 대기 완료, 생성한 스택:'
    aws_cli cloudformation list-stacks --stack-status-filter DELETE_COMPLETE \
        --query "StackSummaries[?StackName=='$project'] | sort_by(@, &DeletionTime)[-1].[StackName,StackStatus,DeletionTime]"
    confirm_absent '종료되지 않은 EC2' ec2 describe-instances \
        --filters "$tag" Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped \
        --query 'Reservations[].Instances[].InstanceId'
    confirm_absent 'EBS' ec2 describe-volumes --filters "$tag" --query 'Volumes[].VolumeId'
    confirm_absent 'Elastic IP' ec2 describe-addresses --filters "$tag" --query 'Addresses[].AllocationId'
    confirm_absent '인터넷 게이트웨이' ec2 describe-internet-gateways \
        --filters "$tag" --query 'InternetGateways[].InternetGatewayId'
    confirm_absent '라우팅 테이블' ec2 describe-route-tables --filters "$tag" --query 'RouteTables[].RouteTableId'
    confirm_absent '서브넷' ec2 describe-subnets --filters "$tag" --query 'Subnets[].SubnetId'
    confirm_absent '보안 그룹' ec2 describe-security-groups --filters "$tag" --query 'SecurityGroups[].GroupId'
    confirm_absent 'VPC' ec2 describe-vpcs --filters "$tag" --query 'Vpcs[].VpcId'
    confirm_absent '키 페어' ec2 describe-key-pairs --filters "$tag" --query 'KeyPairs[].KeyName'
}

confirm_absent() {
    label=$1
    shift
    remaining=$(aws_cli "$@" --output json)
    printf '%s %s\n' "$label" "$remaining"
    [[ $remaining == '[]' ]]
}

case "${1:-}" in
    deploy) check_identity; shift; deploy "$@" ;;
    status) check_identity; status ;;
    cleanup) check_identity; cleanup ;;
    *)
        echo "사용법: $0 deploy <공개키 경로> <공인 IPv4> | status | cleanup" >&2
        exit 1
        ;;
esac
