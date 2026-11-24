extends SceneTree
## Runs every physics query Cameraman makes (intersect_ray, cast_motion, intersect_shape) against
## geometry that matters to a camera, and writes the results as numbers to a JSON file.
## Run once per physics engine and compare the files with compare_parity.py.
##
## godot --headless --path <project> -s res://tests/physics_parity/parity_queries.gd -- --out=<file>

const SPACING: float = 200.0
const PLANE_LAYER: int = 1 << 7
const M0: Dictionary = {"margin": 0.0}

var _results: Dictionary = {}
var _space: PhysicsDirectSpaceState3D
var _world: Node3D
var _origin: Vector3 = Vector3.ZERO
var _scenario: String = ""
var _scenario_index: int = 0
var _server_rids: Array[RID] = []
var _loose_objects: Array[Object] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	_world = Node3D.new()
	_world.name = "ParityWorld"
	root.add_child(_world)
	_build_static_scenarios()
	await physics_frame
	await physics_frame
	_space = root.get_world_3d().direct_space_state
	_query_thin_wall()
	_query_concave_room()
	_query_inside_geometry()
	_query_grazing()
	_query_sphere_along_wall()
	_query_cylinders_and_capsules()
	_query_heightfield()
	_query_many_shapes()
	_query_areas_and_layers()
	_query_world_boundary()
	_query_non_node_bodies()
	_query_scaled_and_convex()
	_query_cast_edge_cases()
	await _query_moving_bodies()
	_write_results()
	for rid in _server_rids:
		PhysicsServer3D.free_rid(rid)
	for object in _loose_objects:
		if is_instance_valid(object):
			object.free()
	quit(0)

# ---------------------------------------------------------------- scene building

func _begin(scenario: String) -> void:
	_scenario = scenario
	_origin = Vector3(SPACING * float(_scenario_index), 0.0, 0.0)
	_scenario_index += 1

func _select(scenario: String, index: int) -> void:
	_scenario = scenario
	_origin = Vector3(SPACING * float(index), 0.0, 0.0)

func _body(body: CollisionObject3D, body_name: String, position: Vector3) -> CollisionObject3D:
	body.name = "%s_%s" % [_scenario, body_name]
	body.position = _origin + position
	_world.add_child(body)
	return body

func _shape(body: CollisionObject3D, shape: Shape3D, position: Vector3 = Vector3.ZERO) -> CollisionShape3D:
	var node: CollisionShape3D = CollisionShape3D.new()
	node.shape = shape
	node.position = position
	body.add_child(node)
	return node

func _box(size: Vector3) -> BoxShape3D:
	var shape: BoxShape3D = BoxShape3D.new()
	shape.size = size
	return shape

func _sphere(radius: float) -> SphereShape3D:
	var shape: SphereShape3D = SphereShape3D.new()
	shape.radius = radius
	return shape

func _static_box(body_name: String, position: Vector3, size: Vector3) -> StaticBody3D:
	var body: StaticBody3D = _body(StaticBody3D.new(), body_name, position) as StaticBody3D
	_shape(body, _box(size))
	return body

## A closed box as triangles. Front faces point outward, or inward for a room.
func _box_trimesh(size: Vector3, inward: bool, backface_collision: bool) -> ConcavePolygonShape3D:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var faces: PackedVector3Array = mesh.get_faces()
	if inward:
		for index in range(0, faces.size(), 3):
			var swap: Vector3 = faces[index + 1]
			faces[index + 1] = faces[index + 2]
			faces[index + 2] = swap
	var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	shape.backface_collision = backface_collision
	shape.set_faces(faces)
	return shape

## A wall in the YZ plane at x = 0 facing +X, as a grid of triangles, so casts cross inner edges.
func _grid_wall_trimesh(height: float, length: float, cells: int) -> ConcavePolygonShape3D:
	var faces: PackedVector3Array = PackedVector3Array()
	for row in cells:
		for column in cells:
			var y0: float = height * float(row) / float(cells) - height * 0.5
			var y1: float = height * float(row + 1) / float(cells) - height * 0.5
			var z0: float = length * float(column) / float(cells)
			var z1: float = length * float(column + 1) / float(cells)
			var quad: Array[Vector3] = [
				Vector3(0.0, y0, z0), Vector3(0.0, y1, z0), Vector3(0.0, y1, z1), Vector3(0.0, y0, z1)
			]
			for corner in [0, 1, 2, 0, 2, 3]:
				faces.append(quad[corner])
	var probe: Vector3 = (faces[1] - faces[0]).cross(faces[2] - faces[0])
	if probe.x > 0.0:
		# Godot front faces are clockwise: the geometric normal of a front face points away.
		for index in range(0, faces.size(), 3):
			var swap: Vector3 = faces[index + 1]
			faces[index + 1] = faces[index + 2]
			faces[index + 2] = swap
	var shape: ConcavePolygonShape3D = ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	return shape

func _octahedron(radius: float) -> ConvexPolygonShape3D:
	var shape: ConvexPolygonShape3D = ConvexPolygonShape3D.new()
	shape.points = PackedVector3Array([
		Vector3(radius, 0, 0), Vector3(-radius, 0, 0), Vector3(0, radius, 0),
		Vector3(0, -radius, 0), Vector3(0, 0, radius), Vector3(0, 0, -radius)
	])
	return shape

