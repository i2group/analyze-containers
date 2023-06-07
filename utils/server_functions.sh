#!/usr/bin/env bash
# i2, i2 Group, the i2 Group logo, and i2group.com are trademarks of N.Harris Computer Corporation.
# © N.Harris Computer Corporation (2022-2023)
#
# SPDX short identifier: MIT

###############################################################################
# Start of function definitions                                               #
###############################################################################

#######################################
# Run a Zookeeper server container.
# Arguments:
#   1. ZK container name
#   2. ZK container FQDN
#   3  ZK data volume name
#   4. ZK datalog volume name
#   5. ZK log volume name
#   6. Zoo ID (an identifier for the ZooKeeper server)
#   7. ZK secret location
#   8. ZK secret volume
#######################################
function run_zk() {
  validate_parameters 8 "$@"

  local CONTAINER="$1"
  local FQDN="$2"
  local DATA_VOLUME="$3"
  local DATALOG_VOLUME="$4"
  local LOG_VOLUME="$5"
  local ZOO_ID="$6"
  local SECRET_LOCATION="$7"
  local SECRETS_VOLUME="$8"

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/${SECRET_LOCATION}/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/${SECRET_LOCATION}/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local extra_args=()
  if [[ "${DEV_BUILD}" == "true" ]]; then
    extra_args+=("-p" "${ZK_SECURE_CLIENT_PORT}:2281")
    extra_args+=("-p" "${ZK_CLIENT_PORT}:2181")
  fi

  print "ZooKeeper container ${CONTAINER} is starting"
  docker run -d \
    --name "${CONTAINER}" \
    --net "${DOMAIN_NAME}" \
    --net-alias "${FQDN}" \
    "${extra_args[@]}" \
    -v "${DATA_VOLUME}:/data" \
    -v "${DATALOG_VOLUME}:/datalog" \
    -v "${LOG_VOLUME}:/logs" \
    -v "${SECRETS_VOLUME}:${CONTAINER_SECRETS_DIR}" \
    -e "ZOO_SERVERS=${ZOO_SERVERS}" \
    -e "ZOO_MY_ID=${ZOO_ID}" \
    -e "ZOO_SECURE_CLIENT_PORT=${ZK_SECURE_CLIENT_PORT}" \
    -e "ZOO_CLIENT_PORT=2181" \
    -e "ZOO_4LW_COMMANDS_WHITELIST=ruok, mntr, conf" \
    -e "ZOO_MAX_CLIENT_CNXNS=100" \
    -e "SERVER_SSL=${SOLR_ZOO_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    "${ZOOKEEPER_IMAGE_NAME}:${ZOOKEEPER_VERSION}"
}

