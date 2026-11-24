# Physics engines and collision without nodes

Three parts of Cameraman ask the 3D physics engine questions:

| Part | Query | Purpose |
| --- | --- | --- |
| `CameramanThirdPersonFollow` with `avoid_obstacles.enabled` | `cast_motion` with a sphere, then `intersect_shape` (up to 32 results) to name what stopped it; `intersect_ray` when `camera_radius` is 0 | Shortens the shoulder and the camera arm at obstacles |
| `CameramanDeoccluder` | `intersect_ray` from the look-at target to the camera | Pulls the camera in front of what hides the target |
| `CameramanThirdPersonAim` | `intersect_ray` from the camera along its forward axis | Finds the point the camera aims at |

All three go through `CameramanPhysicsQueries`
(`addons/cameraman/core/cameraman_physics_queries.gd`). The camera behaves the
same under GodotPhysics3D, Jolt Physics and Box3D Physics (the default 3D engine
of Tarragon), within the limits measured below.

## Collision that has no node

A body can exist on `PhysicsServer3D` without any node: `body_create()`,
`body_add_shape()`, `body_set_space()`. A streamed open world attaches each
cell's baked collision this way. A query that hits such a body returns:

| Key | Value |
| --- | --- |
| `collider` | `null` |
| `collider_id` | `0` |
| `rid` | the body's RID |
| `shape` | the shape's index in the body (`0` for a cell's one baked compound) |

This is the same under all three engines. If the body has an object attached
with `body_attach_object_instance_id()`, `collider` is that object, which need
not be a `Node`, and is `null` again once the object is freed.

Cameraman's rules for such hits:

- **A hit without a node is solid.** It is in no group, so `ignore_group`,
  `ignore_groups` and `transparent_groups` never apply to it. The camera
  collides with it, the deoccluder treats it as an occluder, the aim stops on it.
- **Ignored colliders are skipped by the hit's RID**, not by the node's. An
  ignored collider that is not a `CollisionObject3D` (a `CSGShape3D` with
  collision, a `GridMap`, an object attached to a server body) is skipped
  correctly, and what lies behind it is still found.
- **Exclude by RID when there is no node to put in a group.** Each part has an
  `excluded_rids: Array[RID]`, filled at run time (RIDs are not saved):

  ```gdscript
  follow.avoid_obstacles.excluded_rids.append(body_rid)   # CameramanObstacleAvoidance
  deoccluder.excluded_rids.append(body_rid)               # CameramanDeoccluder
  aim.excluded_rids.append(body_rid)                      # CameramanThirdPersonAim
  ```

  A hit's `rid` is the value to exclude. Remove a RID from the list when its
  body is freed; a streamed cell's body changes every time the cell streams in.
- **Prefer collision layers for whole categories.** `collision_mask`,
  `collide_against` and `aim_collision_mask` are honoured the same way by all
  three engines and cost nothing per frame.

Excluding a streamed cell's RID excludes the whole cell, ground included: a
cell is one body with one shape.

## What differs between engines, and what Cameraman does about it

Measured with `tests/physics_parity/` on Tarragon 4.7.2 (commit `c103c09308`),
294 queries per engine. With a tolerance of 2 cm and face indices left out, 211
agree and 83 differ; every difference falls under one of these headings.

| Difference | Box3D | Jolt | GodotPhysics | Cameraman |
| --- | --- | --- | --- | --- |
| Ray that starts inside a convex shape (`hit_from_inside` off) | Hit at the start, normal `(0, 0, 0)` | No hit | No hit | The ray leaves the shape and reports what is beyond, on every engine |
| Shape cast that starts overlapping a shape by more than about 4 mm | `[0, 0]`: cannot move | Ignores what it overlaps | Ignores what it overlaps | The shape leaves what it starts in, then collides normally |
| Where a sphere cast reports "safe" against a flat wall | 4.5 mm past contact; `intersect_shape` there reports the wall | 1.2 mm before contact | 3.1 mm before contact on a 4 m cast (it bisects in steps of motion / 256) | Steps back in 5 mm steps until the sphere touches nothing |
| Sphere cast that grazes by less than 5 mm | Miss | Hit | Hit | None: the camera notices a grazed corner a frame later under Box3D |
| `CylinderShape3D` | A prism of 32 sides: up to 0.5 % of the radius inside the cylinder (2.5 mm at 0.5 m, 9.8 mm at 2 m) | Exact | Exact | None |
| Concave shape with `backface_collision` | Back faces do not collide (warned once) | Collide | Collide | None |
| `HeightMapShape3D` from below | No hit, ray or cast | Hit | Hit | None |
| Sphere cast into the back of a one-sided concave shape | Passes | Passes | Stops | None |
| `WorldBoundaryShape3D` far from the origin | A box 2000 m wide (project setting) | A box 2000 m wide (project setting) | Infinite | None: do not rely on a world boundary under a large world |
| Body queried in the frame it was added | Found | Found | Found a physics frame later | None |
| `face_index` of a ray hit | Triangle index | `-1` unless enabled | Triangle index, numbered differently | Not used |
| Normal of a ray that hits exactly an edge or a vertex | Either adjacent face | Either adjacent face | Either adjacent face | Not used |

