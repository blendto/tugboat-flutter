## 0.12.10

### Changed

- Compatibility release for `tugboat` 0.12.10 (pop back several screens in one
  step). No `tugboat_http` change; its `tugboat` floor is now `^0.12.10`.

## 0.12.9

### Changed

- Compatibility release for `tugboat` 0.12.9 (tap target actions fix). No
  `tugboat_http` change; its `tugboat` floor is now `^0.12.9`.

## 0.12.8

### Changed

- Compatibility release for `tugboat` 0.12.8 (screenshot masking fix). No
  `tugboat_http` change; its `tugboat` floor is now `^0.12.8`.

## 0.12.7

### Changed

- Compatibility release for `tugboat` 0.12.7 (sink failures stay inside the
  SDK). No `tugboat_http` change; its `tugboat` floor is now `^0.12.7`.

## 0.12.6

### Changed

- Compatibility release for `tugboat` 0.12.6 (dot-notation markers and an
  opt-in accessibility identifier on tags). No `tugboat_http` change; its
  `tugboat` floor is now `^0.12.6`.

## 0.12.5

### Changed

- `tugboat_http` now versions in lockstep with `tugboat` and `tugboat_dio`:
  every release of the three shares one version number and one `v<version>`
  tag. This jumps from 0.1.0 to 0.12.5; there is no API change.
- The `tugboat` floor is now `^0.12.5`, so apps on `tugboat_http` get iOS
  sessions that report the exact device model (`iPhone17,1`).

## 0.1.0

- Add `TugboatHttpClient` to record network evidence from `package:http`.
