#!/usr/bin/env bash
# MIT License
#
# Copyright (c) 2022, N. Harris Computer Corporation
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

###############################################################################
# Function definitions start here                                             #
###############################################################################

function deleteContainer() {
  local container_name_or_id="$1"
  local container_id
  local container_name
  local max_retries=10

  # identify if name or id supplied as $1 exists
  container_id="$(docker ps -aq -f network="${DOMAIN_NAME}" -f name="${container_name_or_id}")"
  if [[ -z "${container_id}" ]]; then
    container_id="$(docker ps -aq -f network="${DOMAIN_NAME}" -f id="${container_name_or_id}")"
    if [[ -z "${container_id}" ]]; then
      printInfo "${container_name_or_id} does NOT exist"
      return 0
    fi
  fi
  container_name="$(docker ps -aq --format "{{.Names}}" -f id="${container_id}")"
  print "Stopping ${container_name} container"
  while ! docker stop "${container_name_or_id}"; do
    if (( "${max_retries}" == 0 )); then
      printErrorAndExit "Unable to stop container '${container_name}', exiting script"
    else
      echo "[WARN] Having issues stopping container '${container_name}', retrying..."
      ((max_retries="${max_retries}"-1))
    fi
    sleep 1s
  done
  print "Deleting ${container_name} container"
  docker rm "${container_name_or_id}"
}

function forceDeleteContainer() {
  local container_name_or_id="$1"
  
  docker rm -f "${container_name_or_id}" &>/dev/null
}

function checkDeploymentIsLive() {
  local config_name="$1"
  local live_flag="true"
  local container_names=("${ZK1_CONTAINER_NAME}" "${SOLR1_CONTAINER_NAME}" "${LIBERTY1_CONTAINER_NAME}")

  if [[ "${DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    case "${DB_DIALECT}" in
      db2)
        container_names+=("${DB2_SERVER_CONTAINER_NAME}")
        ;;
      sqlserver)
        container_names+=("${SQL_SERVER_CONTAINER_NAME}")
        ;;
    esac
  fi

  print "Checking '${config_name}' deployment is live"
  for container_name in "${container_names[@]}"; do
    local container_id
    container_id="$(docker ps -a -q -f network="${DOMAIN_NAME}" -f name="${container_name}" -f "status=running")"
    if [[ -z "${container_id}" ]]; then
      live_flag="false"
      printInfo "${container_id} is not in the 'running' state"
    fi
  done
  if [[ "${live_flag}" == "false" ]]; then
    printErrorAndExit "Deployment is NOT live"
  else
    echo "Deployment is live"
  fi
}

function clearLibertyValidationLog() {
  docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c 'rm /logs/opal-services/IBM_i2_Validation.log > /dev/null 2>&1 || true'
  docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c 'rm /logs/opal-services/IBM_i2_Status.log > /dev/null 2>&1 || true'
}

function replaceXmlElementWithHeredoc() {
  local xml_element="$1"
  local heredoc_file_path="$2"
  local log4j2_file_path="$3"
  # replace string with contents of a heredoc file, sed explantation:
  # line 1: when you find ${xml_element}
  # line 2: remove ${xml_element}
  # line 3: replace with the content of a file
  # line 4: delete the extra new line
  sed -i "/${xml_element}/{
          s/${xml_element}//g
          r ${heredoc_file_path}
          d
  }" "${log4j2_file_path}"
}

function appendLoggingXmlElementWithHeredoc() {
  local loggers_name="$1"
  local loggers_heredoc_file_path="$2"
  local loggers_level="$3"
  local loggers_appender_ref="$4"
  local tmp_log4j2_file_path="/tmp/log4j2.xml"

  if grep -q -E -o -m 1 "${loggers_name}" < "${tmp_log4j2_file_path}"; then
    # Force set logging level
    sed -i -E "s~(${loggers_name} level=\")[^\"]+~\1${loggers_level}~g" "${tmp_log4j2_file_path}"
    # Append AppenderRef for logger
    sed -i -E "/${loggers_name}/a \      <AppenderRef ref=\"${loggers_appender_ref}\" \/>" "${tmp_log4j2_file_path}"
  else
    replaceXmlElementWithHeredoc "<\/Loggers>" "${loggers_heredoc_file_path}" "${tmp_log4j2_file_path}"
  fi
}

function addConfigAdmin() {
  printInfo "Adding config dev environment administrator user to the system"
  addConfigAdminToUserRegistry
  addConfigAdminToCommandAccessControl
}

function addConfigAdminToSecuritySchema() {
  local security_schema_file_path="${GENERATED_LOCAL_CONFIG_DIR}/security-schema.xml"
  local security_schema_container_path="liberty/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/classes"
  local security_dimension_ids dimension_id
  local security_dimension_values dimension_value
  declare -A security_value_map

  readarray -t security_dimension_ids < <(xmlstarlet sel -t -v "/tns:SecuritySchema/SecurityDimensions/AccessSecurityDimensions/Dimension/@Id" "${security_schema_file_path}")
  for dimension_id in "${security_dimension_ids[@]}"; do
    readarray -t security_dimension_values < <(xmlstarlet sel -t -v "/tns:SecuritySchema/SecurityDimensions/AccessSecurityDimensions/Dimension[@Id='${dimension_id}']/DimensionValue/@Id" "${security_schema_file_path}")
    security_value_map[${dimension_id}]="${security_dimension_values[*]}"
  done

  xmlstarlet edit -L \
    --subnode "/tns:SecuritySchema/SecurityPermissions" --type elem -n "GroupPermissions" \
    --insert  "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]" --type attr -n "UserGroup" --value "${I2_ANALYZE_ADMIN}"  \
    "${security_schema_file_path}"

  for dimension_id in "${!security_value_map[@]}"; do
    IFS=' ' read -r -a dimension_values <<<"${security_value_map[${dimension_id}]}"
    xmlstarlet edit -L \
      --subnode "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]" --type elem -n "Permissions" \
      --insert  "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]/Permissions[last()]" --type attr -n "Dimension" --value "${dimension_id}" \
      "${security_schema_file_path}"

    for dimension_value in "${dimension_values[@]}"; do
      xmlstarlet edit -L \
        --subnode "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]/Permissions[last()]" --type elem -n "Permission" \
        --insert  "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]/Permissions[last()]/Permission[last()]" --type attr -n "DimensionValue" --value "${dimension_value}" \
        --insert  "/tns:SecuritySchema/SecurityPermissions/GroupPermissions[last()]/Permissions[last()]/Permission[last()]" --type attr -n "Level" --value "UPDATE" \
        "${security_schema_file_path}"
    done
  done
}

function addConfigAdminToCommandAccessControl() {
  local tmp_command_access_control_file_path="/tmp/command-access-control.xml"
  local command_access_control_file_path="${LOCAL_USER_CONFIG_DIR}/command-access-control.xml"
  local command_access_control_container_path="liberty/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/classes"

  # Create tmp command-access-control file
  cp "${command_access_control_file_path}" "${tmp_command_access_control_file_path}"

  xmlstarlet edit -L \
    --subnode "/tns:CommandAccessControl" --type elem -n "CommandAccessPermissions" \
    --insert "/tns:CommandAccessControl/CommandAccessPermissions[last()]" --type attr -n "UserGroup" --value "${I2_ANALYZE_ADMIN}" \
    "${tmp_command_access_control_file_path}"

  for permission in "${ADMIN_ACCESS_PERMISSIONS[@]}"; do
    xmlstarlet edit -L \
      --subnode "/tns:CommandAccessControl/CommandAccessPermissions[last()]" --type elem -n "Permission" \
      --insert "/tns:CommandAccessControl/CommandAccessPermissions[last()]/Permission[last()]" --type attr -n "Value" --value "${permission}" \
      "${tmp_command_access_control_file_path}"
  done

  # Copy modified file to container
  docker cp "${tmp_command_access_control_file_path}" "${LIBERTY1_CONTAINER_NAME}:${command_access_control_container_path}"
}

