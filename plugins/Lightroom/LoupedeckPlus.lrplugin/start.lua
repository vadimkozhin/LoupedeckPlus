local LrDialogs = import "LrDialogs"
local LrFunctionContext = import "LrFunctionContext"
local LrTasks = import "LrTasks"

local LrApplication = import "LrApplication"
local LrSelection = import "LrSelection"
local LrDevelopController = import "LrDevelopController"
local LrSocket = import "LrSocket"
local LrTableUtils = import "LrTableUtils"

local LrPathUtils = import "LrPathUtils"
local LrFileUtils = import "LrFileUtils"

local function writePortToFile( port, index )
	local tempPath = LrPathUtils.getStandardFilePath( 'temp' )
	local filename = _PLUGIN.id .. '.port' .. index
	local filePath = LrPathUtils.child( tempPath, filename )
	
	local file = io.open( filePath, 'w+' )
	if file then
		file:write( tostring( port ) )
		file:close()
	end
end

local function cleanPortFile( index )
	local tempPath = LrPathUtils.getStandardFilePath( 'temp' )
	local filename = _PLUGIN.id .. '.port' .. index
	local filePath = LrPathUtils.child( tempPath, filename )
	
	LrFileUtils.delete( filePath )
end

local function revealPanel( adjustment )
	if LrDevelopController.revealPanelIfVisible then
		LrDevelopController.revealPanelIfVisible( adjustment )
	elseif LrDevelopController.revealPanel then
		LrDevelopController.revealPanel( adjustment )
	end
end

function changeAdjustmentValue( adjustment, delta, clippingOn )
	import 'LrApplicationView'.switchToModule( 'develop' )
	revealPanel( adjustment )
	
	local val = LrDevelopController.getValue( adjustment ) or 0
	local newVal = val + delta
	
	local min, max = LrDevelopController.getRange( adjustment )
	if min and max then
		if newVal < min then newVal = min end
		if newVal > max then newVal = max end
	end
	
	LrDevelopController.setValue( adjustment, newVal, clippingOn )
end

function changeTemperatureValue( adjustment, delta )
	import 'LrApplicationView'.switchToModule( 'develop' )
	revealPanel( adjustment )
	
	local val = LrDevelopController.getValue( adjustment ) or 0
	
	local min, max = LrDevelopController.getRange( adjustment )
	if min and max then
		if min < 0 then
			val = val + delta
		else
			local step = (math.log(max) - math.log(min)) / 400.0
			val = math.exp(math.log(val) + delta * step)
		end
		if val < min then val = min end
		if val > max then val = max end
	end
	
	LrDevelopController.setValue( adjustment, val )
end

--==============================================================================
-- All of the Develop parameters that we will monitor for changes.

local develop_params = {
	"Temperature",
	"Tint",
	"Exposure",
	"Contrast",
	"Highlights",
	"Shadows",
	"Whites",
	"Blacks",
	"Clarity",
	"Vibrance",
	"Saturation",
}

local develop_param_set = {}

for _, key in ipairs( develop_params ) do
	develop_param_set[ key ] = true
end

--------------------------------------------------------------------------------
-- Checks to see if observer[ key ] is equal to the given value.  If the value has
-- changed, reports the change to the given sender.
-- Used to notify external processes when settings change in Lr.

local function updateValue( observer, sender, key, value )

	if observer[ key ] ~= value then

		-- for table types, check if any values have changed
		if type( value ) == "table" and type( observer[ key ] ) == "table" then
			local different = false
			for k, v in pairs( value ) do
				if observer[ key ][ k ] ~= v then
					different = true
					break
				end
			end
			for k, v in pairs( observer[ key ] ) do
				if value[ k ]  ~= v then
					different = true
					break
				end
			end
			if not different then
				return
			end
		end

		observer[ key ] = value
	
		local data = LrTableUtils.tableToString {
			key = key,
			value = value,
		}
		
		if WIN_ENV then
			data = string.gsub( data, "\n", "\r\n" )
		end
	
		sender:send( data )
	end