func _build_static_scenarios() -> void:
	_begin("thin_wall")
	_static_box("wall", Vector3(0, 0, 2), Vector3(4, 4, 0.02))

	_begin("concave_room")
	var room: StaticBody3D = _body(StaticBody3D.new(), "room", Vector3(0, 1.5, 0)) as StaticBody3D
	_shape(room, _box_trimesh(Vector3(6, 3, 6), true, false))
	var room_backface: StaticBody3D = _body(StaticBody3D.new(), "room_backface", Vector3(20, 1.5, 0)) as StaticBody3D
	_shape(room_backface, _box_trimesh(Vector3(6, 3, 6), true, true))

	_begin("inside")
	_shape(_body(StaticBody3D.new(), "box", Vector3(0, 0, 0)), _box(Vector3(2, 2, 2)))
	_shape(_body(StaticBody3D.new(), "sphere", Vector3(10, 0, 0)), _sphere(1.0))
	var capsule: CapsuleShape3D = CapsuleShape3D.new()
	capsule.radius = 1.0
	capsule.height = 4.0
	_shape(_body(StaticBody3D.new(), "capsule", Vector3(20, 0, 0)), capsule)
	var cylinder: CylinderShape3D = CylinderShape3D.new()
	cylinder.radius = 1.0
	cylinder.height = 2.0
	_shape(_body(StaticBody3D.new(), "cylinder", Vector3(30, 0, 0)), cylinder)
	_shape(_body(StaticBody3D.new(), "hull", Vector3(40, 0, 0)), _octahedron(1.5))
	_shape(_body(StaticBody3D.new(), "trimesh", Vector3(50, 0, 0)), _box_trimesh(Vector3(2, 2, 2), false, false))

	_begin("grazing")
	_shape(_body(StaticBody3D.new(), "sphere", Vector3(0, 0, 0)), _sphere(1.0))
	_static_box("box", Vector3(10, 0, 0), Vector3(2, 2, 2))
	_static_box("seam_a", Vector3(19, 0, 0), Vector3(2, 2, 2))
	_static_box("seam_b", Vector3(21, 0, 0), Vector3(2, 2, 2))

	_begin("sphere_along_wall")
	_static_box("wall", Vector3(-0.5, 0, 5), Vector3(1, 4, 20))
	_static_box("pilaster", Vector3(20.05, 0, 5), Vector3(0.1, 4, 0.5))
	_static_box("pilaster_wall", Vector3(19.5, 0, 5), Vector3(1, 4, 20))
	_shape(_body(StaticBody3D.new(), "grid_wall", Vector3(40, 0, 0)), _grid_wall_trimesh(4.0, 10.0, 10))

	_begin("round")
	var pillar: CylinderShape3D = CylinderShape3D.new()
	pillar.radius = 0.5
	pillar.height = 2.0
	_shape(_body(StaticBody3D.new(), "cylinder", Vector3(0, 0, 0)), pillar)
	var big_pillar: CylinderShape3D = CylinderShape3D.new()
	big_pillar.radius = 2.0
	big_pillar.height = 6.0
	_shape(_body(StaticBody3D.new(), "big_cylinder", Vector3(20, 0, 0)), big_pillar)
	var round_capsule: CapsuleShape3D = CapsuleShape3D.new()
	round_capsule.radius = 0.5
	round_capsule.height = 2.0
	_shape(_body(StaticBody3D.new(), "capsule", Vector3(40, 0, 0)), round_capsule)

	_begin("heightfield")
	var height_shape: HeightMapShape3D = HeightMapShape3D.new()
	height_shape.map_width = 17
	height_shape.map_depth = 17
	var heights: PackedFloat32Array = PackedFloat32Array()
	for z in 17:
		for x in 17:
			heights.append(sin(float(x) * 0.7) * 0.8 + cos(float(z) * 0.45) * 0.6)
	height_shape.map_data = heights
	_shape(_body(StaticBody3D.new(), "terrain", Vector3(0, 0, 0)), height_shape)

	_begin("many_shapes")
	var many: StaticBody3D = _body(StaticBody3D.new(), "grid", Vector3(0, 0, 0)) as StaticBody3D
	for index in 25:
		@warning_ignore("integer_division")
		var cell: Vector3 = Vector3(float(index % 5) * 2.0 - 4.0, float(index / 5) * 2.0 - 4.0, 5.0)
		var node: CollisionShape3D = _shape(many, _box(Vector3(1, 1, 1)), cell)
		node.disabled = index == 12

	_begin("filters")
	var area: Area3D = _body(Area3D.new(), "area", Vector3(0, 0, 1)) as Area3D
	_shape(area, _box(Vector3(2, 2, 0.5)))
	_static_box("wall", Vector3(0, 0, 3), Vector3(4, 4, 0.5))
	var layered: StaticBody3D = _static_box("layer2", Vector3(10, 0, 1), Vector3(2, 2, 0.5))
	layered.collision_layer = 2
	_static_box("layer1", Vector3(10, 0, 3), Vector3(4, 4, 0.5))
	_static_box("near", Vector3(20, 0, 1), Vector3(2, 2, 0.5))
	_static_box("far", Vector3(20, 0, 3), Vector3(4, 4, 0.5))

	_begin("world_boundary")
	var plane_body: StaticBody3D = _body(StaticBody3D.new(), "plane", Vector3(0, 0, 0)) as StaticBody3D
	plane_body.collision_layer = PLANE_LAYER
	_shape(plane_body, WorldBoundaryShape3D.new())

	_begin("non_node")
	_server_body(Vector3(0, 0, 2), Vector3(2, 2, 0.25), 0)
	var proxy: Node3D = Node3D.new()
	proxy.name = "non_node_proxy"
	_world.add_child(proxy)
	_server_body(Vector3(10, 0, 2), Vector3(2, 2, 0.25), proxy.get_instance_id())
	var loose: Object = Object.new()
	_loose_objects.append(loose)
	_server_body(Vector3(20, 0, 2), Vector3(2, 2, 0.25), loose.get_instance_id())
	var freed: Object = Object.new()
	var freed_id: int = freed.get_instance_id()
	freed.free()
	_server_body(Vector3(30, 0, 2), Vector3(2, 2, 0.25), freed_id)
	# A node body in front of a server body, to prove a group-ignored node does not hide it.
	_static_box("node_in_front", Vector3(40, 0, 1), Vector3(2, 2, 0.25))
	_server_body(Vector3(40, 0, 2), Vector3(2, 2, 0.25), 0)

	_begin("scaled_convex")
	var scaled: StaticBody3D = _static_box("scaled_box", Vector3(0, 0, 3), Vector3(1, 1, 1))
	scaled.scale = Vector3(2, 2, 2)
	var scaled_sphere: StaticBody3D = _body(StaticBody3D.new(), "scaled_sphere", Vector3(10, 0, 3)) as StaticBody3D
	_shape(scaled_sphere, _sphere(0.5))
	scaled_sphere.scale = Vector3(2, 2, 2)
	_shape(_body(StaticBody3D.new(), "hull", Vector3(20, 0, 3)), _octahedron(1.0))
	var rotated: StaticBody3D = _static_box("rotated_box", Vector3(30, 0, 3), Vector3(2, 2, 2))
	rotated.rotation = Vector3(0.0, PI / 4.0, 0.0)

	_begin("cast_edges")
	_static_box("wall", Vector3(0, 0, 3), Vector3(4, 4, 1))

	_begin("moving")
	# Bodies for this scenario are created in _query_moving_bodies().

