extends SceneTree
## Dev check (owner vykon): GraphicsSettings.drop_top_mips on real cache DDS files.
##   godot --headless --path game --script res://dev/perf_mips_check.gd -- <textures dir> [max files]
## For every file: format, size, mips before/after, data bytes before/after; FAIL when a result is not exactly
## (w/2, h/2) with one mip less or its first level differs from the source's mip 1.

const GS := preload("res://settings/graphics_settings.gd")
const MeshLib := preload("res://world/mesh_library.gd")


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var dir: String = args[0] if args.size() > 0 else ""
	var max_n := int(args[1]) if args.size() > 1 else 50
	var fails := 0
	var n := 0
	var before := 0
	var after := 0
	for f in DirAccess.get_files_at(dir):
		if not f.ends_with(".dds") or n >= max_n:
			continue
		n += 1
		var img: Image = MeshLib.load_dds(dir.path_join(f))
		if img == null:
			continue
		var out := GS.drop_top_mips(img, 1)
		before += img.get_data_size()
		after += out.get_data_size()
		if img.get_width() < 8 or img.get_height() < 8:
			if out != img:
				fails += 1
				print("  FAIL %s: a %dx%d image must stay as it is" % [f, img.get_width(), img.get_height()])
			continue
		var ok := out != img and out.get_width() == img.get_width() / 2 and out.get_height() == img.get_height() / 2 \
			and out.get_mipmap_count() == img.get_mipmap_count() - 1
		if ok:
			# first level of the result = mip 1 of the source
			var a := img.get_data().slice(img.get_mipmap_offset(1), img.get_mipmap_offset(2) if img.get_mipmap_count() > 1 else img.get_data_size())
			var b := out.get_data().slice(0, out.get_mipmap_offset(1) if out.get_mipmap_count() > 0 else out.get_data_size())
			ok = a == b
		if not ok:
			fails += 1
		if n <= 5 or not ok:
			print("  %s %s fmt %d %dx%d mips %d -> %dx%d mips %d, %d -> %d bytes" % ["ok  " if ok else "FAIL", f, img.get_format(),
				img.get_width(), img.get_height(), img.get_mipmap_count(), out.get_width(), out.get_height(), out.get_mipmap_count(),
				img.get_data_size(), out.get_data_size()])
	print("MIPS_CHECK %d files, %d failed, %.1f -> %.1f MiB" % [n, fails, before / 1048576.0, after / 1048576.0])
	quit(1 if fails > 0 else 0)
