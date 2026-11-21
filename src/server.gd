extends Node2D
## DisasterServer — standalone server replicating BetterServer v1101:
## visuals (grid bg, log panel, buttons), Config.json settings and the
## server-authoritative lobby flow of the original.

const BUILD_VER := 1130
const MAX_PLAYERS := 10
const Maps = preload("res://src/data/maps.gd")
const MapProfiles = preload("res://src/data/map_profiles.gd")
var PLAYABLE_MAPS: Array = Maps.playable_ids()
var profile_rules = preload("res://src/profile_rules.gd").new(self)
# Original client exposes exeNear, but its server radius is not in the OSS sources.
const DEATH_PAUSE_RADIUS := 256.0

enum S { WAITING, LOBBY, VOTE, CHARSELECT, GAMESTART, RESULTS }

# ---------------------------------------------------------------- config
var config := {}
var operators := {}
var bans := []

# ---------------------------------------------------------------- runtime
var _host: ENetConnection = null
var players: Dictionary = {}  # nid -> player dict
var next_nid := 1
var server_state: int = S.WAITING
var uptime := 0.0
var heartbeat_t := 0.0

var lobby_votes: Dictionary = {}  # nid -> map
var vote_map := [0, 0, 0]
var vote_timer := 20.0
var char_timer := 30.0
var countdown := -1.0
var _last_cd := -1  # last countdown second broadcast (throttles the tick packet)
var _last_vote_sec := -1  # the vote timer sync throttle
var _last_char_sec := -1  # the charselect timer sync throttle
var exe_nid := -1
# the authoritative round/game state (stage: netplay sync)
var game_ticks := 0  # the round countdown in 1/60 s ticks
var _game_frame := 0
var chosen_map := 6
var ring_states: Array = []
var next_ring_uid := 0
var projectile_until := 0
var exit_index := -1
var exit_position := Vector2.ZERO
var exit_ready := false
var exit_age := 0
var escape_end_frame := -1
var round_ending := false
var round_had_survivors := false
var round_records: Dictionary = {}
var round_result := 0
var round_duration := 0
var results_ticks := 0

var exeller_rules: RefCounted = preload("res://src/exeller_rules.gd").new(self)
var exetior_rules: RefCounted = preload("res://src/exetior_rules.gd").new(self)
var chaos_rules: RefCounted = preload("res://src/chaos_rules.gd").new(self)
var character_rules: RefCounted = preload("res://src/character_rules.gd").new(self)

var logs: Array = []  # {text, color}

const COL_WHITE := Color(0.92, 0.92, 0.92)
const COL_GREEN := Color(0.0, 1.0, 0.35)
const COL_RED := Color(1.0, 0.35, 0.45)
const COL_YELLOW := Color(1.0, 0.9, 0.3)
const COL_PURPLE := Color(0.8, 0.5, 1.0)
const COL_GRAY := Color(0.55, 0.55, 0.55)

var _active_map: RefCounted
var _active_map_id := -1
var active_map:
	get:
		if _active_map == null or _active_map_id != chosen_map:
			_active_map_id = chosen_map
			var path = Maps.rules_path(chosen_map, true)
			_active_map = (
				load(path if not path.is_empty() else "res://src/maps/shared/rules.gd").new(self)
			)
		return _active_map

var chat_commands = preload("res://src/chat_commands.gd").new(self)


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
		log_line(
			"(CONFIG.C:173)", "ANTICHEAT IS DISABLED. CLIENT MODIFICATIONS ARE ALLOWED.", COL_YELLOW
		)
	if str(config.get("motd", "")) == "":
		log_line("(CONFIG.C:212)", "MOTD IS DISABLED.", COL_WHITE)
	else:
		log_line("(CONFIG.C:212)", "MOTD IS ENABLED.", COL_YELLOW)
	log_line("(LIB.C:50)", "LISTENING ON PORT %d..." % port, COL_WHITE)
	log_line("(LOBBY.C:297)", "SERVER IS NOW IN LOBBY.", COL_YELLOW)
	log_line("(LIB.C:96)", "ENTERING MAIN LOOP...", COL_WHITE)


func _upgrade_map_pool() -> void:
	# JSON parses numbers as floats; normalize IDs for UI membership tests.
	if config.get("maps") is Array:
		var normalized: Array = []
		for value in config.maps:
			if (
				typeof(value) in [TYPE_INT, TYPE_FLOAT]
				and value == int(value)
				and not normalized.has(int(value))
			):
				normalized.append(int(value))
		config.maps = normalized
	MapProfiles.upgrade(config)


func _load_files() -> void:
	if FileAccess.file_exists("user://Config.json"):
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
	var previous_config := config.duplicate(true)
	_upgrade_map_pool()
	operators = (
		JSON.parse_string(FileAccess.get_file_as_string("user://Operators.json"))
		if FileAccess.file_exists("user://Operators.json")
		else {}
	)
	if operators == null or operators.is_empty():
		operators = {"127.0.0.1": "Host (127.0.0.1)"}
		_save_config()
	var b = (
		JSON.parse_string(FileAccess.get_file_as_string("user://Bans.json"))
		if FileAccess.file_exists("user://Bans.json")
		else []
	)
	bans = b if b is Array else []
	if config != previous_config:
		_save_config()


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
	logs.append({"text": "(%s): %s" % [src.trim_prefix("(").trim_suffix(")"), text], "col": col})
	if logs.size() > 1000:
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
				log_line(
					"(SERVER.C:201)", "CLIENT CONNECTED (%s)" % peer.get_remote_address(), COL_WHITE
				)
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
	chat_commands.tick(delta)
	_heartbeat(delta)
	_state_tick(delta)


func _heartbeat(delta: float) -> void:
	heartbeat_t += delta
	if heartbeat_t >= 2.0:
		heartbeat_t = 0.0
		if config.get("log_debug", true):
			log_line("Server.c:525", "Heartbeat done.", COL_GRAY)


