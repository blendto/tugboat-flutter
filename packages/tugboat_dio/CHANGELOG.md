## 0.8.6

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.6`.

### Changed

- Compatibility release for `tugboat` 0.8.6. The Dio adapter has no runtime
  behavior changes.

## 0.8.5

This release follows `0.8.0` and stays on the `0.8.x` line as `0.8.5`.

### Changed

- Compatibility release for `tugboat` 0.8.5. Route resolvers may retain
  dynamic identifier segments in bounded absolute paths.

## 0.8.0

### Changed

- Compatibility release for `tugboat` 0.8.0. The Dio adapter has no runtime
  behavior changes.

## 0.7.1

### Changed

- Compatibility release for `tugboat` 0.7.1. The Dio adapter has no runtime
  behavior changes.

## 0.7.0

### Changed

- Compatibility release for `tugboat` 0.7.0. The Dio adapter has no runtime
  behavior changes.

## 0.6.0

### Added

- Initial `TugboatDioInterceptor` that maps Dio request lifecycle callbacks to
  the core Tugboat network observation token.
- `TugboatDioInterceptor.install` appends to the interceptor chain (after
  auth/retry) and rejects duplicate installation on the same `Dio` instance.

### Fixed

- Inactive or ended capture no longer invokes the host route resolver or
  mutates `RequestOptions.extra`.
- Adapter-owned request state is cleaned up after terminal callbacks without
  deleting colliding host metadata.
