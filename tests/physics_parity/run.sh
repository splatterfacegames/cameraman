#!/usr/bin/env bash
# Runs a headless script of this repository under each 3D physics engine, each in its own scratch
# project that differs only in physics/3d/physics_engine.
#
#   GODOT=/path/to/editor tests/physics_parity/run.sh [--out DIR] [--engines "A;B"] [script ...]
#
# With no script it runs the three in this directory that compare engines (parity_queries,
# behaviour_paths, query_cost) and compares their output. Other names:
#   streamed_world  Tarragon only: the rigs against a streamed synthetic world (baked compounds)
#   gut             the repository's GUT suite
# The binary must be an editor build (it imports the project to build the class cache).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
godot="${GODOT:-godot}"
out="${TMPDIR:-/tmp}/cameraman_physics_parity"
engines="Box3D Physics;Jolt Physics;GodotPhysics3D"
scripts=()
while [ $# -gt 0 ]; do
	case "$1" in
		--out) out="$2"; shift 2 ;;
		--engines) engines="$2"; shift 2 ;;
		*) scripts+=("$1"); shift ;;
	esac
done
[ ${#scripts[@]} -gt 0 ] || scripts=(parity_queries behaviour_paths query_cost)
mkdir -p "$out"

IFS=';' read -r -a engine_list <<< "$engines"
tags=()
for engine in "${engine_list[@]}"; do
	tag="$(echo "$engine" | tr -cd '[:alnum:]' | tr '[:upper:]' '[:lower:]')"
	tags+=("$tag")
	project="$out/project_$tag"
	if [ ! -f "$project/project.godot" ]; then
		mkdir -p "$project"
		for entry in addons tests demo .gutconfig.json; do
			ln -sfn "$repo/$entry" "$project/$entry"
		done
		{
			grep -v '^run/main_scene' "$repo/project.godot"
			printf '\n[physics]\n\n3d/physics_engine="%s"\n' "$engine"
		} > "$project/project.godot"
		"$godot" --headless --path "$project" --import > "$out/import_$tag.log" 2>&1 || true
	fi
	for script in "${scripts[@]}"; do
		log="$out/${script}_$tag.log"
		if [ "$script" = gut ]; then
			"$godot" --headless --path "$project" -s addons/gut/gut_cmdln.gd -gexit > "$log" 2>&1 || true
			echo "$engine: $(grep -a -E '^ *(Tests|Passing|Failing|Risky|Pending|Asserts) ' "$log" | tr -s ' \n' ' ')" \
				"crashes: $(grep -a -c 'handle_crash' "$log" || true)"
		else
			"$godot" --headless --path "$project" -s "res://tests/physics_parity/$script.gd" -- \
				"--out=$out/${script}_$tag.json" "--world=$out/world_$tag" > "$log" 2>&1 || echo "$engine: $script exited with $?"
			echo "$engine: $script, $(grep -a -c -E '^(ERROR|SCRIPT ERROR)' "$log" || true) errors and" \
				"$(grep -a -c '^WARNING' "$log" || true) warnings in $log"
		fi
	done
done

for script in "${scripts[@]}"; do
	files=()
	for tag in "${tags[@]}"; do
		[ -f "$out/${script}_$tag.json" ] && files+=("$out/${script}_$tag.json")
	done
	[ ${#files[@]} -ge 1 ] || continue
	case "$script" in
		parity_queries)
			python3 "$here/compare_parity.py" --markdown "$out/parity_1mm.md" "${files[@]}" > /dev/null
			python3 "$here/compare_parity.py" --tolerance 0.02 --ignore face_index,unsafe,unsafe_distance,safe \
				--markdown "$out/parity_2cm.md" "${files[@]}" > /dev/null
			echo "parity tables: $out/parity_1mm.md (every difference over 1 mm)"
			echo "               $out/parity_2cm.md (over 2 cm, without face indices)"
			sed -n '1,/^$/p' "$out/parity_2cm.md" ;;
		behaviour_paths) python3 "$here/compare_paths.py" --markdown "$out/paths.md" "${files[@]}" ;;
		query_cost) python3 "$here/compare_cost.py" --markdown "$out/cost.md" "${files[@]}" ;;
		streamed_world) cat "${files[@]}" ;;
	esac
done