Areas are ignored, collision layers and masks are applied, exclusion by RID
works and the `shape` index of a many-shape body is reported, identically on
all three.

The first three rows had made the camera behave differently under Box3D: a
deoccluder whose target was a marker inside the character's capsule sat on the
target (the ray hit the capsule it started in), and a rig whose arm started
inside a low ceiling collapsed onto the character. Both are covered by GUT
tests that pass on all three engines.

## The camera's path, frame by frame

`behaviour_paths.gd` moves a target by hand, so its path is identical under
every engine, and records the camera every frame at 60 Hz on three walks: a
slalom past round and square pillars while looking left and right, backing
into a wall of triangles and walking away, and passing under a low ceiling that
the rig's arm reaches into. Largest and mean distance between two engines'
cameras on the same frame:

| Rig, walk | Box3D vs Jolt | Box3D vs GodotPhysics | Jolt vs GodotPhysics |
| --- | --- | --- | --- |
| Third-person follow, pillars | 2.27 m at one contact, mean 8.5 mm | 2.28 m, mean 8.9 mm | 38 mm, mean 2.2 mm |
| Third-person follow, wall | 3.4 mm, mean 0.9 mm | 21 mm, mean 8.1 mm | 19 mm, mean 7.2 mm |
| Third-person follow, ceiling | 3.2 mm, mean 0.2 mm | 2.15 m at one contact, mean 18 mm | 2.15 m at one contact, mean 18 mm |
| Deoccluder, pillars | 4.1 mm, mean 0.1 mm | 4.1 mm, mean 0.1 mm | 0 |
| Deoccluder, wall | 0.20 m on 2 frames, mean 0.9 mm | 0.20 m on 2 frames, mean 0.9 mm | 0 |
| Deoccluder, ceiling | 0 | 0 | 0 |

The metre-sized entries are one event seen a frame apart: when the arm first
touches a pillar the camera jumps in, on every engine, and one engine sees the
contact a frame before another. The cameras agree again within 1 cm about 20
frames later. Under Box3D that frame of delay comes from the grazing rule in
the table above.

The jump itself is not specific to an engine: with the default position
`damping` of zero the camera moves more than 0.25 m in a frame 11 or 12 times on
the pillar walk under each engine.

## Cost

`query_cost.gd`, microseconds per camera per frame for the queries alone (the
rig's update with collision minus the same rig's update without it), least
disturbed of seven repeats, on a shared 12-thread desktop that was busy with
other work. Treat them as relative.

| Rig, walk | Box3D | Jolt | GodotPhysics |
| --- | ---: | ---: | ---: |
| Third-person follow, pillars | 75 | 68 | 73 |
| Third-person follow, wall | 97 | 97 | 157 |
| Third-person follow, ceiling (arm starts inside geometry) | 196 | 75 | 69 |
| Deoccluder, pillars | 18 | 19 | 22 |
| Deoccluder, wall | 30 | 33 | 28 |
| Deoccluder, ceiling | 31 | 26 | 21 |

One raw call from GDScript, in the same scene: `intersect_ray` 0.34 / 0.33 /
0.65, `cast_motion` 2.3 / 1.5 / 5.6, `intersect_shape` 2.2 / 0.8 / 0.7
(Box3D / Jolt / GodotPhysics). Most of a rig's collision cost is GDScript
around the queries, not the queries.

The ceiling walk is dearer under Box3D because the cast starts inside geometry
on every frame and Cameraman samples its way out (up to 16 overlap tests and 5
halvings per cast); the other engines do that step themselves.

## Running the measurements

```console
GODOT=/path/to/editor tests/physics_parity/run.sh --out /tmp/parity
GODOT=/path/to/editor tests/physics_parity/run.sh --out /tmp/parity gut
GODOT=/path/to/editor tests/physics_parity/run.sh --out /tmp/parity --engines "Box3D Physics" streamed_world
```

`box3d_repro` as a script name prints the first three differences of the table
above in three lines, as a minimal reproduction for the engine.

`run.sh` makes one scratch project per engine under `--out`, differing only in
`physics/3d/physics_engine`, runs the scripts in each and writes
`parity_1mm.md`, `parity_2cm.md`, `paths.md` and `cost.md`. `--engines` takes
the engine names separated by semicolons; on stock Godot use
`"Jolt Physics;GodotPhysics3D"`. `gut` runs the repository's GUT suite under
each engine. `streamed_world` needs Tarragon: it bakes a small synthetic
streamed world, streams it in and checks both rigs against its baked collision.

## Not measured

- A real streamed city cell. The streamed-world check uses the engine's
  synthetic world: flat ground and boxes, one baked compound per cell.
- `CameramanThirdPersonAim` on the scripted walks (it has unit tests only).
- Soft bodies, and bodies that move between a physics frame and the camera
  update other than by one teleport.
- Stock Godot 4.4.1 with Jolt. The repository's CI runs the GUT suite on Godot
  4.4.1 with its default engine.