function addConfigAdminToUserRegistry() {
  local tmp_user_registry_file_path="/tmp/user.registry.xml"
  local user_registry_file_path="${LOCAL_USER_CONFIG_DIR}/user.registry.xml"
  local user_registry_container_path="liberty/wlp/usr/shared/config"
  local app_admin_password

  # Create tmp user.registry file
  cp "${user_registry_file_path}" "${tmp_user_registry_file_path}"

  app_admin_password=$(getApplicationAdminPassword)
  xmlstarlet edit -L \
    --subnode "/server/basicRegistry" --type elem -n "user" \
    --insert "/server/basicRegistry/user[last()]" --type attr -n "name" --value "${I2_ANALYZE_ADMIN}" \
    --insert "/server/basicRegistry/user[last()]" --type attr -n "password" --value "${app_admin_password}" \
    --subnode "/server/basicRegistry" --type elem -n "group" \
    --insert "/server/basicRegistry/group[last()]" --type attr -n "name" --value "${I2_ANALYZE_ADMIN}" \
    --subnode "/server/basicRegistry/group[@name='${I2_ANALYZE_ADMIN}']" --type elem -n "member" \
    --insert "/server/basicRegistry/group[@name='${I2_ANALYZE_ADMIN}']/member[last()]" --type attr -n "name" --value "${I2_ANALYZE_ADMIN}" \
    "${tmp_user_registry_file_path}"

  # Copy modified registry to container
  docker cp "${tmp_user_registry_file_path}" "${LIBERTY1_CONTAINER_NAME}:${user_registry_container_path}"
}

function updateLog4jFile() {
  local tmp_log4j2_file_path="/tmp/log4j2.xml"
  local log4j2_file_path="${LOCAL_USER_CONFIG_DIR}/log4j2.xml"
  local log4j2_container_path="liberty/wlp/usr/servers/defaultServer/apps/opal-services.war/WEB-INF/classes"
  local properties_heredoc_file_path="/tmp/properties_heredoc"
  local appenders_heredoc_file_path="/tmp/appenders_heredoc"
  local loggers_heredoc_console_file_path="/tmp/loggers_console_heredoc"
  local loggers_heredoc_availability_file_path="/tmp/loggers_availability_heredoc"
  local loggers_heredoc_mapping_file_path="/tmp/loggers_mapping_heredoc"
  local loggers_heredoc_lifecycle_file_path="/tmp/loggers_lifecycle_heredoc"
  local loggers_heredoc_statehandler_file_path="/tmp/loggers_statehandler_heredoc"
  local loggers_console_name='<Logger name="com.i2group.apollo.common.toolkit.internal.ConsoleLogger"'
  local loggers_console_level="WARN"
  local loggers_console_appender_ref="i2_VALIDATIONLOG"
  local loggers_availability_name='<Logger name="com.i2group.disco.sync.ComponentAvailabilityCheck"'
  local loggers_availability_level="WARN"
  local loggers_availability_appender_ref="i2_VALIDATIONLOG"
  local loggers_mapping_name='<Logger name="com.i2group.opal.daod.mapping.internal"'
  local loggers_mapping_level="WARN"
  local loggers_mapping_appender_ref="i2_VALIDATIONLOG"
  local loggers_lifecycle_name='<Logger name="com.i2group.disco.servlet.ApplicationLifecycleManager"'
  local loggers_lifecycle_level="INFO"
  local loggers_lifecycle_appender_ref="i2_STATUSLOG"
  local loggers_statehandler_name='<Logger name="com.i2group.disco.sync.ApplicationStateHandler"'
  local loggers_statehandler_level="INFO"
  local loggers_statehandler_appender_ref="i2_STATUSLOG"

  printInfo "Updating Log4j2.xml file"

  # Create tmp log4j2 file
  cp "${log4j2_file_path}" "${tmp_log4j2_file_path}"

  # Remove any new line breaking xml element
  xmlstarlet edit -L -u '//text()' -x 'normalize-space()' "${tmp_log4j2_file_path}"

  # Creating heredocs
  cat > "${properties_heredoc_file_path}" <<'EOF'
    <Property name="i2_rootDir">${sys:apollo.log.dir}/opal-services</Property>
    <Property name="i2_validationMessagesPatternLayout">%d - %m%n</Property>
    <Property name="i2_archiveDir">${i2_rootDir}/${archiveDirFormat}</Property>
    <Property name="i2_archiveFileDateFormat">%d{dd-MM-yyyy}-%i</Property>
    <Property name="i2_triggerSize">1MB</Property>
    <Property name="i2_maxRollover">10</Property>
  </Properties>
EOF
  cat > "${appenders_heredoc_file_path}" <<'EOF'
    <RollingFile name="i2_VALIDATIONLOG" append="true">
      <FileName>${i2_rootDir}/IBM_i2_Validation.log</FileName>
      <FilePattern>"${i2_archiveDir}/IBM_i2_Validation-${i2_archiveFileDateFormat}.log</FilePattern>
      <PatternLayout charset="UTF-8" pattern="${i2_validationMessagesPatternLayout}" />
      <Policies>
        <SizeBasedTriggeringPolicy size="${i2_triggerSize}" />
      </Policies>
      <DefaultRolloverStrategy max="${i2_maxRollover}" />
    </RollingFile>
    <RollingFile name="i2_STATUSLOG" append="true">
      <FileName>${i2_rootDir}/IBM_i2_Status.log</FileName>
      <FilePattern>"${i2_archiveDir}/IBM_i2_Status-${i2_archiveFileDateFormat}.log</FilePattern>
      <PatternLayout charset="UTF-8" pattern="${i2_validationMessagesPatternLayout}" />
      <Policies>
        <SizeBasedTriggeringPolicy size="${i2_triggerSize}" />
      </Policies>
      <DefaultRolloverStrategy max="${i2_maxRollover}" />
    </RollingFile>
  </Appenders>
EOF
  cat > "${loggers_heredoc_console_file_path}" <<'EOF'
    <!-- i2Analyze Validation Logging -->
    <Logger name="com.i2group.apollo.common.toolkit.internal.ConsoleLogger" level="WARN" additivity="true">
      <AppenderRef ref="i2_VALIDATIONLOG" />
    </Logger>
  </Loggers>
EOF
  cat > "${loggers_heredoc_availability_file_path}" <<'EOF'
    <Logger name="com.i2group.disco.sync.ComponentAvailabilityCheck" level="WARN" additivity="true">
      <AppenderRef ref="i2_VALIDATIONLOG" />
    </Logger>
  </Loggers>
EOF
  cat > "${loggers_heredoc_mapping_file_path}" <<'EOF'
    <Logger name="com.i2group.opal.daod.mapping.internal" level="WARN" additivity="true">
      <AppenderRef ref="i2_VALIDATIONLOG" />
    </Logger>
  </Loggers>
EOF
  cat > "${loggers_heredoc_lifecycle_file_path}" <<'EOF'
    <Logger name="com.i2group.disco.servlet.ApplicationLifecycleManager" level="INFO" additivity="true">
      <AppenderRef ref="i2_STATUSLOG" />
    </Logger>
  </Loggers>
EOF
  cat > "${loggers_heredoc_statehandler_file_path}" <<'EOF'
    <Logger name="com.i2group.disco.sync.ApplicationStateHandler" level="INFO" additivity="true">
      <AppenderRef ref="i2_STATUSLOG" />
    </Logger>
  </Loggers>
EOF

  # Update temporary Log4j2 file with 'i2_' prefixed properties and appenders from heredoc
  replaceXmlElementWithHeredoc "<\/Properties>" "${properties_heredoc_file_path}" "${tmp_log4j2_file_path}"
  replaceXmlElementWithHeredoc "<\/Appenders>" "${appenders_heredoc_file_path}" "${tmp_log4j2_file_path}"

  # If logger already exists then force set 'level' and append 'AppenderRef', else if
  # logger does not exist then append entire heredoc block for each logger.
  appendLoggingXmlElementWithHeredoc "${loggers_console_name}" "${loggers_heredoc_console_file_path}" "${loggers_console_level}" "${loggers_console_appender_ref}"
  appendLoggingXmlElementWithHeredoc "${loggers_availability_name}" "${loggers_heredoc_availability_file_path}" "${loggers_availability_level}" "${loggers_availability_appender_ref}"
  appendLoggingXmlElementWithHeredoc "${loggers_mapping_name}" "${loggers_heredoc_mapping_file_path}" "${loggers_mapping_level}" "${loggers_mapping_appender_ref}"
  appendLoggingXmlElementWithHeredoc "${loggers_lifecycle_name}" "${loggers_heredoc_lifecycle_file_path}" "${loggers_lifecycle_level}" "${loggers_lifecycle_appender_ref}"
  appendLoggingXmlElementWithHeredoc "${loggers_statehandler_name}" "${loggers_heredoc_statehandler_file_path}" "${loggers_statehandler_level}" "${loggers_statehandler_appender_ref}"

  # Copy modified Logger to container
  docker cp "${tmp_log4j2_file_path}" "${LIBERTY1_CONTAINER_NAME}:${log4j2_container_path}"

  # Remove tmp heredoc files
  rm "${properties_heredoc_file_path}" \
  "${appenders_heredoc_file_path}" \
  "${loggers_heredoc_console_file_path}" \
  "${loggers_heredoc_availability_file_path}" \
  "${loggers_heredoc_mapping_file_path}" \
  "${loggers_heredoc_lifecycle_file_path}" \
  "${loggers_heredoc_statehandler_file_path}"
}