# ---------------------------------------------------------------- packets
func _pkt(type: int, passthrough := false) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(1 if passthrough else 0)
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
	if (
		round_ending
		and (
			nps
			in [
				NetPackets.CLIENT_PLAYER_HURT,
				NetPackets.CLIENT_STATS_REPORT,
				NetPackets.CLIENT_PLAYER_DEATH_STATE,
				NetPackets.CLIENT_PLAYER_ESCAPED,
				NetPackets.CLIENT_RING_COLLECTED,
				NetPackets.CLIENT_RING_BROKE,
				NetPackets.CLIENT_TPROJECTILE,
				NetPackets.CLIENT_TPROJECTILE_HIT
			]
		)
	):
		return
	# find the player by peer
	var plr = null
	for nid: int in players:
		if players[nid].peer == peer:
			plr = players[nid]
			break
	if active_map.handle(plr, nps, rb):
		return
	if profile_rules.handle(plr, nps, rb):
		return
	if exeller_rules.handle(plr, nps, rb):
		return
	if exetior_rules.handle(plr, nps, rb):
		return
	if chaos_rules.handle(plr, nps, rb):
		return
	if character_rules.handle(plr, nps, rb):
		return
	match nps:
		NetPackets.CLIENT_RESULTS_REQUEST:
			if server_state == S.RESULTS and plr != null:
				_send_results(peer)
		NetPackets.CLIENT_PLAYER_DATA:
			# the client sends its own movement sim; the SERVER strips the
			# client's stats and re-authors them from its own state — the
			# puppets on other clients always show the server's hp/rings
			if server_state == S.GAMESTART and plr != null and plr.get("in_round", false):
				if not plr.get("ring_sync", false):
					plr.ring_sync = true
					character_rules.snapshot(peer)
					profile_rules.snapshot(peer)
					active_map.snapshot(peer)
					for iid in ring_states.size():
						var ring: Dictionary = ring_states[iid]
						if ring.timer == 0 and ring.get("dynamic", false):
							_send(peer, character_rules.ring_packet(iid, ring))
							continue
						if ring.timer == 0:
							var snapshot := _pkt(NetPackets.SERVER_RING_STATE)
							snapshot.put_u8(0)
							snapshot.put_u8(iid)
							snapshot.put_u16(ring.uid)
							snapshot.put_u8(1 if ring.red else 0)
							_send(peer, snapshot)
				var px := rb.get_16()
				var py := rb.get_16()
				var pxs := rb.get_16()  # f16 raw bits
				var pys := rb.get_16()
				var pst := rb.get_u8()
				plr.move_state = pst
				var pang := rb.get_16()
				var pim := rb.get_u8()
				plr.move_frame = pim
				var psc := rb.get_8()
				plr.facing = psc
				plr.position_ready = true
				plr.last_x = px
				plr.last_y = py
				var relay := StreamPeerBuffer.new()
				relay.big_endian = false
				relay.put_u8(1)  # passtrough — a relayed client packet
				relay.put_u8(NetPackets.CLIENT_PLAYER_DATA)
				relay.put_u16(plr.nid)
				relay.put_16(px)
				relay.put_16(py)
				relay.put_16(pxs)
				relay.put_16(pys)
				relay.put_u8(pst)
				relay.put_16(pang)
				relay.put_u8(pim)
				relay.put_8(psc)
				if plr.char == 0:
					# the exe's flags are client-driven cosmetics (attack/invis)
					var flags := rb.get_u8()
					if chaos_rules.is_chaos(plr):
						flags = chaos_rules.flags(plr, flags)
					elif exetior_rules.is_exetior(plr):
						flags = exetior_rules.flags(plr, flags)
					elif exeller_rules.is_exeller(plr):
						flags = exeller_rules.flags(plr, flags)
					plr.attacking = flags & NetPackets.PLAYER_ATTACKING != 0
					if (
						plr.char == 0
						and plr.get("exechar", 0) == 0
						and (flags & NetPackets.PLAYER_INVIS != 0 or plr.get("invisible", false))
					):
						profile_rules.event(plr, "invis")
					plr.invisible = flags & NetPackets.PLAYER_INVIS != 0
					relay.put_u8(flags)
				else:
					relay.put_8(plr.hp)
					relay.put_u8(plr.revival)
					relay.put_16(plr.rings)
					# skip the CLIENT's stats (hp/revival/rings) — the server's
					# values above replace them
					rb.seek(rb.get_position() + 4)
					var bitflags := 0
					if plr.hurttime > 0:
						bitflags |= NetPackets.PLAYER_HURT
					if plr.red_ring > 0:
						bitflags |= NetPackets.PLAYER_REDRING
					var cflags := rb.get_u8()
					bitflags |= cflags & (NetPackets.PLAYER_ATTACKING | NetPackets.PLAYER_EFFECT)
					if plr.char == 3:
						bitflags &= ~NetPackets.PLAYER_ATTACKING
						if character_rules.shield(plr):
							bitflags |= NetPackets.PLAYER_ATTACKING
					if plr.char in [2, 4, 6]:
						bitflags &= ~NetPackets.PLAYER_ATTACKING
						if character_rules.melee_flags(
							plr, cflags & NetPackets.PLAYER_ATTACKING != 0
						):
							bitflags |= NetPackets.PLAYER_ATTACKING
					if character_rules.sally_shield(plr):
						bitflags |= NetPackets.PLAYER_SALLYSHIELD
					plr.attacking = bitflags & NetPackets.PLAYER_ATTACKING != 0
					relay.put_u8(bitflags)
					if plr.char == 1:  # Tails: the charge + tail angle pass through
						relay.put_u8(rb.get_u8())
						relay.put_16(rb.get_16())
				_broadcast(relay, plr.nid)
				for other_id in players:
					if other_id != plr.nid and character_rules.try_parry(plr, players[other_id]):
						break
			return
		NetPackets.CLIENT_SPRING_USE:
			if (
				server_state != S.GAMESTART
				or round_ending
				or chosen_map != 0
				or plr == null
				or not plr.get("in_round", false)
				or plr.get("is_dead", true)
				or plr.get("revival", 0) >= 2
				or rb.get_available_bytes() < 6
			):
				return
			rb.get_u16()  # never trust the supplied player identity
			var at := Vector2(rb.get_u16(), rb.get_u16())
			if (
				not plr.get("position_ready", false)
				or at.distance_to(Vector2(plr.last_x, plr.last_y)) > 64
			):
				return
			var locations: Dictionary = preload("res://src/data/maps.gd").table("springs")
			var valid := false
			for spring in locations.get("0", []):
				if at.distance_to(Vector2(spring[0], spring[1])) <= 64:
					valid = true
					break
			if not valid:
				return
			var echo := _pkt(NetPackets.CLIENT_SPRING_USE)
			echo.put_u16(plr.nid)
			echo.put_u16(int(at.x))
			echo.put_u16(int(at.y))
			_broadcast(echo, plr.nid)

		NetPackets.CLIENT_TPROJECTILE:
			if (
				server_state != S.GAMESTART
				or plr == null
				or not plr.get("in_round", false)
				or plr.char != 1
				or plr.is_dead
			):
				return
			if Time.get_ticks_msec() < projectile_until:
				return
			var shot := _pkt(NetPackets.SERVER_TPROJECTILE_STATE)
			shot.put_u8(0)
			shot.put_u16(rb.get_u16())
			shot.put_u16(rb.get_u16())
			shot.put_u16(plr.nid)
			shot.put_8(clampi(rb.get_8(), -1, 1))
			plr.last_shot_power = clampi(rb.get_u8(), 1, 3 if plr.revival >= 2 else 6)
			shot.put_u8(plr.last_shot_power)
			rb.get_u8()
			shot.put_u8(1 if plr.revival >= 2 else 0)
			shot.put_u8(clampi(rb.get_u8(), 0, 5))
			projectile_until = Time.get_ticks_msec() + 1600
			plr.map_ray_origin = Vector2(plr.last_x, plr.last_y)
			plr.map_ray_dir = plr.get("facing", 1)
			plr.map_ray_start = _game_frame
			plr.map_ray_until = _game_frame + 300
			_broadcast(shot)
		NetPackets.CLIENT_TPROJECTILE_HIT:
			if server_state != S.GAMESTART or plr == null or not plr.get("in_round", false):
				return
			var destroyed := _pkt(NetPackets.SERVER_TPROJECTILE_STATE)
			plr.map_ray_until = _game_frame
			destroyed.put_u8(2)
			_broadcast(destroyed)
		NetPackets.CLIENT_PLAYER_ESCAPED:
			if (
				server_state != S.GAMESTART
				or plr == null
				or not plr.get("in_round", false)
				or not exit_ready
			):
				return
			if (
				plr.char == 0
				or plr.revival >= 2
				or plr.is_dead
				or plr.hp <= 0
				or plr.red_ring > 0
				or not plr.get("position_ready", false)
			):
				return
			if Vector2(plr.last_x, plr.last_y).distance_to(exit_position) > 64:
				return
			if not active_map.can_escape():
				return
			plr.escaped = true
			plr.in_round = false
			_send(peer, _pkt(NetPackets.SERVER_PLAYER_ESCAPED))
			var escaped := _pkt(NetPackets.SERVER_GAME_PLAYER_ESCAPED)
			escaped.put_u16(plr.nid)
			_broadcast(escaped, plr.nid)
			_check_round_end()
		NetPackets.CLIENT_STATS_REPORT:
			if server_state != S.GAMESTART or plr == null or not plr.get("in_round", false):
				return
			var report_type := rb.get_u8()
			if report_type == 3:
				_apply_survivor_damage(plr, rb.get_u8())
			elif report_type == 2:
				var attacker := rb.get_u16()
				var damage := rb.get_u16()
				rb.get_u16()
				if (
					players.has(attacker)
					and players[attacker].char == 1
					and players[attacker].revival >= 2
				):
					_apply_survivor_damage(plr, damage, attacker)
		NetPackets.CLIENT_PLAYER_DEATH_STATE:
			if (
				server_state != S.GAMESTART
				or plr == null
				or not plr.get("in_round", false)
				or plr.char == 0
				or plr.revival >= 2
			):
				return
			var dead := rb.get_u8() != 0
			rb.get_u8()  # revival is owned by the server
			if dead and not plr.is_dead:
				plr.hp = 0
				plr.rings = 0
				plr.is_dead = true
				plr.dead_timer = 60 * 31
				plr.death_near = -1
		NetPackets.CLIENT_PLAYER_HURT:
			# the victim reports a hit from the puppet atk_pid; the server
			# validates and applies the authoritative damage
			if server_state != S.GAMESTART or plr == null or not plr.get("in_round", false):
				return
			var atk_pid := rb.get_u16()
			var hx := rb.get_u16()
			var hy := rb.get_u16()
			var stun := rb.get_u16()
			if players.has(atk_pid) and character_rules.try_parry(plr, players[atk_pid]):
				return
			if (
				stun > 0
				and plr.char == 4
				and plr.get("move_state", 0) == 14
				and character_rules.melee_attacking(plr)
			):
				return
			if players.has(atk_pid) and players[atk_pid].char in [2, 4, 6] and stun > 0:
				var knux: Dictionary = players[atk_pid]
				if (
					not character_rules.hunter(plr)
					or character_rules.hunter(knux)
					or not character_rules.melee_attacking(knux)
					or plr.hurttime > 0
					or not character_rules.alive(plr)
					or not plr.get("position_ready", false)
					or plr.get("invisible", false)
					or character_rules.pos(plr).distance_to(character_rules.pos(knux)) > 64
				):
					return
				if plr.char == 4 and plr.get("attacking", false):
					return
				if character_rules.break_sally_shield(
					plr,
					Vector2(
						-signf(character_rules.pos(knux).x - character_rules.pos(plr).x) * 2, -2
					)
				):
					return
				stun = 180
				character_rules.knux_stun(plr, knux)
			elif players.has(atk_pid) and players[atk_pid].char == 3 and stun > 0:
				var egg: Dictionary = players[atk_pid]
				if (
					not character_rules.hunter(plr)
					or character_rules.hunter(egg)
					or not character_rules.shield(egg)
					or plr.hurttime > 0
					or not plr.get("position_ready", false)
					or character_rules.pos(plr).distance_to(character_rules.pos(egg)) > 48
				):
					return
				if character_rules.break_sally_shield(
					plr,
					Vector2(-signf(character_rules.pos(egg).x - character_rules.pos(plr).x) * 2, -2)
				):
					return
				stun = 120
				character_rules.status(plr, 1, stun)
			elif stun > 0 and (not players.has(atk_pid) or players[atk_pid].char != 1):
				return
			# relay to the others (their camera shake / blood effects)
			if stun > 0 and (plr.hurttime > 0 or plr.is_dead or plr.hp <= 0):
				return
			var relay2 := StreamPeerBuffer.new()
			relay2.big_endian = false
			relay2.put_u8(1)
			relay2.put_u8(NetPackets.CLIENT_PLAYER_HURT)
			relay2.put_u16(plr.nid)
			relay2.put_u16(atk_pid)
			relay2.put_u16(hx)
			relay2.put_u16(hy)
			relay2.put_u16(stun)
			_broadcast(relay2, plr.nid)
			if stun > 0:
				plr.hurttime = clampi(stun, 1, 360) + 120
				plr.stunned_ticks = clampi(stun, 1, 360)
				if players.has(atk_pid):
					_stat(players[atk_pid], "stuns", 1)
					if players[atk_pid].char == 2:
						profile_rules.event(
							players[atk_pid],
							"bonus",
							8 if players[atk_pid].get("move_state", 0) == 15 else 9
						)
			# authority: damage only when the victim's hurttime is clear and
			# they are alive; the attacker's character sets the amount
			if (
				stun == 0
				and plr.hurttime <= 0
				and not plr.is_dead
				and plr.hp > 0
				and plr.char != 0
				and players.has(atk_pid)
			):
				var dmg := 1
				var atk: Dictionary = players[atk_pid]
				if not character_rules.hunter(atk) or character_rules.hunter(plr):
					return
				if chaos_rules.is_chaos(atk) and not chaos_rules.can_hit(atk, plr):
					return
				if exetior_rules.is_exetior(atk) and not exetior_rules.can_hit(atk, plr):
					return
				if exeller_rules.is_exeller(atk) and not exeller_rules.can_hit(atk, plr):
					return
				if plr.char == 4:
					if plr.get("move_state", 0) == 14 and character_rules.melee_attacking(plr):
						return
					if (
						plr.get("move_state", 0) == 15
						and plr.get("move_frame", 99) <= 3
						and not atk.get("attacking", false)
						and atk.get("move_state", 0) in [3, 12]
					):
						return
				if plr.char == 3 and character_rules.shield(plr) and atk.char != 4:
					return
				if atk.char == 3:
					if (
						not character_rules.shield(atk)
						or character_rules.pos(plr).distance_to(character_rules.pos(atk)) > 48
					):
						return
				if atk.char == 2:
					if character_rules.pos(plr).distance_to(character_rules.pos(atk)) > 64:
						return
					if atk.get("move_state", 0) in [14, 15]:
						if not character_rules.knux_attacking(atk):
							return
					elif atk.get("move_state", 0) not in [3, 12]:
						return
				if atk.char in [4, 6]:
					if (
						not character_rules.melee_attacking(atk)
						or character_rules.pos(plr).distance_to(character_rules.pos(atk)) > 64
					):
						return
				if character_rules.sally_shield(plr):
					var spin: bool = (
						not atk.get("attacking", false) and atk.get("move_state", 0) in [3, 12]
					)
					character_rules.break_sally_shield(
						plr,
						Vector2(
							(
								signf(character_rules.pos(plr).x - character_rules.pos(atk).x)
								* (3 if spin else 2)
							),
							-4 if spin else -2
						)
					)
					return
				if atk.char == 3:
					character_rules.status(plr, 0, 180)
				if atk.char == 0 and atk.get("attacking", false) and atk.exechar in [0, 2, 3]:
					dmg = 2
				_apply_survivor_damage(plr, dmg, atk_pid, 4)
			return
		NetPackets.CLIENT_RING_BROKE:
			# the demon shot / exe attack broke a ring: everyone destroys THEIR
			# copy (by iid) and the others spawn the particle burst
			if server_state != S.GAMESTART or plr == null or not plr.get("in_round", false):
				return
			var biid := rb.get_u8()
			var buid := rb.get_u16()
			if not _ring_valid(biid, buid) or ring_states[biid].red:
				return
			ring_states[biid].timer = -1 if ring_states[biid].get("dynamic", false) else 2700
			var bx := rb.get_u16()
			var by := rb.get_u16()
			var bxs := rb.get_16()
			var rs2 := _pkt(NetPackets.SERVER_RING_STATE)
			rs2.put_u8(1)
			rs2.put_u8(biid)
			rs2.put_u16(buid)
			_broadcast(rs2)
			var rb2 := StreamPeerBuffer.new()
			rb2.big_endian = false
			rb2.put_u8(1)
			rb2.put_u8(NetPackets.CLIENT_RING_BROKE)
			rb2.put_u16(bx)
			rb2.put_u16(by)
			rb2.put_16(bxs)
			_broadcast(rb2, plr.nid)
			return
		NetPackets.CLIENT_RING_COLLECTED:
			# the ring field is client-raised (solo respawn emulation); the
			# server owns the RING COUNTER and the collection broadcast
			if server_state != S.GAMESTART or plr == null or not plr.get("in_round", false):
				return
			var iid := rb.get_u8()
			var uid := rb.get_u16()
			if plr.char == 0 or plr.is_dead or plr.hp <= 0 or plr.revival >= 2:
				return
			if not _ring_valid(iid, uid):
				return
			var ring: Dictionary = ring_states[iid]
			if ring.get("dynamic", false):
				if (
					not plr.get("position_ready", false)
					or character_rules.pos(plr).distance_to(ring.at) > 48
					or _game_frame - ring.born < (180 if ring.red else 30)
				):
					return
			var red: bool = ring.red
			if red and plr.red_ring > 0:
				return
			ring_states[iid].timer = -1 if ring_states[iid].get("dynamic", false) else 2700
			if red:
				plr.red_ring = 600
			else:
				_stat(plr, "rings", 1)
				plr.rings += 1
				if plr.red_ring >= 60:
					plr.red_ring = maxi(60, plr.red_ring - (120 if game_ticks < 3600 else 30))
			var can_heal := false
			if not red and plr.rings >= 10 and plr.hp < 5 and plr.heal_cd <= 0:
				can_heal = true
				plr.rings = 0
				_stat(plr, "healed", 1)
				plr.hp = mini(plr.hp + 1, 5)
				plr.heal_cd = 30
			# everyone destroys that ring (SERVER_RING_STATE state 1)
			var rs := _pkt(NetPackets.SERVER_RING_STATE)
			rs.put_u8(1)
			rs.put_u8(iid)
			rs.put_u16(uid)
			_broadcast(rs)
			# the collector's own response (rings++ / the heal decision)
			var rc := _pkt(NetPackets.SERVER_RING_COLLECTED)
			rc.put_u8(iid)
			rc.put_u16(plr.nid)
			rc.put_u8(1 if red else 0)
			rc.put_u8(1 if can_heal else 0)
			_send(plr.peer, rc)
			return
		NetPackets.IDENTITY:
			if plr != null:
				return
			var ver := rb.get_u16()
			if ver != BUILD_VER:
				var reject := _pkt(NetPackets.SERVER_PLAYER_FORCE_DISCONNECT)
				_put_str(reject, "Update both client and server (build 1130: first-launch save import).")
				_send(peer, reject)
				return
			var want_lobby: int = rb.get_32()
			var nick := _get_str(rb)
			var udid := _get_str(rb)
			var icon: int = rb.get_8()
			var pet: int = rb.get_8()
			nick = nick.substr(0, 15)
			# ban check
			for banned: String in bans:
				if str(banned) == udid or str(banned) == "ip:" + peer.get_remote_address():
					var kf := _pkt(NetPackets.SERVER_PLAYER_FORCE_DISCONNECT)
					_put_str(kf, "You are banned from this server.")
					_send(peer, kf)
					log_line("(CONFIG.C:95)", "BANNED CLIENT TRIED TO CONNECT: " + udid, COL_YELLOW)
					return
			var nid := next_nid
			next_nid += 1
			players[nid] = {
				"peer": peer,
				"nid": nid,
				"nickname": nick,
				"udid": udid,
				"icon": icon,
				"pet": pet,
				"ready": false,
				"char": -1,
				"ip": peer.get_remote_address(),
				"exechar": -1,
				"ping": 0,
				"in_round": false,
			}
			var resp := _pkt(NetPackets.SERVER_IDENTITY_RESPONSE)
			# the original's wait flag: 0 = "wait for the round to end" (a round is
			# already running → waiting room), 1 = straight into the lobby. A player
			# who joins alone must NOT be parked on the waiting screen.
			resp.put_u8(0 if server_state in [S.GAMESTART, S.RESULTS] else 1)
			resp.put_u16(nid)
			_send(peer, resp)
			log_line("(SERVER.C:254)", "PLAYER JOINED: %s (NID %d)" % [nick, nid], COL_GREEN)
			if server_state in [S.GAMESTART, S.RESULTS]:
				# A late joiner needs the current roster, not only future joins.
				for existing in players.values():
					var waiting_info = _pkt(NetPackets.SERVER_WAITING_PLAYER_INFO)
					var ingame = int(existing.get("char", -1)) >= 0  # Escaped participants still keep their character portrait.
					waiting_info.put_u8(1 if ingame else 0)
					waiting_info.put_u16(existing.nid)
					_put_str(waiting_info, existing.nickname)
					if ingame:
						waiting_info.put_u8(1 if existing.get("char", -1) == 0 else 0)
						waiting_info.put_8(
							(
								existing.get("exechar", 0)
								if existing.get("char", -1) == 0
								else existing.get("char", -1) - 1
							)
						)
					else:
						waiting_info.put_8(existing.icon)
					_send(peer, waiting_info)
				var waiting_clock = _pkt(NetPackets.SERVER_GAME_TIME_SYNC)
				waiting_clock.put_u16(clampi(game_ticks, 0, 65535))
				_send(peer, waiting_clock)
				chat_commands.intro(players[nid])
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
			if (
				not test_role.is_empty()
				and server_state in [S.VOTE, S.CHARSELECT]
				and players.size() > 1
			):
				chat_commands.broadcast("|solo test cancelled: another player joined~")
				back_to_lobby()
		NetPackets.CLIENT_LOBBY_CHOOSEKICK, NetPackets.CLIENT_LOBBY_CHOOSEBAN, NetPackets.CLIENT_LOBBY_CHOOSEOP, NetPackets.CLIENT_LOBBY_CHOOSEVOTEKICK:
			if plr != null and rb.get_available_bytes() >= 2:
				chat_commands.target(plr, nps, rb.get_u16())
		NetPackets.CLIENT_CHAT_MESSAGE:
			if plr == null:
				return
			var _nid := rb.get_u16()
			var msg := _get_str(rb).substr(0, 80)
			if chat_commands.handle(plr, msg):
				return
			log_line("(CHAT.C:88)", "%s: %s" % [plr.nickname, msg], COL_WHITE)
			var out := _pkt(NetPackets.CLIENT_CHAT_MESSAGE)
			out.put_u16(plr.nid)
			_put_str(out, msg)
			_broadcast(out, plr.nid)
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
			chat_commands.intro(plr)
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
				for id: int in players:
					var selected: Dictionary = players[id]
					if selected.char == -1:
						continue
					var chosen: int = selected.exechar if id == exe_nid else selected.char
					var packet: StreamPeerBuffer
					if id == plr.nid:
						packet = _pkt(
							(
								NetPackets.SERVER_LOBBY_EXECHARACTER_RESPONSE
								if id == exe_nid
								else NetPackets.SERVER_LOBBY_CHARACTER_RESPONSE
							)
						)
						packet.put_u8(chosen)
						packet.put_u8(1)
					else:
						packet = _pkt(NetPackets.SERVER_LOBBY_CHARACTER_CHANGE)
						packet.put_u16(id)
						packet.put_u8(chosen)
					_send(peer, packet)
		NetPackets.CLIENT_LOBBY_READY_STATE:
			if plr == null or server_state != S.LOBBY:
				return
			plr.ready = rb.get_u8() != 0
			var st := _pkt(NetPackets.SERVER_LOBBY_READY_STATE)
			st.put_u16(plr.nid)
			st.put_u8(1 if plr.ready else 0)
			_broadcast(st)
			log_line(
				"(LOBBY.C:512)",
				"%s IS %s" % [plr.nickname, "READY" if plr.ready else "NOT READY"],
				COL_WHITE
			)
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
			_shorten_vote()
		NetPackets.CLIENT_REQUEST_CHARACTER:
			if plr == null or server_state != S.CHARSELECT:
				return
			var ch := rb.get_u8()
			var ok: bool = (
				plr.nid != exe_nid and plr.char == -1 and ch >= 1 and ch <= 6 and _char_free(ch)
			)
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
			if ch < 1 or ch > 4 or plr.char != -1:
				return
			ch -= 1  # UI slots 1..4; wire/game EXE indices 0..3.
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
				plr.ping = _peer_ping_ms(peer)
				var limit: int = config.get("ping_limit", 65535)
				if limit < 65535 and plr.ping > limit:
					var reject := _pkt(NetPackets.SERVER_PLAYER_FORCE_DISCONNECT)
					_put_str(reject, "Ping exceeds the server limit (%d ms)." % limit)
					_send(peer, reject)
					return
				var pr := _pkt(NetPackets.SERVER_GAME_PING)
				pr.put_u16(plr.nid)
				pr.put_u16(1)
				_send(plr.peer, pr)


