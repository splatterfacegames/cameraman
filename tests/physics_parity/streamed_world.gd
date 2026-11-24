extends SceneTree
## Tarragon only. Bakes a small synthetic streamed world (ground and boxes, one baked collision
## compound per cell, attached to the physics server with no node), streams it in, and checks what
## the camera's queries return against it and that the camera rigs collide with it.
## On an engine without the WorldStreamer singleton it writes {"skipped": true}.
##
## godot --headless --path <project> -s res://tests/physics_parity/streamed_world.gd -- \
##     --out=<file> --world=<scratch directory>

const FRAME: float = 1.0 / 60.0

var _report: Dictionary = {}
var _failures: PackedStringArray = PackedStringArray()

func _initialize() -> void:
	_run.call_deferred()

func _argument(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""

func _check(condition: bool, text: String) -> void:
	if not condition:
		_failures.append(text)

func _finish() -> void:
	_report["engine"] = String(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT"))
	_report["failures"] = _failures
	var file: FileAccess = FileAccess.open(_argument("--out="), FileAccess.WRITE)
	file.store_string(JSON.stringify(_report, "  "))
	file.close()
	print("streamed world: %d failures" % _failures.size())
	for failure in _failures:
		print("  FAILED: ", failure)
	quit(0 if _failures.is_empty() else 1)

func _run() -> void:
	if not Engine.has_singleton("WorldStreamer"):
		_report["skipped"] = true
		_finish()
		return
	var streamer: Object = Engine.get_singleton("WorldStreamer")
	var directory: String = _argument("--world=")
	var bake_error: String = streamer.call("bake_synthetic", directory, 2, 64, 7, 0)
	_check(bake_error.is_empty(), "bake_synthetic: " + bake_error)
	var open_error: int = streamer.call("open_world", directory)
	_check(open_error == OK, "open_world returned %d" % open_error)
	if not _failures.is_empty():
		_finish()
		return
	var mask: int = 0
	for constant in ["WORLD_CLASS_GROUND_CRITICAL", "WORLD_CLASS_COLLISION"]:
		mask |= 1 << ClassDB.class_get_integer_constant("WorldStreamer", constant)
	var ticket: Object = streamer.call("request_sphere", Vector3(64, 0, 64), 60.0, mask, 10.0)
	var waited: int = 0
	while not bool(ticket.call("is_ready")) and waited < 1200:
		streamer.call("tick")
		await process_frame
		waited += 1
	_report["frames_until_ready"] = waited
	_check(bool(ticket.call("is_ready")), "the collision of the first cell did not stream in")
	await physics_frame
	await physics_frame
	var space: PhysicsDirectSpaceState3D = root.get_world_3d().direct_space_state
	var box: Dictionary = _survey(space)
	if box.is_empty():
		_check(false, "no solid box found in the streamed cell")
		_finish()
		return
	await _camera_checks(space, box)
	streamer.call("close_world")
	_finish()

## Rays straight down over the first cell: what a hit on streamed collision looks like, and
## where the tallest solid box is.
func _survey(space: PhysicsDirectSpaceState3D) -> Dictionary:
	var ground_hits: int = 0
	var box_hits: int = 0
	var misses: int = 0
	var with_collider: int = 0
	var with_collider_id: int = 0
	var bodies: Dictionary = {}
	var shapes: Dictionary = {}
	var best: Dictionary = {}
	for xi in range(4, 124, 1):
		for zi in range(4, 124, 1):
			var from: Vector3 = Vector3(float(xi) + 0.37, 30.0, float(zi) + 0.41)
			var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0)
			var hit: Dictionary = space.intersect_ray(query)
			if hit.is_empty():
				misses += 1
				continue
			if hit.get("collider") != null:
				with_collider += 1
			if int(hit.get("collider_id", 0)) != 0:
				with_collider_id += 1
			bodies[hit["rid"]] = true
			shapes[int(hit["shape"])] = true
			var position: Vector3 = hit["position"]
			if position.y > 0.25:
				box_hits += 1
				if best.is_empty() or position.y > (best["position"] as Vector3).y:
					best = hit
			else:
				ground_hits += 1
	_report["survey"] = {
		"rays": 120 * 120, "ground_hits": ground_hits, "box_hits": box_hits, "misses": misses,
		"hits_with_collider_object": with_collider, "hits_with_collider_id": with_collider_id,
		"distinct_bodies": bodies.size(), "shape_indices": shapes.keys(),
	}
	_check(misses == 0, "%d downward rays missed the streamed ground" % misses)
	_check(with_collider == 0, "streamed collision reported a collider object")
	_check(bodies.size() == 1, "expected one body for the cell, found %d" % bodies.size())
	return best

func _rig(parent: Node3D, target: Node3D, mode: String) -> CameramanCamera:
	var camera: CameramanCamera = CameramanCamera.new()
	camera.tracking_target = target
	var follow: CameramanThirdPersonFollow = CameramanThirdPersonFollow.new()
	follow.shoulder_offset = Vector3.ZERO
	follow.camera_distance = 5.0
	follow.avoid_obstacles.enabled = mode == "follow"
	follow.avoid_obstacles.camera_radius = 0.2
	camera.add_child(follow)
	if mode == "deoccluder":
		var deoccluder: CameramanDeoccluder = CameramanDeoccluder.new()
		deoccluder.camera_radius = 0.2
		camera.add_child(deoccluder)
	parent.add_child(camera)
	return camera

func _camera_checks(space: PhysicsDirectSpaceState3D, box: Dictionary) -> void:
	var top: Vector3 = box["position"]
	var body: RID = box["rid"]
	# Stand 3 m in front of the box at half its height, with the box between target and camera.
	var holder: Node3D = Node3D.new()
	root.add_child(holder)
	var target: Node3D = Node3D.new()
	holder.add_child(target)
	target.global_position = Vector3(top.x, maxf(top.y * 0.5, 0.3), top.z - 3.0)
	var unobstructed: Vector3 = target.global_position + Vector3(0, 0, 5.0)
	# Where the box's near face is, by a ray along the camera's arm.
	var arm: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(target.global_position, unobstructed)
	var arm_hit: Dictionary = space.intersect_ray(arm)
	_check(not arm_hit.is_empty(), "the arm ray did not hit the box")
	if arm_hit.is_empty():
		return
	var face_distance: float = target.global_position.distance_to(arm_hit["position"] as Vector3)
	_report["box"] = {"top": [top.x, top.y, top.z], "face_distance_along_arm": face_distance}
	var sphere: SphereShape3D = SphereShape3D.new()
	sphere.radius = 0.19
	for mode in ["follow", "deoccluder"]:
		var camera: CameramanCamera = _rig(holder, target, mode)
		await physics_frame
		for _frame in 60:
			camera.update_state(Vector3.UP, FRAME)
		var position: Vector3 = camera.get_state().get_final_position()
		var distance: float = target.global_position.distance_to(position)
		var overlap: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
		overlap.shape = sphere
		overlap.margin = 0.0
		overlap.transform = Transform3D(Basis.IDENTITY, position)
		var touching: int = space.intersect_shape(overlap, 8).size()
		_report[mode] = {"camera_distance": distance, "camera_sphere_overlaps": touching}
		_check(distance < face_distance + 0.01, "%s: camera at %.3f m is behind the box face at %.3f m" % [
			mode, distance, face_distance
		])
		_check(distance > face_distance - 0.5, "%s: camera at %.3f m stopped far short of the face at %.3f m" % [
			mode, distance, face_distance
		])
		# The deoccluder backs off along its ray only, so against a slanted face its sphere may still touch.
		_check(touching == 0 or mode == "deoccluder", "%s: the camera's sphere overlaps streamed collision" % mode)
		# With the cell's body excluded by RID the camera goes to its full distance.
		if mode == "follow":
			(camera.get_child(0) as CameramanThirdPersonFollow).avoid_obstacles.excluded_rids.append(body)
		else:
			(camera.get_child(1) as CameramanDeoccluder).excluded_rids.append(body)
		for _frame in 120:
			camera.update_state(Vector3.UP, FRAME)
		var free_distance: float = target.global_position.distance_to(camera.get_state().get_final_position())
		_report[mode]["camera_distance_cell_excluded"] = free_distance
		_check(absf(free_distance - 5.0) < 0.01, "%s: with the cell excluded the camera is at %.3f m, not 5" % [
			mode, free_distance
		])
		camera.queue_free()