func _server_body(position: Vector3, half_extents: Vector3, instance_id: int) -> RID:
	var shape: RID = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, half_extents)
	var body: RID = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, 1)
	PhysicsServer3D.body_set_collision_mask(body, 1)
	PhysicsServer3D.body_add_shape(body, shape)
	PhysicsServer3D.body_set_state(
		body, PhysicsServer3D.BODY_STATE_TRANSFORM, Transform3D(Basis.IDENTITY, _origin + position)
	)
	if instance_id != 0:
		PhysicsServer3D.body_attach_object_instance_id(body, instance_id)
	PhysicsServer3D.body_set_space(body, root.get_world_3d().space)
	_server_rids.append(body)
	_server_rids.append(shape)
	return body

# ---------------------------------------------------------------- query helpers

func _round(value: float) -> float:
	return snappedf(value, 0.00001)

func _vec(value: Vector3) -> Array:
	return [_round(value.x), _round(value.y), _round(value.z)]

func _collider_text(hit: Dictionary) -> String:
	var collider: Variant = hit.get("collider")
	if collider == null:
		return "<null>"
	if not is_instance_valid(collider):
		return "<freed>"
	if collider is Node:
		return String((collider as Node).name)
	return "<%s>" % (collider as Object).get_class()

func _ray(key: String, from: Vector3, to: Vector3, options: Dictionary = {}) -> Dictionary:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(_origin + from, _origin + to)
	query.collision_mask = int(options.get("mask", 1))
	for property in ["hit_from_inside", "hit_back_faces", "collide_with_areas", "collide_with_bodies"]:
		if options.has(property):
			query.set(property, options[property])
	if options.has("exclude"):
		query.exclude = options["exclude"]
	var hit: Dictionary = _space.intersect_ray(query)
	var record: Dictionary = {"call": "intersect_ray", "hit": not hit.is_empty()}
	if not hit.is_empty():
		var position: Vector3 = (hit["position"] as Vector3) - _origin
		record["position"] = _vec(position)
		record["distance"] = _round(from.distance_to(position))
		record["normal"] = _vec(hit["normal"] as Vector3)
		record["collider"] = _collider_text(hit)
		record["collider_id_is_zero"] = int(hit.get("collider_id", 0)) == 0
		record["rid_valid"] = (hit.get("rid", RID()) as RID).is_valid()
		record["shape"] = int(hit.get("shape", -1))
		record["face_index"] = int(hit.get("face_index", -1))
	_results["%s/%s" % [_scenario, key]] = record
	return hit

func _shape_query(shape: Shape3D, at: Vector3, options: Dictionary) -> PhysicsShapeQueryParameters3D:
	var query: PhysicsShapeQueryParameters3D = PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis.IDENTITY, _origin + at)
	query.collision_mask = int(options.get("mask", 1))
	for property in ["margin", "collide_with_areas", "collide_with_bodies"]:
		if options.has(property):
			query.set(property, options[property])
	if options.has("exclude"):
		query.exclude = options["exclude"]
	return query

func _cast(key: String, shape: Shape3D, from: Vector3, motion: Vector3, options: Dictionary = {}) -> void:
	var query: PhysicsShapeQueryParameters3D = _shape_query(shape, from, options)
	query.motion = motion
	var result: PackedFloat32Array = _space.cast_motion(query)
	var record: Dictionary = {"call": "cast_motion", "size": result.size()}
	if result.size() >= 2:
		record["safe"] = _round(result[0])
		record["unsafe"] = _round(result[1])
		record["safe_distance"] = _round(result[0] * motion.length())
		record["unsafe_distance"] = _round(result[1] * motion.length())
	_results["%s/%s" % [_scenario, key]] = record

func _overlap(key: String, shape: Shape3D, at: Vector3, options: Dictionary = {}) -> void:
	var query: PhysicsShapeQueryParameters3D = _shape_query(shape, at, options)
	var hits: Array[Dictionary] = _space.intersect_shape(query, int(options.get("max", 32)))
	var names: Dictionary = {}
	var pairs: Dictionary = {}
	for hit in hits:
		names[_collider_text(hit)] = true
		pairs["%s:%d" % [str(hit.get("rid")), int(hit.get("shape", -1))]] = true
	var sorted_names: Array = names.keys()
	sorted_names.sort()
	_results["%s/%s" % [_scenario, key]] = {
		"call": "intersect_shape",
		"count": hits.size(),
		"distinct_shapes": pairs.size(),
		"colliders": ",".join(PackedStringArray(sorted_names)),
	}