function waitForLibertyToBeLive() {
  print "Waiting for i2Analyze service to be live"
  local MAX_TRIES=10

  local ssl_ca_certificate
  getSecret "certificates/externalCA/CA.cer" > /tmp/CA.cer

  for i in $(seq 1 "${MAX_TRIES}"); do
    if curl \
        -s -S -o /tmp/response.txt \
        --cookie /tmp/cookie.txt \
        --write-out "%{http_code}" \
        --silent \
        --cacert /tmp/CA.cer \
        "${FRONT_END_URI}/api/v1/health/live" > /tmp/http_code.txt; then
      http_status_code=$(cat /tmp/http_code.txt)
      if [[ "${http_status_code}" -eq 200 ]]; then
        echo "i2Analyze service is live"
        return 0
      else
        echo "Response from the /health/live endpoint: $(cat /tmp/response.txt)"
      fi
    fi
    echo "i2Analyze service is NOT live (attempt: $i). Waiting..."
    sleep 10
  done
  echo "Response from the /health/live endpoint: $(cat /tmp/response.txt)"
  docker logs --tail 50 "${LIBERTY1_CONTAINER_NAME}"
  printErrorAndExit "i2Analyze service is NOT live"
}

function checkLibertyStatus() {
  print "Checking Liberty Status"

  local warn_message="Warnings detected, please review the above message(s)."
  local errors_message="Validation errors detected, please review the above message(s)."
  local validation_log_path="/logs/opal-services/IBM_i2_Validation.log"
  local status_log_path="/logs/opal-services/IBM_i2_Status.log"
  local validation_messages

  waitForLibertyToBeLive

  # Wait for a known I2ANALYZE_STATUS code:
  #  0002 is success
  #  0005 is exception on startup
  #  0068 is waiting for component availability
  if docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c "timeout 3m grep -q '0002\|0005\|0068' <(tail -f ${status_log_path})"; then
      validation_messages=$(docker exec "${LIBERTY1_CONTAINER_NAME}" cat "${validation_log_path}")
      if docker exec "${LIBERTY1_CONTAINER_NAME}" bash -c "grep -q '0002' <(cat ${status_log_path})"; then
        if [[ -n "${validation_messages}" ]]; then
          echo "${validation_messages}"
          printWarn "${warn_message}"
        fi
      else
        if [[ -n "${validation_messages}" ]]; then
          echo "${validation_messages}"
          printErrorAndExit "${errors_message}"
        fi
      fi
      echo "No Validation errors detected."
  else
    validation_messages=$(docker exec "${LIBERTY1_CONTAINER_NAME}" cat "${validation_log_path}")
    if [[ -z "${validation_messages}" ]]; then
      docker logs --tail 50 "${LIBERTY1_CONTAINER_NAME}"
    else
      echo "${validation_messages}"
    fi
    printErrorAndExit "Liberty failed to start in time. The last messages logged by the server are above."
  fi
}

#######################################
# Wait for a solr Asynchronous process to be completed.
# Arguments:
#   The Asynchronous ID used to monitor the asynchronous operation.
#######################################
function waitForAsyncrhonousRequestStatusToBeCompleted() {
  local async_id="$1"
  local tries=1
  local max_tries=30

  print "Waiting for ${async_id} to be completed"
  while [[ "${tries}" -le "${max_tries}" ]]; do
    response=$(getAsyncRequestStatus "${async_id}")
    if [[ "${response}" == "completed" ]]; then
      echo "${async_id} status has been marked completed" && return 0
    fi

    echo "${async_id} status has not been marked as completed"
    echo "Waiting..."
    sleep 5
    if [[ "${tries}" -ge "${max_tries}" ]]; then
      printErrorAndExit "ERROR: ${async_id} could not be completed: '${response}'"
    fi
    ((tries++))
  done
}




#######################################
# Wait for Solr to be live
# Arguments:
#   Solr node to wait for to be live
#######################################
function waitForSolrToBeLive() {
  local solr_node="$1"
  local max_tries=15
  local can_access_admin_endpoint=true

  print "Waiting for Solr Node to be live: ${solr_node}"

  for i in $(seq 1 "${max_tries}"); do
    status_response=$(getSolrNodeStatus "${solr_node}")
    if [[ "${status_response}" == "ACTIVE" ]]; then
      echo "${solr_node} status: ACTIVE" && return 0
    elif [[ "${status_response}" == "ERROR" ]]; then
      can_access_admin_endpoint=false
    else
      echo "${solr_node} status: DOWN"
    fi
    sleep 5
    echo "(attempt: ${i}). Waiting..."
  done

  # If you get here, getSolrNodeStatus has not been successful
  if [[ "${can_access_admin_endpoint}" == false ]]; then
    runSolrClientCommand bash -c "curl --silent --write-out \"%{http_code}\" \
      --cacert ${CONTAINER_CERTS_DIR}/CA.cer \
      -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" \
      \"${SOLR1_BASE_URL}/solr/admin/info/health\""
    printErrorAndExit "Unable to access ${SOLR1_BASE_URL}/solr/admin/info/health endpoint"
  else
    printErrorAndExit "${solr_node} is NOT live. The list of all live nodes: ${nodes}"
  fi
}

