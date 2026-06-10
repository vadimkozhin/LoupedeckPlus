tell application "Capture One"
	repeat with v in (get selected variants)
		tell adjustments of v
			set bw to black and white
			set black and white to not bw
		end tell
	end repeat
end tell
