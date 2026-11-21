extends Node2D
## Original BetterServer.exe atlas and recovered SDL source/destination rectangles.
const ATLAS = preload("res://assets/ui/betterserver_atlas.png")
const NAV_POS := [Vector2(59, 249), Vector2(150, 249), Vector2(268, 249), Vector2(386, 249)]
const NAV_WIDTH := [32, 54, 53, 29]
const TITLE_SRC := [
	Rect2(1829, 0, 64, 16), Rect2(1925, 0, 103, 16), Rect2(2032, 0, 112, 16), Rect2(2172, 0, 55, 16)
]
const TITLE_POS := [Vector2(199, 10), Vector2(184, 10), Vector2(179, 10), Vector2(208, 10)]
const MapProfiles = preload("res://src/data/map_profiles.gd")
const MAP_SET_NAMES = MapProfiles.NAMES
const MAP_SETS = MapProfiles.MAPS
const PING_LIMITS := [80, 120, 180, 250, 65535]
const PING_NAMES := ["VERY STRICT", "STRICT", "FORGIVING", "DEFAULT", "UNLIMITED"]
var screen := 0
var scroll_t := 0.0
var map_scroll := 0.0
var log_scroll := 0
var click_pending := false
var click_position := Vector2.ZERO
var press_pulse := false


func _ready() -> void:
	scale = Vector2(2, 2)  # SDL original renders logical coordinates directly at 960x540.


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			click_pending = true
			click_position = get_global_transform_with_canvas().affine_inverse() * event.position
			press_pulse = true
		if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var step := 1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1
			if screen == 1 and _pointer().x < 288:
				map_scroll = clampf(map_scroll + step * 31, 0, 124)
			elif screen == 0:
				log_scroll = maxi(0, log_scroll - step * 3)


func _physics_process(delta: float) -> void:
	scroll_t += delta
	if click_pending:
		click_pending = false
		_click(click_position)
	queue_redraw()


func _pointer() -> Vector2:
	return get_local_mouse_position()


func _mouse_down() -> bool:
	return (
		Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	)


func _press_offset(rect: Rect2) -> Vector2:
	return Vector2(0, 1) if _hover(rect) and _mouse_down() else Vector2.ZERO


func _hover(rect: Rect2) -> bool:
	return rect.has_point(_pointer())


func _sprite(src: Rect2, at: Vector2, size := Vector2.ZERO, color := Color.WHITE) -> void:
	draw_texture_rect_region(
		ATLAS, Rect2(at, src.size if size == Vector2.ZERO else size), src, color
	)


func _text(
	value: String, at: Vector2, color := Color.WHITE, scale := 1.0, max_width := INF
) -> float:
	var x: float = at.x
	var y: float = at.y
	for ch in value.to_lower():
		if ch == "\n":
			x = at.x
			y += 8 * scale
			continue
		if ch == " ":
			x += 5 * scale
			continue
		if x + 8 * scale > at.x + max_width:
			break
		var idx: int = GM._letter_index(ch)
		_sprite(Rect2(480 + idx * 8, 432, 8, 6), Vector2(x, y), Vector2(8, 6) * scale, color)
		x += (8 if ch in GM._WIDE_CHARS else 6) * scale
	return x


func _button(src_x: int, at: Vector2, height := 20, green := false) -> void:
	var rect := Rect2(at, Vector2(128, height))
	var over := _hover(rect)
	# Native draw callbacks 0x1400270e8/0x14002721c: hover takes
	# precedence over the enabled sprite; held buttons move two screen pixels.
	var offset := 128 if over else (256 if green else 0)
	if src_x in [4016, 4272]:
		_sprite(Rect2(src_x + offset, 0, 128, height), at)
		if over:
			# Selector callbacks draw a separate arrow layer, nudged on the press edge.
			_sprite(Rect2(1680, 0, 116, 32), at + (Vector2(0, 1) if press_pulse else Vector2.ZERO))
	else:
		_sprite(Rect2(src_x + offset, 0, 128, height), at + _press_offset(rect))


