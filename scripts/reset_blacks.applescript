tell application "Capture One"
	repeat with v in (get selected variants)
		set black recovery of adjustments of v to {{DEFAULT}}
	end repeat
end tell
