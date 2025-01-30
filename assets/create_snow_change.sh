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

token_auth() {
  # parameters username, password, client_id, client_secret, oauth_URL
  # returns bearer token
  # called with: token_auth -O "${oauth_URL}" -u "${username}" -p "${password}" -C "${client_id}" -S "${client_secret}" -o "${timeout}" # optional -g "${grant_type}"
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly

  local username=""
  local password=""
  local client_id=""
  local client_secret=""
  local oauth_URL=""
  local timeout="60"
  local response=""
  local bearer_token=""
  local grant_type="password" # optional passed parameter, default to password, unlikely to need anything else set

  # parse arguments. use substitution to set grant_type default to 'password'
  while getopts ":u:p:C:S:O:o:g:" arg; do
    case "${arg}" in
      u) username="${OPTARG}" ;;
      p) password="${OPTARG}" ;;
      C) client_id="${OPTARG}" ;;
      S) client_secret="${OPTARG}" ;;
      O) oauth_URL="${OPTARG}" ;;
      o) timeout="${OPTARG}" ;;
      g) grant_type="${OPTARG}" ;;
      *)
        err "Invalid option: -$OPTARG"
        exit 1
        ;;
    esac
  done

  # debug output all passed parameters
  dbg "token_auth(): All passed parameters:"
  dbg " username: $username"
  if [[ "$DEBUG_PASS" == true ]]; then
    dbg " password: $password"
    dbg " client_id: $client_id"
    dbg " client_secret: $client_secret"
  fi
  dbg " oauth_URL: $oauth_URL"
  dbg " timeout: $timeout"
  dbg " grant_type: $grant_type"


  # ensure required parameters are set
  if [[ -z "$username" || -z "$password" || -z "$client_id" || -z "$client_secret" || -z "$oauth_URL" ]]; then
    err "token_auth(): Missing required parameters: username, password, client_id, client_secret, and oauth_URL."
    exit 1
  fi

  # get bearer token
  # save HTTP response code to variable 'code', API response to variable 'body'
  # https://superuser.com/a/1321274
  dbg "token_auth(): Attempting to authenticate with OAuth."
  response=$(curl -s -k --location -w "\n%{http_code}" -X POST -d "grant_type=$grant_type" -d "username=$username" -d "password=$password" -d "client_id=$client_id" -d "client_secret=$client_secret" "$oauth_URL")
  body=$(echo "$response" | sed '$d')
  code=$(echo "$response" | tail -n1)
  # curl -s -w -k  --location "\n%{http_code}" -X POST -d "grant_type=$grant_type" -d "username=$username" -d "password=$password" -d "client_id=$client_id" -d "client_secret=$client_secret" "$oauth_URL" | {
  #   read -r body
  #   read -r code
  # }

  dbg "token_auth(): HTTP code: $code"
  if [[ -z "$DEBUG_PASS" ]]; then
    dbg "token_auth(): Token auth response: $body"
  fi

  # check if response is 2xx
  if [[ "$code" =~ ^2 ]]; then
    # HTTP 2xx returned, successful API call. get bearer token and clean up
    bearer_token=$(echo "$body" | jq -r '.access_token')
    if [[ -z "$DEBUG_PASS" ]]; then
      dbg "token_auth(): Bearer token: $bearer_token"
    fi
    # return bearer token
    echo "$bearer_token"
  else
    err "Token authentication failed. HTTP response code: $code"
    dbg "Token auth response: $body"
    exit 1
  fi

}

