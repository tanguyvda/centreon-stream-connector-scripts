#!/usr/bin/lua

--------------------------------------------------------------------------------
-- Centreon Broker PagerDuty Connector
-- Tested with the public API on the developer platform:
-- https://events.pagerduty.com/v2/enqueue
--
-- References: 
-- https://developer.pagerduty.com/api-reference/reference/events-v2/openapiv3.json/paths/~1enqueue/post
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Prerequisites:
--
-- You need a PagerDuty instance
-- You need your instance's routing_key. According to the page linked above: "The GUID of one of your Events API V2 integrations. This is the "Integration Key" listed on the Events API V2 integration's detail page."
--
-- The lua-curl and luatz libraries are required by this script:
-- yum install lua-curl epel-release
-- yum install luarocks
-- luarocks install luatz
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Parameters:
-- [MANDATORY] pdy_routing_key: see above, this will be your authentication token
-- [RECOMMENDED] pdy_centreon_url: in order to get links/url that work in your events
-- [RECOMMENDED] log_level: level of verbose. Default is 2 but in production 1 is the recommended value.
-- [OPTIONAL] http_server_url: default "https://events.pagerduty.com/v2/enqueue"
-- [OPTIONAL] http_proxy_string: default empty
--
--------------------------------------------------------------------------------

-- libraries 
local curl = require "cURL"

-- Global variables

-- Useful functions

--------------------------------------------------------------------------------
-- boolean_to_number: convert boolean variable to number
-- @param {boolean} boolean, the boolean that will be converted
-- @return {number}, a number according to the boolean value
--------------------------------------------------------------------------------
local function boolean_to_number (boolean)
  return boolean and 1 or 0
end

--------------------------------------------------------------------------------
-- check_boolean_number_option_syntax: make sure the number is either 1 or 0
-- @param {number} number, the boolean number that must be validated
-- @param {number} default, the default value that is going to be return if the default number is not validated
-- @return {number} number, a boolean number
--------------------------------------------------------------------------------
local function check_boolean_number_option_syntax (number, default)
  if number ~= 1 or number ~= 0 then
    number = default
  end
  
  return number
end

--------------------------------------------------------------------------------
-- get_hostname: retrieve hostname from host_id
-- @param {number} host_id,
-- @return {string} hostname,
--------------------------------------------------------------------------------
local function get_hostname (host_id)
  local hostname = broker_cache:get_hostname(host_id)
  if not hostname then
    broker_log:warning(1, "get_hostname: hostname for id " .. host_id .. " not found. Restarting centengine should fix this.")
    hostname = host_id
  end
  
  return hostname
end

--------------------------------------------------------------------------------
-- get_service_description: retrieve the service name from its host_id and service_id
-- @param {number} host_id,
-- @param {number} service_id,
-- @return {string} service, the name of the service
--------------------------------------------------------------------------------
local function get_service_description (host_id, service_id)
  local service = broker_cache:get_service_description(host_id, service_id)
  if not service then
    broker_log:warning(1, "get_service_description: service_description for id " .. host_id .. "." .. service_id .. " not found. Restarting centengine should fix this.")
    service = service_id
  end
  return service
end

--------------------------------------------------------------------------------
-- split: convert a string into a table
-- @param {string} string, the string that is going to be splitted into a table
-- @param {string} separatpr, the separator character that will be used to split the string
-- @return {table} table,
--------------------------------------------------------------------------------
local function split (text, separator)
  local hash = {}
  -- broker_log:info(1, "text : " .. text .. ";; separator: " .. separator)
  -- https://stackoverflow.com/questions/1426954/split-string-in-lua
  for value in string.gmatch(text, "([^" .. separator .. "]+)") do
    table.insert(hash, value)
  end

  return hash
end

--------------------------------------------------------------------------------
-- find_in_mapping: check if item type is in the mapping and is accepted
-- @param {table} mapping, the mapping table 
-- @param {string} reference, the accepted values for the item
-- @param {string} item, the item we want to find in the mapping table and in the reference
-- @return {boolean}
--------------------------------------------------------------------------------
local function find_in_mapping (mapping, reference, item)
  for mappingIndex, mappingValue in pairs(mapping) do
    for referenceIndex, referenceValue in pairs(split(reference, ',')) do
      if item == mappingValue and mappingIndex == referenceValue then
        return true
      end
    end
  end 

  return false
end

