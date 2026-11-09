extends Node2D
## DisasterServer — standalone server replicating BetterServer v1101:
## visuals (grid bg, log panel, buttons), Config.json settings and the
## server-authoritative lobby flow of the original.

const BUILD_VER := 1101
const MAX_PLAYERS := 10

enum S { WAITING, LOBBY, VOTE, CHARSELECT, GAMESTART }

# ---------------------------------------------------------------- config
var config := {}
var operators := {}
var bans := []

# ---------------------------------------------------------------- runtime
var _host: ENetConnection = null
var players: Dictionary = {}      # nid -> player dict
var next_nid := 1
var server_state: int = S.WAITING
var uptime := 0.0
var heartbeat_t := 0.0

var lobby_votes: Dictionary = {}  # nid -> map
var vote_map := [0, 0, 0]
var vote_timer := 20.0
var char_timer := 30.0
var countdown := -1
var _last_cd := -1   # last countdown second broadcast (throttles the tick packet)
var exe_nid := -1
var chosen_map := 6

var logs: Array = []              # {text, color}

const COL_WHITE := Color(0.92, 0.92, 0.92)
const COL_GREEN := Color(0.0, 1.0, 0.35)
const COL_RED := Color(1.0, 0.35, 0.45)
const COL_YELLOW := Color(1.0, 0.9, 0.3)
const COL_PURPLE := Color(0.8, 0.5, 1.0)
const COL_GRAY := Color(0.55, 0.55, 0.55)

func _ready() -> void:
	_load_files()
	var port: int = int(config.get("port", 8606))
	_host = ENetConnection.new()
	var err := _host.create_host_bound("0.0.0.0", port, MAX_PLAYERS, 2)
	if err != OK:
		log_line("(LIB.C:96)", "FAILED TO CREATE HOST. ERROR %d" % err, COL_RED)
		_host = null
		return
	log_line("(LIB.C:55)", "DISASTER V%d" % BUILD_VER, COL_GREEN)
	log_line("(LIB.C:55)", "BUILD FROM MOD ... BDY-01/31/25.", COL_RED)
	log_line("(LIB.C:78)", "(C) 2021 TEAM EXE EMPIRE", COL_WHITE)
	log_line("(LIB.C:78)", "-------------", COL_WHITE)
	log_line("(LIB.C:178)", "TIMEOUTS.JSON LOADED...", COL_WHITE)
	log_line("(CONFIG.C:413)", "BANS.JSON LOADED.", COL_WHITE)
	log_line("(CONFIG.C:107)", "OPERATORS.JSON LOADED.", COL_WHITE)
	if config.get("anticheat", false):
		log_line("(CONFIG.C:173)", "ANTICHEAT IS ENABLED.", COL_YELLOW)
	else:
		log_line("(CONFIG.C:173)", "ANTICHEAT IS DISABLED. CLIENT MODIFICATIONS ARE ALLOWED.", COL_YELLOW)
	if str(config.get("motd", "")) == "":
		log_line("(CONFIG.C:212)", "MOTD IS DISABLED.", COL_WHITE)
	else:
		log_line("(CONFIG.C:212)", "MOTD IS ENABLED.", COL_YELLOW)
	log_line("(LIB.C:50)", "LISTENING ON PORT %d..." % port, COL_WHITE)
	log_line("(LOBBY.C:297)", "SERVER IS NOW IN LOBBY.", COL_YELLOW)
	log_line("(LIB.C:96)", "ENTERING MAIN LOOP...", COL_WHITE)

func _load_files() -> void:
	if FileAccess.file_exists("user://Config.json") :
		config = JSON.parse_string(FileAccess.get_file_as_string("user://Config.json"))
	if config == null or config.is_empty():
		# seed defaults next to the exe (working dir) if present, else user://
		config = {
			"port": 8606,
			"server_count": 1,
			"ping_limit": 65535,
			"log_file": true,
			"log_debug": true,
			"anticheat": false,
			"pride": true,
			"motd": "",
		}
		_save_config()
	operators = JSON.parse_string(FileAccess.get_file_as_string("user://Operators.json")) if FileAccess.file_exists("user://Operators.json") else {}
	if operators == null:
		operators = {}
	var b = JSON.parse_string(FileAccess.get_file_as_string("user://Bans.json")) if FileAccess.file_exists("user://Bans.json") else []
	bans = b if b is Array else []