#######################################
# Get Solr node status through Solr API
# Arguments:
#   Solr node to get status of
#######################################
function getSolrNodeStatus() {
  local solr_node="$1"

  if [[ "$(runSolrClientCommand bash -c "curl --silent --output /dev/null --write-out \"%{http_code}\" \
        -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" --cacert \"${CONTAINER_CERTS_DIR}/CA.cer\" \
        \"${SOLR1_BASE_URL}/solr/admin/info/health\"")" == 200 ]]; then
    jsonResponse=$(
      runSolrClientCommand bash -c "curl --silent -u \"\${SOLR_ADMIN_DIGEST_USERNAME}:\${SOLR_ADMIN_DIGEST_PASSWORD}\" \
          --cacert /tmp/i2acerts/CA.cer \"${SOLR1_BASE_URL}/solr/admin/collections?action=CLUSTERSTATUS\""
    )
    nodes=$(echo "${jsonResponse}" | jq -r '.cluster.live_nodes | join(", ")')
    if grep -q "${solr_node}" <<<"$nodes"; then
      echo "ACTIVE" && return 0
    fi
    echo "DOWN"
  else
    echo "ERROR can't access admin endpoint"
  fi
}

#######################################
# Get i2 Analyze Service status.
# Arguments:
#   Liberty instance name. E.g liberty1, liberty2 (defaults to 'all').
# Outputs:
#   i2 Analyze service status: Active, Degraded, Down
#######################################
function geti2AnalyzeServiceStatus() {
  local liberty_instance_name="${1:-all}"
  local load_balancer_stats_status_code
  local load_balancer_stats_response
  local liberty_stats
  local liberty_stats_array
  local liberty_name
  local liberty_status
  local liberty_status_number=17

  load_balancer_stats_status_code="$(
    runi2AnalyzeToolAsExternalUser bash -c "curl --write-out \"%{http_code}\" --silent --output /dev/null \
        --cacert /tmp/i2acerts/CA.cer \"${LOAD_BALANCER_STATS_URI}\""
  )"
  # Make sure you get 200 from /haproxy_stats;csv
  if [[ "${load_balancer_stats_status_code}" -eq 200 ]]; then
    # Get Load Balancer Stats
    load_balancer_stats_response="$(
      runi2AnalyzeToolAsExternalUser bash -c "curl  --silent --cacert /tmp/i2acerts/CA.cer \"${LOAD_BALANCER_STATS_URI}\""
    )"
    # Make sure response in not empty
    if [[ -n "${load_balancer_stats_response}" ]]; then
      if [[ "${liberty_instance_name}" == "all" ]]; then
        # Determine whether all Liberty servers are Down
        if grep -q "BACKEND" <<<"${load_balancer_stats_response}"; then
          liberty_stats=$(grep "BACKEND" <<<"${load_balancer_stats_response}")
          # Parse line of csv into a $liberty_stats array
          # IFS is a separator used by the 'read' command
          IFS=',' read -r -a liberty_stats_array <<<"${liberty_stats}"
          liberty_status="${liberty_stats_array[${liberty_status_number}]}"
          if [[ "${liberty_status}" != "UP" ]]; then
            echo "DOWN"
            return
          fi
        fi
        # If Liberty Backend is UP, check whether i2 Analyze Service state is Active or Degraded
        while read -r line; do
          if grep -q "liberty" <<<"${line}"; then
            IFS=',' read -r -a liberty_stats_array <<<"${line}"
            liberty_status="${liberty_stats_array[${liberty_status_number}]}"
            if [[ "${liberty_status}" != "UP" ]]; then
              echo "DEGRADED"
              return
            fi
          fi
        done < <(echo "${load_balancer_stats_response}")
      else
        liberty_stats=$(grep "$liberty_instance_name" <<<"${load_balancer_stats_response}")
        IFS=',' read -r -a liberty_stats_array <<<"${liberty_stats}"
        liberty_status="${liberty_stats_array[${liberty_status_number}]}"
        if [[ "${liberty_status}" != "UP" ]]; then
          echo "DOWN"
          return
        fi
      fi
    else
      echo "Empty response from the load balancer stats page (${LOAD_BALANCER_STATS_URI})"
    fi
  else
    echo "Response from the load balancer stats page (${LOAD_BALANCER_STATS_URI}) is not OK. We are getting: ${load_balancer_stats_status_code}"
  fi
  # IF you get here i2 Analyze Service is UP
  echo "ACTIVE"
}

#######################################
# Get ZooKeeper ensemble service status.
# Arguments:
#   None
# Outputs:
#   ZooKeeper ensemble service status: Active, Degraded, Down
#######################################
function getZkQuorumEnsembleStatus() {
  local online_count=0
  local zookeepers=("${ZK1_FQDN}" "${ZK2_FQDN}" "${ZK3_FQDN}")
  local not_serving_error="This ZooKeeper instance is not currently serving requests"

  for zookeeper in "${zookeepers[@]}"; do
    srvr_endpoint="http://${zookeeper}:8080/commands/srvr"
    if [[ $(runSolrClientCommand bash -c "curl -s --fail --cacert ${CONTAINER_CERTS_DIR}/CA.cer ${srvr_endpoint}") ]]; then
      response=$(runSolrClientCommand bash -c "curl -s --fail --cacert ${CONTAINER_CERTS_DIR}/CA.cer ${srvr_endpoint}")
      error=$(echo "${response}" | jq -r '.error')
      if [[ "${error}" == "null" ]]; then
        ((online_count++))
      elif [[ "${error}" == "${not_serving_error}" ]]; then
        echo "DOWN"
        return
      fi
    fi
  done

  if ((online_count == "${#zookeepers[@]}")); then
    echo "ACTIVE"
  else
    echo "DEGRADED"
  fi
}

#######################################
# Wait for the i2 Analyze Service status to be 'Active'.
# Arguments:
#   None
#######################################
function waitFori2AnalyzeServiceToBeLive() {
  local max_tries=50
  local exit_code=0
  local i2analyze_service_status

  print "Waiting for i2 Analyze service to be live"

  for i in $(seq 1 "${max_tries}"); do
    i2analyze_service_status="$(geti2AnalyzeServiceStatus)"
    if [[ "${i2analyze_service_status}" == "ACTIVE" ]]; then
      exit_code=0
      break
    elif [[ "${i2analyze_service_status}" == "DOWN" ]]; then
      echo "i2 Analyze service state: 'DOWN' (attempt: ${i}). Waiting..."
      exit_code=1
    elif [[ "${i2analyze_service_status}" == "DEGRADED" ]]; then
      echo "i2 Analyze service state: 'DEGRADED' (attempt: ${i}). Waiting..."
      exit_code=2
    fi
    sleep 10
  done

  if [[ "${exit_code}" -eq 0 ]]; then
    echo "i2Analyze service state: 'ACTIVE'"
  elif [[ "${exit_code}" -eq 1 ]]; then
    printErrorAndExit "i2Analyze service state: 'DOWN'"
  elif [[ "${exit_code}" -eq 2 ]]; then
    printErrorAndExit "i2Analyze service state: 'DEGRADED'"
  else
    printErrorAndExit "ERROR: ${i2analyze_service_status}"
  fi
}

#######################################
# Wait for SQL Server to be live. The functions performs
# a simple non consequential query to check whether SQL Server is live.
# Arguments:
#   1 - first_run: {true, false}
#       if 'true' uses the initial SA Password
#       if 'false' uses SA Password
#######################################
function waitForSQLServerToBeLive() {
  local max_tries=15
  local sql_query='SELECT 1'
  local first_run="${1:-false}"
  print "Waiting for SQL Server to be live"
  for i in $(seq 1 "${max_tries}"); do
    if [[ "${first_run}" == "true" ]]; then
      if runSQLServerCommandAsFirstStartSA runSQLQuery "${sql_query}"; then
        echo "SQL Server is live" && return 0
      fi
    else
      if runSQLServerCommandAsSA runSQLQuery "${sql_query}"; then
        echo "SQL Server is live" && return 0
      fi
    fi
    echo "SQL Server is NOT live (attempt: ${i}). Waiting..."
    sleep 5
  done

  # If you get here, waitForSQLServerToBeLive has not been successful
  printErrorAndExit "SQL Server is NOT live."
}

#######################################
# Wait for Db2 Server to be live. The functions performs
# a simple non consequential query to check whether Db2 Server is live.
# Arguments:
#   1 - first_run: {true, false}
#       if 'true' uses the initial db2inst1 Password
#       if 'false' uses db2inst1 Password
#######################################
function waitForDb2ServerToBeLive() {
  local max_tries=30
  local sql_query='TERMINATE'
  local first_run="${1:-false}"
  print "Waiting for Db2 Server to be live"
  for i in $(seq 1 "${max_tries}"); do
    if [[ "${first_run}" == "true" ]]; then
      if runDb2ServerCommandAsAsFirstStartDb2inst1 runSQLQuery "${sql_query}"; then
        echo "Db2 Server is live" && return 0
      fi
    else
      if runDb2ServerCommandAsDb2inst1 runSQLQuery "${sql_query}"; then
        echo "Db2 Server is live" && return 0
      fi
    fi
    echo "Db2 Server is NOT live (attempt: ${i}). Waiting..."
    sleep 5
  done

  # If you get here, waitForDb2ServerToBeLive has not been successful
  printErrorAndExit "Db2 Server is NOT live."
}

#######################################
# Runs i2 Analyze request as a gateway user
# Arguments:
#   None
#######################################
function runi2AnalyzeToolAsGatewayUser() {
  local SSL_OUTBOUND_PRIVATE_KEY
  local SSL_OUTBOUND_CERTIFICATE
  local SSL_CA_CERTIFICATE
  SSL_OUTBOUND_PRIVATE_KEY=$(getSecret certificates/gateway_user/server.key)
  SSL_OUTBOUND_CERTIFICATE=$(getSecret certificates/gateway_user/server.cer)
  SSL_CA_CERTIFICATE=$(getSecret certificates/CA/CA.cer)

  docker run --rm \
    --network "${DOMAIN_NAME}" \
    -e GATEWAY_SSL_CONNECTION="${GATEWAY_SSL_CONNECTION}" \
    -e SSL_OUTBOUND_PRIVATE_KEY="${SSL_OUTBOUND_PRIVATE_KEY}" \
    -e SSL_OUTBOUND_CERTIFICATE="${SSL_OUTBOUND_CERTIFICATE}" \
    -e SSL_CA_CERTIFICATE="${SSL_CA_CERTIFICATE}" \
    "${I2A_TOOLS_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}" "$@"
}