# get sys_id
get_ci_sys_id() {
  # needs: timeout, ci_name, sn_url, (username & password or token)
  # ${sn_url}/api/now/table/cmdb_ci_service_discovered?sysparm_fields=name,sys_id&timeout=${timeout}&sysparm_query=name=${encoded_ci_name}
  # TODO: update curl commands to not use intermediate files for data and use variables for http response and body like in token_auth()
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
    dbg " token: $token"
  fi
  dbg " timeout: $timeout"
  dbg " DEBUG: $DEBUG"
  dbg " DEBUG_PASS: $DEBUG_PASS"

  # validation steps
  # check for required parameters
  if [[ -z "$ci_name" ]]; then
    err "get_ci_sys_id(): Missing required parameter: ci_name."
    exit 1
  fi

  if [[ -z "$sn_url" ]]; then
    err "get_ci_sys_id(): Missing required parameter: sn_url."
    exit 1
  fi

  if [[ ( -z "$username" && -z "$password" ) || -z "$token" ]]; then
    err "get_ci_sys_id(): Missing required parameter: either username + password or token."
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
      --connect-timeout "${timeout}" \
      --location \
      --url "${URL}" \
      --header "Authorization: Bearer ${token}" \
      --header "Accept: application/json" \
      --silent -w "%{http_code}" -o sys_id.json)
  else
    dbg "get_ci_sys_id(): Using username and password for authentication."
    response=$(curl -k --request GET \
      --connect-timeout "${timeout}" \
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
  # TODO: update curl commands to not use intermediate files for data and use variables for http response and body like in token_auth()
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly
  
  local json_payload=""
  local sn_url=""
  local username=""
  local password=""
  local token=""
  local timeout="60"

  while getopts "j:l:u:p:t:o:r:" opt; do
    case "$opt" in
      j) json_payload="$OPTARG" ;;
      l) sn_url="$OPTARG" ;;
      u) username="$OPTARG" ;;
      p) password="$OPTARG" ;;
      t) token="$OPTARG" ;;
      o) timeout="$OPTARG" ;;
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
    dbg " token: $token"
  fi
  dbg " timeout: $timeout"
  dbg " DEBUG: $DEBUG"
  dbg " DEBUG_PASS: $DEBUG_PASS"

  # validate required parameters
  if [[ -z "$json_payload" ]]; then
    err "create_chg(): Missing required parameter: json_payload (-j)"
    exit 1
  fi

  if [[ -z "$sn_url" ]]; then
    err "create_chg(): Missing required parameter: sn_url (-l)"
    exit 1
  fi

  if [[ ( -z "$username" && -z "$password" ) || -z "$token" ]]; then
    err "create_chg(): Missing required parameter: either username + password or token."
    exit 1
  fi

  # build URL
  # break up here so we can add logic around pieces of the API call as needed in the future
  local API_ENDPOINT="/api/sn_chg_rest/v1/change"
  local URL="${sn_url}${API_ENDPOINT}"


  # if token is set use that, otherwise use username and password
  # if both are set, use token
  # save HTTP response code to variable, API response to file (new_chg_response.json)
  if [[ -n "$token" ]]; then
    dbg "create_chg(): Using token for authentication."
    response=$(curl -k --request POST \
      --connect-timeout "${timeout}" \
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
      --connect-timeout "${timeout}" \
      --location \
      --url "${URL}" \
      --user "${username}:${password}" \
      --header "Accept: application/json" \
      --header "Content-Type: application/json" \
      --data "${json_payload}" \
      --silent -w "%{http_code}" -o new_chg_response.json)
  fi

  # debug output
  dbg "API response: $(cat new_chg_response.json)"
  dbg "Submitted JSON payload: $json_payload"

  # check if response is 2xx
  if [[ "$response" =~ ^2 ]]; then
    # HTTP 2xx, successful API call. return CHG detail payload and clean up
    cat new_chg_response.json
    rm new_chg_response.json 2> /dev/null
  else
    err "Failed to create CHG. HTTP response code: $response"
    # clean up file quietly, error to /dev/null
    rm new_chg_response.json 2> /dev/null
    exit 1
  fi
}

