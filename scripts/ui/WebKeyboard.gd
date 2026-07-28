extends Node

# Text entry on a phone browser.
#
# Godot draws its own LineEdit on a canvas, so the browser has no idea a text
# field exists. To get a keyboard at all the engine asks for one and feeds the
# result back through a hidden element - and that path only survives keyboards
# that send ordinary key events. Samsung's does. Gboard and iOS Safari do not:
# they compose text (autocorrect, suggestions, swipe) and deliver it as an
# input/composition event, so the keyboard opens and typing goes nowhere. On
# iOS the keyboard often does not open at all, because focus() only counts
# inside a live user gesture and Godot handles the tap a frame later.
#
# So instead of asking the browser for a keyboard, this puts a real <input> on
# top of the canvas exactly where the LineEdit is drawn. The tap lands on a
# genuine HTML field, the browser opens whatever keyboard it likes, composition
# and autocorrect work because nothing is intercepting them, and the value is
# copied back into the LineEdit so the rest of the game reads `.text` as usual.
#
# Nothing here runs outside a touch browser. Desktop browsers and native builds
# use the engine's own text handling, which works.

const ELEMENT_FONT_PX := 16   # below 16, iOS Safari zooms the page in on focus

var entries: Array = []       # [{ "id": int, "line_edit": LineEdit, "uppercase": bool, "rect": Rect2, "shown": bool }]

var _next_id: int = 1
var _installed: bool = false
var _input_cb = null
var _submit_cb = null

func _ready() -> void:
	if not is_active():
		set_process(false)

# --- when this is used at all ----------------------------------------------

func is_active() -> bool:
	# Checked by capability, not by platform name: iPadOS Safari asks for
	# desktop sites and does not report as iOS, and a laptop with a touchscreen
	# is perfectly happy either way.
	if not OS.has_feature("web"):
		return false
	return DisplayServer.is_touchscreen_available()

# --- attaching --------------------------------------------------------------

func attach(line_edit: LineEdit, uppercase: bool = false) -> void:
	if line_edit == null or not is_active():
		return
	for entry_raw in entries:
		if (entry_raw as Dictionary).get("line_edit", null) == line_edit:
			return

	_install()
	if not _installed:
		return

	# The engine's own keyboard is deliberately left switched on until the
	# overlay is confirmed to be on the page. If anything stops the overlay
	# appearing, the field still behaves the way it did before this class
	# existed - which works on some phones - instead of being a box that
	# nothing at all happens when you tap.
	var id := _next_id
	_next_id += 1
	entries.append({
		"id": id, "line_edit": line_edit, "uppercase": uppercase,
		"rect": Rect2(), "shown": false, "owns_keyboard": false,
	})

	var placeholder := str(line_edit.placeholder_text).replace("'", "")
	var centred := line_edit.alignment == HORIZONTAL_ALIGNMENT_CENTER
	_eval("window.__mendigoVK.create(%d, '%s', %d, %s, %s);" % [
		id, placeholder, maxi(0, line_edit.max_length),
		"true" if centred else "false", "true" if uppercase else "false"])
	_eval("window.__mendigoVK.sync(%d, '%s');" % [id, str(line_edit.text).replace("'", "")])

	line_edit.tree_exiting.connect(func(): detach(line_edit))

func sync(line_edit: LineEdit) -> void:
	# Call after setting `.text` from code. The overlay holds the real text, so
	# without this a field cleared by the game still shows the old value.
	if line_edit == null or not is_active():
		return
	for entry_raw in entries:
		var entry: Dictionary = entry_raw
		if entry.get("line_edit", null) != line_edit:
			continue
		_eval("window.__mendigoVK.sync(%d, '%s');" % [int(entry.get("id", 0)), str(line_edit.text).replace("'", "")])
		return

func detach(line_edit: LineEdit) -> void:
	for i in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[i]
		if entry.get("line_edit", null) != line_edit:
			continue
		_release_keyboard(entry)
		_eval("window.__mendigoVK.remove(%d);" % int(entry.get("id", 0)))
		entries.remove_at(i)

# --- what may be on screen --------------------------------------------------

# An HTML element sits on top of the canvas, so nothing drawn inside the game
# can cover it. Anything the game puts over the whole screen has to say so.
var blocked: bool = false
# While something is exclusive - a dialog, a settings panel - only the fields
# inside it may show. Without this the screen underneath keeps its boxes and
# the player gets two stacked on top of each other.
var exclusive: Array = []

func set_blocked(on: bool) -> void:
	blocked = on

func push_exclusive(node: Node) -> void:
	if node == null or exclusive.has(node):
		return
	exclusive.append(node)