#######################################
# Puts a key and value pair in a bash 3 compatible map.
# Arguments:
#   1: The map name
#   2: The key
#   3: The value
#######################################
function map_put() {
  alias "${1}${2}=${3}"
}

#######################################
# Gets a value pair from a bash 3 compatible map.
# Arguments:
#   1: The map name
#   2: The key
# Returns:
#   The value from the specified map
#######################################
function map_get() {
  alias "${1}${2}" | awk -F"'" '{ print $2; }'
}

#######################################
# Gets all the keys from a bash 3 compatible map.
# Arguments:
#   1: The map name
# Returns:
#   The keys from the specified map
#######################################
function map_keys() {
  alias -p | grep "$1" | cut -d'=' -f1 | awk -F"$1" '{print $2; }'
}

#######################################
# Prints a heading style message to the console.
# Arguments:
#   1: The message
#######################################
function print() {
  echo ""
  echo "#----------------------------------------------------------------------"
  echo "# $1"
  echo "#----------------------------------------------------------------------"
}

#######################################
# Prints an error message to the console,
# then exit 1.
# Arguments:
#   1: The message
#######################################
function printErrorAndExit() {
  printf "\n\e[31mERROR: %s\n" "$1" >&2
  printf "\e[0m" >&2
  exit 1
}

#######################################
# Prints an error message to the console
# Arguments:
#   1: The message
#######################################
function printWarn() {
  printf "\n\e[31mWARN: %s\n" "$1" >&2
  printf "\e[0m" >&2
}

#######################################
# Prints an INFO message to the console.
# Arguments:
#   1: The message
#######################################
function printInfo() {
  if [[ "${VERBOSE}" == "true" ]]; then
    printf "[INFO] %s\n" "$1"
  fi
}

#######################################
# Removes Folder if it exists.
# Arguments:
#   1: Folder path
#######################################
function deleteFolderIfExists() {
  local folder_path="$1"
  if [[ -d "${folder_path}" ]]; then
    rm -rf "${folder_path}"
  fi
}

#######################################
# Removes Folder if it exists and create a new one.
# Arguments:
#   1: Folder path
#######################################
function deleteFolderIfExistsAndCreate() {
  local folder_path="$1"

  printInfo "Deleting folder: ${folder_path}"
  deleteFolderIfExists "${folder_path}"

  printInfo "Creating folder: ${folder_path}"
  createFolder "${folder_path}"
}

#######################################
# Create folder if it doesn't exist.
# Arguments:
#   1: Folder path
#######################################
function createFolder() {
  local folder_path="$1"

  if [[ ! -d "${folder_path}" ]]; then
    mkdir -p "${folder_path}"
  fi
}

#######################################
# Create dsid.properties file
# Arguments:
#   1: File path for the properties file
#######################################
function createDsidPropertiesFile() {
  local dsid_properties_file_path="$1"
  local dsid_file_name
  local dsid_folder_path
  dsid_folder_path="$(dirname "${dsid_properties_file_path}")"
  dsid_file_name="$(basename "${dsid_properties_file_path}")"

  if [[ ! -f "${dsid_properties_file_path}" ]]; then
    print "Creating ${dsid_file_name} file"
    createFolder "${dsid_folder_path}"
    echo "DataSourceId=$(uuidgen)" > "${dsid_properties_file_path}"
  fi
}

#######################################
# Stop docker container
# Arguments:
#   1: container name or id
#######################################
function stopContainer() {
  local container_name_or_id="$1"
  local max_retries=10
  while ! docker stop "${container_name_or_id}"; do
    if (( "${max_retries}" == 0 )); then
      printErrorAndExit "Unable to stop container '${container_name_or_id}', exiting script"
    else
      echo "[WARN] Having issues stopping container '${container_name_or_id}', retrying..."
      ((max_retries="${max_retries}"-1))
    fi
    sleep 1s
  done
}

#######################################
# Remove docker container
# Arguments:
#   1: container name or id
#######################################
function removeContainer() {
  local container_name_or_id="$1"
  local max_retries=10
  while ! docker rm "${container_name_or_id}"; do
    if (( "${max_retries}" == 0 )); then
      printErrorAndExit "Unable to remove container '${container_name_or_id}', exiting script"
    else
      echo "[WARN] Having issues removing container '${container_name_or_id}', retrying..."
      ((max_retries="${max_retries}"-1))
    fi
    sleep 1s
  done
}

#######################################
# Removes containers based on the CONFIG_NAME.
# Arguments:
#   None
#######################################
function removeAllContainersForTheConfig() {
  local config_name="$1"
  if docker network ls | grep -q -w "${DOMAIN_NAME}"; then
    local container_ids
    container_ids=$(docker ps -a -q -f network="${DOMAIN_NAME}" -f name="${config_name}")
    if [[ -n "${container_ids}" ]]; then
      print "Removing containers running in the network (${DOMAIN_NAME}) with the config name (${config_name})"
      while IFS= read -r container_id; do
        deleteContainer "${container_id}"
      done <<<"${container_ids}"
    fi
  fi
}

function cleanUpDockerResources() {
  deleteAllPreProdContainers
  stopConfigDevContainers
  stopConnectorContainers
  if [[ "${ENVIRONMENT}" == "pre-prod" ]]; then
    removeDockerVolumes
  fi
}

function deleteAllPreProdContainers() {
  local pre_prod_containers=(
    "${ZK1_CONTAINER_NAME%.*}"
    "${ZK2_CONTAINER_NAME%.*}"
    "${ZK3_CONTAINER_NAME%.*}"
    "${SOLR1_CONTAINER_NAME%.*}"
    "${SOLR2_CONTAINER_NAME%.*}"
    "${SOLR3_CONTAINER_NAME%.*}"
    "${SQL_SERVER_CONTAINER_NAME%.*}"
    "${LIBERTY1_CONTAINER_NAME%.*}"
    "${LIBERTY2_CONTAINER_NAME%.*}"
    "${LOAD_BALANCER_CONTAINER_NAME%.*}"
    "${CONNECTOR1_CONTAINER_NAME%.*}"
    "${CONNECTOR2_CONTAINER_NAME%.*}"
  )

  for pre_prod_container in "${pre_prod_containers[@]}"; do
    forceDeleteContainer "${pre_prod_container}"
  done
}