func _peer_ping_ms(peer: ENetPacketPeer) -> int:
	return (
		maxi(1, int(peer.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))) if peer != null else 1
	)


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
	practice = false
	test_role = ""
	chat_commands.reset()
	round_ending = false
	escape_end_frame = -1
	server_state = S.LOBBY
	countdown = -1
	exe_nid = -1
	lobby_votes.clear()
	for nid: int in players:
		players[nid].in_round = false
		players[nid].char = -1
		players[nid].exechar = -1
		players[nid].ready = false
		players[nid].intro_sent = false
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
	if ready_count >= 2 and ready_count == players.size() and not _enabled_maps().is_empty():
		_begin_countdown()
	elif countdown >= 0:
		countdown = -1.0
		_last_cd = -1
		var cd := _pkt(NetPackets.SERVER_LOBBY_COUNTDOWN)
		cd.put_u8(0)
		cd.put_u8(0)
		_broadcast(cd)


var practice := false
var test_role := ""


func start_solo_test(role: String) -> void:
	if (
		role not in ["k", "s"]
		or server_state not in [S.WAITING, S.LOBBY]
		or players.size() != 1
		or _enabled_maps().is_empty()
	):
		return
	chat_commands.reset()
	test_role = role
	practice = false
	_start_vote()


func practice_mode() -> void:
	if server_state not in [S.WAITING, S.LOBBY] or players.size() < 2:
		log_line("UI", "PRACTICE REQUIRES AT LEAST TWO PLAYERS IN THE LOBBY.", COL_YELLOW)
		return
	start_selected_map(20)


