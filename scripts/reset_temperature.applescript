tell application "Capture One"
	repeat with v in (get selected variants)
		tell adjustments of v
			set currentTint to tint
			set white balance preset to "Shot"
			set tint to currentTint
		end tell
	end repeat
end tell