## Casts, then asks whether the shape overlaps anything where the cast said it was safe.
## `contact_distance` is where the shape exactly touches; a positive depth is penetration.
func _safe_position(key: String, shape: Shape3D, from: Vector3, motion: Vector3, contact_distance: float) -> void:
	var query: PhysicsShapeQueryParameters3D = _shape_query(shape, from, M0)
	query.motion = motion
	var result: PackedFloat32Array = _space.cast_motion(query)
	var safe_distance: float = result[0] * motion.length()
	query.motion = Vector3.ZERO
	query.transform = Transform3D(Basis.IDENTITY, _origin + from + motion * result[0])
	var overlaps: int = _space.intersect_shape(query, 8).size()
	_note(key, {
		"safe_depth_mm": snappedf((safe_distance - contact_distance) * 1000.0, 0.01),
		"unsafe_depth_mm": snappedf((result[1] * motion.length() - contact_distance) * 1000.0, 0.01),
		"overlaps_at_safe": overlaps,
	})

func _note(key: String, record: Dictionary) -> void:
	record["call"] = "note"
	_results["%s/%s" % [_scenario, key]] = record

# ---------------------------------------------------------------- scenarios

func _query_thin_wall() -> void:
	_select("thin_wall", 0)
	_ray("ray_perpendicular", Vector3(0, 0, 0), Vector3(0, 0, 4))
	_ray("ray_from_behind", Vector3(0, 0, 4), Vector3(0, 0, 0))
	_ray("ray_shallow_1deg", Vector3(-1.5, 0, 1.94), Vector3(1.5, 0, 1.9924))
	_ray("ray_edge_on", Vector3(-4, 0, 2), Vector3(4, 0, 2))
	_ray("ray_stops_1mm_short", Vector3(0, 0, 0), Vector3(0, 0, 1.989))
	_ray("ray_ends_inside_wall", Vector3(0, 0, 0), Vector3(0, 0, 2.0))
	_ray("ray_long_1km", Vector3(0, 0, -500), Vector3(0, 0, 500))
	_cast("sphere_0.2", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 4), M0)
	_cast("sphere_0.2_default_margin", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 4))
	_cast("sphere_0.2_margin_0.1", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 4), {"margin": 0.1})
	_cast("sphere_0.01", _sphere(0.01), Vector3(0, 0, 0), Vector3(0, 0, 4), M0)
	_cast("sphere_0.2_long_1km", _sphere(0.2), Vector3(0, 0, -500), Vector3(0, 0, 1000), M0)
	_cast("sphere_0.2_shallow", _sphere(0.2), Vector3(-1.5, 0, 1.6), Vector3(3, 0, 0.3), M0)
	_cast("box_0.2", _box(Vector3(0.4, 0.4, 0.4)), Vector3(0, 0, 0), Vector3(0, 0, 4), M0)
	_overlap("sphere_0.2_clear_by_1cm", _sphere(0.2), Vector3(0, 0, 1.78), M0)
	_overlap("sphere_0.2_touching_1cm", _sphere(0.2), Vector3(0, 0, 1.80), M0)
	_overlap("sphere_0.2_clear_by_1cm_default_margin", _sphere(0.2), Vector3(0, 0, 1.78))
	_overlap("sphere_0.2_clear_by_6cm_default_margin", _sphere(0.2), Vector3(0, 0, 1.73))
	_overlap("sphere_0.2_straddling", _sphere(0.2), Vector3(0, 0, 2.0), M0)

func _query_concave_room() -> void:
	_select("concave_room", 1)
	for variant in [["", 0.0], ["backface_", 20.0]]:
		var prefix: String = variant[0]
		var x: float = variant[1]
		_ray(prefix + "ray_inside_to_wall", Vector3(x, 1.5, 0), Vector3(x, 1.5, 5))
		_ray(prefix + "ray_inside_to_corner", Vector3(x, 1.5, 0), Vector3(x + 4, 1.5, 4))
		_ray(prefix + "ray_outside_in", Vector3(x, 1.5, 6), Vector3(x, 1.5, -5))
		_ray(prefix + "ray_outside_in_no_back_faces", Vector3(x, 1.5, 6), Vector3(x, 1.5, -5), {"hit_back_faces": false})
		_ray(prefix + "ray_floor_seam", Vector3(x, 1, 0), Vector3(x, -1, 0))
		_ray(prefix + "ray_skims_floor_1mm", Vector3(x - 2.5, 0.001, -2.5), Vector3(x + 2.5, 0.001, 2.5))
		_ray(prefix + "ray_inside_hit_from_inside", Vector3(x, 1.5, 0), Vector3(x, 1.5, 5), {"hit_from_inside": true})
		_cast(prefix + "sphere_to_wall", _sphere(0.2), Vector3(x, 1.5, 0), Vector3(0, 0, 5), M0)
		_cast(prefix + "sphere_to_corner", _sphere(0.2), Vector3(x, 1.5, 0), Vector3(4, 0, 4), M0)
		_cast(prefix + "sphere_to_floor_seam", _sphere(0.2), Vector3(x, 1.5, 0), Vector3(0, -3, 0), M0)
		_cast(prefix + "sphere_outside_in", _sphere(0.2), Vector3(x, 1.5, 6), Vector3(0, 0, -11), M0)
		_cast(prefix + "sphere_starts_in_wall", _sphere(0.2), Vector3(x, 1.5, 3.0), Vector3(0, 0, -2), M0)
		_overlap(prefix + "sphere_free_inside", _sphere(0.2), Vector3(x, 1.5, 0), M0)
		_overlap(prefix + "sphere_on_wall", _sphere(0.2), Vector3(x, 1.5, 3.0), M0)
		_overlap(prefix + "sphere_outside_touching", _sphere(0.2), Vector3(x, 1.5, 3.1), M0)

