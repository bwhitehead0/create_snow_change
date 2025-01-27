#!/bin/bash

set -euo pipefail

# set DEBUG to false, will be evaluated in main()
DEBUG=false

# error output function
err() {
  # date format year-month-day hour:minute:second.millisecond+timezone - requires coreutils date
    echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N%z') - Error - $1" >&2
}

dbg() {
  # date format year-month-day hour:minute:second.millisecond+timezone - requires coreutils date
  if [[ "$DEBUG" == true ]]; then
    echo "$(date +'%Y-%m-%dT%H:%M:%S.%3N%z') - Debug - $1" >&2
  fi
}

# check if required apps are installed
check_application_installed() {
    dbg "check_application_installed(): Checking if $1 is installed."

    if [ -x "$(command -v "${1}")" ]; then
      true
    else
      false
    fi
}

# URL encode the CI name
url_encode_string() {
    local input="$1"
    local output=""

    dbg "url_encode_string(): Encoding string: $input"

    for (( i=0; i<${#input}; i++ )); do
        char="${input:i:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) 
                output+="$char"
                ;;
            *)
                output+=$(printf '%%%02X' "'$char")
                ;;
        esac
    done
    dbg "url_encode_string(): Encoded string: $output"
    echo "$output"
}

# get sys_id
get_ci_sys_id() {
  # needs: timeout, ci_name, sn_url, (username & password or token)
  # ${sn_url}/api/now/table/cmdb_ci_service_discovered?sysparm_fields=name,sys_id&timeout=${timeout}&sysparm_query=name=${encoded_ci_name}
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly
  
  local ci_name=""
  local encoded_ci_name=""
  local timeout="60"
  local sn_url=""
  local username=""
  local password=""
  local token=""
  local response=""
  local sys_id=""
  local ci_name=""

  # parse arguments
  while getopts ":c:l:u:p:t:o:" arg; do
    case "${arg}" in
      c) ci_name="${OPTARG}" ;;
      l) sn_url="$OPTARG" ;;
      u) username="$OPTARG" ;;
      p) password="$OPTARG" ;;
      t) token="$OPTARG" ;;
      o) timeout="$OPTARG" ;;
      *)
        err "Invalid option: -$OPTARG"
        exit 1
        ;;
    esac
  done

  # Debug output all passed parameters
  dbg "get_ci_sys_id(): All passed parameters:"
  dbg " ci_name: $ci_name"
  dbg " sn_url: $sn_url"
  dbg " username: $username"
  if [[ "$DEBUG_PASS" == true ]]; then
    dbg " password: $password"
  fi
  dbg " token: $token"
  dbg " timeout: $timeout"
  dbg " DEBUG: $DEBUG"
  dbg " DEBUG_PASS: $DEBUG_PASS"

  # validation steps
  # check for required parameters
  # double check this logic around user/pass/token
  if [[ -z "$ci_name" ]]; then
    err "get_ci_sys_id(): Missing required parameter: ci_name."
    exit 1
  fi

  if [[ -z "$sn_url" ]]; then
    err "get_ci_sys_id(): Missing required parameter: sn_url."
    exit 1
  fi

  if [[ -z "$username" && -z "$token" ]]; then
    err "get_ci_sys_id(): Missing required parameter: either username or token."
    exit 1
  fi

  # get encoded_ci_name
  encoded_ci_name=$(url_encode_string "$ci_name")
  dbg "get_ci_sys_id(): encoded_ci_name: ${encoded_ci_name}"

  # build URL
  # break up here so we can add logic around pieces of the API call as needed in the future
  API_ENDPOINT="/api/now/table/cmdb_ci_service_discovered"
  API_PARAMETERS="sysparm_fields=name,sys_id&timeout=${timeout}&sysparm_query=name=""$encoded_ci_name"
  URL="${sn_url}${API_ENDPOINT}?${API_PARAMETERS}"

  dbg "get_ci_sys_id(): URL: ${URL}"

  # if token is set use that, otherwise use username and password
  # if both are set, use token
  # save HTTP response code to variable, API response to file (sys_id.json)
  if [[ -n "$token" ]]; then
    dbg "get_ci_sys_id(): Using token for authentication."
    response=$(curl -k --request GET \
      --location \
      --url "${URL}" \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/json" \
      --silent -w "%{http_code}" -o sys_id.json)
  else
    dbg "get_ci_sys_id(): Using username and password for authentication."
    response=$(curl -k --request GET \
      --location \
      --url "${URL}" \
      --user "${username}:${password}" \
      --header "Accept: application/json" \
      --silent -w "%{http_code}" -o sys_id.json)
  fi

  # check if response is 2xx
  if [[ "$response" =~ ^2 ]]; then
    # HTTP 2xx returned, successful API call. get sys_id and clean up
    # get sys_id from sys_id.json
    # remove sys_id.json
    sys_id=$(jq -r '.result[0].sys_id' sys_id.json)
    rm sys_id.json
    dbg "get_ci_sys_id(): sys_id: ${sys_id}"
    # return sys_id
    echo "${sys_id}"
  else
    err "Failed to get sys_id. HTTP response code: $response"
    exit 1
  fi
}