func _click(point: Vector2) -> void:
	var srv = get_parent()
	for i in 4:
		if Rect2(NAV_POS[i], Vector2(NAV_WIDTH[i], 8)).grow(2).has_point(point):
			screen = i
			return
	if screen == 0:
		for i in 4:
			if Rect2(320, 106 + i * 30, 128, 20).has_point(point):
				match i:
					0:
						srv.ui_force_back_to_lobby()
					1:
						srv.practice_mode()
					2:
						srv.ui_force_exe_win()
					3:
						srv.ui_force_escape()
				return
	if screen == 1:
		var maps: Array = (
			srv
			. config
			. get("maps", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19])
			. duplicate()
		)
		var clip := Rect2(0, 38, 286, 195)
		for i in [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]:
			if clip.has_point(point) and _map_rect(i).has_point(point):
				if maps.has(i):
					maps.erase(i)
				else:
					maps.append(i)
				srv.config.maps = maps
				srv.config.map_set = -1
				_save_options("MAP %d %s." % [i, "ENABLED" if maps.has(i) else "DISABLED"])
				return
		var direction := -1 if point.x < 384 else 1
		var message := ""
		if Rect2(320, 48, 128, 40).has_point(point):
			var preset: int = srv.config.get(
				"map_set",
				(
					0
					if (
						maps
						== [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
					)
					else -1
				)
			)
			preset = posmod(preset + direction, MAP_SETS.size())
			srv.config.map_set = preset
			srv.config.maps = MAP_SETS[preset].duplicate()
			message = "MAP SET: %s." % MAP_SET_NAMES[preset]
		elif Rect2(320, 96, 128, 20).has_point(point):
			srv.config.maps = []
			srv.config.map_set = -1
			message = "ALL MAPS DISABLED."
		elif Rect2(320, 125, 128, 40).has_point(point):
			var index := PING_LIMITS.find(int(srv.config.get("ping_limit", 65535)))
			index = posmod(index + direction, PING_LIMITS.size())
			srv.config.ping_limit = PING_LIMITS[index]
			message = "PING LIMIT: %s." % ("UNLIMITED" if index == 4 else str(PING_LIMITS[index]))
		elif Rect2(320, 172, 128, 20).has_point(point):
			srv.config.anticheat = not srv.config.get("anticheat", false)
			message = (
				"CLIENT MODIFICATIONS %s." % ("DISALLOWED" if srv.config.anticheat else "ALLOWED")
			)
		elif Rect2(320, 200, 128, 20).has_point(point):
			srv.config.camp_tease = not srv.config.get("camp_tease", true)
			message = "CAMP TEASE %s." % ("ENABLED" if srv.config.camp_tease else "DISABLED")
		else:
			return
		_save_options(message)


func _save_options(message: String) -> void:
	var srv = get_parent()
	srv.save_all()
	srv._maybe_start_vote()
	srv.log_line("UI", message)


func _map_rect(index: int) -> Rect2:
	# Native MapList callback: x=8+143*column, y=90+124*row, size=123x104.
	return Rect2(4 + (index % 4) * 71.5, 45 + (index / 4) * 62 - map_scroll, 61.5, 52)


func _draw() -> void:
	# room_menu.yy: 10 FPS, hspeed=-0.2 at 60 ticks/s. Keep the
	# phase fractional, but draw on native pixels (half a logical pixel).
	var frame := int(scroll_t * 10) % 28
	var offset_x := -floorf(fposmod(scroll_t * 12.0, 48.0) * 2.0) / 2.0
	for x in 11:
		for y in 6:
			_sprite(
				Rect2(480 + frame * 96, 446, 96, 96),
				Vector2(x * 48 + offset_x, y * 48),
				Vector2(48, 48)
			)
	draw_rect(Rect2(0, 0, 480, 36), Color.BLACK)
	draw_rect(Rect2(0, 236, 480, 34), Color.BLACK)
	_sprite(Rect2(0, 272, 480, 270), Vector2.ZERO)
	_sprite(TITLE_SRC[screen], TITLE_POS[screen])
	match screen:
		0:
			_main()
		1:
			_options()
		2:
			_players()
		3:
			_info()
	for i in 4:
		var rect := Rect2(NAV_POS[i], Vector2(NAV_WIDTH[i], 8))
		var over := _hover(rect)
		_sprite(
			Rect2(480 + (NAV_WIDTH[i] if over else 0), 400 + i * 8, NAV_WIDTH[i], 8),
			NAV_POS[i] + _press_offset(rect)
		)
	press_pulse = false


func _main() -> void:
	_sprite(Rect2(128, 0, 272, 176), Vector2(16, 48), Vector2(276, 176))
	var logs: Array = get_parent().logs
	var start := maxi(0, logs.size() - 40 - mini(log_scroll, maxi(0, logs.size() - 40)))
	for i in mini(40, logs.size() - start):
		var line: Dictionary = logs[start + i]
		# Clip to the original log panel, including long usernames/messages.
		_text(str(line.text).left(87), Vector2(24, 56 + i * 4), line.col, 0.5, 260)
	for i in 4:
		_button(400 + i * 256, Vector2(320, 106 + i * 30))


func _options() -> void:
	var srv = get_parent()
	var maps: Array = srv.config.get(
		"maps", [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19]
	)
	_sprite(Rect2(2540, 38, 4, 195), Vector2(284, 38))
	var clip := Rect2(0, 38, 286, 195)
	for i in 20:
		var dest := _map_rect(i)
		if _hover(dest) and clip.has_point(_pointer()) and not _mouse_down():
			dest.position.y -= 1
		var area := dest.intersection(clip)
		if not area.has_area():
			continue
		var src := Rect2(480 + i * 123, 272, 123, 104)
		src.position += (area.position - dest.position) * Vector2(2, 2)
		src.size = area.size * Vector2(2, 2)
		var color := Color.WHITE if maps.has(i) else Color(96.0 / 255, 96.0 / 255, 96.0 / 255)
		_sprite(src, area.position, area.size, color)
	_button(4016, Vector2(320, 48), 40)
	var preset: int = srv.config.get(
		"map_set",
		0 if maps == [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19] else -1
	)
	_text(
		(
			MAP_SET_NAMES[preset]
			if preset >= 0 and preset < MAP_SET_NAMES.size()
			else ("CUSTOM" if not maps.is_empty() else "NONE")
		),
		Vector2(328, 73)
	)
	_button(3540, Vector2(320, 96))
	_button(4272, Vector2(320, 125), 40)
	var limit: int = srv.config.get("ping_limit", 65535)
	var ping_index := PING_LIMITS.find(limit)
	var value_x := _text(
		PING_NAMES[ping_index] if ping_index >= 0 else "CUSTOM", Vector2(328, 150), Color.GREEN
	)
	_text(" - " + ("OFF" if limit == 65535 else str(limit)), Vector2(value_x, 150))
	_button(3120, Vector2(320, 172), 20, not srv.config.get("anticheat", false))
	_button(2736, Vector2(320, 200), 20, srv.config.get("camp_tease", true))


func _players() -> void:
	var srv = get_parent()
	var xs := [16, 168, 320]
	for i in 3:
		_sprite(Rect2(4528, 0, 144, 176), Vector2(xs[i], 48))
		var width: int = [80, 96, 64][i]
		_sprite(
			Rect2(4752 if i == 2 else 4672, 8 if i == 1 else 0, width, 8),
			Vector2(xs[i] + (144 - width) / 2, 52)
		)
	var row := 0
	for player in srv.players.values():
		_text(str(player.nickname).left(20), Vector2(24, 67 + row * 8), Color.WHITE, 0.75)
		row += 1
	row = 0
	for id in srv.operators:
		_text(str(id).left(20), Vector2(176, 67 + row * 8), Color.WHITE, 0.75)
		row += 1
	row = 0
	for id in srv.bans:
		_text(str(id).left(20), Vector2(328, 67 + row * 8), Color.WHITE, 0.75)
		row += 1


func _info() -> void:
	var srv = get_parent()
	_text("DISASTERSERVERUI", Vector2(4, 42), Color(0.7, 0.15, 1))
	_text("GODOT PORT", Vector2(125, 42), Color(0.2, 0.4, 1))
	_text("(C) 2024 TEAM EXE EMPIRE", Vector2(4, 50))
	_text("GAME VERSION:", Vector2(4, 74))
	_text("V" + str(srv.BUILD_VER), Vector2(90, 74), Color(0.7, 0.15, 1))
	_text("ENGINE:", Vector2(4, 82))
	_text("GODOT " + Engine.get_version_info().string, Vector2(58, 82), Color(0.7, 0.15, 1))
	_text("PORT: " + str(srv.config.get("port", 8606)), Vector2(4, 90))
	_text("PLAYERS: " + str(srv.players.size()), Vector2(4, 98))
