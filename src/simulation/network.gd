class_name SimulationNetwork
extends RefCounted
const PacketType = preload("res://src/net_packets.gd")
const STATE_GAME := 4
var state := STATE_GAME
var gameEnds := false
var lvlId := 0
var nid := 0
var held := 0
var pressed := 0
var released := 0
var host: Node
var player: Dictionary
var pending: Array[StreamPeerBuffer] = []
var pending_states: Array[int] = []
var event_state := -1
var effect_node: SimulationNode
var players := {}


func cpacket_tcp(type: int, passthrough := false) -> StreamPeerBuffer:
	var b := StreamPeerBuffer.new()
	b.big_endian = false
	b.put_u8(int(passthrough))
	b.put_u8(type)
	return b


func send_server_tcp(b: StreamPeerBuffer):
	pending.append(b)
	pending_states.append(event_state)
	event_state = -1


func _send_player_data(state_override := -1):
	event_state = state_override


func character_sound(_sound: String, _at: Vector2):
	pass


func report_spring_use(_at: Vector2):
	pass


func before_player(actor: Node):
	host.motion.world.before_player(actor)


func spawn_black_ring(_owner: int, _at: Vector2):
	pass


func spawn_exetior_waves(_at: Vector2):
	pass


func report_sally_shield(activate: bool):
	var b := cpacket_tcp(PacketType.CLIENT_SALLY_SHIELD)
	b.put_u8(int(activate))
	send_server_tcp(b)


func report_egg_shield():
	send_server_tcp(cpacket_tcp(PacketType.CLIENT_EGG_SHIELD))


func report_egg_tracker(at: Vector2):
	_send_player_data(8)
	var b := cpacket_tcp(PacketType.CLIENT_ETRACKER)
	b.put_16(int(at.x))
	b.put_16(int(at.y))
	send_server_tcp(b)


func report_cream_rings(at: Vector2, demon: bool):
	_send_player_data(15)
	var b := cpacket_tcp(PacketType.CLIENT_CREAM_SPAWN_RINGS)
	b.put_16(int(at.x))
	b.put_16(int(at.y))
	b.put_u8(int(demon))
	send_server_tcp(b)


func request_exeller_clone():
	var b := cpacket_tcp(PacketType.CLIENT_EXELLER_SPAWN_CLONE)
	b.put_16(int(player.last_x))
	b.put_16(int(player.last_y))
	b.put_8(player.facing)
	send_server_tcp(b)


func request_clone_teleport(id: int):
	var b := cpacket_tcp(PacketType.CLIENT_EXELLER_TELEPORT_CLONE)
	b.put_u16(id)
	send_server_tcp(b)


func flush():
	var events := pending.duplicate()
	var poses := pending_states.duplicate()
	pending.clear()
	pending_states.clear()
	for index in events.size():
		var old_state: int = player.move_state
		if poses[index] >= 0:
			player.move_state = poses[index]
		host._process_packet(player.get("peer"), events[index].data_array, true)
		player.move_state = old_state
