extends RefCounted
## Chat commands recovered from BetterServer v1101; authority belongs to host.
var host: Node
var vote: Dictionary = {}
var pending: Dictionary = {}
var cooldown: Dictionary = {}
const Maps = preload("res://src/data/maps.gd")
var MAP_NAMES: Array = Maps.names()


func _init(server):
	host = server


func is_op(p: Dictionary) -> bool:
	return host.operators.has(str(p.get("ip", "")))


func message(p: Dictionary, text: String):
	var b = host._pkt(NetPackets.CLIENT_CHAT_MESSAGE)
	b.put_u16(0)
	host._put_str(b, text)
	host._send(p.peer, b)


func broadcast(text: String):
	var b = host._pkt(NetPackets.CLIENT_CHAT_MESSAGE)
	b.put_u16(0)
	host._put_str(b, text)
	host._broadcast(b)


func info(p: Dictionary):
	message(
		p,
		(
			"server \\%d~ of /%d~"
			% [int(host.config.get("lobby_index", 1)), int(host.config.get("server_count", 1))]
		)
	)
	message(p, "-----------------------")
	message(p, "\\better/server~ godot build &%d~" % host.BUILD_VER)
	for line in str(host.config.get("motd", "")).split("\n"):
		if not line.is_empty():
			message(p, line)
	message(p, "-----------------------")
	message(p, "|type .help for command list~")


func intro(p: Dictionary):
	if p.get("intro_sent", false):
		return
	p.intro_sent = true
	message(p, "-----------------------")
	message(p, "\\better/server~ v%d" % host.BUILD_VER)
	message(p, "build @godot~")
	message(
		p,
		(
			"server \\%d~ of /%d~"
			% [int(host.config.get("lobby_index", 1)), int(host.config.get("server_count", 1))]
		)
	)
	message(p, "-----------------------")
	message(p, "|type .help for command list~")
	for line in str(host.config.get("motd", "")).split("\n"):
		if not line.is_empty():
			message(p, line)
	if is_op(p):
		message(p, "@you're an operator on this server~")
	if not host.config.get("anticheat", false):
		message(p, "`Anticheat is disabled, client modifications are allowed.")


func reset():
	vote.clear()
	pending.clear()


func tick(dt: float):
	for id in cooldown.keys():
		cooldown[id] = maxf(0, float(cooldown[id]) - dt)
		if cooldown[id] <= 0:
			cooldown.erase(id)
	for id in pending.keys():
		pending[id].time -= dt
		if pending[id].time <= 0:
			pending.erase(id)
	if not vote.is_empty():
		vote.time -= dt
		if vote.time <= 0:
			finish_vote()


func handle(p: Dictionary, text: String) -> bool:
	if text == "i want big burgr" and host.server_state in [host.S.WAITING, host.S.LOBBY]:
		if is_op(p):
			p.force_exe = true
			var chance = host._pkt(NetPackets.SERVER_LOBBY_EXE_CHANCE)
			chance.put_u8(101)
			host._send(p.peer, chance)
		message(p, "|you were sent to \\brazil~")
		return true
	var parts = text.strip_edges().to_lower().split(" ", false)
	var cmd = str(parts[0]) if not parts.is_empty() else ""
	match cmd:
		".help":
			message(p, "|.lobby~ choose lobby (1-%d)" % int(host.config.get("server_count", 1)))
			message(p, "|.info~ server info")
			if host.server_state in [host.S.WAITING, host.S.LOBBY]:
				message(p, "|.vk~ vote kick / |.vp~ practice mode")
				message(p, "|.test k/s~ solo test as killer/survivor (no progress)")
				if is_op(p):
					message(p, "|.map~ choose map (1-21)")
			if is_op(p):
				for line in [
					"|.kick~ kick someone ig", "|.ban~ ban someone ig", "|.op~ op someone ig"
				]:
					message(p, line)
		".info":
			info(p)
		".test":
			if parts.size() != 2 or parts[1] not in ["k", "s"]:
				message(p, "\\usage:~ .test k / .test s")
			elif (
				host.server_state not in [host.S.WAITING, host.S.LOBBY] or host.players.size() != 1
			):
				message(p, "\\test requires exactly one player in the lobby")
			elif host._enabled_maps().is_empty():
				message(p, "\\no maps enabled")
			else:
				message(p, "|solo test: no achievements, money or EXE chance changes~")
				host.start_solo_test(str(parts[1]))
		".stink":
			if parts.size() < 2:
				message(p, "\\example:~ .stink baller")
			else:
				broadcast("\\%s~, you /sti@nk~" % str(parts[1]).left(35))
		".lobby":
			var index = int(parts[1]) if parts.size() > 1 and parts[1].is_valid_int() else 0
			if parts.size() < 2:
				message(p, "\\example:~ .lobby 1")
			elif index < 1 or index > int(host.config.get("server_count", 1)):
				message(
					p,
					"\\lobby should be between 1 and %d" % int(host.config.get("server_count", 1))
				)
			else:
				var b = host._pkt(NetPackets.SERVER_LOBBY_CHANGELOBBY)
				b.put_32(int(host.config.get("port", 8606)) + index - 1)
				host._send(p.peer, b)
		".map":
			if not is_op(p):
				message(p, "\\you aren't an operator")
			elif host.server_state not in [host.S.WAITING, host.S.LOBBY]:
				message(p, "\\map can only be selected in the lobby")
			elif parts.size() < 2:
				message(p, "\\example:~ .map 1")
			elif not parts[1].is_valid_int() or int(parts[1]) < 1 or int(parts[1]) > 21:
				message(p, "\\map should be between 1 and 21")
			else:
				host.start_selected_map(int(parts[1]) - 1)
		".kick", ".ban", ".op":
			if not is_op(p):
				message(p, "\\you aren't an operator.")
			else:
				choose(p, cmd.trim_prefix("."))
		".vk":
			if lobby_only(p) and can_vote(p):
				if host.players.size() < 3:
					message(p, "\\not enough participants.")
				else:
					choose(p, "vk")
		".vp":
			if lobby_only(p) and can_vote(p):
				start_vote(p, "practice", -1)
		".yes", ".y":
			cast(p)
		_:
			return false
	return true