function stopConfigDevContainers() {
  local config
  local container_ids
  local container_id

  for config_dir in "${ROOT_DIR}"/configs/*/ ; do
    # get config name from the path
    config=$(sed -e 's/.*\/configs\///' -e 's/\///' <<< "${config_dir}")

    # if not current config name
    if [[ "${config}" != "${CONFIG_NAME}" ]]; then
      print "Stopping containers for configuration: ${config}"
      IFS=' ' read -ra container_ids <<<  "$(docker ps -a -q -f name="${config}" -f status=running | xargs)"
      for container_id in "${container_ids[@]}"; do
        stopContainer "${container_id}"
      done
    fi
  done
}

function stopConnectorContainers() {
  local container_ids

  IFS=' ' read -ra container_ids <<<  "$(docker ps -a -q -f name="${CONNECTOR_PREFIX}" -f status=running | xargs)"

  print "Stopping connector containers"
  for container_id in "${container_ids[@]}"; do
    stopContainer "${container_id}"
  done
}

function restartDockerContainersForConfig() {
  local config_name="$1"
  local database_restarted="false"
  local solr_restarted="false"
  local all_exited_container_names

  IFS=' ' read -ra all_exited_container_names <<< "$(docker ps -a --format "{{.Names}}" -f name="${config_name}" -f status=exited | xargs)"

  if [[ "${#all_exited_container_names[@]}" -gt "0" ]]; then
    print "Restarting containers for config: ${config_name}"
    # Restarting containers
    for container_name in "${all_exited_container_names[@]}"; do
      # if previusly deployed without the isotre don't start it up, should be handled later in the code if needed
      if [[ "${container_name}" == "${SQL_SERVER_CONTAINER_NAME}" || "${container_name}" == "${DB2_SERVER_CONTAINER_NAME}" ]] && [[ "${PREVIOUS_DEPLOYMENT_PATTERN}" != *"store"* ]]; then
        continue
      fi
      docker start "${container_name}"
      if [[ "${container_name}" == "${SQL_SERVER_CONTAINER_NAME}" ]]; then
        database_restarted="true"
      elif [[ "${container_name}"  == "${SOLR1_CONTAINER_NAME}" ]] || [[ "${container_name}" == "${ZK1_CONTAINER_NAME}" ]]; then
        solr_restarted="true"
      fi
    done

    # Waiting for system to be up
    if [[ "${database_restarted}" == "true" ]]; then
      waitForSQLServerToBeLive
    elif [[ "${solr_restarted}" == "true" ]]; then
      waitForSolrToBeLive "${SOLR1_FQDN}"
    fi
    # if at least one container has been restarted, wait for Liberty to be up
    waitForLibertyToBeLive
  fi
}

#######################################
# Prompt user to reply y/n to a question
# Arguments:
#   The question
#######################################
function waitForUserReply() {
  local question="$1"
  echo "" # print an empty line

  if [[ "${YES_FLAG}" == "true" ]]; then
    echo "${question} (y/n) "
    echo "You selected -y flag, continuing"
    return 0
  fi

  while true; do
    read -r -p "${question} (y/n) " yn
    case $yn in
      [Yy]* ) echo "" && break;;
      [Nn]* ) exit 1;;
      * ) ;;
    esac
  done
}

#######################################
# Checks if a volume exists before attempting to remove it.
# This avoids unnecessary console output when a volume does
# not exist.
# Arguments:
#   The name  of the Docker volume to delete
#######################################
function quietlyRemoveDockerVolume() {
  local volume_to_delete="$1"
  local docker_volumes
  docker_volumes="$(docker volume ls -q)"
  if grep -q ^"$volume_to_delete"$ <<<"$docker_volumes"; then
    docker volume rm "$volume_to_delete"
  fi
}

#######################################
# Runs a Solr container as root to change permissions on the Solr backup volume.
# Arguments:
#   None
#######################################
function runSolrContainerWithBackupVolume() {
  docker run --rm \
    -v "${SOLR_BACKUP_VOLUME_NAME}:${SOLR_BACKUP_VOLUME_LOCATION}" \
    --user="root" \
    "${SOLR_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}" "$@"
}

#######################################
# Removes all the i2Analyze related docker volumes.
# Arguments:
#   None
#######################################
function removeDockerVolumes() {
  print "Removing all associated volumes"
  quietlyRemoveDockerVolume "${SQL_SERVER_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${DB2_SERVER_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${DB_BACKUP_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${SOLR1_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${SOLR2_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${SOLR3_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK1_DATA_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK2_DATA_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK3_DATA_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK1_DATALOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK2_DATALOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK3_DATALOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK1_LOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK2_LOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${ZK3_LOG_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${LIBERTY1_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${LIBERTY2_VOLUME_NAME}"
  quietlyRemoveDockerVolume "${SOLR_BACKUP_VOLUME_NAME}"
}

#######################################
# Creates docker network if it doesn't exist.
# Arguments:
#   None
#######################################
function createDockerNetwork() {
  local name=$1
  if ! docker network ls | grep -q -w "${name}"; then
    print "Creating docker network: ${name}"
    docker network create "${name}"
  fi
}

#######################################
# Prints out the current timestamp,
# in the format that can be passed to the `docker logs`
# with `--since` flag
# Arguments:
#   None
#######################################
function getTimestamp() {
  date --rfc-3339=seconds | sed 's/ /T/'
}

#######################################
# Check variables is set and prints an error if not.
# Arguments:
#   1. Variable value
#   2. Error message to be printed in case of a failure
#######################################
function checkVariableIsSet() {
  local var_value="$1"
  local error_message="$2"
  if [[ -z "${var_value}" ]]; then
    printErrorAndExit "${error_message}"
  fi
}

#######################################
# Checks ENVIRONMENT is a valid environment name.
# Arguments:
#   None
#######################################
function checkEnvironmentIsValid() {
  checkVariableIsSet "${ENVIRONMENT}" "ENVIRONMENT environment variable is not set"
  if [ "${ENVIRONMENT}" != "pre-prod" ] && [ "${ENVIRONMENT}" != "config-dev" ] && [ "${ENVIRONMENT}" != "aws" ]; then
    printErrorAndExit "${ENVIRONMENT} is not a valid environment name"
  fi
}

#######################################
# Returns the application admin password depending
# of the environment.
# Arguments:
#   None
#######################################
function getApplicationAdminPassword() {
  local app_admin_password

  if [[ "${ENVIRONMENT}" == "pre-prod" ]]; then
    app_admin_password="${I2_ANALYZE_ADMIN}"
  else
    app_admin_password=$(getSecret application/admin_PASSWORD)
  fi

  echo "${app_admin_password}"
}

#######################################
# Checks DEPLOYMENT_PATTERN is valid.
# Arguments:
#   None
#######################################
function checkDeploymentPatternIsValid() {
  checkVariableIsSet "${DEPLOYMENT_PATTERN}" "DEPLOYMENT_PATTERN environment variable is not set"
  if [ "${DEPLOYMENT_PATTERN}" != "schema_dev" ] && [ "${DEPLOYMENT_PATTERN}" != "istore" ] && [ "${DEPLOYMENT_PATTERN}" != "cstore" ] &&
    [ "${DEPLOYMENT_PATTERN}" != "i2c" ] && [ "${DEPLOYMENT_PATTERN}" != "i2c_istore" ] && [ "${DEPLOYMENT_PATTERN}" != "i2c_cstore" ]; then
    printErrorAndExit "${DEPLOYMENT_PATTERN} is not not a valid deployment pattern"
  fi
}

#######################################
# Checks if DEPLOYMENT_PATTERN contains i2connect.
# Arguments:
#   None
#######################################
function isI2ConnectDeploymentPattern() {
 if [[ $DEPLOYMENT_PATTERN == *"i2c"* ]]; then
    return 0
  else
    return 1
  fi
}

#######################################
# Checks required containers for the current deploy exist.
# Arguments:
#   None
# Returns:
#   0 - if all exist
#   1 - if >=1 does NOT exist
#######################################
function checkContainersExist() {
  local all_present=0
  local containers=("${SOLR1_CONTAINER_NAME}" "${ZK1_CONTAINER_NAME}" "${LIBERTY1_CONTAINER_NAME}")

  print "Checking all containers required for the deployment exist"
  if [[ "${PREVIOUS_DEPLOYMENT_PATTERN}" == *"store"* ]]; then
    case "${DB_DIALECT}" in
      db2)
        containers+=("${DB2_SERVER_CONTAINER_NAME}")
        ;;
      sqlserver)
        containers+=("${SQL_SERVER_CONTAINER_NAME}")
        ;;
    esac
  fi

  for container in "${containers[@]}"; do
    if [[ -z "$( docker ps -aq -f name="${container}")" ]]; then
      echo "${container} does NOT exist"
      all_present=1
    fi
  done

  return "${all_present}"
}

#######################################
# Checks required connector containers for the current deploy exist.
# Arguments:
#   None
# Returns:
#   0 - if all exist
#   1 - if >=1 does NOT exist
#######################################
function checkConnectorContainersExist() {
  if [ "${DEPLOYMENT_PATTERN}" != "istore" ] && [ "${DEPLOYMENT_PATTERN}" != "cstore" ]; then
    local all_present=0
    local connector_references_file="${LOCAL_USER_CONFIG_DIR}/connector-references.json"
    local connector_name connector_type
    local all_connector_names
    IFS=' ' read -ra all_connector_names <<< "$( jq -r '.connectors[].name' < "${connector_references_file}" | xargs)"
    for connector_name in "${all_connector_names[@]}"; do
      connector_type=$(jq -r '.type' <"${CONNECTOR_IMAGES_DIR}/${connector_name}/connector-definition.json")
      if [[ "${connector_type}" != "${EXTERNAL_CONNECTOR_TYPE}" && -z "$( docker ps -aq -f name="${CONNECTOR_PREFIX}${connector_name}")" ]]; then
        echo "${CONNECTOR_PREFIX}${connector_name} does NOT exist"
        all_present=1
      fi
    done

    return "${all_present}"
  fi

}

###############################################################################
# Connector Helper Functions                                                  #
###############################################################################

function setListOfConnectorsToUpdate() {
  local connector_image_dir
  local connector_name
  local excluded_connector

  # Included connectors
  if [[ -n "${INCLUDED_CONNECTORS}" ]]; then
    IFS=" " read -r -a CONNECTOR_NAMES <<< "${INCLUDED_CONNECTORS[@]}"
  else

    # All connectors
    for connector_image_dir in "${CONNECTOR_IMAGES_DIR}"/* ; do
      [[ ! -d "${connector_image_dir}" ]] && continue
      connector_name="${connector_image_dir##*/}"
      CONNECTOR_NAMES+=("${connector_name}")
    done

    # All connectors minus excluded connectors
    if [[ -n "${EXCLUDED_CONNECTORS}" ]]; then
      for excluded_connector in "${EXCLUDED_CONNECTORS[@]}"; do
        for i in "${!CONNECTOR_NAMES[@]}"; do
          if [[ ${CONNECTOR_NAMES[i]} = "$excluded_connector" ]]; then
            unset 'CONNECTOR_NAMES[i]'
        fi
        done
      done
    fi
  fi

  #  Validation
  validateConnectorsExist
}