func _save_config() -> void:
	var f := FileAccess.open("user://Config.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(config, "\t"))
	var f2 := FileAccess.open("user://Operators.json", FileAccess.WRITE)
	if f2:
		f2.store_string(JSON.stringify(operators, "\t"))
	var f3 := FileAccess.open("user://Bans.json", FileAccess.WRITE)
	if f3:
		f3.store_string(JSON.stringify(bans, "\t"))

func log_line(src: String, text: String, col: Color = COL_WHITE) -> void:
	logs.append({"text": "(%s) %s" % [src, text], "col": col})
	if logs.size() > 14:
		logs.pop_front()
	print(text)

func log_debug_msg(text: String) -> void:
	if config.get("log_debug", true):
		log_line("DBG", text, COL_GRAY)

# ---------------------------------------------------------------- loop
func _physics_process(delta: float) -> void:
	var shot_spec := OS.get_environment("SERVER_SHOT")
	if shot_spec != "":
		var sf := shot_spec.split("=")
		if Engine.get_physics_frames() >= int(sf[0]):
			get_viewport().get_texture().get_image().save_png(sf[1])
			print("SERVER_SHOT_SAVED")
			get_tree().quit()
			return
	if _host == null:
		return
	uptime += delta
	while true:
		var ev := _host.service(0)
		var event: int = ev[0]
		if event == ENetConnection.EVENT_ERROR:
			return
		match event:
			ENetConnection.EVENT_NONE:
				break
			ENetConnection.EVENT_CONNECT:
				var peer: ENetPacketPeer = ev[1]
				log_line("(SERVER.C:201)", "CLIENT CONNECTED (%s)" % peer.get_remote_address(), COL_WHITE)
				_send(peer, _pkt(NetPackets.SERVER_PREIDENTITY))
				continue
			ENetConnection.EVENT_DISCONNECT:
				var peer: ENetPacketPeer = ev[1]
				_on_disconnect(peer)
				continue
			ENetConnection.EVENT_RECEIVE:
				var peer: ENetPacketPeer = ev[1]
				var data := peer.get_packet()
				if data.size() >= 2:
					_process_packet(peer, data)
				continue
	_heartbeat(delta)
	_state_tick(delta)

func _heartbeat(delta: float) -> void:
	heartbeat_t += delta
	if heartbeat_t >= 2.0:
		heartbeat_t = 0.0
		if config.get("log_debug", true):
			log_line("Server.c:525", "Heartbeat done.", COL_GRAY)

# ---------------------------------------------------------------- packets
func _pkt(type: int) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(0)
	b.put_u8(type)
	return b

func _put_str(b: StreamPeerBuffer, s: String) -> void:
	b.put_data(s.to_utf8_buffer())
	b.put_u8(0)

func _get_str(b: StreamPeerBuffer) -> String:
	var bytes := PackedByteArray()
	while b.get_available_bytes() > 0:
		var c := b.get_u8()
		if c == 0:
			break
		bytes.append(c)
	return bytes.get_string_from_utf8()

func _send(peer: ENetPacketPeer, b: StreamPeerBuffer, _reliable := true) -> void:
	# ENetPacketPeer.put_packet is reliable by default (stage 2 only needs reliable)
	peer.put_packet(b.data_array)

func _broadcast(b: StreamPeerBuffer, except_nid := -1) -> void:
	for nid: int in players:
		if nid == except_nid:
			continue
		_send(players[nid].peer, b)

func _process_packet(peer: ENetPacketPeer, data: PackedByteArray) -> void:
	var rb := StreamPeerBuffer.new()
	rb.data_array = data
	rb.big_endian = false
	var _passthrough := rb.get_u8()
	var nps := rb.get_u8()
	# find the player by peer
	var plr = null
	for nid: int in players:
		if players[nid].peer == peer:
			plr = players[nid]
			break
	match nps:
		NetPackets.IDENTITY:
			if plr != null:
				return
			var ver := rb.get_u16()
			var want_lobby: int = rb.get_32()
			var nick := _get_str(rb)
			var udid := _get_str(rb)
			var icon: int = rb.get_8()
			var pet: int = rb.get_8()
			nick = nick.substr(0, 15)
			# ban check
			for banned: String in bans:
				if str(banned) == udid:
					var kf := _pkt(NetPackets.SERVER_PLAYER_FORCE_DISCONNECT)
					_put_str(kf, "You are banned from this server.")
					_send(peer, kf)
					log_line("(CONFIG.C:95)", "BANNED CLIENT TRIED TO CONNECT: " + udid, COL_YELLOW)
					return
			var nid := next_nid
			next_nid += 1
			players[nid] = {
				"peer": peer, "nid": nid, "nickname": nick, "udid": udid,
				"icon": icon, "pet": pet, "ready": false, "char": -1,
				"exechar": -1, "ping": 0,
			}
			var resp := _pkt(NetPackets.SERVER_IDENTITY_RESPONSE)
			# the original's wait flag: 0 = "wait for the round to end" (a round is
			# already running → waiting room), 1 = straight into the lobby. A player
			# who joins alone must NOT be parked on the waiting screen.
			resp.put_u8(0 if server_state == S.GAMESTART else 1)
			resp.put_u16(nid)
			_send(peer, resp)
			if OS.get_environment("SERVER_AUTO_PRACTICE") == "1":
				get_tree().create_timer(1.5).timeout.connect(func() -> void:
					if server_state == S.WAITING:
						practice_mode()
				)
			log_line("(SERVER.C:254)", "PLAYER JOINED: %s (NID %d)" % [nick, nid], COL_GREEN)
			# tell everyone in the waiting screen about the new player
			var info := _pkt(NetPackets.SERVER_WAITING_PLAYER_INFO)
			info.put_u8(0)
			info.put_u16(nid)
			_put_str(info, nick)
			info.put_8(icon)
			_broadcast(info, nid)
			# players already IN the lobby only get the full list on their own join
			# request, so a late joiner would stay invisible to them — the original
			# broadcasts SERVER_PLAYER_JOINED for exactly this (net_state_lobby
			# spawns the icon from it).
			if server_state >= S.LOBBY:
				var pj := _pkt(NetPackets.SERVER_PLAYER_JOINED)
				pj.put_u16(nid)
				_put_str(pj, nick)
				pj.put_u8(icon)
				pj.put_8(pet)
				_broadcast(pj, nid)
			_check_lobby_start()
		NetPackets.CLIENT_CHAT_MESSAGE:
			if plr == null:
				return
			var _nid := rb.get_u16()
			var msg := _get_str(rb).substr(0, 96)
			log_line("(CHAT.C:88)", "%s: %s" % [plr.nickname, msg], COL_WHITE)
			var out := _pkt(NetPackets.CLIENT_CHAT_MESSAGE)
			out.put_u16(plr.nid)
			_put_str(out, msg)
			_broadcast(out)
		NetPackets.CLIENT_LOBBY_PLAYERS_REQUEST:
			if plr == null or server_state < S.LOBBY:
				return
			for nid: int in players:
				var p: Dictionary = players[nid]
				var lp := _pkt(NetPackets.SERVER_LOBBY_PLAYER)
				lp.put_u16(nid)
				lp.put_u8(1 if p.ready else 0)
				_put_str(lp, p.nickname)
				lp.put_u8(p.icon)
				lp.put_8(p.pet)
				_send(peer, lp)
			var corr := _pkt(NetPackets.SERVER_LOBBY_CORRECT)
			_send(peer, corr)
			if server_state == S.VOTE:
				var vm := _pkt(NetPackets.SERVER_VOTE_MAPS)
				vm.put_u8(vote_map[0])
				vm.put_u8(vote_map[1])
				vm.put_u8(vote_map[2])
				_send(peer, vm)
			elif server_state == S.CHARSELECT:
				var ex := _pkt(NetPackets.SERVER_LOBBY_EXE)
				ex.put_u16(exe_nid)
				ex.put_u16(chosen_map)
				_send(peer, ex)
		NetPackets.CLIENT_LOBBY_READY_STATE:
			if plr == null or server_state != S.LOBBY:
				return
			plr.ready = rb.get_u8() != 0
			var st := _pkt(NetPackets.SERVER_LOBBY_READY_STATE)
			st.put_u16(plr.nid)
			st.put_u8(1 if plr.ready else 0)
			_broadcast(st)
			log_line("(LOBBY.C:512)", "%s IS %s" % [plr.nickname, "READY" if plr.ready else "NOT READY"], COL_WHITE)
			_maybe_start_vote()
		NetPackets.CLIENT_VOTE_REQUEST:
			if plr == null or server_state != S.VOTE:
				return
			var m := rb.get_u8()
			if m > 2:
				return
			lobby_votes[plr.nid] = m
			plr.voted = m
			var vs := _pkt(NetPackets.SERVER_VOTE_SET)
			var c := [0, 0, 0]
			for nid: int in lobby_votes:
				c[lobby_votes[nid]] += 1
			vs.put_u8(c[0])
			vs.put_u8(c[1])
			vs.put_u8(c[2])
			_broadcast(vs)
		NetPackets.CLIENT_REQUEST_CHARACTER:
			if plr == null or server_state != S.CHARSELECT:
				return
			var ch := rb.get_u8()
			var ok := ch >= 1 and ch <= 6 and _char_free(ch)
			var resp := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_RESPONSE)
			resp.put_u8(ch)
			resp.put_u8(1 if ok else 0)
			_send(peer, resp)
			if ok:
				plr.char = ch
				var chg := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_CHANGE)
				chg.put_u16(plr.nid)
				chg.put_u8(ch)
				_broadcast(chg, plr.nid)
				log_line("(LOBBY.C:655)", "%s CHOSE CHARACTER %d" % [plr.nickname, ch], COL_WHITE)
				_maybe_start_game()
		NetPackets.CLIENT_REQUEST_EXECHARACTER:
			if plr == null or server_state != S.CHARSELECT or exe_nid != plr.nid:
				return
			var ch := rb.get_u8()
			if ch < 1 or ch > 4:
				return
			plr.char = 0
			plr.exechar = ch
			var resp := _pkt(NetPackets.SERVER_LOBBY_EXECHARACTER_RESPONSE)
			resp.put_u8(ch)
			resp.put_u8(1)
			_send(peer, resp)
			var chg := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_CHANGE)
			chg.put_u16(plr.nid)
			chg.put_u8(ch)
			_broadcast(chg, plr.nid)
			log_line("(LOBBY.C:655)", "%s CHOSE EXE CHARACTER %d" % [plr.nickname, ch], COL_WHITE)
			_maybe_start_game()
		NetPackets.CLIENT_PING:
			if plr != null:
				plr.ping = 0

