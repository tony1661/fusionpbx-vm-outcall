--[[

Author: Tony Fernandez

Date: May 6th 2021

Database Tables and Fields:
	v_voicemail_outcall:		--contains all voicemail boxes that have the outcalling feature enabled.
		voicemail_uuid 			(uuid)
		enabled 				(boolean)
		caller_id 				(varchar) --the caller ID that should be displayed on the outcall
		acknowledged			(boolean)
	
	v_voicemail_outcall_destinations:	--contains information required for each destination
		v_voicemail_destination_uuid (serial)
		outcall_digits 			(numberic)
		gateway_uuid 			(uuid)
		position 				(numeric)
		voicemail_uuid 			(uuid)

	v_voicemail_outcall_tracker:		--tracks the status of the outcall campaign
		voicemail_message_uuid	(uuid)
		last_position			(numeric)


]]

--connect to the database
	Database = require "resources.functions.database";
	dbh = Database.new('system');

--debug
	debug["info"] = true;
	debug["sql"] = true;

--variables
	msgs = {} --used for storing vms that need outcalling
	tracker = {} --used for storing vms that need outcalling
	outcalls = {} --used for storing outcalls that will happen
	values_returned = 0 -- var to see if there is any values in the query
	i = 0 --increment variable
	existing = 0 --variable to track if a message uuid exists while looping through and checking the msgs and tracker arrays


---------------------------------------------------
-- PART ONE: Population of the tracking database --
---------------------------------------------------

--get voicemail message uuids that need outcalling. They will be stored in the msgs array in the format: *1 => 3da09d4b-ded1-49d1-8901-ca269a3b7a56*
i = 0 --reset increment variable
sql = [[SELECT vm.voicemail_message_uuid FROM v_voicemail_messages vm INNER JOIN v_voicemail_outcall voc ON (vm.voicemail_uuid = voc.voicemail_uuid)
				where voc.enabled = true and voc.acknowledged = false]];
dbh:query(sql, params, function(result)
	values_returned = 1
	for key, val in pairs(result) do
		i = i + 1
		msgs[i] = val
		freeswitch.consoleLog("notice", "Voicemail messages that require and outcalling:   " .. key.. "[" ..i.."]: " .. val .. "\n");
	end
end);

--get a list of all the voicemail messages that are already being tracked. They will be stored in the tracker array in the format: *1 => 3da09d4b-ded1-49d1-8901-ca269a3b7a56*
if (values_returned == 1) then --only proceed if the previous query returned results
	i = 0 --reset increment variable
	values_returned = 0 --reset values_returned
	dbh:query("select voicemail_message_uuid from v_voicemail_outcall_tracker", params, function(result)
		values_returned = 1
		for key, val in pairs(result) do
			i = i + 1
			tracker[i] = val
			if (debug["sql"]) then
				freeswitch.consoleLog("notice", "Tracker Status:   " .. key.. "["..i.."]: " .. val .. "\n");
			end
		end
	end);
else
	freeswitch.consoleLog("notice", "No voicemails in need of outcalling" .. "\n");
end

if (values_returned == 1) then -- there are already values so we must compare the msgs array with the tracker array
	values_returned = 0 --reset values_returned
	for key,val in pairs(msgs) do
		freeswitch.consoleLog("notice", "Msgs Array:   " .. key.. ": " .. val .. "\n");
		existing = 0 --reset the existing variable
		for k,v in pairs(tracker) do
			if (val == v) then --already exists in tracker. Do nothing.
				existing = 1
			end
		end
		if (existing == 1) then
			freeswitch.consoleLog("notice", "EXISTING:   " .. key.. ": " .. val .. "\n");
		else
			dbh:query("INSERT INTO v_voicemail_outcall_tracker VALUES ('"..val.."', 1)", params);
			freeswitch.consoleLog("notice", "Adding   " .. key.. ": " .. val .. "to tracker table\n");
		end
	end
else --there are no values in the tracker db table so we can add all of the results from the msgs array.
	freeswitch.consoleLog("notice", "Tracker DB table is empty. Populating..\n");
	for key,val in pairs(msgs) do
		dbh:query("INSERT INTO v_voicemail_outcall_tracker VALUES ('"..val.."', 1)", params);
	end
end

---------------------------------------------------
--       PART TWO: Start of the outcalling       --
---------------------------------------------------
dbh:query('SELECT vvot.last_position,voc.caller_id , vm.voicemail_uuid, vm.voicemail_message_uuid,vvod.outcall_digits,vvod.gateway_uuid FROM v_voicemail_messages vm INNER JOIN v_voicemail_outcall voc ON (vm.voicemail_uuid = voc.voicemail_uuid) inner join v_voicemail_outcall_destinations vvod on (voc.voicemail_uuid = vvod.voicemail_uuid) inner join v_voicemail_outcall_tracker vvot on (vm.voicemail_message_uuid = vvot.voicemail_message_uuid) WHERE voc.enabled = true AND voc.acknowledged = false AND vvot.last_position = vvod."position" group by vm.voicemail_message_uuid,vm.voicemail_uuid,voc.caller_id,vvod.outcall_digits,vvod.outcall_digits,vvot.last_position,vvod.gateway_uuid', params, function(result)
	for key, val in pairs(result) do
		freeswitch.consoleLog("notice", "Calling:   " .. key.. ": " .. val .. "\n");
		if (key == 'last_position') then
			--attempt the call
			outSession = freeswitch.Session("{origination_caller_id_name="..result["caller_id"]..",origination_caller_id_number=".. "9057592660" .."}sofia/gateway/".. result["gateway_uuid"] .."/".. result["outcall_digits"])
			outSession:setAutoHangup(true)
			while(outSession:ready() and dispoA ~= "ANSWER") do
				dispoA = outSession:getVariable("endpoint_disposition")
				freeswitch.consoleLog("INFO","Leg A disposition is '" .. dispoA .. "'\n")
				os.execute("sleep 1")
			end
			if ( outSession:ready() ) then
				--pause for 1 second
				outSession:execute("sleep", 1000)
				digits = outSession:playAndGetDigits(1, 1, 3, 5000, "", "wav_location_temp", "/error.wav", "\\d+")
				outSession:hangup();
				dbh:query('UPDATE v_voicemail_outcall_tracker SET last_position = '.. result["last_position"] + 1 ..' WHERE voicemail_message_uuid = '..result['voicemail_message_uuid']..'', params);
			else
				-- opps, lost leg A handle this case
				freeswitch.consoleLog("NOTICE","It appears that outSession is disconnected...\n")
		
		
				-- log the hangup cause
				local outCause = outSession:hangupCause()
				freeswitch.consoleLog("info", "outSession:hangupCause() = " .. outCause)
			end
			outSession:hangup();
		end
	end
end);
