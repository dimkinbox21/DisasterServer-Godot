class_name SimulationAudio
extends RefCounted
var _sound_pool := []


## Sound and camera feedback have no effect on authoritative physics.
func play_sound(_name: String):
	pass


func stop_sound(_name: String):
	pass


func play_emotion3(_character: int, _hunter: int):
	pass


func crossfade_music(_name: String, _volume: float):
	pass