func _char_free(ch: int) -> bool:
	for nid: int in players:
		if players[nid].char == ch and nid != exe_nid:
			return false
	return true

# ---------------------------------------------------------------- flow
func _check_lobby_start() -> void:
	if server_state != S.WAITING:
		return
	# the lobby opens as soon as anyone is connected — the waiting room is only
	# for players who join mid-round (they get wait=0 on identity instead)
	if players.size() >= 1:
		_start_lobby()

func _start_lobby() -> void:
	server_state = S.LOBBY
	log_line("(LOBBY.C:301)", "LOBBY IS NOW OPEN.", COL_YELLOW)
	for nid: int in players:
		var resp := _pkt(NetPackets.SERVER_IDENTITY_RESPONSE)
		resp.put_u8(1)
		resp.put_u16(nid)
		_send(players[nid].peer, resp)
	# exe chance — random 15..85 like the original vibe
	var ch := _pkt(NetPackets.SERVER_LOBBY_EXE_CHANCE)
	ch.put_u8(randi() % 70 + 15)
	_broadcast(ch)

func back_to_lobby() -> void:
	server_state = S.LOBBY
	countdown = -1
	exe_nid = -1
	lobby_votes.clear()
	for nid: int in players:
		players[nid].char = -1
		players[nid].exechar = -1
		players[nid].ready = false
	var b := _pkt(NetPackets.SERVER_GAME_BACK_TO_LOBBY)
	_broadcast(b)
	# players who sat in the waiting room during the round now move to the lobby
	for nid: int in players:
		var resp := _pkt(NetPackets.SERVER_IDENTITY_RESPONSE)
		resp.put_u8(1)
		resp.put_u16(nid)
		_send(players[nid].peer, resp)
	log_line("(LOBBY.C:297)", "SERVER IS NOW IN LOBBY.", COL_YELLOW)
	# resend full lobby list
	for nid: int in players:
		var p: Dictionary = players[nid]
		var lp := _pkt(NetPackets.SERVER_LOBBY_PLAYER)
		lp.put_u16(nid)
		lp.put_u8(1 if p.ready else 0)
		_put_str(lp, p.nickname)
		lp.put_u8(p.icon)
		lp.put_8(p.pet)
		_broadcast(lp)

