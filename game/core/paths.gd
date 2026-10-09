extends RefCounted
## Well-known locations (hooks cache.root, cache.logs, cache.settings, hzs.converter_launch).

const DEV_CONVERTER_REL := "converter/src/Hzs.Cli/bin/Release/net10.0/hzsconv.exe"
const DEV_CONVERTER_MAIN := "C:/meshy/converter/src/Hzs.Cli/bin/Release/net10.0/hzsconv.exe"


static func app_root() -> String:
	var la := OS.get_environment("LOCALAPPDATA")
	if la == "":
		return OS.get_user_data_dir().path_join("HorizonStrike")
	return la.replace("\\", "/").path_join("HorizonStrike")


static func logs_dir() -> String:
	return app_root().path_join("logs")


static func log_file() -> String:
	return logs_dir().path_join("latest.log")


static func settings_file() -> String:
	return app_root().path_join("settings.json")


static func default_cache(mock: bool) -> String:
	return app_root().path_join("cache-mock" if mock else "cache")


static func default_out() -> String:
	return app_root().path_join("autotest")


static func exe_dir() -> String:
	return OS.get_executable_path().get_base_dir()


## Repository root when running from the editor / `--path game` (the folder above game/), else "".
static func repo_root() -> String:
	if not OS.has_feature("editor"):
		return ""
	return ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()


## Converter executable: --converter, then {managed}/converter/hzsconv.exe, then the dev build output.
static func converter_exe(override: String) -> String:
	var candidates := PackedStringArray()
	if override != "":
		candidates.append(override)
	candidates.append(exe_dir().path_join("converter/hzsconv.exe"))
	var repo := repo_root()
	if repo != "":
		candidates.append(repo.path_join(DEV_CONVERTER_REL))
		candidates.append(DEV_CONVERTER_MAIN)
	for c in candidates:
		if FileAccess.file_exists(c):
			return c
	return ""


static func norm(p: String) -> String:
	return p.replace("\\", "/").trim_suffix("/")
