#!/bin/bash

set -euo pipefail

# set DEBUG to false, will be evaluated in main()
DEBUG=false

# error output function
err() {
  # date format year-month-day hour:minute:second.millisecond+timezone - requires coreutils date
    printf '%s' "$(date +'%Y-%m-%dT%H:%M:%S.%3N%z') - Error - $1" >&2
    echo "\n"
}

dbg() {
  # date format year-month-day hour:minute:second.millisecond+timezone - requires coreutils date
  if [[ "$DEBUG" == true ]]; then
    printf '%s\n' "$(date +'%Y-%m-%dT%H:%M:%S.%3N%z') - Debug - $1" >&2
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

# calculate duration timestamp for change end date
get_duration_timestamp() {
  # accepts string in format "1h30m" or "1h" or "30m"
  # returns timestamp in format "YYYY-MM-DD HH:MM:SS"
  # TODO: pass in start_time to accurately calculate end time
  # ? primary use for action is in automated workflows where start time is now, so this being set to current time is sufficient for now
  # ? may need to update later for scheduled/queued workflows

  # validate input format
  if [[ ! $1 =~ ^([0-9]+[hH])?([0-9]+[mM])?$ ]]; then
    err "get_duration_timestamp(): Invalid duration format. Use '1h30m', '1h', or '30m'."
    exit 1
  fi
  local duration=$1
  local hours=0
  local minutes=0

  if [[ "$duration" == *h* ]]; then
    hours=${duration%%h*}
  fi

  if [[ "$duration" == *m* ]]; then
    minutes=${duration##*h}
  fi
  minutes=${minutes%m}

  # duration_timestamp=$(date -d "+${hours} hours +${minutes} minutes" "+%Y-%m-%d %H:%M:%S")
  # Use UTC format
  duration_timestamp=$(date -u -d "+${hours} hours +${minutes} minutes" "+%Y-%m-%d %H:%M:%S")

  echo "$duration_timestamp"
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

# validate additional fields
validate_additional_fields() {
  # TODO
  # additional fields should come thru as a string, with '|' delimiter, in format of key=value|key=value|key=value
  # if contains '|', split, validate format (key=value), validate key=value format for all results from split
  # key should contain alphanum and underscores, value should be > 0 characters
  # use nested function(s): test_kv_pair()
  # if contains '|', split on '|' into an array, then validate each array, call test_kv_pair() for each pair

  test_kv_pair() {
    # tests if key=value format is valid
    # regex for alphanum and underscore on left side of '=', any characters on right side
    if [[ "$1" =~ ^[a-zA-Z0-9_]+=.+$ ]]; then
      # key is valid, and value exists and not empty string
      echo "true"
    else
      echo "false"
    fi
  }

  # TODO: optimize this, removing the if statement and just using IFS... will still populate fields array properly if it's just a single k/v pair
  if echo "${1}" | grep '|' > /dev/null; then
    # check for multiple key/value pairs
    IFS='|' read -r -a fields <<< "${1}"
    for field in "${fields[@]}"; do
      # iterate thru each key/value pair and validate key and value
      kv_result=$(test_kv_pair "${field}")
      if [[ "$kv_result" == false ]]; then
        err "validate_additional_fields(): Invalid additional fields key/value format: ${field}"
      else
        if [[ "$DEBUG" == true ]]; then
          dbg "validate_additional_fields(): Valid additional fields key/value format: ${field}"
        fi
      fi
    done
  else
    # single key/value pair
    kv_result=$(test_kv_pair "${field}")
    if [[ "$kv_result" == false ]]; then
      # found an invalid key or value. should be optimized to catch all bad k/v pairs but for now catching the first failure is sufficient
      err "validate_additional_fields(): Invalid additional fields key/value format: ${field}"
      exit 1
    else
      if [[ "$DEBUG" == true ]]; then
        dbg "validate_additional_fields(): Valid additional fields key/value format: ${field}"
      fi
    fi
  fi

  # this should only reach this point if all keys are valid
  # comment out for now, as this is not needed in the current implementation
  # echo "${kv_result}"
}

# marshall additional fields
marshall_additional_fields() {
  # take in string, split into JSON without brackets
  local json_fields=""
  IFS='|' read -r -a fields <<< "${1}"
    for field in "${fields[@]}"; do
      # iterate thru each key/value pair and convert to JSON format
      # split on '=' to get key and value
      # prepend with comma and space for JSON formatting, will be dropped into final JSON payload at the end
      IFS='=' read -r key value <<< "${field}"
      json_fields+=", \"${key}\": \"${value}\""
    done
  dbg "marshall_additional_fields(): json_fields: ${json_fields}"
  echo "${json_fields}"
}

# create JSON payload
create_json_payload() {
  local OPTIND=1 # reset OPTIND so getopts starts at 1 and parameters are parsed correctly

  local description=""
  local short_description=""
  local ci_sys_id=""
  local additional_fields=""

  while getopts "c:d:s:a:T:r:G:A:N:n:O:R:b:t:j:y:" opt; do
    case "$opt" in
      c) ci_sys_id="$OPTARG" ;;
      d) description="$OPTARG" ;;
      s) short_description="$OPTARG" ;;
      a) additional_fields="$OPTARG" ;;
      T) change_category="$OPTARG" ;;
      r) change_risk="$OPTARG" ;;
      G) change_group="$OPTARG" ;;
      A) change_start_date="$OPTARG" ;;
      N) change_end_date="$OPTARG" ;;
      n) change_implementation_plan="$OPTARG" ;;
      O) assigned_to="$OPTARG" ;;
      R) change_risk_impact_analysis="$OPTARG" ;;
      b) change_backout_plan="$OPTARG" ;;
      t) change_test_plan="$OPTARG" ;;
      j) change_justification="$OPTARG" ;;
      #B) change_business_impact="$OPTARG" ;;
      y) change_type="$OPTARG" ;;
      *) err "Invalid option: -$OPTARG"; exit 1 ;;
    esac
  done

  dbg "create_json_payload(): additional_fields: ${additional_fields}"

  # create JSON payload
  # ! this needs to be way more dynamic - chg_model, x_kpmg3_pit_change_testing_signoff shouldn't be hardcoded, and x_kpmg3_pit_change_testing_signoff looks like a custom field anyway [this is done via additional_fields now].
  # this likely limits the use of this script to our internal environment, and even then, the differences between prod and nonprod servicenow may make that even more difficult.
  # TODO: after creating new function to marshall incoming variable for additional fields into k/v pairs to add here, remove x_kpmg3_pit_change_testing_signoff as a hard-coded field.
  # TODO: if -a arg for script and k/v pairs passed, then add a variable to the below creation of json_payload
  # TODO: simplify JSON creation. create all without additional fields and without braces, then append additional fields if set, and add braces at the end.
  if [[ -n "${additional_fields}" ]]; then
    # removing chg_model for now, but we'll want to re-add later
    # \"chg_model\": \"Standard\", 
    # if additional fields are set, add them to the JSON payload
    # $additional_fields will include prepended comma and space, so we can just append it to the JSON payload
    dbg "create_json_payload(): Additional fields are set: ${additional_fields}"
    
    json_payload="{\"description\": \"${description}\", \"short_description\": \"${short_description}\", \"cmdb_ci\": \"${ci_sys_id}\", \"type\": \"${change_type}\", \"category\": \"${change_category}\", \"risk\": \"${change_risk}\", \"assignment_group\": \"${change_group}\", \"start_date\": \"${change_start_date}\", \"end_date\": \"${change_end_date}\", \"implementation_plan\": \"${change_implementation_plan}\", \"risk_impact_analysis\": \"${change_risk_impact_analysis}\", \"backout_plan\": \"${change_backout_plan}\", \"test_plan\": \"${change_test_plan}\", \"assigned_to\": \"${assigned_to}\", \"justification\": \"${change_justification}\"${additional_fields}}"
  else
    # \"chg_model\": \"Standard\", 
    dbg "create_json_payload(): No additional fields set."
    json_payload="{\"description\": \"${description}\", \"short_description\": \"${short_description}\", \"cmdb_ci\": \"${ci_sys_id}\", \"type\": \"${change_type}\", \"category\": \"${change_category}\", \"risk\": \"${change_risk}\", \"assignment_group\": \"${change_group}\", \"start_date\": \"${change_start_date}\", \"end_date\": \"${change_end_date}\", \"implementation_plan\": \"${change_implementation_plan}\", \"risk_impact_analysis\": \"${change_risk_impact_analysis}\", \"backout_plan\": \"${change_backout_plan}\", \"test_plan\": \"${change_test_plan}\", \"assigned_to\": \"${assigned_to}\", \"justification\": \"${change_justification}\"}"
  fi

  dbg "create_json_payload(): json_payload: ${json_payload}"

  # silently validate the JSON
  if ! printf '%s' "$json_payload" | jq empty > /dev/null 2>&1; then
    err "Invalid JSON payload. Check input values."
    exit 1
  else
    # return json payload
    printf '%s' "${json_payload}"
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
  dbg "create_chg(): All passed parameters:"
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
    err "create_chg(): Missing required parameter(s): either username + password or token."
    exit 1
  fi

  # build URL
  # break up here so we can add logic around pieces of the API call as needed in the future
  # local API_ENDPOINT="/api/sn_chg_rest/v1/change"
  local API_ENDPOINT="/api/now/table/change_request"
  local URL="${sn_url}${API_ENDPOINT}"


  # if token is set use that, otherwise use username and password
  # if both are set, use token
  # save HTTP response code to variable, API response to file (new_chg_response.json)
  # TODO: update to use variables for response and body like in token_auth()
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
  dbg "main(): All passed parameters (\$*): $*"

  local ci_name=""
  local ci_sys_id=""
  local sn_url=""
  local description=""
  local short_description=""
  local additional_fields=""
  local username=""
  local password=""
  local marshalled_fields=""
  local change_category=""
  local change_risk=""
  local change_group=""
  local change_start_date=""
  local change_end_date=""
  local change_implementation_plan=""
  local change_risk_impact_analysis=""
  local change_backout_plan=""
  local change_test_plan=""
  local change_justification=""
  local change_type=""
  local assigned_to=""
  # local token="" # need to remove in next update, replaced by BEARER_TOKEN for clarity
  local timeout="60" # default timeout value
  local oauth_endpoint="oauth_token.do"
  local client_id=""
  local client_secret=""
  local BEARER_TOKEN=""
  DEBUG=false
  DEBUG_PASS=false
  
  # TODO: remove DEBUG_PASS entirely?

  while getopts ":c:l:d:s:a:u:p:C:S:o:O:D:P:T:r:G:A:N:n:R:b:t:j:y:" opt; do
    case "$opt" in
      a) additional_fields="$OPTARG" ;;
      A) change_start_date="$OPTARG" ;;
      b) change_backout_plan="$OPTARG" ;;
      c) ci_name="$OPTARG" ;;
      C) client_id="$OPTARG" ;;
      d) description="$OPTARG" ;;
      D) DEBUG="$OPTARG" ;;
      G) change_group="$OPTARG" ;;
      j) change_justification="$OPTARG" ;;
      l) sn_url="$OPTARG" ;;
      n) change_implementation_plan="$OPTARG" ;;
      N) change_end_date="$OPTARG" ;;
      o) timeout="$OPTARG" ;;
      O) assigned_to="$OPTARG" ;;
      p) password="$OPTARG" ;;
      P) DEBUG_PASS=true ;;
      r) change_risk="$OPTARG" ;;
      R) change_risk_impact_analysis="$OPTARG" ;;
      s) short_description="$OPTARG" ;;
      S) client_secret="$OPTARG" ;;
      t) change_test_plan="$OPTARG" ;;
      T) change_category="$OPTARG" ;;
      u) username="$OPTARG" ;;
      y) change_type="$OPTARG" ;;
      :) err "Option -$OPTARG requires an argument."; exit 1 ;;
      ?) err "Invalid option: -$OPTARG"; exit 1 ;;
      *) err "Invalid option: -$OPTARG"; exit 1 ;;
    esac
  done

  # DEBUG=true
  # set DEBUG and DEBUG_PASS as environment variables
  export DEBUG
  export DEBUG_PASS

  echo "DEBUG: $DEBUG" >&2

  # debug output all passed parameters
    dbg "main(): All passed parameters:"
    dbg " ci_name: $ci_name"
    dbg " sn_url: $sn_url"
    dbg " description: $description"
    dbg " short_description: $short_description"
    dbg " change_category: $change_category"
    dbg " change_risk: $change_risk"
    dbg " change_group: $change_group"
    dbg " change_start_date: $change_start_date"
    dbg " change_end_date: $change_end_date"
    dbg " change_implementation_plan: $change_implementation_plan"
    dbg " change_risk_impact_analysis: $change_risk_impact_analysis"
    dbg " assigned_to: $assigned_to"
    dbg " change_backout_plan: $change_backout_plan"
    dbg " change_test_plan: $change_test_plan"
    dbg " change_justification: $change_justification"
    #dbg " change_business_impact: $change_business_impact"
    dbg " change_type: $change_type"
    dbg " additional_fields: $additional_fields"
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

  # validate additional fields if set
  if [[ -n "$additional_fields" ]]; then
    dbg "main(): Validating additional fields: $additional_fields"
    # validate additional fields (will exit 1 if invalid)
    validate_additional_fields "$additional_fields"
    # marshall additional fields into JSON format
    marshalled_fields=$(marshall_additional_fields "$additional_fields")
  fi

  # ! validate behavior of timestamps interacting with servicnow. timezone, etc, may need to be adjusted to UTC

  # calculate start time if input is 'now'
  if [[ "$change_start_date" =~ ^[Nn][Oo][Ww]$ ]]; then
    dbg "main(): change_start_date set to 'now', using current time."
    change_start_date=$(date -u +"%Y-%m-%d %H:%M:%S")
    dbg "main(): change_start_date set from 'now' to current time: $change_start_date"
  fi

  # calculate end time if input is valid duration or timestamp
  # TODO: accept 24hr time ie 14:45 for 2:45 PM, check not in past, and use same date + specified time
  # TODO: add some additional validation for BOTH dates, year is current year or next year & < 1min in future (or is that overkill?)
  # TODO: !! allow timestamp without seconds, ie 2023-10-01 14:45, and convert to full timestamp with seconds
  if [[ "$change_end_date" =~ ^([0-9]+[hH])?([0-9]+[mM])?$ ]]; then
    change_end_date=$(get_duration_timestamp "$change_end_date")
    dbg "main(): change_end_date set from duration to: $change_end_date"
  elif [[ "$change_end_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    # if change_end_date is a valid timestamp, do nothing
    dbg "main(): change_end_date is a valid timestamp: $change_end_date"
  else
    err "main(): Invalid change_end_date format. Use '1h30m', '1h', '30m', or 'YYYY-MM-DD hh:mm:ss'."
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

  dbg "main(): marshalled_fields: ${marshalled_fields}"
  # json_payload=$(create_json_payload -c "${ci_sys_id}" -d "${description}" -s "${short_description}" -a "${marshalled_fields}") # done
  json_payload=$(create_json_payload -c "${ci_sys_id}" \
    -d "${description}" \
    -s "${short_description}" \
    -T "${change_category}" \
    -r "${change_risk}" \
    -G "${change_group}" \
    -A "${change_start_date}" \
    -N "${change_end_date}" \
    -n "${change_implementation_plan}" \
    -r "${change_risk}" \
    -R "${change_risk_impact_analysis}" \
    -b "${change_backout_plan}" \
    -t "${change_test_plan}" \
    -j "${change_justification}" \
    -y "${change_type}" \
    -a "${marshalled_fields}") # done
    #-B "${change_business_impact}" \


  # ? might need to dump this to variable(s) and evaluate, use `printf '%s'` to output the actual JSON payload, and trigger logic based on HTTP response code
  create_chg -j "${json_payload}" -l "${sn_url}" -u "${username}" -p "${password}" -o "${timeout}" -t "${BEARER_TOKEN}" # done

}

main "$@"