func _maybe_start_vote() -> void:
	if server_state != S.LOBBY:
		return
	var ready_count := 0
	for nid: int in players:
		if players[nid].ready:
			ready_count += 1
	if ready_count >= 2 and ready_count == players.size():
		_start_vote()

var practice := false

func practice_mode() -> void:
	if players.is_empty():
		log_line("(MAIN.C:112)", "NO PLAYERS CONNECTED.", COL_YELLOW)
		return
	practice = true
	_start_lobby()
	# jump straight to charselect on map 2 ("...")
	server_state = S.CHARSELECT
	chosen_map = 3
	var ids := players.keys()
	exe_nid = ids[0]
	var ex := _pkt(NetPackets.SERVER_LOBBY_EXE)
	ex.put_u16(exe_nid)
	ex.put_u16(chosen_map)
	_broadcast(ex)
	log_line("(LOBBY.C:390)", "%s IS THE EXE!" % players[exe_nid].nickname, COL_RED)
	log_line("(MAIN.C:118)", "PRACTICE MODE STARTED.", COL_YELLOW)
	get_tree().create_timer(2.5).timeout.connect(func() -> void:
		if server_state == S.CHARSELECT:
			_start_game()
	)

func _start_vote() -> void:
	server_state = S.VOTE
	vote_timer = 20.0
	lobby_votes.clear()
	# pick 3 distinct maps from the first 20 (map 20 = practice)
	var pool := range(20)
	vote_map[0] = pool.pick_random()
	pool.erase(vote_map[0])
	vote_map[1] = pool.pick_random()
	pool.erase(vote_map[1])
	vote_map[2] = pool.pick_random()
	var vm := _pkt(NetPackets.SERVER_VOTE_MAPS)
	vm.put_u8(vote_map[0])
	vm.put_u8(vote_map[1])
	vm.put_u8(vote_map[2])
	_broadcast(vm)
	log_line("(VOTE.C:140)", "MAP VOTE STARTED.", COL_YELLOW)

