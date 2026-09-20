extends Control
## Native radio panel drawing supplied portraits and bitmap glyphs.
const DialogueFrame = preload("res://src/presentation/panel.gd")
signal dismissed
var library
var cue := {}
var lines := PackedStringArray()
var portrait: Texture2D
var panel_rect := Rect2()
## The supplied radio plays its cue on a message's first draw, then that
## message's speech; leaving the message stops the speech. Speech IDs the bank
## never registered stay silent, exactly as in the supplied build.
var chime := preload("res://src/presentation/audio_settings.gd").effect_player()
var voice := preload("res://src/presentation/audio_settings.gd").effect_player()


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	resized.connect(queue_redraw)
	add_child(chime)
	add_child(voice)


func present(value: Dictionary) -> void:
	if value == cue:
		return
	cue = value.duplicate()
	visible = not cue.is_empty()
	voice.stop()
	voice.stream = null
	if visible:
		portrait = library.radio_portrait(int(cue.speaker))
		lines = preload("res://src/presentation/bitmap_font.gd").wrap_lines(library,
			library.text(int(cue.text)), library.content.radio_ui.text_width - portrait.get_width())
		play_clip(chime, int(library.content.radio_ui.audio.cue))
		play_clip(voice, library.radio_voice(cue))
	queue_redraw()


func play_clip(player: AudioStreamPlayer, id: int) -> void:
	player.stop()
	player.stream = library.sound_clip(id)
	if player.stream == null:
		return
	player.volume_linear = float(library.content.sound_bank[str(id)].gain)
	if DisplayServer.get_name() != "headless":
		player.play()


func _draw() -> void:
	if cue.is_empty() or portrait == null:
		return
	# Original 480-wide composition, centered and scaled with the viewport.
	var factor := preload("res://src/presentation/bitmap_font.gd").composition_scale(size)
	var origin := Vector2((size.x - 480 * factor) / 2, 0)
	var glyphs: Dictionary = library.radio_glyphs()
	var line_height: float = glyphs.values()[0].size.y
	var layout: Dictionary = library.content.radio_ui.layout
	var point := Vector2(layout.origin[0], layout.origin[1])
	var portrait_point := Vector2(layout.portrait[0], layout.portrait[1])
	var text_point := Vector2(layout.text[0] + portrait.get_width(), layout.text[1])
	# Extend the source portrait-height panel only when localized text needs room.
	var height := maxf(
		portrait.get_height() + layout.height_padding,
		lines.size() * line_height + 2 * (text_point.y - point.y)
	)
	panel_rect = Rect2(origin + point * factor, Vector2(layout.width, height) * factor)
	draw_set_transform(origin, 0, Vector2.ONE * factor)
	DialogueFrame.draw(self, library, Rect2(point, Vector2(layout.width, height)))
	draw_texture(portrait, portrait_point)
	for index in lines.size():
		preload("res://src/presentation/bitmap_font.gd").draw_text(
			self, library, lines[index], text_point + Vector2(0, index * line_height))
	draw_set_transform(Vector2.ZERO)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		voice.stream_paused = true
		chime.stop()
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		voice.stream_paused = false


func _input(event: InputEvent) -> void:
	if not visible or cue.is_empty():
		return
	var keyboard: bool = (
		event is InputEventKey
		and event.pressed
		and not event.echo
		and event.physical_keycode == KEY_ENTER
	)
	var touch: bool = (
		event is InputEventScreenTouch and event.pressed and panel_rect.has_point(event.position)
	)
	if keyboard or touch:
		dismissed.emit()
		get_viewport().set_input_as_handled()