func start_selected_map(map_id: int):
	if map_id < 0 or map_id > 20 or players.is_empty():
		return
	test_role = ""
	chat_commands.reset()
	countdown = -1
	chosen_map = map_id
	practice = map_id == 20
	_start_charselect()
	chat_commands.broadcast("map: @%s~" % chat_commands.MAP_NAMES[map_id])


func _start_vote() -> void:
	if _enabled_maps().is_empty():
		return
	countdown = -1.0
	_last_cd = -1
	server_state = S.VOTE
	vote_timer = 20.0
	lobby_votes.clear()
	_last_vote_sec = -1
	# Include every enabled playable map before filling the third card and shuffling.
	var pool := _enabled_maps()
	pool.shuffle()
	vote_map = pool.slice(0, 3)
	while vote_map.size() < 3:
		vote_map.append(pool.pick_random())
	vote_map.shuffle()
	var vm := _pkt(NetPackets.SERVER_VOTE_MAPS)
	vm.put_u8(vote_map[0])
	vm.put_u8(vote_map[1])
	vm.put_u8(vote_map[2])
	_broadcast(vm)
	log_line(
		"(VOTE.C:140)",
		"MAP VOTE STARTED: %d / %d / %d." % [vote_map[0], vote_map[1], vote_map[2]],
		COL_YELLOW
	)


