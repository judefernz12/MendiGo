extends SceneTree

# The rotate prompt, and the conditions that decide when it appears.
#
# Getting these wrong is worse than not having the prompt: showing it to a
# desktop player who narrowed their window, or to a native Android build that
# is already pinned landscape, would be a permanent black screen over a game
# that was working fine.

const OrientationScript = preload("res://scripts/ui/Orientation.gd")

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
	var live := root.get_node_or_null("Orientation")
	ok(live != null, "the Orientation autoload is registered")

	aspect_check()
	platform_check(live)
	overlay_check()

	_report()

# --- which sizes count as portrait -----------------------------------------

func aspect_check() -> void:
	var probe: Node = OrientationScript.new()

	# Phones, upright. Every one of these cuts the table off at the sides,
	# because the camera keeps vertical FOV and the stretch aspect is "expand".
	for size in [Vector2(390, 844), Vector2(360, 800), Vector2(414, 896), Vector2(768, 1024)]:
		ok(probe.is_portrait(size), "%dx%d is portrait" % [size.x, size.y])

	# The same phones, turned.
	for size in [Vector2(844, 390), Vector2(800, 360), Vector2(896, 414), Vector2(1024, 768)]:
		ok(not probe.is_portrait(size), "%dx%d is landscape" % [size.x, size.y])

	# The shipping resolution and a typical laptop.
	ok(not probe.is_portrait(Vector2(1280, 720)), "the game's own 1280x720 is landscape")
	ok(not probe.is_portrait(Vector2(1440, 900)), "a laptop window is landscape")

	# Exactly square is not portrait: nothing is cut off, and the headless
	# viewport this suite runs in is square, so a wrong answer here would show
	# the prompt during every other test.
	ok(not probe.is_portrait(Vector2(1000, 1000)), "a square viewport is not portrait")

	# Degenerate sizes must not be treated as portrait - a viewport reports
	# zero for a frame or two while a scene is being swapped.
	ok(not probe.is_portrait(Vector2(0, 0)), "a zero size is not portrait")
	ok(not probe.is_portrait(Vector2(0, 800)), "a zero width is not portrait")
	ok(not probe.is_portrait(Vector2(800, 0)), "a zero height is not portrait")

	probe.free()

# --- where the prompt is allowed to appear ----------------------------------

func platform_check(live: Node) -> void:
	var probe: Node = OrientationScript.new()

	# This suite runs on desktop, not in a browser. Whatever the viewport is
	# doing, the prompt must stay out of it.
	ok(not probe._is_touch_browser(), "a desktop run is never asked to rotate")
	ok(not OS.has_feature("web"), "this check really is running outside a browser")

	if live != null:
		ok(not live.watching, "the live autoload is dormant on desktop")
		ok(live.overlay == null, "and does not even build the overlay here")

	# The rule itself: a browser is required. A native Android build is pinned
	# landscape by window/handheld/orientation, so the prompt would be both
	# wrong and impossible to dismiss there.
	ok(int(ProjectSettings.get_setting("display/window/handheld/orientation", 0)) == 4,
		"native handheld builds are pinned to sensor landscape")

	probe.free()

# --- the overlay itself -----------------------------------------------------

func overlay_check() -> void:
	var probe: Node = OrientationScript.new()
	root.add_child(probe)
	# Force the branch a phone browser would take, so the overlay is built and
	# can be inspected on a desktop test run.
	probe.watching = true
	probe._build_overlay()

	ok(probe.layer != null and probe.layer.layer >= 100, "the prompt sits above every other layer")
	ok(probe.overlay != null, "the overlay exists")
	ok(not probe.overlay.visible, "and starts hidden")
	ok(probe.overlay.mouse_filter == Control.MOUSE_FILTER_STOP, "it swallows input so nothing can be tapped behind it")

	# It must cover the whole screen, whatever the screen is: a gap would let
	# the player see and tap a game they cannot read.
	ok(probe.overlay.anchor_left == 0.0 and probe.overlay.anchor_top == 0.0
		and probe.overlay.anchor_right == 1.0 and probe.overlay.anchor_bottom == 1.0,
		"it covers the whole screen at any size")

	var wording := str(probe.hint.text).to_lower()
	ok(wording.contains("rotation lock"),
		"the prompt mentions rotation lock, or a player who has it on is stuck with no explanation")
	ok(str(probe.message.text).strip_edges() != "", "the prompt actually says something")

	# The lock is only ever attempted once, and only from a real tap.
	ok(not probe.lock_attempted, "no lock is attempted before the player touches anything")
	var press := InputEventScreenTouch.new()
	press.pressed = true
	probe._input(press)
	ok(probe.lock_attempted, "the first tap is what triggers the attempt")
	var again := InputEventScreenTouch.new()
	again.pressed = true
	probe._input(again)
	ok(probe.lock_attempted, "and it is not retried on every later tap")

	# A finger lift is not a gesture to hang a fullscreen request on.
	var lifted: Node = OrientationScript.new()
	root.add_child(lifted)
	lifted.watching = true
	var lift := InputEventScreenTouch.new()
	lift.pressed = false
	lifted._input(lift)
	ok(not lifted.lock_attempted, "lifting a finger does not trigger it")
	lifted.queue_free()

	probe.queue_free()

# A floor on how much this suite has to have done before it may call itself
# green. Adding a reference to another autoload inside Orientation.gd once made
# the script fail to compile here, so the probe was never built, almost every
# check was skipped - and the suite still printed OK, having run one check out
# of thirty-one. Silence is the failure mode worth guarding against.
const MIN_CHECKS := 30

func _report() -> void:
	print("")
	print("CHECKS RUN: ", checks)
	if checks < MIN_CHECKS:
		print("FAILURES: 1")
		print(" - only %d checks ran, expected at least %d - the suite did not finish" % [checks, MIN_CHECKS])
		quit(1)
		return
	if fails.is_empty():
		print("ALL_ORIENTATION_OK")
		quit(0)
	else:
		print("FAILURES: ", fails.size())
		for f in fails:
			print(" - ", f)
		quit(1)
