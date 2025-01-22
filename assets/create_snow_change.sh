#!/bin/bash

# error output function
err() {
    echo "Error: $1" >&2
}

# check if required apps are installed
check_application_installed() {
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
    local i

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
    echo "$output"
}

# get sys_id
get_ci_sys_id() {
  # needs: timeout, ci_name, sn_url, (username & password or token)
  # ${sn_url}/api/now/table/cmdb_ci_service_discovered?sysparm_fields=name,sys_id&timeout=${timeout}&sysparm_query=name=${encoded_ci_name}
  local ci_name=""
  local encoded_ci_name=""
  local timeout="60"
  local sn_url=""
  local username=""
  local password=""
  local token=""
  local response=""

  # parse arguments
  while getopts "c:l:u:p:t:o:" opt; do
    case "$opt" in
    c) ci_name="$OPTARG" ;;
    l) sn_url="$OPTARG" ;;
    u) username="$OPTARG" ;;
    p) password="$OPTARG" ;;
    t) token="$OPTARG" ;;
    o) timeout="$OPTARG" ;;
    *)
      echo "Invalid option: -$OPTARG" >&2
      exit 1
      ;;
    esac
  done

  # validation steps
  # check for required parameters
  # double check this logic around user/pass/token
  if [[ -z "$ci_name" || -z "$sn_url" || (-z "$username" && -z "$token") ]]; then
    err "Missing required parameters."
    exit 1
  fi

  # get encoded_ci_name
  encoded_ci_name=$(url_encode_string "$ci_name")

  # build URL
  # break up here so we can add logic around pieces of the API call as needed in the future
  local API_ENDPOINT="/api/now/table/cmdb_ci_service_discovered"
  local API_PARAMETERS="sysparm_fields=name,sys_id&timeout=${timeout}&sysparm_query=name=${encoded_ci_name}"
  local URL="${sn_url}${API_ENDPOINT}?${API_PARAMETERS}"

  # if token is set use that, otherwise use username and password
  # if both are set, use token
  # save HTTP response code to variable, API response to file (sys_id.json)
  if [[ -n "$token" ]]; then
    response=$(curl --request GET \
      --url "${URL}" \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/json" \
      --silent -w "%{http_code}" -o sys_id.json)
  else
    response=$(curl --request GET \
      --url "${URL}" \
      --user "${username}:${password}" \
      --header "Accept: application/json" \
      --silent -w "%{http_code}" -o sys_id.json)
  fi

  # check if response is 2xx
  if [[ "$response" =~ ^2 ]]; then
    # successful API call. get sys_id and clean up
    # get sys_id from sys_id.json
    # remove sys_id.json
    sys_id=$(jq -r '.result[0].sys_id' sys_id.json)
    rm sys_id.json
    echo "${sys_id}"
  else
    err "Failed to get sys_id. HTTP response code: $response"
    exit 1
  fi
}

# create JSON payload
create_json_payload() {
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
  # this likely limits the use of this script to our internal environment, and even then, the differences between prod and nonprod servicenow makes that even more difficult.
  json_payload="{\"chg_model\": \"Standard\", \"description\": \"${description}\", \"short_description\": \"${short_description}\", \"cmdb_ci\": \"${ci_sys_id}\", \"type\": \"Standard\", \"x_kpmg3_pit_change_testing_signoff\": \"PreProd Change\"}"

  # silently validate the JSON
  if ! echo "$json_payload" | jq empty > /dev/null 2>&1; then
    err "Invalid JSON payload. Check input values."
    exit 1
  else
    echo "${json_payload}"
  fi

}

# create change request
create_chg() {
  local json_payload="${1}"
  # replace with actual command to create change request
  echo "Change request created with payload: ${json_payload}"
}

# primary function to grab all passed parameters and call other functions
main() {
  # ! data such as tag, environment, etc should all exist outside of this script. any references passed in should be validated in the workflow, and addressed in description/short_description only.
  local ci_name=""
  # local encoded_ci_name=""
  local ci_sys_id=""
  local sn_url=""
  local description=""
  local short_description=""
  local username=""
  local password=""
  local token=""
  local timeout="60"
  local response_type="short"

  while getopts "c:l:d:s:u:p:t:o:r:" opt; do
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
      *) echo "Invalid option: -$OPTARG" >&2; exit 1 ;;
    esac
  done

  # VALIDATION STEPS
  # check if jq and curl are installed
  # ? add version output if installed?
  if [ ! "$(check_application_installed jq)" ]; then
    err "jq not available, aborting."
    exit 1
  fi

  if [ ! "$(check_application_installed curl)" ]; then
    err "curl not available, aborting."
    exit 1
  fi


  # check for required parameters
  # double check this logic around user/pass/token
  if [[ -z "$ci_name" || -z "$sn_url" || -z "$short_description" || ( -z "$username" && -z "$token" ) ]]; then
    err "Missing required parameters."
    exit 1
  fi

  # convert response_type to lowercase and check if it is 'full' or 'short'
  response_type=$(echo "$response_type" | tr '[:upper:]' '[:lower:]')
  if [[ "$response_type" != "full" && "$response_type" != "short" ]]; then
    err "Invalid response type. Use 'full' or 'short'. Defaulting to 'short'."
    response_type="short"
  fi

  # test if url is valid and reachable
  if ! curl -s --head "$sn_url" | grep "HTTP/[1-9]* [2][0-9][0-9]" > /dev/null; then
    err "Invalid or unreachable URL: $sn_url"
    exit 1
  fi


  # encoded_ci_name=$(url_encode_string "$ci_name") # we just call this in get_ci_sys_id
  ci_sys_id=$(get_ci_sys_id "$ci_name") # done
  json_payload=$(create_json_payload -c "$ci_sys_id" "$encoded_description") # TODO
  create_chg "$json_payload"


}

main "$@"