func _start_charselect() -> void:
	countdown = -1.0
	_last_cd = -1
	server_state = S.CHARSELECT
	char_timer = 30.0
	_last_char_sec = -1
	# exe: pick random player
	var ids := players.keys()
	exe_nid = ids.pick_random()
	if test_role == "s":
		exe_nid = -1
	elif test_role.is_empty():
		for p in players.values():
			if p.get("force_exe", false):
				exe_nid = p.nid
				p.erase("force_exe")
				break
	var ex := _pkt(NetPackets.SERVER_LOBBY_EXE)
	ex.put_u16(65535 if exe_nid < 0 else exe_nid)
	ex.put_u16(chosen_map)
	_broadcast(ex)
	if players.has(exe_nid):
		log_line("(LOBBY.C:390)", "%s IS THE EXE!" % players[exe_nid].nickname, COL_RED)


func _start_game() -> void:
	exit_index = -1
	exit_ready = false
	exit_age = 0
	escape_end_frame = -1
	round_ending = false
	round_had_survivors = false
	for player in players.values():
		round_had_survivors = round_had_survivors or player.get("char", -1) > 0
	server_state = S.GAMESTART
	var gs := _pkt(NetPackets.SERVER_LOBBY_GAME_START)
	gs.put_u8(int(not test_role.is_empty()))
	_broadcast(gs)
	round_records.clear()
	# the SERVER owns the game state (the original's netcode trusted the
	# clients — rebuilt as server-authoritative): hp/rings/revival/death
	# timers live here and flow to the puppets through the PLAYER_DATA relay
	for nid: int in players:
		round_records[nid] = players[nid]
		players[nid].erase("palette_packets")
		players[nid].stats = {
			"rings": 0,
			"kills": 0,
			"damage": 0,
			"taken": 0,
			"stun_time": 0,
			"stuns": 0,
			"healed": 0,
			"survival": 0,
			"danger": 0
		}
		players[nid].quit = false
		players[nid].escaped = false
		players[nid].in_round = true
		players[nid].ring_sync = false
		players[nid].hp = 5
		players[nid].rings = 0
		players[nid].revival = 0
		players[nid].is_dead = false
		players[nid].dead_timer = -1
		players[nid].red_ring = 0
		players[nid].hurttime = 0
		players[nid].heal_cd = 0
		players[nid].stunned_ticks = 0
		players[nid].position_ready = false
		players[nid].last_x = 0
		players[nid].last_y = 0
	character_rules.reset()
	exetior_rules.reset()
	if chosen_map == 20:
		var points = active_map.objects("obj_blackring_spawner")
		for id in points.size():
			exetior_rules.rings[50000 + id] = {
				"owner": 0,
				"at": Vector2(points[id].position[0], points[id].position[1]),
				"born": -30,
				"purple": false
			}
	exeller_rules.reset()
	ring_states.clear()
	var counts: Dictionary = preload("res://src/data/maps.gd").table("ring_spawners")
	for i in int(counts.get(str(chosen_map), 0)):
		ring_states.append({"timer": randi_range(180, 2700), "uid": -1, "red": false})
	game_ticks = 60 * 300  # the 5-minute round in 1/60 s ticks
	if chosen_map in [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]:
		var survivors := 0
		for p in players.values():
			if p.char > 0:
				survivors += 1
		game_ticks = 60 * active_map.duration_seconds(chosen_map, survivors)
	_game_frame = 0
	active_map.reset()
	set_meta("np_fast", false)
	if chosen_map in [1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]:
		var initial_clock := _pkt(NetPackets.SERVER_GAME_TIME_SYNC)
		initial_clock.put_u16(game_ticks)
		_broadcast(initial_clock)
	log_line("(GAME.C:220)", "GAME STARTED ON MAP %d." % chosen_map, COL_GREEN)
	# the round now RUNS (the timer sync + the death timers tick); the results
	# flow (SERVER_RESULTS) replaces the old 4-second boot later