func lobby_only(p: Dictionary) -> bool:
	if host.server_state in [host.S.WAITING, host.S.LOBBY]:
		return true
	message(p, "\\this vote is only available in the lobby")
	return false


func can_vote(p: Dictionary) -> bool:
	if not vote.is_empty():
		message(p, "\\another vote is already in progress.")
		return false
	if float(cooldown.get(p.nid, 0)) > 0:
		message(p, "\\you cannot start another vote for %d s" % ceili(cooldown[p.nid]))
		return false
	return true


func choose(p: Dictionary, action: String):
	if host.players.size() < 2:
		message(p, "\\not enough participants.")
		return
	pending[p.nid] = {"action": action, "time": 30.0}
	var type = {
		"kick": NetPackets.SERVER_LOBBY_CHOOSEKICK,
		"ban": NetPackets.SERVER_LOBBY_CHOOSEBAN,
		"op": NetPackets.SERVER_LOBBY_CHOOSEOP,
		"vk": NetPackets.SERVER_LOBBY_CHOOSEVOTEKICK
	}[action]
	host._send(p.peer, host._pkt(type))


func target(p: Dictionary, type: int, id: int):
	var action = str(
		(
			{
				NetPackets.CLIENT_LOBBY_CHOOSEKICK: "kick",
				NetPackets.CLIENT_LOBBY_CHOOSEBAN: "ban",
				NetPackets.CLIENT_LOBBY_CHOOSEOP: "op",
				NetPackets.CLIENT_LOBBY_CHOOSEVOTEKICK: "vk"
			}
			. get(type, "")
		)
	)
	if not pending.has(p.nid) or pending[p.nid].action != action:
		return
	pending.erase(p.nid)
	if not host.players.has(id):
		message(p, "\\specified player not found.")
		return
	if id == p.nid:
		message(p, "\\why are you kicking yourself ???")
		return
	var other: Dictionary = host.players[id]
	if action == "vk":
		if is_op(other):
			message(p, "\\you're permissionless")
			return
		if lobby_only(p) and can_vote(p):
			start_vote(p, "kick", id)
	elif not is_op(p):
		message(p, "\\you aren't an operator.")
	elif action == "op":
		if is_op(other):
			message(p, "\\you're already an operator tho??")
			return
		host.operators[str(other.ip)] = str(other.nickname)
		host._save_config()
		message(other, "@you're an operator now")
	else:
		remove(other, action == "ban")


func remove(p: Dictionary, ban: bool, reason: String = ""):
	if ban:
		for value in [str(p.get("udid", "")), "ip:" + str(p.get("ip", ""))]:
			if not value.is_empty() and not host.bans.has(value):
				host.bans.append(value)
		host._save_config()
	var b = host._pkt(NetPackets.SERVER_PLAYER_FORCE_DISCONNECT)
	host._put_str(
		b,
		(
			reason
			if not reason.is_empty()
			else "You are banned from this server." if ban else "You were kicked from the server."
		)
	)
	host._send(p.peer, b)
	if p.peer != null:
		p.peer.peer_disconnect_later()
	host._on_disconnect(p.peer)


func start_vote(p: Dictionary, kind: String, id: int):
	var eligible = []
	for player in host.players.values():
		if int(player.nid) != id:
			eligible.append(int(player.nid))
	if eligible.size() < 2:
		message(p, "\\not enough participants.")
		return
	vote = {"kind": kind, "target": id, "eligible": eligible, "yes": [int(p.nid)], "time": 20.0}
	cooldown[p.nid] = 30.0
	broadcast("-----------------------")
	broadcast(
		(
			"%s~ `started practice vote.~" % p.nickname
			if kind == "practice"
			else "%s~ \\started kick vote for ~%s~" % [p.nickname, host.players[id].nickname]
		)
	)
	broadcast("type @.yes~ or ignore")
	broadcast("results will be summarized in |20~ sec")
	broadcast("-----------------------")


func cast(p: Dictionary):
	if vote.is_empty() or not vote.eligible.has(int(p.nid)):
		message(p, "\\you can't participate in this vote.")
		return
	if vote.yes.has(int(p.nid)):
		message(p, "\\you have already voted.")
		return
	vote.yes.append(int(p.nid))
	broadcast("%s~ @voted~." % p.nickname)
	if vote.yes.size() >= vote.eligible.size():
		finish_vote()


func finish_vote():
	if vote.is_empty():
		return
	var result = vote.duplicate(true)
	vote.clear()
	var passed = result.yes.size() > result.eligible.size() * .5
	broadcast(
		(
			"vote %s %s~ (@%d ~from \\%d~)"
			% [
				result.kind,
				"@succeeded" if passed else "\\failed",
				result.yes.size(),
				result.eligible.size()
			]
		)
	)
	if passed:
		if result.kind == "practice":
			host.practice_mode()
		elif host.players.has(result.target):
			remove(host.players[result.target], false)
