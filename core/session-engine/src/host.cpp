#include "host.h"

namespace tugboat {
namespace engine {

namespace {

bool decode_app(const Value& json, const std::string& where, AppInfo* out,
                Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys(
             {"name", "version", "buildNumber", "installationId", "appId"}) &&
         r.req_string("name", &out->name) &&
         r.req_string("version", &out->version) &&
         r.req_string("buildNumber", &out->build_number) &&
         r.req_string("installationId", &out->installation_id) &&
         r.req_string("appId", &out->app_id);
}

bool decode_screen(const ObjectReader& device, DeviceInfo* out, Error* error) {
  const Value* screen = nullptr;
  if (!device.req_object("screenSize", &screen)) {
    return false;
  }
  const ObjectReader r(*screen, device.child("screenSize"), error);
  return r.check_keys({"width", "height"}) &&
         r.req_double("width", &out->screen_width) &&
         r.req_double("height", &out->screen_height);
}

bool decode_device(const Value& json, const std::string& where,
                   DeviceInfo* out, Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys({"id", "platform", "manufacturer", "model", "osVersion",
                       "batteryPercent", "storageFreeMb", "ramMb",
                       "networkType", "screenSize", "screenDensity",
                       "screenDpi", "screenPixelDensity"}) &&
         decode_screen(r, out, error) && r.req_string("id", &out->id) &&
         r.req_string("platform", &out->platform) &&
         r.opt_string("manufacturer", &out->manufacturer) &&
         r.opt_string("model", &out->model) &&
         r.opt_string("osVersion", &out->os_version) &&
         r.opt_int("batteryPercent", &out->battery_percent) &&
         r.opt_int("storageFreeMb", &out->storage_free_mb) &&
         r.opt_int("ramMb", &out->ram_mb) &&
         r.opt_string("networkType", &out->network_type) &&
         r.req_double("screenDensity", &out->screen_density) &&
         r.req_int("screenDpi", &out->screen_dpi) &&
         r.req_double("screenPixelDensity", &out->screen_pixel_density);
}

bool decode_ip(const Value& json, const std::string& where, IpInfo* out,
               Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys(
             {"ip", "city", "region", "country", "timezone", "isp", "org"}) &&
         r.req_string("ip", &out->ip) && r.opt_string("city", &out->city) &&
         r.opt_string("region", &out->region) &&
         r.opt_string("country", &out->country) &&
         r.opt_string("timezone", &out->timezone) &&
         r.opt_string("isp", &out->isp) && r.opt_string("org", &out->org);
}

bool decode_configured_locale(const Value& json, const std::string& where,
                              ConfiguredLocale* out, Error* error) {
  const ObjectReader r(json, where, error);
  return r.check_keys({"language", "country", "timezone"}) &&
         r.opt_string("language", &out->language) &&
         r.opt_string("country", &out->country) &&
         r.opt_string("timezone", &out->timezone);
}

}  // namespace

bool decode_host(const Value& json, const std::string& where, Host* out,
                 Error* error) {
  const ObjectReader r(json, where, error);
  const Value* app = nullptr;
  const Value* device = nullptr;
  const Value* ip = nullptr;
  const Value* locale = nullptr;
  return r.check_keys({"app", "device", "ip", "locale", "configuredUserId"}) &&
         r.req_object("app", &app) &&
         decode_app(*app, r.child("app"), &out->app, error) &&
         r.req_object("device", &device) &&
         decode_device(*device, r.child("device"), &out->device, error) &&
         r.req_object("ip", &ip) &&
         decode_ip(*ip, r.child("ip"), &out->ip, error) &&
         r.req_object("locale", &locale) &&
         decode_configured_locale(*locale, r.child("locale"), &out->locale,
                                  error) &&
         r.opt_string("configuredUserId", &out->configured_user_id);
}

Value app_info_json(const AppInfo& app) {
  Value out = Value::object();
  out.set("name", Value::string(app.name));
  out.set("version", Value::string(app.version));
  out.set("buildNumber", Value::string(app.build_number));
  out.set("installationId", Value::string(app.installation_id));
  out.set("appId", Value::string(app.app_id));
  out.set("packageName", Value::string(app.app_id));
  return out;
}

}  // namespace engine
}  // namespace tugboat
