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