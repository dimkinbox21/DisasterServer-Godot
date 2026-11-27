class_name SimulationGlobals
extends RefCounted
const CHARACTER_EXE := 0
const EXE_CHAOS := 1
const EXE_EXETIOR := 2
const EXE_EXELLER := 3
const KeyLeft := 0
const KeyRight := 1
const KeyUp := 2
const KeyDown := 3
const KeyA := 4
const KeyB := 5
const KeyC := 6
const KeyEm1 := 7
const KeyEm2 := 8
const KeyEm3 := 9
const KeyIdle := 10
var character := 0
var exeCharacter := 0
var playerControls := true
var cameraMode := 0
var player: Node
var timeMinutes := 5
var timeSeconds := 0
var palleteName := "default"
