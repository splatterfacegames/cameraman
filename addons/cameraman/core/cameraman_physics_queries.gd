@tool
class_name CameramanPhysicsQueries
## Shared physics queries for collision-aware components and extensions.
##
## They make three things independent of the 3D physics engine in use:
## [br]- A hit is identified by its body RID, never by its collider node, so bodies created
## directly on PhysicsServer3D (streamed world collision, for example) behave like any other.
## Their hits carry no node: `collider` is null and `collider_id` is 0.
## [br]- A ray that starts inside a shape passes out of it. GodotPhysics and Jolt report nothing
## for the shape; Box3D reports a hit at the start with a zero normal.
## [br]- A shape cast that starts overlapping geometry passes out of it. GodotPhysics and Jolt
## ignore what the shape overlaps at the start; Box3D reports that it cannot move at all.
extends RefCounted

## Most hits a single ray may skip before the query gives up and reports a clear path.
const MAX_SKIPPED_HITS: int = 32
## Most rounds of casting and excluding ignored bodies a single shape cast may take.
const MAX_CAST_PASSES: int = 8
## Samples taken along a ray or cast to find where it leaves geometry it started inside.
const EXIT_SAMPLES: int = 32
## Halvings that refine that exit point after sampling.
const EXIT_REFINEMENTS: int = 6
## Metres a blocked shape cast steps back while the shape still overlaps the obstacle where the
## engine reported it safe (Box3D reports a rounded shape safe about 5 mm past contact), and the
## most steps it takes.
const BACK_OFF_STEP: float = 0.005
const BACK_OFF_STEPS: int = 4

## Returns the collider of a query hit as a Node, or null when the hit has no node: a body made
## on the physics server without an attached object, an attached object that is not a Node, or
## one that has been freed.
static func get_hit_node(hit: Dictionary) -> Node:
	var collider: Variant = hit.get("collider")
	if collider == null or not is_instance_valid(collider):
		return null
	return collider as Node

## Adds the body or area of a query hit to an exclusion list. Returns false when the hit has no
## valid RID or is already excluded, in which case repeating the query cannot make progress.
static func exclude_hit(exclusions: Array[RID], hit: Dictionary) -> bool:
	var rid: RID = hit.get("rid", RID()) as RID
	if not rid.is_valid() or exclusions.has(rid):
		return false
	exclusions.append(rid)
	return true

## Appends the valid RIDs of `extra` that `exclusions` does not hold yet.
static func append_rids(exclusions: Array[RID], extra: Array[RID]) -> void:
	for rid in extra:
		if rid.is_valid() and not exclusions.has(rid):
			exclusions.append(rid)

## Appends the collision objects a target belongs to: the target itself or its nearest collision
## object ancestor, and every collision object below the target.
static func append_target_bodies(exclusions: Array[RID], target: Node) -> void:
	if target == null:
		return
	var owner_body: CollisionObject3D = target as CollisionObject3D
	var ancestor: Node = target.get_parent()
	while owner_body == null and ancestor != null:
		owner_body = ancestor as CollisionObject3D
		ancestor = ancestor.get_parent()
	if owner_body != null and not exclusions.has(owner_body.get_rid()):
		exclusions.append(owner_body.get_rid())
	_append_descendant_bodies(exclusions, target)

static func _append_descendant_bodies(exclusions: Array[RID], node: Node) -> void:
	for child in node.get_children():
		var body: CollisionObject3D = child as CollisionObject3D
		if body != null and not exclusions.has(body.get_rid()):
			exclusions.append(body.get_rid())
		_append_descendant_bodies(exclusions, child)

## Returns the nearest ray hit that `is_ignored` does not reject, or an empty Dictionary.
## `is_ignored` receives the hit's node (null for a hit without one) and returns true to skip it.
## Skipped hits are excluded by RID. A ray that starts inside a shape leaves it first.
## `exclusions` is not modified; `query.from` and `query.exclude` are.
static func intersect_ray_filtered(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsRayQueryParameters3D,
	exclusions: Array[RID],
	is_ignored: Callable
) -> Dictionary:
	var filtered: Array[RID] = exclusions.duplicate()
	for _index in MAX_SKIPPED_HITS:
		query.exclude = filtered
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty():
			return hit
		if is_ignored.call(get_hit_node(hit)):
			if not exclude_hit(filtered, hit):
				return hit
			continue
		if not _started_inside(query, hit):
			return hit
		if not _leave_shape(space, query):
			return {}
	return {}

