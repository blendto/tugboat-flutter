## 0.6.0

### Added

- Initial `TugboatDioInterceptor` that maps Dio request lifecycle callbacks to
  the core Tugboat network observation token.
- `TugboatDioInterceptor.install` inserts at the start of the interceptor chain
  and rejects duplicate installation on the same `Dio` instance.