--------------------------------------------------------------------------------
-- check_neb_event_status: check the status of a neb event (ok, critical...)
-- @param {number} eventStatus, the status of the event
-- @param {table} acceptedStatus, the separator character that will be used to split the string
-- @return {boolean}
--------------------------------------------------------------------------------
local function check_neb_event_status (eventStatus, acceptedStatuses) 
  for i, v in ipairs(split(acceptedStatuses, ',')) do
    if tostring(eventStatus) == v then
      return true
    end
  end

  return false
end

--------------------------------------------------------------------------------
-- compare_numbers: compare two numbers, if comparison is valid, then return true
-- @param {number} firstNumber
-- @param {number} secondNumber
-- @param {string} operator, the mathematical operator that is used for the comparison
-- @return {boolean}
--------------------------------------------------------------------------------
local function compare_numbers(firstNumber, secondNumber, operator)
  if type(firstNumber) ~= 'number' or type(secondNumber) ~= 'number' then
    return false
  end

  if firstNumber .. operator .. secondNumber then
    return true
  end

  return false
end

--------------------------------------------------------------------------------
-- EventQueue class
--------------------------------------------------------------------------------

local EventQueue = {}
EventQueue.__index = EventQueue

--------------------------------------------------------------------------------
-- Constructor
-- @param conf The table given by the init() function and returned from the GUI
-- @return the new EventQueue
--------------------------------------------------------------------------------

function EventQueue:new (conf)
  local retval = {
    host_status = "0,1,2",
    service_status = "0,1,2,3",
    hard_only = 1,
    acknowledged = 0,
    element_type = "metric", --metric,host_status,service_status,ba_event,kpi_event"
    category_type = "neb,storage", -- neb,storage,bam
    in_downtime = 0,
    max_buffer_size = 1,
    max_buffer_age = 5,
    skip_anon_events = 1,
    instance = "",
    username = "",
    password = "",
    client_id = "",
    client_secret = "",
    tokens = {},
    element_mapping = {},
    category_mapping = {}
  }

  retval.category_mapping = {
    neb = 1,
    bbdo = 2,
    storage = 3,
    correlation = 4,
    dumper = 5,
    bam = 6,
    extcmd = 7
  }

  retval.element_mapping = {
    [1] = {},
    [3] = {},
    [6] = {} 
  }

  retval.element_mapping[1].acknowledgement = 1
  retval.element_mapping[1].comment = 2
  retval.element_mapping[1].custom_variable = 3
  retval.element_mapping[1].custom_variable_status = 4
  retval.element_mapping[1].downtime = 5
  retval.element_mapping[1].event_handler = 6
  retval.element_mapping[1].flapping_status = 7
  retval.element_mapping[1].host_check = 8
  retval.element_mapping[1].host_dependency = 9
  retval.element_mapping[1].host_group = 10
  retval.element_mapping[1].host_group_member = 11
  retval.element_mapping[1].host = 12
  retval.element_mapping[1].host_parent = 13
  retval.element_mapping[1].host_status = 14
  retval.element_mapping[1].instance = 15
  retval.element_mapping[1].instance_status = 16
  retval.element_mapping[1].log_entry = 17
  retval.element_mapping[1].module = 18
  retval.element_mapping[1].service_check = 19
  retval.element_mapping[1].service_dependency = 20
  retval.element_mapping[1].service_group = 21
  retval.element_mapping[1].service_group_member = 22
  retval.element_mapping[1].service = 23
  retval.element_mapping[1].service_status = 24
  retval.element_mapping[1].instance_configuration = 25

  retval.element_mapping[3].metric = 1
  retval.element_mapping[3].rebuild = 2
  retval.element_mapping[3].remove_graph = 3
  retval.element_mapping[3].status = 4
  retval.element_mapping[3].index_mapping = 5
  retval.element_mapping[3].metric_mapping = 6

  retval.element_mapping[6].ba_status = 1
  retval.element_mapping[6].kpi_status = 2
  retval.element_mapping[6].meta_service_status = 3
  retval.element_mapping[6].ba_event = 4
  retval.element_mapping[6].kpi_event = 5
  retval.element_mapping[6].ba_duration_event = 6
  retval.element_mapping[6].dimension_ba_event = 7
  retval.element_mapping[6].dimension_kpi_event = 8
  retval.element_mapping[6].dimension_ba_bv_relation_event = 9
  retval.element_mapping[6].dimension_bv_event = 10
  retval.element_mapping[6].dimension_truncate_table_signal = 11
  retval.element_mapping[6].bam_rebuild = 12
  retval.element_mapping[6].dimension_timeperiod = 13
  retval.element_mapping[6].dimension_ba_timeperiod_relation = 14
  retval.element_mapping[6].dimension_timeperiod_exception = 15
  retval.element_mapping[6].dimension_timeperiod_exclusion = 16
  retval.element_mapping[6].inherited_downtime = 17

  retval.tokens.authToken = nil
  retval.tokens.refreshToken = nil

  for i,v in pairs(conf) do
    if retval[i] then
      retval[i] = v
      broker_log:info(1, "EventQueue.new: getting parameter " .. i .. " => " .. v)
    else
      broker_log:info(1, "EventQueue.new: ingoring unhandled parameter " .. i .. " => " .. v)
    end
  end

  retval.__internal_ts_last_flush = os.time()
  retval.events = {}
  setmetatable(retval, EventQueue)
  -- Internal data initialization
  broker_log:info(2, "EventQueue.new: setting the internal timestamp to " .. retval.__internal_ts_last_flush)

  return retval
