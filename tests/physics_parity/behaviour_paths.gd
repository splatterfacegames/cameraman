extends SceneTree
## Records the camera's position frame by frame for the third-person follow with collision and for
## the deoccluder, while a target walks past pillars, backs into a wall and passes under a low
## ceiling. Run once per physics engine and compare the files with compare_paths.py.
##
## godot --headless --path <project> -s res://tests/physics_parity/behaviour_paths.gd -- --out=<file>

const ParityWorld: GDScript = preload("res://tests/physics_parity/parity_world.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world: Node3D = Node3D.new()
	root.add_child(world)
	ParityWorld.build_world(world)
	var target: Array[Node3D] = ParityWorld.build_target(world)
	var rigs: Dictionary = {
		"third_person_follow": ParityWorld.build_follow_rig(world, target[0], true),
		"deoccluder": ParityWorld.build_deoccluder_rig(world, target[1], true),
	}
	var recorded: Dictionary = {}
	for path in ParityWorld.path_names():
		target[0].global_transform = ParityWorld.path_transform(path, 0)
		await physics_frame
		await physics_frame
		for rig_name in rigs:
			var camera: CameramanCamera = rigs[rig_name]
			camera.previous_state_is_valid = false
			CameramanCore.notify_target_warped(target[0], Vector3.ZERO)
			recorded["%s/%s" % [rig_name, path]] = []
		var target_track: Array = []
		for frame in ParityWorld.path_frames(path):
			target[0].global_transform = ParityWorld.path_transform(path, frame)
			await physics_frame
			target_track.append(_vec(target[0].global_position))
			for rig_name in rigs:
				var camera: CameramanCamera = rigs[rig_name]
				camera.update_state(Vector3.UP, ParityWorld.FRAME)
				(recorded["%s/%s" % [rig_name, path]] as Array).append(_vec(camera.get_state().get_final_position()))
		recorded["target/%s" % path] = target_track
	var out_path: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			out_path = argument.trim_prefix("--out=")
	var document: Dictionary = {
		"engine": String(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")),
		"frame_seconds": ParityWorld.FRAME,
		"paths": recorded,
	}
	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(document))
	file.close()
	print("behaviour: wrote %d tracks to %s" % [recorded.size(), out_path])
	quit(0)

func _vec(value: Vector3) -> Array:
	return [snappedf(value.x, 0.00001), snappedf(value.y, 0.00001), snappedf(value.z, 0.00001)]