func _query_inside_geometry() -> void:
	_select("inside", 2)
	var places: Array = [
		["box", 0.0], ["sphere", 10.0], ["capsule", 20.0], ["cylinder", 30.0], ["hull", 40.0], ["trimesh", 50.0]
	]
	for place in places:
		var label: String = place[0]
		var x: float = place[1]
		_ray(label + "_ray_from_centre", Vector3(x, 0, 0), Vector3(x + 5, 0, 0))
		_ray(label + "_ray_from_centre_hit_from_inside", Vector3(x, 0, 0), Vector3(x + 5, 0, 0), {"hit_from_inside": true})
		_ray(label + "_ray_wholly_inside", Vector3(x, 0, 0), Vector3(x + 0.5, 0, 0))
		_cast(label + "_sphere_from_centre", _sphere(0.2), Vector3(x, 0, 0), Vector3(5, 0, 0), M0)
		_cast(label + "_sphere_from_surface", _sphere(0.2), Vector3(x + 1.0, 0, 0), Vector3(5, 0, 0), M0)
		_cast(label + "_sphere_towards_from_surface", _sphere(0.2), Vector3(x + 1.1, 0, 0), Vector3(-1, 0, 0), M0)
		_overlap(label + "_sphere_at_centre", _sphere(0.2), Vector3(x, 0, 0), M0)

func _query_grazing() -> void:
	_select("grazing", 3)
	for offset in [0.99, 0.999, 0.9999, 1.0, 1.0001, 1.001]:
		_ray("sphere_tangent_x_%s" % str(offset), Vector3(offset, 0, -5), Vector3(offset, 0, 5))
	for offset in [0.999, 1.0, 1.001]:
		_ray("box_face_x_%s" % str(offset), Vector3(10 + offset, 0, -5), Vector3(10 + offset, 0, 5))
	_ray("box_edge_diagonal", Vector3(12, 2, 0), Vector3(10, 0, 0))
	_ray("box_corner_diagonal", Vector3(12, 2, 2), Vector3(10, 0, 0))
	_ray("seam_between_boxes_down", Vector3(20, 5, 0), Vector3(20, -5, 0))
	_ray("seam_between_boxes_along", Vector3(20, 0, -5), Vector3(20, 0, 5))
	_cast("sphere_down_seam", _sphere(0.2), Vector3(20, 5, 0), Vector3(0, -10, 0), M0)
	_cast("sphere_past_sphere_clear_1mm", _sphere(0.2), Vector3(1.201, 0, -5), Vector3(0, 0, 10), M0)
	_cast("sphere_past_sphere_touch_1mm", _sphere(0.2), Vector3(1.199, 0, -5), Vector3(0, 0, 10), M0)

func _query_sphere_along_wall() -> void:
	_select("sphere_along_wall", 4)
	for distance in [0.25, 0.201, 0.2001, 0.2, 0.1999, 0.199, 0.15]:
		_cast("box_wall_gap_%s" % str(distance), _sphere(0.2), Vector3(distance, 0, 0), Vector3(0, 0, 10), M0)
	_cast("box_wall_gap_0.25_default_margin", _sphere(0.2), Vector3(0.25, 0, 0), Vector3(0, 0, 10))
	_cast("box_wall_gap_0.21_default_margin", _sphere(0.2), Vector3(0.21, 0, 0), Vector3(0, 0, 10))
	_cast("pilaster_gap_0.25", _sphere(0.2), Vector3(20.25, 0, 0), Vector3(0, 0, 10), M0)
	_cast("pilaster_gap_0.31", _sphere(0.2), Vector3(20.31, 0, 0), Vector3(0, 0, 10), M0)
	for distance in [0.25, 0.201, 0.2, 0.199]:
		_cast("grid_wall_gap_%s" % str(distance), _sphere(0.2), Vector3(40 + distance, 0, 0.5), Vector3(0, 0, 9), M0)
	_cast("grid_wall_towards", _sphere(0.2), Vector3(42, 0.05, 5.05), Vector3(-4, 0, 0), M0)
	_ray("grid_wall_ray_along_1mm", Vector3(40.001, 0, 0.5), Vector3(40.001, 0, 9.5))
	_ray("grid_wall_ray_on_vertex", Vector3(42, 0, 5), Vector3(38, 0, 5))

func _radial_range(key: String, centre: Vector3, start_radius: float, height: float) -> void:
	var minimum: float = INF
	var maximum: float = -INF
	var misses: int = 0
	var samples: int = 180
	for index in samples:
		var angle: float = TAU * float(index) / float(samples) + 0.0123
		var direction: Vector3 = Vector3(cos(angle), 0.0, sin(angle))
		var from: Vector3 = centre + direction * start_radius + Vector3(0, height, 0)
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
			_origin + from, _origin + centre + Vector3(0, height, 0)
		)
		var hit: Dictionary = _space.intersect_ray(query)
		if hit.is_empty():
			misses += 1
			continue
		var position: Vector3 = (hit["position"] as Vector3) - _origin - centre
		var radius: float = Vector2(position.x, position.z).length()
		minimum = minf(minimum, radius)
		maximum = maxf(maximum, radius)
	if misses == samples:
		minimum = -1.0
		maximum = -1.0
	_note(key, {"min_radius": _round(minimum), "max_radius": _round(maximum), "misses": misses})

