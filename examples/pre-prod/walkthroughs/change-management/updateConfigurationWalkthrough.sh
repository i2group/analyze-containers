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

set -e

if [[ -z "${ANALYZE_CONTAINERS_ROOT_DIR}" ]]; then
  echo "ANALYZE_CONTAINERS_ROOT_DIR variable is not set"
  echo "Please run '. initShell.sh' in your terminal first or set it with 'export ANALYZE_CONTAINERS_ROOT_DIR=<path_to_root>'"
  exit 1
fi

# Load common functions
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/commonFunctions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/serverFunctions.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/clientFunctions.sh"

# Load common variables
source "${ANALYZE_CONTAINERS_ROOT_DIR}/examples/pre-prod/utils/simulatedExternalVariables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/commonVariables.sh"
source "${ANALYZE_CONTAINERS_ROOT_DIR}/utils/internalHelperVariables.sh"

warnRootDirNotInPath
###############################################################################
# Removing Liberty containers                                                 #
###############################################################################
print "Removing Liberty container"
docker stop "$LIBERTY1_CONTAINER_NAME" "$LIBERTY2_CONTAINER_NAME"
docker rm "$LIBERTY1_CONTAINER_NAME" "$LIBERTY2_CONTAINER_NAME"

###############################################################################
# Updating the configuration                                                  #
###############################################################################
print "Updating configuration with the geospatial-configuration.json file from $LOCAL_CONFIG_CHANGES_DIR"
cp "$LOCAL_CONFIG_CHANGES_DIR/geospatial-configuration.json" "$LOCAL_CONFIG_LIVE_DIR"
buildLibertyConfiguredImageForPreProd

###############################################################################
# Running the Liberty containers                                              #
###############################################################################
print "Running the newly configured Liberty"
runLiberty "$LIBERTY1_CONTAINER_NAME" "$LIBERTY1_FQDN" "$LIBERTY1_VOLUME_NAME" "$LIBERTY1_SECRETS_VOLUME_NAME" "$LIBERTY1_PORT" "$LIBERTY1_CONTAINER_NAME"
runLiberty "$LIBERTY2_CONTAINER_NAME" "$LIBERTY2_FQDN" "$LIBERTY2_VOLUME_NAME" "$LIBERTY1_SECRETS_VOLUME_NAME" "$LIBERTY2_PORT" "$LIBERTY2_CONTAINER_NAME"
waitFori2AnalyzeServiceToBeLive