end

--------------------------------------------------------------------------------
-- is_valid_category: check if the event category is valid
-- @param {number} category, the category id of the event
-- @return {boolean}
--------------------------------------------------------------------------------
function EventQueue:is_valid_category (category)
  return find_in_mapping(self.category_mapping, self.category_type, category)
end


--------------------------------------------------------------------------------
-- is_valid_element: check if the event element is valid
-- @param {number} category, the category id of the event
-- @param {number} element, the element id of the event
-- @return {boolean}
--------------------------------------------------------------------------------
function EventQueue:is_valid_element(category, element)
  return find_in_mapping(self.element_mapping[category], self.element_type, element)
end

--------------------------------------------------------------------------------
-- is_valid_neb_event: check if the neb event is valid
-- @param {table} event, the event data
-- @return {table} validNebEvent, a table of boolean indexes validating the event
--------------------------------------------------------------------------------
function EventQueue:is_valid_neb_event (event) 
  local validNebEvent = {}
  
  if event.element == 14 or event.element == 24 then
    self.hard_only = check_boolean_number_option_syntax(self.hard_only, 1)
    self.acknowledged = check_boolean_number_option_syntax(self.acknowledged, 0)
    self.in_downtime = check_boolean_number_option_syntax(self.in_downtime, 0)
    self.skip_anon_events = check_boolean_number_option_syntax(self.skip_anon_events, 1)
    validNebEvent.ack = false
    validNebEvent.state = false
    validNebEvent.downtime = false
  end

  if event.element == 14 then
    validNebEvent.host_status = check_neb_event_status(event.state, self.host_status)
  elseif event.element == 24 then
    if event.host_id == nil and self.skip_anon_events == 1 then
      return false
    end

    validNebEvent.service_status = check_neb_event_status(event.state, self.service_status)
  end

  validNebEvent.state = compare_numbers(event.state_type, self.hard_only, '>=')
  validNebEvent.ack = compare_numbers(self.acknowledged, boolean_to_number(event.acknowledged), '>=')
  validNebEvent.downtime = compare_numbers(self.in_downtime, event.scheduled_downtime_depth, '>=')

  return validNebEvent
end

--------------------------------------------------------------------------------
-- is_valid_storage_event: check if the storage event is valid
-- @param {table} event, the event data
-- @return {table} validStorageEvent, a table of boolean indexes validating the event
--------------------------------------------------------------------------------
function EventQueue:is_valid_storage_event (event)
  local validStorageEvent = {
    default = true
  }

  return validStorageEvent
end

--------------------------------------------------------------------------------
-- is_valid_bam_event: check if the bam event is valid
-- @param {table} event, the event data
-- @return {table} validBamEvent, a table of boolean indexes validating the event
--------------------------------------------------------------------------------
function EventQueue:is_valid_bam_event (event)
  local validBamEvent = {
    default = true
  }

  return validBamEvent
end

