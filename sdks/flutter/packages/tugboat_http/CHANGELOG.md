## 0.12.5

### Changed

- `tugboat_http` now versions in lockstep with `tugboat` and `tugboat_dio`:
  every release of the three shares one version number and one `v<version>`
  tag. This jumps from 0.1.0 to 0.12.5; there is no API change.
- The `tugboat` floor is now `^0.12.5`, so apps on `tugboat_http` get iOS
  sessions that report the exact device model (`iPhone17,1`).

## 0.1.0

- Add `TugboatHttpClient` to record network evidence from `package:http`.
