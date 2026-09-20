extends "res://tests/touch_hud.gd"
## Render-rate presentation of the tick-driven simulation, and the frame-rate
## limit option. Uses existing imported content; nothing is written.
const Display = preload("res://src/presentation/display_settings.gd")


func run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("Pass an existing imported content directory after --")
		quit(2)
		return
	var lib := Library.new()
	check(lib.open(args[0], args[0].get_file()), "Open supplied imported content without reimporting")
	if failures:
		quit(1)
		return
	check(physics_interpolation, "Project renders the physics simulation interpolated between ticks")
	check(is_zero_approx(float(ProjectSettings.get_setting("physics/common/physics_jitter_fix"))), "Jitter fix is off, as interpolation requires")
	await resize_view(Vector2i(1280, 720))
	var app := TestMain.new()
	root.add_child(app)
	app.setup_world()
	app.setup_ui()
	app.add_child(app.music)
	app.library = lib
	app.ready_content = true
	app.transient_preview = true
	app.settings.touch = false
	app.settings.music = false
	check(app.showcase.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, "Title showcase turns from render frames without tick blending")
	for scene in ["menu_scene", "hangar_scene", "destination_scene", "briefing_scene", "opening_scene"]:
		var node: Node3D = load("res://src/presentation/%s.gd" % scene).new()
		check(node.physics_interpolation_mode == Node.PHYSICS_INTERPOLATION_MODE_OFF, scene + " animates from render frames without tick blending")
		node.free()
	check_frame_rate_option(app)
	app.session = Session.new()
	app.session.configure(lib, true)
	app.launch()
	app.music.stop()
	await settle(app)
	await check_steady_turn(app)
	await check_camera_cuts(app)
	await check_marker_projection(app)
	app.music.stop()
	app.stop_flight()
	app.queue_free()
	for frame in 3:
		await process_frame
	print("FRAME PACING ", checks, " CHECKS; ", failures, " FAILURES")
	quit(1 if failures else 0)


func check_frame_rate_option(app) -> void:
	var window := root
	check(Display.frame_rate_value("auto") == "auto" and Display.frame_rate_value(60) == 60 and Display.frame_rate_value(60.0) == 60, "Frame-rate choices keep their stored forms")
	for junk in [61, -30, "fast", null, 1e400, NAN]:
		check(Display.frame_rate_value(junk) == "auto", "Unknown frame-rate value %s falls back to the panel" % str(junk))
	check(app.settings.frame_rate == "auto", "Panel refresh rate is the default limit")
	var panel := Display.panel_refresh_rate(window)
	Display.apply_frame_rate(window, "auto")
	check(Engine.max_fps == panel, "Automatic limit equals the panel refresh rate (%d)" % panel)
	Display.apply_frame_rate(window, 30)
	check(Engine.max_fps == 30, "A chosen limit applies directly")
	Display.apply_frame_rate(window, "unlimited")
	check(Engine.max_fps == 0, "Unlimited removes the cap")
	check(Display.frame_rate_caption(window, 144) == "144" and Display.frame_rate_caption(window, "unlimited") == "Unlimited" and Display.frame_rate_caption(window, "auto").begins_with("Auto"), "Captions name the chosen limit")
	app.show_options()
	app.options_panel.show_section("display")
	var options = app.options_panel
	check(options.entries.map(func(e): return e.action).has("frame_rate"), "Display options offer the frame-rate limit")
	var expected: Array = Display.FRAME_RATES
	for step in expected.size():
		options.handle_action("frame_rate")
		var wanted: Variant = expected[(step + 1) % expected.size()]
		check(app.settings.frame_rate == wanted, "Cycling the option selects %s" % str(wanted))
		check(Engine.max_fps == (wanted if wanted is int else (panel if wanted == "auto" else 0)), "Selecting %s applies its cap" % str(wanted))
	check(app.settings.frame_rate == "auto" and Engine.max_fps == panel, "A full cycle returns to the panel rate")
	app.change_option("frame_rate", "bogus")
	check(app.settings.frame_rate == "auto", "Rejected frame-rate values leave the setting alone")
	app.navigate_back()
	app.navigate_back()