## Returns how far a shape can move from `start` along `motion`, from 0 to 1, before it touches
## a body that `is_ignored` does not reject. Bodies it rejects are excluded by RID and the cast
## repeated. A shape that starts overlapping geometry leaves it first.
## `query` supplies the shape, mask and margin; its transform, motion and exclusions are set here.
static func cast_shape_filtered(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsShapeQueryParameters3D,
	start: Vector3,
	motion: Vector3,
	exclusions: Array[RID],
	is_ignored: Callable
) -> float:
	var filtered: Array[RID] = exclusions.duplicate()
	var basis: Basis = query.transform.basis
	var skipped: float = 0.0
	var last_safe: float = 0.0
	for _index in MAX_CAST_PASSES:
		query.transform = Transform3D(basis, start + motion * skipped)
		query.motion = motion * (1.0 - skipped)
		query.exclude = filtered
		var result: PackedFloat32Array = space.cast_motion(query)
		if result.is_empty():
			return last_safe
		var safe: float = clampf(result[0], 0.0, 1.0)
		var unsafe: float = clampf(result[1], safe, 1.0)
		var safe_total: float = skipped + (1.0 - skipped) * safe
		last_safe = safe_total
		if safe >= 1.0:
			return 1.0
		var probe: float = clampf(skipped + (1.0 - skipped) * unsafe + 0.01, 0.0, 1.0)
		var hits: Array[Dictionary] = _overlaps(space, query, basis, start + motion * probe, filtered)
		if hits.is_empty():
			return safe_total
		if _exclude_if_all_ignored(hits, filtered, is_ignored):
			continue
		if safe > 0.0 or skipped > 0.0:
			return _back_off_until_clear(space, query, basis, start, motion, skipped, safe_total, filtered, is_ignored)
		# Blocked before it could move at all: either it rests against the obstacle, or it
		# started inside it and the engine did not pass it out.
		var clear: float = _first_clear_fraction(space, query, basis, start, motion, filtered, is_ignored)
		if clear <= 0.0:
			return safe_total
		if clear < 1.0:
			skipped = clear
			continue
		# Inside something all the way. Ignore what it started in, as GodotPhysics and Jolt do,
		# and cast again for anything else.
		var around_start: Array[Dictionary] = _overlaps(space, query, basis, start, filtered)
		var excluded_any: bool = false
		for hit in around_start:
			if exclude_hit(filtered, hit):
				excluded_any = true
		if not excluded_any:
			return 1.0
	return 1.0

static func _started_inside(query: PhysicsRayQueryParameters3D, hit: Dictionary) -> bool:
	if query.hit_from_inside:
		return false
	return (hit.get("normal", Vector3.UP) as Vector3).is_zero_approx()

## Moves `query.from` to just past the shape it starts inside. Returns false when the ray ends
## inside.
static func _leave_shape(space: PhysicsDirectSpaceState3D, query: PhysicsRayQueryParameters3D) -> bool:
	var from: Vector3 = query.from
	var span: Vector3 = query.to - from
	var inside: float = 0.0
	var outside: float = -1.0
	for sample in range(1, EXIT_SAMPLES + 1):
		var fraction: float = float(sample) / float(EXIT_SAMPLES)
		query.from = from + span * fraction
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() or not _started_inside(query, hit):
			outside = fraction
			break
		inside = fraction
	if outside < 0.0:
		query.from = from
		return false
	for _refinement in EXIT_REFINEMENTS:
		var middle: float = (inside + outside) * 0.5
		query.from = from + span * middle
		var hit: Dictionary = space.intersect_ray(query)
		if hit.is_empty() or not _started_inside(query, hit):
			outside = middle
		else:
			inside = middle
	query.from = from + span * outside
	return true

static func _overlaps(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsShapeQueryParameters3D,
	basis: Basis,
	at: Vector3,
	exclusions: Array[RID]
) -> Array[Dictionary]:
	query.transform = Transform3D(basis, at)
	query.motion = Vector3.ZERO
	query.exclude = exclusions
	return space.intersect_shape(query, 32)

static func _any_solid(hits: Array[Dictionary], is_ignored: Callable) -> bool:
	for hit in hits:
		if not is_ignored.call(get_hit_node(hit)):
			return true
	return false

## Steps `fraction` back towards `floor_fraction` until the shape overlaps nothing solid there.
static func _back_off_until_clear(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsShapeQueryParameters3D,
	basis: Basis,
	start: Vector3,
	motion: Vector3,
	floor_fraction: float,
	fraction: float,
	exclusions: Array[RID],
	is_ignored: Callable
) -> float:
	var length: float = motion.length()
	if length <= 0.0:
		return fraction
	for _step in BACK_OFF_STEPS:
		if fraction <= floor_fraction:
			break
		if not _any_solid(_overlaps(space, query, basis, start + motion * fraction, exclusions), is_ignored):
			break
		fraction = maxf(fraction - BACK_OFF_STEP / length, floor_fraction)
	return fraction

## True when every hit is ignored; they are then excluded. False when one is solid, or when
## nothing new could be excluded. A hit without a node is in no group: it is solid.
static func _exclude_if_all_ignored(
	hits: Array[Dictionary],
	exclusions: Array[RID],
	is_ignored: Callable
) -> bool:
	for hit in hits:
		if not is_ignored.call(get_hit_node(hit)):
			return false
	var excluded_any: bool = false
	for hit in hits:
		if exclude_hit(exclusions, hit):
			excluded_any = true
	return excluded_any

## The first fraction of `motion` at which the shape overlaps nothing solid: 0 when it is clear
## where it starts, 1 when it is never clear.
static func _first_clear_fraction(
	space: PhysicsDirectSpaceState3D,
	query: PhysicsShapeQueryParameters3D,
	basis: Basis,
	start: Vector3,
	motion: Vector3,
	exclusions: Array[RID],
	is_ignored: Callable
) -> float:
	var inside: float = 0.0
	var outside: float = -1.0
	for sample in range(0, EXIT_SAMPLES + 1):
		var fraction: float = float(sample) / float(EXIT_SAMPLES)
		var hits: Array[Dictionary] = _overlaps(space, query, basis, start + motion * fraction, exclusions)
		if hits.is_empty() or _exclude_if_all_ignored(hits, exclusions, is_ignored):
			outside = fraction
			break
		inside = fraction
	if outside <= 0.0:
		return 0.0 if outside == 0.0 else 1.0
	for _refinement in EXIT_REFINEMENTS:
		var middle: float = (inside + outside) * 0.5
		var hits: Array[Dictionary] = _overlaps(space, query, basis, start + motion * middle, exclusions)
		if hits.is_empty() or _exclude_if_all_ignored(hits, exclusions, is_ignored):
			outside = middle
		else:
			inside = middle
	return outside