# create JSON payload
create_json_payload() {
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly

  local description=""
  local short_description=""
  local ci_sys_id=""

  while getopts "c:d:s:" opt; do
    case "$opt" in
      c) ci_sys_id="$OPTARG" ;;
      d) description="$OPTARG" ;;
      s) short_description="$OPTARG" ;;
      *) err "Invalid option: -$OPTARG"; exit 1 ;;
    esac
  done

  # create JSON payload
  # this needs to be way more dynamic - chg_model, x_kpmg3_pit_change_testing_signoff shouldn't be hardcoded, and x_kpmg3_pit_change_testing_signoff looks like a custom field anyway.
  # this likely limits the use of this script to our internal environment, and even then, the differences between prod and nonprod servicenow may make that even more difficult.
  json_payload="{\"chg_model\": \"Standard\", \"description\": \"${description}\", \"short_description\": \"${short_description}\", \"cmdb_ci\": \"${ci_sys_id}\", \"type\": \"Standard\", \"x_kpmg3_pit_change_testing_signoff\": \"PreProd Change\"}"

  dbg "create_json_payload(): json_payload: ${json_payload}"

  # silently validate the JSON
  if ! echo "$json_payload" | jq empty > /dev/null 2>&1; then
    err "Invalid JSON payload. Check input values."
    exit 1
  else
    # return json payload
    echo "${json_payload}"
  fi
}

# create change request
create_chg() {
  # needs: json_payload, sn_url, (username & password or token)
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly
  
  local json_payload=""
  local sn_url=""
  local username=""
  local password=""
  local token=""

  while getopts "j:l:u:p:t:r:" opt; do
    case "$opt" in
      j) json_payload="$OPTARG" ;;
      l) sn_url="$OPTARG" ;;
      u) username="$OPTARG" ;;
      p) password="$OPTARG" ;;
      t) token="$OPTARG" ;;
      r) response_type="$OPTARG" ;;
      *) err "Invalid option: -$OPTARG"; exit 1 ;;
    esac
  done

  # Debug output all passed parameters
  dbg "DEBUG create_chg(): All passed parameters:"
  dbg " json_payload: $json_payload"
  dbg " sn_url: $sn_url"
  dbg " username: $username"
  if [[ "$DEBUG_PASS" == true ]]; then
    dbg " password: $password"
  fi
  dbg " token: $token"
  dbg " DEBUG: $DEBUG"
  dbg " DEBUG_PASS: $DEBUG_PASS"

  # validate required parameters
  if [[ -z "$json_payload" || -z "$sn_url" || (-z "$username" && -z "$token") ]]; then
    err "create_chg(): Missing required parameters: json_payload, sn_url, and either username or token."
    exit 1
  fi

  # build URL
  # break up here so we can add logic around pieces of the API call as needed in the future
  local API_ENDPOINT="/api/sn_chg_rest/v1/change"
  local URL="${sn_url}${API_ENDPOINT}"
  local SHORT_RESPONSE="?sysparm_fields=sys_id,number"

  # filter response if response_type is 'short'
  if [[ "$response_type" == "short" ]]; then
    local URL="${sn_url}${API_ENDPOINT}${SHORT_RESPONSE}"
  fi

  # if token is set use that, otherwise use username and password
  # if both are set, use token
  # save HTTP response code to variable, API response to file (new_chg_response.json)
  if [[ -n "$token" ]]; then
    dbg "create_chg(): Using token for authentication."
    response=$(curl -k --request POST \
      --location \
      --url "${URL}" \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/json" \
      --header "Content-Type: application/json" \
      --data "${json_payload}" \
      --silent -w "%{http_code}" -o new_chg_response.json)
  else
    dbg "create_chg(): Using username and password for authentication."
    response=$(curl -k --request POST \
      --location \
      --url "${URL}" \
      --user "${username}:${password}" \
      --header "Accept: application/json" \
      --header "Content-Type: application/json" \
      --data "${json_payload}" \
      --silent -w "%{http_code}" -o new_chg_response.json)
  fi

  #### ! temporary set response to 400
  # response=400

  # check if response is 2xx
  if [[ "$response" =~ ^2 ]]; then
    # HTTP 2xx, successful API call. return CHG detail payload and clean up
    cat new_chg_response.json
    rm new_chg_response.json 2> /dev/null
  else
    err "Failed to create CHG. HTTP response code: $response"
    err "Full response: $(cat new_chg_response.json)"
    err "Submitted JSON payload: $json_payload"
    # clean up file quietly, error to /dev/null
    rm new_chg_response.json 2> /dev/null
    exit 1
  fi
}

