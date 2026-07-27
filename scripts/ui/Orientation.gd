extends Node

# Keeps the game landscape on a phone.
#
# A web page cannot rotate a device. `screen.orientation.lock()` is the only
# API that exists anywhere, it requires fullscreen, and Safari does not
# implement it on any platform - so on an iPhone the only thing that actually
# works is asking the player to turn the phone. Android browsers get a real
# lock on top of the prompt.
#
# Native builds are not involved: `window/handheld/orientation` is set to
# sensor landscape, so Android holds the game landscape itself and this
# overlay must never appear there.

# Everything below `window/size/viewport_height / viewport_width` is portrait
# enough that the table gets cut off at the sides, because the camera keeps
# vertical FOV and the stretch aspect is "expand".
const LANDSCAPE_MIN_ASPECT := 1.0

var layer: CanvasLayer = null
var overlay: Control = null
var message: Label = null
var hint: Label = null

# Whether this build/platform is one where the player can be asked to rotate.
var watching: bool = false
# The lock is attempted once, on the first real tap, because browsers only
# grant it inside a user gesture.
var lock_attempted: bool = false

func _ready() -> void:
	watching = _is_touch_browser()
	if not watching:
		# Desktop browsers and native builds never see this. Nagging someone
		# who narrowed their desktop window would be worse than the layout.
		set_process_input(false)
		return

	_build_overlay()
	get_viewport().size_changed.connect(_refresh)
	_refresh()

func _is_touch_browser() -> bool:
	# Only a browser on a touch device can end up in an orientation the game
	# cannot handle. A native Android build is pinned landscape by the project
	# settings, and a desktop browser is the player's own window to size.
	#
	# Checked by capability rather than by sniffing the platform: iPadOS Safari
	# requests desktop sites by default, so it does not report as iOS, and a
	# name-based check would miss it.
	if not OS.has_feature("web"):
		return false
	return DisplayServer.is_touchscreen_available()

func is_portrait(size: Vector2) -> bool:
	if size.x <= 0.0 or size.y <= 0.0:
		return false
	return (size.x / size.y) < LANDSCAPE_MIN_ASPECT

func _refresh() -> void:
	if not watching or overlay == null or not is_instance_valid(overlay):
		return
	overlay.visible = is_portrait(get_viewport().get_visible_rect().size)

func _input(event: InputEvent) -> void:
	if not watching or lock_attempted:
		return
	var pressed := false
	if event is InputEventScreenTouch:
		pressed = event.pressed
	elif event is InputEventMouseButton:
		pressed = event.pressed
	if not pressed:
		return

	# Browsers only allow fullscreen and an orientation lock while a user
	# gesture is still "live", which is why this waits for the first tap
	# rather than running at startup.
	lock_attempted = true
	request_landscape_lock()

func request_landscape_lock() -> void:
	if not OS.has_feature("web"):
		return
	if not Engine.has_singleton("JavaScriptBridge") and not ClassDB.class_exists("JavaScriptBridge"):
		return

	# Feature detection, never browser sniffing: Safari exposes
	# screen.orientation but not screen.orientation.lock, and iPhone Safari has
	# no element fullscreen at all. Both are simply absent there, so both
	# checks fail and the prompt is left to do the job on its own.
	var script := """
	(function () {
		var out = 0;
		try {
			var el = document.documentElement;
			var full = el.requestFullscreen || el.webkitRequestFullscreen;
			if (full) {
				var f = full.call(el);
				if (f && f.catch) { f.catch(function () {}); }
				out += 1;
			}
			if (window.screen && screen.orientation && screen.orientation.lock) {
				var o = screen.orientation.lock('landscape');
				if (o && o.catch) { o.catch(function () {}); }
				out += 2;
			}
		} catch (e) {}
		return out;
	})();
	"""
	JavaScriptBridge.eval(script, true)

func _build_overlay() -> void:
	layer = CanvasLayer.new()
	layer.name = "RotateLayer"
	# Above every HUD in the game, including the leave confirmation and the
	# match-over screen, so it cannot be drawn underneath anything.
	layer.layer = 128
	add_child(layer)

	overlay = Control.new()
	overlay.name = "RotatePrompt"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.visible = false
	layer.add_child(overlay)

	var dim := ColorRect.new()
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.color = Color(0.035, 0.06, 0.05, 1.0)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(center)

	var box := VBoxContainer.new()
	box.name = "RotateBox"
	box.add_theme_constant_override("separation", 14)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(box)

	var glyph := Label.new()
	glyph.text = "⟳"
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.add_theme_font_size_override("font_size", 84)
	glyph.add_theme_color_override("font_color", Color(0.463, 0.831, 0.6))
	box.add_child(glyph)

	message = Label.new()
	message.name = "RotateMessage"
	message.text = "Turn your phone sideways"
	message.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	message.add_theme_font_size_override("font_size", 26)
	box.add_child(message)

	# Without this line the player whose rotation lock is on simply turns the
	# phone, nothing happens, and there is nothing on screen to explain why.
	hint = Label.new()
	hint.name = "RotateHint"
	hint.text = "MendiGo is played in landscape.\nIf nothing happens, switch off rotation lock in your phone's control centre."
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(320, 0)
	hint.add_theme_font_size_override("font_size", 15)
	hint.add_theme_color_override("font_color", Color(0.604, 0.702, 0.647))
	box.add_child(hint)