func check_steady_turn(app) -> void:
	# Pointer steering is buffered to the physics tick: a hull turned between
	# ticks would leave the chase camera a tick behind and make the reticle
	# alternate between two places on consecutive frames, at any frame rate.
	var flight = app.flight
	var hud = app.hud
	flight.mouse_flight_enabled = true
	flight.web_mouse_input = true
	var event := InputEventMouseMotion.new()
	event.relative = Vector2(40, 0)
	event.screen_relative = event.relative
	var before: Basis = flight.ship.basis
	flight._unhandled_input(event)
	check(flight.mouse_motion != Vector2.ZERO and flight.ship.basis.is_equal_approx(before), "Pointer movement is buffered rather than turning the hull between ticks")
	flight.step(1.0 / 60)
	check(not flight.ship.basis.is_equal_approx(before) and flight.mouse_motion == Vector2.ZERO, "The next tick applies the buffered pointer angle")
	if DisplayServer.get_name() == "headless":
		return
	flight.set_physics_process(true)
	var samples := PackedFloat32Array()
	for frame in 40:
		flight._unhandled_input(event)
		await RenderingServer.frame_post_draw
		if frame >= 10:
			samples.append(hud.reticle.position.x)
	flight.set_physics_process(false)
	var lowest := samples[0]
	var highest := samples[0]
	for value in samples:
		lowest = minf(lowest, value)
		highest = maxf(highest, value)
	check(highest - lowest < 1.5, "Reticle holds one place through a steady pointer turn (spread %.2f px)" % (highest - lowest))
	flight.mouse_motion = Vector2.ZERO


func check_camera_cuts(app) -> void:
	var flight = app.flight
	var camera: Camera3D = flight.camera
	check(flight.camera_view == "chase", "Flight opens on the chase view")
	# Advance a couple of ticks with the ship turning so the camera has a history.
	for tick in 4:
		flight.ship.rotate_y(.05)
		flight.update_camera(1.0 / 60.0)
		await physics_frame
	var before := camera.global_transform
	flight.first_person = true
	flight.ship.visible = false
	flight.update_camera(1.0 / 60.0)
	check(flight.camera_view == "cockpit" and not camera.global_transform.is_equal_approx(before), "Switching to the cockpit moves the camera")
	check(camera.get_global_transform_interpolated().is_equal_approx(camera.global_transform), "A view cut is presented at once, not blended across a tick")
	flight.first_person = false
	flight.ship.visible = true
	flight.update_camera(1.0 / 60.0)
	check(flight.camera_view == "chase" and camera.get_global_transform_interpolated().is_equal_approx(camera.global_transform), "Returning to the chase view is a cut too")
	await physics_frame
	# A steady chase follow keeps blending: after a tick the interpolated pose
	# reflects both the previous and current placement rather than a reset.
	flight.ship.position += Vector3(0, 0, -30)
	flight.update_camera(1.0 / 60.0)
	check(flight.camera_view == "chase", "Ordinary following does not count as a cut")
	flight.begin_outro()
	check(flight.camera_view == "outro" and camera.get_global_transform_interpolated().is_equal_approx(camera.global_transform), "The mission outro places its camera without a sweep")


func check_marker_projection(app) -> void:
	var flight = app.flight
	var hud = app.hud
	flight.outro_active = false
	flight.camera_view = ""
	flight.update_camera(1.0 / 60.0)
	var radar: Dictionary = app.library.content.flight_ui.radar
	var pose: Transform3D = flight.ship.get_global_transform_interpolated()
	var aim: Vector3 = pose.origin - pose.basis.z * radar.aim_distance
	hud._process(0)
	var expected: Vector2 = flight.camera.unproject_position(aim) - hud.reticle.size * .5
	check(hud.reticle.position.is_equal_approx(expected), "Reticle is projected from the ship's rendered pose")
	# Between ticks the rendered pose differs from the tick pose whenever the
	# ship moved; the marker must follow the rendered one.
	flight.ship.position += Vector3(0, 0, -20)
	flight.update_camera(1.0 / 60.0)
	hud._process(0)
	var tick_aim: Vector3 = flight.ship.position - flight.ship.basis.z * radar.aim_distance
	var shown_pose: Transform3D = flight.ship.get_global_transform_interpolated()
	var shown_aim: Vector3 = shown_pose.origin - shown_pose.basis.z * radar.aim_distance
	check(hud.reticle.position.is_equal_approx(flight.camera.unproject_position(shown_aim) - hud.reticle.size * .5), "Reticle tracks the interpolated aim point after a move")
	if not shown_aim.is_equal_approx(tick_aim):
		check(not hud.reticle.position.is_equal_approx(flight.camera.unproject_position(tick_aim) - hud.reticle.size * .5) or flight.camera.unproject_position(tick_aim).is_equal_approx(flight.camera.unproject_position(shown_aim)), "Reticle does not sit on the stale tick pose")
