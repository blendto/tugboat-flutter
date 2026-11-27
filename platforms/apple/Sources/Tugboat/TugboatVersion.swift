/// Version of the native Apple SDK (module `Tugboat`), versioned on its own
/// (ADR 0008). This is the single source of truth: `HostConfig` sends it as
/// `X-Sdk-Version`, and the newest `CHANGELOG.md` entry must name it
/// (`TugboatVersionTests`).
enum TugboatVersion {
  static let current = "0.1.0"
}