function validateConnectorsExist() {
  local connector_name
  for connector_name in "${CONNECTOR_NAMES[@]}"; do
    connector_image_dir=${CONNECTOR_IMAGES_DIR}/${connector_name}
    if [[ ! -d "${connector_image_dir}" ]]; then
      printErrorAndExit "Connector image directory ${connector_image_dir} does NOT exist"
    fi
  done

}

function setListOfExtensionsToUpdate() {
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"
  local extension_dir
  local extension_name
  local excluded_extension

  # Included extensions
  if [[ -n "${INCLUDED_EXTENSIONS}" ]]; then
    IFS=" " read -r -a EXTENSION_NAMES <<< "${INCLUDED_EXTENSIONS[@]}"
  else

    # All extensions in config-dev
    readarray -t EXTENSION_NAMES < <( jq -r '.extensions[].name' < "${extension_references_file}")

    # All extensions minus excluded extensions
    if [[ -n "${EXCLUDED_EXTENSIONS}" ]]; then
      for excluded_extension in "${EXCLUDED_EXTENSIONS[@]}"; do
        for i in "${!EXTENSION_NAMES[@]}"; do
          if [[ ${EXTENSION_NAMES[i]} = "$excluded_extension" ]]; then
            unset 'EXTENSION_NAMES[i]'
          fi
        done
      done
    fi
  fi
}

#######################################
# Appends a property value pair to the given property file.
# Arguments:
#   1. The file path to the properties file
#   2. The property value pair e.g. "name=value"
#######################################
function addToPropertiesFile() {
  local property="${1}"
  local properties_file="${2}"

  {
    echo
    echo "${property}"
  } >> "${properties_file}"
}

function addDataSourcePropertiesIfNecessary() {
  local properties_file="${1}"
  local topology_id
  local datasource_name

  if [[ "${DEPLOYMENT_PATTERN}" != "i2c" ]]; then
    topology_id="infostore"
    datasource_name="Information Store"
  else
    topology_id="opalDAOD"
    datasource_name="Opal DAOD"
  fi

  if ! grep -xq "DataSourceName=.*" "${properties_file}" ; then
    addToPropertiesFile "DataSourceName=${datasource_name}" "${properties_file}"
  fi
  if ! grep -xq "TopologyId=.*" "${properties_file}" ; then
    addToPropertiesFile "TopologyId=${topology_id}" "${properties_file}"
  fi
}

function getTopologyId() {
  local topology_id

  if [[ "${DEPLOYMENT_PATTERN}" != "i2c" ]]; then
    topology_id="infostore"
  else
    topology_id="opalDAOD"
  fi
  echo "${topology_id}"
}

function createDsidPropertiesForDeploymentPattern() {
  local dsid_properties_file_path="${1}"
  local dsid_deployment_pattern_properties_file_path
  local topology_id

  topology_id="$(getTopologyId)"
  dsid_deployment_pattern_properties_file_path="${LOCAL_CONFIG_DIR}/environment/dsid/dsid.${topology_id}.properties"
  mv "${dsid_properties_file_path}" "${dsid_deployment_pattern_properties_file_path}"

  addDataSourcePropertiesIfNecessary "${dsid_deployment_pattern_properties_file_path}"
}

#######################################
# Create .configuration folder that is used by the i2 tools
# Arguments:
#   None
#######################################
function createMountedConfigStructure() {
  local OPAL_SERVICES_IS_PATH="${LOCAL_CONFIG_DIR}/fragments/opal-services-is/WEB-INF/classes"
  local OPAL_SERVICES_PATH="${LOCAL_CONFIG_DIR}/fragments/opal-services/WEB-INF/classes"
  local OPAL_SERVICES_LIB_PATH="${LOCAL_CONFIG_DIR}/fragments/opal-services/WEB-INF/lib"
  local COMMON_PATH="${LOCAL_CONFIG_DIR}/fragments/common/WEB-INF/classes"
  local ENV_COMMON_PATH="${LOCAL_CONFIG_DIR}/environment/common"
  local LIVE_PATH="${LOCAL_CONFIG_DIR}/live"
  local LOG4J_PATH="${LOCAL_CONFIG_DIR}/i2-tools/classes"
  local topology_id

  # Create hidden configuration folder
  deleteFolderIfExistsAndCreate "${LOCAL_CONFIG_DIR}"
  cp -pr "${GENERATED_LOCAL_CONFIG_DIR}/." "${LOCAL_CONFIG_DIR}"

  # Add jdbc drivers from pre-reqs folder
  deleteFolderIfExistsAndCreate "${ENV_COMMON_PATH}"

  # Recreate structure and copy right files
  mkdir -p "${LOG4J_PATH}" "${ENV_COMMON_PATH}" "${OPAL_SERVICES_IS_PATH}" "${OPAL_SERVICES_PATH}" "${COMMON_PATH}" "${LIVE_PATH}"
  cp -pr "${PRE_REQS_DIR}/jdbc-drivers" "${ENV_COMMON_PATH}"
  mv "${LOCAL_CONFIG_DIR}/analyze-settings.properties" \
    "${LOCAL_CONFIG_DIR}/analyze-connect.properties" \
    "${LOCAL_CONFIG_DIR}/ApolloServerSettingsMandatory.properties" \
    "${LOCAL_CONFIG_DIR}/ApolloServerSettingsConfigurationSet.properties" \
    "${LOCAL_CONFIG_DIR}/schema-charting-schemes.xml" \
    "${LOCAL_CONFIG_DIR}/schema.xml" "${LOCAL_CONFIG_DIR}/security-schema.xml" \
    "${LOCAL_CONFIG_DIR}/mapping-configuration.json" \
    "${LOCAL_CONFIG_DIR}/log4j2.xml" "${COMMON_PATH}"
  mv "${LOCAL_CONFIG_DIR}/schema-results-configuration.xml" "${LOCAL_CONFIG_DIR}/schema-vq-configuration.xml" \
    "${LOCAL_CONFIG_DIR}/schema-source-reference-schema.xml" \
    "${LOCAL_CONFIG_DIR}/command-access-control.xml" \
    "${LOCAL_CONFIG_DIR}/DiscoSolrConfiguration.properties" \
    "${LOCAL_CONFIG_DIR}/connectors-template.json" \
    "${OPAL_SERVICES_PATH}"
  mv "${LOCAL_CONFIG_DIR}/InfoStoreNamesDb2.properties" "${LOCAL_CONFIG_DIR}/InfoStoreNamesSQLServer.properties" "${OPAL_SERVICES_IS_PATH}"
  mv "${LOCAL_CONFIG_DIR}/fmr-match-rules.xml" "${LOCAL_CONFIG_DIR}/system-match-rules.xml" \
    "${LOCAL_CONFIG_DIR}/highlight-queries-configuration.xml" "${LOCAL_CONFIG_DIR}/geospatial-configuration.json" \
    "${LOCAL_CONFIG_DIR}/type-access-configuration.xml" \
    "${LIVE_PATH}"
  rm "${LOCAL_CONFIG_DIR}/extension-references.json" &>/dev/null || true

  createDsidPropertiesForDeploymentPattern "${LOCAL_CONFIG_DIR}/environment/dsid/dsid.properties"

  # Add gateway schemas
  for gateway_short_name in "${!GATEWAY_SHORT_NAME_SET[@]}"; do
    mv "${LOCAL_CONFIG_DIR}/${gateway_short_name}-schema.xml" "${COMMON_PATH}"
    mv "${LOCAL_CONFIG_DIR}/${gateway_short_name}-schema-charting-schemes.xml" "${COMMON_PATH}"
  done
}