func _maybe_start_game() -> void:
	if server_state != S.CHARSELECT:
		return
	for nid: int in players:
		if players[nid].char == -1:
			return
	if not players.is_empty():
		_start_game()


func _begin_countdown() -> void:
	if countdown >= 0:
		return
	countdown = 4.0
	_last_cd = 4
	var cd := _pkt(NetPackets.SERVER_LOBBY_COUNTDOWN)
	cd.put_u8(1)
	cd.put_u8(4)
	_broadcast(cd)


func _on_disconnect(peer: ENetPacketPeer) -> void:
	for nid: int in players:
		if players[nid].peer == peer:
			log_line(
				"(SERVER.C:301)",
				"PLAYER LEFT: %s (NID %d)" % [players[nid].nickname, nid],
				COL_YELLOW
			)
			if round_records.has(nid):
				round_records[nid].quit = true
			players.erase(nid)
			lobby_votes.erase(nid)
			var pl := _pkt(NetPackets.SERVER_PLAYER_LEFT)
			pl.put_u16(nid)
			_broadcast(pl)
			# practice/game session with nobody left → reset to lobby so the
			# next joiner gets a normal flow
			if players.is_empty():
				server_state = S.WAITING
				practice = false
				test_role = ""
				chat_commands.reset()
				exe_nid = -1
				log_line("(LOBBY.C:297)", "SERVER IS NOW IN LOBBY.", COL_YELLOW)
			if server_state == S.CHARSELECT:
				if nid == exe_nid:
					back_to_lobby()
				else:
					_maybe_start_game()
			elif server_state == S.LOBBY:
				_maybe_start_vote()
			elif server_state == S.VOTE:
				_shorten_vote()
			if server_state == S.WAITING:
				_check_lobby_start()
			elif server_state == S.GAMESTART:
				_check_round_end()
			return