func _start_charselect() -> void:
	server_state = S.CHARSELECT
	char_timer = 30.0
	# exe: pick random player
	var ids := players.keys()
	exe_nid = ids.pick_random()
	var ex := _pkt(NetPackets.SERVER_LOBBY_EXE)
	ex.put_u16(exe_nid)
	ex.put_u16(chosen_map)
	_broadcast(ex)
	log_line("(LOBBY.C:390)", "%s IS THE EXE!" % players[exe_nid].nickname, COL_RED)

func _start_game() -> void:
	server_state = S.GAMESTART
	var gs := _pkt(NetPackets.SERVER_LOBBY_GAME_START)
	_broadcast(gs)
	log_line("(GAME.C:220)", "GAME STARTED ON MAP %d." % chosen_map, COL_GREEN)
	# in vs-mode the server returns everyone after 4s; practice stays on the map
	if not practice:
		get_tree().create_timer(4.0).timeout.connect(func() -> void:
			if server_state == S.GAMESTART:
				back_to_lobby()
		)

func _maybe_start_game() -> void:
	if server_state != S.CHARSELECT:
		return
	for nid: int in players:
		if players[nid].char == -1:
			return
	_begin_countdown()

func _begin_countdown() -> void:
	if countdown >= 0:
		return
	countdown = 4

func _on_disconnect(peer: ENetPacketPeer) -> void:
	for nid: int in players:
		if players[nid].peer == peer:
			log_line("(SERVER.C:301)", "PLAYER LEFT: %s (NID %d)" % [players[nid].nickname, nid], COL_YELLOW)
			players.erase(nid)
			lobby_votes.erase(nid)
			var pl := _pkt(NetPackets.SERVER_PLAYER_LEFT)
			pl.put_u16(nid)
			_broadcast(pl)
			# practice/game session with nobody left → reset to lobby so the
			# next joiner gets a normal flow
			if players.is_empty() and server_state >= S.CHARSELECT:
				server_state = S.WAITING
				practice = false
				exe_nid = -1
				log_line("(LOBBY.C:297)", "SERVER IS NOW IN LOBBY.", COL_YELLOW)
			if server_state == S.WAITING:
				_check_lobby_start()
			return

