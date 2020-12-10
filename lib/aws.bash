[[ -z ${LIB_COMMON_LOADED} ]] && { source "${LIB_DIR:-lib}/common.bash"; }
export LIB_AWS_LOADED=1
export SERVICE_ACCOUNT=0

check_envvar AWS_DEFAULT_REGION O eu-central-1

aws_update_service() {
  check_envvar AWS_DEFAULT_REGION R
  [[ -z ${1} || -z ${2} || -z ${3} || -z ${4} || -z ${5} ]] && \
    fail "aws_update_service aws_ecs_cluster_name aws_ecs_service_name aws_ecs_task_family image_tag image_basename"
  local aws_ecs_cluster_name=${1}; shift
  local aws_ecs_service_name=${1}; shift
  local aws_ecs_task_family=${1}; shift
  local image_tag=${1}; shift
  local image_basename=${1}; shift

  info "Creating task definition file for ${aws_ecs_task_family} with version ${image_tag}"
  aws_ecs_create_task_definition_file "${aws_ecs_task_family}" "${image_basename}:${image_tag}"
  success "Task definition file successfully created"

  info "Registering task definition file for ${aws_ecs_task_family} with version ${image_tag}"
  aws_ecs_register_taskdefinition "${aws_ecs_task_family}"
  success "Task definition successfully registered"

  info "Update service ${aws_ecs_service_name} in cluster ${aws_ecs_cluster_name}"
  aws ecs update-service --cluster "${aws_ecs_cluster_name}" \
                         --task-definition "${AWS_ECS_NEW_TASK_DEFINITION_ARN}" \
                         --force-new-deployment \
                         --service "${aws_ecs_service_name}"
  success "Successfully updated service ${aws_ecs_service_name} in cluster ${aws_ecs_cluster_name}"
}


#######################################
# Create a task definition file based on
# the current task definition, replacing
# the image name with the new version
#
# Globals:
#
# Arguments:
#   Image Name: The name of the image, including tag
#
# Returns:
#   None
#######################################
aws_ecs_create_task_definition_file() {
  check_command aws || install_awscli
  check_command jq || install_sw jq
  [[ -z ${1} || -z ${2} ]] && fail "aws_ecs_create_task_definition_file aws_ecs_task_family docker_image"
  local aws_ecs_task_family=${1}; shift
  local aws_image=${1}; shift

  aws ecs describe-task-definition --task-definition "${aws_ecs_task_family}" \
                                   --query 'taskDefinition' | \
                                   jq "del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities)" | \
                                   jq ".containerDefinitions[0].image = \"${aws_image}\"" > /taskdefinition.json

  if is_debug_enabled; then
    debug "Content of task definition file -- START"
    cat /taskdefinition.json
    debug "Content of task definition file -- END"
  fi
}

aws_ecs_register_taskdefinition() {
  # Limitation: only supports task definitions with 1 containerDefinition
  check_command aws || install_awscli
  check_command jq || install_sw jq
  [[ -z ${1} ]] && fail "aws_ecs_create_task_definition_file aws_ecs_task_family docker_image"
  local aws_ecs_task_family=${1}; shift
  local RESULT

  info "Registering a new task definition for ${aws_ecs_task_family}"
  RESULT=$(aws ecs register-task-definition --family "${aws_ecs_task_family}" --cli-input-json file:///taskdefinition.json)
  AWS_ECS_NEW_TASK_DEFINITION_ARN=$(echo "${RESULT}" | jq -r '.taskDefinition.taskDefinitionArn')
  success "Successfully registered new task definition for ${aws_ecs_task_family}"
  info "New task definition ARN is ${AWS_ECS_NEW_TASK_DEFINITION_ARN}"
}

_indirection() {
  local basename_var=${1}
  local account=${2}
  local var="${basename_var}_${account}"
  echo "${!var}"
}

#######################################
#
#
aws_set_service_account_config() {
  local account

  [[ -z ${AWS_CONFIG_BASEDIR} ]] && AWS_CONFIG_BASEDIR=~/.aws
  if [[ -n ${SA_ACCOUNT_LIST} ]]; then
    check_command aws || install_awscli
    mkdir -p "${AWS_CONFIG_BASEDIR}"
    {
      for account in ${SA_ACCOUNT_LIST}; do
        echo "[${account}_SOURCE]"
        echo "aws_access_key_id=$(_indirection ACCESS_KEY_ID ${account})"
        echo "aws_secret_access_key=$(_indirection SECRET_ACCESS_KEY ${account})"
        echo "region=eu-central-1"
        echo ""
      done
    } > ${AWS_CONFIG_BASEDIR}/credentials
    {
      (( counter = 0 )) || true
      for account in ${SA_ACCOUNT_LIST}; do
        local role_arn
        local account_id

        role_arn="$(_indirection ROLE_TO_ASSUME ${account})"
        account_id="$(_indirection ACCOUNT_ID ${account})"

        if [[ -z ${role_arn} ]]; then
          role_arn="arn:aws:iam::${account_id}:role/ServiceAccount/cicd"
        fi
        if [[ ${counter} -eq 0 ]]; then
          echo "[profile default]"
          echo "source_profile=${account}_SOURCE"
          echo "role_arn=${role_arn}"
          echo ""
        fi
        echo "[profile ${account}]"
        echo "source_profile=${account}_SOURCE"
        echo "role_arn=${role_arn}"
        echo ""
        (( counter++ )) || true
      done
    } > ${AWS_CONFIG_BASEDIR}/config

    SERVICE_ACCOUNT=1
    aws sts get-caller-identity || true
  fi
}

aws_set_codeartifact_token() {
  if [[ -n ${AWS_CODEARTIFACT_DOMAIN} && -n ${AWS_CODEARTIFACT_DOMAIN_OWNER} ]]; then
    info "Trying to get the CODEARTIFACT_AUTH_TOKEN"
    check_command aws || install_awscli
    if CODEARTIFACT_AUTH_TOKEN=$(aws codeartifact get-authorization-token  \
                                --domain "${AWS_CODEARTIFACT_DOMAIN}" \
                                --domain-owner "${AWS_CODEARTIFACT_DOMAIN_OWNER}" \
                                --query authorizationToken \
                                --output text); then
      success "Successfully retrieved CODEARTIFACT_AUTH_TOKEN"
      export CODEARTIFACT_AUTH_TOKEN
    else
      error "Unable to get CODEARTIFACT_AUTH_TOKEN for:"
      error "  Domain:       ${AWS_CODEARTIFACT_DOMAIN}"
      error "  Domain Owner: ${AWS_CODEARTIFACT_DOMAIN_OWNER}"
      fail "Exiting ..."
    fi
  else
    info "Skipping CODEARTIFACT_AUTH_TOKEN generation because AWS_CODEARTIFACT_DOMAIN"
    info "  and/or AWS_CODEARTIFACT_DOMAIN_OWNER are not set"
  fi
}