# ---------------------------------------------------------------- ticks
func _state_tick(delta: float) -> void:
	match server_state:
		S.LOBBY:
			_maybe_start_vote()
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
			_shorten_vote()
			vote_timer -= delta
			# one sync packet per second (the client plays snd_clock on every
			# packet with voteTimer <= 3 — a per-frame broadcast is a machine-gun)
			var vsec := ceili(vote_timer)
			if vsec != _last_vote_sec:
				_last_vote_sec = vsec
				var ts := _pkt(NetPackets.SERVER_VOTE_TIME_SYNC)
				ts.put_u8(clampi(vsec, 0, 255))
				_broadcast(ts)
			if vote_timer <= 0.0:
				_finish_vote()
		S.CHARSELECT:
			char_timer -= delta
			# one sync per second (the client beeps on every packet <= 3s)
			var csec := ceili(char_timer)
			if csec != _last_char_sec:
				_last_char_sec = csec
				var ts := _pkt(NetPackets.SERVER_CHAR_TIME_SYNC)
				ts.put_u8(clampi(csec, 0, 255))
				_broadcast(ts)
			if char_timer <= 0.0:
				# auto-assign random free characters
				for nid: int in players:
					if players[nid].char == -1:
						if nid == exe_nid:
							players[nid].char = 0
							players[nid].exechar = randi() % 4
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
				_maybe_start_game()
		S.RESULTS:
			results_ticks -= 1
			if results_ticks <= 0:
				back_to_lobby()
		S.GAMESTART:
			_game_frame += 1
			if round_ending:
				if _game_frame >= escape_end_frame:
					_start_results()
				return
			_tick_exit()
			_tick_rings()
			character_rules.tick()
			profile_rules.tick()
			chaos_rules.tick()
			exetior_rules.tick()
			exeller_rules.tick()
			active_map.tick()
			# per-player authoritative state tick (in practice nobody reports
			# hurts — the loop is a harmless no-op, the clock below still runs)
			for nid: int in players:
				var p: Dictionary = players[nid]
				if not p.get("in_round", false):
					continue
				if p.get("char", 0) > 0 and p.get("revival", 0) < 2 and not p.get("is_dead", false):
					_stat(p, "survival", 1)
					if _exe_near_dead_player(p):
						_stat(p, "danger", 1)
				if p.get("stunned_ticks", 0) > 0:
					p.stunned_ticks -= 1
					_stat(p, "stun_time", 1)
				if p.hurttime > 0:
					p.hurttime -= 1
				if p.heal_cd > 0:
					p.heal_cd -= 1
				if p.red_ring > 0:
					p.red_ring -= 1
				if p.is_dead:
					var exe_near := _exe_near_dead_player(p)
					if not exe_near:
						p.dead_timer -= 1
					# Use a running clock for sync: a frozen timer must still publish proximity changes.
					if _game_frame % 60 == 0 or p.get("death_near", -1) != int(exe_near):
						p.death_near = int(exe_near)
						var dt := _pkt(NetPackets.SERVER_GAME_DEATHTIMER_TICK)
						dt.put_u8(1 if exe_near else 0)
						dt.put_u16(nid)
						dt.put_u8(clampi(int(ceili(p.dead_timer / 60.0)), 0, 255))
						_broadcast(dt)
					if p.dead_timer <= 0:
						var de := _pkt(NetPackets.SERVER_GAME_DEATHTIMER_END)
						if p.revival < 1:
							# First expiry removes the revival window; the player stays down.
							p.hp = 0
							p.revival = 1
							p.dead_timer = 1860
							de.put_u8(0)
						else:
							p.is_dead = false
							p.hp = 5
							p.revival = 2
							character_rules.reset_player(p)
							p.hurttime = 120
							de.put_u8(1)
						_send(p.peer, de)
			_check_round_end()
			if round_ending:
				return
			# the round timer: one SERVER_GAME_TIME_SYNC per second
			if game_ticks > 0:
				game_ticks -= 1
			if _game_frame % 60 == 0:
				var ts := _pkt(NetPackets.SERVER_GAME_TIME_SYNC)
				ts.put_u16(game_ticks)
				_broadcast(ts)
				log_line(
					"(GAME.C:230)",
					"TIME_SYNC ticks=%d frame=%d" % [game_ticks, _game_frame],
					COL_GRAY
				)
			if game_ticks <= 0:
				var escaped := false
				for survivor in players.values():
					escaped = escaped or survivor.get("escaped", false)
				_finish_round(
					(
						NetPackets.SERVER_GAME_SURVIVOR_WIN
						if escaped
						else NetPackets.SERVER_GAME_TIME_OVER
					)
				)
				return


func _finish_vote() -> void:
	# tally votes
	var counts := [0, 0, 0]
	for nid: int in lobby_votes:
		counts[lobby_votes[nid]] += 1
	var best := 0
	if counts[1] > counts[best]:
		best = 1
	if counts[2] > counts[best]:
		best = 2
	chosen_map = vote_map[best]
	log_line("(VOTE.C:201)", "MAP %d WON THE VOTE." % chosen_map, COL_GREEN)
	_start_charselect()


# ---------------------------------------------------------------- commands from UI
func ui_force_back_to_lobby() -> void:
	if server_state == S.WAITING:
		log_line("UI", "NO ACTIVE LOBBY.", COL_YELLOW)
		return
	back_to_lobby()


func ui_force_exe_win() -> void:
	if server_state != S.GAMESTART or round_ending:
		log_line("UI", "NO ACTIVE ROUND.", COL_YELLOW)
		return
	_finish_round(NetPackets.SERVER_GAME_EXE_WINS)


func ui_force_escape() -> void:
	if server_state != S.GAMESTART or round_ending:
		log_line("UI", "NO ACTIVE ROUND.", COL_YELLOW)
		return
	_finish_round(NetPackets.SERVER_GAME_SURVIVOR_WIN)


func toggle_option(key: String) -> void:
	var v = config.get(key)
	match typeof(v):
		TYPE_BOOL:
			config[key] = not v
			log_line(
				"(CONFIG.C:%d)" % (randi() % 300 + 100),
				"%s IS NOW %s." % [key.to_upper(), "ENABLED" if config[key] else "DISABLED"],
				COL_YELLOW
			)
		TYPE_INT, TYPE_FLOAT:
			log_line("(CONFIG.C:99)", "EDIT %s IN CONFIG.JSON (USER APPDATA FOLDER).", COL_GRAY)
		_:
			log_line("(CONFIG.C:99)", "EDIT %s IN CONFIG.JSON (USER APPDATA FOLDER).", COL_GRAY)
	save_all()


func save_all() -> void:
	_save_config()


func _on_disconnect_signal() -> void:
	pass


func _tick_rings() -> void:
	for iid in ring_states.size():
		var ring: Dictionary = ring_states[iid]
		if ring.timer <= 0:
			continue
		ring.timer -= 1
		if ring.timer == 0:
			next_ring_uid = (next_ring_uid + 1) % 65536
			ring.uid = next_ring_uid
			ring.red = randf() < 0.08
			var b := _pkt(NetPackets.SERVER_RING_STATE)
			b.put_u8(0)
			b.put_u8(iid)
			b.put_u16(ring.uid)
			b.put_u8(1 if ring.red else 0)
			_broadcast(b)


func _ring_valid(iid: int, uid: int) -> bool:
	return (
		iid >= 0
		and iid < ring_states.size()
		and ring_states[iid].timer == 0
		and ring_states[iid].uid == uid
	)


func _shorten_vote() -> void:
	if (
		server_state == S.VOTE
		and not players.is_empty()
		and lobby_votes.size() == players.size()
		and vote_timer > 3.0
	):
		vote_timer = 3.0
		_last_vote_sec = 3
		var b := _pkt(NetPackets.SERVER_VOTE_TIME_SYNC)
		b.put_u8(3)
		_broadcast(b)


func _exe_near_dead_player(victim: Dictionary) -> bool:
	if not players.has(exe_nid) or not victim.get("position_ready", false):
		return false
	var killer: Dictionary = players[exe_nid]
	if not killer.get("in_round", false) or not killer.get("position_ready", false):
		return false
	return (
		Vector2(victim.last_x, victim.last_y).distance_squared_to(
			Vector2(killer.last_x, killer.last_y)
		)
		<= DEATH_PAUSE_RADIUS * DEATH_PAUSE_RADIUS
	)