#######################################
# Run a Solr server container.
# Arguments:
#   1. Solr container name
#   2. Solr container FQDN
#   3. Solr volume name
#   4. Solr port (on the host machine)
#   5. Solr secret location
#   6. Solr secret volume
#######################################
function run_solr() {
  validate_parameters 6 "$@"

  local CONTAINER="$1"
  local FQDN="$2"
  local VOLUME="$3"
  local HOST_PORT="$4"
  local SECRET_LOCATION="$5"
  local SECRETS_VOLUME="$6"
  local DEBUG_PORT="$7"

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/${SECRET_LOCATION}/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/${SECRET_LOCATION}/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local zk_digest_password
  zk_digest_password=$(get_secret "solr/ZK_DIGEST_PASSWORD")
  local zk_digest_readonly_password
  zk_digest_readonly_password=$(get_secret "solr/ZK_DIGEST_READONLY_PASSWORD")

  local extra_args=()
  if [[ -n "${DEBUG_PORT}" ]]; then
    extra_args+=("-p" "${DEBUG_PORT}:${DEBUG_PORT}")
  fi

  print "Solr container ${CONTAINER} is starting"
  docker run -d \
    --name "${CONTAINER}" \
    --net "${DOMAIN_NAME}" \
    --net-alias "${FQDN}" \
    --init \
    "${extra_args[@]}" \
    -p "${HOST_PORT}":8983 \
    -v "${VOLUME}:/var/solr" \
    -v "${SOLR_BACKUP_VOLUME_NAME}:${SOLR_BACKUP_VOLUME_LOCATION}" \
    -v "${SECRETS_VOLUME}:${CONTAINER_SECRETS_DIR}" \
    -e SOLR_OPTS="-Dsolr.allowPaths=${SOLR_BACKUP_VOLUME_LOCATION} ${SOLR_OPTS}" \
    -e "ZK_HOST=${ZK_HOST}" \
    -e "SOLR_HOST=${FQDN}" \
    -e "ZOO_DIGEST_USERNAME=${ZK_DIGEST_USERNAME}" \
    -e "ZOO_DIGEST_PASSWORD=${zk_digest_password}" \
    -e "ZOO_DIGEST_READONLY_USERNAME=${ZK_DIGEST_READONLY_USERNAME}" \
    -e "ZOO_DIGEST_READONLY_PASSWORD=${zk_digest_readonly_password}" \
    -e "SOLR_ZOO_SSL_CONNECTION=${SOLR_ZOO_SSL_CONNECTION}" \
    -e "SERVER_SSL=${SOLR_ZOO_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    "${SOLR_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

#######################################
# Run a SQL Server container.
# Arguments:
#   None
#######################################
function run_sql_server() {
  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/sqlserver/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/sqlserver/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local sa_initial_password
  sa_initial_password=$(get_secret "sqlserver/sa_INITIAL_PASSWORD")

  local container_data_dir="/var/i2a-data"
  update_volume "${DATA_DIR}" "${I2A_DATA_SERVER_VOLUME_NAME}" "${container_data_dir}"

  print "SQL Server container ${SQL_SERVER_CONTAINER_NAME} is starting"
  docker run -d \
    --name "${SQL_SERVER_CONTAINER_NAME}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${SQL_SERVER_FQDN}" \
    -p "${HOST_PORT_DB}:1433" \
    -v "${SQL_SERVER_VOLUME_NAME}:/var/opt/mssql" \
    -v "${SQL_SERVER_BACKUP_VOLUME_NAME}:${DB_CONTAINER_BACKUP_DIR}" \
    -v "${SQL_SERVER_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    -v "${I2A_DATA_SERVER_VOLUME_NAME}:${container_data_dir}" \
    -e "ACCEPT_EULA=${ACCEPT_EULA}" \
    -e "MSSQL_AGENT_ENABLED=true" \
    -e "MSSQL_PID=${MSSQL_PID}" \
    -e "SA_PASSWORD=${sa_initial_password}" \
    -e "SERVER_SSL=${DB_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    "${SQL_SERVER_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

#######################################
# Run a Postgres Server container.
# Arguments:
#   None
#######################################
function run_postgres_server() {
  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/postgres/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/postgres/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local postgres_initial_password
  postgres_initial_password=$(get_secret "postgres/postgres_INITIAL_PASSWORD")

  local container_data_dir="/var/i2a-data"
  update_volume "${DATA_DIR}" "${I2A_DATA_SERVER_VOLUME_NAME}" "${container_data_dir}"

  print "Postgres Server container ${POSTGRES_SERVER_CONTAINER_NAME} is starting"
  docker run -d \
    --name "${POSTGRES_SERVER_CONTAINER_NAME}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${POSTGRES_SERVER_FQDN}" \
    -p "${HOST_PORT_DB}:5432" \
    -v "${POSTGRES_SERVER_VOLUME_NAME}:/var/lib/postgresql" \
    -v "${POSTGRES_SERVER_BACKUP_VOLUME_NAME}:${DB_CONTAINER_BACKUP_DIR}" \
    -v "${POSTGRES_SERVER_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    -v "${I2A_DATA_SERVER_VOLUME_NAME}:${container_data_dir}" \
    -e "POSTGRES_USER=${POSTGRES_USER}" \
    -e "POSTGRES_PASSWORD=${postgres_initial_password}" \
    -e "SERVER_SSL=${DB_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    "${POSTGRES_SERVER_IMAGE_NAME}:${POSTGRES_IMAGE_VERSION}"
}

#######################################
# Run a Db2 Server container.
# Arguments:
#   None
#######################################
function run_db2_server() {
  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/db2server/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/db2server/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local db2inst1_initial_password
  db2inst1_initial_password=$(get_secret "db2server/db2inst1_INITIAL_PASSWORD")

  local container_data_dir="/var/i2a-data"
  update_volume "${DATA_DIR}" "${I2A_DATA_SERVER_VOLUME_NAME}" "${container_data_dir}"

  print "Db2 Server container ${DB2_SERVER_CONTAINER_NAME} is starting"
  docker run -d \
    --privileged=true \
    --name "${DB2_SERVER_CONTAINER_NAME}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${DB2_SERVER_FQDN}" \
    -p "${HOST_PORT_DB}:50000" \
    -v "${DB2_SERVER_BACKUP_VOLUME_NAME}:${DB_CONTAINER_BACKUP_DIR}" \
    -v "${DB2_SERVER_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    -v "${DB2_SERVER_VOLUME_NAME}:/database/data" \
    -v "${I2A_DATA_SERVER_VOLUME_NAME}:${container_data_dir}" \
    -e "LICENSE=${DB2_LICENSE}" \
    -e "DB_INSTALL_DIR=${DB_INSTALL_DIR}" \
    -e "DB2INST1_PASSWORD=${db2inst1_initial_password}" \
    -e "SERVER_SSL=${DB_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    "${DB2_SERVER_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

#######################################
# Run a Liberty Server container.
# Arguments:
#   1. Liberty container name
#   2. Liberty container FQDN
#   3. Liberty volume name
#   4  Liberty secret volume name
#   5. Liberty port (on the host machine)
#   6. Liberty key folder
#   7. (Optional) Liberty debug port (will be exposed as the same port)
#######################################
function run_liberty() {
  validate_parameters 6 "$@"

  local CONTAINER="$1"
  local FQDN="$2"
  local VOLUME="$3"
  local SECRET_VOLUME="$4"
  local HOST_PORT="$5"
  local KEY_FOLDER="$6"
  local DEBUG_PORT="$7"

  local liberty_start_command=()
  local db_environment=("-e" "DB_DIALECT=${DB_DIALECT}" "-e" "DB_PORT=${DB_PORT}")

  # TODO: Remove after a major upgrade
  if [[ -n "${DEBUG_LIBERTY_SERVERS}" ]]; then
    print_warn "DEBUG_LIBERTY_SERVERS has been deprecated. Please use LIBERTY_DEBUG=\"true\" instead."
    if [[ ${DEBUG_LIBERTY_SERVERS[*]} =~ (^|[[:space:]])"${CONTAINER}"($|[[:space:]]) ]]; then
      LIBERTY_DEBUG="true"
    else
      LIBERTY_DEBUG="false"
    fi
  fi

  local ssl_outbound_private_key
  ssl_outbound_private_key=$(get_secret "certificates/gateway_user/server.key")
  local ssl_certificate
  ssl_outbound_certificate=$(get_secret "certificates/gateway_user/server.cer")
  local ssl_ca_certificate
  ssl_outbound_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local zk_digest_password
  zk_digest_password=$(get_secret "solr/ZK_DIGEST_PASSWORD")

  local solr_application_digest_password
  solr_application_digest_password=$(get_secret "solr/SOLR_APPLICATION_DIGEST_PASSWORD")

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/${KEY_FOLDER}/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/${KEY_FOLDER}/server.cer")
  local ssl_ca_certificate

  if [[ "${ENVIRONMENT}" == "config-dev" ]]; then
    if [[ -f "${LOCAL_USER_CONFIG_DIR}/secrets/app-secrets.json" ]]; then
      app_secrets=$(cat "${LOCAL_USER_CONFIG_DIR}/secrets/app-secrets.json")
    else
      app_secrets="None"
    fi

    if [[ -f "${LOCAL_USER_CONFIG_DIR}"/secrets/additional-trust-certificates.cer ]]; then
      ssl_additional_trust_certificates=$(cat "${LOCAL_USER_CONFIG_DIR}"/secrets/additional-trust-certificates.cer)
    fi

    ssl_ca_certificate=$(get_secret "certificates/externalCA/CA.cer")
  else
    ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")
  fi

  local db_password
  case "${DB_DIALECT}" in
  db2)
    db_password=$(get_secret "db2server/db2inst1_PASSWORD")
    db_environment+=("-e" "DB_SERVER=${DB2_SERVER_FQDN}")
    db_environment+=("-e" "DB_NODE=${DB_NODE}")
    db_environment+=("-e" "DB_USERNAME=${DB2INST1_USERNAME}")
    ;;
  sqlserver)
    db_password=$(get_secret "sqlserver/i2analyze_PASSWORD")
    db_environment+=("-e" "DB_SERVER=${SQL_SERVER_FQDN}")
    db_environment+=("-e" "DB_USERNAME=${I2_ANALYZE_USERNAME}")
    ;;
  postgres)
    db_password=$(get_secret "postgres/i2analyze_PASSWORD")
    db_environment+=("-e" "DB_SERVER=${POSTGRES_SERVER_FQDN}")
    db_environment+=("-e" "DB_USERNAME=${I2_ANALYZE_USERNAME}")
    ;;
  esac
  db_environment+=("-e" "DB_PASSWORD=${db_password}")

  if [[ "${LIBERTY_DEBUG}" == "false" ]]; then
    print "Liberty container ${CONTAINER} is starting"
    liberty_start_command+=("${LIBERTY_CONFIGURED_IMAGE_NAME}:${I2A_LIBERTY_CONFIGURED_IMAGE_TAG}")
  else
    print "Liberty container ${CONTAINER} is starting in debug mode"
    if [ -z "$6" ]; then
      echo "No Debug port provided to run_liberty. Debug port must be set if running a container in debug mode!" >&2
      exit 1
    fi

    liberty_start_command+=("-p")
    liberty_start_command+=("${DEBUG_PORT}:${DEBUG_PORT}")
    liberty_start_command+=("-e")
    liberty_start_command+=("WLP_DEBUG_ADDRESS=0.0.0.0:${DEBUG_PORT}")
    liberty_start_command+=("-e")
    liberty_start_command+=("WLP_DEBUG_SUSPEND=${WLP_DEBUG_SUSPEND}")
    liberty_start_command+=("${LIBERTY_CONFIGURED_IMAGE_NAME}:${I2A_LIBERTY_CONFIGURED_IMAGE_TAG}")
    liberty_start_command+=("/opt/ol/wlp/bin/server")
    liberty_start_command+=("debug")
    liberty_start_command+=("defaultServer")
  fi

  #Pass in mappings environment if there is one
  if [[ "${ENVIRONMENT}" == "config-dev" && -f "${CONNECTOR_IMAGES_DIR}/connector-url-mappings-file.json" ]]; then
    CONNECTOR_URL_MAP=$(cat "${CONNECTOR_IMAGES_DIR}"/connector-url-mappings-file.json)
  fi

  if [[ "${LIBERTY_SSL_CONNECTION}" == "true" ]]; then
    CONTAINER_PORT=9443
  else
    CONTAINER_PORT=9080
  fi

  docker run -m 2g -d \
    --name "${CONTAINER}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${FQDN}" \
    -p "${HOST_PORT}:${CONTAINER_PORT}" \
    -v "${SECRET_VOLUME}:${CONTAINER_SECRETS_DIR}" \
    -v "${VOLUME}:/data" \
    -e "LICENSE=${LIC_AGREEMENT}" \
    "${db_environment[@]}" \
    -e "ZK_HOST=${ZK_MEMBERS}" \
    -e "ZOO_DIGEST_USERNAME=${ZK_DIGEST_USERNAME}" \
    -e "ZOO_DIGEST_PASSWORD=${zk_digest_password}" \
    -e "SOLR_HTTP_BASIC_AUTH_USER=${SOLR_APPLICATION_DIGEST_USERNAME}" \
    -e "SOLR_HTTP_BASIC_AUTH_PASSWORD=${solr_application_digest_password}" \
    -e "DB_SSL_CONNECTION=${DB_SSL_CONNECTION}" \
    -e "SOLR_ZOO_SSL_CONNECTION=${SOLR_ZOO_SSL_CONNECTION}" \
    -e "SERVER_SSL=${LIBERTY_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    -e "APP_SECRETS=${app_secrets}" \
    -e "SSL_ADDITIONAL_TRUST_CERTIFICATES=${ssl_additional_trust_certificates}" \
    -e "GATEWAY_SSL_CONNECTION=${GATEWAY_SSL_CONNECTION}" \
    -e "SSL_OUTBOUND_PRIVATE_KEY=${ssl_outbound_private_key}" \
    -e "SSL_OUTBOUND_CERTIFICATE=${ssl_outbound_certificate}" \
    -e "SSL_OUTBOUND_CA_CERTIFICATE=${ssl_outbound_ca_certificate}" \
    -e "LIBERTY_HADR_MODE=1" \
    -e "LIBERTY_HADR_POLL_INTERVAL=1" \
    -e "CONNECTOR_URL_MAP=${CONNECTOR_URL_MAP}" \
    "${liberty_start_command[@]}"

  if [[ "${LIBERTY_DEBUG}" == "true" && "${WLP_DEBUG_SUSPEND}" == "y" ]]; then
    # Wait until debugger is attached
    wait_for_user_reply "You need to attach the debugger now before continuing. Ready?"
  fi
}

function create_data_source_properties() {
  local folder_path="$1"
  local datasource_properties_file_path="${folder_path}/DataSource.properties"
  local dsid_properties_file_path
  local topology_id

  if [[ "${DEPLOYMENT_PATTERN}" != "i2c" ]]; then
    topology_id="infostore"
  else
    topology_id="opalDAOD"
  fi
  dsid_properties_file_path="${LOCAL_CONFIG_DIR}/environment/dsid/dsid.${topology_id}.properties"
  cp "${dsid_properties_file_path}" "${datasource_properties_file_path}"

  add_data_source_properties_if_necessary "${datasource_properties_file_path}"

  if [[ "${DEPLOYMENT_PATTERN}" != "i2c" ]] && [[ "${DEPLOYMENT_PATTERN}" != "schema_dev" ]]; then
    sed -i.bak -e '/DataSourceId.*/d' "${datasource_properties_file_path}"
  fi
  if ! grep -xq "IsMonitored=.*" "${datasource_properties_file_path}"; then
    add_to_properties_file "IsMonitored=true" "${datasource_properties_file_path}"
  fi

  add_to_properties_file "AppName=opal-services" "${datasource_properties_file_path}"
}

#######################################
# Build a configured Liberty image.
# Arguments:
#   None
#######################################
function build_liberty_configured_image() {
  local liberty_configured_path="${IMAGES_DIR}/liberty_ubi_combined"
  local liberty_configured_classes_folder_path="${liberty_configured_path}/classes"
  local liberty_configured_lib_folder_path="${liberty_configured_path}/lib"
  local liberty_configured_plugins_folder_path="${liberty_configured_path}/plugins"
  local liberty_configured_web_app_files_folder_path="${liberty_configured_path}/application/web-app-files"
  local extension_references_file="${LOCAL_USER_CONFIG_DIR}/extension-references.json"
  local extension_dependencies_path="${EXTENSIONS_DIR}/extension-dependencies.json"
  local plugin_references_file="${LOCAL_USER_CONFIG_DIR}/plugin-references.json"

  print "Building Liberty image"

  delete_folder_if_exists_and_create "${liberty_configured_classes_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_lib_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_plugins_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_web_app_files_folder_path}"

  create_data_source_properties "${liberty_configured_classes_folder_path}"

  cp -r "${LOCAL_CONFIG_DIR}/fragments/common/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/opal-services/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/opal-services-is/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/live/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/liberty/user.registry.xml" "${liberty_configured_path}/"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/common/privacyagreement.html" "${liberty_configured_path}/"

  # Copy extra configuration files into the classes directory
  find "${LOCAL_CONFIG_DIR}" -maxdepth 1 -type f \
    ! -name privacyagreement.html \
    ! -name user.registry.xml \
    ! -name extension-references.json \
    ! -name plugin-references.json \
    ! -name connector-references.json \
    ! -name server.extensions.xml \
    ! -name server.extensions.dev.xml \
    ! -name web.xml \
    ! -name jvm.options \
    ! -name '*.bak' \
    ! -name '*.xsd' \
    -exec cp -t "${liberty_configured_classes_folder_path}" {} \;

  # Copy extensions to the liberty image
  delete_folder_if_exists_and_create "${liberty_configured_lib_folder_path}"
  readarray -t extension_files < <(jq -r '.extensions[] | .name + "-" + .version' <"${extension_references_file}")
  create_folder "${PREVIOUS_CONFIGURATION_DIR}/lib"
  for extension in "${extension_files[@]}"; do
    # shellcheck disable=SC2001
    extension_name=$(echo "${extension}" | sed 's|\(.*\)-.*|\1|')
    is_code_extension="true"
    if [[ ! -f "${EXTENSIONS_DIR}/${extension_name}/target/${extension}.jar" ]]; then
      if [[ ! $(find -L "${EXTENSIONS_DIR}/${extension_name}" -mindepth 1 -maxdepth 1 -name "*.jar" -type f -print0 | xargs -0) ]]; then
        echo "Extension does NOT exist: ${EXTENSIONS_DIR}/${extension_name}/target/${extension}.jar"
        continue
      fi
      is_code_extension="false"
    fi
    # Copy dependencies of the extension
    IFS=' ' read -ra dependencies <<<"$(jq -r --arg name "${extension_name}" '.[] | select(.name == $name) | .dependencies[]' "${extension_dependencies_path}" | xargs)"
    for dependency_name in "${dependencies[@]}"; do
      if [[ ! -f "${EXTENSIONS_DIR}/${dependency_name}/pom.xml" ]]; then
        find -L "${EXTENSIONS_DIR}/${dependency_name}" -mindepth 1 -maxdepth 1 -name "*.jar" -type f -exec cp -p {} "${liberty_configured_lib_folder_path}" \;
      else
        local dependency_version
        dependency_version="$(xmlstarlet sel -t -v "/project/version" "${EXTENSIONS_DIR}/${dependency_name}/pom.xml")"
        cp "${EXTENSIONS_DIR}/${dependency_name}/target/${dependency_name}-${dependency_version}.jar" "${liberty_configured_lib_folder_path}"
      fi
      cp -p "${PREVIOUS_EXTENSIONS_DIR}/${dependency_name}.sha512" "${PREVIOUS_CONFIGURATION_DIR}/lib"
    done
    # Copy the extension
    if [[ "${is_code_extension}" == "false" ]]; then
      find -L "${EXTENSIONS_DIR}/${extension_name}" -mindepth 1 -maxdepth 1 -name "*.jar" -type f -exec cp -p {} "${liberty_configured_lib_folder_path}" \;
    else
      cp "${EXTENSIONS_DIR}/${extension_name}/target/${extension}.jar" "${liberty_configured_lib_folder_path}"
    fi
    cp -p "${PREVIOUS_EXTENSIONS_DIR}/${extension_name}.sha512" "${PREVIOUS_CONFIGURATION_DIR}/lib"
  done

  # Copy plugins to the liberty image
  readarray -t plugin_files < <(jq -r '.plugins[] | .name' <"${plugin_references_file}")
  create_folder "${PREVIOUS_CONFIGURATION_DIR}/plugins"
  for plugin in "${plugin_files[@]}"; do
    # shellcheck disable=SC2001
    if [[ ! -f "${PLUGINS_DIR}/${plugin}/entrypoint.js" ]]; then
      echo "Plugin entry point does NOT exist: ${PLUGINS_DIR}/${plugin}/entrypoint.js"
      continue
    fi
    if [[ ! -f "${PLUGINS_DIR}/${plugin}/plugin.json" ]]; then
      echo "Plugin manifest does NOT exist: ${PLUGINS_DIR}/${plugin}/plugin.json"
      continue
    fi
    create_folder "${liberty_configured_plugins_folder_path}/${plugin}"
    cp -r "${PLUGINS_DIR}/${plugin}/." "${liberty_configured_plugins_folder_path}/${plugin}"
    cp -p "${PREVIOUS_PLUGINS_DIR}/${plugin}.sha512" "${PREVIOUS_CONFIGURATION_DIR}/plugins"
  done

  # Copy server extensions
  if [[ -f "${LOCAL_CONFIG_DIR}/liberty/server.extensions.xml" ]]; then
    cp -r "${LOCAL_CONFIG_DIR}/liberty/server.extensions.xml" "${liberty_configured_path}/"
  else
    echo '<?xml version="1.0" encoding="UTF-8"?><server/>' >"${liberty_configured_path}/server.extensions.xml"
  fi
  if [[ "${DEV_LIBERTY_SERVER_EXTENSIONS}" == "true" ]]; then
    cp -r "${LOCAL_CONFIG_DIR}/liberty/server.extensions.dev.xml" "${liberty_configured_path}/"
  else
    echo '<?xml version="1.0" encoding="UTF-8"?><server/>' >"${liberty_configured_path}/server.extensions.dev.xml"
  fi

  # Copy catalog.json & web.xml specific to the DEPLOYMENT_PATTERN
  cp -r "${TOOLKIT_APPLICATION_DIR}/target-mods/${CATALOGUE_TYPE}/catalog.json" "${liberty_configured_classes_folder_path}"
  if [[ -f "${LOCAL_CONFIG_DIR}/liberty/web.xml" ]]; then
    cp -r "${LOCAL_CONFIG_DIR}/liberty/web.xml" "${liberty_configured_web_app_files_folder_path}/web.xml"
  else
    cp -r "${TOOLKIT_APPLICATION_DIR}/fragment-mods/${APPLICATION_BASE_TYPE}/WEB-INF/web.xml" "${liberty_configured_web_app_files_folder_path}/web.xml"
    sed -i.bak -e '1s/^/<?xml version="1.0" encoding="UTF-8"?><web-app xmlns="http:\/\/java.sun.com\/xml\/ns\/javaee" xmlns:xsi="http:\/\/www.w3.org\/2001\/XMLSchema-instance" xsi:schemaLocation="http:\/\/java.sun.com\/xml\/ns\/javaee http:\/\/java.sun.com\/xml\/ns\/javaee\/web-app_3_0.xsd" id="WebApp_ID" version="3.0"> <display-name>opal<\/display-name>/' \
      "${liberty_configured_web_app_files_folder_path}/web.xml"
    echo '</web-app>' >>"${liberty_configured_web_app_files_folder_path}/web.xml"
  fi
  if [[ -f "${LOCAL_CONFIG_DIR}/liberty/jvm.options" ]]; then
    cp -r "${LOCAL_CONFIG_DIR}/liberty/jvm.options" "${liberty_configured_path}/"
  fi

  # In the schema_dev deployment point Gateway schemes to the ISTORE schemes
  if [[ "${DEPLOYMENT_PATTERN}" == "schema_dev" ]]; then
    sed -i 's/^SchemaResource=/Gateway.External.SchemaResource=/' "${liberty_configured_classes_folder_path}/ApolloServerSettingsMandatory.properties"
    sed -i 's/^ChartingSchemesResource=/Gateway.External.ChartingSchemesResource=/' "${liberty_configured_classes_folder_path}/ApolloServerSettingsMandatory.properties"
  fi

  docker build \
    -t "${LIBERTY_CONFIGURED_IMAGE_NAME}:${I2A_LIBERTY_CONFIGURED_IMAGE_TAG}" \
    "${IMAGES_DIR}/liberty_ubi_combined" \
    --build-arg "BASE_IMAGE=${LIBERTY_BASE_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

#######################################
# Build a configured Liberty image.
# Arguments:
#   None
#######################################
function build_liberty_configured_image_for_pre_prod() {
  local liberty_configured_path="${IMAGES_DIR}/liberty_ubi_combined"
  local liberty_configured_classes_folder_path="${liberty_configured_path}/classes"
  local liberty_configured_lib_folder_path="${liberty_configured_path}/lib"
  local liberty_configured_plugins_folder_path="${liberty_configured_path}/plugins"
  local liberty_configured_web_app_files_folder_path="${liberty_configured_path}/application/web-app-files"

  print "Building Liberty image"

  delete_folder_if_exists_and_create "${liberty_configured_classes_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_lib_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_plugins_folder_path}"
  delete_folder_if_exists_and_create "${liberty_configured_web_app_files_folder_path}"

  create_data_source_properties "${liberty_configured_classes_folder_path}"

  # Updating mpMetrics authentication value
  xmlstarlet edit -L --update "/server/mpMetrics/@authentication" \
    --value "${LIBERTY_SSL_CONNECTION}" \
    "${LOCAL_CONFIG_DIR}/liberty/server.extensions.xml"

  cp -r "${LOCAL_CONFIG_DIR}/fragments/common/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/opal-services/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/opal-services-is/WEB-INF/classes/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/live/." "${liberty_configured_classes_folder_path}"
  cp -r "${LOCAL_CONFIG_DIR}/liberty/server.extensions.xml" "${liberty_configured_path}/"
  cp -r "${LOCAL_CONFIG_DIR}/user.registry.xml" "${liberty_configured_path}/"
  cp -r "${LOCAL_CONFIG_DIR}/fragments/common/privacyagreement.html" "${liberty_configured_path}/"

  # Copy catalog.json & web.xml specific to the DEPLOYMENT_PATTERN
  cp -pr "${TOOLKIT_APPLICATION_DIR}/target-mods/${CATALOGUE_TYPE}/catalog.json" "${liberty_configured_classes_folder_path}"
  cp -pr "${TOOLKIT_APPLICATION_DIR}/fragment-mods/${APPLICATION_BASE_TYPE}/WEB-INF/web.xml" "${liberty_configured_web_app_files_folder_path}/web.xml"

  sed -i.bak -e '1s/^/<?xml version="1.0" encoding="UTF-8"?><web-app xmlns="http:\/\/java.sun.com\/xml\/ns\/javaee" xmlns:xsi="http:\/\/www.w3.org\/2001\/XMLSchema-instance" xsi:schemaLocation="http:\/\/java.sun.com\/xml\/ns\/javaee http:\/\/java.sun.com\/xml\/ns\/javaee\/web-app_3_0.xsd" id="WebApp_ID" version="3.0"> <display-name>opal<\/display-name>/' \
    "${liberty_configured_web_app_files_folder_path}/web.xml"
  echo '</web-app>' >>"${liberty_configured_web_app_files_folder_path}/web.xml"

  echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?><server>
    <featureManager>
        <feature>restConnector-2.0</feature>
    </featureManager>
    <administrator-role>
        <user>${I2_ANALYZE_ADMIN}</user>
    </administrator-role>
  </server>" >"${liberty_configured_path}/server.extensions.dev.xml"

  docker build \
    -t "${LIBERTY_CONFIGURED_IMAGE_NAME}:${I2A_LIBERTY_CONFIGURED_IMAGE_TAG}" \
    "${IMAGES_DIR}/liberty_ubi_combined" \
    --build-arg "BASE_IMAGE=${LIBERTY_BASE_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

#######################################
# Run a Load Balancer container.
# Arguments:
#   None
#######################################
function run_load_balancer() {
  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/i2analyze/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/i2analyze/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  local load_balancer_config_dir="/usr/local/etc/haproxy"
  update_volume "${PRE_PROD_DIR}/load-balancer" "${LOAD_BALANCER_VOLUME_NAME}" "${load_balancer_config_dir}"

  print "Load balancer container ${LOAD_BALANCER_CONTAINER_NAME} is starting"
  docker run -d \
    --name "${LOAD_BALANCER_CONTAINER_NAME}" \
    --net "${DOMAIN_NAME}" \
    --net-alias "${I2_ANALYZE_FQDN}" \
    -p "9046:9046" \
    -v "${LOAD_BALANCER_VOLUME_NAME}:${load_balancer_config_dir}" \
    -v "${LOAD_BALANCER_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    -e "LIBERTY1_LB_STANZA=${LIBERTY1_LB_STANZA}" \
    -e "LIBERTY2_LB_STANZA=${LIBERTY2_LB_STANZA}" \
    -e "LIBERTY_SSL_CONNECTION=${LIBERTY_SSL_CONNECTION}" \
    -e "LIBERTY_SSL=${LIBERTY_SSL}" \
    -e "SERVER_SSL=true" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    "${LOAD_BALANCER_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

function run_example_connector() {
  validate_parameters 4 "$@"

  local CONTAINER="$1"
  local FQDN="$2"
  local KEY_FOLDER="$3"
  local SECRET_VOLUME="$4"

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/${KEY_FOLDER}/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/${KEY_FOLDER}/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  print "Connector container ${CONTAINER} is starting"
  docker run -m 128m -d \
    --name "${CONTAINER}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${FQDN}" \
    -v "${SECRET_VOLUME}:${CONTAINER_SECRETS_DIR}" \
    -e "SSL_ENABLED=${GATEWAY_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    "${CONNECTOR_IMAGE_NAME}:${I2A_DEPENDENCIES_IMAGES_TAG}"
}

function run_connector() {
  validate_parameters 4 "$@"

  local CONTAINER="$1"
  local FQDN="$2"
  local connector_name="$3"
  local connector_tag="$4"
  local connector_id="$5"
  local connector_path="${connector_name}"

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/${connector_path}/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/${connector_path}/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  print "Connector container ${CONTAINER} is starting"
  docker run -d \
    --name "${CONTAINER}" \
    --network "${DOMAIN_NAME}" \
    --net-alias "${FQDN}" \
    -v "${connector_name}_secrets:${CONTAINER_SECRETS_DIR}" \
    -e "CONNECTOR_ID=${connector_id}" \
    -e "SSL_ENABLED=${GATEWAY_SSL_CONNECTION}" \
    -e "SSL_PRIVATE_KEY=${ssl_private_key}" \
    -e "SSL_CERTIFICATE=${ssl_certificate}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    -e "SSL_GATEWAY_CN=${I2_GATEWAY_USERNAME}" \
    -e "SSL_SERVER_PORT=3443" \
    "${CONNECTOR_IMAGE_BASE_NAME}${connector_name}:${connector_tag}"
}

function run_prometheus() {
  local prometheus_tmp_config_dir="/tmp/prometheus"
  local prometheus_start_command=()

  local prometheus_password
  prometheus_password=$(get_prometheus_admin_password)
  local liberty_admin_password
  liberty_admin_password=$(get_application_admin_password)

  local ssl_private_key
  ssl_private_key=$(get_secret "certificates/prometheus/server.key")
  local ssl_certificate
  ssl_certificate=$(get_secret "certificates/prometheus/server.cer")
  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/externalCA/CA.cer")

  local ssl_outbound_private_key
  ssl_outbound_private_key=$(get_secret "certificates/gateway_user/server.key")
  local ssl_certificate
  ssl_outbound_certificate=$(get_secret "certificates/gateway_user/server.cer")
  local ssl_ca_certificate
  ssl_outbound_ca_certificate=$(get_secret "certificates/CA/CA.cer")

  if [[ "${ENVIRONMENT}" == "config-dev" ]]; then
    prometheus_start_command+=("-e" "PROMETHEUS_USERNAME=${PROMETHEUS_USERNAME}")
    prometheus_start_command+=("-e" "PROMETHEUS_PASSWORD=${prometheus_password}")
    prometheus_start_command+=("-e" "LIBERTY_ADMIN_USERNAME=${I2_ANALYZE_ADMIN}")
    prometheus_start_command+=("-e" "LIBERTY_ADMIN_PASSWORD=${liberty_admin_password}")
    prometheus_start_command+=("-e" "LIBERTY_SSL_CONNECTION=${LIBERTY_SSL_CONNECTION}")
    prometheus_start_command+=("-e" "SERVER_SSL=${PROMETHEUS_SSL_CONNECTION}")
    prometheus_start_command+=("-e" "SSL_PRIVATE_KEY=${ssl_private_key}")
    prometheus_start_command+=("-e" "SSL_CERTIFICATE=${ssl_certificate}")
    prometheus_start_command+=("-e" "SSL_CA_CERTIFICATE=${ssl_ca_certificate}")
    prometheus_start_command+=("-e" "SSL_OUTBOUND_PRIVATE_KEY=${ssl_outbound_private_key}")
    prometheus_start_command+=("-e" "SSL_OUTBOUND_CERTIFICATE=${ssl_outbound_certificate}")
    prometheus_start_command+=("-e" "SSL_OUTBOUND_CA_CERTIFICATE=${ssl_outbound_ca_certificate}")
  fi

  check_file_exists "${LOCAL_PROMETHEUS_CONFIG_DIR}/prometheus.yml"
  update_volume "${LOCAL_PROMETHEUS_CONFIG_DIR}" "${PROMETHEUS_CONFIG_VOLUME_NAME}" "${prometheus_tmp_config_dir}"

  print "Prometheus container ${PROMETHEUS_CONTAINER_NAME} is starting"
  docker run -d \
    --name "${PROMETHEUS_CONTAINER_NAME}" \
    --net "${DOMAIN_NAME}" \
    --net-alias "${PROMETHEUS_FQDN}" \
    -p "${HOST_PORT_PROMETHEUS}:9090" \
    -v "${PROMETHEUS_CONFIG_VOLUME_NAME}:${prometheus_tmp_config_dir}" \
    -v "${PROMETHEUS_DATA_VOLUME_NAME}:/prometheus" \
    -v "${PROMETHEUS_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    "${prometheus_start_command[@]}" \
    "${PROMETHEUS_IMAGE_NAME}:${PROMETHEUS_VERSION}"
}

function run_grafana() {
  local grafana_provisioning_dir="/etc/grafana/provisioning"
  local grafana_dashboards_dir="/etc/grafana/dashboards"
  update_volume "${LOCAL_GRAFANA_CONFIG_DIR}/provisioning" "${GRAFANA_PROVISIONING_VOLUME_NAME}" "${grafana_provisioning_dir}"
  update_grafana_dashboard_volume

  local grafana_password
  grafana_password=$(get_secret "grafana/admin_PASSWORD")

  local prometheus_password
  prometheus_password=$(get_prometheus_admin_password)

  local ssl_ca_certificate
  ssl_ca_certificate=$(get_secret "certificates/externalCA/CA.cer")

  local prometheus_scheme="http"
  if [[ "${PROMETHEUS_SSL_CONNECTION}" == "true" ]]; then
    prometheus_scheme="https"
  fi
  local prometheus_url="${prometheus_scheme}://${PROMETHEUS_FQDN}:9090"

  print "Grafana container ${GRAFANA_CONTAINER_NAME} is starting"
  docker run -d \
    -p "${HOST_PORT_GRAFANA}:3000" \
    --name="${GRAFANA_CONTAINER_NAME}" \
    --net "${DOMAIN_NAME}" \
    --net-alias "${GRAFANA_FQDN}" \
    -v "${GRAFANA_DATA_VOLUME_NAME}:/var/lib/grafana" \
    -v "${GRAFANA_DASHBOARDS_VOLUME_NAME}:${grafana_dashboards_dir}" \
    -v "${GRAFANA_PROVISIONING_VOLUME_NAME}:${grafana_provisioning_dir}" \
    -v "${GRAFANA_SECRETS_VOLUME_NAME}:${CONTAINER_SECRETS_DIR}" \
    -e "GF_SECURITY_ADMIN_USER=${GRAFANA_USERNAME}" \
    -e "GF_SECURITY_ADMIN_PASSWORD=${grafana_password}" \
    -e "GF_SERVER_PROTOCOL=https" \
    -e "GF_SERVER_CERT_FILE=/run/secrets/server.cer" \
    -e "GF_SERVER_CERT_KEY=/run/secrets/server.key" \
    -e "PROMETHEUS_URL=${prometheus_url}" \
    -e "PROMETHEUS_USERNAME=${PROMETHEUS_USERNAME}" \
    -e "PROMETHEUS_PASSWORD=${prometheus_password}" \
    -e "SSL_CA_CERTIFICATE=${ssl_ca_certificate}" \
    "${GRAFANA_IMAGE_NAME}:${GRAFANA_VERSION}"
}

###############################################################################
# End of function definitions                                                 #
###############################################################################
