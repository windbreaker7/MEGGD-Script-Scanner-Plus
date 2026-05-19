# Script Version 1.0.0

- The script has been created!

# Script Scanner Update to 1.1.0

+ Added a filter when searching for the number of matches.
+ Added a warning about unsupported required features.
+ Added support for PC devices.
+ A feature has been added that allows you to search for various scripts with multiple matching terms. Example: "GetMouse, FireServer".
+ Added a button to hide the interface.
+ The `clamp_pos` function has been changed to prevent the GUI from going beyond the screen/monitor boundaries.

# Script Scanner Update to 1.1.5

+ Fixed a bug with the hide button (it incorrectly detected the release of a finger/mouse).
+ Fixed line scrolling bug.
+ Added highlighting of matches.

# Script Scanner Update to 1.1.6

+ The decompiler has been fixed.

# Script Scanner Update to 1.1.7

+ Improved search speed.
+ The API 500 error has been fixed.
+ The "THEME" button has been removed.
+ The search has been fixed.

# Script Scanner Update to 1.2.0

+ Added setting
 - Decompiler mode
 - Do not show comments in code
+ The bug with `resize_handle` has been fixed.
+ Added new decompiler "Shiny" from Rocult.

# Script Scanner Update to 1.2.1

+ The "Do not show comments in code" setting has been fixed.
+ Added animation when selecting the Decompiler mode.

# Script Scanner Update to 1.3.0 (Fork by windbreaker7)

**NEW FEATURES:**

+ **Type Filter Bar** - Added filter buttons (LocalScript, ModuleScript, Script)
  - Filter multiple script types simultaneously
  - Visual toggle with color-coded buttons
  - Dynamic filter visualization with animations

+ **Export to File Button** - Save decompiled scripts locally
  - New green "Export" button in code viewer
  - Floppy disk icon design
  - Success animation on export
  - Files saved as MEGGD_[ScriptName].lua
  - Error handling for write failures

+ **Enhanced Search Results** - Type filtering integrated into search
  - Filter results by script type before/after search
  - Only show results matching selected types
  - Prevent deselecting all filters (keeps at least one active)

+ **UI Improvements**
  - Repositioned content area to accommodate filter bar
  - Better spacing and layout management
  - New filter bar at position UDim2(0, 10, 0, 101) with height 26
  - Dynamic positioning of search container

+ **Advanced Filtering System**
  - `active_type_filters` table for tracking selected types
  - `update_filter_visuals()` function for dynamic button styling
  - Toggle animations when filters are activated/deactivated
  - Prevents deselecting the last active filter

+ **Export Icon System**
  - `icon_export` - Shows floppy disk save icon
  - `icon_export_ok` - Shows checkmark on successful export
  - Dynamic icon switching based on export status

**CHANGES:**

~ Version bump from 1.2.1 to 1.3.0
~ Improved content area positioning for filter bar integration
~ Enhanced button color system with filter-specific colors
~ Better visual feedback for filter selections

