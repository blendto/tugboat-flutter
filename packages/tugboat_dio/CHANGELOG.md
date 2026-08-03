## 0.6.0

### Added

- Initial `TugboatDioInterceptor` that maps Dio request lifecycle callbacks to
  the core Tugboat network observation token.
- `TugboatDioInterceptor.install` appends to the interceptor chain (after
  auth/retry) and rejects duplicate installation on the same `Dio` instance.