# primary function to grab all passed parameters and call other functions
main() {
  # ! data such as tag, environment, etc should all exist outside of this script. any references passed in should be validated in the workflow, and addressed in description/short_description only.
  # ! -r not working - likely an issue with the 'sysparm_fields' parameter in the API call
  dbg "main(): All passed parameters (\$*): $*"

  local ci_name=""
  local ci_sys_id=""
  local sn_url=""
  local description=""
  local short_description=""
  local username=""
  local password=""
  # local token="" # need to remove in next update, replaced by BEARER_TOKEN for clarity
  local timeout="60" # default timeout value
  local oauth_endpoint="oauth_token.do"
  local client_id=""
  local client_secret=""
  local BEARER_TOKEN=""
  DEBUG=false
  DEBUG_PASS=false
  # ? DONE: (debug, not debug_pass). TODO: update debug/debug_pass to accept true/false, not just a flag, for use with action.yml and users setting DEBUG at runtime
  # TODO: remove DEBUG_PASS entirely?

  while getopts ":c:l:d:s:u:p:C:S:o:r:D:P" opt; do
    case "$opt" in
      u) username="$OPTARG" ;;
      p) password="$OPTARG" ;;
      C) client_id="$OPTARG" ;;
      S) client_secret="$OPTARG" ;;
      c) ci_name="$OPTARG" ;;
      l) sn_url="$OPTARG" ;;
      o) timeout="$OPTARG" ;;
      D) DEBUG="$OPTARG" ;;
      P) DEBUG_PASS=true ;;
      d) description="$OPTARG" ;;
      s) short_description="$OPTARG" ;;
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
      dbg " client_id: $client_id"
      dbg " client_secret: $client_secret"
    fi
    dbg " timeout: $timeout"
    dbg " DEBUG: $DEBUG"
    dbg " DEBUG_PASS: $DEBUG_PASS"


  # VALIDATION STEPS
  # check if jq and curl are installed
  if ! check_application_installed jq; then
    err "jq not available, aborting."
    exit 1
  else
    dbg "main(): jq version: $(jq --version)"
  fi

  if ! check_application_installed curl; then
    err "curl not available, aborting."
    exit 1
  else
    dbg "main(): curl version: $(curl --version | head -n 1)"
  fi

  # check for required parameters
  if [[ -z "$ci_name" || -z "$sn_url" || -z "$short_description" || ( -z "$username" && -z "$password" ) || ( -z "$username" && -z "$password" && -z "$client_id" && -z "$client_secret" ) ]]; then
    err "main(): Missing required parameters: ci_name, sn_url, short_description, and either Username and Password, or Username + Password + Client ID + Client Secret."
    exit 1
  fi

  # normalize sn_url. remove trailing slash if present
  sn_url=$(echo "$sn_url" | sed 's/\/$//')

  # test if url is valid and reachable
  # do we need to add normalization here? ie, ensure https:// or http:// is present?
  if ! curl -Lk -s -w "%{http_code}" "$sn_url" -o /dev/null | grep "200" > /dev/null; then
    err "main(): Invalid or unreachable URL: $sn_url"
    exit 1
  fi

  # if user, pass, client_id, and client_secret are set, build oauth URL and authenticate
  if [[ -n "$username" && -n "$password" && -n "$client_id" && -n "$client_secret" ]]; then
    oauth_URL="${sn_url}/${oauth_endpoint}"
    dbg "main(): Using OAuth for authentication: ${oauth_URL}"
    BEARER_TOKEN=$(token_auth -O "${oauth_URL}" -u "${username}" -p "${password}" -C "${client_id}" -S "${client_secret}" -o "${timeout}")
    if [[ "$DEBUG_PASS" == true ]]; then
      dbg "main(): BEARER_TOKEN: $BEARER_TOKEN"
    fi
  fi
  

  ci_sys_id=$(get_ci_sys_id -c "$ci_name" -l "${sn_url}" -u "${username}" -p "${password}" -t "${BEARER_TOKEN}") # done
  json_payload=$(create_json_payload -c "${ci_sys_id}" -d "${description}" -s "${short_description}") # done
  create_chg -j "${json_payload}" -l "${sn_url}" -u "${username}" -p "${password}" -o "${timeout}" -t "${BEARER_TOKEN}" # done

}

main "$@"
