extends Node2D
## UI layer replicating BetterServer: grid background, red bars, /MAIN title,
## log panel, side buttons, bottom nav MAIN|OPTIONS|PLAYERS|INFO.

const COL_WHITE := Color(0.92, 0.92, 0.92)
const COL_RED := Color(0.95, 0.15, 0.15)
const COL_GRAY := Color(0.55, 0.55, 0.55)
const COL_SELECTED := Color(0.95, 0.15, 0.15)
const COL_GREEN := Color(0.0, 1.0, 0.35)
const COL_YELLOW := Color(1.0, 0.9, 0.3)

var screen := 0  # 0=MAIN 1=OPTIONS 2=PLAYERS 3=INFO
var scroll_t := 0.0
var click_pending := false

var nav_names := ["MAIN", "OPTIONS", "PLAYERS", "INFO"]
var nav_x := [77, 177, 295, 397]

var side_buttons := ["BACK TO LOBBY", "PRACTICE MODE", "FORCE EXE WIN", "FORCE ESCAPE"]
var side_y := [142, 175, 208, 241]

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		click_pending = true

func _physics_process(delta: float) -> void:
	scroll_t += delta
	_click_check()
	queue_redraw()

func _click_check() -> void:
	if not click_pending:
		return
	click_pending = false
	# stretch/resolution-aware canvas coordinates (client-proven approach)
	var mp := get_global_mouse_position()
	var mx: float = mp.x
	var my: float = mp.y
	# bottom nav first (always available so you can leave any screen)
	for i in nav_names.size():
		var w := GM.text_width(nav_names[i], 2.0)
		if _gm_button_hit(mx, my, nav_x[i] - w / 2 - 4, 250, w + 8, 20):
			screen = i
			return
	# side buttons (MAIN screen)
	if screen == 0:
		for i in side_buttons.size():
			if _gm_button_hit(mx, my, 325, side_y[i] - 9, 125, 18):
				_side_pressed(i)
				return
	# options toggles
	if screen == 1:
		var srv := get_parent()
		var rows: Array = _option_rows()
		for i in rows.size():
			if _gm_button_hit(mx, my, 20, 40 + i * 18, 440, 14):
				srv.toggle_option(rows[i][0])
				return

func _gm_button_hit(mx: float, my: float, x: float, y: float, w: float, h: float) -> bool:
	return mx >= x and mx <= x + w and my >= y and my <= y + h

func _side_pressed(i: int) -> void:
	var srv := get_parent()
	match i:
		0: srv.ui_force_back_to_lobby()
		1: srv.practice_mode()
		2: srv.ui_force_exe_win()
		3: srv.ui_force_escape()

func _option_rows() -> Array:
	return [
		["port", "PORT"],
		["server_count", "SERVER COUNT"],
		["ping_limit", "PING LIMIT"],
		["log_file", "LOG FILE"],
		["log_debug", "LOG DEBUG"],
		["anticheat", "ANTICHEAT"],
		["pride", "PRIDE"],
		["motd", "MOTD"],
	]

func _draw() -> void:
	# tiled animated grid background
	var tex := GM.sprite_texture("background_test", int(Time.get_ticks_msec() / 100))
	if tex:
		var off := fmod(-scroll_t * 0.2 * 96.0, 96.0)
		var x := off
		while x < 480:
			var y := 0.0
			while y < 270:
				draw_texture(tex, Vector2(x, y), Color(0.35, 0.35, 0.35))
				y += 96
			x += 96
	# red bars
	draw_rect(Rect2(0, 45, 480, 2), Color(0.6, 0.02, 0.02))
	draw_rect(Rect2(0, 252, 480, 2), Color(0.6, 0.02, 0.02))
	draw_rect(Rect2(0, 46, 480, 1), Color(0.25, 0.0, 0.0))
	# title
	var title := "/MAIN"
	match screen:
		1: title = "/OPTIONS"
		2: title = "/PLAYERS"
		3: title = "/INFO"
	var tw := GM.text_width(title, 3.0)
	GM.draw_text(self, 240 - tw / 2, 8, title, COL_WHITE, 3.0)

	match screen:
		0: _draw_main()
		1: _draw_options()
		2: _draw_players()
		3: _draw_info()

	# bottom nav
	for i in nav_names.size():
		var w := GM.text_width(nav_names[i], 2.0)
		var col := COL_SELECTED if screen == i else COL_WHITE
		GM.draw_text(self, nav_x[i] - w / 2, 260, nav_names[i], col, 2.0)

