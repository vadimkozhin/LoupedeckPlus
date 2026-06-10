tell application "Capture One"
	repeat with v in (get selected variants)
		tell color editor settings of adjustments of v
			set saturation change of basic color correction "blue" to (get saturation change of basic color correction "blue") - 1.0
		end tell
	end repeat
end tell