func pop_exclusive(node: Node) -> void:
	exclusive.erase(node)

func top_exclusive() -> Node:
	# Anything freed or hidden since it was pushed no longer counts, so a panel
	# that goes away without saying so cannot lock every field off the screen.
	for i in range(exclusive.size() - 1, -1, -1):
		var node = exclusive[i]
		if node == null or not is_instance_valid(node):
			exclusive.remove_at(i)
			continue
		if node is CanvasItem and not (node as CanvasItem).is_visible_in_tree():
			continue
		return node
	return null

func should_show(line_edit: LineEdit) -> bool:
	if line_edit == null or not is_instance_valid(line_edit):
		return false
	if blocked:
		return false
	if not line_edit.is_visible_in_tree():
		return false
	var top := top_exclusive()
	return top == null or _is_within(line_edit, top)

func _is_within(node: Node, ancestor: Node) -> bool:
	var walk: Node = node
	while walk != null:
		if walk == ancestor:
			return true
		walk = walk.get_parent()
	return false

func _process(_delta: float) -> void:
	if entries.is_empty():
		return
	var viewport_size := get_viewport().get_visible_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return

	for i in range(entries.size() - 1, -1, -1):
		var entry: Dictionary = entries[i]
		var line_edit = entry.get("line_edit", null)
		if line_edit == null or not is_instance_valid(line_edit):
			_eval("window.__mendigoVK.remove(%d);" % int(entry.get("id", 0)))
			entries.remove_at(i)
			continue

		var id := int(entry.get("id", 0))
		if not should_show(line_edit):
			if bool(entry.get("shown", false)):
				entry["shown"] = false
				_eval("window.__mendigoVK.hide(%d);" % id)
			continue

		var rect := screen_rect_of(line_edit)
		# Only talk to the page when something actually moved. This runs every
		# frame and each call crosses into JavaScript.
		if bool(entry.get("shown", false)) and (entry.get("rect", Rect2()) as Rect2).is_equal_approx(rect):
			continue

		# The page gets the last word on whether the box is really up: it can
		# refuse, most often because the canvas has no measurable size yet
		# while a scene is still settling. Taking success on trust left the
		# field hidden for good - one failed frame and nothing ever retried,
		# which is what made the room code box impossible to type into.
		var placed := _eval_int("window.__mendigoVK.place(%d, %f, %f, %f, %f, %f, %f);" % [
			id, rect.position.x, rect.position.y, rect.size.x, rect.size.y,
			viewport_size.x, viewport_size.y])
		if placed != 1:
			entry["shown"] = false
			continue
		entry["rect"] = rect
		entry["shown"] = true
		_claim_keyboard(entry, line_edit)

func _claim_keyboard(entry: Dictionary, line_edit: LineEdit) -> void:
	# Only now, with a real input box confirmed over the field, is it safe to
	# switch the engine's own keyboard off. Two of them over one tap would
	# fight; none of them is worse.
	if bool(entry.get("owns_keyboard", false)):
		return
	entry["owns_keyboard"] = true
	line_edit.virtual_keyboard_enabled = false

func _release_keyboard(entry: Dictionary) -> void:
	if not bool(entry.get("owns_keyboard", false)):
		return
	entry["owns_keyboard"] = false
	var line_edit = entry.get("line_edit", null)
	if line_edit != null and is_instance_valid(line_edit):
		line_edit.virtual_keyboard_enabled = true

func screen_rect_of(line_edit: LineEdit) -> Rect2:
	# In viewport pixels, including whatever canvas transform is above it, so
	# the maths still holds inside a CanvasLayer.
	var xf := line_edit.get_global_transform_with_canvas()
	return Rect2(xf.origin, line_edit.size * xf.get_scale())

# --- talking to the page ----------------------------------------------------

func _eval(code: String) -> void:
	if not _installed:
		return
	JavaScriptBridge.eval(code, true)

func _eval_int(code: String) -> int:
	if not _installed:
		return 0
	var answer = JavaScriptBridge.eval(code, true)
	return int(answer) if answer != null else 0

func _install() -> void:
	if _installed or not is_active():
		return

	# Held as members: a callback that gets collected stops being callable from
	# the page, and the field goes quiet again with no error anywhere.
	_input_cb = JavaScriptBridge.create_callback(_on_js_input)
	_submit_cb = JavaScriptBridge.create_callback(_on_js_submit)
	var window_object = JavaScriptBridge.get_interface("window")
	if window_object == null:
		return
	window_object.__mendigoVKInput = _input_cb
	window_object.__mendigoVKSubmit = _submit_cb

	JavaScriptBridge.eval(_BOOTSTRAP, true)
	_installed = true

