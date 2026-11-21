extends RefCounted
var host
var interactions: Dictionary = {}


func _init(server):
	host = server


func living(p: Dictionary) -> bool:
	return (
		p.get("in_round", false)
		and p.get("position_ready", false)
		and p.char > 0
		and p.get("revival", 0) < 2
		and not p.get("is_dead", false)
		and p.hp > 0
	)


func tick():
	if host.round_ending:
		return
	var active: Dictionary = {}
	for p in host.players.values():
		if (
			not living(p)
			or p.get("hurttime", 0) > 0
			or p.get("stunned_ticks", 0) > 0
			or p.get("red_ring", 0) > 0
		):
			continue
		var pose = int(p.get("move_state", 0))
		if pose not in [7, 8] or p.rings < (3 if pose == 8 else 10):
			continue
		for target in host.players.values():
			if (
				target.nid == p.nid
				or target.char == 0
				or not target.get("in_round", false)
				or not target.get("position_ready", false)
			):
				continue
			if absf(p.last_x - target.last_x) > 16 or absf(p.last_y - target.last_y) > 36:
				continue
			var revival = (
				pose == 8 and target.get("is_dead", false) and target.get("revival", 0) == 0
			)
			var healing = pose == 7 and living(target) and target.hp < 5
			if not revival and not healing:
				continue
			var key = str(p.nid) + ":" + str(target.nid) + ":" + str(pose)
			if healing and int(float(interactions.get(key, 0)) * 100) % 32 == 0:
				var particle = host._pkt(NetPackets.CLIENT_PLAYER_HEAL_PART, true)
				particle.put_16(int(target.last_x))
				particle.put_16(int(target.last_y))
				host._broadcast(particle)
			var amount = (
				float(interactions.get(key, 0))
				+ (0.004 * (p.rings - 3) + 0.015 if revival else 0.016)
			)
			active[key] = amount
			if host._game_frame % 6 == 0:
				interaction_packet(p, target.nid, amount, revival)
			if amount >= 1:
				if revival:
					target.hp = 2
					target.is_dead = false
					target.revival = 1
					target.dead_timer = 0
					target.hurttime = 240
					p.rings = 0
					host._send(target.peer, host._pkt(NetPackets.SERVER_REVIVAL_REVIVED))
					host._send(p.peer, host._pkt(NetPackets.SERVER_REVIVAL_RINGSUB))
				else:
					target.hp += 1
					p.rings -= 10
					host._stat(target, "healed", 1)
					event(p, "heal_other", 1, target.nid)
				host.active_map.owner_stats(p)
				host.active_map.owner_stats(target)
				active.erase(key)
				interaction_packet(p, target.nid, 0, revival)
			break
	for key in interactions:
		if not active.has(key):
			var id = int(str(key).get_slice(":", 0))
			if host.players.has(id):
				interaction_packet(host.players[id], -1, 0, false)
	interactions = active


func interaction_packet(p: Dictionary, target: int, amount: float, revival: bool):
	var b = host._pkt(NetPackets.SERVER_PROFILE_EVENT)
	b.put_data(
		(
			JSON
			. stringify(
				{"kind": "interaction", "target": target, "progress": amount, "revive": revival}
			)
			. to_utf8_buffer()
		)
	)
	host._send(p.peer, b)


func handle(p, type: int, b: StreamPeerBuffer) -> bool:
	if type != NetPackets.CLIENT_PLAYER_PALETTE:
		return false
	if p == null or host.server_state != host.S.GAMESTART or b.get_available_bytes() < 5:
		return true
	var side = b.get_u8()
	var claimed = b.get_u16()
	var label = ""
	while b.get_available_bytes() > 0:
		var ch = b.get_u8()
		if ch == 0:
			break
		label += char(ch)
		if label.length() > 32:
			return true
	if side > 1 or claimed != p.nid or b.get_available_bytes() < 1:
		return true
	var count = b.get_u8()
	if count % 4 != 0 or count > 252 or b.get_available_bytes() != count:
		return true
	var packet = host._pkt(NetPackets.CLIENT_PLAYER_PALETTE, true)
	packet.put_u8(side)
	packet.put_u16(p.nid)
	host._put_str(packet, label)
	packet.put_u8(count)
	packet.put_data(b.get_data(count)[1])
	if not p.has("palette_packets"):
		p.palette_packets = {}
	p.palette_packets[side] = packet.data_array
	host._broadcast(packet, p.nid)
	return true


func snapshot(peer):
	for p in host.players.values():
		for bytes in p.get("palette_packets", {}).values():
			var b = StreamPeerBuffer.new()
			b.data_array = bytes
			host._send(peer, b)


func event(p: Dictionary, kind: String, value := 1, other := -1):
	if (
		not host.test_role.is_empty()
		or not p.get("in_round", false)
		or host.chosen_map not in host.PLAYABLE_MAPS
	):
		return
	var b = host._pkt(NetPackets.SERVER_PROFILE_EVENT)
	b.put_data(JSON.stringify({"kind": kind, "value": value, "other": other}).to_utf8_buffer())
	host._send(p.get("peer"), b)


func stat(p: Dictionary, key: String, value: int):
	if key in ["taken", "healed", "rings"]:
		event(p, key, value)
	if key == "black_rings":
		event(p, "black", value)
	if key == "shards":
		event(p, "shard", value)
	if key == "kills":
		event(p, "bonus", 0 if p.char == 0 else 4)
	if key == "stuns":
		var kind = 1
		if p.char == 1:
			kind = 2
		elif p.char == 4:
			kind = 3 if p.get("revival", 0) >= 2 else 11
		event(p, "bonus", kind, p.get("last_shot_power", 0))
		if p.char == 4 and p.get("revival", 0) < 2:
			event(p, "bonus", 1)