func _draw_main() -> void:
	# log panel
	var panel := Rect2(22, 62, 273, 172)
	draw_rect(panel.grow(2), Color(0.85, 0.85, 0.85))
	draw_rect(panel, Color(0.02, 0.02, 0.02))
	var srv := get_parent()
	var y := 66.0
	for l in srv.logs:
		GM.draw_text(self, 26, y, l.text, l.col)
		y += 8
	GM.draw_text(self, 26, 238, "chat works in game. join via the game's JOIN GAME.", COL_GRAY)
	# side buttons
	for i in side_buttons.size():
		var bw := GM.text_width(side_buttons[i], 2.0)
		var bx := 325.0
		var by: float = side_y[i] - 9
		draw_rect(Rect2(bx, by, 125, 18), Color(0.05, 0.02, 0.02))
		draw_rect(Rect2(bx, by, 125, 18), COL_RED, false, 1.0)
		draw_rect(Rect2(bx + 1, by + 1, 123, 16), Color(0.10, 0.02, 0.02))
		GM.draw_text(self, bx + (125 - bw) / 2, by + 5, side_buttons[i], COL_RED, 2.0)

func _draw_options() -> void:
	var srv := get_parent()
	var rows: Array = _option_rows()
	GM.draw_text(self, 60, 30, "setting", COL_GRAY)
	GM.draw_text(self, 300, 30, "value", COL_GRAY)
	for i in rows.size():
		var key: String = rows[i][0]
		var label: String = rows[i][1]
		var val = srv.config.get(key, "")
		GM.draw_text(self, 30, 44 + i * 18, label, COL_WHITE)
		GM.draw_text(self, 300, 44 + i * 18, str(val), COL_GREEN)
	GM.draw_text(self, 30, 44 + rows.size() * 18 + 8, "click a bool row to toggle it", COL_GRAY)
	GM.draw_text(self, 30, 44 + rows.size() * 18 + 20, "edits save to config.json", COL_GRAY)

func _draw_players() -> void:
	var srv := get_parent()
	if srv.players.is_empty():
		GM.draw_text(self, 30, 70, "no players connected.", COL_GRAY)
		return
	GM.draw_text(self, 30, 40, "nid", COL_GRAY)
	GM.draw_text(self, 80, 40, "nickname", COL_GRAY)
	GM.draw_text(self, 220, 40, "state", COL_GRAY)
	GM.draw_text(self, 330, 40, "ping", COL_GRAY)
	var i := 0
	for nid: int in srv.players:
		var p: Dictionary = srv.players[nid]
		var st := "WAITING"
		match srv.server_state:
			0: st = "WAITING"
			1: st = "LOBBY" + (" [READY]" if p.ready else "")
			2: st = "VOTE"
			3: st = "CHARSELECT" + (" (EXE)" if nid == srv.exe_nid else "")
			4: st = "GAME"
		GM.draw_text(self, 30, 58 + i * 14, str(nid), COL_WHITE)
		GM.draw_text(self, 80, 58 + i * 14, p.nickname, COL_WHITE)
		GM.draw_text(self, 220, 58 + i * 14, st, COL_GREEN if p.ready else COL_WHITE)
		GM.draw_text(self, 330, 58 + i * 14, str(p.ping), COL_WHITE)
		i += 1

func _draw_info() -> void:
	var srv := get_parent()
	var lines := [
		["DISASTER V%d (GODOT REPLICA)" % srv.BUILD_VER, COL_GREEN],
		["BUILD FROM MOD ... BDY-01/31/25.", COL_RED],
		["(C) 2021 TEAM EXE EMPIRE", COL_WHITE],
		["PORT: %d" % int(srv.config.get("port", 8606)), COL_WHITE],
		["PLAYERS: %d" % srv.players.size(), COL_WHITE],
		["UPTIME: %d SEC" % int(srv.uptime), COL_WHITE],
		["STATE: %s" % ["WAITING", "LOBBY", "VOTE", "CHARSELECT", "GAME"][srv.server_state], COL_YELLOW],
	]
	var y := 70.0
	for l in lines:
		GM.draw_text(self, 60, y, l[0], l[1], 1.5)
		y += 18
