extends SceneTree

# Settings, and text entry on a phone browser.
#
# Both are "shell" behaviour rather than game rules: what the app remembers
# between runs, and how a player gets characters into a text box. The second
# one cannot be fully checked headlessly - there is no browser here - so what
# is checked is the part that was actually wrong: the conditions that decide
# whether the workaround runs at all, and the maths that puts it in the right
# place. Guessing those wrong is worse than not having it, because an input
# box in the wrong spot is one a player cannot tap.

var fails: Array = []
var checks := 0

func ok(cond: bool, label: String) -> void:
	checks += 1
	if not cond:
		fails.append(label)
		print("  FAIL: ", label)

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	settings_persist_check()
	fullscreen_support_check()
	await settings_panel_check()
	await auto_sort_check()
	web_keyboard_conditions_check()
	await web_keyboard_placement_check()
	await web_keyboard_visibility_check()
	_report()

# --- what is remembered -----------------------------------------------------

func settings_persist_check() -> void:
	var settings := root.get_node_or_null("GameSettings")
	ok(settings != null, "the settings autoload is available")
	if settings == null:
		return

	# The hand has always arrived in dealt order with Arrange to tidy it. A
	# setting that defaults to on would change how the game plays for everybody
	# who never opened the menu.
	var fresh = load("res://scripts/ui/GameSettings.gd").new()
	ok(not fresh.auto_sort_hand, "sorting the hand is off unless it is asked for")
	fresh.free()

	var before_sort: bool = settings.auto_sort_hand
	var before_full: bool = settings.fullscreen

	settings.set_auto_sort_hand(true)
	var reloaded = load("res://scripts/ui/GameSettings.gd").new()
	reloaded.load_settings()
	ok(reloaded.auto_sort_hand, "a setting survives being written and read back")
	reloaded.free()

	settings.set_auto_sort_hand(false)
	var reloaded_off = load("res://scripts/ui/GameSettings.gd").new()
	reloaded_off.load_settings()
	ok(not reloaded_off.auto_sort_hand, "and so does turning it off again")
	reloaded_off.free()

	settings.auto_sort_hand = before_sort
	settings.fullscreen = before_full
	settings.save()

func fullscreen_support_check() -> void:
	var settings := root.get_node_or_null("GameSettings")
	if settings == null:
		return
	# This test runs as a desktop build, where fullscreen is real. The point of
	# the check is that the answer is decided by the platform rather than
	# assumed, so the switch can be hidden where it would do nothing.
	ok(settings.supports_fullscreen(), "a desktop build offers fullscreen")

# --- the settings screen ----------------------------------------------------

func settings_panel_check() -> void:
	var settings := root.get_node_or_null("GameSettings")
	var panel: Control = load("res://scenes/ui/SettingsPanel.tscn").instantiate()
	root.add_child(panel)
	await process_frame

	ok(not panel.visible, "the settings panel starts closed")

	settings.auto_sort_hand = true
	panel.open()
	ok(panel.visible, "opening it shows it")
	ok(panel.auto_sort_check.button_pressed, "and it opens showing what is actually set")

	# Toggling has to reach the stored setting, not just the checkbox - the
	# table reads the setting, never the box.
	panel.auto_sort_check.button_pressed = false
	ok(not settings.auto_sort_hand, "unticking a box changes the setting behind it")

	ok(panel.fullscreen_row.visible == settings.supports_fullscreen(), "the fullscreen switch is only shown where it works")

	# The name is the one thing here that other screens read, so it has to be
	# written where they look for it rather than kept in the panel. That is a
	# real file this machine's player uses, so put back whatever was in it -
	# a test must not leave its own name sitting in somebody's profile.
	var profile := ConfigFile.new()
	profile.load("user://profile.cfg")
	var real_name := str(profile.get_value("player", "name", ""))
	var net := root.get_node_or_null("NetworkManager")
	var real_network_name := str(net.local_player_name) if net != null else ""

	panel.name_input.text = "Testy McTest"
	panel.close()
	ok(not panel.visible, "Done closes it")
	var config := ConfigFile.new()
	config.load("user://profile.cfg")
	ok(str(config.get_value("player", "name", "")) == "Testy McTest", "and the name typed here is the name that is saved")

	config.set_value("player", "name", real_name)
	config.save("user://profile.cfg")
	if net != null:
		net.local_player_name = real_network_name
	var restored := ConfigFile.new()
	restored.load("user://profile.cfg")
	ok(str(restored.get_value("player", "name", "")) == real_name, "and this check puts the real one back")

	panel.queue_free()
	await process_frame

