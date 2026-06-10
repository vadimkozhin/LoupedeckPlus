use AppleScript version "2.4" -- Yosemite (10.10) or later
use scripting additions

-- Increase Exposure by 1 stop
set exposureVar to -1.0

tell application "Capture One 21"
	
	repeat with variantItem in (get selected variants)
		-- Get current exposure
		tell adjustments of variantItem
			set currentExposure to exposure
		end tell

		-- Set new exposure
		tell adjustments of variantItem
			set exposure to (currentExposure + exposureVar)
		end tell

	end repeat
end tell