end

--------------------------------------------------------------------------------
-- Calls the appropriate API to adjust a setting in Lr.

local function setValue( key, value )

	if value == "+" then
		LrDevelopController.increment( key )
		return
	end

	if value == "-" then
		LrDevelopController.decrement( key )
		return
	end
	
	if value == "reset" then
		LrDevelopController.resetToDefault( key )
		return
	end

	local numberValue = tonumber( value )
	
	if key == "rating" and numberValue then

		LrSelection.setRating( value )

	elseif key == "flag" and numberValue then

		if numberValue == -1 then
			LrSelection.flagAsReject()
		elseif numberValue == 0 then
			LrSelection.removeFlag()
		elseif numberValue == 1 then
			LrSelection.flagAsPick()
		end
		
	elseif key == "labels" then
	
		--[[ TODO: parse to get bools for each label, thencall:

			LrController.setColorLabels {
				[1] = bool,
				[2] = bool,
				[3] = bool,
				[4] = bool,
				[5] = bool,
			}
		]]--

	elseif key and develop_param_set[ key ] then

		value = tonumber( value )
		if value then
			LrDevelopController.setValue( key, value )
		end
	end

end

--------------------------------------------------------------------------------
-- simple parser for handling messages sent from the external process over the socket

local function parseMessage( data )

	if type( data ) == "string" then

		local _, _, key, value = string.find( data, "([^ ]+)%s*=%s*(.*)" ) -- ex: "rating = 2"
		
		if data and not key then
			data = loadstring( "return " .. data )
			if type( data ) == "table" then
				key = data.key
				value = data.value
			end
		end
	
		return key, value
	end
end

--------------------------------------------------------------------------------
-- checks all supported photo attributes for any changes that happened in Lr, reporting
-- them to the sender socket.

local function updateAttributes( observer )
	local sender = observer._sender
	local ok1, rating = pcall( LrSelection.getRating )
	local rVal = (ok1 and rating) or 0
	
	local ok2, flag = pcall( LrSelection.getFlag )
	local fVal = (ok2 and flag) or 0
	
	local ok3, label = pcall( LrSelection.getColorLabel )
	local lVal = ok3 and label
	
	updateValue( observer, sender, "rating", rVal )
	updateValue( observer, sender, "flag", fVal )
	updateValue( observer, sender, "labels", lVal )
end

--------------------------------------------------------------------------------
-- checks all Develop parameters for any changes that happened in Lr, reporting
-- them to the sender socket.

local function updateDevelopParameters( observer )
	local sender = observer._sender
	for _, param in ipairs( develop_params ) do
		local ok, val = pcall( LrDevelopController.getValue, param )
		if ok then
			updateValue( observer, sender, param, val )
		end
	end
end

--------------------------------------------------------------------------------

local AUTO_PORT = 0 -- port zero indicates that we want the OS to auto-assign the port

local address = "localhost"
local sendPort = AUTO_PORT
local receivePort = AUTO_PORT

--------------------------------------------------------------------------------
-- Start everything in a task so we can sleep in a loop until we are shut down.

