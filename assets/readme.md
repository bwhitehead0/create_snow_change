# Script documentation

## Flow Diagram for `assets/create_snow_change.sh`

1. Start
  - Usage: `./create_snow_change.sh [options]`
  - Options:
    - `-c` : CI name
    - `-l` : ServiceNow URL
    - `-d` : Description
    - `-s` : Short description
    - `-u` : Username
    - `-p` : Password
    - `-t` : Token
    - `-o` : Timeout (default: 60)
2. Validate Arguments and Environment
  - Check if required arguments are provided
  - Check if `jq` and `curl` are installed
  - Validate URL
  - Display error message if arguments are invalid
3. Execute Main Function
  - Call `url_encode_string()` to encode the 'CI name'
  - Call `get_ci_sys_id` to get the CI sys_id using encoded 'CI name'
  - Call `create_json_payload` to create the JSON payload
  - Call `create_chg` to create the change request
  - Return API response

### Functions

1. main()
  - Usage: `main "$@"`
  - Description: Main function to parse arguments, validate them, and call other functions
  - Steps:
    - Parse arguments
    - Validate required parameters and applications
    - Get the CI sys_id
    - Create the JSON payload
    - Create the change request

2. url_encode_string()
  - Usage: `url_encode_string "string"`
  - Description: URL encodes the provided string

3. get_ci_sys_id()
  - Usage: `get_ci_sys_id -c "ci_name" -l "sn_url" -u "username" -p "password" -t "token" -o "timeout"`
  - Description: Retrieves the sys_id of the specified CI
  - Steps:
    - Parse arguments
    - Validate required parameters
    - URL encode the CI name
    - Build the API URL
    - Make the API request to get the sys_id
    - Handle the response and extract the sys_id

4. create_json_payload()
  - Usage: `create_json_payload -c "ci_sys_id" -d "description" -s "short_description"`
  - Description: Creates a JSON payload for the change request
  - Steps:
    - Parse arguments
    - Create the JSON payload
    - Validate the JSON payload

5. create_chg()
  - Usage: `create_chg -j "json_payload" -l "sn_url" -u "username" -p "password" -t "token"`
  - Description: Creates a change request in ServiceNow
  - Steps:
    - Parse arguments
    - Build the API URL
    - Make the API request to create the change request
    - Handle the response and output the result

6. err()
  - Usage: `err "error message"`  
  - Description: Outputs an error message to stderr

7. check_application_installed()
  - Usage: `check_application_installed "application_name"`
  - Description: Checks if the specified application is installed

## Other notes

create CHG:

required inputs:
  * CI name
  * SN url
  * user/pass, token
  * description
  * short description

optional inputs:
  * timeout (override default)
  * response (short/full, default: (?))

required script actions:
  * URL encode CI name (see bwhitehead0/url_encode_string@v1)
  * get sys_ID using URL encoded CI name (endpoint: table/cmdb_ci_service_discovered)
  * create CHG using sys_id and other required info (description, etc)
  * capture SN response payload and write to GITHUB_OUTPUT
  * error handling

requires:
  * `jq`
  * `curl`