# ---------------------------------------------------------------- ticks
func _state_tick(delta: float) -> void:
	match server_state:
		S.LOBBY:
			if countdown < 0.0:
				return  # no countdown running — the original only ticks the packet
				       # during the actual countdown, and the client plays snd_clock
				       # on EVERY packet, so broadcasting while waiting for players
				       # turns the clock into a machine-gun tick.
			countdown -= delta
			var sec2 := int(ceili(countdown))
			if sec2 != _last_cd:
				_last_cd = sec2
				var cd := _pkt(NetPackets.SERVER_LOBBY_COUNTDOWN)
				cd.put_u8(1)
				cd.put_u8(clampi(sec2, 0, 255))
				_broadcast(cd)
			if countdown <= 0.0:
				countdown = -1
				_last_cd = -1
				_start_vote()
		S.VOTE:
			var prev := int(vote_timer)
			vote_timer -= delta
			var ts := _pkt(NetPackets.SERVER_VOTE_TIME_SYNC)
			ts.put_u8(clampi(int(vote_timer) + 1, 0, 255))
			_broadcast(ts)
			if int(vote_timer) != prev and int(vote_timer) <= 3 and int(vote_timer) > 0:
				pass
			if vote_timer <= 0.0:
				_finish_vote()
		S.CHARSELECT:
			char_timer -= delta
			var ts := _pkt(NetPackets.SERVER_CHAR_TIME_SYNC)
			ts.put_u8(clampi(int(char_timer) + 1, 0, 255))
			_broadcast(ts)
			if char_timer <= 0.0:
				# auto-assign random free characters
				for nid: int in players:
					if players[nid].char == -1:
						if nid == exe_nid:
							players[nid].char = 0
							players[nid].exechar = randi() % 4 + 1
							var resp := _pkt(NetPackets.SERVER_LOBBY_EXECHARACTER_RESPONSE)
							resp.put_u8(players[nid].exechar)
							resp.put_u8(1)
							_send(players[nid].peer, resp)
							var chg := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_CHANGE)
							chg.put_u16(nid)
							chg.put_u8(players[nid].exechar)
							_broadcast(chg, nid)
						else:
							for ch in range(1, 7):
								if _char_free(ch):
									players[nid].char = ch
									var resp := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_RESPONSE)
									resp.put_u8(ch)
									resp.put_u8(1)
									_send(players[nid].peer, resp)
									var chg := _pkt(NetPackets.SERVER_LOBBY_CHARACTER_CHANGE)
									chg.put_u16(nid)
									chg.put_u8(ch)
									_broadcast(chg, nid)
									break
				_begin_countdown()
			if countdown >= 0:
				countdown -= delta
				# one packet per second: the client plays snd_clock on EVERY
				# SERVER_LOBBY_COUNTDOWN, so a per-frame broadcast is a machine-gun
				var sec_c := int(ceili(countdown))
				if sec_c != _last_cd:
					_last_cd = sec_c
					var cd := _pkt(NetPackets.SERVER_LOBBY_COUNTDOWN)
					cd.put_u8(1)
					cd.put_u8(clampi(sec_c, 0, 255))
					_broadcast(cd)
				if countdown <= 0.0:
					countdown = -1
					_last_cd = -1
					_start_game()

func _finish_vote() -> void:
	# tally votes
	var counts := [0, 0, 0]
	for nid: int in lobby_votes:
		counts[lobby_votes[nid]] += 1
	var best := 0
	if counts[1] > counts[best]: best = 1
	if counts[2] > counts[best]: best = 2
	chosen_map = vote_map[best]
	log_line("(VOTE.C:201)", "MAP %d WON THE VOTE." % chosen_map, COL_GREEN)
	_start_charselect()

# ---------------------------------------------------------------- commands from UI
func ui_force_back_to_lobby() -> void:
	if server_state != S.WAITING:
		back_to_lobby()

func ui_force_exe_win() -> void:
	log_line("(MAIN.C:141)", "FORCE EXE WIN — AVAILABLE IN STAGE 3.", COL_YELLOW)

func ui_force_escape() -> void:
	log_line("(MAIN.C:146)", "FORCE ESCAPE — AVAILABLE IN STAGE 3.", COL_YELLOW)

func toggle_option(key: String) -> void:
	var v = config.get(key)
	match typeof(v):
		TYPE_BOOL:
			config[key] = not v
			log_line("(CONFIG.C:%d)" % (randi() % 300 + 100), "%s IS NOW %s." % [key.to_upper(), "ENABLED" if config[key] else "DISABLED"], COL_YELLOW)
		TYPE_INT, TYPE_FLOAT:
			log_line("(CONFIG.C:99)", "EDIT %s IN CONFIG.JSON (USER APPDATA FOLDER).", COL_GRAY)
		_:
			log_line("(CONFIG.C:99)", "EDIT %s IN CONFIG.JSON (USER APPDATA FOLDER).", COL_GRAY)
	save_all()

func save_all() -> void:
	_save_config()

func _on_disconnect_signal() -> void:
	pass