func _query_cylinders_and_capsules() -> void:
	_select("round", 5)
	_radial_range("cylinder_r0.5_radial_rays", Vector3(0, 0, 0), 3.0, 0.3)
	_radial_range("cylinder_r2_radial_rays", Vector3(20, 0, 0), 6.0, 0.3)
	_radial_range("capsule_r0.5_radial_rays", Vector3(40, 0, 0), 3.0, 0.3)
	_ray("cylinder_cap", Vector3(0.2, 5, 0.1), Vector3(0.2, -5, 0.1))
	_ray("cylinder_rim", Vector3(2, 3, 0), Vector3(0, 0, 0))
	_ray("cylinder_tangent_0.499", Vector3(0.499, 0, -5), Vector3(0.499, 0, 5))
	_ray("cylinder_tangent_0.49", Vector3(0.49, 0, -5), Vector3(0.49, 0, 5))
	_ray("capsule_cap", Vector3(40.1, 5, 0.1), Vector3(40.1, -5, 0.1))
	_ray("capsule_side", Vector3(45, 0.2, 0), Vector3(40, 0.2, 0))
	_cast("sphere_to_cylinder_side", _sphere(0.2), Vector3(5, 0, 0), Vector3(-5, 0, 0), M0)
	_cast("sphere_to_cylinder_side_22deg", _sphere(0.2), Vector3(4.6194, 0, 1.9134), Vector3(-4.6194, 0, -1.9134), M0)
	_cast("sphere_to_cylinder_cap", _sphere(0.2), Vector3(0.1, 5, 0), Vector3(0, -5, 0), M0)
	_cast("sphere_past_cylinder_clear_1cm", _sphere(0.2), Vector3(0.71, 0, -5), Vector3(0, 0, 10), M0)
	_cast("sphere_past_cylinder_touch_1cm", _sphere(0.2), Vector3(0.69, 0, -5), Vector3(0, 0, 10), M0)
	_cast("sphere_to_big_cylinder", _sphere(0.2), Vector3(26, 0, 1), Vector3(-6, 0, 0), M0)
	_cast("sphere_to_capsule_side", _sphere(0.2), Vector3(45, 0, 0), Vector3(-5, 0, 0), M0)
	_cast("sphere_to_capsule_cap", _sphere(0.2), Vector3(40.1, 5, 0), Vector3(0, -5, 0), M0)
	_overlap("sphere_near_cylinder_clear_1cm", _sphere(0.2), Vector3(0.71, 0, 0), M0)
	_overlap("sphere_near_cylinder_touch_1cm", _sphere(0.2), Vector3(0.69, 0, 0), M0)

func _query_heightfield() -> void:
	_select("heightfield", 6)
	for point in [Vector2(0.5, 0.5), Vector2(0.0, 0.0), Vector2(1.0, 0.5), Vector2(-3.3, 2.7), Vector2(7.9, -7.9)]:
		_ray("ray_down_%s_%s" % [str(point.x), str(point.y)], Vector3(point.x, 10, point.y), Vector3(point.x, -10, point.y))
	_ray("ray_up_from_below", Vector3(0.5, -10, 0.5), Vector3(0.5, 10, 0.5))
	_ray("ray_up_from_below_no_back_faces", Vector3(0.5, -10, 0.5), Vector3(0.5, 10, 0.5), {"hit_back_faces": false})
	_ray("ray_horizontal_through_ridges", Vector3(-9, 0.4, 0.3), Vector3(9, 0.4, 0.3))
	_ray("ray_off_the_edge", Vector3(9, 10, 0), Vector3(9, -10, 0))
	_cast("sphere_down", _sphere(0.2), Vector3(0.5, 10, 0.5), Vector3(0, -20, 0), M0)
	_cast("sphere_horizontal", _sphere(0.2), Vector3(-9, 0.6, 0.3), Vector3(18, 0, 0), M0)
	_cast("sphere_up_from_below", _sphere(0.2), Vector3(0.5, -10, 0.5), Vector3(0, 20, 0), M0)
	_overlap("sphere_above", _sphere(0.2), Vector3(0.5, 5, 0.5), M0)
	_overlap("sphere_below", _sphere(0.2), Vector3(0.5, -5, 0.5), M0)

func _query_many_shapes() -> void:
	_select("many_shapes", 7)
	_ray("ray_shape_0", Vector3(-4, -4, 0), Vector3(-4, -4, 10))
	_ray("ray_shape_7", Vector3(0, -2, 0), Vector3(0, -2, 10))
	_ray("ray_shape_24", Vector3(4, 4, 0), Vector3(4, 4, 10))
	_ray("ray_disabled_shape_12", Vector3(0, 0, 0), Vector3(0, 0, 10))
	_cast("sphere_to_shape_7", _sphere(0.2), Vector3(0, -2, 0), Vector3(0, 0, 10), M0)
	_cast("sphere_through_disabled_shape", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 10), M0)
	_overlap("sphere_covers_all", _sphere(8.0), Vector3(0, 0, 5), M0)
	_overlap("sphere_covers_all_max_8", _sphere(8.0), Vector3(0, 0, 5), {"margin": 0.0, "max": 8})
	_overlap("sphere_covers_four", _sphere(0.6), Vector3(-3, -3, 5), M0)

func _query_areas_and_layers() -> void:
	_select("filters", 8)
	_ray("area_ray_default", Vector3(0, 0, 0), Vector3(0, 0, 5))
	_ray("area_ray_with_areas", Vector3(0, 0, 0), Vector3(0, 0, 5), {"collide_with_areas": true})
	_cast("area_sphere_default", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 5), M0)
	_overlap("area_sphere_default", _sphere(0.2), Vector3(0, 0, 1), M0)
	_overlap("area_sphere_with_areas", _sphere(0.2), Vector3(0, 0, 1), {"margin": 0.0, "collide_with_areas": true})
	for mask in [0, 1, 2, 3]:
		_ray("layer_ray_mask_%d" % mask, Vector3(10, 0, 0), Vector3(10, 0, 5), {"mask": mask})
		_cast("layer_sphere_mask_%d" % mask, _sphere(0.2), Vector3(10, 0, 0), Vector3(0, 0, 5), {"margin": 0.0, "mask": mask})
		_overlap("layer_overlap_mask_%d" % mask, _sphere(0.2), Vector3(10, 0, 1), {"margin": 0.0, "mask": mask})
	var first: Dictionary = _ray("exclude_ray_none", Vector3(20, 0, 0), Vector3(20, 0, 5))
	var exclude: Array[RID] = []
	if not first.is_empty():
		exclude.append(first["rid"] as RID)
	_ray("exclude_ray_near", Vector3(20, 0, 0), Vector3(20, 0, 5), {"exclude": exclude})
	_cast("exclude_sphere_none", _sphere(0.2), Vector3(20, 0, 0), Vector3(0, 0, 5), M0)
	_cast("exclude_sphere_near", _sphere(0.2), Vector3(20, 0, 0), Vector3(0, 0, 5), {"margin": 0.0, "exclude": exclude})
	_overlap("exclude_overlap_none", _sphere(0.2), Vector3(20, 0, 1), M0)
	_overlap("exclude_overlap_near", _sphere(0.2), Vector3(20, 0, 1), {"margin": 0.0, "exclude": exclude})