LrTasks.startAsyncTask( function()

	-- a function context is required for the socket API below. When this context is exited the
	-- socket connection will be closed.

	LrFunctionContext.callWithContext( 'socket_remote', function( context )

		local senderPort, senderConnected, receiverPort, receiverConnected
		
		local function maybeStartService()
			-- Service started silently without Telnet countdown bezel
		end

		-- socket connection used to send messages from the plugin to the external process

		local sender = LrSocket.bind {
			name = "Remote Control Sender", -- (optional)
			functionContext = context,
			address = address,
			port = sendPort,
			mode = "send",

			onConnecting = function( socket, port )
				--LrDialogs.message("Sender port connecting...")
				senderPort = port
				writePortToFile( port, '2' )
				maybeStartService()
			end,
			
			onConnected = function( socket, port )
				--LrDialogs.message("Sender port connected...")
				senderConnected = true
			end,

			onMessage = function( socket, message )
				LrDialogs.message("We should never see this...")
				-- nothing, we don't expect to get any messages back
			end,

			onClosed = function( socket )
				--LrDialogs.message("Sender connection closed...")
				senderConnected = false
			end,

			onError = function( socket, err )
				--LrDialogs.message("Sender socket error: "..err)
				if err == "timeout" then
					--LrDialogs.message("Sender socket attempting re-connect...")
					socket:reconnect()
				end
			end,
			plugin = _PLUGIN
		}

		-- socket connection used to recieve messages from the external process

		local receiver = LrSocket.bind {
			name = "Remote Control Receiver", -- (optional)
			functionContext = context,
			address = address,
			port = receivePort,
			mode = "receive",

			onConnecting = function( socket, port )
				--LrDialogs.message("Receiver port connecting...")			
				receiverPort = port
				writePortToFile( port, '1' )
				maybeStartService()
			end,

			onConnected = function( socket, port )
				--LrDialogs.message("Receiver port connected...")			
				receiverConnected = true
			end,

			onClosed = function( socket )
				--LrDialogs.message("Receiver port closed...")			
				receiverConnected = false
			end,

			onMessage = function( socket, message )
				--LrDialogs.message("Receiver port message recieved...")
				if type( message ) == "string" then
					local firstPipe = string.find( message, "|", 1, true )
					if firstPipe then
						local messageId = string.sub( message, 1, firstPipe - 1 )
						local secondPipe = string.find( message, "|", firstPipe + 1, true )
						local action, params
						if secondPipe then
							action = string.sub( message, firstPipe + 1, secondPipe - 1 )
							params = string.sub( message, secondPipe + 1 )
						else
							action = string.sub( message, firstPipe + 1 )
							params = ""
						end
						
						if action == "runscript" then
							local method, err = loadstring( params )
							if method then
								local ok, res = pcall( method )
								if not ok then
									LrDialogs.showBezel( "Script Error: " .. tostring( res ), 2 )
								end
							else
								LrDialogs.showBezel( "Parse Error: " .. tostring( err ), 2 )
							end
						end
					else
						local key, value = parseMessage( message )
						if key and value then
							setValue( key, value )
							LrDialogs.showBezel( key .. " " .. value, 4 )
						end
					end
				end
			end,
			
			onError = function( socket, err )
				--LrDialogs.message("Receiver port error. Attempting reconnect...")			
				if err == "timeout" then
					socket:reconnect()
				end
			end,
			plugin = _PLUGIN
		}
		
		-- object used to observe both selection changes and Develop parameter changes and
		-- report them all to the sender socket.
		
		local observer = {
			_sender = sender,
		}
		
		LrApplication.addActivePhotoChangeObserver( context, observer, updateAttributes )
		LrDevelopController.addAdjustmentChangeObserver( context, observer, updateDevelopParameters )

		LrDevelopController.revealAdjustedControls( true ) -- doesn't exist in API reference
	
		-- do intial update

		updateAttributes( observer )
		updateDevelopParameters( observer )

		-- loop until this plug-in global is set to false, either by a "close" command issued by the external
		-- process or when the user selects "Stop" from the "Plug-in Extras" menu.

		_G.running = true

		while _G.running do
			LrTasks.sleep( 1/2 ) -- seconds
		end
		
		--LrDialogs.message("Sender type ='"..sender:type().."'")
		
		_G.shutdown = true

		if senderConnected then
			sender:close()
		end
		
		if receiverConnected then
			receiver:close()
		end

		cleanPortFile( '1' )
		cleanPortFile( '2' )
				
		LrDialogs.showBezel( "Remote Connections Closed", 4 )
			
	end )

end )