func _apply_survivor_damage(
	plr: Dictionary, damage: int, attacker := -1, blood_effect := 2
) -> void:
	if (
		damage <= 0
		or damage > 5
		or plr.char == 0
		or plr.revival >= 2
		or plr.is_dead
		or plr.hp <= 0
		or plr.hurttime > 0
	):
		return
	if character_rules.break_sally_shield(plr):
		return
	active_map.drop(plr)
	active_map.release(plr)
	var had_rings: bool = plr.rings > 0
	var actual: int = mini(plr.hp, damage)
	if players.has(attacker):
		var source: Dictionary = players[attacker]
		if source.char == 0 and source.get("exechar", 0) == 1 and source.get("move_state", 0) == 14:
			profile_rules.event(source, "bonus", 10)
	_stat(plr, "taken", actual)
	if players.has(attacker):
		_stat(players[attacker], "damage", actual)
		if damage >= plr.hp:
			_stat(players[attacker], "kills", 1)
	plr.hp = maxi(0, plr.hp - damage)
	plr.rings = 0
	plr.hurttime = 60 if game_ticks < 3600 else 180
	if plr.hp == 0:
		plr.is_dead = true
		plr.dead_timer = 1860
		plr.death_near = -1
	if players.has(attacker):
		# scr_player_hurt / scr_player_instakill choose this after applying HP.
		# Only accepted hits emit; the victim already played its predicted sound.
		var sound := _pkt(NetPackets.CLIENT_SOUND_EMIT, true)
		sound.put_u16(plr.nid)
		sound.put_u8(2 if plr.hp == 0 else (6 if had_rings else 9))
		sound.put_u8(0)
		_broadcast(sound, plr.nid)

	if plr.get("position_ready", false):
		var effect := _pkt(NetPackets.CLIENT_SPAWN_EFFECT)
		effect.put_u16(plr.last_x)
		effect.put_u16(plr.last_y)
		effect.put_u8(0)  # play the animation once, without fading
		var direction := 1
		if players.has(attacker) and players[attacker].get("position_ready", false):
			direction = -1 if plr.last_x < players[attacker].last_x else 1
		effect.put_8(direction)
		effect.put_u8(3 if plr.hp == 0 else blood_effect)
		effect.put_8(0)
		effect.put_8(0)
		effect.put_float(1.0)
		# The victim already spawned the predicted local blood / death effect.
		_broadcast(effect, plr.nid)


func _tick_exit() -> void:
	if exit_index < 0 and game_ticks <= 3600:
		var points: Dictionary = preload("res://src/data/maps.gd").table("exit_spawns")
		var positions: Array = points.get(str(chosen_map), [])
		if positions.is_empty():
			return
		exit_index = randi_range(0, positions.size() - 1)
		exit_position = Vector2(positions[exit_index][0], positions[exit_index][1])
		var spawn := _pkt(NetPackets.SERVER_GAME_SPAWN_RING)
		spawn.put_u8(0)
		spawn.put_u8(exit_index)
		_broadcast(spawn)
		return  # opening delay starts after the spawn frame
	if chosen_map == 1 and exit_index >= 0 and exit_ready and not active_map.can_escape():
		exit_ready = false
		var close_exit := _pkt(NetPackets.SERVER_GAME_SPAWN_RING)
		close_exit.put_u8(0)
		_broadcast(close_exit)
	if exit_index >= 0 and not exit_ready:
		exit_age += 1
		if exit_age >= 600 and active_map.can_escape():
			exit_ready = true
			var ready := _pkt(NetPackets.SERVER_GAME_SPAWN_RING)
			ready.put_u8(1)
			_broadcast(ready)


func _finish_round(result: int) -> void:
	if server_state != S.GAMESTART or round_ending:
		return
	round_ending = true
	escape_end_frame = _game_frame + 420
	round_duration = _game_frame / 60
	round_result = (
		1
		if result == NetPackets.SERVER_GAME_SURVIVOR_WIN
		else (2 if result == NetPackets.SERVER_GAME_TIME_OVER else 0)
	)
	var packet := _pkt(result)
	packet.put_u8(int(test_role.is_empty() and not practice))
	_broadcast(packet)
	log_line("(GAME.C:400)", "ROUND FINISHED.", COL_YELLOW)


func _check_round_end() -> void:
	if server_state != S.GAMESTART or round_ending:
		return
	var had_survivors := round_had_survivors
	var remaining := false
	var escaped := false
	for player in players.values():
		if player.get("char", -1) <= 0:
			continue
		had_survivors = (
			had_survivors or player.get("in_round", false) or player.get("escaped", false)
		)
		escaped = escaped or player.get("escaped", false)
		if (
			player.get("in_round", false)
			and player.get("revival", 0) < 2
			and not player.get("is_dead", false)
			and player.get("hp", 0) > 0
		):
			remaining = true
	if had_survivors and not remaining:
		_finish_round(
			NetPackets.SERVER_GAME_SURVIVOR_WIN if escaped else NetPackets.SERVER_GAME_EXE_WINS
		)
	elif had_survivors and test_role.is_empty() and not players.has(exe_nid):
		_finish_round(NetPackets.SERVER_GAME_SURVIVOR_WIN)


func _stat(player: Dictionary, key: String, amount: int) -> void:
	if player.has("stats"):
		player.stats[key] = player.stats.get(key, 0) + amount
	profile_rules.stat(player, key, amount)


func _start_results() -> void:
	server_state = S.RESULTS
	results_ticks = 900
	var packet := _pkt(NetPackets.SERVER_RESULTS)
	packet.put_u8(chosen_map)
	_broadcast(packet)


func _send_results(peer: ENetPacketPeer) -> void:
	for player in round_records.values():
		var packet := _pkt(NetPackets.SERVER_RESULTS_DATA)
		_put_str(packet, player.get("nickname", "player"))
		packet.put_8(player.get("exechar", 0) if player.char == 0 else player.char - 1)
		packet.put_u8(round_result)
		packet.put_u16(clampi(round_duration, 0, 65535))
		packet.put_u8(1 if player.get("quit", false) else 0)
		var type := (
			0
			if player.char == 0
			else (
				4
				if player.get("escaped", false)
				else (
					1
					if player.get("revival", 0) >= 2
					else (2 if player.get("is_dead", false) else 3)
				)
			)
		)
		packet.put_u8(type)
		var stats: Dictionary = player.get("stats", {})
		for key in ["rings", "kills", "damage", "taken", "stun_time", "stuns", "healed"]:
			var value: int = stats.get(key, 0)
			packet.put_u16(clampi(value / 60 if key == "stun_time" else value, 0, 65535))
		packet.put_double(float(stats.get("survival", 0)))
		packet.put_double(float(stats.get("danger", 0)))
		_send(peer, packet)


func _enabled_maps() -> Array:
	var enabled: Array = []
	var selected = config.get("maps", PLAYABLE_MAPS)
	if not selected is Array:
		return enabled
	for value in selected:
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or value != int(value):
			continue
		var id := int(value)
		if id in PLAYABLE_MAPS and not enabled.has(id):
			enabled.append(id)
	return enabled