--------------------------------------------------------------------------------
-- is_valid_event: check if the event is valid
-- @param {table} event, the event data
-- @return {boolean}
--------------------------------------------------------------------------------
function EventQueue:is_valid_event(event)
  local validEvent = {}
  
  if event.category == 1 then
    validEvent = EventQueue:is_valid_neb_event(event)
  elseif event.category == 3 then
    for i, v in pairs(event) do
      broker_log:info(1, "mon index: " .. i .. ";; ma value: " .. tostring(v))
    end
    validEvent = EventQueue:is_valid_storage_event(event)
  elseif event.category == 6 then
    validEvent = EventQueue:is_valid_bam_event(event)
  else
    return false
  end
    
  for i, v in pairs(validEvent) do
    if not v then
      return false
    end
  end

  return true
end

--------------------------------------------------------------------------------
-- EventQueue:getAuthToken handle tokens
-- @return {string} the new EventQueue
--------------------------------------------------------------------------------

function EventQueue:getAuthToken ()
  if not self:refreshTokenIsValid() then
    self:authToken()
  end

  if not self:accessTokenIsValid() then
    self:refreshToken(self.tokens.refreshToken.token)
  end

  return self.tokens.authToken.token
end

--------------------------------------------------------------------------------
-- EventQueue:authToken prepare api call to get auth token
--------------------------------------------------------------------------------

-- EventQueue:authToken ()
--   local data = "grant_type=password&client_id=" .. self.clientId .. "&client_secret=" .. self.clientPassword .. "&username=" .. self.username .. "&password=" .. self.password

--   local res = self:call(
--     "oauth_token.do",
--     "POST",
--     data
--   )

--   if not res.access_token then
--     error("Authentication failed")
--   end

--   self.tokens.authToken = {
--     token = res.access_token,
--     expTime = os.time(os.date("!*t")) + 1700
--   }

--   self.tokens.refreshToken = {
--     token = res.resfresh_token,
--     expTime = os.time(os.date("!*t")) + 360000
--   }
-- end

--------------------------------------------------------------------------------
-- EventQueue:refreshToken update token
-- @param {string} token 
--------------------------------------------------------------------------------

-- function EventQueue:refreshToken (token)
--   local data = "grant_type=refresh_token&client_id=" .. self.clientId .. "&client_secret=" .. self.clientPassword .. "&username=" .. self.username .. "&password=" .. self.password
  
--   res = self.call(
--     "oauth_token.do",
--     "POST",
--     data
--   )

--   if not res.access_token then
--     error("Bad access token")
--   end

--   self.tokens.authToken = {
--     token = res.access_token,
--     expTime = os.time(os.date("!*t")) + 1700
--   }
-- end

--------------------------------------------------------------------------------
-- EventQueue:refreshTokenIsValid check if token is valid
-- @return {boolean}
--------------------------------------------------------------------------------

-- function EventQueue:refreshTokenIsValid ()
--   if not self.tokens.refreshToken then
--     return false
--   end

--   if os.time(os.date("!*t")) > self.tokens.refreshToken.expTime then
--     self.refreshToken = nil

--     return false
--   end

--   return true
-- end

--------------------------------------------------------------------------------
-- EventQueue:call run api call
-- @param {string} url, the service now instance url
-- @param {string} method, the HTTP method that is used
-- @param {string} data, the data we want to send to service now
-- @param {string} authToken, the api auth token
-- @return {array} decoded output
-- @throw exception if http call fails or response is empty
--------------------------------------------------------------------------------

-- function EventQueue:call (url, method, data, authToken)
--   method = method or "GET"
--   data = data or nil
--   authToken = authToken or nil

--   local endpoint = "https://" .. tostring(self.instance) .. ".service-now.com/" .. tostring(url)
--   broker_log:info(1, "Prepare url " .. endpoint)

--   local res = ""
--   local request = curl.easy()
--     :setopt_url(endpoint)
--     :setopt_writefunction(function (response)
--       res = res .. tostring(response)
--     end)
--   broker_log:info(1, "Request initialize")

--   if not authToken then
--     if method ~= "GET" then
--       broker_log:info(1, "Add form header")
--       request:setopt(curl.OPT_HTTPHEADER, { "Content-Type: application/x-www-form-urlencoded" })
--       broker_log:info(1, "After add form header")
--     end
--   else
--     broker_log:info(1, "Add JSON header")
--     request:setopt(
--       curl.OPT_HTTPHEADER,
--       {
--         "Accept: application/json",
--         "Content-Type: application/json",
--         "Authorization: Bearer " .. authToken
--       }
--     )
--   end

