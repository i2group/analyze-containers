#!/usr/bin/env bash
# i2, i2 Group, the i2 Group logo, and i2group.com are trademarks of N.Harris Computer Corporation.
# © N.Harris Computer Corporation (2022-2023)
#
# SPDX short identifier: MIT

set -e

if [[ -z "${ANALYZE_CONTAINERS_ROOT_DIR}" ]]; then
  echo "ANALYZE_CONTAINERS_ROOT_DIR variable is not set"
  echo "This project should be run inside a VSCode Dev Container. For more information read, the Getting Started guide at https://i2group.github.io/analyze-containers/content/getting_started.html"
  exit 1
fi

# Load common functions
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/common_functions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/server_functions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/client_functions.sh"

# Load common variables
source "${ANALYZE_CONTAINERS_ROOT_DIR}/examples/pre-prod/utils/simulated_external_variables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/common_variables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/internal_helper_variables.sh"

warn_root_dir_not_in_path
set_dependencies_tag_if_necessary
###############################################################################
# Stop and remove Liberty                                                     #
###############################################################################
# Stop and remove the existing Liberty containers
print "Removing the Liberty containers"
docker stop "${LIBERTY1_CONTAINER_NAME}" "${LIBERTY2_CONTAINER_NAME}"
docker rm "${LIBERTY1_CONTAINER_NAME}" "${LIBERTY2_CONTAINER_NAME}"

###############################################################################
# Add example Connector to connectors.json                                    #
###############################################################################
print "Updating configuration's connector.json"
cp "${LOCAL_CONFIG_CHANGES_DIR}/connectors.json" "${LOCAL_CONFIG_OPAL_SERVICES_DIR}"

###############################################################################
# Run example Connector to connectors.json                                    #
###############################################################################
run_example_connector "${CONNECTOR2_CONTAINER_NAME}" "${CONNECTOR2_FQDN}" "${CONNECTOR2_CONTAINER_NAME}"
wait_for_connector_to_be_live "${CONNECTOR2_FQDN}"

###############################################################################
# Updating the configuration                                                  #
###############################################################################
# Rebuild liberty container image because the connectors.json has changed
build_liberty_configured_image_for_pre_prod

###############################################################################
# Running the Liberty containers                                              #
###############################################################################
# Run liberties
run_liberty "${LIBERTY1_CONTAINER_NAME}" "${LIBERTY1_FQDN}" "${LIBERTY1_VOLUME_NAME}" "${LIBERTY1_PORT}" "${LIBERTY1_CONTAINER_NAME}"
run_liberty "${LIBERTY2_CONTAINER_NAME}" "${LIBERTY2_FQDN}" "${LIBERTY2_VOLUME_NAME}" "${LIBERTY2_PORT}" "${LIBERTY2_CONTAINER_NAME}"

# Wait for i2 Analyze service to be live
wait_for_i2_analyze_service_to_be_live

print_success "addExampleConnectorWalkthrough.sh has run successfully"