# primary function to grab all passed parameters and call other functions
main() {
  # ! data such as tag, environment, etc should all exist outside of this script. any references passed in should be validated in the workflow, and addressed in description/short_description only.
  dbg "main(): All passed parameters (\$*): $*"

  local ci_name=""
  local ci_sys_id=""
  local sn_url=""
  local description=""
  local short_description=""
  local username=""
  local password=""
  local token=""
  local timeout="60" # default timeout value
  local response_type="short" # default response type
  DEBUG=false
  DEBUG_PASS=false
  # TODO: update debug/debug_pass to accept true/false, not just a flag, for use with action.yml and users setting DEBUG at runtime
  # TODO: remove DEBUG_PASS entirely?

  while getopts ":c:l:d:s:u:p:t:o:r:D:P" opt; do
    case "$opt" in
      c) ci_name="$OPTARG" ;;
      l) sn_url="$OPTARG" ;;
      d) description="$OPTARG" ;;
      s) short_description="$OPTARG" ;;
      u) username="$OPTARG" ;;
      p) password="$OPTARG" ;;
      t) token="$OPTARG" ;;
      o) timeout="$OPTARG" ;;
      r) response_type="$OPTARG" ;;
      D) DEBUG="$OPTARG" ;;
      P) DEBUG_PASS=true ;;
      :) err "Option -$OPTARG requires an argument."; exit 1 ;;
      ?) err "Invalid option: -$OPTARG"; exit 1 ;;
      *) err "Invalid option: -$OPTARG"; exit 1 ;;
    esac
  done

  # set DEBUG and DEBUG_PASS as environment variables
  export DEBUG
  export DEBUG_PASS

  # debug output all passed parameters
    dbg "main(): All passed parameters:"
    dbg " ci_name: $ci_name"
    dbg " sn_url: $sn_url"
    dbg " description: $description"
    dbg " short_description: $short_description"
    dbg " username: $username"
    if [[ "$DEBUG_PASS" == true ]]; then
      dbg " password: $password"
    fi
    dbg " token: $token"
    dbg " timeout: $timeout"
    dbg " response_type: $response_type"
    dbg " DEBUG: $DEBUG"
    dbg " DEBUG_PASS: $DEBUG_PASS"


  # VALIDATION STEPS
  # check if jq and curl are installed
  # ? add version output if installed? especially for curl since there may be argument changes for older versions
  if ! check_application_installed jq; then
    err "jq not available, aborting."
    exit 1
  fi

  if ! check_application_installed curl; then
    err "curl not available, aborting."
    exit 1
  fi

  # check for required parameters
  # double check this logic around user/pass/token
  if [[ -z "$ci_name" || -z "$sn_url" || -z "$short_description" || ( -z "$username" && -z "$token" ) ]]; then
    err "main(): Missing required parameters: ci_name, sn_url, short_description, and either username or token."
    exit 1
  fi

  # convert response_type to lowercase and check if it is 'full' or 'short'
  response_type=$(echo "$response_type" | tr '[:upper:]' '[:lower:]')
  if [[ "$response_type" != "full" && "$response_type" != "short" ]]; then
    dbg "Invalid response type. Use 'full' or 'short'. Defaulting to 'short'."
    response_type="short"
  fi

  # test if url is valid and reachable
  # do we need to add normalization here? ie, ensure https:// or http:// is present?
  if ! curl -Lk -s -w "%{http_code}" "$sn_url" -o /dev/null | grep "200" > /dev/null; then
    err "Invalid or unreachable URL: $sn_url"
    exit 1
  fi

  ci_sys_id=$(get_ci_sys_id -c "$ci_name" -l "${sn_url}" -u "${username}" -p "${password}" -t "${token}") # done
  json_payload=$(create_json_payload -c "${ci_sys_id}" -d "${description}" -s "${short_description}") # done
  create_chg -j "${json_payload}" -l "${sn_url}" -u "${username}" -p "${password}" -t "${token}" -r "${response_type}" # done

}

main "$@"