func auto_sort_check() -> void:
	# The setting has to be picked up by the table itself. It is the same flag
	# the Arrange button sets, just set before the first card lands.
	var settings := root.get_node_or_null("GameSettings")
	var net := root.get_node_or_null("NetworkManager")
	net.pending_match_setup = {
		"players": [], "phase": "trump_mode_choice", "dealer_seat_id": "",
		"trump_holder_seat_id": "", "dealer_draw_cards": [], "is_host": false
	}
	net.latest_game_state_snapshot = {}

	for wanted in [true, false]:
		settings.auto_sort_hand = wanted
		var table: Node = load("res://scenes/game/GameRoom3D.tscn").instantiate()
		root.add_child(table)
		await process_frame
		ok(table.my_hand_sorted == wanted, "the table starts sorted only when the setting says so (%s)" % wanted)
		table.queue_free()
		await process_frame

	settings.auto_sort_hand = false
	settings.save()

# --- typing on a phone ------------------------------------------------------

func web_keyboard_conditions_check() -> void:
	var keyboard := root.get_node_or_null("WebKeyboard")
	ok(keyboard != null, "the web keyboard helper is available")
	if keyboard == null:
		return

	# The overlay must never appear outside a touch browser. On a desktop it
	# would put an HTML box over a game that is already handling text fine, and
	# on a native build there is no page to put it on.
	ok(not keyboard.is_active(), "it stays out of the way on a native build")

	var line_edit := LineEdit.new()
	root.add_child(line_edit)
	keyboard.attach(line_edit)
	ok(keyboard.entries.is_empty(), "attaching does nothing where it is not needed")
	ok(line_edit.virtual_keyboard_enabled, "and the engine's own keyboard is left alone")

	# Every entry point must survive being called anyway, because the screens
	# call them unconditionally rather than testing the platform themselves.
	keyboard.sync(line_edit)
	keyboard.detach(line_edit)
	keyboard.attach(null)
	ok(true, "sync, detach and a null field are all safe no-ops here")

	line_edit.queue_free()

func web_keyboard_placement_check() -> void:
	var keyboard := root.get_node_or_null("WebKeyboard")
	if keyboard == null:
		return

	# The overlay is positioned from this rect. If it is wrong the box lands
	# somewhere other than the field it belongs to, which is worse than the bug
	# it is fixing - an invisible input over the middle of the screen.
	var holder := Control.new()
	root.add_child(holder)
	var line_edit := LineEdit.new()
	holder.add_child(line_edit)
	holder.position = Vector2(40, 25)
	line_edit.position = Vector2(10, 5)
	line_edit.size = Vector2(220, 48)
	await process_frame

	var rect: Rect2 = keyboard.screen_rect_of(line_edit)
	ok(rect.position.is_equal_approx(Vector2(50, 30)), "the field's screen position counts its parents in (got %s)" % rect.position)
	ok(rect.size.is_equal_approx(Vector2(220, 48)), "and its size is the size it is drawn at (got %s)" % rect.size)

	# Inside a CanvasLayer the control's own position is not where it is drawn,
	# and the game's HUD lives in one.
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var layered := LineEdit.new()
	layer.add_child(layered)
	layered.position = Vector2(12, 8)
	layered.size = Vector2(100, 40)
	layer.offset = Vector2(200, 100)
	await process_frame
	var layered_rect: Rect2 = keyboard.screen_rect_of(layered)
	ok(layered_rect.position.is_equal_approx(Vector2(212, 108)), "a field inside a CanvasLayer is placed where the layer puts it (got %s)" % layered_rect.position)

	holder.queue_free()
	layer.queue_free()
	await process_frame