--   if method ~= "GET" then
--     broker_log:info(1, "Add post data")
--     request:setopt_postfields(data)
--   end

--   broker_log:info(1, "Call url " .. endpoint)
--   request:perform()

--   respCode = request:getinfo(curl.INFO_RESPONSE_CODE)
--   broker_log:info(1, "HTTP Code : " .. respCode)
--   broker_log:info(1, "Response body : " .. tostring(res))

--   request:close()

--   if respCode >= 300 then
--     broker_log:info(1, "HTTP Code : " .. respCode)
--     broker_log:info(1, "HTTP Error : " .. res)
--     error("Bad request code")
--   end

--   if res == "" then
--     broker_log:info(1, "HTTP Error : " .. res)
--     error("Bad content")
--   end

--   broker_log:info(1, "Parsing JSON")
--   return broker.json_decode(res)
-- end

--------------------------------------------------------------------------------
-- EventQueue:call send event to service now
-- @param {array} event, the event we want to send
-- @return {boolean}
--------------------------------------------------------------------------------

-- function ServiceNow:sendEvent (event)
--   local authToken = self:getAuthToken()

--   broker_log:info(1, "Event information :")
--   for k, v in pairs(event) do
--     broker_log:info(1, tostring(k) .. " : " .. tostring(v))
--   end

--   broker_log:info(1, "------")
--   broker_log:info(1, "Auth token " .. authToken)
--   if pcall(self:call(
--       "api/now/table/em_event",
--       "POST",
--       broker.json_encode(event),
--       authToken
--     )) then
--     return true
--   end

--   return false
-- end

local queue

--------------------------------------------------------------------------------
-- EventQueue:call 
-- @param {array} event, the event we want to send
-- @return {boolean}
--------------------------------------------------------------------------------

function init (parameters)
  logfile = parameters.logfile or "/var/log/centreon-broker/connector-servicenow.log"
  if not parameters.instance or not parameters.username or not parameters.password
     or not parameters.client_id or not parameters.client_secret then
     error("The needed parameters are 'instance', 'username', 'password', 'client_id' and 'client_secret'")
  end

  broker_log:set_parameters(1, logfile)
  broker_log:info(1, "Parameters")
  for i,v in pairs(parameters) do
    broker_log:info(1, "Init " .. i .. " : " .. v)
  end
  queue = EventQueue:new(parameters)
  -- serviceNow = ServiceNow:new(
  --   parameters.instance,
  --   parameters.username,
  --   parameters.password,
  --   parameters.client_id,
  --   parameters.client_secret
  -- )
end

--------------------------------------------------------------------------------
-- write
-- @param {array} data, the data from broker
-- @return {boolean}
--------------------------------------------------------------------------------

function write (data)
  local sendData = {
    source = "centreon",
    event_class = "centreon",
    severity = 5
  }

  broker_log:info(1, "Prepare Go category " .. tostring(data.category) .. " element " .. tostring(data.element))

  if not queue:is_valid_event(data) then
    return false
  end

  hostname = get_hostname(data.host_id)
  sendData.node = hostname
  sendData.description = data.output
  sendData.time_of_event = os.date("%Y-%m-%d %H:%M:%S", data.last_check)

  if data.element == 14 then
    sendData.resource = hostname
    if data.current_state == 0 then
      sendData.severity = 0
    elseif data.current_state then
      sendData.severity = 1
    end
  else
    service_description = get_service_description(data.host_id, data.service_id)
    if data.current_state == 0 then
      sendData.severity = 0
    elseif data.current_state == 1 then
      sendData.severity = 3
    elseif data.current_state == 2 then
      sendData.severity = 1
    elseif data.current_state == 3 then
      sendData.severity = 4
    end

    sendData.resource = service_description
  end

  for i, v in pairs(sendData) do
    broker_log:info(1, 'key: ' .. i .. ';; value : ' .. v )
  end

  -- return EventQueue:sendEvent(sendData)
  return true
end

--------------------------------------------------------------------------------
-- filter
-- @param {integer} category, the category of the event
-- @param {integer} element, the element of the event
-- @return {boolean}
--------------------------------------------------------------------------------
function filter (category, element)
  if not queue:is_valid_category(category) then
    return false
  end

  if not queue:is_valid_element(category, element) then
    return false
  end

  broker_log:info(1, "Go category " .. tostring(category) .. " element " .. tostring(element))

  return true
end