function createDataSourceId() {
  local dsid_properties_file_path="${LOCAL_USER_CONFIG_DIR}/environment/dsid/dsid.properties"

  # Ensure this to work for previous release
  local old_dsid_properties_file_path="${LOCAL_USER_CONFIG_DIR}/environment/dsid/dsid.infostore.properties"
  if [[ -f "${old_dsid_properties_file_path}" ]]; then
    mv "${old_dsid_properties_file_path}" "${dsid_properties_file_path}"
  fi
  createDsidPropertiesFile "${dsid_properties_file_path}"
}

function generateBoilerPlateFiles() {
  local all_patterns_config_dir="${LOCAL_TOOLKIT_DIR}/examples/configurations/all-patterns/configuration"
  local toolkit_common_clases_dir="${all_patterns_config_dir}/fragments/common/WEB-INF/classes"
  local toolkit_opal_services_classes_dir="${all_patterns_config_dir}/fragments/opal-services/WEB-INF/classes"

  cp -p "${toolkit_common_clases_dir}/ApolloServerSettingsMandatory.properties" "${GENERATED_LOCAL_CONFIG_DIR}"
  cp -p "${toolkit_common_clases_dir}/ApolloServerSettingsConfigurationSet.properties" "${GENERATED_LOCAL_CONFIG_DIR}"

  echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?><server>
    <webAppSecurity overrideHttpAuthMethod=\"FORM\" allowAuthenticationFailOverToAuthMethod=\"FORM\"  loginFormURL=\"opal/login.html\" loginErrorURL=\"opal/login.html?failed\"/>
    <featureManager>
        <feature>restConnector-2.0</feature>
    </featureManager>
    <applicationMonitor updateTrigger=\"mbean\" dropinsEnabled=\"false\"/>
    <config updateTrigger=\"mbean\"/>
    <administrator-role>
        <user>${I2_ANALYZE_ADMIN}</user>
    </administrator-role>
  </server>" >"${GENERATED_LOCAL_CONFIG_DIR}/server.extensions.dev.xml"
}

function generateConnectorsArtefacts() {
  local connector_references_file=${LOCAL_USER_CONFIG_DIR}/connector-references.json

  local connector_definitions_file=${GENERATED_LOCAL_CONFIG_DIR}/connectors-template.json
  local gateway_properties_file=${GENERATED_LOCAL_CONFIG_DIR}/analyze-connect.properties
  local temp_file=${LOCAL_USER_CONFIG_DIR}/temp.json

  #Find all connector names from connector-references.json and combine connector-definition from each connector together
  IFS=' ' read -ra all_connector_names <<< "$( jq -r '.connectors[].name' < "${connector_references_file}" | xargs)"
  jq -n '. += {connectors: []}' > "${connector_definitions_file}"

  for connector_name in "${all_connector_names[@]}"; do
    local connector_image_dir=${CONNECTOR_IMAGES_DIR}/${connector_name}
    if [[ ! -d "${connector_image_dir}" ]]; then
      printErrorAndExit "Connector image directory ${connector_image_dir} does NOT exist"
    fi

    connector_json=$(cat "${CONNECTOR_IMAGES_DIR}/${connector_name}/connector-definition.json")
    # Remove the "type" from the connectors-definition.json
    connector_json=$(jq -r 'del(.type)' <<< "$connector_json")
    jq -r --argjson connector_json "${connector_json}"\
      '.connectors += [$connector_json]' \
      < "${connector_definitions_file}" > "${temp_file}"
    mv "${temp_file}" "${connector_definitions_file}"
  done

  #Find all gateway schemas declared in connectors
  for connector_name in "${all_connector_names[@]}"; do
    gateway_short_name=$(jq -r '.gatewaySchema' <"${CONNECTOR_IMAGES_DIR}/${connector_name}/connector-definition.json")
    #May not declare a gateway
    if [[ -n ${gateway_short_name} ]]; then
      GATEWAY_SHORT_NAME_SET["${gateway_short_name}"]=$gateway_short_name
    fi
  done

  #Find all gateway schemas declared for this configuration
  readarray -t config_gateway_schemas < <( jq -r '.gatewaySchemas[].shortName' < "${connector_references_file}")

  for gateway_short_name in "${config_gateway_schemas[@]}"; do
    GATEWAY_SHORT_NAME_SET["${gateway_short_name}"]=$gateway_short_name
  done

  echo "# ------------------------ Gateway schemas and charting schemes -----------------------" > "${gateway_properties_file}"
  #Create configuration file
  for gateway_short_name in "${!GATEWAY_SHORT_NAME_SET[@]}"; do
    echo "Gateway.${gateway_short_name}.SchemaResource=${gateway_short_name}-schema.xml" >> "${gateway_properties_file}"
    echo "Gateway.${gateway_short_name}.ChartingSchemesResource=${gateway_short_name}-schema-charting-schemes.xml" >> "${gateway_properties_file}"
  done

  #Copy in gateway schemas
  for gateway_short_name in "${!GATEWAY_SHORT_NAME_SET[@]}"; do
    cp "${GATEWAY_SCHEMA_DIR}/${gateway_short_name}-schema.xml" "${GENERATED_LOCAL_CONFIG_DIR}"
    cp "${GATEWAY_SCHEMA_DIR}/${gateway_short_name}-schema-charting-schemes.xml" "${GENERATED_LOCAL_CONFIG_DIR}"
  done
}

#######################################
# Create .configuration-generated folder
# Arguments:
#   None
#######################################
function generateArtefacts() {
  # Create hidden configuration folder
  rm -rf "${GENERATED_LOCAL_CONFIG_DIR}"
  mkdir -p "${GENERATED_LOCAL_CONFIG_DIR}"
  rsync -qpr \
  --exclude "**.xsd" \
  --exclude "**/connector-references.json" \
  "${LOCAL_USER_CONFIG_DIR}/." "${GENERATED_LOCAL_CONFIG_DIR}"

  generateConnectorsArtefacts
  generateBoilerPlateFiles
}

function subtractArrayFromArray() {
  local -n array1="${1}"
  local -n array2="${2}"
  local new_array

  readarray -t new_array < <(comm -13 --check-order <(printf '%s\n' "${array1[@]}" | LC_ALL=C sort) <(printf '%s\n' "${array2[@]}" | LC_ALL=C sort))

  echo "${new_array[*]}"
}

function deployExtensions() {
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"
  local extension_names
  local extension_args=()

  readarray -t extension_names < <( jq -r '.extensions[].name' < "${extension_references_file}" )

  if [[ -n "${INCLUDED_EXTENSIONS[*]}" ]]; then
    for included_extension in "${INCLUDED_EXTENSIONS[@]}"; do
      extension_args+=(-i "${included_extension}")
    done
  elif [[ -n "${EXCLUDED_EXTENSIONS[*]}" ]]; then
    for excluded_connector in "${EXCLUDED_CONNECTORS[@]}"; do
      extension_args+=(-e "${excluded_extension}")
    done
  fi

  if [[ "${#extension_names[@]}" -gt 0 ]]; then
    print "Deploying i2Analyze extensions"
    "${ROOT_DIR}/utils/deployExtensions.sh" -c "${CONFIG_NAME}" "${extension_args[@]}"
  fi
}

###############################################################################
# End of function definitions.                                                #
###############################################################################