func web_keyboard_visibility_check() -> void:
	# An HTML input sits on top of the canvas, so nothing the game draws can
	# cover it. Every case below was a real box left floating on a phone.
	var keyboard := root.get_node_or_null("WebKeyboard")
	if keyboard == null:
		return

	var page := Control.new()
	root.add_child(page)
	var page_field := LineEdit.new()
	page.add_child(page_field)

	var panel := Control.new()
	root.add_child(panel)
	var panel_field := LineEdit.new()
	panel.add_child(panel_field)
	panel.visible = false
	await process_frame

	ok(keyboard.should_show(page_field), "a field on the open screen is shown")
	ok(not keyboard.should_show(panel_field), "one on a hidden panel is not")

	# Opening the settings panel: the screen underneath is still visible, so
	# without this both name boxes were on screen, stacked.
	panel.visible = true
	keyboard.push_exclusive(panel)
	await process_frame
	ok(keyboard.should_show(panel_field), "opening a panel shows its own field")
	ok(not keyboard.should_show(page_field), "and takes the one underneath off the page")

	keyboard.pop_exclusive(panel)
	panel.visible = false
	await process_frame
	ok(keyboard.should_show(page_field), "closing it gives the screen underneath its field back")

	# A panel that is freed or hidden without saying so must not lock every
	# field off the page for the rest of the session.
	keyboard.push_exclusive(panel)
	ok(keyboard.should_show(page_field), "a panel hidden without closing does not hold the page hostage")
	keyboard.pop_exclusive(panel)

	# The rotate prompt: a CanvasLayer at 128 still cannot cover an HTML
	# element, so the name box floated over "turn your phone sideways".
	keyboard.set_blocked(true)
	ok(not keyboard.should_show(page_field), "nothing shows while the rotate prompt is up")
	keyboard.set_blocked(false)
	ok(keyboard.should_show(page_field), "and it comes back when the phone is turned")

	ok(not keyboard.should_show(null), "a field that has gone away shows nothing")

	# The engine's own keyboard is only given up once an input box is confirmed
	# to be on the page. Taking that on trust is what made the room code box
	# dead: one frame where the canvas had no measurable size left the overlay
	# hidden for good, and the engine's keyboard had already been switched off,
	# so tapping the field did nothing at all.
	var probe := LineEdit.new()
	page.add_child(probe)
	var entry := {"line_edit": probe, "owns_keyboard": false}
	ok(probe.virtual_keyboard_enabled, "a field starts with the engine's keyboard on")
	keyboard._claim_keyboard(entry, probe)
	ok(not probe.virtual_keyboard_enabled, "confirming the overlay hands the keyboard over")
	ok(bool(entry["owns_keyboard"]), "and the overlay knows it owns it")
	keyboard._release_keyboard(entry)
	ok(probe.virtual_keyboard_enabled, "letting go gives the engine's keyboard back")

	# If the overlay cannot be placed it must hand the field back rather than
	# leave a box that does nothing. One bad frame is not enough - a container
	# has not laid out on the frame it is first shown - but a run of them is.
	keyboard._claim_keyboard(entry, probe)
	entry["misses"] = 0
	keyboard._note_place_failed(entry)
	ok(not probe.virtual_keyboard_enabled, "one frame the overlay cannot be placed is not given up on")
	for _i in range(keyboard.PLACE_FAILURES_BEFORE_GIVING_UP):
		keyboard._note_place_failed(entry)
	ok(probe.virtual_keyboard_enabled, "but a field the overlay never reaches goes back to the engine")

	# Focusing a text field must not go through Godot on a phone: its focus
	# opens the engine's hidden input and takes the keyboard, which cannot then
	# be handed back. This is what made the room code box dead while the name
	# box was fine - only the room code page ever grabbed focus.
	var unattached := LineEdit.new()
	page.add_child(unattached)
	await process_frame
	keyboard.focus(unattached)
	ok(unattached.has_focus(), "a field the overlay does not own is focused normally")

	page.queue_free()
	panel.queue_free()
	await process_frame

func _report() -> void:
	print("CHECKS RUN: ", checks)
	if fails.is_empty():
		print("ALL_SETTINGS_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		quit(1)