func _query_world_boundary() -> void:
	_select("world_boundary", 9)
	var mask: Dictionary = {"mask": PLANE_LAYER}
	var plane_cast: Dictionary = {"mask": PLANE_LAYER, "margin": 0.0}
	_ray("ray_down", Vector3(0, 5, 0), Vector3(0, -5, 0), mask)
	_ray("ray_down_3km_away", Vector3(3000, 5, 3000), Vector3(3000, -5, 3000), mask)
	_ray("ray_down_30km_away", Vector3(30000, 5, 0), Vector3(30000, -5, 0), mask)
	_ray("ray_up_from_below", Vector3(0, -5, 0), Vector3(0, 5, 0), mask)
	_ray("ray_below_going_down", Vector3(0, -5, 0), Vector3(0, -15, 0), mask)
	var inside: Dictionary = {"mask": PLANE_LAYER, "hit_from_inside": true}
	_ray("ray_below_hit_from_inside", Vector3(0, -5, 0), Vector3(0, -15, 0), inside)
	_ray("ray_shallow", Vector3(0, 0.5, 0), Vector3(100, -0.5, 0), mask)
	_cast("sphere_down", _sphere(0.2), Vector3(0, 5, 0), Vector3(0, -10, 0), plane_cast)
	_cast("sphere_along_clear_1cm", _sphere(0.2), Vector3(0, 0.21, 0), Vector3(50, 0, 0), plane_cast)
	_cast("sphere_from_below", _sphere(0.2), Vector3(0, -5, 0), Vector3(0, 10, 0), plane_cast)
	_overlap("sphere_above", _sphere(0.2), Vector3(0, 1, 0), plane_cast)
	_overlap("sphere_below", _sphere(0.2), Vector3(0, -5, 0), plane_cast)

func _query_non_node_bodies() -> void:
	_select("non_node", 10)
	var cases: Array = [["no_object", 0.0], ["node_attached", 10.0], ["object_attached", 20.0], ["freed_attached", 30.0]]
	for case in cases:
		var label: String = case[0]
		var x: float = case[1]
		var hit: Dictionary = _ray(label + "_ray", Vector3(x, 0, 0), Vector3(x, 0, 5))
		_cast(label + "_sphere", _sphere(0.2), Vector3(x, 0, 0), Vector3(0, 0, 5), M0)
		_overlap(label + "_overlap", _sphere(0.2), Vector3(x, 0, 2), M0)
		var exclude: Array[RID] = []
		if not hit.is_empty():
			exclude.append(hit["rid"] as RID)
			_note(label + "_hit_keys", {
				"has_collider_key": hit.has("collider"),
				"collider_is_null": hit.get("collider") == null,
				"collider_as_node_is_null": (hit.get("collider") as Node) == null,
				"collider_id": "zero" if int(hit.get("collider_id", 0)) == 0 else "nonzero",
			})
		_ray(label + "_ray_excluded_by_rid", Vector3(x, 0, 0), Vector3(x, 0, 5), {"exclude": exclude})
		var without: Dictionary = {"margin": 0.0, "exclude": exclude}
		_cast(label + "_sphere_excluded_by_rid", _sphere(0.2), Vector3(x, 0, 0), Vector3(0, 0, 5), without)
		_overlap(label + "_overlap_excluded_by_rid", _sphere(0.2), Vector3(x, 0, 2), {"margin": 0.0, "exclude": exclude})
	var front: Dictionary = _ray("behind_node_ray", Vector3(40, 0, 0), Vector3(40, 0, 5))
	var front_exclude: Array[RID] = []
	if not front.is_empty():
		front_exclude.append(front["rid"] as RID)
	_ray("behind_node_ray_node_excluded", Vector3(40, 0, 0), Vector3(40, 0, 5), {"exclude": front_exclude})
	_overlap("behind_node_overlap_both", _sphere(1.0), Vector3(40, 0, 1.5), M0)

func _query_scaled_and_convex() -> void:
	_select("scaled_convex", 11)
	_ray("scaled_box_ray", Vector3(0, 0, 0), Vector3(0, 0, 5))
	_ray("scaled_box_ray_off_centre", Vector3(0.9, 0, 0), Vector3(0.9, 0, 5))
	_cast("scaled_box_sphere", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 5), M0)
	_ray("scaled_sphere_ray", Vector3(10, 0, 0), Vector3(10, 0, 5))
	_cast("scaled_sphere_sphere", _sphere(0.2), Vector3(10, 0, 0), Vector3(0, 0, 5), M0)
	_ray("hull_ray_vertex", Vector3(20, 0, 0), Vector3(20, 0, 5))
	_ray("hull_ray_face", Vector3(20.3, 0.3, 0), Vector3(20.3, 0.3, 5))
	_cast("hull_sphere_vertex", _sphere(0.2), Vector3(20, 0, 0), Vector3(0, 0, 5), M0)
	_cast("hull_sphere_face", _sphere(0.2), Vector3(20.3, 0.3, 0), Vector3(0, 0, 5), M0)
	_ray("rotated_box_ray_edge", Vector3(30, 0, 0), Vector3(30, 0, 5))
	_cast("rotated_box_sphere_edge", _sphere(0.2), Vector3(30, 0, 0), Vector3(0, 0, 5), M0)
	_cast("rotated_box_sphere_face", _sphere(0.2), Vector3(30.5, 0, 0), Vector3(0, 0, 5), M0)