func _entry_by_id(id: int) -> Dictionary:
	for entry_raw in entries:
		var entry: Dictionary = entry_raw
		if int(entry.get("id", -1)) == id:
			return entry
	return {}

func _on_js_input(args: Array) -> void:
	if args.size() < 2:
		return
	var entry := _entry_by_id(int(args[0]))
	if entry.is_empty():
		return
	var line_edit = entry.get("line_edit", null)
	if line_edit == null or not is_instance_valid(line_edit):
		return
	var value := str(args[1])
	if bool(entry.get("uppercase", false)):
		value = value.to_upper()
	if line_edit.text == value:
		return
	line_edit.text = value
	line_edit.caret_column = value.length()
	# LineEdit only emits this for typing it handled itself, and every screen
	# that reacts to a field is listening for it.
	line_edit.text_changed.emit(value)

func _on_js_submit(args: Array) -> void:
	if args.is_empty():
		return
	var entry := _entry_by_id(int(args[0]))
	if entry.is_empty():
		return
	var line_edit = entry.get("line_edit", null)
	if line_edit == null or not is_instance_valid(line_edit):
		return
	line_edit.text_submitted.emit(line_edit.text)

const _BOOTSTRAP := """
window.__mendigoVK = window.__mendigoVK || (function () {
	var fields = {};

	function canvasBox() {
		var c = document.getElementById('canvas') || document.querySelector('canvas');
		if (!c) { return null; }
		return c.getBoundingClientRect();
	}

	function make(id, placeholder, maxLength, centred, upper) {
		var el = document.createElement('input');
		el.type = 'text';
		el.setAttribute('autocomplete', 'off');
		el.setAttribute('autocorrect', 'off');
		el.setAttribute('autocapitalize', upper ? 'characters' : 'off');
		el.setAttribute('spellcheck', 'false');
		el.setAttribute('enterkeyhint', 'go');
		el.placeholder = placeholder || '';
		if (maxLength > 0) { el.maxLength = maxLength; }
		el.style.position = 'fixed';
		el.style.zIndex = '90';
		el.style.margin = '0';
		el.style.boxSizing = 'border-box';
		el.style.display = 'none';
		el.style.background = 'rgba(9,18,14,0.97)';
		el.style.color = '#eaf2ee';
		el.style.border = '2px solid #4bb37d';
		el.style.borderRadius = '10px';
		el.style.padding = '0 12px';
		el.style.outline = 'none';
		el.style.fontFamily = 'inherit';
		if (centred) { el.style.textAlign = 'center'; }
		if (upper) { el.style.textTransform = 'uppercase'; }
		el.addEventListener('input', function () {
			if (window.__mendigoVKInput) { window.__mendigoVKInput(id, el.value); }
		});
		el.addEventListener('keydown', function (e) {
			if (e.key === 'Enter') {
				e.preventDefault();
				el.blur();
				if (window.__mendigoVKSubmit) { window.__mendigoVKSubmit(id); }
			}
		});
		document.body.appendChild(el);
		return el;
	}

	return {
		create: function (id, placeholder, maxLength, centred, upper) {
			if (fields[id]) { return; }
			fields[id] = make(id, placeholder, maxLength, centred, upper);
		},
		sync: function (id, value) {
			var el = fields[id];
			if (el && el.value !== value) { el.value = value; }
		},
		place: function (id, x, y, w, h, viewW, viewH) {
			var el = fields[id];
			var box = canvasBox();
			// Answered rather than assumed: the caller retries on a 0, so a
			// canvas that has not been measured yet only costs a frame.
			if (!el || !box || !viewW || !viewH) { return 0; }
			if (!box.width || !box.height) { return 0; }
			var sx = box.width / viewW;
			var sy = box.height / viewH;
			el.style.left = (box.left + x * sx) + 'px';
			el.style.top = (box.top + y * sy) + 'px';
			el.style.width = (w * sx) + 'px';
			el.style.height = (h * sy) + 'px';
			// Never below 16px: iOS Safari zooms the whole page in when a
			// smaller field is focused, and the game never zooms back out.
			el.style.fontSize = Math.max(16, Math.round(h * sy * 0.42)) + 'px';
			el.style.display = 'block';
			return 1;
		},
		hide: function (id) {
			var el = fields[id];
			if (el) { el.style.display = 'none'; }
		},
		remove: function (id) {
			var el = fields[id];
			if (el) {
				if (el.parentNode) { el.parentNode.removeChild(el); }
				delete fields[id];
			}
		}
	};
})();
"""
