extends Node

# Player preferences that outlive a session, kept in one place so the menu and
# the table cannot disagree about them.
#
# Deliberately short: every entry here has to actually do something. The game
# has no audio, so there are no volume sliders to put in front of people.

const SETTINGS_PATH := "user://settings.cfg"

# Off by default: the hand has always arrived in the order it was dealt, with
# an Arrange button for anyone who wants it tidied. Turning this on by default
# would change how the game plays for everybody who never asked.
var auto_sort_hand: bool = false
var fullscreen: bool = false

var _web_fullscreen_checked: bool = false
var _web_fullscreen_available: bool = false

func _ready() -> void:
	load_settings()
	if fullscreen and supports_fullscreen():
		_apply_fullscreen(true)

func load_settings() -> void:
	var config := ConfigFile.new()
	if config.load(SETTINGS_PATH) != OK:
		return
	auto_sort_hand = bool(config.get_value("game", "auto_sort_hand", auto_sort_hand))
	fullscreen = bool(config.get_value("display", "fullscreen", fullscreen))

func save() -> void:
	var config := ConfigFile.new()
	config.set_value("game", "auto_sort_hand", auto_sort_hand)
	config.set_value("display", "fullscreen", fullscreen)
	config.save(SETTINGS_PATH)

func set_auto_sort_hand(on: bool) -> void:
	auto_sort_hand = on
	save()

func set_fullscreen(on: bool) -> void:
	fullscreen = on
	_apply_fullscreen(on)
	save()

func _apply_fullscreen(on: bool) -> void:
	if not supports_fullscreen():
		return
	DisplayServer.window_set_mode(
		DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)

func supports_fullscreen() -> bool:
	# A native handheld build is already fullscreen, so offering a switch that
	# does nothing is worse than not offering one.
	if OS.has_feature("android") or OS.has_feature("ios"):
		return false
	if not OS.has_feature("web"):
		return true
	return _browser_allows_fullscreen()

func _browser_allows_fullscreen() -> bool:
	# Feature detection rather than browser sniffing. iPhone Safari has no
	# element fullscreen at all, and it is the browser that says so - a name
	# check would also have to guess about iPadOS, which asks for desktop sites
	# and does not report as iOS.
	if _web_fullscreen_checked:
		return _web_fullscreen_available
	_web_fullscreen_checked = true
	_web_fullscreen_available = false
	if not OS.has_feature("web"):
		return false
	if not ClassDB.class_exists("JavaScriptBridge"):
		return false
	var probe := """
	(function () {
		try {
			if (document.fullscreenEnabled) { return 1; }
			if (document.webkitFullscreenEnabled) { return 1; }
		} catch (e) {}
		return 0;
	})();
	"""
	var answer = JavaScriptBridge.eval(probe, true)
	_web_fullscreen_available = answer != null and int(answer) == 1
	return _web_fullscreen_available