func _query_cast_edge_cases() -> void:
	_select("cast_edges", 12)
	_cast("no_hit", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 1), M0)
	_cast("zero_motion_free", _sphere(0.2), Vector3(0, 0, 0), Vector3.ZERO, M0)
	_cast("zero_motion_overlapping", _sphere(0.2), Vector3(0, 0, 3), Vector3.ZERO, M0)
	_cast("tiny_motion_0.1mm", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 0.0001), M0)
	_cast("stops_exactly_touching", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 2.3), M0)
	_cast("stops_1mm_short", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 2.299), M0)
	_cast("starts_overlapping_moving_in", _sphere(0.2), Vector3(0, 0, 2.4), Vector3(0, 0, 1), M0)
	_cast("starts_overlapping_moving_out", _sphere(0.2), Vector3(0, 0, 2.4), Vector3(0, 0, -1), M0)
	_cast("starts_deep_inside_moving_out", _sphere(0.2), Vector3(0, 0, 3), Vector3(0, 0, -3), M0)
	_cast("starts_touching_moving_away", _sphere(0.2), Vector3(0, 0, 2.3), Vector3(0, 0, -1), M0)
	_cast("starts_touching_sliding", _sphere(0.2), Vector3(0, 0, 2.3), Vector3(1, 0, 0), M0)
	_cast("starts_touching_moving_in", _sphere(0.2), Vector3(0, 0, 2.3), Vector3(0, 0, 1), M0)
	_cast("starts_1mm_clear_moving_in", _sphere(0.2), Vector3(0, 0, 2.299), Vector3(0, 0, 1), M0)
	_cast("starts_1mm_inside_moving_in", _sphere(0.2), Vector3(0, 0, 2.301), Vector3(0, 0, 1), M0)
	_cast("starts_4mm_inside_moving_in", _sphere(0.2), Vector3(0, 0, 2.304), Vector3(0, 0, 1), M0)
	_cast("starts_6mm_inside_moving_in", _sphere(0.2), Vector3(0, 0, 2.306), Vector3(0, 0, 1), M0)
	_safe_position("sphere_0.2_at_safe_position", _sphere(0.2), Vector3(0, 0, 0), Vector3(0, 0, 4), 2.3)
	_safe_position("box_0.4_at_safe_position", _box(Vector3(0.4, 0.4, 0.4)), Vector3(0, 0, 0), Vector3(0, 0, 4), 2.3)
	_ray("zero_length_ray_outside", Vector3(0, 0, 0), Vector3(0, 0, 0))
	_ray("zero_length_ray_inside", Vector3(0, 0, 3), Vector3(0, 0, 3))

func _query_moving_bodies() -> void:
	_select("moving", 13)
	var kinds: Array = [
		["static", StaticBody3D.new()],
		["animatable", AnimatableBody3D.new()],
		["character", CharacterBody3D.new()],
		["frozen_rigid", RigidBody3D.new()],
	]
	var bodies: Array[CollisionObject3D] = []
	for index in kinds.size():
		var body: CollisionObject3D = kinds[index][1]
		if body is AnimatableBody3D:
			(body as AnimatableBody3D).sync_to_physics = false
		if body is RigidBody3D:
			(body as RigidBody3D).freeze = true
			(body as RigidBody3D).freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		_body(body, String(kinds[index][0]), Vector3(10.0 * float(index), 0, 3))
		_shape(body, _box(Vector3(2, 2, 0.5)))
		bodies.append(body)
	# Queried in the same frame the bodies were added: has the server seen them yet?
	for index in kinds.size():
		var x: float = 10.0 * float(index)
		_ray("%s_ray_same_frame_as_added" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
	await physics_frame
	await physics_frame
	for index in kinds.size():
		var x: float = 10.0 * float(index)
		_ray("%s_ray_settled" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
		bodies[index].global_position = _origin + Vector3(x, 0, 6)
		_ray("%s_ray_same_frame_as_moved" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
		_cast("%s_sphere_same_frame_as_moved" % kinds[index][0], _sphere(0.2), Vector3(x, 0, 0), Vector3(0, 0, 10), M0)
	await physics_frame
	for index in kinds.size():
		var x: float = 10.0 * float(index)
		_ray("%s_ray_one_frame_after_move" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
	await physics_frame
	for index in kinds.size():
		var x: float = 10.0 * float(index)
		_ray("%s_ray_two_frames_after_move" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
		bodies[index].get_parent().remove_child(bodies[index])
		_ray("%s_ray_same_frame_as_removed" % kinds[index][0], Vector3(x, 0, 0), Vector3(x, 0, 10))
		bodies[index].queue_free()
	# A dynamic body dropped on a floor: positions differ a little by solver, the queries must agree with them.
	_static_box("floor", Vector3(60, -0.5, 0), Vector3(10, 1, 10))
	var crate: RigidBody3D = _body(RigidBody3D.new(), "crate", Vector3(60, 2, 0)) as RigidBody3D
	_shape(crate, _box(Vector3(1, 1, 1)))
	for _step in 120:
		await physics_frame
	var crate_top: float = crate.global_position.y - _origin.y + 0.5
	var hit: Dictionary = _ray("crate_ray_down_after_2s", Vector3(60, 5, 0), Vector3(60, -5, 0))
	var ray_top: float = ((hit["position"] as Vector3).y - _origin.y) if not hit.is_empty() else -999.0
	_note("crate_rest", {"top_from_node": _round(crate_top), "ray_minus_node": _round(ray_top - crate_top)})

func _write_results() -> void:
	var out_path: String = ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--out="):
			out_path = argument.trim_prefix("--out=")
	var document: Dictionary = {
		"engine": String(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")),
		"version": Engine.get_version_info()["string"],
		"results": _results,
	}
	var text: String = JSON.stringify(document, "  ", true)
	if out_path.is_empty():
		print(text)
		return
	var file: FileAccess = FileAccess.open(out_path, FileAccess.WRITE)
	file.store_string(text)
	file.close()
	print("parity: wrote %d results to %s" % [_results.size(), out_path])
