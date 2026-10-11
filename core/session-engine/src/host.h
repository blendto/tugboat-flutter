// Host metadata: what the platform host knows about the app, device, and
// network (the slice 1 `host` vocabulary, TugboatCollectorConfig without
// transport settings). Shared by the stateless collector mapping and
// `engine.configure`. Not part of the C ABI.
#ifndef TUGBOAT_SESSION_ENGINE_HOST_H
#define TUGBOAT_SESSION_ENGINE_HOST_H

#include <cstdint>
#include <optional>
#include <string>

#include "json.h"
#include "models.h"
#include "reader.h"

namespace tugboat {
namespace engine {

struct AppInfo {
  std::string name;
  std::string version;
  std::string build_number;
  std::string installation_id;
  std::string app_id;
};

struct DeviceInfo {
  std::string id;
  std::string platform;
  OptString manufacturer;
  OptString model;
  OptString os_version;
  std::optional<int64_t> battery_percent;
  std::optional<int64_t> storage_free_mb;
  std::optional<int64_t> ram_mb;
  OptString network_type;
  double screen_width = 0;
  double screen_height = 0;
  double screen_density = 0;
  int64_t screen_dpi = 0;
  double screen_pixel_density = 0;
};

struct IpInfo {
  std::string ip;
  OptString city;
  OptString region;
  OptString country;
  OptString timezone;
  OptString isp;
  OptString org;
};

struct ConfiguredLocale {
  OptString language;
  OptString country;
  OptString timezone;
};

struct Host {
  AppInfo app;
  DeviceInfo device;
  IpInfo ip;
  ConfiguredLocale locale;
  OptString configured_user_id;
};

// Decodes the `host` object at JSON path `where`. Every field the collector
// needs for `session_start` is required: app version and build number, the
// device with its screen size and densities, the IP, and the configured
// locale (which may be `{}`).
bool decode_host(const Value& json, const std::string& where, Host* out,
                 Error* error);

// TugboatCollectorAppInfo.toJson (`packageName` repeats `appId`).
Value app_info_json(const AppInfo& app);

}  // namespace engine
}  // namespace tugboat

#endif  // TUGBOAT_SESSION_ENGINE_HOST_H
